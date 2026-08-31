defmodule Barkpark.Plugins.Indx.RetrieverTotalScopeTest do
  @moduledoc """
  The Indx index is keyed by the Barkpark dataset STRING alone
  (`Indexer.current_dataset/1` reads `persistent_term[scope][:dataset]`), so two
  workspaces sharing a dataset name share ONE candidate pool. `Retriever`
  already knows this — `hydrate_documents/3`'s own comment says the index "can
  never surface another workspace's row even when two workspaces share a
  dataset STRING", and it is right about the ROWS: hydration re-reads through
  `Content.get_documents_by_ids/3`, which is workspace-scoped.

  The COUNT was not re-read. `total_for/3` returned `length(ranked)` — the size
  of the pre-hydration pool — for every non-grant caller, on the stated premise
  that "for an ordinary read the candidate-pool length is the honest match
  count". That premise holds only if the pool is already tenant-scoped, and the
  pool is dataset-scoped. So workspace A's search reported a total that counted
  workspace B's matching documents, while returning only A's rows: the
  existence and volume of another tenant's content, disclosed as a number.

  Same class as the `Content.Analytics.type_census/2` grant leak
  (task-c6d2e34c64100678 — "existence and volume across a grant boundary"),
  one boundary over: workspace, and for ORDINARY tenant callers rather than
  grantees.

  THE FIXTURE MUST BE ABLE TO PRODUCE THE LEAK. The stub returns BOTH
  workspaces' documents as index records — which is exactly what a shared
  dataset-keyed index does — so the `hits`/`total` split below is a real
  measurement, not a fence asserted against an empty pool. The `hits == 1`
  assertion is what proves it: B's row WAS in the pool and hydration dropped it.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.Retriever

  @pointer_term {Barkpark.Plugins.Indx.Indexer, :live_dataset}

  # A stand-in for `Barkpark.Plugins.Indx.Client`, injected via `opts[:client]`
  # (`Retriever.do_search/6`: `client = Keyword.get(opts, :client, Client)`).
  # It models the ONE property under test: the engine answers from a
  # dataset-wide index, so it hands back both tenants' records.
  defmodule BothTenantsClient do
    def search_full(_dataset, _text, _opts) do
      {:ok,
       %{
         records: [%{"documentKey" => 1}, %{"documentKey" => 2}],
         facets: nil,
         truncation_index: nil
       }}
    end

    def get_json(_dataset, _keys, _opts) do
      {:ok,
       [
         %{"_id" => "widget-a", "_type" => "post", "title" => "Widget A"},
         %{"_id" => "widget-b", "_type" => "post", "title" => "Widget B"}
       ]}
    end
  end

  setup do
    # A dataset name unique to this test: the pointer term is global (and this
    # case is async: false), so a shared name would let a sibling test's pointer
    # decide what this one reads.
    dataset = "indxscope#{System.unique_integer([:positive])}"

    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # Each workspace needs a project: `WriteScope.resolve_write_scope/1` falls
    # back to `default_project_id_for_workspace/1`, and a projectless workspace
    # leaves both `project_id` and `dataset_id` NULL — which makes the rows
    # unreadable through the scoped read and would leave this test asserting
    # against an empty hit list.
    _proj_a = create_project!(ws_a)
    _proj_b = create_project!(ws_b)

    # `get_documents_by_ids/3` ends in `restrict_to_visible_types/3`, so a type
    # with no PUBLIC schema in this dataset hydrates to nothing. Register "post"
    # in both workspaces or the hit list is empty for a reason that has nothing
    # to do with tenancy — a vacuous pass waiting to happen.
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
        %{"_id" => "widget-a", "_type" => "post", "title" => "Widget A"},
        dataset,
        workspace_id: ws_a.id
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "widget-b", "_type" => "post", "title" => "Widget B"},
        dataset,
        workspace_id: ws_b.id
      )

    # `create_document/4` writes a DRAFT (`drafts.widget-a`). Search hydrates
    # PUBLISHED rows, so publish both — otherwise `get_documents_by_ids/3`
    # matches nothing and the assertions below would be vacuous.
    {:ok, _} = Content.publish_document("widget-a", "post", dataset, workspace_id: ws_a.id)
    {:ok, _} = Content.publish_document("widget-b", "post", dataset, workspace_id: ws_b.id)

    # Point the retriever at a live Indx dataset for this scope; without it
    # `search/4` short-circuits to `{[], 0, %{}}` and the test would pass
    # vacuously against an empty pool.
    prior = :persistent_term.get(@pointer_term, %{})
    :persistent_term.put(@pointer_term, Map.put(prior, dataset, %{dataset: "idx-#{dataset}"}))
    on_exit(fn -> :persistent_term.put(@pointer_term, prior) end)

    %{dataset: dataset, ws_a: ws_a, ws_b: ws_b}
  end

  test "the reported total counts only the caller's workspace, not the shared pool",
       %{dataset: dataset, ws_a: ws_a} do
    {hits, total, _meta} =
      Retriever.search(
        dataset,
        %{terms: ["widget"]},
        %{},
        workspace_id: ws_a.id,
        client: BothTenantsClient
      )

    # The fixture COULD have leaked: both tenants' docs were in the candidate
    # pool, and the workspace-scoped hydration dropped B's. If this ever reads
    # 2, the hydration fence broke and the total assertion below is meaningless.
    assert length(hits) == 1,
           "hydration should return only workspace A's row; got hits=#{inspect(Enum.map(hits, & &1.doc_id))} total=#{inspect(total)}"

    assert hd(hits).doc_id == "widget-a"

    # The count must agree with what the caller may actually see. Before the
    # fix this was 2 — workspace B's document counted in A's total.
    assert total == 1,
           "total counted another workspace's document: the pool is dataset-wide, not tenant-wide"
  end
end
