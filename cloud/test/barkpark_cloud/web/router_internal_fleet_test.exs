defmodule BarkparkCloud.Web.RouterInternalFleetTest do
  @moduledoc """
  The internal fleet-ops surface behind `bp cloud hetzner instance` —
  GET /v1/internal/barkparks (cross-team list), POST /v1/internal/barkparks
  (adopt), POST /v1/internal/barkparks/:id/deprovision (remove-any, incl. the
  detach mode for stale-host rows). All worker-token gated; a user session
  token must NOT open any of them.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @worker_token "worker-token-test-fixed"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn =
      case token do
        nil -> conn
        t -> put_req_header(conn, "authorization", "Bearer " <> t)
      end

    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /v1/internal/barkparks" do
    test "worker token → every row across ALL teams, with dns_label + job statuses" do
      team_a = team_fixture()
      team_b = team_fixture()

      bp_a = barkpark_fixture(team_a, %{slug: "alpha", url: "https://alpha.barkpark.cloud"})
      {:ok, _} = Registry.upsert_health(bp_a, %{host: "203.0.113.10"})
      {:ok, _} = Registry.enqueue_deprovision_job(Registry.get_barkpark(bp_a.id))

      _bp_b = barkpark_fixture(team_b, %{slug: "beta", url: "https://beta.barkpark.cloud"})

      conn = call(:get, "/v1/internal/barkparks", nil, @worker_token)
      assert conn.status == 200

      rows = json_body(conn)["barkparks"]
      assert length(rows) == 2

      alpha = Enum.find(rows, &(&1["slug"] == "alpha"))
      assert alpha["dns_label"] == "alpha"
      assert alpha["host"] == "203.0.113.10"
      assert alpha["team_id"] == team_a.id
      assert alpha["deprovision_status"] == "pending"
    end

    test "a user session token does NOT open the fleet view" do
      {:ok, user} =
        Accounts.register_user(%{
          email: "u-#{System.unique_integer([:positive])}@example.com",
          password: "correct-horse-battery"
        })

      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/internal/barkparks", nil, token)
      assert conn.status == 401
    end

    test "no token → 401" do
      conn = call(:get, "/v1/internal/barkparks")
      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/barkparks (adopt)" do
    # cch-w34-s2: adoption records an operator's intent, not a measurement —
    # the row lands with health "unknown" until an agent report arrives.
    test "registers a managed row (health unknown), admin token encrypted at rest" do
      team = team_fixture()

      conn =
        call(
          :post,
          "/v1/internal/barkparks",
          %{
            team_id: team.id,
            name: "Guerrilla",
            slug: "guerrilla",
            url: "https://guerrilla.barkpark.cloud",
            host: "203.0.113.30",
            admin_token: "bp_admin_secret"
          },
          @worker_token
        )

      assert conn.status == 201
      body = json_body(conn)["barkpark"]
      assert body["slug"] == "guerrilla"
      assert body["host"] == "203.0.113.30"
      assert body["health_status"] == "unknown"
      assert body["mode"] == "managed"

      bp = Registry.get_barkpark(body["id"])
      # Encrypted at rest, revealable through the same vault as succeed_job.
      refute bp.admin_token_encrypted == "bp_admin_secret"
      assert {:ok, "bp_admin_secret"} = Registry.reveal_admin_token(bp)
    end

    test "missing team_id → 422" do
      conn = call(:post, "/v1/internal/barkparks", %{name: "X", slug: "x"}, @worker_token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "team_id_required"
    end

    test "duplicate url → 422 with details" do
      team = team_fixture()

      _existing =
        barkpark_fixture(team, %{slug: "taken", url: "https://taken.barkpark.cloud"})

      conn =
        call(
          :post,
          "/v1/internal/barkparks",
          %{
            team_id: team.id,
            name: "Taken Again",
            slug: "taken-again",
            url: "https://taken.barkpark.cloud",
            host: "203.0.113.31"
          },
          @worker_token
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/internal/barkparks", %{team_id: "x"})
      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/barkparks/:id/deprovision" do
    test "live row → 202 deprovisioning, a worker job is enqueued, the row stays" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.40"})

      conn = call(:post, "/v1/internal/barkparks/#{bp.id}/deprovision", %{}, @worker_token)

      assert conn.status == 202
      assert json_body(conn)["status"] == "deprovisioning"
      assert Registry.get_barkpark(bp.id) != nil
      assert %{status: "pending"} = Registry.latest_deprovision_status_map([bp.id])[bp.id]
    end

    test "non-live row → 200 removed, the row is gone" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/internal/barkparks/#{bp.id}/deprovision", %{}, @worker_token)

      assert conn.status == 200
      assert json_body(conn)["status"] == "removed"
      assert Registry.get_barkpark(bp.id) == nil
    end

    test "mode detach → 200 removed even for a LIVE row, NO worker job" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.41"})

      conn =
        call(
          :post,
          "/v1/internal/barkparks/#{bp.id}/deprovision",
          %{mode: "detach"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["status"] == "removed"
      assert Registry.get_barkpark(bp.id) == nil
      # detach must NEVER have enqueued a teardown job for the box.
      assert Registry.claim_next_deprovision_job("tok") == nil
    end

    test "unknown id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/barkparks/#{Ecto.UUID.generate()}/deprovision",
          %{},
          @worker_token
        )

      assert conn.status == 404
    end

    test "no token → 401" do
      conn = call(:post, "/v1/internal/barkparks/#{Ecto.UUID.generate()}/deprovision", %{})
      assert conn.status == 401
    end
  end

  # THE TRAIL (task-55fb1f33a217249b). Both arms of this route removed a team's
  # instance row and wrote NOTHING — the console's append-only audit list was
  # silent about every box an operator took out through the internal surface.
  # This route is WORKER-authenticated, so the row carries a nil actor: the
  # documented shape for a system-caused event, never a missing team.
  describe "POST /v1/internal/barkparks/:id/deprovision writes barkpark.deleted" do
    test "the non-live arm lands on the row's own team trail, with a nil actor" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert audit_rows(team) == []

      conn = call(:post, "/v1/internal/barkparks/#{bp.id}/deprovision", %{}, @worker_token)

      assert conn.status == 200
      assert Registry.get_barkpark(bp.id) == nil

      assert [%AuditEvent{} = event] = audit_rows(team)
      assert event.action == "barkpark.deleted"
      assert event.target_type == "barkpark"
      assert event.target_id == bp.id
      assert event.team_id == team.id
      assert is_nil(event.actor_user_id)
      assert event.metadata["lane"] == "internal_deprovision_not_live"
      assert event.metadata["name"] == bp.name
    end

    test "the detach arm lands too — a live row removed with no teardown" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.42"})

      conn =
        call(
          :post,
          "/v1/internal/barkparks/#{bp.id}/deprovision",
          %{mode: "detach"},
          @worker_token
        )

      assert conn.status == 200
      assert Registry.get_barkpark(bp.id) == nil

      assert [%AuditEvent{} = event] = audit_rows(team)
      assert event.action == "barkpark.deleted"
      assert event.metadata["lane"] == "internal_deprovision_detach"
    end

    test "a lane that does NOT delete a row writes no deletion" do
      # The control. Without it, an arm that stamped the verb on every request
      # would read exactly as green as one that stamps it on the delete.
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.43"})

      conn = call(:post, "/v1/internal/barkparks/#{bp.id}/deprovision", %{}, @worker_token)

      assert conn.status == 202
      assert Registry.get_barkpark(bp.id) != nil
      assert audit_rows(team) == []
    end
  end

  defp audit_rows(team) do
    Repo.all(from(e in AuditEvent, where: e.team_id == ^team.id))
  end
end
