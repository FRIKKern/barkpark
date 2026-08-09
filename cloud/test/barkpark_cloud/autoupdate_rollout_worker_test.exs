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

  test "a 503 (no one-click apply on the box) pauses the instance instead of retrying" do
    bp = live_behind()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: ~s({"error":{}})}}])

    tick()

    fresh = reload(bp)
    assert fresh.autoupdate_paused, "503 → paused"
    refute fresh.autoupdate_triggered_at, "not marked in-flight (it never started)"
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
