defmodule BarkparkWeb.Live.ShareLinkRemountConfinementTest do
  @moduledoc """
  task-9e74fdbdf0242c22 — an item share link bound to ONE paper read EVERY
  paper in its workspace/project through the LiveView RE-MOUNT path.

  ## The seam

  `/s/<tokenA>` 302s to `/w/<ws>/p/<proj>/papers/A?share=<tokenA>`. On that
  HTTP request `BarkparkWeb.Plugs.RequireShareScope.maybe_grant_item_token/4`
  checks `link.ref_id == path_params["slug"]` before assigning
  `share_public: true`, so the DEAD RENDER is correctly confined (the negative
  HTTP controls below re-assert that).

  But `live_session :scoped_paper_reader` (router.ex) carried exactly one
  `on_mount` — `{PluginScopeSession, :scope}` — whose own moduledoc said it
  "never halts", and no `LiveAuth` hook is mounted there. `BulldocsLive.mount/3`
  then takes the slug from the CURRENT url and fetches with the SESSION-carried
  workspace/project scope; the item link is never consulted again. Every
  LiveView re-entry that does not replay the router pipeline therefore reached
  any paper in the scope:

    * `live_redirect` to a sibling `/papers/:slug` in the same live_session —
      a full re-mount over the ESTABLISHED socket, no HTTP request, no plugs;
    * the mount that follows a WebSocket RECONNECT — the client replays the
      signed session token it already holds, with whatever URL it chooses;
    * a hand-rolled channel join with the signed session token lifted from
      paper A's page source.

  All three are the same primitive: *A's signed LiveView session + B's URL*.
  `reproduce_socket_remount/2` below is exactly that primitive — it dead-renders
  A (obtaining A's signed session token from the page), then rewrites the conn's
  request path to B and connects, so the socket join carries A's session and B's
  params with no plug in between. `Phoenix.LiveViewTest.live/1` reads the join
  URL from `conn.request_path` (`__live__/3` → `rebuild_path/1`), which is what
  makes the substitution possible without touching LiveView internals.

  ## Verdict

  LEAKS before the fix. Against the unpatched hook the substitution mounted
  BulldocsLive on paper B and rendered `#{"REMOUNT-LEAK-BODY"}` — a paper with
  NO share of any kind — from a link bound to paper A. The positive controls
  (A over its own link, and a section-shared scope) prove the read path is live,
  so the leak was a real read and not a rendering artifact.

  ## The fix

  `PluginScopeSession.build/1` now records the anonymous-grant provenance
  (`scoped_share_public`) plus the RAW `?share=` token in the SIGNED LiveView
  session, and `on_mount(:scope, …)` re-resolves that token on EVERY mount and
  requires it to bind the resource in the current params. Enforcement sits in
  the hook the live_session already registers, so it is inherited by every
  LiveView in `:scoped_paper_reader` — not in `BulldocsLive.mount/3`.

  Because the token is re-RESOLVED (not baked in at dead render), revoking a
  link now tears down the next mount of an already-open reader socket too —
  the sibling revocation gap named in the row.

  ## Kinds covered

  Confined here: `kind: "doc"` / `ref_type: "paper"` item links on the scoped
  paper reader — the only item kind that addresses a LiveView route. `kind:
  "media"` links address controller routes (renditions/meta) with no LiveView,
  so they have no re-mount seam; the hook's `binds_route_resource?/2` mirrors
  the plug for them anyway (fail-closed on any unrecognised param shape).
  SECTION shares (`Sharing.shared?/4`) legitimately grant the WHOLE scope and
  are asserted UNCHANGED below — narrowing them was explicitly out of scope.

  `async: false` — the `:shares` registry is process-global application env.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Sharing, Tenancy}
  alias Barkpark.Sharing.Links
  alias BarkparkWeb.PluginScopeSession

  @dataset "production"
  @granted_slug "remount-granted-paper"
  @granted_body "REMOUNT-GRANTED-BODY"
  @sibling_slug "remount-sibling-paper"
  @sibling_body "REMOUNT-LEAK-BODY"

  setup %{conn: conn} do
    prior_shares = Application.get_env(:barkpark, :shares)

    on_exit(fn ->
      if is_nil(prior_shares),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior_shares)
    end)

    # A NON-default workspace: the seeded Default is an open public demo in
    # test, which would grant the reads under audit for the wrong reason.
    ws = create_workspace!("remount-share-ws-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "remount-share-proj"})

    seed_paper!(ws, proj, @granted_slug, "Granted Paper", @granted_body)
    seed_paper!(ws, proj, @sibling_slug, "Sibling Paper", @sibling_body)

    %{conn: conn, ws: ws, proj: proj}
  end

  defp seed_paper!(ws, proj, slug, title, body) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => title,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => body}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  defp mint_link!(ws, proj, ref_id, attrs \\ %{}) do
    {:ok, {raw, link}} =
      Links.create(
        Map.merge(
          %{
            workspace_id: ws.id,
            project_id: proj.id,
            dataset: @dataset,
            kind: "doc",
            ref_type: "paper",
            ref_id: ref_id,
            access: "read"
          },
          attrs
        )
      )

    {raw, link}
  end

  defp with_shares(env_string) do
    Application.put_env(:barkpark, :shares, Sharing.parse(env_string))
    :ok
  end

  defp paper_path(ws, proj, slug), do: "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}"

  # THE ATTACK PRIMITIVE. Dead-render `granted_path` (the plug grants, the page
  # carries A's SIGNED LiveView session token), then connect the socket with the
  # request path rewritten to `target_path`. No plug runs on that join — which is
  # exactly what a `live_redirect`, a socket reconnect, or a hand-rolled channel
  # join with the lifted session token does in a real browser.
  defp reproduce_socket_remount(conn, {granted_path, target_path}) do
    dead = get(conn, granted_path)

    assert dead.status == 200,
           "the granted dead render must succeed for the substitution to mean anything"

    forged = %{dead | request_path: target_path, query_string: ""}
    live(forged)
  end

  describe "the socket re-mount is confined to the item link's bound paper" do
    test "A's signed share session + B's URL is REFUSED (the row's exploit)", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {raw, _link} = mint_link!(ws, proj, @granted_slug)

      result =
        reproduce_socket_remount(conn, {
          paper_path(ws, proj, @granted_slug) <> "?share=#{raw}",
          paper_path(ws, proj, @sibling_slug)
        })

      # EVIDENCE ORDER MATTERS. A bare `assert {:error, …} = result` only proves
      # the mount was not refused; it does NOT prove the socket read the other
      # paper, and a red run on it would be void-but-plausible. Assert the READ
      # first, so an unfixed tree fails naming the leaked body — the positive
      # control in the section-share describe proves @sibling_body is renderable
      # at all, which is what makes this refute meaningful.
      refute leaked?(result, @sibling_body),
             "the socket re-mount RENDERED #{@sibling_body} — a paper the item link never granted"

      # Same denial envelope the tree's other live-auth tests assert (a bare
      # {:redirect, %{to: …}}); the redirect's :flash is a SIGNED TOKEN here, so
      # the message itself is pinned on the hook directly, further down.
      assert {:error, {:redirect, %{to: "/login"}}} = result
    end

    test "positive control: the SAME substitution back onto A's own slug still mounts", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {raw, _link} = mint_link!(ws, proj, @granted_slug)

      assert {:ok, _view, html} =
               reproduce_socket_remount(conn, {
                 paper_path(ws, proj, @granted_slug) <> "?share=#{raw}",
                 paper_path(ws, proj, @granted_slug)
               })

      assert html =~ @granted_body
    end

    test "the ordinary first mount over the item link is unchanged", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {raw, _link} = mint_link!(ws, proj, @granted_slug)

      assert {:ok, _view, html} =
               live(conn, paper_path(ws, proj, @granted_slug) <> "?share=#{raw}")

      assert html =~ @granted_body
    end

    test "revoking the link tears down the NEXT mount of the same share session", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {raw, link} = mint_link!(ws, proj, @granted_slug)
      granted = paper_path(ws, proj, @granted_slug) <> "?share=#{raw}"

      dead = get(conn, granted)
      assert dead.status == 200

      {:ok, _link} = Links.revoke(link.id)

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(%{dead | request_path: paper_path(ws, proj, @granted_slug), query_string: ""})
    end
  end

  describe "the section-share path is NOT narrowed" do
    test "a :papers section share still reaches every paper in its scope", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

      assert {:ok, _view, html} = live(conn, paper_path(ws, proj, @granted_slug))
      assert html =~ @granted_body

      assert {:ok, _view, sibling_html} = live(conn, paper_path(ws, proj, @sibling_slug))
      assert sibling_html =~ @sibling_body
    end

    test "a stale item token on a section-shared scope does not lock the reader out", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {raw, link} = mint_link!(ws, proj, @granted_slug)
      {:ok, _link} = Links.revoke(link.id)
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

      assert {:ok, _view, html} =
               live(conn, paper_path(ws, proj, @sibling_slug) <> "?share=#{raw}")

      assert html =~ @sibling_body
    end
  end

  describe "the HTTP dead render stays confined (negative controls)" do
    test "B's dead render with A's token is denied", %{conn: conn, ws: ws, proj: proj} do
      {raw, _link} = mint_link!(ws, proj, @granted_slug)

      conn = get(conn, paper_path(ws, proj, @sibling_slug) <> "?share=#{raw}")
      assert conn.status == 403
    end

    test "B's dead render with no credential at all is denied", %{conn: conn, ws: ws, proj: proj} do
      conn = get(conn, paper_path(ws, proj, @sibling_slug))
      assert conn.status == 403
    end
  end

  # The hook is the enforcement point, so it is also asserted directly: the
  # BOUND resource is read from the SIGNED session's token, never from params.
  describe "PluginScopeSession session contract" do
    test "build/1 bakes the anonymous-grant provenance + the raw token", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {raw, _link} = mint_link!(ws, proj, @granted_slug)

      dead = get(conn, paper_path(ws, proj, @granted_slug) <> "?share=#{raw}")
      assert dead.status == 200

      session = PluginScopeSession.build(dead)

      assert session["scoped_workspace_id"] == ws.id
      assert session["scoped_project_id"] == proj.id
      assert session["scoped_share_public"] == true
      assert session["scoped_share_token"] == raw
    end

    test "the session's token decides, not the params slug", %{conn: conn, ws: ws, proj: proj} do
      {raw, _link} = mint_link!(ws, proj, @granted_slug)

      dead = get(conn, paper_path(ws, proj, @granted_slug) <> "?share=#{raw}")
      session = PluginScopeSession.build(dead)
      socket = bare_socket()

      assert {:cont, _} =
               PluginScopeSession.on_mount(:scope, %{"slug" => @granted_slug}, session, socket)

      assert {:halt, denied} =
               PluginScopeSession.on_mount(:scope, %{"slug" => @sibling_slug}, session, socket)

      # The denial envelope, read off the socket the hook returned: a full
      # redirect out of the live_session plus the reason — never a silent
      # in-socket fallback to another document.
      assert {:redirect, %{to: "/login"}} = denied.redirected
      assert denied.assigns.flash["error"] =~ "share link"

      # An item link can only open a SINGLE-resource route; a params shape with
      # no resource key is never item-granted.
      assert {:halt, _} = PluginScopeSession.on_mount(:scope, %{}, session, socket)

      assert {:halt, _} =
               PluginScopeSession.on_mount(:scope, :not_mounted_at_router, session, socket)
    end

    test "a membership-gated session carries no share keys and never halts", %{
      ws: ws,
      proj: proj
    } do
      session =
        PluginScopeSession.build(%Plug.Conn{
          assigns: %{current_workspace: ws, current_project: proj}
        })

      refute Map.has_key?(session, "scoped_share_public")
      refute Map.has_key?(session, "scoped_share_token")

      assert {:cont, _} =
               PluginScopeSession.on_mount(
                 :scope,
                 %{"slug" => @sibling_slug},
                 session,
                 bare_socket()
               )
    end
  end

  # `deny/1` puts a flash, so the socket needs the assigns a real mount carries.
  defp bare_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  # Did the socket actually READ `body`? `live/1` returns the dead-render HTML
  # merged with the connected diff, so the connected render is checked too — the
  # dead response here belongs to paper A, and only the CONNECTED mount can put
  # paper B's body on the socket.
  defp leaked?({:ok, view, html}, body), do: html =~ body or render(view) =~ body
  defp leaked?(_result, _body), do: false
end
