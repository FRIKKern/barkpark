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

  alias Barkpark.{Auth, Content, Sharing}

  import Barkpark.TenancyFixtures

  # The reader + the share scope both default to the canonical public dataset.
  @dataset "production"

  setup %{conn: conn} = ctx do
    ws = create_workspace!("share-test-ws")
    project = create_project!(ws, "share-test-proj")

    # Create a real paper (doc_id == slug, NOT a `drafts.` row) in this scope,
    # carrying a known body_html so we can assert it renders.
    {:ok, _paper} =
      Content.upsert_paper(%{
        "slug" => "shared-paper",
        "dataset" => @dataset,
        "body_html" => "<h1>Hello Shared Paper</h1><p>scoped body</p>",
        "workspace_id" => ws.id,
        "project_id" => project.id
      })

    # The conn is anonymous (no Bearer / no session token) — so the only way it
    # can read this scope is via a public share.
    {:ok, Map.merge(ctx, %{conn: conn, ws: ws, project: project})}
  end

  defp paper_path(ws, project, slug), do: "/w/#{ws.slug}/p/#{project.slug}/papers/#{slug}"

  # Mirror sharing_test.exs's helper: stash a parsed :shares config for this
  # test only and restore the prior value on exit.
  defp with_shares(env_string) do
    prior = Application.get_env(:barkpark, :shares)
    Application.put_env(:barkpark, :shares, Sharing.parse(env_string))

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior)
    end)

    :ok
  end

  describe "GET /w/:ws/p/:project/papers/:slug — (a) shared :papers scope" do
    test "returns 200 and renders the paper for an anonymous caller", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      assert body =~ "Hello Shared Paper"
      assert body =~ "scoped body"
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — (b) NO shares configured" do
    test "is NOT public — the membership gate denies the anonymous caller", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      # No with_shares/1 call → :shares unset → Default-OFF. Reset any leakage.
      Application.delete_env(:barkpark, :shares)
      refute Sharing.active?()

      conn = get(conn, paper_path(ws, project, "shared-paper"))

      # ResolveWorkspace gates an anonymous caller closed. It MUST NOT be a 200
      # and MUST NOT render the paper body.
      assert conn.status in [401, 403, 404]
      refute conn.status == 200
      refute conn.resp_body =~ "Hello Shared Paper"
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
    test "a non-existent slug in a shared scope renders the pending shell, leaking nothing", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      conn = get(conn, paper_path(ws, project, "does-not-exist"))

      # P4: the scoped reader is the LIVE BulldocsLive — a missing slug
      # renders the empty live shell (200) and streams the paper in if it
      # is published later (the flat reader's contract, now shared). The
      # no-leak property is about CONTENT, which stays absent.
      assert conn.status == 200
      refute conn.resp_body =~ "Hello Shared Paper"
    end
  end

  describe "GET /w/:ws/p/:project/papers/:slug — 'Linked mentions' backlinks section" do
    test "renders the section listing a paper that wikilinks to this one", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      # A second paper whose blocks carry a wikilink pinned (docId) to the
      # target slug "shared-paper". A heading block gives it a real title
      # (paper_title derives the title from the first heading block).
      {:ok, _src} =
        Content.upsert_paper(%{
          "slug" => "linking-paper",
          "dataset" => @dataset,
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "blocks" => [
            %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "The Linking Paper"},
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [
                %{"type" => "text", "value" => "As covered in "},
                %{"type" => "wikilink", "docId" => "shared-paper", "children" => []},
                %{"type" => "text", "value" => " earlier."}
              ]
            }
          ]
        })

      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      assert body =~ "Linked mentions"
      assert body =~ "The Linking Paper"
      assert body =~ ~s(href="/papers/linking-paper")
      assert body =~ "As covered in"
    end

    test "omits the section entirely when nothing links to the paper", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      # No other paper links to "shared-paper" → no section.
      conn = get(conn, paper_path(ws, project, "shared-paper"))
      body = html_response(conn, 200)

      assert body =~ "Hello Shared Paper"
      refute body =~ "Linked mentions"
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
end
