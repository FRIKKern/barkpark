defmodule Barkpark.Tenancy.WorkspaceBundleDatasetRemapTest do
  @moduledoc """
  A dataset exported from one workspace imports into another under a NEW
  dataset id and slug, with every stored pointer to the source rewritten
  (task-c7d4f4a5d5034651). The second workspace stands in for a second
  instance: it shares this database, so any row the import failed to re-key
  would collide with, or silently point at, the source rows that are still
  here — which is exactly what these tests look for.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog, DatasetRemap, DatasetRemapError}

  @src "src"

  describe "round trip: export a dataset, import it under a new dataset id in another workspace" do
    test "documents, references, edges and revisions resolve inside the new dataset; the source is untouched" do
      fx = seed_source!()

      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)
      source_before = source_fingerprint(fx)

      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      {:ok, stats} =
        WorkspaceBundle.import_bundle(bundle,
          into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]
        )

      remap = stats.remap
      new_ds = remap.dataset_id

      # The new dataset is a new row: new id, target project, requested slug.
      assert remap.source.dataset_id == fx.src_ds.id
      refute new_ds == fx.src_ds.id

      assert rows("SELECT project_id::text, slug FROM datasets WHERE id = $1::text::uuid", [
               new_ds
             ]) == [[proj_b.id, "copy"]]

      # DOCUMENTS: the same (doc_id, type) set, every row under the target
      # tenancy, and no row id reused from the source.
      assert doc_keys(fx.src_ds.id) == doc_keys(new_ds)
      assert length(doc_keys(new_ds)) == fx.doc_count

      assert rows(
               "SELECT DISTINCT workspace_id::text, project_id::text, dataset FROM documents " <>
                 "WHERE dataset_id = $1::text::uuid",
               [new_ds]
             ) == [[ws_b.id, proj_b.id, "copy"]]

      new_ids = ids_in("documents", new_ds)
      assert length(new_ids) == fx.doc_count
      assert MapSet.disjoint?(MapSet.new(new_ids), MapSet.new(ids_in("documents", fx.src_ds.id)))

      # REFERENCES inside content: every `_ref` a new document carries names a
      # document that exists in the NEW dataset.
      refs =
        rows(
          "SELECT d.doc_id, r.value->>'_ref' FROM documents d, " <>
            "jsonb_each(d.content) r WHERE d.dataset_id = $1::text::uuid " <>
            "AND jsonb_typeof(r.value) = 'object' AND r.value ? '_ref'",
          [new_ds]
        )

      assert length(refs) == 2

      for [from, to] <- refs do
        assert scalar(
                 "SELECT count(*) FROM documents WHERE dataset_id = $1::text::uuid " <>
                   "AND (doc_id = $2 OR doc_id = 'drafts.' || $2)",
                 [new_ds, to]
               ) >= 1,
               "#{from} references #{to}, which does not exist in the new dataset"
      end

      # EDGES / BACKLINKS: every edge that leaves a new document lands on a new
      # document, and the in-dataset edge set survived intact. The edge inside
      # the OTHER source dataset did not come along.
      for table <- ~w(content_edges task_edges) do
        new_edges = edges_in(table, new_ds)
        assert new_edges == edges_in(table, fx.src_ds.id), "#{table} edge set changed"
        assert length(new_edges) == fx.edge_counts[table]
        assert fx.edge_counts[table] == 1

        assert scalar(
                 "SELECT count(*) FROM #{table} e JOIN documents f ON f.id = e.from_id " <>
                   "LEFT JOIN documents t ON t.id = e.to_id " <>
                   "WHERE f.dataset_id = $1::text::uuid " <>
                   "AND t.dataset_id IS DISTINCT FROM $1::text::uuid",
                 [new_ds]
               ) == 0,
               "a #{table} row from the new dataset points outside it"
      end

      assert remap.dropped_out_of_dataset["content_edges"] == 1

      # The smaller rewritten tables: re-keyed onto the new dataset and its rows.
      assert rows(
               "SELECT name, workspace_id::text, project_id::text, dataset FROM schema_definitions " <>
                 "WHERE dataset_id = $1::text::uuid",
               [new_ds]
             ) == [["post", ws_b.id, proj_b.id, "copy"]]

      assert rows(
               "SELECT d.doc_id FROM plugin_doc_state s JOIN documents d ON d.id = s.doc_id " <>
                 "WHERE d.dataset_id = $1::text::uuid",
               [new_ds]
             ) == [[fx.src_docs.a.doc_id]]

      assert remap.dropped_out_of_dataset["plugin_doc_state"] == 1

      assert rows("SELECT doc_id FROM authoring_exemptions WHERE dataset = 'copy'", []) == [
               [fx.src_docs.a.doc_id]
             ]

      assert remap.rewritten["mutation_events"] > 0

      assert rows(
               "SELECT DISTINCT workspace_id::text, project_id::text, dataset FROM mutation_events " <>
                 "WHERE dataset_id = $1::text::uuid",
               [new_ds]
             ) == [[ws_b.id, proj_b.id, "copy"]]

      # REVISIONS: same history per document, every revision bound to a
      # document of the new dataset, and each document's revision pointers
      # land on revisions of the new dataset.
      assert revision_keys(new_ds) == revision_keys(fx.src_ds.id)
      assert length(revision_keys(new_ds)) == fx.revision_count
      assert fx.revision_count > 0

      assert scalar(
               "SELECT count(*) FROM revisions r LEFT JOIN documents d ON d.id = r.document_id " <>
                 "WHERE r.dataset_id = $1::text::uuid AND r.document_id IS NOT NULL " <>
                 "AND d.dataset_id IS DISTINCT FROM $1::text::uuid",
               [new_ds]
             ) == 0

      for col <- ~w(current_revision_id released_revision_id) do
        assert scalar(
                 "SELECT count(*) FROM documents d LEFT JOIN revisions r ON r.id = d.#{col} " <>
                   "WHERE d.dataset_id = $1::text::uuid AND d.#{col} IS NOT NULL " <>
                   "AND r.dataset_id IS DISTINCT FROM $1::text::uuid",
                 [new_ds]
               ) == 0
      end

      assert scalar(
               "SELECT count(*) FROM documents WHERE dataset_id = $1::text::uuid " <>
                 "AND current_revision_id IS NOT NULL",
               [new_ds]
             ) == fx.docs_with_current_revision

      assert fx.docs_with_current_revision > 0

      # `c` was published, so its published row carries a released revision.
      assert rows(
               "SELECT d.doc_id FROM documents d JOIN revisions r ON r.id = d.released_revision_id " <>
                 "WHERE d.dataset_id = $1::text::uuid AND r.dataset_id = $1::text::uuid",
               [new_ds]
             ) == [["c"]]

      # Nothing that landed names a source tenancy id or a source row id.
      assert source_ids_in_new_rows(fx, new_ds) == []

      # THE SOURCE IS UNTOUCHED: a fresh export of it is byte-identical, member
      # by member, and its rows are the same rows.
      assert source_fingerprint(fx) == source_before
    end

    test "import_bundle_file/2 takes the same option and lands the same dataset" do
      fx = seed_source!()
      {:ok, path} = WorkspaceBundle.export_to_file(fx.ws_a.id, dataset: @src)

      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      try do
        {:ok, stats} =
          WorkspaceBundle.import_bundle_file(path,
            into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "from-file"]
          )

        assert doc_keys(stats.remap.dataset_id) == doc_keys(fx.src_ds.id)
      after
        File.rm(path)
      end
    end
  end

  describe "every member table of a bundle has a remap class" do
    test "the live catalog classifies every table an export can carry, and the explicit lists are disjoint" do
      members =
        [Catalog.root_table()] ++
          Catalog.live_e1(Repo) ++ Catalog.live_e2(Repo) ++ Catalog.live_e3(Repo)

      classes = Map.new(members, &{&1, DatasetRemap.member_class(&1)})

      assert Enum.filter(classes, fn {_t, c} -> c == :unknown end) == []

      assert MapSet.disjoint?(
               MapSet.new(DatasetRemap.rewritten_tables()),
               MapSet.new(DatasetRemap.spine_tables())
             )

      # Every rewritten and spine table is a real member, so a rename cannot
      # quietly turn a rewrite into dead code.
      for t <-
            DatasetRemap.rewritten_tables() ++
              DatasetRemap.spine_tables() ++ Map.keys(DatasetRemap.not_carried_tables()) do
        assert t in members, "#{t} is listed by the remap but no export carries it"
      end

      # The tables with a dataset column that the remap does NOT rewrite are
      # guarded, never waved through as workspace-scoped.
      for {t, {:workspace_scoped, _}} <- classes do
        cols =
          List.flatten(
            rows(
              "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' " <>
                "AND table_name = $1 AND column_name IN ('dataset', 'dataset_id', 'scope')",
              [t]
            )
          )

        assert cols == [], "#{t} carries #{inspect(cols)} but is classed workspace-scoped"
      end

      if System.get_env("PRINT_REMAP_CLASSES") do
        for {t, c} <- Enum.sort(classes), do: IO.puts("REMAP-CLASS #{t} #{inspect(c)}")
      end
    end
  end

  describe "refusals: a remap that cannot be done cleanly writes nothing" do
    test "a slug the target project already has is refused as dataset_slug_conflict" do
      fx = seed_source!()
      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))
      opts = [into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]]

      {:ok, first} = WorkspaceBundle.import_bundle(bundle, opts)
      docs_after_first = scalar("SELECT count(*) FROM documents", [])

      error =
        assert_raise DatasetRemapError, fn -> WorkspaceBundle.import_bundle(bundle, opts) end

      assert error.code == "dataset_slug_conflict"
      assert error.details.existing_dataset_id == first.remap.dataset_id
      assert scalar("SELECT count(*) FROM documents", []) == docs_after_first
    end

    test "the source's own project and slug collide too — a remap never merges into the source" do
      fx = seed_source!()
      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)

      error =
        assert_raise DatasetRemapError, fn ->
          WorkspaceBundle.import_bundle(bundle,
            into_dataset: [workspace_id: fx.ws_a.id, project_id: fx.proj_a.id, slug: @src]
          )
        end

      assert error.code == "dataset_slug_conflict"
    end

    test "a whole-workspace bundle has no single dataset to remap" do
      fx = seed_source!()
      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id)
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      error =
        assert_raise DatasetRemapError, fn ->
          WorkspaceBundle.import_bundle(bundle,
            into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]
          )
        end

      assert error.code == "not_a_dataset_bundle"
    end

    test "an edge from the dataset to a document outside it is refused as dangling_reference" do
      fx = seed_source!()
      insert_edge!("content_edges", fx.src_docs.a.id, fx.other_doc.id)
      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      error =
        assert_raise DatasetRemapError, fn ->
          WorkspaceBundle.import_bundle(bundle,
            into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]
          )
        end

      assert error.code == "dangling_reference"
      assert error.table == "content_edges"
      assert error.details.sample == [fx.other_doc.id]
      # Nothing was written: the dataset row the remap created rolled back too.
      assert scalar("SELECT count(*) FROM datasets WHERE project_id = $1::text::uuid", [proj_b.id]) ==
               0
    end

    test "dataset rows in a table the remap does not rewrite are refused, not dropped" do
      fx = seed_source!()
      {:ok, media} = create_media_file_in!(fx.ws_a, fx.proj_a, %{}, @src)

      # The fixture stamps only the slug; a dataset export narrows media on the
      # canonical dataset_id, so give the row the id every real write stamps.
      Repo.query!(
        "UPDATE media_files SET dataset_id = $1::text::uuid WHERE id = $2::text::uuid",
        [
          fx.src_ds.id,
          media.id
        ]
      )

      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      error =
        assert_raise DatasetRemapError, fn ->
          WorkspaceBundle.import_bundle(bundle,
            into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]
          )
        end

      assert error.code == "unhandled_dataset_rows"
      assert error.table == "media_files"
      assert error.details.count == 1
    end

    test "a source id hidden in content is caught by the backstop scan" do
      fx = seed_source!()

      # A shape no explicit rewrite knows: a document's row id stored in content.
      Repo.query!(
        "UPDATE documents SET content = content || jsonb_build_object('pinned_row', $1::text) " <>
          "WHERE id = $2::text::uuid",
        [fx.src_docs.b.id, fx.src_docs.a.id]
      )

      {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      error =
        assert_raise DatasetRemapError, fn ->
          WorkspaceBundle.import_bundle(bundle,
            into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]
          )
        end

      assert error.code == "unremapped_source_id"
      assert error.table == "documents"
      assert fx.src_docs.b.id in error.details.sample
    end

    test "a malformed option or an incompatible mode is an ArgumentError before the bundle is read" do
      assert_raise ArgumentError, fn ->
        WorkspaceBundle.import_bundle("not a tar", into_dataset: [slug: "x"])
      end

      id = Ecto.UUID.generate()

      assert_raise ArgumentError, fn ->
        WorkspaceBundle.import_bundle("not a tar",
          mode: :merge,
          into_dataset: [workspace_id: id, project_id: id, slug: "x"]
        )
      end
    end
  end

  # ── Fixture ──────────────────────────────────────────────────────────────────

  # Workspace A, one project, two datasets: `src` (the one exported) and
  # `other` (which must not come along). In `src`: three posts, where `a`
  # references `b` and `b` references `c` through content `_ref` fields, a
  # content edge and a task edge a -> b, a publish (so revisions exist and
  # documents carry revision pointers). In `other`: one post with an edge to
  # itself's sibling, so the workspace-whole edge member carries a row the
  # remap must drop.
  defp seed_source! do
    ws_a = create_workspace!(unique("wsa"))
    proj_a = create_project!(ws_a, unique("proja"))
    scope = [workspace_id: ws_a.id, project_id: proj_a.id]

    c = create!(scope, "c", %{"title" => "C"})
    b = create!(scope, "b", %{"title" => "B", "next" => %{"_ref" => "c"}})
    a = create!(scope, "a", %{"title" => "A", "next" => %{"_ref" => "b"}})

    {:ok, _} = Content.publish_document("c", "post", @src, scope)

    other = create!(scope, "o1", %{"title" => "O1"}, "other")
    other2 = create!(scope, "o2", %{"title" => "O2"}, "other")

    insert_edge!("content_edges", a.id, b.id)
    insert_edge!("task_edges", a.id, b.id)
    insert_edge!("content_edges", other.id, other2.id)

    src_ds_id =
      Repo.one!(
        from d in Barkpark.Tenancy.Dataset,
          where: d.project_id == ^proj_a.id and d.slug == ^@src,
          select: d.id
      )

    # The three smaller rewritten tables, one row each in `src`, plus a plugin
    # state row on the OTHER dataset's document that must be dropped.
    Repo.query!(
      "INSERT INTO schema_definitions (id, name, title, dataset, workspace_id, project_id, " <>
        "dataset_id, inserted_at, updated_at) VALUES (gen_random_uuid(), 'post', 'Post', $1, " <>
        "$2::text::uuid, $3::text::uuid, $4::text::uuid, now(), now())",
      [@src, ws_a.id, proj_a.id, src_ds_id]
    )

    for doc <- [a, other] do
      Repo.query!(
        "INSERT INTO plugin_doc_state (plugin_name, doc_id, key, value, updated_at) " <>
          "VALUES ('fixture', $1::text::uuid, 'seen', '{\"n\": 1}', now())",
        [doc.id]
      )
    end

    Repo.query!(
      "INSERT INTO authoring_exemptions (doc_id, dataset, type) VALUES ($1, $2, 'post')",
      [a.doc_id, @src]
    )

    src_ds =
      Repo.one!(
        from d in Barkpark.Tenancy.Dataset,
          where: d.project_id == ^proj_a.id and d.slug == ^@src
      )

    %{
      ws_a: ws_a,
      proj_a: proj_a,
      src_ds: src_ds,
      src_docs: %{a: a, b: b, c: c},
      other_doc: other,
      doc_count:
        scalar("SELECT count(*) FROM documents WHERE dataset_id = $1", [dump(src_ds.id)]),
      revision_count:
        scalar("SELECT count(*) FROM revisions WHERE dataset_id = $1", [dump(src_ds.id)]),
      docs_with_current_revision:
        scalar(
          "SELECT count(*) FROM documents WHERE dataset_id = $1 AND current_revision_id IS NOT NULL",
          [dump(src_ds.id)]
        ),
      edge_counts: %{
        "content_edges" => length(edges_in("content_edges", src_ds.id)),
        "task_edges" => length(edges_in("task_edges", src_ds.id))
      }
    }
  end

  defp create!(scope, doc_id, attrs, dataset \\ @src) do
    {:ok, doc} = Content.create_document("post", Map.put(attrs, "doc_id", doc_id), dataset, scope)
    doc
  end

  defp insert_edge!(table, from_id, to_id) do
    Repo.query!(
      "INSERT INTO #{table} (id, from_id, to_id, kind, inserted_at" <>
        if(table == "content_edges", do: ", updated_at", else: "") <>
        ") VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'next', now()" <>
        if(table == "content_edges", do: ", now()", else: "") <> ")",
      [from_id, to_id]
    )
  end

  # ── Readers ──────────────────────────────────────────────────────────────────

  defp doc_keys(ds_id),
    do:
      rows(
        "SELECT doc_id, type, status, content::text FROM documents " <>
          "WHERE dataset_id = $1::text::uuid ORDER BY doc_id, type",
        [ds_id]
      )

  defp ids_in(table, ds_id),
    do:
      List.flatten(
        rows("SELECT id::text FROM #{table} WHERE dataset_id = $1::text::uuid", [ds_id])
      )

  defp revision_keys(ds_id),
    do:
      rows(
        "SELECT r.doc_id, r.type, r.action, r.rev, r.content::text FROM revisions r " <>
          "WHERE r.dataset_id = $1::text::uuid ORDER BY r.doc_id, r.inserted_at, r.rev",
        [ds_id]
      )

  # Edges by the doc_ids of their endpoints, so two datasets' edge sets compare
  # without the (necessarily different) row ids.
  defp edges_in(table, ds_id),
    do:
      rows(
        "SELECT f.doc_id, t.doc_id, e.kind FROM #{table} e " <>
          "JOIN documents f ON f.id = e.from_id JOIN documents t ON t.id = e.to_id " <>
          "WHERE f.dataset_id = $1::text::uuid ORDER BY 1, 2, 3",
        [ds_id]
      )

  # Every source tenancy id and source row id that appears anywhere in a row
  # of the new dataset (documents, revisions, mutation_events, schema rows) or
  # in an edge leaving it.
  defp source_ids_in_new_rows(fx, new_ds) do
    source_ids =
      [fx.ws_a.id, fx.proj_a.id, fx.src_ds.id] ++
        List.flatten(
          rows("SELECT id::text FROM documents WHERE dataset_id = $1::text::uuid", [fx.src_ds.id])
        ) ++
        List.flatten(
          rows("SELECT id::text FROM revisions WHERE dataset_id = $1::text::uuid", [fx.src_ds.id])
        )

    texts =
      for table <- ~w(documents revisions mutation_events schema_definitions) do
        rows("SELECT row_to_json(t)::text FROM #{table} t WHERE dataset_id = $1::text::uuid", [
          new_ds
        ])
      end ++
        for table <- ~w(content_edges task_edges) do
          rows(
            "SELECT row_to_json(e)::text FROM #{table} e JOIN documents f ON f.id = e.from_id " <>
              "WHERE f.dataset_id = $1::text::uuid",
            [new_ds]
          )
        end

    texts = texts |> List.flatten() |> Enum.join("\n")
    Enum.filter(source_ids, &String.contains?(texts, &1))
  end

  # What "the source is untouched" means, measured: a fresh dataset export of
  # it matches member by member (row counts and md5 of every row), which
  # covers every table the bundle carries.
  defp source_fingerprint(fx) do
    {:ok, bundle} = WorkspaceBundle.export(fx.ws_a.id, dataset: @src)
    {manifest, _} = Archive.unpack(bundle)
    Map.new(manifest["tables"], &{&1["name"], {&1["row_count"], &1["md5"]}})
  end

  defp rows(sql, params), do: Repo.query!(sql, params).rows
  defp scalar(sql, params), do: sql |> rows(params) |> hd() |> hd()
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
