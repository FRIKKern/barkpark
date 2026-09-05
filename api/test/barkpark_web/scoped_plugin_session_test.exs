defmodule BarkparkWeb.ScopedPluginSessionTest do
  @moduledoc """
  Task barkpark-uv1t — the scoped BROWSER plugin LiveViews under
  `/w/:ws/p/:project/{studio,admin}` must work for COOKIE-authenticated
  browser users (not just Bearer-header API clients), and must run
  WORKSPACE-SCOPED once past the membership gate.

  Two halves of the fix are pinned here:

    1. `BarkparkWeb.Plugs.OptionalSessionToken` — resolves the token from
       either the Bearer header OR `session["api_token"]`, so the
       `:scoped_browser` pipeline's `ResolveWorkspace` membership gate
       sees a real member's token even when only the session cookie is
       present. A member with cookie-only auth reaches the LV (no 403);
       a non-member still 403s (fail-closed).

    2. `BarkparkWeb.PluginScopeSession` — the `session:` MFA copies the
       resolved workspace/project ids+slugs from conn assigns into the
       LV session at the HTTP→WS boundary; the `:scope` on_mount hook
       reads them back into socket assigns so
       `ScopeHelpers.scope_opts(socket)` returns the real (non-empty)
       scope instead of running unscoped.

  The cookie-only path is the gap the review flagged: the pre-fix
  `OptionalToken` read Bearer ONLY, so a logged-in browser user 403'd
  before mount.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias BarkparkWeb.PluginScopeSession
  alias BarkparkWeb.Plugs.OptionalSessionToken
  alias BarkparkWeb.ScopeHelpers

  @body_marker "OnixEdit plugin route alive."

  setup %{conn: conn} do
    # Default-workspace member with admin perms (clears the LV admin gate).
    raw = "scoped-cookie-member-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(raw, "scoped cookie member", "production", ["read", "write", "admin"])

    # A second workspace this token is NOT a member of (membership-gate target).
    {:ok, other_ws} =
      Tenancy.create_workspace(%{
        slug: "scoped-cookie-other-#{System.unique_integer([:positive])}",
        name: "Other"
      })

    {:ok, other_proj} = Tenancy.create_project(other_ws, %{slug: "other-proj", name: "Other"})

    {:ok, conn: conn, raw_token: raw, other_ws: other_ws, other_proj: other_proj}
  end

  # ── 1. Member cookie reaches the scoped admin LV (was a 403 pre-fix) ──

  describe "cookie-authenticated member reaches scoped plugin LV" do
    test "session cookie alone (NO Bearer) mounts the scoped admin LV", %{
      conn: conn,
      raw_token: raw
    } do
      conn = init_test_session(conn, %{"api_token" => raw})

      assert {:ok, _view, html} =
               live(conn, "/w/default/p/default/studio/onixedit/ping")

      assert html =~ @body_marker
    end

    test "HTTP request (cookie only) resolves the tenant scope into conn assigns", %{
      conn: conn,
      raw_token: raw
    } do
      conn =
        conn
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/default/p/default/studio/onixedit/ping")

      assert html_response(conn, 200) =~ @body_marker
      # OptionalSessionToken → ResolveWorkspace/Project ran off the cookie.
      assert conn.assigns.current_workspace.slug == "default"
      assert conn.assigns.current_project.slug == "default"
    end
  end

  # ── 2. Non-member cookie still 403s (fail-closed) ─────────────────────

  describe "fail-closed: non-member cookie user is rejected" do
    test "cookie member of Default is 403 on a workspace they don't belong to", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws,
      other_proj: other_proj
    } do
      conn =
        conn
        |> init_test_session(%{"api_token" => raw})
        |> get("/w/#{other_ws.slug}/p/#{other_proj.slug}/studio/onixedit/ping")

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "forbidden"
    end

    # P3 (Scoped-by-URL): ResolveWorkspace now runs with
    # `allow_anonymous_default: true` on :scoped_browser, so an anonymous
    # conn passes the WORKSPACE gate for the seeded Default workspace only.
    # The admin plugin LV stays unreachable: the LiveAuth :admin on_mount
    # gate halts and redirects to /studio. Non-Default is still a hard 403.
    test "anonymous cookie (no api_token) never reaches the scoped admin plugin LV", %{
      conn: conn,
      other_ws: other_ws,
      other_proj: other_proj
    } do
      # Default workspace: past the workspace gate, bounced by the admin gate.
      default_conn =
        conn
        |> init_test_session(%{})
        |> get("/w/default/p/default/studio/onixedit/ping")

      assert redirected_to(default_conn) == "/studio"
      refute default_conn.resp_body =~ @body_marker

      # Any NON-Default workspace: the membership gate still fails closed.
      other_conn =
        scoped_conn()
        |> init_test_session(%{})
        |> get("/w/#{other_ws.slug}/p/#{other_proj.slug}/studio/onixedit/ping")

      assert other_conn.status == 403
    end
  end

  # ── 3. OptionalSessionToken resolves from Bearer OR session ───────────

  describe "OptionalSessionToken resolves the api_token" do
    test "from the session cookie when no Bearer header", %{conn: conn, raw_token: raw} do
      out =
        conn
        |> init_test_session(%{"api_token" => raw})
        |> OptionalSessionToken.call([])

      assert out.assigns[:api_token]
      assert out.assigns.api_token.label == "scoped cookie member"
    end

    test "from the Bearer header (precedence) even with a session token", %{
      conn: conn,
      raw_token: raw
    } do
      out =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
        |> init_test_session(%{"api_token" => "ignored-garbage"})
        |> OptionalSessionToken.call([])

      assert out.assigns[:api_token].label == "scoped cookie member"
    end

    test "leaves api_token unassigned for an anonymous conn (never halts)", %{conn: conn} do
      out =
        conn
        |> init_test_session(%{})
        |> OptionalSessionToken.call([])

      refute out.halted
      refute out.assigns[:api_token]
    end
  end

  # ── 4. PluginScopeSession bridges scope across HTTP→WS ────────────────

  describe "PluginScopeSession carries the resolved scope into the socket" do
    test "build/1 copies workspace+project ids+slugs from conn assigns into session" do
      conn = %Plug.Conn{
        assigns: %{
          current_workspace: %{id: "ws-123", slug: "default"},
          current_project: %{id: "proj-456", slug: "default"}
        }
      }

      session = PluginScopeSession.build(conn)

      assert session["scoped_workspace_id"] == "ws-123"
      assert session["scoped_workspace_slug"] == "default"
      assert session["scoped_project_id"] == "proj-456"
      assert session["scoped_project_slug"] == "default"
    end

    test "build/1 returns an empty map when the resolvers didn't set assigns" do
      assert PluginScopeSession.build(%Plug.Conn{assigns: %{}}) == %{}
    end

    test "on_mount(:scope) puts the scope into socket assigns → ScopeHelpers is non-empty" do
      session = %{
        "scoped_workspace_id" => "ws-123",
        "scoped_workspace_slug" => "default",
        "scoped_project_id" => "proj-456",
        "scoped_project_slug" => "default"
      }

      socket = %Phoenix.LiveView.Socket{}
      {:cont, mounted} = PluginScopeSession.on_mount(:scope, %{}, session, socket)

      assert mounted.assigns.current_workspace.id == "ws-123"
      assert mounted.assigns.current_project.id == "proj-456"

      # The whole point: scope_opts now returns the real workspace scope.
      opts = ScopeHelpers.scope_opts(mounted)
      assert opts[:workspace_id] == "ws-123"
      assert opts[:project_id] == "proj-456"
    end

    test "on_mount(:scope) with an empty session leaves scope_opts empty (unscoped)" do
      socket = %Phoenix.LiveView.Socket{}
      {:cont, mounted} = PluginScopeSession.on_mount(:scope, %{}, %{}, socket)

      opts = ScopeHelpers.scope_opts(mounted)

      # No tenancy scope is resolved (the read runs unscoped / global)...
      assert opts[:workspace_id] == nil
      assert opts[:project_id] == nil

      # ...but the caller principal IS always threaded (Phase 4 row/ownership
      # ACL): an empty session is the ANONYMOUS principal, not "no principal".
      # Threading anonymous is what lets `Scope.scope_to_owner/2` restrict an
      # unauthenticated reader to unowned rows instead of bypassing the filter.
      assert opts[:caller_context] == Barkpark.Content.CallerContext.anonymous()
    end
  end

  # ── 5. Two workspaces don't see each other's scope (isolation) ────────

  describe "scope isolation across workspaces" do
    test "the session scope built for workspace A never carries workspace B's id" do
      conn_a = %Plug.Conn{assigns: %{current_workspace: %{id: "ws-A", slug: "a"}}}
      conn_b = %Plug.Conn{assigns: %{current_workspace: %{id: "ws-B", slug: "b"}}}

      assert PluginScopeSession.build(conn_a)["scoped_workspace_id"] == "ws-A"
      assert PluginScopeSession.build(conn_b)["scoped_workspace_id"] == "ws-B"

      socket_a =
        elem(
          PluginScopeSession.on_mount(
            :scope,
            %{},
            PluginScopeSession.build(conn_a),
            %Phoenix.LiveView.Socket{}
          ),
          1
        )

      assert ScopeHelpers.scope_opts(socket_a)[:workspace_id] == "ws-A"
      refute ScopeHelpers.scope_opts(socket_a)[:workspace_id] == "ws-B"
    end
  end
end
