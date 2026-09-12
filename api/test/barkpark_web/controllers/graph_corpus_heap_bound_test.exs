defmodule BarkparkWeb.GraphCorpusHeapBoundTest do
  @moduledoc """
  `/v1/graph` derives the corpus ONE TYPE AT A TIME — the peak-heap bound.

  WHAT THIS MEASURES AND WHY IT IS NOT A LATENCY TEST. `derive_graph_corpus/2`
  read every type's published documents into a `doc_lists` list and held that
  list live across the whole derivation (the edge phase zipped over it, and the
  budget + Jason phases ran after that). Every document carries its full decoded
  `content` map; the response keeps four fields per node. So the request process
  held the ENTIRE published corpus resident while it built and encoded a
  response two orders of magnitude smaller.

  Measured from outside the BEAM on guerrilla (dr-bl-w9): three natural
  /v1/graph calls moved beam.smp RSS +684 MB / +568 MB / +646 MB off a
  403-446 MB idle floor on a 3,819 MB box, and both OOM kills in that window
  shot beam.smp itself. #10016's `dangling: :skip` deleted the per-reference
  existence round trips — the POOL-TIMEOUT story — and changed none of this.

  THE ASSERTION IS ON THE REQUEST PROCESS'S PEAK HEAP, not on RSS: RSS is the
  whole VM and is not attributable to one call inside a test. `Phoenix.ConnTest`
  dispatches the endpoint IN THE CALLER, so the test process's heap IS the
  derivation's heap, and a sampler process polls it while the request runs.

  THE DISCRIMINATOR IS SHAPE, NOT SIZE. The corpus below is @types types of
  @docs_per_type documents each. Holding every type at once costs
  @types x (one type's documents); holding one at a time costs one type's
  documents plus the projected nodes. The ceiling asserted here sits between
  those two, so it cannot pass by accident on a fast machine or a small heap.

  RED-WITHOUT PROOF (rerun it before trusting this file): restore the
  `{doc_lists, per_type_capped} = Enum.map_reduce(...)` phase in
  `BarkparkWeb.TasksController.derive_graph_corpus/2` and this test fails with a
  peak several times the ceiling. The measured numbers are in the PR body.
  """

  use BarkparkWeb.ConnCase, async: false

  # The fixture publishes @types x @docs_per_type documents and the derivation
  # then walks all of them; on a loaded shared test database that is well past
  # ExUnit's 60s default AND past the sandbox's ownership ceiling — the second
  # one surfaces as a DBConnection.OwnershipError mid-derivation, not as a
  # timeout. Both are fixture cost, not a slow assertion.
  @moduletag timeout: 300_000
  @moduletag ownership_timeout: 300_000

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @admin_token "barkpark-test-graph-heap-admin"
  @dataset "production"

  # 12 types x 40 documents. The per-type cap is 1000 and the node budget 2000,
  # so 320 nodes trips neither — this test measures the derivation, not the
  # truncation passes.
  @types 12
  @docs_per_type 40

  # Each document's content is a map of many SMALL values. Small binaries live
  # ON the process heap; a single large binary would be refcounted OFF it and
  # `process_info(:memory)` would not see the corpus at all — which is exactly
  # how this test could have been vacuous.
  @fields_per_doc 120

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@admin_token, "graph-heap-admin", @dataset, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    types =
      for i <- 1..@types do
        name = "heapt#{i}"

        {:ok, _} =
          Content.upsert_schema(
            %{"name" => name, "title" => "Heap #{i}", "visibility" => "public", "fields" => []},
            @dataset,
            scope
          )

        name
      end

    for type <- types, n <- 1..@docs_per_type do
      doc_id = "#{type}-#{n}"

      content =
        for f <- 1..@fields_per_doc, into: %{} do
          {"f#{f}", "v#{f}-#{doc_id}-padpadpadpadpadpadpadpad"}
        end

      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => doc_id, "title" => "T-#{doc_id}", "content" => content},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(doc_id, type, @dataset, scope)
    end

    %{scope: scope, types: types}
  end

  # Poll the target's :memory (heap + stack + unreclaimed garbage) until told to
  # stop, and report the maximum seen.
  defp sample_peak(target, fun) do
    parent = self()

    sampler =
      spawn(fn ->
        loop = fn loop, peak ->
          receive do
            {:stop, from} -> send(from, {:peak, peak})
          after
            0 ->
              peak =
                case :erlang.process_info(target, :memory) do
                  {:memory, m} -> max(peak, m)
                  _ -> peak
                end

              Process.sleep(1)
              loop.(loop, peak)
          end
        end

        send(parent, :sampling)
        loop.(loop, 0)
      end)

    receive do
      :sampling -> :ok
    after
      1_000 -> flunk("sampler never started")
    end

    result = fun.()
    send(sampler, {:stop, self()})

    peak =
      receive do
        {:peak, p} -> p
      after
        5_000 -> flunk("sampler never reported")
      end

    {result, peak}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "the corpus derivation's peak heap is bounded by ONE type, not the corpus", %{
    conn: conn,
    scope: scope
  } do
    # The control: one type's documents, decoded, as the fold sees them. This is
    # measured, not guessed, so the ceiling below is derived from the machine
    # this test runs on rather than from a constant someone tuned once.
    :erlang.garbage_collect()
    {:memory, before_mem} = :erlang.process_info(self(), :memory)

    one_type_docs =
      Content.list_documents(
        "heapt1",
        @dataset,
        [limit: 1000, perspective: :published] ++ scope
      )

    # Collect while `one_type_docs` is still LIVE — the assert BELOW is what
    # keeps it live across the collect, so this is the RETAINED cost of one
    # type's documents and not decode garbage a GC would drop. Reorder those two
    # lines and the compiler drops the binding at the collect and the cost reads
    # ZERO; the > 100_000 guard is what caught exactly that.
    :erlang.garbage_collect()
    {:memory, with_one_type} = :erlang.process_info(self(), :memory)
    one_type_cost = with_one_type - before_mem

    assert length(one_type_docs) == @docs_per_type,
           "fixture did not publish #{@docs_per_type} documents — the ceiling would be nonsense"

    assert one_type_cost > 100_000,
           "one type's documents cost only #{one_type_cost} bytes of heap — the fixture is too " <>
             "small for this test to discriminate anything"

    :erlang.garbage_collect()
    {:memory, baseline} = :erlang.process_info(self(), :memory)

    {resp, peak} =
      sample_peak(self(), fn -> conn |> bearer(@admin_token) |> get("/v1/graph") end)

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["ok"] == true

    nodes = body["nodes"]

    assert length(nodes) >= @types * @docs_per_type,
           "the response is missing nodes — a cheap derivation that lost documents is not a fix"

    growth = peak - baseline

    IO.puts(
      "graph-heap-bound: one_type_cost=#{one_type_cost} baseline=#{baseline} peak=#{peak} " <>
        "growth=#{growth} nodes=#{length(nodes)} ratio=#{Float.round(growth / one_type_cost, 2)}"
    )

    # The ceiling: FIVE times one type's retained documents. CALIBRATED, not
    # picked — on this fixture, with `one_type_cost` reading an identical
    # 969,280 B on both sides, origin/main grows 11,188,584 B (11.54x) and this
    # branch grows 2,547,816 B (2.63x). 5x sits between them with ~2x margin in
    # each direction for scheduler and allocator churn. If you widen the
    # fixture, RE-CALIBRATE: a ceiling that both sides satisfy is not a test.
    ceiling = one_type_cost * 5

    assert growth < ceiling,
           """
           /v1/graph's peak process heap grew #{growth} bytes over a #{baseline}-byte baseline.
           One type's documents cost #{one_type_cost} bytes; the ceiling is #{ceiling}
           (#{@types} types, so materialising all of them costs at least #{@types * one_type_cost}).
           A growth at or above the ceiling means the derivation is holding more than one
           type's documents at a time — the corpus is materialised in the request heap again.
           """
  end
end
