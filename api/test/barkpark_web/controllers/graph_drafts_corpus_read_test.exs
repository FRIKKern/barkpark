defmodule BarkparkWeb.GraphDraftsCorpusReadTest do
  @moduledoc """
  THE SLOW READ: `GET /v1/graph/:id?drafts=true` answered, but in 18.4 s
  (task `graph-endpoint-latency`).

  `graph_drafts_hang_test.exs` pinned the per-DOCUMENT round-trip and killed
  it. What it deliberately did NOT pin is the constant that remained, and its
  own comment names it: "the fixed drafts read pays a real constant — one
  corpus page per SCHEMA in the dataset". That constant is what this file pins,
  because it was not a constant at all.

  ## What the profile said

  `Content.Graph.build_drafts_index/1` read the corpus with
  `Content.collect_all_documents/3` ONCE PER SCHEMA, and that helper pages with
  `LIMIT/OFFSET` over a `DISTINCT ON (regexp_replace(doc_id, '^drafts\\.', ''))`
  subquery re-sorted by `updated_at DESC, id`. Neither sort key is indexed, so
  EVERY page re-sorted the ENTIRE type corpus twice, carrying the full
  `content` jsonb through the sort tuple, to return 1,000 rows.
  `EXPLAIN (ANALYZE, BUFFERS)` over an 8,000-document corpus, page 6 of 8:

      Limit  (actual time=70.158..70.255 rows=1000 loops=1)
        Buffers: shared hit=409, temp read=258 written=293
        ->  Sort  (actual time=69.764..70.122 rows=6000 loops=1)
              Sort Key: s0.updated_at DESC, s0.id
              Sort Method: external merge  Disk: 2336kB
              ->  Unique  (actual time=58.741..60.155 rows=8001 loops=1)
                    ->  Sort  (actual rows=8001) quicksort  Memory: 2747kB
                          ->  Index Scan using
                              documents_workspace_project_type_dataset_id_index

  8,001 rows sorted to return 1,000 — once per page, and once more per EMPTY
  schema. The whole request: 199 queries, 1,264 ms, of which 1,046 ms was those
  47 reads. LIVE on guerrilla the same request took 18.4 s (2026-09-10).

  So the cost was NOT N+1 (that was `task-051a87de9a085e4d`), NOT a missing
  index (the type index is used), and NOT a jsonb scan. It was an UNBOUNDED,
  RE-SORTED, PER-TYPE WHOLE-CORPUS READ: work quadratic in the corpus, times
  the number of schemas.

  After `Content.Query.collect_corpus_documents/3` — one bounded `DISTINCT ON`
  per ACL class, one sort, no outer re-sort, no offset walk — the same request
  is 13 queries and 474 ms on the same corpus.

  ## What is pinned here, and why it is the COUNT

  Two properties, both of which the old shape violated:

    1. a drafts graph request costs a BOUNDED number of round-trips, and
    2. that number does not grow with the number of SCHEMAS in the dataset.

  (2) is the discriminating one: it is exactly the per-type multiplication, and
  it is measurable without seeding a corpus big enough to blow a wall clock on
  a laptop. The clock is what the user feels but it is hardware; the count is
  exact and it is the quantity that grew.

  MUTATION PROOF (run 2026-09-10): restore the per-schema read in
  `build_drafts_index/1` (`Enum.map_reduce` over `schemas` calling
  `Content.collect_all_documents/3`) and the schema-slope test REDS with
  "20 more schemas added 20 queries"; restore the corpus read and it is green.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-graph-drafts-corpus-read"
  @dataset "production"

  # Schemas added between the two measurements. Under the per-type read each
  # one cost its own full corpus query even with ZERO documents in it.
  @extra_schemas 20

  # Slack on the comparison. Registering a schema legitimately perturbs a
  # cached read or two; what it must NOT do is add a corpus query apiece.
  @schema_slack 4

  # A drafts graph request is a fixed number of round-trips. The measured cost
  # after the fix is 13; the ceiling leaves room for an unrelated fixed read
  # without leaving room for a per-type or per-document one.
  @query_ceiling 30

  @test_timeout_ms 60_000

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@token, "graph-drafts-corpus-read", @dataset, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} = upsert_ref_schema!("post", scope)

    %{scope: scope}
  end

  defp upsert_ref_schema!(name, scope) do
    Content.upsert_schema(
      %{
        "name" => name,
        "title" => String.capitalize(name),
        "visibility" => "public",
        "fields" => [%{"name" => "related", "type" => "reference", "refType" => "post"}]
      },
      @dataset,
      scope
    )
  end

  defp bearer(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_draft_only!(doc_id, scope, content) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp seed_corpus!(n, scope) do
    root = uniq("corpus-read-root")
    mk_draft_only!(root, scope, %{"related" => root})
    for _ <- 1..n, do: mk_draft_only!(uniq("corpus-read-filler"), scope, %{"related" => root})
    root
  end

  # Count Repo queries issued while `fun` runs, in THIS process. ConnCase is
  # single-process, so the process filter keeps a concurrent test out of the
  # count.
  defp with_query_count(fun) do
    me = self()
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _e, _m, _meta, _cfg -> if self() == me, do: :counters.add(counter, 1, 1) end,
      nil
    )

    try do
      {micros, result} = :timer.tc(fun)
      {result, :counters.get(counter, 1), div(micros, 1000)}
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "GET /v1/graph/:id?drafts=true reads the corpus in a bounded number of queries" do
    @tag timeout: @test_timeout_ms
    test "adding SCHEMAS does not add queries", %{conn: conn, scope: scope} do
      root = seed_corpus!(40, scope)

      {before_resp, q_before, ms_before} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert before_resp.status == 200, before_resp.resp_body

      # EMPTY types — not one extra document, only extra schemas. Under the
      # per-type read each one still cost a full corpus query.
      for _ <- 1..@extra_schemas, do: {:ok, _} = upsert_ref_schema!(uniq("cr_type"), scope)

      {after_resp, q_after, ms_after} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert after_resp.status == 200, after_resp.resp_body

      assert q_after <= q_before + @schema_slack,
             "GET /v1/graph/:id?drafts=true issued #{q_before} queries (#{ms_before}ms) and " <>
               "#{q_after} (#{ms_after}ms) after #{@extra_schemas} EMPTY schemas were added — " <>
               "the read is still PER TYPE. Content.Graph.build_drafts_index/1 must read the " <>
               "corpus with Content.collect_corpus_documents/3 (one bounded DISTINCT ON per " <>
               "ACL class), not once per schema: the per-type read re-sorted the whole corpus " <>
               "for every type and every page, which is what made this request take 18.4s on " <>
               "guerrilla (task graph-endpoint-latency)."
    end

    @tag timeout: @test_timeout_ms
    test "the whole request stays under the round-trip ceiling", %{conn: conn, scope: scope} do
      root = seed_corpus!(40, scope)

      {resp, queries, ms} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert resp.status == 200, resp.resp_body

      assert queries <= @query_ceiling,
             "GET /v1/graph/:id?drafts=true issued #{queries} queries (#{ms}ms) — over the " <>
               "#{@query_ceiling} round-trip ceiling. A graph read is a CONSTANT number of " <>
               "queries; a count that drifts above this is a per-type or per-document read " <>
               "that came back."
    end

    @tag timeout: @test_timeout_ms
    test "the corpus read still sees the whole corpus — edges and phantoms unchanged",
         %{conn: conn, scope: scope} do
      # The bound above must not be met by reading LESS. Two draft-only docs,
      # one referencing the other: the edge must survive, and the published-lens
      # phantom for the draft-only target must survive with it.
      target = uniq("corpus-read-target")
      mk_draft_only!(target, scope, %{})

      source = uniq("corpus-read-source")
      mk_draft_only!(source, scope, %{"related" => target})

      resp = conn |> bearer() |> get("/v1/graph/#{source}?drafts=true")
      assert resp.status == 200, resp.resp_body
      body = Jason.decode!(resp.resp_body)

      assert body["root"] == source

      assert Enum.any?(body["edges"], fn e ->
               e["from_id"] == source and e["to_id"] == target and e["kind"] == "related"
             end),
             "the corpus read lost the draft->draft `related` edge: #{resp.resp_body}"

      assert Enum.any?(body["nodes"], fn n ->
               n["phantom"] == true and n["broken_id"] == target and n["via_field"] == "related"
             end),
             "the corpus read changed the :published dangling lens: #{resp.resp_body}"
    end

    @tag timeout: @test_timeout_ms
    test "two types sharing one doc_id contribute BOTH their edges", %{conn: conn, scope: scope} do
      # THE IDENTITY LEG. Row identity is (doc_id, type, dataset_id), so the
      # single-query corpus read MUST distinct on (type, slug). Distinct-ing on
      # the slug alone collapses a `post` and an `article` that share a doc_id
      # into ONE row — one of the two documents silently missing from the fold,
      # and every edge IT owns gone with it.
      #
      # Asserting the edge INTO the shared slug would not see that: that edge is
      # extracted from the SOURCE's content and survives either way. What only
      # the surviving row can produce is its OWN outbound edge — so give the two
      # rows DIFFERENT targets and demand both. Which row a collapse would keep
      # is arbitrary; requiring both reds on either.
      {:ok, _} = upsert_ref_schema!("article", scope)

      shared = uniq("corpus-read-shared")
      post_target = uniq("corpus-read-target-post")
      article_target = uniq("corpus-read-target-article")

      # PUBLISHED, both of them. A core edge's `dangling` is decided under the
      # :published lens, and the BFS does not expand a dangling target — so a
      # draft-only `shared` would render as a phantom and NEITHER row's out-edge
      # would appear, which would make this test red for a reason that is not
      # the identity leg.
      mk_draft_only!(shared, scope, %{"related" => post_target})
      {:ok, _} = Content.publish_document(shared, "post", @dataset, scope)

      {:ok, _} =
        Content.create_document(
          "article",
          %{"doc_id" => shared, "title" => shared, "content" => %{"related" => article_target}},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(shared, "article", @dataset, scope)

      source = uniq("corpus-read-twin-source")
      mk_draft_only!(source, scope, %{"related" => shared})

      resp = conn |> bearer() |> get("/v1/graph/#{source}?drafts=true")
      assert resp.status == 200, resp.resp_body

      body = Jason.decode!(resp.resp_body)
      targets = for e <- body["edges"], e["from_id"] == shared, do: e["to_id"]

      assert post_target in targets and article_target in targets,
             "the doc_id shared by two types contributed only #{inspect(targets)} — the corpus " <>
               "read collapsed the two rows into one. DISTINCT ON must carry `type` as well " <>
               "as the slug: row identity is (doc_id, type, dataset_id), and a document " <>
               "dropped from the fold takes every edge it owns with it (and turns real " <>
               "references into phantoms). Body: #{resp.resp_body}"
    end
  end
end
