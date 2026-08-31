defmodule Barkpark.Search.IndxEngineScopeTest do
  @moduledoc """
  P0 leak guard for the Indx search SEAM (Stage 8, D3 a+b).

  The Indx engine is a RELEVANCE ORACLE only — it returns `documentKey` hits and
  the embedded Barkpark `_id`/`_type`, but the AUTHORITATIVE row always comes
  from a Postgres re-read in `Barkpark.Plugins.Indx.Retriever.load_document/3`.
  If that re-read forgot to thread the tenant scope, two workspaces sharing a
  dataset STRING would conflate: an `engine: "indx"` search scoped to workspace
  B could surface workspace A's document because the index returned A's key.

  This test proves the two halves of the fix WITHOUT a live Indx engine:

    * D3-a (source-read scope): the retriever is driven with an INJECTED fake
      client that deliberately returns BOTH workspaces' docs (the index does
      not scope). A search routed `engine: "indx"` + workspace B's
      `:workspace_id` still returns ONLY B's doc, because `load_document/3`
      forwards `:workspace_id`/`:project_id` into `Content.get_document/4` →
      `scope_to_workspace_or_global/3`. A's doc is dropped at the Postgres read.

    * D3-b (the pipeline gate): `engine: "indx"` with NO binary `:workspace_id`
      falls back to the scoped Postgres `DocumentsRetriever` inside
      `QueryPipeline`, so an unscoped Indx request can never bypass the tenant
      boundary. We assert it does NOT crash and returns the scoped Postgres
      result (the fake Indx client is never consulted on that path).

  The retriever is exercised directly (not via the HTTP controller) so we can
  inject the fake `:client` through opts — there is no Indx engine running in
  the test environment.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Plugins.Indx.Indexer
  alias Barkpark.Plugins.Indx.Retriever, as: IndxRetriever
  alias Barkpark.Search.{DocumentsRetriever, QueryParser, QueryPipeline, SurfaceConfigs}

  # SAME dataset STRING across both workspaces — the conflation surface.
  @ds "production"
  @term "kumquat"

  # The Indexer reads the live dataset for a scope from a :persistent_term map
  # shaped %{scope => %{dataset: ...}}. We point @ds at a live dataset name so
  # Retriever.search/4 does not early-return on a nil dataset.
  @pointer_term {Indexer, :live_dataset}
  @live_dataset "indx-test-live"

  # A fake Indx client that ignores scope entirely (the index is a pure
  # relevance oracle). It returns documentKeys for BOTH workspaces' docs and,
  # on hydrate, the embedded Barkpark `_id`/`_type` for both. The ONLY thing
  # that can drop A's doc on B's search is the Postgres source-read scope.
  defmodule BothDocsClient do
    # The retriever calls `search_full/3` and destructures
    # `{:ok, %{records:, facets:, truncation_index:}}`. Return both workspaces'
    # documentKeys so only the Postgres source-read scope can drop A's doc.
    def search_full(_dataset, _text, _opts) do
      {:ok,
       %{
         records: [%{"documentKey" => 1}, %{"documentKey" => 2}],
         facets: %{},
         truncation_index: nil
       }}
    end

    def get_json(_dataset, _keys, _opts) do
      {:ok,
       [
         %{"_id" => "drafts.a-hit", "_type" => "post"},
         %{"_id" => "drafts.b-hit", "_type" => "post"}
       ]}
    end
  end

  setup do
    # Make @ds resolve to a live dataset so the engine path runs.
    prior = :persistent_term.get(@pointer_term, %{})
    :persistent_term.put(@pointer_term, Map.put(prior, @ds, %{dataset: @live_dataset}))
    on_exit(fn -> :persistent_term.put(@pointer_term, prior) end)

    SurfaceConfigs.seed_defaults!()
    :ok
  end

  # Two workspaces/projects each owning a `production` dataset holding a doc
  # whose title matches @term. Returns {scope_a, scope_b}.
  defp two_workspaces_with_matching_doc do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    # W10 schema-visibility gate: the anonymous (no caller_context) searches in
    # these cases are restricted to PUBLIC schema types — seed "post" as one in
    # each tenant; the workspace-scope isolation stays the behaviour under test.
    for scope <- [scope_a, scope_b] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "post", "visibility" => "public"},
          @ds,
          scope
        )
    end

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "a-hit", "title" => "#{@term} from A"},
        @ds,
        scope_a
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "b-hit", "title" => "#{@term} from B"},
        @ds,
        scope_b
      )

    {scope_a, scope_b}
  end

  test "D3-a: an Indx search scoped to workspace B never returns workspace A's doc even when the index returns A's key" do
    {scope_a, scope_b} = two_workspaces_with_matching_doc()
    parsed = QueryParser.parse(@term)
    config = SurfaceConfigs.get("documents", @ds)

    # B's scope + the fake index that returns BOTH keys. Only the Postgres
    # source-read scope can drop A — and it must.
    {b_hits, b_total, _meta} =
      IndxRetriever.search(
        @ds,
        parsed,
        config,
        [perspective: :raw, client: BothDocsClient] ++ scope_b
      )

    b_ids = Enum.map(b_hits, & &1.doc_id)

    # The leak invariant covers the COUNT as well as the visible hits: exactly
    # one row survives the Postgres source-read scope, it is B's, and the
    # reported total agrees with it.
    #
    # This assertion used to read `b_total == 2`, with the parenthetical "`total`
    # now reflects the pre-scope candidate pool count, not the visible slice" —
    # i.e. this fixture already reproduced the count leak and the invariant was
    # narrowed to exclude it. Two workspaces share one dataset-keyed Indx pool
    # (that is what `BothDocsClient` models), so a pre-scope pool count tells B
    # how many documents workspace A has matching its query. `total_for/3` now
    # recomputes the total through `Content.count_documents_by_ids/3` — the same
    # scoping stack the hydration read applies — so the number can never exceed
    # what the caller may see. Tightened, not relaxed: 2 -> 1.
    assert b_total == 1
    assert length(b_ids) == 1
    assert "drafts.b-hit" in b_ids
    refute "drafts.a-hit" in b_ids

    # Mirror: A's scoped search excludes B's doc, same fake index.
    {a_hits, _a_total, _meta} =
      IndxRetriever.search(
        @ds,
        parsed,
        config,
        [perspective: :raw, client: BothDocsClient] ++ scope_a
      )

    a_ids = Enum.map(a_hits, & &1.doc_id)

    assert length(a_ids) == 1
    assert "drafts.a-hit" in a_ids
    refute "drafts.b-hit" in a_ids
  end

  test "D3-b: engine: \"indx\" with NO binary :workspace_id falls back to the scoped Postgres retriever (no leak)" do
    # Both A's and B's docs are workspace-stamped. With NO :workspace_id in opts
    # the pipeline gate must route to the scoped Postgres DocumentsRetriever
    # instead of the Indx engine. The scoped Postgres read with a nil
    # workspace_id resolves to GLOBAL scope (workspace_id IS NULL), so it
    # surfaces NEITHER workspace's doc — the unscoped Indx request cannot bypass
    # the tenant boundary. The key proof is that it returns a normal
    # {:ok, result} (Postgres path) and never raises, and never leaks A or B.
    {_scope_a, _scope_b} = two_workspaces_with_matching_doc()
    context = %{query: @term, filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", @ds, context,
               engine: "indx",
               perspective: :raw
             )

    ids = Enum.map(result.hits, & &1.doc_id)
    # Gate took the scoped-Postgres branch (global scope, no workspace) → it does
    # not surface either workspace-stamped doc. Had it routed to Indx it would
    # have hit the real unconfigured client and degraded to {[], 0, %{}} — either
    # way the assertion below (no cross-workspace leak) holds, and crucially it
    # does NOT crash.
    refute "drafts.a-hit" in ids
    refute "drafts.b-hit" in ids
  end

  test "D3-b: the gate's fallback target (DocumentsRetriever) is itself scope-safe under a full scope" do
    {scope_a, _scope_b} = two_workspaces_with_matching_doc()
    parsed = QueryParser.parse(@term)
    config = SurfaceConfigs.get("documents", @ds)

    # Sanity on the fallback target: DocumentsRetriever under A's full scope
    # returns only A's doc, confirming the gate's Postgres fallback is scope-safe.
    {hits, total, _meta} =
      DocumentsRetriever.search(@ds, parsed, config, [perspective: :raw] ++ scope_a)

    ids = Enum.map(hits, & &1.doc_id)
    assert total == 1
    assert "drafts.a-hit" in ids
    refute "drafts.b-hit" in ids
  end

  # An owner_scoped type, two owned docs in the SAME workspace (user A + user B).
  # The fake index returns BOTH keys; the only thing that can drop B's doc on
  # A's search is the row/ownership ACL in the Postgres re-read — which requires
  # the retriever to FORWARD the caller_context into hydration (the LOW seam).
  defmodule OwnedDocsClient do
    def search_full(_dataset, _text, _opts) do
      {:ok,
       %{
         records: [%{"documentKey" => 1}, %{"documentKey" => 2}],
         facets: %{},
         truncation_index: nil
       }}
    end

    def get_json(_dataset, _keys, _opts) do
      {:ok,
       [
         %{"_id" => "drafts.a-own", "_type" => "owned_post"},
         %{"_id" => "drafts.b-own", "_type" => "owned_post"}
       ]}
    end
  end

  test "LOW: an Indx search forwards the caller_context so a user sees their OWN owner_scoped doc (and not another's)" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "owned_post",
          "title" => "Owned Post",
          "owner_scoped" => true,
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @ds
      )

    # Global (nil-workspace) docs so the global owner_scoped schema resolves and
    # owner_id is stamped — this test isolates the ROW/owner ACL, not tenancy.
    user_a = Ecto.UUID.generate()
    user_b = Ecto.UUID.generate()
    ctx_a = CallerContext.from_user(user_a)

    {:ok, _} =
      Content.create_document(
        "owned_post",
        %{"doc_id" => "a-own", "title" => "#{@term} A"},
        @ds,
        caller_context: ctx_a
      )

    {:ok, _} =
      Content.create_document(
        "owned_post",
        %{"doc_id" => "b-own", "title" => "#{@term} B"},
        @ds,
        caller_context: CallerContext.from_user(user_b)
      )

    parsed = QueryParser.parse(@term)
    config = SurfaceConfigs.get("documents", @ds)

    # User A's Indx search: hydration forwards ctx_a → scope_to_owner admits A's
    # own row and drops B's. Without the forward, a nil caller fails CLOSED to
    # unowned-only and A would see NEITHER owned doc.
    {hits, _total, _meta} =
      IndxRetriever.search(
        @ds,
        parsed,
        config,
        perspective: :raw,
        client: OwnedDocsClient,
        caller_context: ctx_a
      )

    ids = Enum.map(hits, & &1.doc_id)
    assert "drafts.a-own" in ids
    refute "drafts.b-own" in ids
  end
end
