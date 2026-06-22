defmodule Barkpark.Media.AssetMetadataTenancyTest do
  @moduledoc """
  P0 cross-workspace media-metadata leak (barkpark-vmv1 / write-scope
  barkpark-x56q).

  The blob row (media_files) is scoped on upload, but the companion
  `mediaAsset` DOCUMENT carrying the user-facing metadata (title / tags /
  rights / collection) used to be written WITHOUT scope → docs landed
  NULL-workspace. The metadata read (`asset_docs_for_files/3`, and the search
  LEFT JOIN to Document) keyed on the bare `dataset` STRING with no workspace
  envelope → workspace B's blob rendered workspace A's title/tags.

  Three guarantees are proved here:

    1. LEAK GATE — a NEWLY scoped asset doc in workspace A is NOT returned for
       the SAME blob id when the metadata read is resolved to workspace B,
       even though both share the `production` dataset STRING. (This test was
       confirmed to FAIL against the pre-fix unscoped read — see the test moduledoc
       note in the leak-gate describe block.)
    2. NEVER-WORSE — a LEGACY asset doc (workspace_id=NULL) is STILL visible in
       its own tenant's metadata read after the fix (the NULL-tolerant
       envelope).
    3. IN-SCOPE — a scoped asset doc resolves correctly in its OWN workspace's
       read, with the correct title/tags.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @dataset "production"

  # Insert a `mediaAsset` Document straight through the changeset (no hook
  # pipeline) so the test isolates the SQL scope filter. `scope` overrides the
  # workspace_id / project_id / dataset_id columns; omitting them leaves the
  # legacy NULL-workspace shape media.ex wrote before the write-scope fix.
  defp insert_asset_doc!(media_file_id, title, tags, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id, "tags" => tags}
      }
      |> Map.merge(scope)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(attrs)
      |> Barkpark.Repo.insert()

    doc
  end

  describe "LEAK GATE — newly-scoped asset doc isolated across workspaces" do
    # PRE-FIX CONFIRMATION (manual, recorded here for the gate):
    # Reverting the read-threading — i.e. dropping the workspace envelope from
    # Assets.find_by_media_file_ids and reverting asset_docs_for_files to the
    # 2-arity unscoped form — makes this test FAIL: the workspace-B read
    # returned workspace A's "Secret A title" + ["a-secret-tag"] for the same
    # blob id, because both asset docs shared the `production` dataset STRING
    # and the read had no workspace envelope. With the fix the B-scoped read
    # resolves only B's doc (or none). Leak confirmed-fails-against-prefix.
    test "metadata read scoped to workspace B never returns workspace A's title/tags" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, _ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, _ds_b} = Tenancy.get_or_create_dataset(proj_b, @dataset)

      # Distinct blobs, ONE in each workspace, that happen to share a blob id
      # value is impossible (UUID PKs) — so the leak is keyed on the SAME
      # mediaFileId living in a NEWLY-scoped asset doc in A while B reads its
      # OWN blob list. The pre-fix read joined B's blob to A's doc by dataset
      # STRING + mediaFileId. We reproduce that by giving A's doc a mediaFileId
      # that equals B's blob id (the shared-leaf collision the leak exploits).
      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @dataset)

      # Newly-scoped asset doc in WORKSPACE A, but pointing at B's blob id —
      # the exact cross-tenant collision. Stamped to A (workspace_id=A).
      _doc_a =
        insert_asset_doc!(file_b.id, "Secret A title", ["a-secret-tag"], %{
          workspace_id: ws_a.id,
          project_id: proj_a.id
        })

      # Workspace B reads metadata for its own blob, scoped to B.
      docs =
        Media.asset_docs_for_files([file_b], @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      case Map.get(docs, file_b.id) do
        nil ->
          # No doc resolved for B — A's doc correctly excluded. Pass.
          :ok

        %Document{} = found ->
          refute found.title == "Secret A title",
                 "CROSS-WORKSPACE METADATA LEAK: workspace B's read returned " <>
                   "workspace A's asset title #{inspect(found.title)}"

          refute "a-secret-tag" in Map.get(found.content || %{}, "tags", []),
                 "CROSS-WORKSPACE METADATA LEAK: workspace B's read returned " <>
                   "workspace A's tags"
      end
    end

    test "search LEFT JOIN does not surface workspace A's metadata to workspace B" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, _ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, ds_b} = Tenancy.get_or_create_dataset(proj_b, @dataset)

      # B's blob carries B's dataset_id so the blob-side `m.dataset_id` filter
      # surfaces it for B's search. Its OWN asset doc has NO matching token.
      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{dataset_id: ds_b.id}, @dataset)

      _doc_b =
        insert_asset_doc!(file_b.id, "ordinary b title", [], %{
          workspace_id: ws_b.id,
          project_id: proj_b.id,
          dataset_id: ds_b.id
        })

      # A's NEWLY-scoped asset doc collides on B's blob id AND carries B's
      # dataset_id — so the dataset envelope ALONE cannot exclude it. Only the
      # WORKSPACE envelope on the join (workspace_id=A) keeps it out of B's
      # search. Pre-fix (bare type+dataset join), the A-only token matched B's
      # blob via `ilike(d.title, ...)` in MediaRetriever.
      _doc_a =
        insert_asset_doc!(file_b.id, "zzqqxx-a-only-token", ["a-secret-tag"], %{
          workspace_id: ws_a.id,
          project_id: proj_a.id,
          dataset_id: ds_b.id
        })

      # Workspace B searches for A's exclusive token — must find NOTHING in B.
      {files, total, _facets, _meta} =
        Barkpark.Search.MediaSearch.search(@dataset,
          q: "zzqqxx-a-only-token",
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      refute file_b.id in Enum.map(files, & &1.id),
             "CROSS-WORKSPACE LEAK via search JOIN: workspace B's blob matched " <>
               "workspace A's exclusive asset-doc token (#{inspect(total)} hits) — " <>
               "the join attached A's NULL-workspace-isolated doc to B's blob"
    end
  end

  describe "NEVER-WORSE — legacy NULL-workspace asset docs stay visible" do
    test "a legacy asset doc (workspace_id=NULL) appears in its tenant's metadata read" do
      {default_ws, default_project} = ensure_default_scope!()
      {:ok, _ds} = Tenancy.get_or_create_dataset(default_project, @dataset)

      {:ok, file} = create_media_file_in!(default_ws, default_project, %{}, @dataset)

      # Legacy shape: dataset STRING stamped, workspace_id NULL (the pre-fix
      # write path). Title/tags must STILL surface for the Default-scoped read.
      legacy =
        insert_asset_doc!(file.id, "Legacy title", ["legacy-tag"], %{
          workspace_id: nil,
          project_id: nil,
          dataset_id: nil
        })

      assert is_nil(legacy.workspace_id)

      docs =
        Media.asset_docs_for_files([file], @dataset,
          workspace_id: default_ws.id,
          project_id: default_project.id
        )

      found = Map.get(docs, file.id)

      assert found,
             "NEVER-WORSE REGRESSION: a legacy NULL-workspace asset doc vanished " <>
               "from its own tenant's metadata read after the fix"

      assert found.title == "Legacy title"
      assert "legacy-tag" in Map.get(found.content || %{}, "tags", [])
    end
  end

  describe "IN-SCOPE — a scoped asset doc resolves in its own workspace" do
    test "workspace A's read returns A's own asset doc with correct title/tags" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      {:ok, file_a} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)

      _doc_a =
        insert_asset_doc!(file_a.id, "A title", ["a-tag"], %{
          workspace_id: ws_a.id,
          project_id: proj_a.id,
          dataset_id: ds_a.id
        })

      docs =
        Media.asset_docs_for_files([file_a], @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      found = Map.get(docs, file_a.id)

      assert found, "scoped asset doc was not visible in its own workspace's read"
      assert found.title == "A title"
      assert "a-tag" in Map.get(found.content || %{}, "tags", [])
    end
  end
end
