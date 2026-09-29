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

  MUTATION PROOF: revert `build_drafts_index/1`'s two hoists (drop the `:schemas`
  and `dangling: :skip` opts it now threads into `drafts_edges_for_doc/3`, and the
  `resolve_core_dangling/3` pass) and both slope tests below red with a count that
  scales with the corpus; restore and they are green.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-graph-drafts-hang"
  @dataset "production"

  # THE MEASUREMENT IS A SLOPE, NOT A CEILING. The fixed drafts read pays a real
  # constant — one corpus page per SCHEMA in the dataset, and the test env
  # registers ~160 of them — so any absolute budget here would be a number about
  # the fixture roster, not about this defect. What the defect IS, exactly, is a
  # per-DOCUMENT round-trip: the same request over a corpus 4x larger must cost
  # the SAME queries. Measure both, compare.
  @corpus_small 60
  @corpus_large 240

  # Slack on the comparison. The two reads are the same shape, so the honest
  # expectation is equality; a handful of queries of headroom keeps an unrelated
  # fixed-cost read (a cache miss, a schema registration) from flapping the pin
  # while still being ~1/50th of the growth the unfixed path shows.
  @slope_slack 10

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
    add_fillers!(n, root, scope)
    root
  end

  defp add_fillers!(n, root, scope) when n > 0 do
    for _ <- 1..n, do: mk_draft_only!(uniq("drafts-hang-filler"), scope, %{"related" => root})
    :ok
  end

  defp add_fillers!(_n, _root, _scope), do: :ok

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
    test "?drafts=true costs the SAME queries on a 4x larger drafts corpus",
         %{conn: conn, scope: scope} do
      root = seed_corpus!(@corpus_small, scope)

      {resp_small, q_small, ms_small} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert resp_small.status == 200,
             "?drafts=true answered #{resp_small.status}: #{resp_small.resp_body}"

      # Same dataset, same root — only the corpus around it grows.
      add_fillers!(@corpus_large - @corpus_small, root, scope)

      {resp_large, q_large, ms_large} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert resp_large.status == 200,
             "?drafts=true answered #{resp_large.status} on the larger corpus: " <>
               resp_large.resp_body

      assert q_large <= q_small + @slope_slack,
             "GET /v1/graph/:id?drafts=true issued #{q_small} queries over " <>
               "#{@corpus_small} drafts documents (#{ms_small}ms) and #{q_large} over " <>
               "#{@corpus_large} (#{ms_large}ms) — the cost GROWS WITH THE CORPUS. " <>
               "Content.Graph.build_drafts_index/1 folds the WHOLE dataset corpus on " <>
               "every drafts request, so a per-document round-trip there is bounded by " <>
               "nothing the endpoint owns: not depth, not @node_budget, not @fan_out. " <>
               "That is why this request stopped returning at all on guerrilla " <>
               "(task-051a87de9a085e4d)."
    end

    @tag timeout: @test_timeout_ms
    test "the ?perspective=drafts spelling carries the SAME slope",
         %{conn: conn, scope: scope} do
      root = seed_corpus!(@corpus_small, scope)

      {resp_small, q_small, _} =
        with_query_count(fn ->
          conn |> bearer() |> get("/v1/graph/#{root}?perspective=drafts")
        end)

      assert resp_small.status == 200, resp_small.resp_body

      add_fillers!(@corpus_large - @corpus_small, root, scope)

      {resp_large, q_large, _} =
        with_query_count(fn ->
          conn |> bearer() |> get("/v1/graph/#{root}?perspective=drafts")
        end)

      assert resp_large.status == 200, resp_large.resp_body

      assert q_large <= q_small + @slope_slack,
             "?perspective=drafts issued #{q_small} queries over #{@corpus_small} drafts " <>
               "documents and #{q_large} over #{@corpus_large} — the two spellings reach " <>
               "the same fold, so they must carry the same slope."
    end

    @tag timeout: @test_timeout_ms
    test "an ABSENT id 404s at the drafts perspective without touching the corpus fold",
         %{conn: conn, scope: scope} do
      # The control the live probes supply: on guerrilla a truly absent id
      # answers 404 in 70ms UNDER ?drafts=true. If that ever starts paying the
      # fold, the 404 arm has moved BELOW the traversal.
      root = seed_corpus!(@corpus_small, scope)
      absent = uniq("drafts-hang-absent")

      {resp, q_absent, ms} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{absent}?drafts=true") end)

      assert resp.status == 404,
             "an absent id answered #{resp.status} at ?drafts=true: #{resp.resp_body}"

      {_present, q_present, _} =
        with_query_count(fn -> conn |> bearer() |> get("/v1/graph/#{root}?drafts=true") end)

      assert q_absent < q_present,
             "an ABSENT id at ?drafts=true issued #{q_absent} queries (#{ms}ms) — as many " <>
               "as the resolving root's #{q_present}. The 404 must be decided BEFORE the " <>
               "corpus fold, never after it; that ordering is what makes an absent id " <>
               "answer in 70ms on guerrilla while a resolving one does not answer at all."
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

      # THE PRESERVED SEMANTIC, PINNED SO THE FIX CANNOT MOVE IT. A core edge's
      # `dangling` is resolved under the :published lens (Content.Edges'
      # `resolve_target_existence/4`, and the gap-#2 contract in its comment), so
      # a DRAFT-ONLY target renders as a PHANTOM even on a drafts graph. That is
      # today's behaviour and the batched pass reproduces it exactly — batching
      # removes round-trips, it does not change the lens.
      assert Enum.any?(body["nodes"], fn n ->
               n["phantom"] == true and n["broken_id"] == target and n["via_field"] == "related"
             end),
             "the drafts graph lost the phantom for the draft-only target — the " <>
               "batched dangling pass changed the :published lens: #{resp.resp_body}"
    end
  end
end
