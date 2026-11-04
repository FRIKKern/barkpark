defmodule BarkparkCloud.Web.RouterLatestReleaseCommitTest do
  @moduledoc """
  Decision 0011: `GET /v1/barkparks` serves the latest release tag's commit on
  every row as `latest_release_commit`, so `bp cloud status` and the console can
  read a box that runs the latest release as current while main is ahead.

  async: false because the value comes from the one `:persistent_term` entry
  `GitHub.LatestRelease` keeps per node.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.GitHub.LatestRelease
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @v0239 "e2942e0559e198b706a3bd1ad193f97fd4cae775"

  setup do
    LatestRelease.reset()
    on_exit(&LatestRelease.reset/0)
    :ok
  end

  defp fleet_row do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "gyl-#{n}", slug: "gyl-#{n}"})

    bp
    |> Ecto.Changeset.change(
      git_commit: @v0239,
      update_state: "current",
      commit_distance: 17,
      commit_ancestry: "behind"
    )
    |> Repo.update!()

    {:ok, token} = Accounts.create_user_session_token(user)

    conn =
      conn(:get, "/v1/barkparks")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200
    [row] = Jason.decode!(conn.resp_body)["barkparks"]
    row
  end

  test "the row carries the cached latest release commit" do
    tags = [%{"name" => "v0.2.39", "commit" => %{"sha" => @v0239}}]
    body = Jason.encode!(tags)
    http = fn _req -> {:ok, %{status: 200, body: body, headers: []}} end
    assert {:ok, %{commit: @v0239}} = LatestRelease.fetch(http_client: http)

    row = fleet_row()
    assert row["latest_release_commit"] == @v0239
    assert row["git_commit"] == @v0239
    # The measurement itself is unchanged; the reader decides.
    assert row["commit_ancestry"] == "behind"
    assert row["commit_distance"] == 17
  end

  test "the key is null before the first tags read, never a guess" do
    row = fleet_row()
    assert Map.has_key?(row, "latest_release_commit")
    assert row["latest_release_commit"] == nil
  end
end
