defmodule BarkparkWeb.ScopedPaperControllerTest do
  @moduledoc """
  P1b — the gated scoped paper reader at
  `GET /w/:workspace_slug/p/:project_slug/papers/:slug`.

  SECURITY CONTRACT under test: a paper is PUBLIC (anonymous-readable) ONLY when
  its `(workspace, project, dataset)` scope is shared for the `:papers` surface
  via `Barkpark.Sharing`. With no share — or a share of a DIFFERENT scope /
  surface — the request stays gated EXACTLY as a normal scoped request (the
  `ResolveWorkspace` membership gate denies an anonymous caller). Default-OFF.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, EpicFleet, Repo, Sharing}
  alias Barkpark.Content.{Document, Revision}

  import Barkpark.TenancyFixtures

  # The reader + the share scope both default to the canonical public dataset.
  @dataset "production"

  setup %{conn: conn} = ctx do
    ws = create_workspace!("share-test-ws")
    project = create_project!(ws, "share-test-proj")

    # Create a real paper (doc_id == slug, NOT a `drafts.` row) in this scope,
    # carrying a known body_html so we can assert it renders.
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "shared-paper",
          "dataset" => @dataset,
          "body_html" => "<h1>Hello Shared Paper</h1><p>scoped body</p>",
          "workspace_id" => ws.id,
          "project_id" => project.id
        })
      )

    paper = pin_released_revision!(paper)

    # The conn is anonymous (no Bearer / no session token) — so the only way it
    # can read this scope is via a public share.
    {:ok, Map.merge(ctx, %{conn: conn, ws: ws, project: project, paper: paper})}
  end

  defp paper_path(ws, project, slug), do: "/w/#{ws.slug}/p/#{project.slug}/papers/#{slug}"

  # Mirror sharing_test.exs's helper: stash a parsed :shares config for this
  # test only and restore the prior value on exit.
  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  describe "GET /w/:ws/p/:project/papers/:slug — (a) shared :papers scope" do
    test "returns 200 and renders the paper for an anonymous caller", %{
      conn: conn,
      ws: ws,
      project: project,
      paper: paper
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      assert body =~ "Hello Shared Paper"
      assert body =~ "scoped body"
      assert_revision_headers(conn, paper)
    end

    test "PIPELINE ORDER: a conditional replay through the ROUTER is a CSP-free 304 with the pinned cache-control",
         %{conn: conn, ws: ws, project: project} do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      conn200 = get(conn, paper_path(ws, project, "shared-paper"))
      assert [etag] = get_resp_header(conn200, "etag")

      conn304 =
        scoped_conn()
        |> put_req_header("if-none-match", etag)
        |> get(paper_path(ws, project, "shared-paper"))

      assert conn304.status == 304
      assert conn304.resp_body == ""
      assert get_resp_header(conn304, "etag") == [etag]

      assert get_resp_header(conn304, "cache-control") ==
               ["private, max-age=0, must-revalidate"]

      # Second-review condition 3: on the scoped route PaperRevisionHeaders is
      # the LAST plug of :shared_paper_browser, so the 304 halt must keep
      # :paper_reader_csp from ever minting a nonce (and the delete strips the
      # pipeline's own static CSP). Only a ROUTER-level test can catch a future
      # pipeline reorder that leaks a fresh-nonce CSP onto a 304 — the direct
      # plug-call test structurally cannot.
      assert get_resp_header(conn304, "content-security-policy") == []
    end

    test "block-backed scoped reader rejects a conflicting body_html cache", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      blocks = [
        %{
          "id" => "scoped-authority",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Scoped blocks are authoritative."}]
        }
      ]

      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "shared-paper",
            "dataset" => @dataset,
            "blocks" => blocks,
            "workspace_id" => ws.id,
            "project_id" => project.id
          })
        )

      paper = pin_released_revision!(paper)

      stale_content =
        paper.content
        |> Map.put("body_html", "<p>STALE SCOPED CACHE</p>")
        |> Map.put(
          "body_html_sv",
          Barkpark.PortableDoc.Render.body_html_render_version()
        )

      paper
      |> Ecto.Changeset.change(content: stale_content)
      |> Barkpark.Repo.update!()

      assert_raise BarkparkWeb.BulldocsLive.InvalidSource, fn ->
        get(conn, paper_path(ws, project, "shared-paper"))
      end
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — (b) NO shares configured" do
    test "is NOT public — the membership gate denies the anonymous caller", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      # No with_shares/1 call → Default-OFF. arpss-w8: clear_shares!/0 empties the
      # env baseline AND every STORED row (a bare delete_env leaves rows that the
      # next Sharing.refresh/0 puts straight back), and restores both keys.
      Barkpark.SharingFixtures.clear_shares!()
      refute Sharing.active?()

      conn = get(conn, paper_path(ws, project, "shared-paper"))

      # ResolveWorkspace gates an anonymous caller closed. It MUST NOT be a 200
      # and MUST NOT render the paper body.
      assert conn.status in [401, 403, 404]
      refute conn.status == 200
      refute conn.resp_body =~ "Hello Shared Paper"
      assert get_resp_header(conn, "etag") == []
      assert get_resp_header(conn, "x-barkpark-paper-revision") == []
    end

    test "sharing a DIFFERENT scope does not make THIS scope public", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      # Share an unrelated workspace/project for :papers — must not leak here.
      with_shares("some-other-ws/some-other-proj/#{@dataset}:papers:read")

      conn = get(conn, paper_path(ws, project, "shared-paper"))

      assert conn.status in [401, 403, 404]
      refute conn.status == 200
      refute conn.resp_body =~ "Hello Shared Paper"
      assert get_resp_header(conn, "etag") == []
      assert get_resp_header(conn, "x-barkpark-paper-revision") == []
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — (c) shares :docs but NOT :papers" do
    test "the paper reader is NOT public", %{conn: conn, ws: ws, project: project} do
      # Same scope, but only the :docs surface is shared — the :papers reader
      # must stay gated.
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      refute Sharing.shared?(ws.slug, project.slug, @dataset, :papers)
      assert Sharing.shared?(ws.slug, project.slug, @dataset, :docs)

      conn = get(conn, paper_path(ws, project, "shared-paper"))

      assert conn.status in [401, 403, 404]
      refute conn.status == 200
      refute conn.resp_body =~ "Hello Shared Paper"
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — (d) shared scope, missing slug" do
    test "a non-existent slug in a shared scope returns the canonical 404", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      assert_raise BarkparkWeb.BulldocsLive.NotFound, fn ->
        get(conn, paper_path(ws, project, "does-not-exist"))
      end
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — related Paper cards" do
    test "renders the section listing a paper that references this one", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      # A second paper in the SAME scope. A heading block gives it a real title
      # (the engine hydrates the referencer title from its documents row).
      {:ok, _src} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "linking-paper",
            "dataset" => @dataset,
            "workspace_id" => ws.id,
            "project_id" => project.id,
            "blocks" => [
              %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "The Linking Paper"},
              # A body block: heading-only papers are hollow and refused by the
              # p-quality-gate hollow gate; this test is about backlink tenancy.
              %{
                "id" => "p1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      # Materialise the inbound edge in `content_edges` (what the EdgeProjector
      # writes on publish). The reader reads the INDEXED engine
      # (`Content.Graph.reverse_referencers/2`), not a block scan.
      Content.add_edges(
        [%{from_id: "linking-paper", to_id: "shared-paper", kind: "references"}],
        dataset: @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      assert body =~ "Related papers"
      assert body =~ "The Linking Paper"
      assert body =~ ~s(href="/papers/linking-paper")
    end

    test "omits the section entirely when nothing references the paper", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      # No other paper references "shared-paper" → no section.
      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      assert body =~ "Hello Shared Paper"
      refute body =~ "Related papers"
    end

    test "TENANCY: a referencer in ANOTHER workspace is NOT shown to this reader", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      # A foreign workspace + project with a paper that references the target.
      # The edge is materialised, but the engine hydrates the referencer's title
      # under the READER's scope (the target's workspace) — so a source in a
      # DIFFERENT workspace resolves to nothing and the reader never surfaces it.
      foreign_ws = create_workspace!("foreign-ws")
      foreign_project = create_project!(foreign_ws, "foreign-proj")

      {:ok, _foreign} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "foreign-linker",
            "dataset" => @dataset,
            "workspace_id" => foreign_ws.id,
            "project_id" => foreign_project.id,
            "blocks" => [
              %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Foreign Linker"},
              # A body block: heading-only papers are hollow and refused by the
              # p-quality-gate hollow gate; this test is about backlink tenancy.
              %{
                "id" => "p1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      # Resolve both endpoints unscoped (dataset only) so the cross-workspace
      # edge row is actually written.
      Content.add_edges(
        [%{from_id: "foreign-linker", to_id: "shared-paper", kind: "references"}],
        dataset: @dataset
      )

      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      # The reader sees the paper but NOT the cross-workspace referencer.
      assert body =~ "Hello Shared Paper"
      refute body =~ "Foreign Linker"
      refute body =~ ~s(href="/papers/foreign-linker")
      # With the only referencer scoped out, the section is omitted entirely.
      refute body =~ "Related papers"
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — anonymous-Default allowance (bug-scoped-paper-route-500)" do
    # The flat /papers/:slug reader serves the seeded Default workspace's
    # published papers anonymously (get_public_paper pins that tenant). The
    # scoped spelling of the SAME content must not 403: the
    # :shared_paper_browser pipeline carries `allow_anonymous_default: true`
    # exactly like :shared_studio_browser. Everything non-Default stays closed.
    setup %{conn: conn} do
      # Default-OFF shares: the allowance (not a share) must open the route.
      Application.delete_env(:barkpark, :shares)
      refute Sharing.active?()

      {default_ws, default_project} = ensure_default_scope!()

      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "default-public-paper",
            "dataset" => @dataset,
            "body_html" => "<h1>Default Public Paper</h1><p>default body</p>",
            "workspace_id" => default_ws.id,
            "project_id" => default_project.id
          })
        )

      paper = pin_released_revision!(paper)

      {:ok,
       conn: conn, default_ws: default_ws, default_project: default_project, default_paper: paper}
    end

    test "an anonymous caller reads a Default-scope published paper (parity with /papers/:slug)",
         %{
           conn: conn,
           default_ws: default_ws,
           default_project: default_project,
           default_paper: paper
         } do
      # Sanity: the flat public reader serves this paper anonymously.
      flat = get(conn, "/papers/default-public-paper")
      assert html_response(flat, 200) =~ "Default Public Paper"

      # The scoped spelling of the same published content must match, not 403.
      conn = get(conn, paper_path(default_ws, default_project, "default-public-paper"))
      body = html_response(conn, 200)

      assert body =~ "Default Public Paper"
      assert body =~ "default body"
      assert_revision_headers(conn, paper)
    end

    test "a missing slug in the Default scope returns the canonical 404",
         %{conn: conn, default_ws: default_ws, default_project: default_project} do
      assert_raise BarkparkWeb.BulldocsLive.NotFound, fn ->
        get(conn, paper_path(default_ws, default_project, "no-such-paper-xyz"))
      end
    end

    test "the allowance is ANONYMOUS-only: a token that is not a Default member still 403s",
         %{conn: conn, default_ws: default_ws, default_project: default_project} do
      # A token bound to a DIFFERENT workspace: token-present requests keep the
      # membership gate byte-identical (the cond's is_nil(token) arm never fires).
      other_ws = create_workspace!("other-ws-for-token")
      raw = "outsider-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "outsider tok", @dataset, ["read"], other_ws.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(paper_path(default_ws, default_project, "default-public-paper"))

      assert conn.status == 403
      refute conn.resp_body =~ "Default Public Paper"
    end

    test "an anonymous caller still CANNOT read a non-Default workspace's paper", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      # The allowance is bounded to the seeded Default workspace — the
      # setup-created non-Default scope stays gated exactly as before.
      conn = get(conn, paper_path(ws, project, "shared-paper"))

      assert conn.status in [401, 403, 404]
      refute conn.resp_body =~ "Hello Shared Paper"
    end

    test "a Default member with a SESSION token (browser login shape) reads the paper — never a 500",
         %{conn: conn, default_ws: default_ws, default_project: default_project} do
      # The originally-reported failure was observed with a browser session on
      # /w/default/p/default/papers/:slug. Drive the exact pipeline shape —
      # session["api_token"], no Bearer header — through the dead render and
      # assert the paper page renders (and in particular never 500s).
      raw = "member-session-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "session tok", @dataset, ["read"], default_ws.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => raw})
        |> get(paper_path(default_ws, default_project, "default-public-paper"))

      body = html_response(conn, 200)
      assert body =~ "Default Public Paper"
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — non-shared path stays the normal gated request" do
    test "a workspace MEMBER reads their own paper via the membership gate (no share)", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      # Default-OFF: no shares. The bypass must NOT fire. A real member's Bearer
      # token clears ResolveWorkspace's membership gate exactly as on any normal
      # scoped request, proving the non-shared path is byte-identical to today.
      Application.delete_env(:barkpark, :shares)
      refute Sharing.active?()

      raw = "member-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "member tok", @dataset, ["read"], ws.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(paper_path(ws, project, "shared-paper"))

      body = html_response(conn, 200)
      assert body =~ "Hello Shared Paper"
    end
  end

  describe "Paper revision response authority" do
    test "missing and unpublished Papers never receive revision authority headers", %{
      ws: ws,
      project: project,
      paper: paper
    } do
      missing =
        Plug.Test.conn(:get, paper_path(ws, project, "missing-paper"))
        |> Plug.Conn.assign(:current_workspace, ws)
        |> Plug.Conn.assign(:current_project, project)
        |> BarkparkWeb.Plugs.PaperRevisionHeaders.call([])

      assert Plug.Conn.get_resp_header(missing, "etag") == []
      assert Plug.Conn.get_resp_header(missing, "x-barkpark-paper-revision") == []

      paper |> Ecto.Changeset.change(status: "draft") |> Repo.update!()

      unpublished =
        Plug.Test.conn(:get, paper_path(ws, project, paper.doc_id))
        |> Plug.Conn.assign(:current_workspace, ws)
        |> Plug.Conn.assign(:current_project, project)
        |> BarkparkWeb.Plugs.PaperRevisionHeaders.call([])

      assert Plug.Conn.get_resp_header(unpublished, "etag") == []
      assert Plug.Conn.get_resp_header(unpublished, "x-barkpark-paper-revision") == []
    end
  end

  defp assert_revision_headers(conn, paper) do
    paper = Repo.get!(Document, paper.id)

    assert get_resp_header(conn, "x-barkpark-paper-revision") == [paper.released_revision_id]

    # http-edge-truth D9: weak validator over content + compiled shell build,
    # bounded by the 7-day token-safety bucket.
    bucket = div(System.os_time(:second), 604_800)
    build_digest = EpicFleet.canonical_digest(Barkpark.BuildInfo.info())

    assert get_resp_header(conn, "etag") == [
             ~s(W/"sha256:#{EpicFleet.canonical_digest(paper.content)}.#{build_digest}.#{bucket}")
           ]
  end

  defp pin_released_revision!(paper) do
    revision =
      %Revision{}
      |> Revision.changeset(%{
        document_id: paper.id,
        doc_id: paper.doc_id,
        type: paper.type,
        dataset: paper.dataset,
        dataset_id: paper.dataset_id,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id,
        title: paper.title,
        status: paper.status,
        action: "publish",
        content: paper.content
      })
      |> Repo.insert!()

    paper
    |> Ecto.Changeset.change(
      current_revision_id: revision.id,
      released_revision_id: revision.id
    )
    |> Repo.update!()
  end
end
