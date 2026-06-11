defmodule BarkparkWeb.Studio.ScopedStudioMountTest do
  @moduledoc """
  P1 of the Scoped-by-URL arc (tsk-url-p1) — the scoped Studio mount.

  The canonical Studio address is `/w/:ws/p/:proj/d/:dataset/studio/...`;
  LiveScope resolves + authorizes the scope from URL params at mount AND
  on every scope-changing live patch (the conn resolvers only gate the
  dead render — plugs never run for live navigation).

  Matrix under test:
    * member token → mounts and renders (kills the live-verified 404)
    * non-member token → 403 at the dead render (ResolveWorkspace)
    * anonymous → 403 at the dead render (fail-closed; the
      anonymous-Default allowance is deliberately P3)
    * ADVERSARIAL (the judges' gate): a live patch from an authorized
      scope to a foreign workspace's URL inside the same live_session is
      re-authorized by the LiveScope handle_params hook and DENIED —
      the cross-tenant seam conn plugs cannot see.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("scoped-studio-a")
    proj_a = create_project!(ws_a, "scoped-pa")
    ws_b = create_workspace!("scoped-studio-b")
    proj_b = create_project!(ws_b, "scoped-pb")

    # A raw token we control, member of A ONLY.
    raw = "scoped-studio-test-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "scoped-studio-member-a",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "member")

    member_conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn, member_conn: member_conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  defp scoped_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  describe "scoped Studio mount" do
    test "member renders Studio at the canonical scoped URL", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} = live(conn, scoped_url(ws_a, proj_a))
      assert html =~ "pane-layout"
    end

    test "the resolved scope comes from the URL, not session heuristics", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, view, _html} = live(conn, scoped_url(ws_a, proj_a))
      # The workspace switcher renders with the URL's workspace selected.
      assert render(view) =~ ws_a.name
    end

    test "non-member token 403s at the dead render", %{
      member_conn: conn,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      conn = get(conn, scoped_url(ws_b, proj_b))
      assert conn.status == 403
    end

    test "anonymous 403s on any NON-Default workspace (the allowance is Default-only)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      conn = get(conn, scoped_url(ws_a, proj_a))
      assert conn.status == 403
    end

    test "unknown workspace slug 404s (no existence leak past resolve)", %{
      member_conn: conn
    } do
      conn = get(conn, "/w/no-such-ws/p/default/d/#{@dataset}/studio")
      assert conn.status == 404
    end
  end

  describe "ADVERSARIAL: live patch across the tenant boundary" do
    test "a patch to a foreign workspace's URL is re-authorized and denied", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, view, _html} = live(conn, scoped_url(ws_a, proj_a))

      # Same live_session, so this is LIVE navigation: no conn plugs run.
      # Only the LiveScope handle_params hook stands between this socket
      # (member of A) and workspace B's data.
      assert_redirect_to_login(fn ->
        render_patch(view, scoped_url(ws_b, proj_b))
      end)
    end

    test "a patch to another project in the SAME workspace re-resolves and renders", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      proj_a2 = create_project!(ws_a, "scoped-pa2")
      {:ok, view, _html} = live(conn, scoped_url(ws_a, proj_a))

      html = render_patch(view, scoped_url(ws_a, proj_a2))
      assert html =~ "pane-layout"
    end
  end

  describe "P3: the flat→scoped cutover" do
    test "flat /studio/:dataset 302s to the scoped canonical, path+query preserved", %{
      conn: conn
    } do
      {ws, proj} = ensure_default_scope!()

      conn = get(conn, "/studio/#{@dataset}/post/p1?desk=drafts")

      assert redirected_to(conn, 302) ==
               "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/post/p1?desk=drafts"
    end

    test "bare / and /studio 302 to the session-resolved scoped Studio", %{conn: conn} do
      ensure_default_scope!()

      for path <- ["/", "/studio"] do
        conn = get(conn, path)
        assert redirected_to(conn, 302) =~ ~r{^/w/[^/]+/p/[^/]+/d/[^/]+/studio}
      end
    end

    test "a member's flat bookmark resolves to THEIR first workspace, not Default", %{
      member_conn: conn,
      ws_a: ws_a
    } do
      ensure_default_scope!()
      conn = get(conn, "/studio/#{@dataset}")
      # ws_a slug ("scoped-studio-a...") sorts before "default"? Resolution is
      # first slug-ordered MEMBERSHIP workspace — the member only belongs to
      # A (and B in the P2 block's setup, not here), never Default.
      assert redirected_to(conn, 302) =~ "/w/#{ws_a.slug}/p/"
    end

    test "ANONYMOUS mounts the Default scoped Studio (the allowance — prod demo posture)",
         %{conn: conn} do
      {ws, proj} = ensure_default_scope!()
      {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
      assert html =~ "pane-layout"
    end

    test "legacy onixedit book deep link 302s SINGLE-HOP to the scoped editor", %{conn: conn} do
      {ws, proj} = ensure_default_scope!()
      conn = get(conn, "/studio/#{@dataset}/onixedit/book/bk1?tab=meta")

      assert redirected_to(conn, 302) ==
               "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/book/bk1?tab=meta"
    end
  end

  describe "P2: switches and links are URL-real on the scoped surface" do
    setup %{member_conn: _conn, ws_b: ws_b} do
      # The member token (member of A) gains B too, so a workspace switch
      # is authorized and must materialize as a URL change.
      token =
        Barkpark.Repo.get_by!(Barkpark.Auth.ApiToken, label: "scoped-studio-member-a")

      {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, token.id, "member")
      :ok
    end

    test "workspace switch CHANGES THE URL; reload reproduces the location", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {:ok, view, _html} = live(conn, scoped_url(ws_a, proj_a))

      # The scope menu replaced the bar's inline selects — fire the event
      # directly (StudioLive's switch-workspace semantics are unchanged).
      render_change(view, "switch-workspace", %{"workspace" => ws_b.slug})

      # The switch is a push_patch to the NEW workspace's canonical URL —
      # no more socket-state-only switching (reload amnesia).
      patched = assert_patch(view)
      assert patched =~ "/w/#{ws_b.slug}/p/"

      # The kill shot: a FRESH mount of the patched URL reproduces the
      # switched-to location exactly. Before this arc, reload forgot the
      # workspace and snapped back to a session heuristic.
      {:ok, _view2, html2} = live(conn, patched)
      assert html2 =~ ws_b.name
    end

    test "top-nav tabs address the scoped surface", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, _view, html} = live(conn, scoped_url(ws_a, proj_a))

      prefix = "/w/#{ws_a.slug}/p/#{proj_a.slug}"
      assert html =~ ~s{href="#{prefix}/d/#{@dataset}/studio/media"}
      assert html =~ ~s{href="#{prefix}/d/#{@dataset}/studio/api-tester"}
    end

    test "desk navigation patches stay under the scope prefix", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, view, _html} = live(conn, scoped_url(ws_a, proj_a))

      # Any structural pane select must produce a scoped URL.
      html = render(view)

      if html =~ ~s{phx-click="select"} do
        view
        |> element(~s{[phx-click="select"][phx-value-pane="0"]:first-of-type})
        |> render_click()

        assert assert_patch(view) =~ "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/"
      end
    end
  end

  describe "plugin-link hrefs are /d/-canonical on the scoped surface" do
    # Structure emits :plugin_link hrefs in the legacy FLAT shape
    # ("/studio/<ds>/media" — it has no scope knowledge); StudioLive's
    # scoped_plugin_href/2 rewrites them at render time so clicks stay in
    # the CURRENT workspace instead of riding the flat→scoped 302 funnel
    # (which re-resolves the workspace from the session and can teleport
    # the user). The flat _plugins admin LV keeps flat hrefs.
    setup do
      # Both media schemas → the "Media Library" :plugin_link nests inside
      # the "media-desk" group (Structure.build_media_group/2). The rows
      # usually pre-exist in the test env (plugin bootstrap); list_schemas
      # dedups by name, so the inserts just pin the shape deterministically.
      for spec <- [
            %{name: "mediaAsset", title: "Media Asset", icon: "🖼"},
            %{name: "mediaCollection", title: "Media Collection", icon: "📁"}
          ] do
        %Barkpark.Content.SchemaDefinition{}
        |> Barkpark.Content.SchemaDefinition.changeset(
          Map.merge(spec, %{visibility: "private", dataset: @dataset, fields: []})
        )
        |> Repo.insert!()
      end

      :ok
    end

    test "scoped Studio renders the Media Library link in the /d/ canonical shape", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {:ok, view, html} = live(conn, scoped_url(ws_a, proj_a) <> "/media-desk")

      prefix = "/w/#{ws_a.slug}/p/#{proj_a.slug}"

      # The pane row specifically (not the top-nav Media tab, which is
      # already scoped via default_top_menu_entries/2).
      assert has_element?(
               view,
               ~s{#plugin-link-media-library[href="#{prefix}/d/#{@dataset}/studio/media"]}
             )

      # No flat funnel-riding media href survives anywhere in the render.
      refute html =~ ~s{href="/studio/#{@dataset}/media"}
    end

    test "the flat _plugins admin surface still renders flat hrefs", %{conn: conn} do
      raw = "plugin-href-flat-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Barkpark.Auth.create_token(raw, "plugin href flat admin", @dataset, [
          "read",
          "write",
          "admin"
        ])

      conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/_plugins")

      # scope_prefix == "" → default_top_menu_entries/2 keeps the legacy
      # flat tab paths (they ride the flat→scoped 302 funnel by design).
      assert html =~ ~s{href="/studio/#{@dataset}/media"}
    end
  end

  describe "back-compat: old scoped form → /d/ canonical" do
    test "GET old scoped form 302s to the /d/ canonical, path+query preserved", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      conn = get(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/post/p1?desk=drafts")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio/post/p1?desk=drafts"
    end

    test "GET old scoped root (no tail) 302s to the /d/ canonical", %{
      member_conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      conn = get(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio"
    end

    test "the rewrite is pure — anonymous gets the same Location (no session resolution)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      conn = get(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/#{@dataset}/media")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio/media"
    end

    test "scoped plugin route is NOT swallowed by the back-compat redirect", %{conn: conn} do
      # /w/:ws/p/:proj/studio/<plugin-path> (NO dataset segment) must keep
      # resolving to the plugin LV — the back-compat `/studio/:dataset`
      # wildcard registers AFTER the scoped plugin scopes (swallow guard).
      ensure_default_scope!()
      raw = "dcanon-plugin-guard-#{System.unique_integer([:positive])}"

      {:ok, _token} =
        Barkpark.Auth.create_token(raw, "dcanon plugin guard", @dataset, [
          "read",
          "write",
          "admin"
        ])

      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get("/w/default/p/default/studio/onixedit/ping")

      assert html_response(conn, 200) =~ "OnixEdit plugin route alive."
    end
  end

  # The denied patch surfaces as a redirect — either raised by render_patch
  # (LiveViewTest re-raises server redirects) or readable via assert_redirect.
  defp assert_redirect_to_login(fun) do
    result =
      try do
        {:ok, fun.()}
      catch
        :exit, reason -> {:exit, reason}
      end

    case result do
      {:exit, {{:shutdown, {:redirect, %{to: to}}}, _}} ->
        assert to =~ "/login"

      {:ok, {:error, {:redirect, %{to: to}}}} ->
        assert to =~ "/login"

      {:ok, html} when is_binary(html) ->
        flunk(
          "expected a redirect to /login, got a rendered patch: #{String.slice(html, 0, 200)}"
        )

      other ->
        flunk("unexpected result: #{inspect(other)}")
    end
  end
end
