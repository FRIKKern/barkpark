defmodule BarkparkCloud.Workers.AutoupdateRolloutWorkerTest do
  @moduledoc """
  isu-w4 — the `AutoupdateRolloutWorker` tick: settle in-flight instances
  against their live verdict, gate (never advance while a wave is unsettled),
  then advance ONE eligible instance. Uses the isu-6 `StudioLinkFakeHttpClient`
  seam — the worker's real HTTP (status refresh GET, trigger POST) is programmed.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Workers.AutoupdateRolloutWorker

  @admin_token "instance-admin-token-plaintext"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A LIVE instance (url+host+admin token) so refresh/trigger actually call the
  # fake transport. `behind` and eligible unless overridden.
  defp live_behind(overrides \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          update_state: "behind",
          update_checked_at: DateTime.utc_now(),
          autoupdate_enabled: true,
          autoupdate_paused: false
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  # The GET /v1/admin/self-update body carrying a `check.state`.
  defp check_body(state) do
    Jason.encode!(%{
      state: "idle",
      check: %{state: state, running_release: "v0.2.24", latest_release: "v0.3.0"}
    })
  end

  # The same body PLUS the `apply_enabled` SIBLING of `check` (#12995) — the key
  # `refresh_update_status/1` mirrors into `apply_arming`.
  defp armed_check_body(state) do
    Jason.encode!(%{
      state: "idle",
      apply_enabled: true,
      check: %{state: state, running_release: "v0.2.24", latest_release: "v0.3.0"}
    })
  end

  defp reload(bp), do: Registry.get_barkpark(bp.id)
  defp tick, do: AutoupdateRolloutWorker.perform(%Oban.Job{})

  test "no eligible candidate → no-op, no HTTP" do
    live_behind(%{update_state: "current"})
    StudioLinkFakeHttpClient.program([])

    assert tick() == :ok
    assert StudioLinkFakeHttpClient.requests() == []
  end

  test "advance: triggers the next behind instance and marks it in-flight" do
    bp = live_behind()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

    tick()

    assert reload(bp).autoupdate_triggered_at, "instance should be marked in-flight"
    [req] = StudioLinkFakeHttpClient.requests()
    assert req.method == :post
    assert req.url =~ "/v1/admin/self-update"
  end

  test "gate: an unsettled in-flight instance blocks advancing another" do
    in_flight = live_behind(%{autoupdate_triggered_at: DateTime.utc_now()})
    candidate = live_behind()

    # settle GET → still behind (not yet current), within grace → stays in-flight.
    StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])

    tick()

    assert reload(in_flight).autoupdate_triggered_at, "still in flight"
    refute reload(candidate).autoupdate_triggered_at, "must NOT advance while a wave is unsettled"
    # exactly one call (the settle GET); no trigger POST this tick.
    assert length(StudioLinkFakeHttpClient.requests()) == 1
  end

  test "settle current → clears the marker, then advances to the next instance" do
    settling = live_behind(%{autoupdate_triggered_at: DateTime.utc_now()})
    next = live_behind(%{update_checked_at: ~U[2026-07-01 00:00:00.000000Z]})

    # (1) settle GET → current (cleared); (2) advance POST → 202.
    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 200, body: check_body("current")}},
      {:ok, %{status: 202, body: ~s({"ok":true})}}
    ])

    tick()

    refute reload(settling).autoupdate_triggered_at, "settled current → cleared"
    assert reload(next).autoupdate_triggered_at, "advanced to the next behind instance"
  end

  test "contain: an in-flight instance past grace that never settled is cleared + paused" do
    stale = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
    bp = live_behind(%{autoupdate_triggered_at: stale})

    StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])

    tick()

    fresh = reload(bp)
    refute fresh.autoupdate_triggered_at, "cleared after grace"
    assert fresh.autoupdate_paused, "contained (paused) for investigation"
  end

  # ── task-a207d875e61a2e02: the settle timer stops latching a box it could not read ──
  #
  # The pin ABOVE is the MEASURED case and it is deliberately unchanged: the box
  # answered on its own admin route (a decoded 200) and its body still did not say
  # `current`, so the wave really did fail to land. That box is ALSO still a
  # candidate, so dropping its containment would let the rollout re-trigger it every
  # grace window forever while the serial-of-1 gate blocked every box behind it.
  # Containment stays exactly there — these cases prove the fix DISCRIMINATES rather
  # than dropping the pause wholesale.
  test "past grace but UNREACHABLE: the marker is cleared and the box is NOT paused" do
    stale = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
    bp = live_behind(%{autoupdate_triggered_at: stale})

    # The settle GET never lands. `refresh_update_status/1` takes its `{:error,
    # :unreachable}` rung, writes `update_state: "unknown"`, and returns an error —
    # so nothing here is evidence that the UPDATE failed. Applying an update restarts
    # the BEAM, so a box is EXPECTED to be unreachable across part of its own settle
    # window: this is the healthy-box shape, not the broken-box one.
    StudioLinkFakeHttpClient.program([{:error, :nxdomain}])

    tick()

    fresh = reload(bp)

    refute fresh.autoupdate_triggered_at,
           "the marker MUST still be cleared — leaving it stamped holds the " <>
             "serial-of-1 gate shut and freezes the whole fleet behind one unreachable box"

    refute fresh.autoupdate_paused,
           "a measurement we could not take must never write the flag whose only " <>
             "`false` writer is a human PATCH"

    assert fresh.update_state == "unknown",
           "the failure IS recorded — by refresh_update_status/1, in a column a " <>
             "later automatic pass re-measures"
  end

  test "the unreachable box re-enters the rollout by itself, with no human write" do
    # THE NO-WEDGE CONTROL, and the reason the dropped pause needs no replacement
    # flag. `next_autoupdate_candidate/1` requires `update_state == "behind"`, so an
    # unreachable box is ALREADY out of the candidate set on "unknown" — and it comes
    # back the moment it answers again. Nobody clears anything.
    stale = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
    bp = live_behind(%{autoupdate_triggered_at: stale})

    StudioLinkFakeHttpClient.program([{:error, :nxdomain}])
    tick()

    refute Registry.next_autoupdate_candidate(),
           "while unreadable it is not a candidate — containment without a flag"

    # The box comes back and answers honestly: still behind, so still work to do.
    StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
    {:ok, _} = Registry.refresh_update_status(reload(bp))

    assert %{id: id} = Registry.next_autoupdate_candidate()
    assert id == bp.id, "eligible again with no human in the loop"
  end

  test "a settle-latched box is DISTINGUISHABLE from one latched for being unarmed" do
    # Criterion 3. The two machine-observed conditions must not collapse into one
    # row shape, or an operator resuming a settle-latched box gets 409'd with advice
    # about arming a box that is already armed.
    stale = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
    settled_late = live_behind(%{autoupdate_triggered_at: stale})

    # ARMED, and still behind after the grace → a measured failure to land.
    StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: armed_check_body("behind")}}])
    tick()

    latched = reload(settled_late)
    assert latched.autoupdate_paused, "measured failure → contained"

    assert latched.apply_arming == "armed",
           "and it is on record as ARMED — so refuse_unarmed_resume/2 lets the " <>
             "operator resume it, rather than 409'ing with an irrelevant remedy"

    # The 503 box is the other condition: unarmed, and NOT paused.
    unarmed = live_behind()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: ~s({"error":{}})}}])
    tick()

    other = reload(unarmed)
    assert other.apply_arming == "unarmed"
    refute other.autoupdate_paused

    refute {latched.autoupdate_paused, latched.apply_arming} ==
             {other.autoupdate_paused, other.apply_arming},
           "the two causes leave different rows"
  end

  # ── task-0dd7578bc3d2bcbd: a 503 records, it does not latch ────────────────
  #
  # THESE REPLACE the pin that asserted `503 → autoupdate_paused`. That pin was
  # a correct reading of the code and a wrong specification: `autoupdate_paused`
  # has no automatic clear (its sole `false` writer is a human PATCH on
  # `/v1/barkparks/:id/autoupdate`, and there is no `resume_autoupdate/1` verb at
  # all), so the branch it pinned turned a box-side config gap into a permanent,
  # human-gated outage — and, because the branch never stamps
  # `autoupdate_triggered_at`, the serial-of-1 gate never slowed it: one box
  # latched per 5-minute tick until the whole fleet was off autoupdate.
  test "a 503 records the box unarmed and does NOT latch it off autoupdate" do
    bp = live_behind()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: ~s({"error":{}})}}])

    tick()

    fresh = reload(bp)

    assert fresh.apply_arming == "unarmed",
           "the 503 IS a reading of the box's Runner.enabled?/0 — record it"

    assert fresh.apply_arming_checked_at,
           "the measurement carries its own clock, like the GET-side probe"

    refute fresh.autoupdate_paused,
           "a machine-observed 503 must never write a flag that only a human PATCH clears"

    refute fresh.autoupdate_triggered_at, "not marked in-flight (it never started)"
  end

  test "the 503'd box is skipped next tick instead of being re-picked forever" do
    # THE WEDGE CONTROL. Dropping the pause WITHOUT the candidate-query
    # disqualification would leave this box eligible, and `order_by:
    # update_checked_at` would hand it back every tick while `other` — younger,
    # therefore always second in the order — never advanced.
    unarmed = live_behind(%{update_checked_at: ~U[2026-07-01 00:00:00.000000Z]})
    other = live_behind()

    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 503, body: ~s({"error":{}})}},
      {:ok, %{status: 202, body: ~s({"ok":true})}}
    ])

    tick()
    tick()

    refute reload(unarmed).autoupdate_triggered_at, "the unarmed box is never triggered"

    assert reload(other).autoupdate_triggered_at,
           "the rollout advanced past it — a skip, not a wedge"
  end

  test "an armed box recovers with no human write once the sweep re-measures it" do
    # THE RECOVERY PROOF, and the property the old pause could not have: entry
    # into the skipped set is automatic AND so is the exit. Nothing here calls a
    # resume verb, PATCHes a policy column, or touches autoupdate_paused.
    bp = live_behind()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: ~s({"error":{}})}}])
    tick()

    assert reload(bp).apply_arming == "unarmed"
    refute Registry.next_autoupdate_candidate(), "skipped while unarmed"

    # The operator arms the box and restarts it; the hourly UpdateStatusWorker
    # sweep reads `apply_enabled: true` off its admin route.
    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 200, body: armed_check_body("behind")}}
    ])

    {:ok, _} = Registry.refresh_update_status(reload(bp))

    assert reload(bp).apply_arming == "armed"

    assert %{id: id} = Registry.next_autoupdate_candidate()
    assert id == bp.id, "re-entered the candidate set with nobody clearing a flag"
  end

  test "an UNMEASURED box (nil arming) stays eligible — nil is not unarmed" do
    # SQL's `!=` is NULL, not true, on a NULL column, so a disqualification
    # written as `apply_arming != "unarmed"` alone would exclude every box no
    # sweep has read yet — i.e. the entire pre-#12995 fleet. This is that guard.
    bp = live_behind()
    assert is_nil(bp.apply_arming), "fixture is unmeasured"

    assert %{id: id} = Registry.next_autoupdate_candidate()
    assert id == bp.id
  end

  describe "unarmed_autoupdate_boxes/0 — the pre-bless readiness read" do
    test "names measured-unarmed boxes and excludes unmeasured ones" do
      unarmed = live_behind(%{apply_arming: "unarmed"})
      _armed = live_behind(%{apply_arming: "armed"})
      _unmeasured = live_behind()

      assert [%{id: id}] = Registry.unarmed_autoupdate_boxes()

      assert id == unarmed.id,
             "an unmeasured box may well be armed — padding the list makes it unactionable"
    end

    test "an ALREADY-PAUSED unarmed box is on the list, not filtered off it" do
      # The worst case, not an excluded one: it needs the arming AND the human
      # resume, so a pre-bless reader must see it.
      latched = live_behind(%{apply_arming: "unarmed", autoupdate_paused: true})

      assert [%{id: id}] = Registry.unarmed_autoupdate_boxes()
      assert id == latched.id
    end
  end

  # ── cch-w58-s2: a 409 is `already_running`, not a refusal ─────────────────
  #
  # The instance's own handler answers 409 for exactly one reason —
  # `already_running` (api/…/self_update_controller.ex `trigger/2`) — and the
  # relay carries the status intact. So a 409 says a run is in flight that this
  # tick did not start. These two tests pin the two ways that can be told wrong:
  # announcing it as ours, and punishing the box for being busy.
  #
  # HONEST ABOUT WHAT THESE ARE: regression PINS, not mutation proofs. They pass
  # on origin/main too, because main's behaviour on a 409 was already right — it
  # was main's LOG LINE ("triggered <slug> (HTTP 409)") that claimed a trigger
  # this plane never performed, and that is what the slice actually corrects.
  # They exist so the first build's reading of a 409 (pause the box, step past it
  # to another) cannot come back without reddening something.
  test "a 409 (a run already in flight) does not pause a box for being busy" do
    bp = live_behind()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 409, body: ~s({"error":{}})}}])

    tick()

    fresh = reload(bp)

    refute fresh.autoupdate_paused,
           "a box that is merely mid-update must not have autoupdate disabled — a human " <>
             "pressing Apply in the Console is exactly what produces this 409"

    assert fresh.autoupdate_triggered_at,
           "a run IS in flight, so the row is in-flight and the settle grace bounds it"
  end

  test "a box that is already updating does not let a SECOND box be triggered in the same tick" do
    # Oldest-stale first: the already-running box is the head candidate.
    busy = live_behind(%{update_checked_at: ~U[2026-07-01 00:00:00.000000Z]})
    other = live_behind()

    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 409, body: ~s({"error":{}})}},
      {:ok, %{status: 202, body: ~s({"ok":true})}}
    ])

    tick()

    assert reload(busy).autoupdate_triggered_at, "the in-flight run is tracked"

    refute reload(other).autoupdate_triggered_at,
           "serial-of-1 is this worker's stated safety property: no second box is touched " <>
             "while one is mid-run"

    assert length(StudioLinkFakeHttpClient.requests()) == 1,
           "exactly one trigger left the plane this tick"
  end

  # ── isu-w5.2: fleet kill switch ───────────────────────────────────────────
  test "halt blocks advance but settle bookkeeping still runs" do
    in_flight = live_behind(%{autoupdate_triggered_at: DateTime.utc_now()})
    candidate = live_behind()
    {:ok, _} = Registry.set_autoupdate_halted(true)

    # settle GET → current (clears the in-flight marker); NO advance POST fires.
    StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("current")}}])

    tick()

    refute reload(in_flight).autoupdate_triggered_at, "settle still cleared the in-flight box"
    refute reload(candidate).autoupdate_triggered_at, "halt blocks advancing a new box"
    # exactly one call (the settle GET), never a trigger POST while halted.
    assert length(StudioLinkFakeHttpClient.requests()) == 1
  end

  # ── isu-w5.2: canary staging gate ─────────────────────────────────────────
  test "staging gate fails OPEN: prod advances when no staging box exists" do
    prod = live_behind(%{channel: "prod"})
    StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

    tick()

    assert reload(prod).autoupdate_triggered_at, "prod advances with no staging box (fail-open)"
  end

  test "a staging box advances BEFORE any prod box" do
    staging = live_behind(%{channel: "staging"})
    prod = live_behind(%{channel: "prod"})
    StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

    tick()

    assert reload(staging).autoupdate_triggered_at, "staging box advances first"
    refute reload(prod).autoupdate_triggered_at, "prod waits behind the canary"
  end

  test "a non-current staging box BLOCKS prod advancement" do
    # A paused (behind) staging box is not an eligible candidate itself, and it is
    # not current-on-latest, so the gate stays closed — prod must not advance.
    _blocking_staging = live_behind(%{channel: "staging", autoupdate_paused: true})
    prod = live_behind(%{channel: "prod"})
    StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

    tick()

    refute reload(prod).autoupdate_triggered_at, "staging gate closed → prod blocked"
    assert StudioLinkFakeHttpClient.requests() == [], "no trigger fired at all"
  end

  test "prod advances once the staging canary is current on the latest release" do
    _canary =
      live_behind(%{
        channel: "staging",
        update_state: "current",
        update_running_release: "v0.3.0",
        update_latest_release: "v0.3.0"
      })

    prod = live_behind(%{channel: "prod"})
    StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

    tick()

    assert reload(prod).autoupdate_triggered_at, "green canary opens the prod gate"
  end
end
