defmodule BarkparkCloud.Web.RouterBuildLogUrlReachabilityTest do
  @moduledoc """
  A KEY NAMED `build_log_url` MUST CARRY A URL A READER CAN OPEN, OR NOTHING.

  `internal/builder/builder.go` stamps `build_log_url = "file://" <> buildLogPath`
  — a path on the BUILDER HOST's own filesystem. Nothing uploads that file. The
  control plane cannot open it, the Console cannot link it, a customer cannot
  fetch it. Shipping it under a key whose name says "fetch me" IS the claim of
  retrievability, and every reader that printed it passed the claim on.

  ## What this file pins, and how each arm can LOSE

  Three arms, deliberately pulling in opposite directions, so no single edit
  satisfies all three:

    1. THE LIE IS SUPPRESSED. A row whose column holds `file:///var/lib/…`
       serializes `build_log_url` as nil on every reader surface. Restore the
       passthrough (`build_log_url: d.build_log_url`) and this arm reds.

    2. THE TRUTH SURVIVES. A row whose column holds `https://…` serializes that
       string VERBATIM. Suppress the key unconditionally — the cheap way to make
       arm 1 pass — and this arm reds. Arms 1 and 2 cannot both be satisfied by
       a constant.

    3. THE PRECONDITION IS ASSERTED, NOT ASSUMED. Arm 1's nil is only evidence of
       SUPPRESSION if the column really holds the `file://` string. A fixture
       whose write silently failed would produce the same nil and the same green.
       So the DB row is read back and asserted before the wire is measured.

  Scheme coverage is an ALLOWLIST, not a `file://` denylist: `s3://`, a bare
  absolute path, and a `journal:` pointer are each as unopenable to an HTTP
  client, and a denylist would hand the next builder the same lie. The
  non-http arm below carries one of each.

  ## OUT OF FENCE — deferred, with an owner

  Two in-code justifications cite "the durable log" to explain why a dropped
  console line is survivable:

    * `internal/builder/console.go` — `maxConsoleFails` bail-out message
      ("the lines above are NOT the whole build; the durable build log is …")
      and the comment above it ("names the drop and points at the durable log").

  Those sentences are true of the FILE (it is durable on the builder host) and
  false of the POINTER (nobody off that host can reach it). Repairing them means
  editing `internal/`, which is the CLI lane's fence, not this one. DEFERRED TO
  THE CLI LANE, which owns `internal/builder/` and `internal/cli/sites_cmd.go`'s
  `runSitesLogs` (it prints `log: <url>` bare, with no hint the scheme is
  unopenable). The cloud side of the same finding is what this file guards.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Byte-for-byte the shape `internal/builder/builder.go` stamps: `"file://"`
  # concatenated onto the builder host's own log path.
  @builder_file_url "file:///var/lib/barkpark-builder/logs/3f2a91c4.log"

  # The shape the `Registry.Deployment` moduledoc always DESCRIBED and the
  # builder never produced — a log a reader can actually GET.
  @reachable_url "https://logs.example.com/builds/3f2a91c4.log"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "site-#{n}"})
    site
  end

  defp deployment_fixture(site, url) do
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main", trigger: "manual"})

    d
    |> Ecto.Changeset.change(%{status: "live", build_log_url: url})
    |> Repo.update!()
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Arm 3's precondition, run before every measurement: the column really holds
  # what the fixture asked for. Without this a failed write and a working
  # suppression are the SAME green.
  defp assert_column_holds(deployment, expected) do
    assert Repo.get!(Deployment, deployment.id).build_log_url == expected,
           "PRECONDITION FAILED: the fixture never persisted #{inspect(expected)} — " <>
             "a nil on the wire below would prove nothing about suppression."

    deployment
  end

  setup do
    {user, team} = user_with_team()
    %{token: login_token(user), site: site_fixture(team)}
  end

  describe "an unopenable build_log_url never reaches a reader" do
    # ARM 1 + ARM 3. Reds if `deployment_json/1` goes back to passing the column
    # through.
    test "the builder's file:// stamp serializes as nil", %{token: token, site: site} do
      d = site |> deployment_fixture(@builder_file_url) |> assert_column_holds(@builder_file_url)

      # The per-deployment read.
      one = call("/v1/sites/#{site.id}/deployments/#{d.id}", token)
      assert one.status == 200
      body = json_body(one)["deployment"]

      # The KEY is still emitted — consumers key on its presence — and its VALUE
      # is nil. `refute body["build_log_url"]` would pass on a missing key too,
      # which is a different (and unasserted) contract.
      assert Map.has_key?(body, "build_log_url")
      assert body["build_log_url"] == nil

      # The list read, which is a WIDER audience than the per-deployment one.
      many = call("/v1/sites/#{site.id}/deployments", token)
      assert many.status == 200
      [listed] = json_body(many)["deployments"]
      assert listed["id"] == d.id
      assert listed["build_log_url"] == nil

      # And the whole serialized body carries the path NOWHERE — not under this
      # key, not smuggled into a neighbouring one.
      refute one.resp_body =~ "/var/lib/barkpark-builder"
      refute many.resp_body =~ "/var/lib/barkpark-builder"
    end

    # ARM 1, generalised. An allowlist, not a `file://` denylist.
    test "every other unopenable scheme is suppressed too", %{token: token, site: site} do
      for url <- ["s3://barkpark-builds/3f2a91c4.log", "/var/log/build.log", "journal:u-1234"] do
        d = site |> deployment_fixture(url) |> assert_column_holds(url)

        conn = call("/v1/sites/#{site.id}/deployments/#{d.id}", token)
        assert conn.status == 200

        assert json_body(conn)["deployment"]["build_log_url"] == nil,
               "#{url} reached a reader as though it were fetchable"
      end
    end
  end

  describe "a reachable build_log_url is NOT collateral damage" do
    # ARM 2. Reds if the fix is "suppress the key always" — the cheapest wrong
    # way to green the arm above.
    test "an https:// log URL survives verbatim", %{token: token, site: site} do
      d = site |> deployment_fixture(@reachable_url) |> assert_column_holds(@reachable_url)

      conn = call("/v1/sites/#{site.id}/deployments/#{d.id}", token)
      assert conn.status == 200
      assert json_body(conn)["deployment"]["build_log_url"] == @reachable_url
    end

    test "an http:// log URL survives verbatim", %{token: token, site: site} do
      url = "http://logs.internal/builds/3f2a91c4.log"
      d = site |> deployment_fixture(url) |> assert_column_holds(url)

      conn = call("/v1/sites/#{site.id}/deployments/#{d.id}", token)
      assert conn.status == 200
      assert json_body(conn)["deployment"]["build_log_url"] == url
    end

    # A row that never got a log at all stays nil — so arm 1's nil is not the
    # only way this key can be nil, and nobody reads the suppression as "absent".
    test "a row with no build_log_url is nil, as it always was", %{token: token, site: site} do
      d = site |> deployment_fixture(nil) |> assert_column_holds(nil)

      conn = call("/v1/sites/#{site.id}/deployments/#{d.id}", token)
      assert conn.status == 200
      assert json_body(conn)["deployment"]["build_log_url"] == nil
    end
  end
end
