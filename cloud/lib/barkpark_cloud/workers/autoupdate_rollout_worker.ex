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
       `#{div(20 * 60, 60)} min`, the wave failed to land: clear the marker AND
       pause the instance's autoupdate so a bad box is contained, not retried in
       a storm — a human investigates.
    2. GATE — if anything is still in flight after the settle pass, STOP. The
       rollout is serial: never start a new instance while a wave is unsettled.
       This IS the health gate — a slow/failing update blocks advancement.
    3. ADVANCE — otherwise trigger the next eligible `behind` instance
       (`Registry.next_autoupdate_candidate/0`, oldest-stale first) and stamp it
       in-flight. A 202/409 is accepted (it is updating); a 503 means the box
       never armed one-click apply, so we pause it rather than retry forever; any
       other outcome is transient and simply retried next tick.

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
    # refresh_update_status persists the fresh verdict and never raises; re-read
    # the row to branch on the just-written state.
    _ = Registry.refresh_update_status(bp)

    case Registry.get_barkpark(bp.id) do
      nil ->
        :ok

      fresh ->
        cond do
          fresh.update_state == "current" ->
            _ = Registry.clear_autoupdate_triggered(fresh)
            Logger.info("autoupdate: #{fresh.slug} settled current — wave OK")

          triggered_expired?(fresh) ->
            _ = Registry.clear_autoupdate_triggered(fresh)
            _ = Registry.pause_autoupdate(fresh)

            Logger.warning(
              "autoupdate: #{fresh.slug} did not settle within grace (state=#{fresh.update_state}) — paused for investigation"
            )

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
  defp advance do
    case next_gated_candidate() do
      nil ->
        :ok

      bp ->
        case Registry.trigger_self_update(bp) do
          {:ok, status, _body} when status in [202, 409] ->
            _ = Registry.mark_autoupdate_triggered(bp)

            Logger.info(
              "autoupdate: triggered #{bp.slug} (HTTP #{status}) → #{bp.update_latest_release}"
            )

          {:ok, 503, _body} ->
            _ = Registry.pause_autoupdate(bp)

            Logger.warning(
              "autoupdate: #{bp.slug} has no one-click apply (503) — paused (needs BARKPARK_SELF_UPDATE_APPLY=1)"
            )

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
  rescue
    e ->
      Logger.error("autoupdate: advance failed: #{Exception.message(e)}")
      :ok
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
