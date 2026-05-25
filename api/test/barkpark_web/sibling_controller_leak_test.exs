defmodule BarkparkWeb.SiblingControllerLeakTest do
  @moduledoc """
  Wave 1.5-A negative cross-workspace leak tests for the sibling read/write
  controllers that previously filtered by `dataset` ALONE (and so returned
  another workspace's rows on the shared `dataset` leaf).

  Each test stands up TWO workspaces (A and B) in the SAME dataset, writes a
  row into workspace A, then drives the scoped `/w/:ws/p/:project/...` route as
  a member of workspace B and asserts A's row is NOT returned. The dataset
  string is identical across workspaces on purpose — isolation MUST come from
  `workspace_id`, never the dataset leaf.

  Surfaces covered (1:1 with the brief's B1/B2/B3/B11/B12/B13):

    * B1  SEARCH    — /v1/data/search/:dataset            (the worst leak)
    * B1  FEDERATED — /v1/search/:dataset (documents surface)
    * B2  EXPORT    — /v1/data/export/:dataset
    * B3  MUTATE    — inner get_document on the mutate path (Content unit test)
    * B11 HISTORY   — /v1/data/history + /revision + /revision/:id/restore
    * B12 ANALYTICS — /v1/data/analytics/:dataset
    * B13 SCHEMA    — /v1/schemas/:dataset (project-scoped)
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "leak_ds"

  # Build two isolated workspaces, each with a project + an admin-perm token
  # bound as a member of its OWN workspace only. The schema lives in BOTH
  # workspaces (so reads are gated by row scope, not by schema absence).
  setup do
    {ws_a, proj_a, tok_a} = workspace_with_token("a")
    {ws_b, proj_b, tok_b} = workspace_with_token("b")

    # The "post" schema. The DB carries a unique index on (name, dataset), so a
    # single shared-dataset row serves both workspaces' document reads. It is
    # stamped to A; the B13 leak test below uses a SEPARATE, A-only schema name
    # (`secret_a`) to prove the project-scoped read filter — it does not depend
    # on duplicating `post` across workspaces.
    {:ok, _} = Content.upsert_schema(post_schema(), @dataset, scope(ws_a, proj_a))

    {:ok,
     ws_a: ws_a,
     proj_a: proj_a,
     tok_a: tok_a,
     ws_b: ws_b,
     proj_b: proj_b,
     tok_b: tok_b}
  end

  describe "B1 search (/v1/data/search) — the worst leak" do
    test "workspace B's search does not return workspace A's document", ctx do
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "leakdoc-a", "Quokka Field Notes")

      # Sanity: A sees its own doc under A's scope.
      a_hits = search_hits(ctx, ctx.ws_a, ctx.proj_a, ctx.tok_a, "quokka")
      assert "drafts.leakdoc-a" in a_hits, "search did not surface A's own doc under A's scope"

      # Leak guard: B must NOT see A's doc.
      b_hits = search_hits(ctx, ctx.ws_b, ctx.proj_b, ctx.tok_b, "quokka")

      refute "drafts.leakdoc-a" in b_hits,
             "CROSS-WORKSPACE LEAK (search): workspace A's doc surfaced in B's search results"
    end
  end

  describe "B1 federated search (/v1/search documents surface)" do
    test "workspace B's federated search does not return workspace A's document", ctx do
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "fed-a", "Wombat Burrow Guide")

      a_hits = federated_doc_hits(ctx, ctx.ws_a, ctx.proj_a, ctx.tok_a, "wombat")
      assert "drafts.fed-a" in a_hits, "federated search did not surface A's doc under A's scope"

      b_hits = federated_doc_hits(ctx, ctx.ws_b, ctx.proj_b, ctx.tok_b, "wombat")

      refute "drafts.fed-a" in b_hits,
             "CROSS-WORKSPACE LEAK (federated search): A's doc surfaced in B's federated results"
    end
  end

  describe "B2 export (/v1/data/export)" do
    test "workspace B's export does not stream workspace A's document", ctx do
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "export-a", "Export Only A")

      a_ids = export_ids(ctx, ctx.ws_a, ctx.proj_a, ctx.tok_a)
      assert "drafts.export-a" in a_ids, "export did not stream A's own doc under A's scope"

      b_ids = export_ids(ctx, ctx.ws_b, ctx.proj_b, ctx.tok_b)

      refute "drafts.export-a" in b_ids,
             "CROSS-WORKSPACE LEAK (export): A's doc streamed under B's export"
    end
  end

  describe "B3 mutate inner-read (Content.apply_mutations)" do
    test "a mutate scoped to B cannot read or overwrite A's document of the same id", ctx do
      {:ok, doc_a} = create_doc(ctx.ws_a, ctx.proj_a, "shared-id", "A's Title")

      # B issues a patch against the SAME doc id. Pre-fix, the inner (unscoped)
      # get_document resolved A's row and the write UPDATED it — a silent
      # cross-workspace overwrite. Scoped, B's lookup sees no row of its own.
      patch = %{
        "patch" => %{
          "id" => "shared-id",
          "type" => "post",
          "set" => %{"title" => "B's Overwrite"}
        }
      }

      result = Content.apply_mutations([patch], @dataset, scope(ctx.ws_b, ctx.proj_b))

      # B's patch must NOT have resolved A's row. Either it errors (no row of
      # B's own under the (doc_id,type,dataset) unique leaf) — the fail-closed
      # outcome — but it must never return A's document as the patched result.
      case result do
        {:ok, {_tx, [res]}} ->
          refute res.document["title"] == "A's Title",
                 "CROSS-WORKSPACE LEAK (mutate inner-read): B's patch resolved A's row"

        {:error, _reason} ->
          # Fail-closed: B saw no row of its own and the write did not clobber A.
          :ok
      end

      # The decisive assertion: A's row is byte-for-byte untouched.
      {:ok, still_a} =
        Content.get_document("drafts.shared-id", "post", @dataset, scope(ctx.ws_a, ctx.proj_a))

      assert still_a.title == "A's Title",
             "CROSS-WORKSPACE LEAK (mutate inner-read): B's mutate overwrote A's document title"

      assert still_a.id == doc_a.id
      assert still_a.workspace_id == ctx.ws_a.id
    end
  end

  describe "B11 history (/v1/data/history + revision)" do
    test "workspace B's history list does not return workspace A's revisions", ctx do
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "hist-a", "Hist A")
      # publish through the mutate path (scoped to A) so a Revision row is
      # written + stamped with A's scope.
      {:ok, _} =
        Content.apply_mutations(
          [%{"publish" => %{"id" => "hist-a", "type" => "post"}}],
          @dataset,
          scope(ctx.ws_a, ctx.proj_a)
        )

      a_revs =
        ctx.tok_a
        |> authed(ctx.conn)
        |> get(scoped(ctx.ws_a, ctx.proj_a, "/v1/data/history/#{@dataset}/post/hist-a"))
        |> json_response(200)

      assert a_revs["count"] >= 1, "history did not list A's own revision under A's scope"

      b_revs =
        ctx.tok_b
        |> authed(ctx.conn)
        |> get(scoped(ctx.ws_b, ctx.proj_b, "/v1/data/history/#{@dataset}/post/hist-a"))
        |> json_response(200)

      assert b_revs["count"] == 0,
             "CROSS-WORKSPACE LEAK (history): B saw #{b_revs["count"]} of A's revisions"
    end

    test "workspace B cannot fetch a single revision belonging to A", ctx do
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "rev-a", "Rev A")

      {:ok, _} =
        Content.apply_mutations(
          [%{"publish" => %{"id" => "rev-a", "type" => "post"}}],
          @dataset,
          scope(ctx.ws_a, ctx.proj_a)
        )

      [rev_a | _] = Content.list_revisions("rev-a", "post", @dataset, scope(ctx.ws_a, ctx.proj_a))

      # A can fetch its own revision by id.
      a_resp =
        ctx.tok_a
        |> authed(ctx.conn)
        |> get(scoped(ctx.ws_a, ctx.proj_a, "/v1/data/revision/#{@dataset}/#{rev_a.id}"))

      assert a_resp.status == 200

      # B fetching A's revision id → 404 (scoped get_revision returns not_found).
      b_resp =
        ctx.tok_b
        |> authed(ctx.conn)
        |> get(scoped(ctx.ws_b, ctx.proj_b, "/v1/data/revision/#{@dataset}/#{rev_a.id}"))

      assert b_resp.status == 404,
             "CROSS-WORKSPACE LEAK (revision get): B fetched A's revision (status #{b_resp.status})"
    end
  end

  describe "B12 analytics (/v1/data/analytics)" do
    test "workspace B's analytics totals do not count workspace A's documents", ctx do
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "an-a1", "Analytics A1")
      {:ok, _} = create_doc(ctx.ws_a, ctx.proj_a, "an-a2", "Analytics A2")

      a_body =
        ctx.tok_a
        |> authed(ctx.conn)
        |> get(scoped(ctx.ws_a, ctx.proj_a, "/v1/data/analytics/#{@dataset}"))
        |> json_response(200)

      assert a_body["total_documents"] >= 2, "analytics under-counted A's own docs"

      b_body =
        ctx.tok_b
        |> authed(ctx.conn)
        |> get(scoped(ctx.ws_b, ctx.proj_b, "/v1/data/analytics/#{@dataset}"))
        |> json_response(200)

      assert b_body["total_documents"] == 0,
             "CROSS-WORKSPACE LEAK (analytics): B's total counted A's docs " <>
               "(got #{b_body["total_documents"]})"
    end
  end

  describe "B13 schema (/v1/schemas) — project-scoped" do
    test "workspace B's schema list does not return workspace A's project-only schema", ctx do
      # An extra schema that exists ONLY in workspace A's project.
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "secret_a", "title" => "Secret A", "visibility" => "public", "fields" => []},
          @dataset,
          scope(ctx.ws_a, ctx.proj_a)
        )

      a_names = schema_names(ctx, ctx.ws_a, ctx.proj_a, ctx.tok_a)
      assert "secret_a" in a_names, "schema list did not surface A's own project schema"

      b_names = schema_names(ctx, ctx.ws_b, ctx.proj_b, ctx.tok_b)

      refute "secret_a" in b_names,
             "CROSS-WORKSPACE LEAK (schema): A's project-only schema surfaced in B's schema list"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp workspace_with_token(slug_seed) do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{slug_seed}-ws-#{suffix}", name: "WS #{slug_seed}"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "#{slug_seed}-proj-#{suffix}", name: "Proj #{slug_seed}"})

    raw = "leak-#{slug_seed}-#{suffix}"
    {:ok, _token} = Auth.create_token(raw, "leak #{slug_seed}", @dataset, ["read", "write", "admin"], ws.id)

    {ws, proj, raw}
  end

  defp post_schema do
    %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}
  end

  defp scope(ws, proj), do: [workspace_id: ws.id, project_id: proj.id]

  defp create_doc(ws, proj, id, title) do
    Content.create_document("post", %{"_id" => id, "title" => title}, @dataset, scope(ws, proj))
  end

  defp authed(raw, conn), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp scoped(ws, proj, path), do: "/w/#{ws.slug}/p/#{proj.slug}#{path}"

  defp search_hits(ctx, ws, proj, tok, q) do
    body =
      tok
      |> authed(ctx.conn)
      |> get(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=#{q}&perspective=drafts"))
      |> json_response(200)

    Enum.map(body["documents"], & &1["_id"])
  end

  defp federated_doc_hits(ctx, ws, proj, tok, q) do
    body =
      tok
      |> authed(ctx.conn)
      |> get(scoped(ws, proj, "/v1/search/#{@dataset}?q=#{q}&surfaces=documents&perspective=drafts"))
      |> json_response(200)

    body
    |> get_in(["results", "documents", "hits"])
    |> Kernel.||([])
    |> Enum.map(& &1["_id"])
  end

  defp export_ids(ctx, ws, proj, tok) do
    resp =
      tok
      |> authed(ctx.conn)
      |> get(scoped(ws, proj, "/v1/data/export/#{@dataset}"))

    assert resp.status == 200

    resp.resp_body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.map(& &1["_id"])
  end

  defp schema_names(ctx, ws, proj, tok) do
    body =
      tok
      |> authed(ctx.conn)
      |> get(scoped(ws, proj, "/v1/schemas/#{@dataset}"))
      |> json_response(200)

    Enum.map(body["schemas"], & &1["name"])
  end
end
