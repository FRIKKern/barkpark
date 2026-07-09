defmodule BarkparkWeb.Studio.StudioRouteGrammarTest do
  @moduledoc """
  URL-equals-state, layer 2 (bp-studio-deep-link wave 1, slice `sdl-w1-gate`).

  The route-grammar suite. For every wave-1 Studio destination it pins the
  three invariants the epic ratifies:

    1. **Canonical mounts** — each canonical live route (scoped studio,
       scoped media, scoped api-tester, admin settings, dataset `_plugins`)
       mounts and renders. One true address per destination.

    2. **Aliases 302 to canonical** — every flat/legacy spelling of a
       destination redirects (302, never 301 — the target is
       session-dependent) to its ONE canonical URL, path + query preserved:
         · bare `/` and `/studio`            → session-resolved scoped Studio
         · `/studio/:dataset[/*path]`        → scoped canonical (flat funnel)
         · `/w/:ws/p/:proj/studio/:dataset`  → `/d/` canonical (legacy scoped)

    3. **Deep-link reproduces clicking** — a FRESH `live/2` of a canonical
       deep URL yields the SAME scope assigns (workspace / project / dataset /
       nav_path / nav_desk / scope_prefix) as arriving at that URL via
       `push_patch` from the Studio root. If these diverge, a shared link
       lands you in a different context than clicking there — the whole point
       of the sweep. This extends the `scoped_studio_mount_test.exs:202-224`
       idiom into an explicit URL==state equality (kept here, not in the old
       file, per the slice brief).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("grammar-ws")
    proj = create_project!(ws, "grammar-proj")

    # A member token (read+write) → can mount the scoped surfaces.
    raw = "grammar-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "grammar-member",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    member_conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    # An admin token → mounts the admin-gated surfaces (settings, _plugins).
    # It gets a membership in the fixture workspace: the scoped settings route
    # runs LiveScope (URL-workspace membership gate), and the flat→scoped admin
    # 302s resolve their target from this membership.
    admin_raw = "grammar-admin-#{System.unique_integer([:positive])}"

    {:ok, admin_token} =
      Auth.create_token(admin_raw, "grammar admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, admin_token.id, "owner")
    admin_conn = Plug.Test.init_test_session(conn, %{"api_token" => admin_raw})

    {:ok, conn: conn, member_conn: member_conn, admin_conn: admin_conn, ws: ws, proj: proj}
  end

  defp scoped_root(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  # ── (1) Canonical live routes mount ───────────────────────────────────────
  describe "canonical destinations mount" do
    test "scoped Studio root", %{member_conn: conn, ws: ws, proj: proj} do
      {:ok, _view, html} = live(conn, scoped_root(ws, proj))
      assert html =~ "pane-layout"
    end

    test "scoped Media", %{member_conn: conn, ws: ws, proj: proj} do
      {:ok, view, html} = live(conn, scoped_root(ws, proj) <> "/media")
      assert Process.alive?(view.pid)
      assert is_binary(html)
    end

    test "scoped API tester", %{member_conn: conn, ws: ws, proj: proj} do
      {:ok, view, html} = live(conn, scoped_root(ws, proj) <> "/api-tester")
      assert Process.alive?(view.pid)
      assert is_binary(html)
    end

    test "admin Settings (scoped canonical, dataset-less)", %{
      admin_conn: conn,
      ws: ws,
      proj: proj
    } do
      {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/settings")
      assert html =~ "Workspace Settings"
    end

    test "dataset _plugins admin LV (scoped canonical)", %{admin_conn: conn, ws: ws, proj: proj} do
      {:ok, view, html} = live(conn, scoped_root(ws, proj) <> "/_plugins")
      assert Process.alive?(view.pid)
      assert is_binary(html)
    end
  end

  # ── (2) Every alias 302s to its canonical ─────────────────────────────────
  describe "flat + legacy aliases 302 to canonical" do
    test "bare / and /studio 302 to the session-resolved scoped Studio", %{conn: conn} do
      ensure_default_scope!()

      for path <- ["/", "/studio"] do
        redirected = get(conn, path)
        assert redirected_to(redirected, 302) =~ ~r{^/w/[^/]+/p/[^/]+/d/[^/]+/studio}
      end
    end

    test "flat /studio/:dataset 302s to scoped canonical, path + query preserved", %{conn: conn} do
      {ws, proj} = ensure_default_scope!()

      redirected = get(conn, "/studio/#{@dataset}/post/p1?desk=drafts")

      assert redirected_to(redirected, 302) ==
               "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/post/p1?desk=drafts"
    end

    test "flat /studio/:dataset root 302s to the scoped canonical root", %{conn: conn} do
      {ws, proj} = ensure_default_scope!()

      redirected = get(conn, "/studio/#{@dataset}")

      assert redirected_to(redirected, 302) ==
               "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    end

    test "legacy scoped /w/:ws/p/:proj/studio/:dataset 302s to the /d/ canonical (pure rewrite)",
         %{conn: conn, ws: ws, proj: proj} do
      # No session resolution — every segment is already in the URL. A plain
      # (non-member) conn is enough: the :browser pipeline redirects; the
      # canonical route authorizes on arrival.
      redirected = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/#{@dataset}")

      assert redirected_to(redirected, 302) ==
               "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    end

    test "legacy scoped form preserves the trailing path + query", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      redirected =
        get(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/#{@dataset}/post/p1?desk=drafts")

      assert redirected_to(redirected, 302) ==
               "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/post/p1?desk=drafts"
    end

    # The two admin 302s carry a Referer from the fixture workspace's scoped
    # surface: ScopeResolver prefers a membership-verified Referer scope, so
    # the target is deterministic (the token also auto-binds a Default
    # membership, which would otherwise win the slug-ordered fallback).
    test "flat /studio/settings 302s to the Referer-resolved scoped canonical", %{
      admin_conn: conn,
      ws: ws,
      proj: proj
    } do
      redirected =
        conn
        |> put_req_header("referer", scoped_root(ws, proj))
        |> get("/studio/settings")

      assert redirected_to(redirected, 302) == "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"
    end

    test "flat /studio/:dataset/_plugins 302s to the scoped canonical, tail preserved", %{
      admin_conn: conn,
      ws: ws,
      proj: proj
    } do
      referred = put_req_header(conn, "referer", scoped_root(ws, proj))

      redirected = get(referred, "/studio/#{@dataset}/_plugins")
      assert redirected_to(redirected, 302) == scoped_root(ws, proj) <> "/_plugins"

      redirected = get(referred, "/studio/#{@dataset}/_plugins/onixedit/settings")

      assert redirected_to(redirected, 302) ==
               scoped_root(ws, proj) <> "/_plugins/onixedit/settings"
    end

    test "all Studio redirects are 302, never a cacheable 301", %{conn: conn, ws: ws, proj: proj} do
      ensure_default_scope!()

      conns = [
        get(conn, "/studio"),
        get(conn, "/studio/#{@dataset}"),
        get(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/#{@dataset}")
      ]

      for c <- conns, do: assert(c.status == 302)
    end
  end

  # ── (3) Deep-link reproduces clicking ─────────────────────────────────────
  describe "URL == state: deep-linking reproduces clicking your way there" do
    # The scope tuple a shared link must reproduce exactly.
    defp scope_tuple(view) do
      a = :sys.get_state(view.pid).socket.assigns

      %{
        workspace_id: a[:current_workspace] && a.current_workspace.id,
        project_id: a[:current_project] && a.current_project.id,
        dataset: a[:dataset],
        nav_path: a[:nav_path],
        nav_desk: a[:nav_desk],
        scope_prefix: a[:scope_prefix]
      }
    end

    test "a fresh mount of a deep URL yields the same scope as push_patch there", %{
      member_conn: conn,
      ws: ws,
      proj: proj
    } do
      deep = scoped_root(ws, proj) <> "/post/p1?desk=drafts"

      # (a) Click your way there: mount the root, then push_patch to the deep URL.
      {:ok, clicked, _html} = live(conn, scoped_root(ws, proj))
      render_patch(clicked, deep)
      clicked_scope = scope_tuple(clicked)

      # (b) Deep-link there: a cold mount of the same URL.
      {:ok, linked, _html} = live(conn, deep)
      linked_scope = scope_tuple(linked)

      assert clicked_scope == linked_scope,
             "URL != state: deep-linking #{deep} produced #{inspect(linked_scope)} " <>
               "but clicking there produced #{inspect(clicked_scope)}"

      # And the reproduced scope is the one the URL literally encodes.
      assert linked_scope.dataset == @dataset
      assert linked_scope.nav_path == ["post", "p1"]
      assert linked_scope.nav_desk == "drafts"
      assert linked_scope.scope_prefix == "/w/#{ws.slug}/p/#{proj.slug}"
      assert linked_scope.workspace_id == ws.id
      assert linked_scope.project_id == proj.id
    end

    test "the root canonical URL reproduces the root scope on both paths", %{
      member_conn: conn,
      ws: ws,
      proj: proj
    } do
      root = scoped_root(ws, proj)

      {:ok, clicked, _html} = live(conn, scoped_root(ws, proj) <> "/post/p1")
      render_patch(clicked, root)

      {:ok, linked, _html} = live(conn, root)

      assert scope_tuple(clicked) == scope_tuple(linked)
      assert scope_tuple(linked).nav_path == []
      assert scope_tuple(linked).nav_desk == nil
    end
  end
end
