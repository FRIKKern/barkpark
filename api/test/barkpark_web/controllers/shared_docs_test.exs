defmodule BarkparkWeb.SharedDocsTest do
  @moduledoc """
  P2 — the share-aware scoped READ document routes:

    * `GET /w/:ws/p/:project/v1/data/query/:dataset/:type`
    * `GET /w/:ws/p/:project/v1/data/doc/:dataset/:type/:doc_id`

  SECURITY CONTRACT under test: a `:docs` share opens ONLY read-only document
  queries for the scope — it must NEVER open writes, and only the EXACT shared
  surface is opened.

    (a) With `:docs` shared for the scope, an anonymous GET query/doc returns
        the published document(s).
    (b) An anonymous POST to the mutate route in that SAME (read-)shared scope is
        STILL denied — a `:read` share is method-aware and never grants on an
        unsafe method, so the membership/token gate denies (401/403).
    (c) A NON-shared scope keeps the GET reads gated (anonymous → 401/403/404).
    (d) A `:papers`-only share does NOT open the `:docs` query — surface-exact.

  Default-OFF: with no `:shares` configured the routes behave byte-identically
  to a normal scoped request.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Sharing}

  import Barkpark.TenancyFixtures

  # The shared reader + the share scope both default to the canonical public
  # dataset so the scope triple matches the share's default dataset.
  @dataset "production"

  setup %{conn: conn} = ctx do
    ws = create_workspace!("shared-docs-ws")
    project = create_project!(ws, "shared-docs-proj")

    scope = [workspace_id: ws.id, project_id: project.id]

    # A public `post` schema in this scope — keep anon access trivial; the axis
    # under test is the SHARE, not schema visibility.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    # A public `linkpost` schema (SCOPED to this workspace, like `post` above)
    # with a `related` reference. An anonymous read-share query must pass
    # schema_public?(scope), so the schema lives in the scope; Expand.load_schemas
    # now threads the caller scope into get_schema/3 (workspace-or-global), so
    # reference-field detection finds this scoped schema too.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "linkpost",
          "title" => "Link Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "related", "type" => "reference", "refType" => "linkpost"}
          ]
        },
        @dataset,
        scope
      )

    # A published document so a public read has something to return.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p1", "title" => "Shared Post"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("p1", "post", @dataset, scope)

    # A SECOND document of the same type that stays a DRAFT (never published) so
    # `drafts.d1` exists in the scope but `d1` (published) does not. A read share
    # must never leak this via the query perspective param or a doc-by-id fetch.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "d1", "title" => "Draft Only Post"},
        @dataset,
        scope
      )

    # ── Reference-expansion fixtures (type `linkpost`) ──────────────────────
    # A PUBLISHED linkpost target and an UNPUBLISHED (draft-only) linkpost target.
    {:ok, _} =
      Content.create_document(
        "linkpost",
        %{"_id" => "lp_pub", "title" => "Published Target"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("lp_pub", "linkpost", @dataset, scope)

    # Draft-only target: `drafts.lp_draft` exists, the published `lp_draft` does
    # not. A read share must never leak this via `?expand=`.
    {:ok, _} =
      Content.create_document(
        "linkpost",
        %{"_id" => "lp_draft", "title" => "Draft Target Body"},
        @dataset,
        scope
      )

    # A PUBLISHED linkpost whose `related` reference points at the DRAFT-ONLY
    # `lp_draft`. `?expand=related` must NOT resolve to the draft body on a read
    # share (the published twin is absent → leave the ref unexpanded).
    {:ok, _} =
      Content.create_document(
        "linkpost",
        %{"_id" => "ref_to_draft", "title" => "Refs Draft", "related" => "lp_draft"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("ref_to_draft", "linkpost", @dataset, scope)

    # A PUBLISHED linkpost whose `related` reference points at the PUBLISHED
    # `lp_pub`. `?expand=related` must still expand this normally on a read share.
    {:ok, _} =
      Content.create_document(
        "linkpost",
        %{"_id" => "ref_to_pub", "title" => "Refs Published", "related" => "lp_pub"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("ref_to_pub", "linkpost", @dataset, scope)

    # The conn is anonymous (no Bearer / no session token) — the ONLY way it can
    # read this scope is via a public share.
    {:ok, Map.merge(ctx, %{conn: conn, ws: ws, project: project})}
  end

  defp query_path(ws, project),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/query/#{@dataset}/post"

  defp doc_path(ws, project, id),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/doc/#{@dataset}/post/#{id}"

  defp mutate_path(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/mutate/#{@dataset}"

  # `linkpost`-typed read paths for the reference-expansion (`?expand=`) tests.
  defp link_query_path(ws, project),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/query/#{@dataset}/linkpost"

  defp link_doc_path(ws, project, id),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/doc/#{@dataset}/linkpost/#{id}"

  # Helpers for the reference-expansion (`?expand=`) tests in describe (e).
  defp doc_by_id(docs, id), do: Enum.find(docs, &(&1["_id"] == id))

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp with_token(ws) do
    raw = "shared-docs-tok-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "shared-docs auth", @dataset, ["read", "write"], ws.id)
    raw
  end

  # Mirror scoped_paper_controller_test.exs: stash a parsed :shares config for
  # this test only and restore the prior value on exit.
  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  describe "(a) :docs shared scope — anonymous reads are public" do
    test "anonymous GET query returns the published document(s)", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      body =
        conn
        |> get(query_path(ws, project))
        |> json_response(200)

      docs = body["result"]["documents"]
      ids = Enum.map(docs, & &1["_id"])

      assert "p1" in ids
      assert Enum.any?(docs, &(&1["title"] == "Shared Post"))
    end

    test "anonymous GET doc returns the document by id", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      body =
        conn
        |> get(doc_path(ws, project, "p1"))
        |> json_response(200)

      assert body["result"]["_id"] == "p1"
      assert body["result"]["title"] == "Shared Post"
    end
  end

  describe "(a2) :docs read share is PINNED to published — drafts never leak" do
    test "anonymous GET query returns ONLY the published doc (not the draft)", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      body =
        conn
        |> get(query_path(ws, project))
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])

      assert "p1" in ids
      # The draft-only doc must NOT appear under either its draft or published id.
      refute "d1" in ids
      refute "drafts.d1" in ids
      assert body["result"]["perspective"] == "published"
    end

    test "?perspective=drafts is IGNORED — still only the published doc", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      body =
        conn
        |> get(query_path(ws, project) <> "?perspective=drafts")
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])

      # A read share pins the perspective to published regardless of the param.
      assert body["result"]["perspective"] == "published"
      assert "p1" in ids
      refute "d1" in ids
      refute "drafts.d1" in ids
    end

    test "?perspective=raw is IGNORED — still only the published doc", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      body =
        conn
        |> get(query_path(ws, project) <> "?perspective=raw")
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])

      assert body["result"]["perspective"] == "published"
      assert "p1" in ids
      refute "d1" in ids
      refute "drafts.d1" in ids
    end

    test "anonymous GET a draft doc by `drafts.<id>` returns 404", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      conn = get(conn, doc_path(ws, project, "drafts.d1"))

      assert conn.status == 404
      refute conn.resp_body =~ "Draft Only Post"
    end

    test "anonymous GET the published doc by id still works (200)", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      body =
        conn
        |> get(doc_path(ws, project, "p1"))
        |> json_response(200)

      assert body["result"]["_id"] == "p1"
      assert body["result"]["title"] == "Shared Post"
    end
  end

  describe "(b) :docs read share does NOT open the mutate route" do
    test "anonymous POST mutate in the read-shared scope is STILL denied", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      # Sanity: the read share IS active for this exact scope/surface.
      assert Sharing.shared?(ws.slug, project.slug, @dataset, :docs)
      assert Sharing.access_for(ws.slug, project.slug, @dataset) == :read

      conn =
        post(conn, mutate_path(ws, project), %{
          "mutations" => [
            %{"create" => %{"_type" => "post", "_id" => "p2", "title" => "Should not write"}}
          ]
        })

      # A :read share is method-aware: it never grants on POST, so the normal
      # token/membership gate denies the anonymous caller.
      assert conn.status in [401, 403]
      refute conn.status in [200, 201]

      # And nothing was written: the doc must not exist in the scope.
      scope = [workspace_id: ws.id, project_id: project.id]

      assert Content.get_document("p2", "post", @dataset, scope ++ [perspective: :raw]) ==
               {:error, :not_found}
    end
  end

  describe "(c) NON-shared scope — reads stay gated" do
    test "with no shares configured, anonymous GET query is denied", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      Application.delete_env(:barkpark, :shares)
      refute Sharing.active?()

      conn = get(conn, query_path(ws, project))

      assert conn.status in [401, 403, 404]
      refute conn.status == 200
    end

    test "with no shares configured, anonymous GET doc is denied", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      Application.delete_env(:barkpark, :shares)
      refute Sharing.active?()

      conn = get(conn, doc_path(ws, project, "p1"))

      assert conn.status in [401, 403, 404]
      refute conn.status == 200
    end

    test "sharing a DIFFERENT scope does not open THIS scope's docs query", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("some-other-ws/some-other-proj/#{@dataset}:docs:read")

      conn = get(conn, query_path(ws, project))

      assert conn.status in [401, 403, 404]
      refute conn.status == 200
    end
  end

  describe "(d) surface-exact — a :papers-only share does NOT open :docs" do
    test "a :papers share on this scope leaves the docs query gated", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:papers:read")

      # The share is for :papers ONLY, not :docs.
      assert Sharing.shared?(ws.slug, project.slug, @dataset, :papers)
      refute Sharing.shared?(ws.slug, project.slug, @dataset, :docs)

      conn = get(conn, query_path(ws, project))

      assert conn.status in [401, 403, 404]
      refute conn.status == 200
    end
  end

  describe "(e) :docs read share — ?expand= never leaks a referenced DRAFT" do
    # A read share is published-only at the reference-expansion layer too: a
    # PUBLISHED doc whose reference points at an UNPUBLISHED (`drafts.`) twin
    # must resolve to null/unexpanded — never the draft body. A reference to a
    # PUBLISHED doc still expands. Authed / :edit callers are unchanged.

    test "GET query ?expand=related — ref-to-draft is NOT expanded; ref-to-published IS",
         %{conn: conn, ws: ws, project: project} do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      docs =
        conn
        |> get(link_query_path(ws, project) <> "?expand=related")
        |> json_response(200)
        |> get_in(["result", "documents"])

      ref_to_draft = doc_by_id(docs, "ref_to_draft")
      ref_to_pub = doc_by_id(docs, "ref_to_pub")

      # Ref pointing at the draft-only `lp_draft`: left UNexpanded (still the raw
      # id, never the draft body).
      assert ref_to_draft["related"] == "lp_draft"
      refute is_map(ref_to_draft["related"])
      refute Jason.encode!(ref_to_draft) =~ "Draft Target Body"

      # Ref pointing at the published `lp_pub`: expands normally to the doc map.
      assert is_map(ref_to_pub["related"])
      assert ref_to_pub["related"]["_id"] == "lp_pub"
      assert ref_to_pub["related"]["title"] == "Published Target"
    end

    test "GET doc/:id ?expand=related on a read share — ref-to-draft NOT expanded",
         %{conn: conn, ws: ws, project: project} do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      result =
        conn
        |> get(link_doc_path(ws, project, "ref_to_draft") <> "?expand=related")
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["_id"] == "ref_to_draft"
      assert result["related"] == "lp_draft"
      refute is_map(result["related"])
      refute Jason.encode!(result) =~ "Draft Target Body"
    end

    test "GET doc/:id ?expand=related on a read share — ref-to-published STILL expands",
         %{conn: conn, ws: ws, project: project} do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      result =
        conn
        |> get(link_doc_path(ws, project, "ref_to_pub") <> "?expand=related")
        |> json_response(200)
        |> Map.fetch!("result")

      assert is_map(result["related"])
      assert result["related"]["_id"] == "lp_pub"
      assert result["related"]["title"] == "Published Target"
    end

    test "a NORMAL authed caller (no share) STILL gets the draft expansion (unchanged)",
         %{conn: conn, ws: ws, project: project} do
      Application.delete_env(:barkpark, :shares)
      raw = with_token(ws)

      result =
        conn
        |> authed(raw)
        |> get(link_doc_path(ws, project, "ref_to_draft") <> "?expand=related")
        |> json_response(200)
        |> Map.fetch!("result")

      # No read share ⇒ published_only is false ⇒ the legacy `drafts.` fallback
      # resolves the draft twin, exactly as before this fix.
      assert is_map(result["related"])

      assert result["related"]["_id"] == "drafts.lp_draft" or
               result["related"]["_id"] == "lp_draft"

      assert result["related"]["title"] == "Draft Target Body"
    end

    test "an :edit share STILL gets the draft expansion (read_share? is false)",
         %{conn: conn, ws: ws, project: project} do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:edit")

      # Sanity: this is an :edit share, so the read-only hardening does NOT apply.
      assert Sharing.access_for(ws.slug, project.slug, @dataset) == :edit

      result =
        conn
        |> get(link_doc_path(ws, project, "ref_to_draft") <> "?expand=related")
        |> json_response(200)
        |> Map.fetch!("result")

      assert is_map(result["related"])
      assert result["related"]["title"] == "Draft Target Body"
    end
  end

  describe "(f) an AUTHENTICATED member is NEVER downgraded by a read share" do
    # Regression for the live 2026-06-10 finding: with a `:docs:read` share on
    # the scope, the share grant fired for EVERY safe-read — including the
    # scope's own members carrying a valid token — so `read_share?/1` pinned
    # their reads to published and 404'd `drafts.` ids. The TUI (perspective=
    # drafts on the scoped routes) lost every draft the moment a share existed.
    # A verified token must now bypass the grant entirely; the membership gate
    # decides, with full drafts visibility.

    test "authed GET query ?perspective=drafts STILL surfaces the draft", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")
      raw = with_token(ws)

      body =
        conn
        |> authed(raw)
        |> get(query_path(ws, project) <> "?perspective=drafts")
        |> json_response(200)

      ids = Enum.map(body["result"]["documents"], & &1["_id"])
      assert "drafts.d1" in ids
    end

    test "authed GET doc by `drafts.<id>` STILL returns 200", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")
      raw = with_token(ws)

      body =
        conn
        |> authed(raw)
        |> get(doc_path(ws, project, "drafts.d1"))
        |> json_response(200)

      assert body["result"]["_id"] == "drafts.d1"
      assert body["result"]["title"] == "Draft Only Post"
    end

    test "the ANONYMOUS caller on the same share stays pinned to published", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      with_shares("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      # The token-bypass must not widen anonymous access one inch: no token ⇒
      # the grant still fires ⇒ drafts stay invisible on both read shapes.
      body =
        conn
        |> get(query_path(ws, project) <> "?perspective=drafts")
        |> json_response(200)

      ids = Enum.map(body["result"]["documents"], & &1["_id"])
      refute "drafts.d1" in ids

      conn
      |> get(doc_path(ws, project, "drafts.d1"))
      |> json_response(404)
    end
  end
end
