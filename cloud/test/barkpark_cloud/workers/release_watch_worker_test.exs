defmodule BarkparkCloud.Workers.ReleaseWatchWorkerTest do
  @moduledoc """
  The release watch: a GitHub release a box's row does not show yet makes the
  worker re-read that box with `?refresh=1`, inside a 30-minute window. It only
  reads; pause and rollout fields stay as they were.
  """
  # async: false — the GitHub cache is a node-wide :persistent_term entry and
  # the transport is set through Application env.
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.GitHub.LatestRelease
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Workers.ReleaseWatchWorker

  @admin_token "instance-admin-token-plaintext"

  setup do
    LatestRelease.reset()
    prior = Application.get_env(:barkpark_cloud, LatestRelease)

    on_exit(fn ->
      LatestRelease.reset()
      Application.put_env(:barkpark_cloud, LatestRelease, prior)
    end)

    :ok
  end

  defp github(response) do
    Application.put_env(:barkpark_cloud, LatestRelease, http_client: fn _req -> response end)
  end

  defp github_tags(names) do
    github(
      {:ok,
       %{
         status: 200,
         body: Jason.encode!(Enum.map(names, &%{"name" => &1})),
         headers: [{"etag", ~s("e1")}]
       }}
    )
  end

  defp live_box(overrides) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          update_state: "current",
          update_running_release: "0.2.33",
          update_latest_release: "0.2.33",
          update_checked_at: DateTime.utc_now(),
          autoupdate_enabled: true,
          autoupdate_paused: false
        },
        overrides
      )
    )
    |> Repo.update!()
    |> BarkparkCloud.UrlClaimFixtures.claim_url_host!()
  end

  defp check_body(state, latest) do
    Jason.encode!(%{
      state: "idle",
      apply_enabled: true,
      check: %{state: state, running_release: "0.2.33", latest_release: latest}
    })
  end

  defp tick, do: ReleaseWatchWorker.perform(%Oban.Job{})

  test "a box whose row lacks the new release is re-read with ?refresh=1" do
    github_tags(["v0.2.34", "v0.2.33"])
    bp = live_box(%{})

    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 200, body: check_body("behind", "0.2.34")}}
    ])

    assert tick() == :ok

    [req] = StudioLinkFakeHttpClient.requests()
    assert req.method == :get
    assert req.url == bp.url <> "/v1/admin/self-update?refresh=1"

    fresh = Registry.get_barkpark(bp.id)
    assert fresh.update_state == "behind"
    assert fresh.update_latest_release == "0.2.34"
  end

  test "a box that already shows the release is not read" do
    github_tags(["v0.2.34"])
    live_box(%{update_state: "behind", update_latest_release: "0.2.34"})
    StudioLinkFakeHttpClient.program([])

    tick()

    assert StudioLinkFakeHttpClient.requests() == []
  end

  test "a paused box is re-read and stays paused; nothing is triggered" do
    github_tags(["v0.2.34"])
    bp = live_box(%{autoupdate_paused: true})

    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 200, body: check_body("behind", "0.2.34")}}
    ])

    tick()

    assert [%{method: :get}] = StudioLinkFakeHttpClient.requests()
    fresh = Registry.get_barkpark(bp.id)
    assert fresh.autoupdate_paused == true
    assert fresh.autoupdate_triggered_at == nil
  end

  test "a box whose last read failed is left to the hourly sweep" do
    github_tags(["v0.2.34"])

    live_box(%{
      update_state: "unknown",
      update_latest_release: nil,
      update_unavailable_reason: "unreachable"
    })

    StudioLinkFakeHttpClient.program([])

    tick()

    assert StudioLinkFakeHttpClient.requests() == []
  end

  test "after the 30-minute window the watch stops reading boxes" do
    live_box(%{})
    StudioLinkFakeHttpClient.program([])

    :persistent_term.put({LatestRelease, :cache}, %{
      release: "0.2.34",
      etag: ~s("e1"),
      observed_at: DateTime.add(DateTime.utc_now(), -31 * 60, :second)
    })

    github({:ok, %{status: 304, body: "", headers: []}})

    tick()

    assert StudioLinkFakeHttpClient.requests() == []
  end

  test "a GitHub failure reads no box" do
    live_box(%{})
    StudioLinkFakeHttpClient.program([])
    github({:ok, %{status: 403, body: "", headers: []}})

    assert tick() == :ok
    assert StudioLinkFakeHttpClient.requests() == []
  end

  test "unaware?/2 compares versions, not strings" do
    assert ReleaseWatchWorker.unaware?(%{update_latest_release: "0.2.9"}, "0.2.10")
    refute ReleaseWatchWorker.unaware?(%{update_latest_release: "0.2.10"}, "0.2.9")
    refute ReleaseWatchWorker.unaware?(%{update_latest_release: "v0.2.34"}, "0.2.34")

    assert ReleaseWatchWorker.unaware?(
             %{
               update_latest_release: nil,
               update_unavailable_reason: nil,
               update_state: "unknown"
             },
             "0.2.34"
           )

    refute ReleaseWatchWorker.unaware?(
             %{
               update_latest_release: nil,
               update_unavailable_reason: nil,
               update_state: "disabled"
             },
             "0.2.34"
           )
  end
end
