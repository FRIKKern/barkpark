defmodule Barkpark.Plugins.Indx.RetrieverDropsEngineFacetsTest do
  @moduledoc """
  A REGRESSION FENCE. It exists to red the moment the Indx read path starts
  putting `facets` (or `truncation`) back on the wire.

  ## What re-enabling them would reopen

  The Indx index is keyed on the Barkpark dataset STRING alone
  (`Indexer.current_dataset/1` reads `persistent_term[scope][:dataset]`), so
  every workspace sharing a dataset name shares ONE index. The retriever's ROWS
  are re-read from Postgres under full tenant scope (`hydrate_documents/3`) and
  its TOTAL is recounted there (`total_for/3`) — but the engine's facet buckets
  were neither. They were computed by the engine, over the shared index, and
  handed through verbatim.

  `author` and `category` are tenant-authored FREE TEXT that `Indexer`'s
  `field_proxies/1` marks facetable. So workspace A's search returned workspace
  B's author names and category names as strings, not merely as counts — and it
  was reachable with NO credentials: `engine` is a raw caller-supplied query
  param on `SearchController`, a tokenless flat request still gets a binary
  `workspace_id` from `Plugs.AssignDefaultScope` (satisfying both halves of the
  D3-b gate in `QueryPipeline`), and the `search:*` channel DEFAULTS `engine` to
  `"indx"`, so every WS query already took this path with no param at all.

  The ruling: `DocumentsRetriever`'s `count_and_facets/1` already decided that a
  facet number means a count over the CALLER'S full, tenant-scoped match set.
  Indx never implemented that; it reported the index's counts. Dropping the
  buckets makes `facets` mean exactly one thing everywhere it is non-null.
  Restoring them from the shared index reopens an anonymous cross-tenant read.

  ## Why this fixture can actually catch it

  The failure mode this guards is not "a nil got through" — it is "somebody
  reconnected a populated payload". So the stub client returns a POPULATED
  `facets` map carrying BOTH tenants' author/category values with DIFFERENT
  counts, plus an integer `truncation_index`, and the test asserts the retriever
  drops all of it.

  A stub that returned `facets: nil` would prove nothing: the normalize/attach
  path would never run, and the test would stay green against a restored leak.
  `RetrieverTotalScopeTest`'s stub has exactly that flaw (`facets: nil`), which
  is why the earlier count fix walked straight past the facet leak. Do not copy
  it here.

  Non-vacuity is asserted, not assumed:

    * `Retrievers.resolve/1` must actually resolve `"indx"` to this module in
      the test env — if Indx were unregistered, every assertion below would pass
      against a retriever nobody calls.
    * the stub reports back over the mailbox, so we PROVE the leak-capable
      payload reached the retriever rather than short-circuiting at the
      `is_nil(dataset)` guard in `search/4`.
    * `length(hits) == 1` proves the candidate pool genuinely held both tenants'
      records and the tenant fence dropped B's — the same shape the real leak
      had.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.Retriever
  alias Barkpark.Search.Retrievers

  @pointer_term {Barkpark.Plugins.Indx.Indexer, :live_dataset}

  # A stand-in for `Barkpark.Plugins.Indx.Client`, injected via `opts[:client]`
  # (`Retriever.do_search/6`: `client = Keyword.get(opts, :client, Client)`).
  # It models what a dataset-keyed engine actually answers: BOTH tenants'
  # records, AND dataset-wide facet buckets computed over both.
  defmodule LeakyFacetClient do
    # The engine's own wire shape for facets:
    # `%{field => [%{"key" => value, "value" => count}]}` — what
    # `Client.search_full/3`'s `facets_of/1` hands back. BOTH tenants' values in
    # the two free-text dimensions, and counts that exceed what workspace A can
    # read. If any of this can be reached through the retriever's return value,
    # the leak is back.
    @leaky_facets %{
      "author" => [
        %{"key" => "Ada From Workspace A", "value" => 1},
        %{"key" => "Bruno From Workspace B", "value" => 1}
      ],
      "category" => [
        %{"key" => "a-only-category", "value" => 1},
        %{"key" => "b-only-category", "value" => 1}
      ],
      "type" => [%{"key" => "post", "value" => 2}],
      "status" => [%{"key" => "published", "value" => 2}]
    }

    @truncation_index 137

    def leaky_facets, do: @leaky_facets
    def truncation_index, do: @truncation_index

    def search_full(_dataset, _text, _opts) do
      # Report to the caller (the test process runs `Retriever.search/4`
      # synchronously) so the test can prove the payload was really delivered.
      send(self(), {:indx_search_full_called, @leaky_facets})

      {:ok,
       %{
         records: [%{"documentKey" => 1}, %{"documentKey" => 2}],
         facets: @leaky_facets,
         truncation_index: @truncation_index
       }}
    end

    def get_json(_dataset, _keys, _opts) do
      {:ok,
       [
         %{"_id" => "facet-a", "_type" => "post", "title" => "Facet A"},
         %{"_id" => "facet-b", "_type" => "post", "title" => "Facet B"}
       ]}
    end
  end

  setup do
    # A dataset name unique to this test: the pointer term is global (and this
    # case is async: false), so a shared name would let a sibling test's pointer
    # decide what this one reads.
    dataset = "indxfacet#{System.unique_integer([:positive])}"

    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # Each workspace needs a project: a projectless workspace leaves both
    # `project_id` and `dataset_id` NULL, which makes the rows unreadable
    # through the scoped read and would leave the hit assertion vacuous.
    _proj_a = create_project!(ws_a)
    _proj_b = create_project!(ws_b)

    # `get_documents_by_ids/3` ends in `restrict_to_visible_types/3`, so a type
    # with no PUBLIC schema in this dataset hydrates to nothing.
    {:ok, _} =
      Content.upsert_schema(%{"name" => "post", "title" => "Post"}, dataset,
        workspace_id: ws_a.id
      )

    {:ok, _} =
      Content.upsert_schema(%{"name" => "post", "title" => "Post"}, dataset,
        workspace_id: ws_b.id
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => "facet-a",
          "_type" => "post",
          "title" => "Facet A",
          "author" => "Ada From Workspace A",
          "category" => "a-only-category"
        },
        dataset,
        workspace_id: ws_a.id
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => "facet-b",
          "_type" => "post",
          "title" => "Facet B",
          "author" => "Bruno From Workspace B",
          "category" => "b-only-category"
        },
        dataset,
        workspace_id: ws_b.id
      )

    # `create_document/4` writes a DRAFT. Search hydrates PUBLISHED rows, so
    # publish both — otherwise the hit assertion would be vacuous.
    {:ok, _} = Content.publish_document("facet-a", "post", dataset, workspace_id: ws_a.id)
    {:ok, _} = Content.publish_document("facet-b", "post", dataset, workspace_id: ws_b.id)

    # Point the retriever at a live Indx dataset for this scope; without it
    # `search/4` short-circuits to `{[], 0, %{}}` and every assertion below
    # would pass against an empty pool.
    prior = :persistent_term.get(@pointer_term, %{})
    :persistent_term.put(@pointer_term, Map.put(prior, dataset, %{dataset: "idx-#{dataset}"}))
    on_exit(fn -> :persistent_term.put(@pointer_term, prior) end)

    %{dataset: dataset, ws_a: ws_a, ws_b: ws_b}
  end

  test ~s|the Indx retriever is actually the registered "indx" engine in this env| do
    # If Indx were unregistered in the test config, `Retrievers.resolve/1` would
    # hand back the Postgres retriever and the guard below would be measuring
    # a module the pipeline never routes to.
    resolved = Retrievers.resolve(%{"engine" => "indx"})

    assert resolved == Retriever,
           ~s|engine "indx" resolves to | <>
             "#{inspect(resolved)}, not #{inspect(Retriever)} — the Indx retriever is not " <>
             "registered in this env, so the facet guard would be vacuous"
  end

  test "the engine's dataset-wide facet buckets and truncation NEVER reach the caller",
       %{dataset: dataset, ws_a: ws_a} do
    {hits, total, meta} =
      Retriever.search(
        dataset,
        %{terms: ["facet"]},
        %{},
        workspace_id: ws_a.id,
        client: LeakyFacetClient
      )

    # ---- non-vacuity, asserted before the fence ----------------------------

    # The leak-capable payload really was delivered to the retriever: the stub
    # ran, which means `search/4` did NOT short-circuit on a missing dataset.
    assert_received {:indx_search_full_called, delivered_facets}

    refute delivered_facets["author"] in [nil, []],
           "the fixture must hand the retriever a POPULATED facet payload; a nil/empty " <>
             "one never exercises the facet path and this test would prove nothing"

    # Both tenants' records were in the candidate pool and the tenant fence
    # dropped B's — the exact shape the facet leak rode on.
    assert length(hits) == 1,
           "hydration should return only workspace A's row; got " <>
             "hits=#{inspect(Enum.map(hits, & &1.doc_id))} total=#{inspect(total)}"

    assert hd(hits).doc_id == "facet-a"
    assert total == 1

    # ---- the fence ---------------------------------------------------------

    assert meta == %{},
           "the Indx retriever must return an EMPTY meta. Got #{inspect(meta)}. " <>
             "Re-attaching facets/truncation here republishes buckets computed over an " <>
             "index shared by every workspace using the same dataset STRING — an " <>
             "anonymous cross-tenant read of another tenant's author/category text. " <>
             "See this module's @moduledoc before changing it."

    refute Map.has_key?(meta, :facets),
           "`facets` is back on the Indx path — see this module's @moduledoc"

    refute Map.has_key?(meta, :truncation),
           "`truncation` is back on the Indx path — see this module's @moduledoc"

    # Belt and braces, independent of the meta SHAPE: no matter how a future
    # author nests them, workspace B's strings and the shared-pool counts must
    # not be reachable anywhere in what the caller gets back.
    serialized = inspect({hits, total, meta}, limit: :infinity, printable_limit: :infinity)

    refute String.contains?(serialized, "Bruno From Workspace B"),
           "workspace B's author name reached workspace A's caller: #{serialized}"

    refute String.contains?(serialized, "b-only-category"),
           "workspace B's category reached workspace A's caller: #{serialized}"

    # Shape-independent: no `truncation` key by any nesting. (Deliberately a
    # key-name scan, not a scan for the integer 137 — a bare number would match
    # by accident inside an id or timestamp and make this fence flaky.)
    refute String.contains?(serialized, "truncation"),
           "the engine's shared-pool truncation boundary reached the caller: #{serialized}"
  end
end
