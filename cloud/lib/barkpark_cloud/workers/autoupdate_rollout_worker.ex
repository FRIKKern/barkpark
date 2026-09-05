defmodule BarkparkCloud.Workers.AutoupdateRolloutWorker do
  @moduledoc """
  isu-w4 — the fleet autoupdate rollout. Walks the managed fleet ONE
  health-gated instance at a time, riding the isu-6 machinery: each instance is
  its own source of truth (`Registry.refresh_update_status/1` → GET
  /v1/admin/self-update) and the trigger is a server-side relay
  (`Registry.trigger_self_update/1` → POST). Autonomous by design — a blessed
  release (release-curator) is what makes instances report `behind`, and this
  worker rolls that release out with no human step, opt-out per instance.

  Each tick:

    1. SETTLE — for every in-flight instance (one whose `autoupdate_triggered_at`
       is stamped) re-check its live verdict. If it now reports `current`, the
       update landed: clear the marker. If it has NOT settled within
       `#{div(20 * 60, 60)} min`, clear the marker — and pause the instance's
       autoupdate ONLY if the box actually ANSWERED and still is not current (a
       measured failure to land, which would otherwise retry in a storm — a human
       investigates). If the control plane could not READ the box, nothing is
       paused: `autoupdate_paused` has no automatic clear, and an unreachable box
       has already left the candidate set on `update_state: "unknown"`.
    2. GATE — if anything is still in flight after the settle pass, STOP. The
       rollout is serial: never start a new instance while a wave is unsettled.
       This IS the health gate — a slow/failing update blocks advancement.
    3. ADVANCE — otherwise trigger the next eligible `behind` instance
       (`Registry.next_autoupdate_candidate/0`, oldest-stale first) and stamp it
       in-flight. ONLY a 202 is a run THIS tick started; a 409 is the instance's
       `already_running` — a run in flight that is NOT ours, marked in-flight and
       left to the settle grace, never announced as ours and never paused for
       being busy (cch-w58-s2). A 503 means the box never armed one-click apply,
       so we RECORD that (`Registry.record_apply_unarmed/1`) and let
       `next_autoupdate_candidate/1` skip it from then on — never
       `pause_autoupdate/1`, which no code path clears (task-0dd7578bc3d2bcbd);
       any other outcome is transient and simply retried next tick.

  Serial (cohort of 1) is the SAFEST v1 canary — every instance is proven live
  on the new release before the next is touched. Parallel cohorts that grow once
  a canary proves clean are a v2 optimisation (the queries already return a full
  set; only the advance step is single-shot).

  `max_attempts: 1` on the `:maintenance` queue: a missed tick is harmless (the
  next tick is identical), so a transient blip must never retry-storm.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias BarkparkCloud.Registry

  # How long a triggered instance may take to report `current` before the wave is
  # declared failed and the instance contained. Covers fetch + build-aside
  # rebuild + restart + the settle re-check, with slack.
  @settle_grace_seconds 20 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    settle_in_flight()

    cond do
      # (0) HALT — the fleet-wide kill switch (isu-w5.2). Settle bookkeeping above
      # still ran (in-flight boxes keep resolving so state stays honest), but a
      # halted fleet ADVANCES nothing until an operator resumes.
      Registry.autoupdate_halted?() ->
        Logger.info("autoupdate: fleet halted — settle-only, no advance")
        :ok

      # Re-read AFTER settling: the gate must see the post-settle truth, or a
      # just-cleared instance would wrongly block this tick's advance.
      Registry.autoupdate_in_flight() != [] ->
        :ok

      true ->
        advance()
    end
  end

  # ── (1) settle every in-flight instance against its own live verdict ──────
  defp settle_in_flight do
    Registry.autoupdate_in_flight()
    |> Enum.each(&settle_one/1)
  end

  defp settle_one(bp) do
    # THE RETURN VALUE IS THE DISCRIMINATOR, NOT THE RE-READ (task-a207d875e61a2e02).
    #
    # `refresh_update_status/1` persists the fresh verdict and never raises, and the
    # row is re-read below to branch on the just-written state. But the CONTAINMENT
    # decision cannot be made off that re-read — and this is the same distinction
    # `refuse_unarmed_resume/2` turns on in `web/router.ex`. `{:ok, _}` is emitted by
    # exactly one path (a decoded 200: the box answered and we read its body); every
    # failure rung answers `{:error, reason}` AFTER landing `update_state: "unknown"`.
    # The re-read cannot tell those apart, because both produce a row that is simply
    # not `"current"`.
    measurement = Registry.refresh_update_status(bp)

    case Registry.get_barkpark(bp.id) do
      nil ->
        :ok

      fresh ->
        cond do
          fresh.update_state == "current" ->
            _ = Registry.clear_autoupdate_triggered(fresh)
            Logger.info("autoupdate: #{fresh.slug} settled current — wave OK")

          triggered_expired?(fresh) ->
            settle_expired(fresh, measurement)

          true ->
            # Still within grace and not yet current — keep waiting.
            :ok
        end
    end
  rescue
    e ->
      Logger.error("autoupdate: settle failed for #{inspect(bp.id)}: #{Exception.message(e)}")
      :ok
  end

  # THE GRACE EXPIRED — BUT "DID NOT SETTLE" AND "WE COULD NOT ASK" ARE NOT THE
  # SAME SENTENCE, and this branch used to write the same flag for both.
  #
  # `autoupdate_paused` has NO automatic clear: its only `false` writer anywhere is
  # the human PATCH on `/v1/barkparks/:id/autoupdate`, behind
  # `Auth.require_current_team_admin`. There is a `pause_autoupdate/1` verb and no
  # resume verb at all. So every entry into it has to earn itself, exactly as the
  # 503 branch below now does (#13474 / #13551).
  #
  # And this timer fires on a HEALTHY box more readily than it looks: applying an
  # update RESTARTS the BEAM, so a box is EXPECTED to be unreachable for part of its
  # own settle window. A box that is merely slow — a big rebuild, a loaded ARM host,
  # a restart under an api/** auto-deploy — crosses the grace while the control
  # plane simply could not reach it, and was latched off autoupdate for good on a
  # measurement nobody ever took.
  defp settle_expired(fresh, {:ok, _measured}) do
    # MEASURED. The box answered on its own admin route and its body still does not
    # say `current`: the wave genuinely did not land. This box is ALSO still a
    # candidate (`update_state` is whatever it reported — typically `"behind"`), so
    # `order_by: update_checked_at` would hand it straight back and the rollout would
    # re-trigger it every grace window, forever, while the serial-of-1 gate blocked
    # every other box behind it. That is the wedge, and containment is the honest
    # answer to it — the same "last resort, and only where dropping it would wedge"
    # judgement the 503 branch records below.
    _ = Registry.clear_autoupdate_triggered(fresh)
    _ = Registry.pause_autoupdate(fresh)

    Logger.warning(
      "autoupdate: #{fresh.slug} did not settle within grace (state=#{fresh.update_state}) — " <>
        "the box answered and is still not current, so it is paused for investigation " <>
        "(a human must resume it)"
    )
  end

  defp settle_expired(fresh, {:error, reason}) do
    # NEVER MEASURED, so nothing is latched — the fail-open half of
    # `refuse_unarmed_resume/2`, applied here. We could not reach the box (or could
    # not read what it sent), so we cannot say the update failed, and refusing on a
    # measurement we could not take is what creates an unclearable state.
    #
    # DROPPING THE PAUSE LEAVES NO WEDGE, which is why this needs no replacement
    # flag. Every failure rung of `refresh_update_status/1` has already written
    # `update_state: "unknown"`, and `next_autoupdate_candidate/1` requires
    # `update_state == "behind"` — so this box is ALREADY out of the candidate set
    # without any flag, and it re-enters on its own the moment it answers again and a
    # sweep writes a real verdict back. The pause was pure redundancy here: it bought
    # no containment the row did not already have, and cost a human PATCH to undo.
    #
    # Clearing the in-flight marker is what must still happen: leaving it stamped
    # would hold the serial-of-1 gate shut and freeze the whole fleet's advancement
    # behind one unreachable box.
    _ = Registry.clear_autoupdate_triggered(fresh)

    Logger.warning(
      "autoupdate: #{fresh.slug} did not settle within grace and the control plane could " <>
        "not read it (#{inspect(reason)}) — marker cleared, NOT paused; it is already out " <>
        "of the candidate set on update_state=unknown and re-enters when it answers again"
    )
  end

  defp triggered_expired?(%{autoupdate_triggered_at: nil}), do: false

  defp triggered_expired?(%{autoupdate_triggered_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) > @settle_grace_seconds
  end

  # ── (3) advance: trigger the next eligible instance ───────────────────────
  #
  # CANARY GATE (isu-w5.2): staging-channel boxes advance FIRST. A prod box is
  # eligible only when the staging gate is GREEN — either no staging box is
  # registered (fail-OPEN) or a staging box has settled current on the latest
  # release. A staging box that is behind/in-flight/paused blocks prod.
  #
  # WHAT A 202 MEANS AND WHAT A 409 MEANS ARE NOT THE SAME SENTENCE (cch-w58-s2,
  # CORRECTED IN REVIEW). Only a 202 is a run THIS TICK started. A 409 is the
  # instance's `already_running` and nothing else on this route — the box's own
  # handler answers 202 started / 409 already_running / 503 disabled / 500
  # start_failed (`api/lib/barkpark_web/controllers/self_update_controller.ex`
  # `trigger/2`), and `Registry.trigger_self_update/2` relays that status intact.
  #
  # So a 409 is NOT a refusal. A run IS in flight; it simply is not ours (a human
  # pressing Apply in the Console, or a tick whose 202 we never saw). Three things
  # follow, and the first shipped build of this slice got the last two backwards:
  #
  #   * we do NOT say we triggered it — the log states what actually happened.
  #   * we do NOT pause the box. Pausing a merely-BUSY box would disable
  #     autoupdate on it until an operator resumes, on the strength of a customer
  #     doing exactly what the Console invites them to do.
  #   * we do NOT step past it to another box. Serial-of-1 is this worker's
  #     stated safety property — "every instance is proven live on the new
  #     release before the next is touched" — and triggering a second box while
  #     this one is mid-run would make that sentence unsupportable.
  #
  # The row IS in flight, so it is marked in flight, and the SETTLE path bounds it
  # exactly as it bounds our own runs: settles current → cleared; still not
  # current after the grace → paused for investigation. That containment can lose,
  # and it is the only thing that ever paused a wedged runner.
  defp advance do
    case next_gated_candidate() do
      nil ->
        :ok

      bp ->
        trigger_candidate(bp)
    end
  rescue
    e ->
      Logger.error("autoupdate: advance failed: #{Exception.message(e)}")
      :ok
  end

  defp trigger_candidate(bp) do
    case Registry.trigger_self_update(bp) do
      {:ok, 202, _body} ->
        _ = Registry.mark_autoupdate_triggered(bp)

        Logger.info("autoupdate: triggered #{bp.slug} (HTTP 202) → #{bp.update_latest_release}")

      {:ok, 409, _body} ->
        _ = Registry.mark_autoupdate_triggered(bp)

        Logger.warning(
          "autoupdate: #{bp.slug} already had a run in flight (HTTP 409 already_running) — NOT started by this tick; waiting for it to settle"
        )

      # A 503 IS A MEASUREMENT, NOT A POLICY DECISION (task-0dd7578bc3d2bcbd).
      #
      # The box's handler answers 503 `feature_not_configured` off exactly one
      # input — `Runner.enabled?/0`, the running BEAM's boot-frozen read of
      # BARKPARK_SELF_UPDATE_APPLY. That is the SAME fact the hourly arming probe
      # reads as `apply_enabled`. So the honest response is to write what we just
      # learned into `apply_arming`, which `next_autoupdate_candidate/1` now
      # disqualifies on, and NOT to touch `autoupdate_paused`.
      #
      # WHY THE OLD `pause_autoupdate/1` HERE WAS AN OUTAGE WAITING TO HAPPEN.
      # `autoupdate_paused` has NO automatic clear: its only `false` writer is a
      # human PATCH on `/v1/barkparks/:id/autoupdate`, gated on a team admin.
      # There is a `pause_autoupdate/1` verb and no resume verb at all. So one
      # bless against an unarmed fleet walked every box into this branch — one
      # per 5-minute tick, since this branch never stamps
      # `autoupdate_triggered_at` and the serial-of-1 gate therefore never slowed
      # it — and latched each one off autoupdate until a human went box by box.
      # Recovery was not slow; it was absent.
      #
      # The replacement recovers by itself: the operator arms the box and
      # restarts it, the next `UpdateStatusWorker` sweep reads
      # `apply_enabled: true`, `refresh_update_status/1` writes `"armed"`, and
      # the box re-enters the candidate set. Nobody clears a flag.
      #
      # AND THE PAUSE NO LONGER SURVIVES AS A LAST RESORT EITHER
      # (task-a207d875e61a2e02). It used to: a failed arming write fell back to the
      # old containment, on the reasoning that "a latched box is bad; a rollout that
      # advances nothing is worse". That reasoning weighed ONE latched box against a
      # wedge. It is the wrong weighing, because this branch never stamps
      # `autoupdate_triggered_at` — so under a PERSISTENT write failure the fallback
      # does not latch one box, it latches one box per tick until the fleet is gone,
      # which is the very shape the paragraph above describes as the original bug.
      # The error arm below states why the fallback could not have helped anyway.
      {:ok, 503, _body} ->
        case registry().record_apply_unarmed(bp) do
          {:ok, _} ->
            Logger.warning(
              "autoupdate: #{bp.slug} has no one-click apply (503) — recorded unarmed and " <>
                "skipped (needs BARKPARK_SELF_UPDATE_APPLY=1; re-enters automatically once " <>
                "the hourly sweep reads it armed)"
            )

          # AND THE FALLBACK PAUSE IS GONE TOO (task-a207d875e61a2e02). This arm used
          # to answer a failed arming write with `pause_autoupdate/1`, and it is the
          # one place in this worker where that could still walk the WHOLE fleet: it
          # never stamps `autoupdate_triggered_at`, so the serial-of-1 gate never
          # slowed it — one box latched per 5-minute tick for as long as the write
          # kept failing, which is precisely the shape #13474 removed from the line
          # above.
          #
          # IT ALSO COULD NOT HAVE WORKED. `record_apply_unarmed/1` writes two columns
          # of the `barkparks` row through `Repo.update/1`; `pause_autoupdate/1` writes
          # a third column of the SAME row through the SAME `Repo.update/1`
          # (`set_autoupdate/2`). Any DB-level reason the first write fails — a dead
          # pool, a read-only replica, a lock timeout — fails the second identically.
          # The only failure the fallback could survive is a changeset validation on
          # the arming attrs specifically, and those attrs are two hardcoded valid
          # values. So the branch bought containment in no world it can actually reach,
          # while creating the fleet-walk in every world it can.
          #
          # Nothing replaces it. The box stays a candidate and the rollout retries it
          # next tick, which is correct: a failed arming write is a CONTROL-PLANE fault,
          # and pausing a customer's box to route around our own DB is the same
          # category error as pausing one for answering 503 — a measurement treated as
          # a policy decision.
          {:error, reason} ->
            Logger.error(
              "autoupdate: #{bp.slug} answered 503 and the unarmed record FAILED " <>
                "(#{inspect(reason)}) — NOT paused (a pause writes the same row through " <>
                "the same Repo and would fail too); will retry next tick"
            )
        end

      {:ok, status, _body} ->
        Logger.warning(
          "autoupdate: #{bp.slug} trigger returned HTTP #{status} — will retry next tick"
        )

      {:error, reason} ->
        Logger.warning(
          "autoupdate: #{bp.slug} trigger failed (#{inspect(reason)}) — will retry next tick"
        )
    end
  end

  # The Registry module the 503 branch records arming through. Resolved at call
  # time and swappable ONLY via `Application.get_env(:barkpark_cloud, __MODULE__,
  # [])`, exactly like `Billing.registry/0` (whose docstring states the same
  # intent): real code always gets the real `Registry`, and the `:registry` key
  # exists purely so a test can force `record_apply_unarmed/1` to fail and prove
  # that a persistent arming-write failure pauses NOTHING.
  @spec registry() :: module()
  defp registry do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:registry, Registry)
  end

  # Staging first; prod only behind a green staging gate. A behind staging box is
  # itself the next candidate (advanced ahead of prod); once no staging box is
  # behind, prod may advance IFF the gate reports a settled-current canary (or no
  # staging box exists at all — fail open).
  defp next_gated_candidate do
    case Registry.next_autoupdate_candidate("staging") do
      %{} = staging ->
        staging

      nil ->
        if Registry.staging_gate_open?() do
          Registry.next_autoupdate_candidate("prod")
        else
          Logger.info("autoupdate: staging gate closed — prod advancement blocked")
          nil
        end
    end
  end
end
