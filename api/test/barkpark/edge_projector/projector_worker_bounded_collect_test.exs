defmodule Barkpark.EdgeProjector.ProjectorWorkerBoundedCollectTest do
  @moduledoc """
  The rebuild's corpus collection must cost a BOUNDED number of database
  reads, not one read per OFFSET page.

  THE DEFECT. `ProjectorWorker.run_rebuild_scoped/4` collected its corpus with
  `Content.collect_all_documents/3` once per type — a `LIMIT/OFFSET` page walk
  at page_size 1000, max_pages 50, i.e. up to 50 SEPARATE connection checkouts
  per type per attempt, each at Ecto's unconfigured 15,000 ms checkout deadline
  (queue time included), and each page re-sorting the whole type partition (no
  `documents` index carries `updated_at`). That pre-transaction region is where
  the live `client (…ProjectorWorker) timed out because it queued and checked
  out the connection for longer than 15000ms` disconnect landed.

  THE FIX. `Content.collect_corpus_documents/3` — ONE bounded `DISTINCT ON`
  read per ACL class (at most two: owner-scoped and not).

  Both arms below drive the REAL `Content` against a REAL corpus. The CONTROL
  is not a story about the old code: `WalkOnlyContent` is a content seam that
  exports `collect_all_documents/3` and NOT `collect_corpus_documents/3`, so
  the worker takes its page-walk branch — the old collector, measured in the
  same test, on the same fixtures, by the same counter.
  """

  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Content
  alias Barkpark.EdgeProjector.{Projector, ProjectorWorker}
  alias Barkpark.Plugins.Registry

  @dataset "bounded_collect_test"

  # The OLD collector, reachable through the documented `"content"` seam: it
  # exports ONLY the per-type page walk, so `collect_corpus/4` falls back to
  # `page_walk_collect/4`. Everything else is the real `Content`.
  defmodule WalkOnlyContent do
    @moduledoc false
    defdelegate collect_all_documents(type, dataset, opts), to: Barkpark.Content
    defdelegate get_document(id, type, dataset, opts), to: Barkpark.Content
    defdelegate owner_scoped?(type, dataset, opts), to: Barkpark.Content
  end

  # Counts docs only; performs no writes, so the only reads a rebuild issues
  # are the collection reads (plus the constant per-type schema/hydrate reads).
  defmodule FakeProjectorOk do
    @moduledoc false
    def rebuild_scope(_scope, docs, _opts), do: {:ok, %{added: length(docs), deleted: 0}}
  end

  # Captures the documents the collector handed the projector and projects the
  # REAL edge fan-out over them (core reference fields UNION plugin edges via
  # the `:edge_extractor_collector` seam).
  defmodule CaptureProjector do
    @moduledoc false
    def rebuild_scope(scope, docs, opts) do
      {:ok, %{edges: edges}} = Projector.project(scope, docs, opts)
      send(:bounded_collect_probe, {:edges, edges})
      {:ok, %{added: length(edges), deleted: 0}}
    end
  end

  # A plugin edge extractor — the PLUGIN half of the c1 corpus. Drives the
  # resolver form the collector seam fans out to.
  defmodule FakeEdgePlugin do
    @moduledoc false
    def name, do: "fake_edges"

    def resolve_extract_edges(prev, ctx) do
      case Map.get(ctx, :doc) do
        nil ->
          prev

        doc ->
          from = Content.published_id(Map.get(doc, :doc_id) || Map.get(doc, "doc_id"))
          prev ++ [%{from_id: from, to_id: "auth-1", kind: "related-to", plugin_source: "fake"}]
      end
    end
  end

  setup do
    prev_plugins = Barkpark.PluginEnv.capture()
    Application.delete_env(:barkpark, :plugins)

    on_exit(fn ->
      Registry.reset()

      Barkpark.PluginEnv.restore(prev_plugins)
    end)

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [%{"name" => "author", "type" => "reference", "refType" => "author"}]
      },
      @dataset
    )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp seed_articles!(range) do
    for n <- range, do: publish!("article", "art-#{n}", %{"author" => "auth-1"})
  end

  # Count Ecto query events — one per connection checkout — for the duration of
  # `fun`. `[:barkpark, :repo, :query]` is `Barkpark.Repo`'s default telemetry
  # prefix; every `Repo.all/1` the collector issues emits exactly one.
  defp count_queries(fun) do
    handler = "bounded-collect-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measure, _meta, _cfg -> :counters.add(counter, 1, 1) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    :counters.get(counter, 1)
  end

  defp rebuild(args) do
    perform_job(
      ProjectorWorker,
      Map.merge(
        %{
          "op" => "rebuild",
          "scope" => @dataset,
          "types" => ["article", "author"],
          "page_size" => 5,
          "max_pages" => 50,
          "projector" => inspect(FakeProjectorOk)
        },
        args
      )
    )
  end

  describe "c0 — checkout cost is bounded by the ACL classes, not by the corpus" do
    test "the bounded read holds its count as the corpus grows; the page walk does not" do
      # One page's worth is 5 (page_size above). Seed past it, twice.
      publish!("author", "auth-1")
      seed_articles!(1..8)

      small_bounded = count_queries(fn -> assert :ok = rebuild(%{}) end)

      small_walk =
        count_queries(fn -> assert :ok = rebuild(%{"content" => inspect(WalkOnlyContent)}) end)

      # Double the corpus. Same types, same schemas, same page size.
      seed_articles!(9..16)

      large_bounded = count_queries(fn -> assert :ok = rebuild(%{}) end)

      large_walk =
        count_queries(fn -> assert :ok = rebuild(%{"content" => inspect(WalkOnlyContent)}) end)

      # The numbers themselves are the criterion's evidence; print them on
      # demand rather than making a reader re-derive them from a diff.
      if System.get_env("BOUNDED_COLLECT_COUNTS") do
        IO.puts(
          "\ncorpus 9 docs:  bounded=#{small_bounded} walk=#{small_walk}" <>
            "\ncorpus 17 docs: bounded=#{large_bounded} walk=#{large_walk}"
        )
      end

      # The CONTROL first: unless the old walk's count actually grows, this
      # test measures nothing and its green arm is vacuous.
      assert large_walk > small_walk,
             "CONTROL FAILED: the OFFSET page walk did not get more expensive when the " <>
               "corpus doubled (#{small_walk} -> #{large_walk}) — the counter is not " <>
               "measuring the collection, so the bounded arm below proves nothing"

      assert large_bounded == small_bounded,
             "the bounded read must cost the SAME number of checkouts at 17 docs as at 9 " <>
               "(#{small_bounded} -> #{large_bounded}); a growing count means the rebuild " <>
               "is still paging"

      assert large_bounded < large_walk,
             "bounded=#{large_bounded} walk=#{large_walk}"
    end
  end

  describe "c1 — the projected edges are unchanged" do
    test "bounded read and page walk project TERM-IDENTICAL edges (core + plugin)" do
      Process.register(self(), :bounded_collect_probe)
      :ok = Registry.register(FakeEdgePlugin, %{"plugin_name" => "fake_edges"})

      publish!("author", "auth-1")
      publish!("author", "auth-2")
      seed_articles!(1..8)
      publish!("article", "art-solo", %{"author" => "auth-2"})

      # A NEVER-PUBLISHED document. Without it the two collectors cannot
      # diverge on this fixture and the term-equality below is vacuous on the
      # one axis where substituting the collector actually changes ROWS:
      # `collect_all_documents/3` runs through `list_documents/3`, which
      # applies `perspective: :published`; `collect_corpus_documents/3` is
      # draft-preferred `DISTINCT ON` and, until the `:perspective` option was
      # threaded into `corpus_query/3`, returned `drafts.art-unpublished` as a
      # corpus row. MEASURED with that clause reverted: walk = ["art-1".."art-8",
      # "art-solo"], corpus = the same PLUS "drafts.art-unpublished" — draft
      # edges projected into a published scope.
      {:ok, _} =
        Content.create_document(
          "article",
          %{"_id" => "art-unpublished", "title" => "art-unpublished", "author" => "auth-1"},
          @dataset
        )

      bounded_q =
        count_queries(fn -> assert :ok = rebuild(%{"projector" => inspect(CaptureProjector)}) end)

      assert_received {:edges, bounded_edges}

      walk_q =
        count_queries(fn ->
          assert :ok =
                   rebuild(%{
                     "projector" => inspect(CaptureProjector),
                     "content" => inspect(WalkOnlyContent)
                   })
        end)

      assert_received {:edges, walk_edges}

      # PRECONDITION, not decoration: the equality below is only a FINDING if
      # the two arms really ran DIFFERENT collectors. If both took the page
      # walk (say a future change makes `corpus_collector?/1` always false),
      # the term-equality is trivially true and this test measures nothing.
      assert bounded_q < walk_q,
             "the two arms ran the same collector (bounded=#{bounded_q} walk=#{walk_q}) — " <>
               "the edge comparison below would be vacuous"

      sort = &Enum.sort_by(&1, fn e -> {e[:from_id], e[:to_id], e[:kind]} end)

      assert sort.(bounded_edges) == sort.(walk_edges)

      kinds = bounded_edges |> Enum.map(& &1[:kind]) |> Enum.uniq() |> Enum.sort()

      assert "author" in kinds,
             "the fixture must span the CORE reference-field extractor, got #{inspect(kinds)}"

      assert "related-to" in kinds,
             "the fixture must span a PLUGIN extractor (the :edge_extractor_collector " <>
               "fan-out), got #{inspect(kinds)}"
    end
  end
end
