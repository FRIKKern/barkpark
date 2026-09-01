defmodule Barkpark.Media.SharedOnlySentinelScopeTest do
  @moduledoc """
  The `:shared_only` sentinel must be honoured by EVERY hand-rolled workspace
  envelope on the media read path, not just the one that was corrected.

  `BarkparkWeb.ScopeHelpers.scope_opts/1` emits `workspace_id: :shared_only`
  for any HTTP request that resolved no workspace. `Content.Scope` owns the
  arm (`scope_to_workspace/3` → `workspace_id IS NULL`) and
  `Media.Delivery.Search.join_scope_workspace/3` was given a matching arm.

  Its two documented mirrors were NOT:

    * `Barkpark.Plugins.Media.Assets.scope_asset_workspace/3` — reached from
      `Media.asset_docs_for_files/3` at `v1/media_controller.ex:34`,
      `v1/media_collections_controller.ex:57,123` and
      `federated_search_controller.ex:143`, each passing `scope_opts(conn)`
      verbatim.
    * `Barkpark.Media.Delivery.Retriever.join_scope_workspace/3` — reached from
      `Media.search_files/2` → `Search.maybe_filter_text/3`, which rebuilds
      `retriever_opts` with `workspace_id: Keyword.get(opts, :workspace_id)`.

  Both had a `nil` arm and two `is_binary/1` arms, so the atom matched NO
  clause: a FunctionClauseError (500) on a live request. The remedy is the
  sentinel's own meaning — the SHARED layer (`workspace_id IS NULL`), never
  every tenant — which is also what forecloses the worse repair of collapsing
  `:shared_only` to `nil`, whose arm returns the query UNTOUCHED.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Retriever
  alias Barkpark.Plugins.Media.Assets

  @asset_type "mediaAsset"
  @dataset "production"

  # Straight through the changeset so the test isolates the SQL scope filter.
  # `scope` overrides the tenancy columns; omitting workspace_id leaves the
  # NULL-workspace SHARED row that media.ex actually writes untenanted.
  defp insert_asset_doc!(media_file_id, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: "asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id}
      }
      |> Map.merge(scope)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(attrs)
      |> Barkpark.Repo.insert()

    doc
  end

  describe "Assets.scope_asset_workspace/3 under the :shared_only sentinel" do
    test "resolves the shared layer and EXCLUDES a foreign workspace's asset doc" do
      workspace = create_workspace!()

      # Two distinct blob ids so the returned map carries two distinct keys —
      # a shared row and a workspace-owned row. Every assertion below is keyed
      # on these two ids only, so a peer agent's rows in the same table can
      # neither satisfy nor break it.
      shared_blob = Ecto.UUID.generate()
      foreign_blob = Ecto.UUID.generate()

      shared_doc = insert_asset_doc!(shared_blob, %{})
      foreign_doc = insert_asset_doc!(foreign_blob, %{workspace_id: workspace.id})

      docs =
        Assets.find_by_media_file_ids(
          [shared_blob, foreign_blob],
          @dataset,
          workspace_id: :shared_only
        )

      assert %Document{id: id} = Map.get(docs, shared_blob)
      assert id == shared_doc.id

      refute Map.has_key?(docs, foreign_blob),
             "the :shared_only sentinel resolved workspace #{workspace.id}'s asset doc " <>
               "#{foreign_doc.id} — the sentinel means `workspace_id IS NULL`, not every tenant"
    end

    test "NON-VACUITY: the same fixture pair IS both visible to an unscoped read" do
      # Without this, the assertion above would still pass if the fixtures had
      # been caught by an unrelated filter (a mismatched dataset_id, the type
      # filter) and the scope clause never ran at all.
      workspace = create_workspace!()

      shared_blob = Ecto.UUID.generate()
      foreign_blob = Ecto.UUID.generate()

      insert_asset_doc!(shared_blob, %{})
      insert_asset_doc!(foreign_blob, %{workspace_id: workspace.id})

      docs = Assets.find_by_media_file_ids([shared_blob, foreign_blob], @dataset, [])

      assert Map.has_key?(docs, shared_blob)

      assert Map.has_key?(docs, foreign_blob),
             "fixture never reached the workspace clause — an unrelated filter caught it, " <>
               "so the sentinel assertion above is vacuous"
    end
  end

  describe "Retriever.join_scope_workspace/3 under the :shared_only sentinel" do
    test "builds a query instead of raising FunctionClauseError" do
      parsed = %{terms: ["cat"], phrases: [], prefixes: [], raw: ""}

      assert %Ecto.Query{} =
               Retriever.build_text_filter(@dataset, parsed, %{}, workspace_id: :shared_only)
    end

    test "the sentinel narrows the joined asset doc rather than widening it" do
      parsed = %{terms: ["cat"], phrases: [], prefixes: [], raw: ""}

      sentinel = Retriever.build_text_filter(@dataset, parsed, %{}, workspace_id: :shared_only)
      unscoped = Retriever.build_text_filter(@dataset, parsed, %{}, workspace_id: nil)

      # The nil arm is the documented explicit-global read (join filter OFF).
      # The sentinel must NOT compile to that same query — it carries an extra
      # `workspace_id IS NULL` clause on the joined Document.
      refute inspect(sentinel) == inspect(unscoped),
             "the :shared_only sentinel compiled to the same query as the unscoped " <>
               "global read — it was collapsed to nil rather than narrowed"
    end
  end
end
