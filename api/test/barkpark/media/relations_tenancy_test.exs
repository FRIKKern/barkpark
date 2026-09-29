defmodule Barkpark.Media.Storage.RelationsTenancyTest do
  @moduledoc """
  P0 cross-workspace relations leak (barkpark-m21z).

  `/v1/media/:dataset/:id/relations` builds an asset relation graph: outbound
  refs on the asset doc, plus inbound back-links (other asset docs whose
  `relatedAssets` target this blob's doc) — each rendered with the related
  blob's file + signed URL. Before the fix:

    * `graph/3` dropped `:workspace_id` / `:project_id` (`Keyword.take` only
      kept `:conn`, `:sign_urls`, `:dataset`), so no scope reached the reads.
    * `inbound/3` queried back-links on the bare `dataset` STRING with NO
      workspace/dataset_id envelope.
    * `resolve_target` / `file_for_doc` called `Content.get_document` /
      `Media.get_file` with NO scope opts.

  Net: the relations graph resolved to workspace B surfaced workspace A's
  related asset docs / titles / signed URLs whenever the two shared the
  `dataset` STRING.

  Three guarantees are proved here:

    1. LEAK GATE — an inbound back-link asset doc in workspace A that targets
       a blob B reads is NOT surfaced in B's relations graph, even though both
       share the `production` dataset STRING. (Confirmed to FAIL against the
       pre-fix unscoped reads — see the leak-gate note.)
    2. NEVER-WORSE — a legacy NULL-workspace asset doc still appears in its own
       tenant's relations graph (the NULL-tolerant envelope).
    3. IN-SCOPE — in-scope inbound/outbound relations resolve correctly.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.Relations
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @dataset "production"

  # Insert a `mediaAsset` Document straight through the changeset (no hook
  # pipeline) so the test isolates the SQL scope filter — mirrors
  # Barkpark.Media.AssetMetadataTenancyTest.insert_asset_doc!/4. `content`
  # carries the `mediaFileId` link and an optional `relatedAssets` edge list.
  # `scope` overrides workspace_id / project_id / dataset_id; omitting them
  # leaves the legacy NULL-workspace shape.
  defp insert_asset_doc!(doc_id, media_file_id, title, related, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: doc_id,
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id, "relatedAssets" => related}
      }
      |> Map.merge(scope)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(attrs)
      |> Barkpark.Repo.insert()

    doc
  end

  defp edge(target_doc_id), do: %{"target" => target_doc_id, "relation" => "related"}

  describe "LEAK GATE — inbound back-links isolated across workspaces" do
    # PRE-FIX CONFIRMATION (recorded for the gate, and proven by reverting ONLY
    # the inbound envelope + resolve_target/file_for_doc scope): the pre-fix
    # `inbound/3` queried back-links on the bare `d.dataset == ^dataset` filter
    # with NO workspace envelope, so workspace B's relations graph surfaced
    # "Secret A inbound" as an inbound back-link — A's source doc shared the
    # `production` dataset STRING and targeted the same `doc_id` B's blob
    # resolves to. With the fix the B-scoped inbound list excludes A's doc
    # (workspace_id=A != B and not NULL). Leak confirmed-fails-against-prefix.
    #
    # The entry doc carries dataset_id=NULL (legacy STRING-only) so it resolves
    # identically under prefix and fixed code — isolating the inbound WORKSPACE
    # envelope as the sole discriminator, not the entry-doc lookup.
    test "relations graph scoped to workspace B never surfaces workspace A's inbound asset doc" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, _ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, _ds_b} = Tenancy.get_or_create_dataset(proj_b, @dataset)

      # B's blob + its OWN scoped entry asset doc (dataset_id NULL so the entry
      # lookup resolves via the STRING fallback under both prefix and fixed).
      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @dataset)

      _doc_b =
        insert_asset_doc!("asset-b-entry", file_b.id, "B entry", [], %{
          workspace_id: ws_b.id,
          project_id: proj_b.id,
          dataset_id: nil
        })

      # WORKSPACE A's source asset doc back-links (relatedAssets → B's entry
      # doc_id). Shares the `production` dataset STRING — only the WORKSPACE
      # envelope keeps it out of B's inbound list. Points at A's own blob so
      # file_for_doc has something to (try to) resolve.
      {:ok, file_a} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)

      _doc_a =
        insert_asset_doc!(
          "asset-a-inbound",
          file_a.id,
          "Secret A inbound",
          [edge("asset-b-entry")],
          %{
            workspace_id: ws_a.id,
            project_id: proj_a.id,
            dataset_id: nil
          }
        )

      # B reads the relations graph for its own blob, scoped to B.
      graph =
        Relations.graph(file_b, @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      inbound_doc_ids = Enum.map(graph.inbound, & &1.assetDocId)
      inbound_titles = Enum.map(graph.inbound, &(&1.asset && &1.asset.title))

      refute "asset-a-inbound" in inbound_doc_ids,
             "CROSS-WORKSPACE RELATIONS LEAK: workspace B's graph surfaced " <>
               "workspace A's inbound asset doc id (#{inspect(inbound_doc_ids)})"

      refute "Secret A inbound" in inbound_titles,
             "CROSS-WORKSPACE RELATIONS LEAK: workspace B's graph surfaced " <>
               "workspace A's inbound asset title (#{inspect(inbound_titles)})"
    end
  end

  # ── The DATASET half of the envelope (task-96d8720de593d82a) ──────────────
  #
  # `inbound/4` stacks `Assets.scope_asset_dataset/3` then
  # `Assets.scope_asset_workspace/3`, and the inline comment above them claims
  # both are load-bearing. The LEAK GATE test above stamps `dataset_id: nil` on
  # BOTH docs, and with a NULL dataset_id `scope_asset_dataset/3` falls through
  # to its `is_nil(d.dataset_id) and d.dataset == ^dataset` arm, which matches
  # workspace A's doc IDENTICALLY to the bare string filter. That test is
  # structurally incapable of seeing the dataset envelope: reverting the call to
  # the pre-fix `where([d], d.dataset == ^dataset)` left all 366 media-fence
  # tests green. Only the workspace clause ever excluded anything.
  #
  # The `dataset_id: nil` arm above STAYS — it is the NULL-tolerance case. This
  # is an ADDITIONAL arm whose foreign doc is STAMPED with another project's
  # dataset_id and carries the SAME workspace_id as the reader, so the workspace
  # clause admits it and only the dataset clause can refuse.
  describe "LEAK GATE — the dataset envelope excludes a foreign row ON ITS OWN" do
    test "a SIBLING PROJECT's stamped inbound doc in the reader's OWN workspace is excluded" do
      ws = create_workspace!()

      # A `"default"`-slugged project so `Tenancy.scope_project_id/1` resolves
      # one for a project-LESS read and `scope_asset_dataset/3` takes its
      # dataset_id arm. Without it the resolution is nil, the production code
      # ALREADY degrades to the bare string filter, and the mutation would be a
      # no-op — the precondition is asserted below, not assumed.
      proj_default = create_project!(ws, "default")
      proj_foreign = create_project!(ws)

      {:ok, ds_default} = Tenancy.get_or_create_dataset(proj_default, @dataset)
      {:ok, ds_foreign} = Tenancy.get_or_create_dataset(proj_foreign, @dataset)

      assert Tenancy.scope_project_id(workspace_id: ws.id) == proj_default.id,
             "FIXTURE NOT ARMED: a project-less read does not resolve this workspace's " <>
               "default project, so scope_asset_dataset/3 takes its bare-string arm and " <>
               "the mutation under test is a no-op"

      refute ds_default.id == ds_foreign.id,
             "FIXTURE NOT ARMED: the two projects resolved the SAME dataset row"

      # The reader's blob and its entry doc. The entry doc is projectless and
      # dataset_id-NULL so BOTH reads below resolve it identically and the only
      # thing that moves between them is the inbound query.
      {:ok, file_entry} = create_media_file_in!(ws, proj_default, %{}, @dataset)

      entry_id = "asset-entry-#{System.unique_integer([:positive])}"

      _entry =
        insert_asset_doc!(entry_id, file_entry.id, "Entry", [], %{
          workspace_id: ws.id,
          project_id: nil,
          dataset_id: nil
        })

      # The foreign inbound doc: SAME workspace as the reader (so
      # `scope_asset_workspace/3` admits it — the read passes no project, so its
      # 2-arg clause runs and there is no project rung either), STAMPED with the
      # sibling project's dataset_id (so ONLY `scope_asset_dataset/3` can refuse
      # it), sharing the `production` dataset STRING (so the bare pre-fix filter
      # admits it).
      {:ok, file_foreign} = create_media_file_in!(ws, proj_foreign, %{}, @dataset)

      foreign_id = "asset-foreign-inbound-#{System.unique_integer([:positive])}"

      foreign =
        insert_asset_doc!(
          foreign_id,
          file_foreign.id,
          "Sibling project inbound",
          [
            edge(entry_id)
          ],
          %{
            workspace_id: ws.id,
            project_id: proj_foreign.id,
            dataset_id: ds_foreign.id
          }
        )

      assert foreign.workspace_id == ws.id,
             "FIXTURE NOT ARMED: the foreign doc must share the reader's workspace, or " <>
               "the WORKSPACE clause is the excluder and the dataset clause stays untested"

      refute is_nil(foreign.dataset_id),
             "FIXTURE NOT ARMED: a NULL dataset_id is admitted by scope_asset_dataset/3's " <>
               "NULL-tolerant arm IDENTICALLY to the bare string filter — that is exactly " <>
               "why the arm above cannot see this clause"

      assert foreign.dataset == @dataset,
             "FIXTURE NOT ARMED: the bare pre-fix `d.dataset == ^dataset` filter would " <>
               "not admit this row either, so nothing distinguishes the two predicates"

      # ARMED — scope the read to the foreign doc's OWN project. The dataset
      # envelope then resolves ds_foreign and the very same doc IS an inbound
      # back-link. Everything but the dataset clause admits this row.
      armed =
        Relations.graph(file_entry, @dataset, workspace_id: ws.id, project_id: proj_foreign.id)

      assert foreign_id in Enum.map(armed.inbound, & &1.assetDocId),
             "FIXTURE NOT ARMED: the foreign doc is not an inbound back-link even under " <>
               "its own project's scope, so its absence below proves nothing about the " <>
               "dataset envelope"

      graph = Relations.graph(file_entry, @dataset, workspace_id: ws.id)

      inbound_doc_ids = Enum.map(graph.inbound, & &1.assetDocId)

      refute foreign_id in inbound_doc_ids,
             "CROSS-PROJECT RELATIONS LEAK: a sibling project's STAMPED inbound asset doc " <>
               "(dataset_id #{inspect(foreign.dataset_id)}) appeared in a read whose " <>
               "dataset resolves to #{inspect(ds_default.id)} " <>
               "(#{inspect(inbound_doc_ids)}). The workspace clause admits it by " <>
               "construction — only Assets.scope_asset_dataset/3 can refuse it, and the " <>
               "moduledoc's two-part envelope claim rests on that."
    end
  end

  describe "NEVER-WORSE — legacy NULL-workspace relations stay visible" do
    test "a legacy NULL-workspace inbound asset doc appears in its tenant's relations graph" do
      {default_ws, default_project} = ensure_default_scope!()
      {:ok, ds} = Tenancy.get_or_create_dataset(default_project, @dataset)

      {:ok, file} =
        create_media_file_in!(default_ws, default_project, %{dataset_id: ds.id}, @dataset)

      # The graph entry doc for the blob — also legacy NULL-workspace shape.
      _entry =
        insert_asset_doc!("asset-legacy-entry", file.id, "Legacy entry", [], %{
          workspace_id: nil,
          project_id: nil,
          dataset_id: nil
        })

      {:ok, file_src} =
        create_media_file_in!(default_ws, default_project, %{dataset_id: ds.id}, @dataset)

      # Legacy source doc (workspace_id NULL, dataset_id NULL, dataset STRING
      # stamped) that back-links to the entry doc — must STILL surface for the
      # Default-scoped read via the NULL-tolerant envelope.
      legacy_src =
        insert_asset_doc!(
          "asset-legacy-inbound",
          file_src.id,
          "Legacy inbound",
          [edge("asset-legacy-entry")],
          %{workspace_id: nil, project_id: nil, dataset_id: nil}
        )

      assert is_nil(legacy_src.workspace_id)

      graph =
        Relations.graph(file, @dataset,
          workspace_id: default_ws.id,
          project_id: default_project.id
        )

      inbound_doc_ids = Enum.map(graph.inbound, & &1.assetDocId)

      assert "asset-legacy-inbound" in inbound_doc_ids,
             "NEVER-WORSE REGRESSION: a legacy NULL-workspace inbound asset doc vanished " <>
               "from its own tenant's relations graph after the fix (#{inspect(inbound_doc_ids)})"
    end
  end

  describe "IN-SCOPE — relations resolve correctly within a workspace" do
    test "workspace A's graph surfaces A's own inbound + outbound relations" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      {:ok, file_entry} = create_media_file_in!(ws_a, proj_a, %{dataset_id: ds_a.id}, @dataset)
      {:ok, file_out} = create_media_file_in!(ws_a, proj_a, %{dataset_id: ds_a.id}, @dataset)
      {:ok, file_in} = create_media_file_in!(ws_a, proj_a, %{dataset_id: ds_a.id}, @dataset)

      scope = %{workspace_id: ws_a.id, project_id: proj_a.id, dataset_id: ds_a.id}

      # Outbound target doc the entry doc references.
      _out_doc = insert_asset_doc!("asset-a-out", file_out.id, "A outbound target", [], scope)

      # Entry doc references the outbound target.
      _entry =
        insert_asset_doc!("asset-a-entry", file_entry.id, "A entry", [edge("asset-a-out")], scope)

      # Inbound source doc back-links to the entry doc.
      _in_doc =
        insert_asset_doc!(
          "asset-a-in",
          file_in.id,
          "A inbound source",
          [edge("asset-a-entry")],
          scope
        )

      graph =
        Relations.graph(file_entry, @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      outbound_doc_ids = Enum.map(graph.outbound, & &1.assetDocId)
      inbound_doc_ids = Enum.map(graph.inbound, & &1.assetDocId)

      assert "asset-a-out" in outbound_doc_ids,
             "in-scope outbound relation was not resolved (#{inspect(outbound_doc_ids)})"

      assert "asset-a-in" in inbound_doc_ids,
             "in-scope inbound relation was not resolved (#{inspect(inbound_doc_ids)})"
    end
  end
end
