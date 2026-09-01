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
      `federated_search_controller.ex`'s `surface_payload/3` media clause, each
      passing `scope_opts(conn)` verbatim.
    * `Barkpark.Media.Delivery.Retriever.join_scope_workspace/3` — reached from
      `Media.search_files/2` → `Search.maybe_filter_text/3`, which rebuilds
      `retriever_opts` with `workspace_id: Keyword.get(opts, :workspace_id)`.

  Both had a `nil` arm and two `is_binary/1` arms, so the atom matched NO
  clause: a FunctionClauseError (500) on a live request. The remedy is the
  sentinel's own meaning — the SHARED layer (`workspace_id IS NULL`), never
  every tenant — which is also what forecloses the worse repair of collapsing
  `:shared_only` to `nil`, whose arm returns the query UNTOUCHED.

  ## A THIRD mirror, in the module that was already corrected

  The enumeration above said "its two documented mirrors". That was wrong, and
  the miss is instructive: `Media.Delivery.Search` was corrected at
  `join_scope_workspace/3` (the Ecto results path) while `scope_fragments/2`
  — the RAW-SQL envelope for the tag facet, 340 lines below in the SAME file —
  was not. Both are reached by ONE request, `GET /v1/media/search?facets=tags`
  (`v1/media_controller.ex:32` threads `scope_opts(conn)` into
  `Media.search_files/2`), so a single unresolved conn hit a corrected
  interpreter and an uncorrected one in the same call.

  `scope_fragments/2` runs `uuid_param(first_present([opts[:workspace_id]]))`.
  `first_present/1` passes `:shared_only` through (an atom is neither `nil` nor
  `""`), and `uuid_param/1` has only a `nil` clause and an `is_binary/1`
  clause — the identical guard shape, and the identical FunctionClauseError,
  as the two mirrors this module already names.

  Searching for the FUNCTION NAME found the mirrors; the defect is keyed on the
  GUARD SHAPE, and one instance of it did not carry the name.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Retriever
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @asset_type "mediaAsset"
  @dataset "production"

  # The raw-SQL facet arms below reuse the dataset string the existing
  # `tags_facet_sql` regression suite proves the facet path resolves under
  # (`search/media_search_scope_test.exs`), rather than this module's
  # "production" leaf.
  @facet_dataset "test"

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

  describe "Search.scope_fragments/2 (raw-SQL tag facet) under the :shared_only sentinel" do
    # `create_media_file_in!/4` requires a workspace, and the shared layer is
    # `workspace_id IS NULL`. Create in a throwaway workspace, then NULL the
    # tenancy columns on BOTH the blob and its asset doc — the same move
    # `empty_scope_shared_layer_test.exs` makes, and for the same reason: a
    # fixture that merely OMITS the scope gets a Default-owned row instead of
    # the pre-tenancy shape under test.
    defp shared_layer_asset!(tag) do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, file} = create_media_file_in!(ws, proj, %{}, @facet_dataset)
      doc = link_facet_asset!(file, ws, proj, [tag])

      {1, _} =
        Repo.update_all(
          from(m in Barkpark.Media.Storage.MediaFile, where: m.id == ^file.id),
          set: [workspace_id: nil, project_id: nil]
        )

      {1, _} =
        Repo.update_all(
          from(d in Document, where: d.id == ^doc.id),
          set: [workspace_id: nil, project_id: nil]
        )

      file
    end

    defp link_facet_asset!(file, ws, proj, tags) do
      suffix = System.unique_integer([:positive])

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          doc_id: "sentinel-facet-#{suffix}",
          type: @asset_type,
          dataset: @facet_dataset,
          title: "sentinel facet asset #{suffix}",
          status: "draft",
          rev: "r#{suffix}",
          content: %{"mediaFileId" => file.id, "tags" => tags},
          workspace_id: ws.id,
          project_id: proj && proj.id
        })
        |> Repo.insert()

      doc
    end

    defp tags_facet(scope) do
      {_files, _total, facets, _meta} =
        Search.search(@facet_dataset, [facets: ["tags"]] ++ scope)

      facets["tags"] |> Enum.map(& &1.value)
    end

    test "the sentinel builds a facet query instead of raising FunctionClauseError" do
      # The bare reachability arm. `uuid_param/1` matches neither of its two
      # clauses on an atom, so BEFORE the fix this raises rather than failing an
      # assertion — which is exactly how a live `GET /v1/media/search?facets=tags`
      # announced itself as a 500 with no Default workspace seeded.
      result = Search.search(@facet_dataset, facets: ["tags"], workspace_id: :shared_only)

      assert match?({_files, _total, _facets, _meta}, result),
             "the :shared_only sentinel did not survive the raw-SQL facet path; got: " <>
               inspect(result)
    end

    test "the facet resolves the shared layer and EXCLUDES a foreign workspace's tag" do
      n = System.unique_integer([:positive])
      shared_tag = "sentinel-shared-#{n}"
      foreign_tag = "sentinel-foreign-#{n}"

      # Tags are unique per run, so every assertion below is keyed on THIS
      # fixture's own strings — a peer agent's rows in the shared test database
      # can neither satisfy nor break it.
      shared_layer_asset!(shared_tag)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @facet_dataset)
      link_facet_asset!(file_b, ws_b, proj_b, [foreign_tag])

      tags = tags_facet(workspace_id: :shared_only)

      assert shared_tag in tags,
             "the :shared_only sentinel lost the shared NULL-workspace layer it means; " <>
               "facet returned #{inspect(tags)}"

      refute foreign_tag in tags,
             "CROSS-TENANT LEAK: the :shared_only sentinel surfaced workspace " <>
               "#{ws_b.id}'s exclusive tag #{inspect(foreign_tag)} — the sentinel means " <>
               "`workspace_id IS NULL`, not every tenant. Facet: #{inspect(tags)}"
    end

    test "NON-VACUITY: both fixture tags ARE visible to the explicit-global read" do
      # Without this the arm above would still pass if the fixtures had been
      # caught by an unrelated filter (the dataset leaf, the type filter, a
      # missing dataset_id) and the workspace clause never ran at all.
      n = System.unique_integer([:positive])
      shared_tag = "sentinel-shared-#{n}"
      foreign_tag = "sentinel-foreign-#{n}"

      shared_layer_asset!(shared_tag)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @facet_dataset)
      link_facet_asset!(file_b, ws_b, proj_b, [foreign_tag])

      # `nil` is the documented EXPLICIT-global read — it must keep meaning
      # "every tenant", which is what makes the sentinel a narrowing rather
      # than a behaviour change to the ~90 nil callers.
      tags = tags_facet(workspace_id: nil)

      assert shared_tag in tags,
             "fixture never reached the workspace clause — the shared-layer row was " <>
               "caught by an unrelated filter, so the sentinel arm above is vacuous"

      assert foreign_tag in tags,
             "fixture never reached the workspace clause — the foreign row was caught " <>
               "by an unrelated filter, so the refute above is vacuous"
    end
  end
end
