defmodule Barkpark.Plugins.Media.AssetsScopeTest do
  @moduledoc """
  Tenancy-scope regression tests for `Barkpark.Plugins.Media.Assets`
  asset-doc lookups (barkpark-5p3y).

  Two guarantees are proved here, and — this is the point of the fixtures —
  each is measured by the WORKSPACE ENVELOPE alone
  (`Barkpark.Plugins.Media.Assets.scope_asset_workspace/3`), never by a
  `dataset_id` filter standing in for it (task-7faee37433ed92be).

    * NEVER-WORSE: media.ex writes asset docs WITHOUT workspace/project scope,
      so `dataset_id` lands NULL while the `dataset` STRING is stamped, and
      `workspace_id` lands NULL too. A read scoped to a real workspace must
      STILL surface them — that is the envelope's `is_nil(d.workspace_id)`
      leg. Drop that leg and every legacy asset doc vanishes from its own
      tenant's media listing.

    * CROSS-TENANT: two workspaces sharing the `production` dataset STRING
      each own an asset doc for the SAME mediaFileId. A lookup scoped to
      workspace B must resolve B's doc, never A's.

  ## Why workspace A's doc carries dataset_id = NULL

  These two arms pull in OPPOSITE directions, and the fixture is built so only
  the envelope can answer either one.

  The earlier version of this file gave A and B distinct, fully-stamped
  `dataset_id`s, so the SIBLING clause `scope_asset_dataset/3` excluded A's doc
  before the envelope was ever consulted: replacing the envelope's
  is_binary/is_binary clause body with a bare `query` left all three tests
  GREEN. The file that NAMES the envelope could not tell whether it existed.

  Workspace A's doc is therefore stamped in the shape a PROJECTLESS workspace
  write actually produces (`Barkpark.Content.WriteScope.put_scope_attrs/2`
  degrades to no `dataset_id` key when no project resolves): `workspace_id`
  set, `project_id` NULL, `dataset_id` NULL, `dataset` STRING stamped. That
  doc sails through the dataset envelope on its NULL-tolerant leg
  (`is_nil(d.dataset_id) and d.dataset == ^dataset`), so the WORKSPACE is the
  only discriminator left. Remove the envelope and A's doc leaks into B's read.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @dataset "production"

  # Insert a `mediaAsset` Document straight through the changeset (no hook
  # pipeline) so the test isolates the SQL scope filter. `scope` is a map of
  # extra column overrides (workspace_id / project_id / dataset_id); omitting
  # them leaves the NULL-stamped legacy shape that media.ex actually writes.
  # The doc_id carries the `drafts.` prefix so it matches the real draft asset
  # row Content.create_document stamps (the delete path resolves by doc_id).
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

  # The cross-tenant fixture, shared by the single and batch arms.
  #
  # Returns `{ws_b, proj_b, doc_a, doc_b, media_file_id}`. A's doc is inserted
  # LAST and its `updated_at` is pushed a minute past B's, so an UNENVELOPED
  # query does not merely admit the leak — it PREFERS it: the single-doc read
  # orders `desc: updated_at limit 1`, so the leaked row wins deterministically
  # rather than by whichever row the planner happened to emit first.
  defp cross_tenant_fixture! do
    ws_a = create_workspace!()

    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    {:ok, ds_b} = Tenancy.get_or_create_dataset(proj_b, @dataset)

    media_file_id = "shared-blob-#{System.unique_integer([:positive])}"

    doc_b =
      insert_asset_doc!(media_file_id, %{
        workspace_id: ws_b.id,
        project_id: proj_b.id,
        dataset_id: ds_b.id
      })

    # Workspace A, projectless write shape: workspace stamped, project and
    # dataset_id NULL. The dataset envelope's NULL-tolerant leg admits it.
    doc_a =
      insert_asset_doc!(media_file_id, %{
        workspace_id: ws_a.id,
        project_id: nil,
        dataset_id: nil
      })

    assert is_nil(doc_a.dataset_id),
           "FIXTURE PRECONDITION: workspace A's doc must carry dataset_id=NULL, " <>
             "otherwise scope_asset_dataset/3 excludes it and the workspace " <>
             "envelope is never the discriminator"

    refute is_nil(doc_a.workspace_id)
    refute doc_a.workspace_id == doc_b.workspace_id

    {1, _} =
      Repo.update_all(
        from(d in Document, where: d.id == ^doc_a.id),
        set: [updated_at: DateTime.add(doc_b.updated_at, 60, :second)]
      )

    {ws_b, proj_b, doc_a, doc_b, media_file_id}
  end

  # The rows the production envelopes leave visible to a read scoped to
  # `ws`/`proj` — the exact clause pair `asset_doc_scope/4` composes, so the
  # assertion is on the SCOPE, deterministically (no ordering, no map
  # collapse), not on whichever of two colliding rows a lookup returns.
  defp visible_doc_ids(media_file_id, ws, proj) do
    Document
    |> where([d], d.type == ^@asset_type)
    |> Assets.scope_asset_dataset(@dataset, workspace_id: ws.id, project_id: proj.id)
    |> Assets.scope_asset_workspace(ws.id, proj.id)
    |> where([d], fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id))
    |> Repo.all()
    |> Enum.map(& &1.doc_id)
    |> Enum.sort()
  end

  # Same clause pair as `visible_doc_ids/3`, but the DATASET envelope's project
  # and the WORKSPACE envelope's project rung are supplied SEPARATELY. That is
  # what lets the ARMED control drop the project RUNG on its own while leaving
  # the dataset resolution byte-identical — otherwise the control would move two
  # things at once and prove neither.
  defp visible_doc_ids(media_file_id, ws_id, dataset_project_id, envelope_project_id) do
    Document
    |> where([d], d.type == ^@asset_type)
    |> Assets.scope_asset_dataset(@dataset, workspace_id: ws_id, project_id: dataset_project_id)
    |> Assets.scope_asset_workspace(ws_id, envelope_project_id)
    |> where([d], fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id))
    |> Repo.all()
    |> Enum.map(& &1.doc_id)
    |> Enum.sort()
  end

  describe "find_by_media_file_id/3 — never-worse (legacy NULL dataset_id)" do
    test "returns a legacy asset doc whose dataset_id is NULL on the default path" do
      {default_ws, default_project} = ensure_default_scope!()

      # Force a real `production` dataset_id under the Default project so the
      # read's `resolve_dataset_id` returns a non-nil id and exercises the
      # dataset_id-filtering branch. Without this the test would fall into the
      # legacy string-only branch and never prove the OR clause.
      {:ok, _dataset} = Tenancy.get_or_create_dataset(default_project, @dataset)

      media_file_id = "blob-#{System.unique_integer([:positive])}"

      # Legacy shape: dataset STRING stamped, dataset_id NULL, no workspace.
      legacy = insert_asset_doc!(media_file_id, %{dataset_id: nil})
      assert is_nil(legacy.dataset_id)
      assert is_nil(legacy.workspace_id)

      # The default path, SCOPED — the Default workspace/project the flat
      # back-compat reader resolves to. Scoped is what reaches the envelope's
      # is_binary/is_binary clause: an unscoped read passes workspace_id=nil
      # and returns the query UNTOUCHED, so it could not tell a NULL-tolerant
      # envelope from a strict one.
      found =
        Assets.find_by_media_file_id(media_file_id, @dataset,
          workspace_id: default_ws.id,
          project_id: default_project.id
        )

      assert found,
             "NEVER-WORSE REGRESSION: a legacy mediaAsset doc with dataset_id=NULL " <>
               "and workspace_id=NULL was invisible on the default read path — the " <>
               "strict dataset_id filter would have missed it, and a strict workspace " <>
               "envelope (no is_nil(workspace_id) leg) would have missed it too; both " <>
               "NULL-tolerant OR clauses must surface it"

      assert found.doc_id == legacy.doc_id

      assert visible_doc_ids(media_file_id, default_ws, default_project) == [legacy.doc_id]
    end
  end

  describe "find_by_media_file_id/3 — cross-tenant isolation" do
    test "scoped to workspace B resolves B's asset doc, never workspace A's" do
      {ws_b, proj_b, doc_a, doc_b, media_file_id} = cross_tenant_fixture!()

      found =
        Assets.find_by_media_file_id(media_file_id, @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      assert found.doc_id == doc_b.doc_id,
             "CROSS-WORKSPACE LEAK: lookup scoped to workspace B resolved " <>
               "#{inspect(found.doc_id)} — expected B's doc #{inspect(doc_b.doc_id)}, " <>
               "not A's #{inspect(doc_a.doc_id)}. A's doc carries dataset_id=NULL, so " <>
               "the dataset envelope admits it; only scope_asset_workspace/3 can exclude it"

      refute found.doc_id == doc_a.doc_id

      assert visible_doc_ids(media_file_id, ws_b, proj_b) == [doc_b.doc_id],
             "CROSS-WORKSPACE LEAK: the scoped query itself left workspace A's doc visible"
    end
  end

  describe "find_by_media_file_ids/3 — cross-tenant isolation" do
    test "batch lookup scoped to workspace B returns only B's asset doc" do
      {ws_b, proj_b, doc_a, doc_b, media_file_id} = cross_tenant_fixture!()

      result =
        Assets.find_by_media_file_ids([media_file_id], @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      assert %{^media_file_id => found} = result
      assert found.doc_id == doc_b.doc_id
      refute found.doc_id == doc_a.doc_id

      # The batch reader keys by mediaFileId, so two colliding rows COLLAPSE to
      # one map entry and the assertion above depends on emission order. This
      # one does not: it counts the rows the scope actually leaves visible.
      assert visible_doc_ids(media_file_id, ws_b, proj_b) == [doc_b.doc_id],
             "CROSS-WORKSPACE LEAK: the batch scope left workspace A's doc visible; " <>
               "the map collapse hid it behind a single key"
    end
  end

  describe "scope_asset_workspace/3 — the PROJECT rung" do
    # The envelope's is_binary/is_binary clause stacks TWO rungs in one
    # parenthesis. Both cross-tenant fixtures above stand two rows in DIFFERENT
    # WORKSPACES, so the WORKSPACE rung answers them and the inner project rung
    # is never consulted: appending `or not is_nil(d.project_id)` to it — making
    # it unconditionally true, workspace rung byte-identical — left all 366
    # media-fence tests green (task-96d8720de593d82a).
    #
    # This fixture is the same shape one rung down: ONE workspace, TWO projects.
    # The foreign doc shares the reader's workspace_id, so the workspace rung
    # admits it by construction, and carries dataset_id=NULL, so
    # `scope_asset_dataset/3` admits it on its NULL-tolerant leg. The project
    # rung is the only thing left that can refuse it.
    test "a SIBLING PROJECT's asset doc in the SAME workspace never resolves" do
      ws = create_workspace!()
      proj_reader = create_project!(ws)
      proj_foreign = create_project!(ws)

      {:ok, ds_reader} = Tenancy.get_or_create_dataset(proj_reader, @dataset)
      {:ok, ds_foreign} = Tenancy.get_or_create_dataset(proj_foreign, @dataset)

      refute ds_reader.id == ds_foreign.id,
             "FIXTURE NOT ARMED: the two projects resolved the SAME dataset row"

      media_file_id = "shared-blob-#{System.unique_integer([:positive])}"

      mine =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws.id,
          project_id: proj_reader.id,
          dataset_id: ds_reader.id
        })

      foreign =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws.id,
          project_id: proj_foreign.id,
          dataset_id: nil
        })

      assert is_nil(foreign.dataset_id),
             "FIXTURE NOT ARMED: a stamped dataset_id is refused by scope_asset_dataset/3 " <>
               "before the workspace envelope is reached, so the project rung is untested"

      assert foreign.workspace_id == mine.workspace_id,
             "FIXTURE NOT ARMED: the foreign doc must share the reader's workspace, or " <>
               "the WORKSPACE rung is the excluder"

      refute foreign.project_id == mine.project_id

      # As in `cross_tenant_fixture!/0`: push the foreign row's updated_at past
      # the reader's own, so an un-runged query does not merely ADMIT the leak —
      # the `desc: updated_at limit 1` single-doc read PREFERS it.
      {1, _} =
        Repo.update_all(
          from(d in Document, where: d.id == ^foreign.id),
          set: [updated_at: DateTime.add(mine.updated_at, 60, :second)]
        )

      # ARMED — drop the project rung alone (the envelope's 2-arg clause) and
      # the foreign doc IS visible. Everything but the rung admits this row.
      assert visible_doc_ids(media_file_id, ws.id, proj_reader.id, nil) ==
               Enum.sort([mine.doc_id, foreign.doc_id]),
             "FIXTURE NOT ARMED: the foreign doc is not visible even with the project rung " <>
               "off, so its absence below proves nothing about the rung"

      assert visible_doc_ids(media_file_id, ws.id, proj_reader.id, proj_reader.id) == [
               mine.doc_id
             ],
             "CROSS-PROJECT ASSET-DOC LEAK: a sibling project's mediaAsset doc stayed " <>
               "visible to a read scoped to this project inside the same workspace. Only " <>
               "the project rung of scope_asset_workspace/3 can refuse it."

      found =
        Assets.find_by_media_file_id(media_file_id, @dataset,
          workspace_id: ws.id,
          project_id: proj_reader.id
        )

      assert found.doc_id == mine.doc_id,
             "CROSS-PROJECT ASSET-DOC LEAK: find_by_media_file_id/3 resolved " <>
               "#{inspect(found.doc_id)} — the sibling project's doc, freshly updated, " <>
               "won the `desc: updated_at limit 1` read"
    end

    test "NEVER-WORSE — a legacy NULL-project doc stays visible under a project scope" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, _ds} = Tenancy.get_or_create_dataset(proj, @dataset)

      media_file_id = "legacy-blob-#{System.unique_integer([:positive])}"

      # `Content.WriteScope.put_scope_attrs/2` degrades to no project key when
      # no project resolves, so a workspace-only write lands exactly here. The
      # rung's `is_nil(d.project_id)` leg is what keeps it visible.
      legacy =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws.id,
          project_id: nil,
          dataset_id: nil
        })

      assert visible_doc_ids(media_file_id, ws.id, proj.id, proj.id) == [legacy.doc_id],
             "NEVER-WORSE REGRESSION: a legacy NULL-project asset doc vanished from its " <>
               "own tenant's scoped read — the rung's `is_nil(d.project_id)` leg is gone"
    end
  end
end
