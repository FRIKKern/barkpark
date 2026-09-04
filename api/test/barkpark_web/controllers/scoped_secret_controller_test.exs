defmodule BarkparkWeb.ScopedSecretControllerTest do
  @moduledoc """
  Contract tests for the scoped per-workspace run-secrets surface
  (`/w/:workspace_slug/p/:project_slug/v1/secrets`, connectors D197/D199).

  The invariants under test:

    * TENANT WALL — a ws-B workspace-admin never sees/mutates ws-A's scoped
      secrets: their own scoped route reads only their tier (opaque 404/empty),
      and ws-A's route 403s them at the membership gate.
    * GLOBAL TIER INVISIBLE — an instance-global secret (flat `/v1/secrets`)
      never appears through a scoped route, and a scoped secret never appears
      through the flat route. Same-name coexistence across tiers holds.
    * FLAT UNCHANGED — the flat route still reads/writes the GLOBAL tier
      (never the Default workspace tier AssignDefaultScope puts in
      `conn.assigns` — the scope seam keys off the ROUTE, not the assign).
    * SCOPED-ADMIN GATE — member (even with global admin perms) → 403,
      non-member → 403, anonymous → 401/403/404.
    * D199 GUARD (forged assigns) — no live HTTP path can deliver a non-UUID
      workspace id (`ResolveWorkspace` always assigns a DB-resolved struct or
      halts), so the guard is exercised at the controller seam directly: a
      forged `current_workspace` with a non-UUID id folds into an opaque 404
      on EVERY verb. On a naive passthrough this raises
      `Ecto.Query.CastError` (a 500) — see `secrets_castgap_contract_test.exs`
      for the context-layer witness.
    * AUDIT — scoped reveal/set/delete stamp the acting workspace on the
      audit row (D195).
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query

  alias Barkpark.{Auth, Repo, Secrets, Tenancy}
  alias Barkpark.Secrets.SecretAudit
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.SecretController

  @dataset "production"

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "sec-scope-a", name: "Sec Scope A"})
    {:ok, _} = Tenancy.create_project(ws_a, %{slug: "default", name: "Default"})

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "sec-scope-b", name: "Sec Scope B"})
    {:ok, _} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # Workspace ADMINS — admin authority on the scoped surface is the
    # membership ROLE (RequireWorkspaceRole), not the token's global perms.
    admin_a_raw = "sec-admin-a-#{System.unique_integer([:positive])}"
    {:ok, tok_a} = Auth.create_token(admin_a_raw, "admin-a", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws_a.id, tok_a.id, "admin")

    admin_b_raw = "sec-admin-b-#{System.unique_integer([:positive])}"
    {:ok, tok_b} = Auth.create_token(admin_b_raw, "admin-b", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws_b.id, tok_b.id, "admin")

    # MEMBER of ws_a holding global admin perms — must NOT pass :scoped_admin.
    member_raw = "sec-member-#{System.unique_integer([:positive])}"

    {:ok, member_tok} =
      Auth.create_token(member_raw, "member", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_a.id, member_tok.id)

    # Instance-global admin — no membership anywhere; drives the FLAT route.
    global_raw = "sec-global-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(global_raw, "global", @dataset, ["read", "write", "admin"])

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      admin_a_raw: admin_a_raw,
      admin_b_raw: admin_b_raw,
      member_raw: member_raw,
      global_raw: global_raw
    }
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp scoped(ws_slug, rest), do: "/w/#{ws_slug}/p/default/v1/secrets#{rest}"

  defp put_scoped(raw, ws_slug, name, value) do
    scoped_conn()
    |> authed(raw)
    |> put(scoped(ws_slug, "/#{name}"), Jason.encode!(%{value: value}))
  end

  describe "own-workspace CRUD (happy path)" do
    test "PUT → GET reveals unmasked → list masked → DELETE → 404", %{admin_a_raw: raw} do
      assert put_scoped(raw, "sec-scope-a", "slack_token", "xoxb-secret-9876").status == 200

      reveal = scoped_conn() |> authed(raw) |> get(scoped("sec-scope-a", "/slack_token"))
      assert reveal.status == 200
      payload = Jason.decode!(reveal.resp_body)
      assert payload["name"] == "slack_token"
      assert payload["value"] == "xoxb-secret-9876"

      list = scoped_conn() |> authed(raw) |> get(scoped("sec-scope-a", ""))
      assert list.status == 200
      row = Jason.decode!(list.resp_body)["secrets"] |> Enum.find(&(&1["name"] == "slack_token"))
      assert row["value"] == "********9876"

      assert scoped_conn()
             |> authed(raw)
             |> delete(scoped("sec-scope-a", "/slack_token"))
             |> Map.get(:status) == 200

      assert scoped_conn()
             |> authed(raw)
             |> get(scoped("sec-scope-a", "/slack_token"))
             |> Map.get(:status) == 404
    end

    test "scoped writes land in the WORKSPACE tier and stamp the audit workspace", %{
      admin_a_raw: raw,
      ws_a: ws_a
    } do
      assert put_scoped(raw, "sec-scope-a", "audit_probe", "v1").status == 200

      # Context-level truth: the row lives in ws_a's tier, not the global one.
      assert Secrets.get("audit_probe", ws_a.id) == "v1"
      assert Secrets.get("audit_probe") == nil

      # D195: the "set" audit row carries the acting workspace.
      audit =
        SecretAudit
        |> where([a], a.name == "audit_probe" and a.action == "set")
        |> Repo.one()

      assert audit.workspace_id == ws_a.id
    end
  end

  describe "the tenant wall (cross-workspace, red-first)" do
    setup %{admin_a_raw: raw_a} do
      assert put_scoped(raw_a, "sec-scope-a", "ws_a_only", "ws-a-value").status == 200
      :ok
    end

    test "ws-B admin's own scoped list never contains ws-A's secret", %{admin_b_raw: raw_b} do
      list = scoped_conn() |> authed(raw_b) |> get(scoped("sec-scope-b", ""))
      assert list.status == 200
      names = Jason.decode!(list.resp_body)["secrets"] |> Enum.map(& &1["name"])
      refute "ws_a_only" in names, "ws-B's scoped list LEAKED ws-A's secret — CROSS-TENANT LEAK"
    end

    test "ws-B admin cannot reveal ws-A's secret through their own scope (opaque 404)", %{
      admin_b_raw: raw_b
    } do
      resp = scoped_conn() |> authed(raw_b) |> get(scoped("sec-scope-b", "/ws_a_only"))
      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "ws-B admin cannot delete ws-A's secret through their own scope", %{
      admin_b_raw: raw_b,
      ws_a: ws_a
    } do
      resp = scoped_conn() |> authed(raw_b) |> delete(scoped("sec-scope-b", "/ws_a_only"))
      assert resp.status == 404
      # ws-A's row is untouched.
      assert Secrets.get("ws_a_only", ws_a.id) == "ws-a-value"
    end

    test "ws-B PUT of the same name writes ws-B's OWN tier — ws-A's row is untouched", %{
      admin_b_raw: raw_b,
      ws_a: ws_a,
      ws_b: ws_b
    } do
      assert put_scoped(raw_b, "sec-scope-b", "ws_a_only", "ws-b-value").status == 200
      assert Secrets.get("ws_a_only", ws_a.id) == "ws-a-value"
      assert Secrets.get("ws_a_only", ws_b.id) == "ws-b-value"
      assert Secrets.get("ws_a_only") == nil
    end

    test "ws-B admin hitting ws-A's route is stopped at the membership gate (403)", %{
      admin_b_raw: raw_b
    } do
      resp = scoped_conn() |> authed(raw_b) |> get(scoped("sec-scope-a", ""))
      assert resp.status == 403
    end
  end

  describe "global tier stays invisible through the scoped route" do
    setup %{global_raw: global_raw} do
      resp =
        scoped_conn()
        |> authed(global_raw)
        |> put("/v1/secrets/instance_cred", Jason.encode!(%{value: "global-value"}))

      assert resp.status == 200
      :ok
    end

    test "scoped list omits the global secret; scoped reveal 404s it", %{admin_a_raw: raw} do
      list = scoped_conn() |> authed(raw) |> get(scoped("sec-scope-a", ""))
      names = Jason.decode!(list.resp_body)["secrets"] |> Enum.map(& &1["name"])
      refute "instance_cred" in names, "scoped list LEAKED an instance-global credential"

      assert scoped_conn()
             |> authed(raw)
             |> get(scoped("sec-scope-a", "/instance_cred"))
             |> Map.get(:status) == 404
    end

    test "a scoped secret never appears through the flat route", %{
      admin_a_raw: raw,
      global_raw: global_raw
    } do
      assert put_scoped(raw, "sec-scope-a", "tenant_cred", "tenant-value").status == 200

      flat_list = scoped_conn() |> authed(global_raw) |> get("/v1/secrets")
      names = Jason.decode!(flat_list.resp_body)["secrets"] |> Enum.map(& &1["name"])
      refute "tenant_cred" in names, "flat list LEAKED a workspace-scoped secret"

      assert scoped_conn()
             |> authed(global_raw)
             |> get("/v1/secrets/tenant_cred")
             |> Map.get(:status) == 404
    end
  end

  describe "flat route unchanged (byte-identical :global behavior)" do
    test "flat PUT lands in the GLOBAL tier — never the Default workspace tier", %{
      global_raw: global_raw
    } do
      # AssignDefaultScope puts the migration-seeded Default workspace into
      # conn.assigns on the FLAT route too — the scope seam must key off the
      # ROUTE (path_params), or this write would land in Default's tier.
      resp =
        scoped_conn()
        |> authed(global_raw)
        |> put("/v1/secrets/flat_probe", Jason.encode!(%{value: "flat-value"}))

      assert resp.status == 200
      assert Secrets.get("flat_probe") == "flat-value"

      case Tenancy.get_default_workspace() do
        nil -> :ok
        default_ws -> assert Secrets.get("flat_probe", default_ws.id) == nil
      end
    end
  end

  describe "scoped-admin gate" do
    test "a member of the workspace (global admin perms) → 403", %{member_raw: raw} do
      assert scoped_conn() |> authed(raw) |> get(scoped("sec-scope-a", "")) |> Map.get(:status) ==
               403
    end

    test "a non-member global admin → 403", %{global_raw: raw} do
      assert scoped_conn() |> authed(raw) |> get(scoped("sec-scope-a", "")) |> Map.get(:status) ==
               403
    end

    test "anonymous → 401/403/404", %{} do
      resp =
        scoped_conn()
        |> put_req_header("content-type", "application/json")
        |> get(scoped("sec-scope-a", ""))

      assert resp.status in [401, 403, 404]
    end
  end

  describe "D199 guard — forged non-UUID workspace id folds into an opaque 404" do
    # No live HTTP path can deliver a non-UUID workspace id (ResolveWorkspace
    # always assigns a DB-resolved struct or halts), so the guard is
    # defense-in-depth exercised at the controller seam: forge the assigns and
    # call the controller directly. On a naive scope passthrough every verb
    # here raises Ecto.Query.CastError (a 500 on the wire) instead of 404.
    defp forged_call(action, params) do
      scoped_conn()
      |> Map.put(:path_params, %{"workspace_slug" => "forged", "project_slug" => "default"})
      |> Map.put(:params, params)
      |> assign(:current_workspace, %Tenancy.Workspace{id: "not-a-uuid", slug: "forged"})
      |> SecretController.call(SecretController.init(action))
    end

    test "index (list) → 404 not_found" do
      conn = forged_call(:index, %{})
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end

    test "show (reveal) → 404 not_found" do
      conn = forged_call(:show, %{"name" => "x"})
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end

    test "update (create/rotate) → 404 not_found" do
      conn = forged_call(:update, %{"name" => "x", "value" => "v"})
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end

    test "delete → 404 not_found" do
      conn = forged_call(:delete, %{"name" => "x"})
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end

    test "a scoped route whose workspace assign is MISSING also fails closed to 404" do
      # path_params say "scoped" but no resolver ran — never fall back to
      # :global (that would leak instance credentials through a scoped URL).
      conn =
        scoped_conn()
        |> Map.put(:path_params, %{"workspace_slug" => "forged", "project_slug" => "default"})
        |> Map.put(:params, %{})
        |> SecretController.call(SecretController.init(:index))

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
    end
  end
end
