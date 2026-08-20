defmodule Barkpark.Search.QueryPipelineTest do
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Search.{QueryParser, QueryPipeline, SurfaceConfigs}

  setup do
    SurfaceConfigs.seed_defaults!()

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "pipeline"
    )

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      "pipeline"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.p1", "title" => "Elixir Phoenix Guide"},
      "pipeline"
    )

    Content.create_document(
      "author",
      %{"doc_id" => "drafts.p2", "title" => "Phoenix Wright"},
      "pipeline"
    )

    Content.publish_document("p1", "post", "pipeline")
    Content.publish_document("p2", "author", "pipeline")
    :ok
  end

  test "search returns hits with parsed query metadata" do
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    assert result.total == 2
    assert length(result.hits) == 2
    assert result.parsed[:terms] == ["phoenix"]
    assert is_map(result.highlights)
  end

  test "exclude token removes matching documents" do
    context = %{query: "phoenix -wright", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    ids = Enum.map(result.hits, & &1.doc_id)
    assert "p1" in ids
    refute "p2" in ids
    assert result.total == 1
  end

  test "drop_tokens recovery on zero-hit query" do
    context = %{query: "zzzznomatch extra", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    assert result.recovery in [nil, "drop_tokens", "typo_widen"]
  end

  # ── engine_used: which retriever ACTUALLY served (charter D66) ──────────
  #
  # The client heuristic guessing this shipped dead code twice — the pipeline
  # is the only place that knows. Indx is UNREGISTERED-equivalent in test (no
  # live dataset pointer), so Indx.Retriever degrades to {[], 0, %{}} without
  # throwing — exactly the silent substitution the field must expose.

  test "engine_used is postgres for a plain postgres search" do
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    assert result.engine_used == "postgres"
    assert result.total == 2
  end

  test "engine_used is postgres when indx is requested without a tenant scope (D3-b gate)" do
    # No binary workspace_id ⇒ the non-postgres engine cannot prove tenant
    # scope and the pipeline substitutes the Postgres retriever outright.
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10,
               engine: "indx"
             )

    assert result.engine_used == "postgres"
    assert result.total == 2
  end

  # Workspace-scoped fixture: a binary workspace_id is what lets a non-postgres
  # engine past the D3-b gate, and the postgres scope is fail-closed, so the
  # doc must live IN that workspace for the recovery pass to find it.
  defp indx_scope_with_doc do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    # These searches carry NO caller_context (anonymous), and the W10
    # schema-visibility gate (stw10-search-visibility-leak) restricts anonymous
    # hits to PUBLIC schema types IN THE CALLER'S TENANT SCOPE — the setup's
    # nil-scope "post" row is invisible here. Seed the scoped public row every
    # live searchable type has, keeping the gate active through the recovery
    # assertions below.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "pipeline",
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "indx-ws-hit", "title" => "Phoenix Guide"},
        "pipeline",
        scope
      )

    scope
  end

  test "engine_used reports postgres when the zero-hit recovery silently re-runs an indx query" do
    # With a tenant scope the Indx retriever runs for real — and, with no live
    # dataset, degrades to zero hits WITHOUT throwing. The recovery pass
    # re-runs on Postgres (relaxed) and finds the doc, so the served answer is
    # postgres wearing an indx request — engine_used must say so.
    scope = indx_scope_with_doc()
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search(
               "documents",
               "pipeline",
               context,
               [perspective: :raw, limit: 10, engine: "indx"] ++ scope
             )

    assert result.total > 0
    assert result.recovery != nil
    assert result.engine_used == "postgres"
  end

  test "engine_used stays indx when the indx retriever served the (empty) final answer" do
    # A query nothing matches even relaxed: recovery finds nothing, so the
    # primary (indx) retriever's empty result IS the served answer.
    scope = indx_scope_with_doc()
    context = %{query: "zzzznomatchxyzzy", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search(
               "documents",
               "pipeline",
               context,
               [perspective: :raw, limit: 10, engine: "indx"] ++ scope
             )

    assert result.total == 0
    assert result.engine_used == "indx"
  end

  test "engine_used threads through Content.search_documents meta into the hit envelope" do
    {docs, count, meta} =
      Barkpark.Content.search_documents("phoenix", "pipeline",
        perspective: :published,
        limit: 10
      )

    assert meta[:engine_used] == "postgres"

    envelope =
      Barkpark.Search.HitEnvelope.build(docs, count, "phoenix", meta,
        caller_context: nil,
        schema_resolver: fn _type -> nil end
      )

    assert envelope.engineUsed == "postgres"
  end

  test "media_recovery delegates to search_fn" do
    parsed = QueryParser.parse("onlyterm extra")
    config = SurfaceConfigs.default_for("media")

    {hits, total, recovery} =
      QueryPipeline.media_recovery(parsed, config, fn p, _relaxed ->
        terms = p.terms ++ p.phrases
        if length(terms) >= 1, do: {[:hit], 1}, else: {[], 0}
      end)

    assert total == 1
    assert hits == [:hit]
    assert recovery in [nil, "drop_tokens"]
  end
end
