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
end
