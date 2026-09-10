defmodule BarkparkWeb.GraphDraftsHangTest do
  @moduledoc """
  THE NON-RETURNING READ: `GET /v1/graph/:id?drafts=true` (task-051a87de9a085e4d).

  MEASURED ON GUERRILLA 2026-09-10 (commit 7406e9fbb), read/write/admin bearer:

      GET /v1/graph/zz-definitely-absent-27153              -> 404 in 0.07 s
      GET /v1/graph/zz-definitely-absent-6506?drafts=true   -> 404 in 0.07 s
      GET /v1/graph/gh-9531                                 -> 404 in 0.07 s
      GET /v1/graph/gh-9531?drafts=true                     -> curl exit 28 (>25 s)
      GET /v1/graph/gh-9531?drafts=true&depth=1             -> curl exit 28 (>30 s)
      GET /v1/graph/gh-9531?drafts=true&dataset=zzz-nope    -> 404 in 0.10 s

  Those six probes name the mechanism between them:

    * a TRULY absent id answers 404 in 70 ms UNDER `?drafts=true` — so nothing
      before `resolve_graph_root/2` is slow, and the hang is not the
      perspective-widened root query. (`gh-9531` is not absent: it is the
      DRAFT-ONLY id from the graph_draft_leak repro, so the drafts perspective
      resolves a root and enters the traversal that the published perspective
      404s out of.)
    * `depth=1` hangs identically — so the cost is NOT the BFS. Every bound the
      drafts walk owns (`@node_budget`, `@fan_out`, depth) sits DOWNSTREAM of
      the cost.
    * prod carries a pool-wide `statement_timeout: "30s"` (see `Barkpark.Repo`'s
      moduledoc), and a >70 s request never 500s — so it is NOT one unbounded
      statement either. It is MANY small statements.

  THE COST: `Content.Graph.build_drafts_index/1` folds the WHOLE drafts corpus
  of the dataset and calls `Content.extract_edges/2` once per document with the
  bare traversal opts — no `:schemas` prefetch and the default `dangling:
  :resolve`. `Content.Edges.extract_edges/2` documents both round-trips as the
  ones a corpus fold must hoist:

    * `:schemas` absent -> `Content.list_schemas(dataset, opts)` PER DOCUMENT
      ("a 4096-document corpus issued 4096 identical schema queries … measured
      live: a 34s first paint"),
    * `dangling: :resolve` -> "ONE un-batched DB round-trip per reference value
      per document".

  So one `?drafts=true` request costs O(corpus documents + corpus reference
  values) SERIAL queries on ONE pooled connection, independent of the root, the
  depth and the node budget. On a corpus of guerrilla's size that is minutes.

  THE PIN BELOW is the query COUNT, not the clock: the clock is what the user
  sees but it is hardware, and a corpus big enough to blow a wall-clock budget
  on a laptop is a corpus too big to seed in a test. The count is exact and it
  is the quantity that grows with the corpus. Each test also carries an ExUnit
  `timeout:` so a genuine non-return REDS the test instead of wedging the suite.

  MUTATION PROOF: revert `build_drafts_index/1`'s prefetch (drop the `:schemas`
  and `:dangling` opts it now threads into `drafts_edges_for_doc/3`) and
  "the drafts index is built with a BOUNDED number of queries" reds with a count
  that scales with @corpus_size; restore and it is green.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-graph-drafts-hang"
  @dataset "production"

  # Big enough that an O(corpus) query storm is unmistakable next to the
  # constant the fixed path pays, small enough to seed in a couple of seconds.
  @corpus_size 120

  # The bound. The fixed drafts index pays a fixed handful of reads (token,
  # scope, schema list, one page per schema type, the root lookup) plus the
  # per-type corpus pages — never a per-DOCUMENT read. 60 leaves generous room
  # for the fixed prelude while staying far below @corpus_size.
  @query_budget 60

  # Wall-clock ceiling for the whole request, and the ExUnit timeout that makes
  # a genuine non-return a RED rather than a wedged suite.
  @test_timeout_ms 30_000

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@token, "graph-drafts-hang", @dataset, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # A reference field, so `extract_edges/2` has an edge to extract and (on the
    # unfixed path) a target existence query to issue per document.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "related", "type" => "reference", "refType" => "post"}
          ]
        },
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp bearer(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A draft-only doc — created, never published; its only row is the
  # `drafts.<id>` twin, the shape of the live `gh-9531` repro.
  defp mk_draft_only!(doc_id, scope, content \\ %{}) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Seed a drafts corpus whose documents each carry one reference — the shape
  # that makes the per-document dangling round-trip fire.
  defp seed_corpus!(n, scope) do
    root = uniq("drafts-hang-root")
    mk_draft_only!(root, scope, %{"related" => root})

    for i <- 1..n do
      mk_draft_only!(uniq("drafts-hang-filler-#{i}"), scope, %{"related" => root})
    end

    root
  end

  # Count Repo queries issued while `fun` runs, in THIS process (ConnCase is
  # single-process, so the handler's process filter keeps a concurrently running
  # test out of the count).
  defp with_query_count(fun) do
    me = self()
    ref = make_ref()
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measure, _meta, _cfg ->
        if self() == me, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      {micros, result} = :timer.tc(fun)
      {result, :counters.get(counter, 1), div(micros, 1000)}
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "GET /v1/graph/:id at the drafts perspective terminates in bounded work" do
    @tag timeout: @test_timeout_ms
    test "the drafts index is built with a BOUNDED number of queries (?drafts=true)",
         %{conn: conn, scope: scope} do
      root = seed_corpus!(@corpus_size, scope)

      {resp, queries, ms} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert resp.status == 200,
             "?drafts=true on a #{@corpus_size}-document drafts corpus answered " <>
               "#{resp.status}: #{resp.resp_body}"

      assert queries <= @query_budget,
             "GET /v1/graph/:id?drafts=true issued #{queries} queries over a " <>
               "#{@corpus_size}-document drafts corpus (budget #{@query_budget}, took #{ms}ms). " <>
               "The drafts fold is paying a PER-DOCUMENT round-trip — " <>
               "Content.Graph.build_drafts_index/1 is not hoisting the schema list " <>
               "and/or is resolving dangling per reference value. That is the shape " <>
               "that makes this request never return on a production-sized corpus " <>
               "(task-051a87de9a085e4d)."
    end

    @tag timeout: @test_timeout_ms
    test "the same bound holds for the ?perspective=drafts spelling",
         %{conn: conn, scope: scope} do
      root = seed_corpus!(@corpus_size, scope)

      {resp, queries, ms} =
        with_query_count(fn ->
          conn |> bearer() |> get("/v1/graph/#{root}?perspective=drafts")
        end)

      assert resp.status == 200,
             "?perspective=drafts answered #{resp.status}: #{resp.resp_body}"

      assert queries <= @query_budget,
             "?perspective=drafts issued #{queries} queries over a #{@corpus_size}-document " <>
               "drafts corpus (budget #{@query_budget}, took #{ms}ms) — the two spellings " <>
               "reach the same fold, so they must carry the same bound."
    end

    @tag timeout: @test_timeout_ms
    test "an ABSENT id 404s at the drafts perspective without touching the corpus fold",
         %{conn: conn, scope: scope} do
      # The control the live probes supply: on guerrilla a truly absent id
      # answers 404 in 70ms UNDER ?drafts=true. If that ever starts paying the
      # fold, the 404 arm has moved BELOW the traversal.
      seed_corpus!(@corpus_size, scope)
      absent = uniq("drafts-hang-absent")

      {resp, queries, ms} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{absent}?drafts=true") end)

      assert resp.status == 404,
             "an absent id answered #{resp.status} at ?drafts=true: #{resp.resp_body}"

      assert queries <= @query_budget,
             "an ABSENT id at ?drafts=true issued #{queries} queries (budget " <>
               "#{@query_budget}, #{ms}ms) — the 404 must be decided before the " <>
               "corpus fold, never after it."
    end

    @tag timeout: @test_timeout_ms
    test "the drafts response is still a correct graph — never a 500, never empty",
         %{conn: conn, scope: scope} do
      # Two draft-only docs, one referencing the other: the drafts graph must
      # still SEE that edge after the prefetch, so the bound above cannot be met
      # by simply extracting nothing.
      target = uniq("drafts-hang-target")
      mk_draft_only!(target, scope)

      source = uniq("drafts-hang-source")
      mk_draft_only!(source, scope, %{"related" => target})

      resp = conn |> bearer() |> get("/v1/graph/#{source}?drafts=true")

      assert resp.status == 200, resp.resp_body
      body = Jason.decode!(resp.resp_body)

      assert body["root"] == source

      assert Enum.any?(body["edges"], fn e ->
               e["from_id"] == source and e["to_id"] == target and e["kind"] == "related"
             end),
             "the drafts graph lost the draft->draft `related` edge: #{resp.resp_body}"

      assert Enum.any?(body["nodes"], fn n -> n["id"] == target end),
             "the drafts graph did not reach the referenced draft node: #{resp.resp_body}"
    end
  end
end
