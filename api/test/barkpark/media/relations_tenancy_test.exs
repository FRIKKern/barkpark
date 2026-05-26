defmodule Barkpark.Media.RelationsTenancyTest do
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
  alias Barkpark.Media.Relations
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
        insert_asset_doc!("asset-a-inbound", file_a.id, "Secret A inbound", [edge("asset-b-entry")], %{
          workspace_id: ws_a.id,
          project_id: proj_a.id,
          dataset_id: nil
        })

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

  describe "NEVER-WORSE — legacy NULL-workspace relations stay visible" do
    test "a legacy NULL-workspace inbound asset doc appears in its tenant's relations graph" do
      {default_ws, default_project} = ensure_default_scope!()
      {:ok, ds} = Tenancy.get_or_create_dataset(default_project, @dataset)

      {:ok, file} = create_media_file_in!(default_ws, default_project, %{dataset_id: ds.id}, @dataset)

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
        insert_asset_doc!("asset-a-in", file_in.id, "A inbound source", [edge("asset-a-entry")], scope)

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
