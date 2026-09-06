defmodule Barkpark.Content.Papers.TableEditingOpTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.PortableDoc.TableEditing
  alias Barkpark.Repo

  @dataset "production"
  @doc_type "table_editing_op_post"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Table editing op post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "layout" => [%{"kind" => "field", "name" => "title"}]
        },
        @dataset
      )

    :ok
  end

  for intent <- ~w(patch-table-cells patch-table-structure) do
    test "#{intent} requires a revision before payload validation in every paper lane" do
      {slug, paper} = seed_table!()
      # Deliberately malformed: missing revision must win before shape parsing.
      op = %{"op" => unquote(intent), "id" => "table", "shape" => nil}

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_op(slug, op, @dataset)

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops(slug, [op], @dataset)

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_ops_once(
                 slug,
                 [op],
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:table-editing"
               )

      assert {:error, :precondition_failed} =
               Content.apply_paper_block_op(slug, op, @dataset, if_rev: paper.content["rev"] + 1)

      assert Content.get_paper(slug).content == paper.content
    end

    test "#{intent} requires a revision before payload validation in both document lanes" do
      {doc, table} = seed_table_document!()
      op = %{"op" => unquote(intent), "id" => "table", "shape" => nil}

      assert {:error, :precondition_failed} =
               Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset)

      assert {:error, :precondition_failed} =
               Content.apply_document_block_op_once(
                 doc.doc_id,
                 @doc_type,
                 op,
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:table-editing"
               )

      assert {:error, {:rev_mismatch, %{actual: actual, expected: "stale-revision"}}} =
               Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset,
                 if_rev: "stale-revision"
               )

      assert actual == doc.rev
      {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
      assert stored.content["blocks"] == [table]
      assert stored.rev == doc.rev
    end
  end

  test "cell edits preserve authoritative wrappers and exact retries do not write again" do
    source = metadata_table()
    {slug, paper} = seed_table!([source])
    request = Ecto.UUID.generate()
    op = cells_op(source, "Changed cell")

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request,
               "user:table-editing",
               if_rev: paper.content["rev"]
             )

    [saved] = Content.get_paper(slug).content["blocks"]

    expected =
      put_in(
        source,
        ["rows", Access.at(0), "cells", Access.at(0), "content"],
        inline("Changed cell")
      )

    assert saved == expected
    before_replay = Content.get_paper(slug)

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request,
               "user:table-editing",
               if_rev: paper.content["rev"]
             )

    assert Content.get_paper(slug) == before_replay
  end

  test "single paper and direct document cells use the same authoritative merge" do
    {slug, paper} = seed_table!()
    op = cells_op(table(), "Single paper cell")

    assert {:ok, %{block_id: "table"}} =
             Content.apply_paper_block_op(slug, op, @dataset, if_rev: paper.content["rev"])

    assert hd(Content.get_paper(slug).content["blocks"])["rows"] == [
             [inline("Single paper cell")]
           ]

    {doc, source} = seed_table_document!()

    assert {:ok, %{block_id: "table", written_doc_id: written_id}} =
             Content.apply_document_block_op(
               doc.doc_id,
               @doc_type,
               cells_op(source, "Document cell"),
               @dataset,
               if_rev: doc.rev
             )

    {:ok, stored} = Content.get_document(written_id, @doc_type, @dataset)
    assert stored.content["blocks"] == [Map.put(source, "rows", [[inline("Document cell")]])]
  end

  test "document exact-once Table edits replay without another write" do
    {doc, source} = seed_table_document!()
    op = cells_op(source, "Exact document cell")
    request = Ecto.UUID.generate()

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request,
               "user:table-editing",
               if_rev: doc.rev
             )

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request,
               "user:table-editing",
               if_rev: doc.rev
             )

    {:ok, stored} = Content.get_document(receipt.written_doc_id, @doc_type, @dataset)

    assert stored.content["blocks"] == [
             Map.put(source, "rows", [[inline("Exact document cell")]])
           ]
  end

  test "every structural intent lowers to the exact storage-lens result" do
    source = %{
      "id" => "table",
      "type" => "table",
      "table-meta" => true,
      "head" => [inline("A"), inline("B")],
      "rows" => [
        %{
          "cells" => [%{"content" => inline("One"), "cell-meta" => 1}, inline("Two")],
          "row-meta" => 1
        },
        %{
          "cells" => [inline("Three"), %{"content" => inline("Four"), "cell-meta" => 4}],
          "row-meta" => 2
        }
      ]
    }

    for action <-
          ~w(add-row remove-row:0 up-row:1 down-row:0 add-column remove-column:0 left-column:1 right-column:0 remove-header) do
      {slug, paper} = seed_table!([source])
      {:ok, %{shape: shape}} = TableEditing.project(source)
      {:ok, expected} = TableEditing.apply_action(source, shape, action)

      op = %{
        "op" => "patch-table-structure",
        "id" => "table",
        "shape" => shape,
        "action" => action
      }

      assert {:ok, _receipt} =
               Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: paper.content["rev"])

      assert Content.get_paper(slug).content["blocks"] == [expected], action
    end

    no_head = Map.delete(source, "head")
    {slug, paper} = seed_table!([no_head])
    {:ok, %{shape: shape}} = TableEditing.project(no_head)
    {:ok, expected} = TableEditing.apply_action(no_head, shape, "add-header")

    op = %{
      "op" => "patch-table-structure",
      "id" => "table",
      "shape" => shape,
      "action" => "add-header"
    }

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: paper.content["rev"])

    assert Content.get_paper(slug).content["blocks"] == [expected]
  end

  test "a normalizing legacy sibling refuses a target edit instead of changing the sibling" do
    {slug, paper} = seed_table!()
    legacy = %{"id" => "legacy-table", "type" => "table", "rows" => [["Authored scalar"]]}
    original = Map.put(paper.content, "blocks", [table(), legacy])
    Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: original])

    assert {:error, _reason} =
             Content.apply_paper_block_ops(slug, [cells_op(table(), "Must not save")], @dataset,
               if_rev: original["rev"]
             )

    assert Content.get_paper(slug).content == original
  end

  test "normalization-idempotent legacy siblings are preserved rather than unnecessarily blocked" do
    {slug, paper} = seed_table!()
    # Ragged grids are outside the strict editor, but the reader and normalizer
    # already preserve this shape. Editing a separate strict Table is safe.
    legacy = %{
      "id" => "legacy-table",
      "type" => "table",
      "rows" => [[inline("A")], [inline("B"), inline("C")]]
    }

    original = Map.put(paper.content, "blocks", [table(), legacy])
    Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: original])

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(
               slug,
               [cells_op(table(), "Safe isolated edit")],
               @dataset,
               if_rev: original["rev"]
             )

    assert Enum.at(Content.get_paper(slug).content["blocks"], 1) == legacy
  end

  test "normalization census includes nested legacy Tables and both private intents" do
    {slug, paper} = seed_table!()
    legacy = %{"id" => "legacy-table", "type" => "table", "rows" => [["Legacy scalar"]]}
    nested = %{"id" => "section", "type" => "section", "blocks" => [legacy], "title" => "Keep"}
    original = Map.put(paper.content, "blocks", [table(), nested])
    Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: original])
    cell_op = cells_op(table(), "Rejected")

    action_op = %{
      "op" => "patch-table-structure",
      "id" => "table",
      "shape" => cell_op["shape"],
      "action" => "add-row"
    }

    for op <- [cell_op, action_op] do
      assert {:error, _reason} =
               Content.apply_paper_block_op(slug, op, @dataset, if_rev: original["rev"])

      assert Content.get_paper(slug).content == original

      {doc, _source} = seed_table_document!()
      doc_content = Map.put(doc.content, "blocks", [table(), nested])
      Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: doc_content])

      assert {:error, _} =
               Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset,
                 if_rev: doc.rev
               )

      assert {:error, _} =
               Content.apply_document_block_op_once(
                 doc.doc_id,
                 @doc_type,
                 op,
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:table-editing",
                 if_rev: doc.rev
               )

      {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
      assert stored.content == doc_content
      assert stored.rev == doc.rev
    end
  end

  test "a contextual Table edit cannot normalize a legacy Table outside its canvas run" do
    {slug, paper} = seed_table!()
    section = %{"id" => "section", "type" => "section", "blocks" => [table()]}
    legacy = %{"id" => "outside", "type" => "table", "rows" => [["Must stay scalar"]]}
    original = Map.put(paper.content, "blocks", [section, legacy])
    Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: original])

    assert {:error, _reason} =
             Content.apply_paper_block_ops(slug, [cells_op(table(), "Rejected")], @dataset,
               if_rev: original["rev"],
               canvas_run_context: %{
                 container_kind: "section",
                 container_id: "section",
                 container_run_ids: ["table"]
               }
             )

    assert Content.get_paper(slug).content == original
  end

  test "nested cell edits retain Section, Columns, siblings and placement metadata" do
    source = metadata_table()
    sibling = %{"id" => "sibling", "type" => "paragraph", "text" => "Keep sibling"}

    section = %{
      "id" => "section",
      "type" => "section",
      "layout" => "stack",
      "section-meta" => true,
      "blocks" => [
        %{
          "id" => "columns",
          "type" => "columns",
          "columns-meta" => true,
          "columns" => [[source], [sibling]]
        }
      ]
    }

    {slug, paper} = seed_table!([section])

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(slug, [cells_op(source, "Nested cell")], @dataset,
               if_rev: paper.content["rev"]
             )

    expected =
      put_in(
        section,
        [
          "blocks",
          Access.at(0),
          "columns",
          Access.at(0),
          Access.at(0),
          "rows",
          Access.at(0),
          "cells",
          Access.at(0),
          "content"
        ],
        inline("Nested cell")
      )

    assert Content.get_paper(slug).content["blocks"] == [expected]
  end

  test "wrong shape, coordinates, extra keys and duplicate targets fail without writing" do
    {slug, paper} = seed_table!()
    valid = cells_op(table(), "Rejected")

    for op <- [
          Map.put(valid, "shape", %{}),
          Map.put(valid, "extra", true),
          put_in(valid, ["cells", Access.at(0), "row"], 1),
          put_in(valid, ["cells", Access.at(0), "column"], -1),
          put_in(valid, ["cells", Access.at(0), "extra"], true),
          Map.put(valid, "cells", valid["cells"] ++ valid["cells"])
        ] do
      assert {:error, _reason} =
               Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: paper.content["rev"])

      assert Content.get_paper(slug).content == paper.content
    end

    duplicate = Map.put(paper.content, "blocks", [table(), table()])
    Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: duplicate])

    assert {:error, _reason} =
             Content.apply_paper_block_ops(slug, [valid], @dataset, if_rev: paper.content["rev"])

    assert Content.get_paper(slug).content == duplicate
  end

  test "an exact cell no-op retains Paper content and revision on single and batch lanes" do
    {slug, paper} = seed_table!()
    before = Content.get_paper(slug)
    op = cells_op(table(), "Original cell")

    assert {:ok, _receipt} =
             Content.apply_paper_block_op(slug, op, @dataset, if_rev: paper.content["rev"])

    assert Content.get_paper(slug) == before

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: paper.content["rev"])

    assert Content.get_paper(slug) == before
  end

  test "cell edits settle before structure within one atomic batch and failure rolls everything back" do
    {slug, paper} = seed_table!()
    cell_op = cells_op(table(), "Cell before structure")

    action_op = %{
      "op" => "patch-table-structure",
      "id" => "table",
      "shape" => cell_op["shape"],
      "action" => "add-column"
    }

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(slug, [cell_op, action_op], @dataset,
               if_rev: paper.content["rev"]
             )

    assert hd(Content.get_paper(slug).content["blocks"])["rows"] == [
             [inline("Cell before structure"), []]
           ]

    {other_slug, other} = seed_table!()
    invalid_action = Map.put(action_op, "action", "remove-column:0")

    assert {:error, _reason} =
             Content.apply_paper_block_ops(other_slug, [cell_op, invalid_action], @dataset,
               if_rev: other.content["rev"]
             )

    assert Content.get_paper(other_slug).content == other.content
  end

  test "old canonical coarse canvas saves remain accepted through the Table migration" do
    {slug, paper} = seed_table!()

    op = %{
      "op" => "patch-block",
      "id" => "table",
      "patch" => %{"rows" => [[inline("Old canvas still settles")]]}
    }

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: paper.content["rev"])

    [stored] = Content.get_paper(slug).content["blocks"]
    assert stored["rows"] == [[inline("Old canvas still settles")]]
    assert stored["table-meta"] == table()["table-meta"]
    assert {:ok, _projection} = TableEditing.project(stored)
  end

  test "synthetic IDs cannot turn id-less stored Tables into authored targets" do
    idless = Map.delete(table(), "id")

    for {blocks, synthetic_id} <- [
          {[idless], "block-0"},
          {[%{"id" => "section", "type" => "section", "blocks" => [idless]}], "section-0"}
        ] do
      {slug, paper} = seed_table!()
      original = Map.put(paper.content, "blocks", blocks)
      Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: original])
      op = Map.put(cells_op(table(), "Forbidden synthesized target"), "id", synthetic_id)

      assert {:error, _} =
               Content.apply_paper_block_op(slug, op, @dataset, if_rev: original["rev"])

      assert {:error, _} =
               Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: original["rev"])

      assert {:error, _} =
               Content.apply_paper_block_ops_once(
                 slug,
                 [op],
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:table-editing",
                 if_rev: original["rev"]
               )

      assert Content.get_paper(slug).content == original

      {doc, _table} = seed_table_document!()
      doc_content = Map.put(doc.content, "blocks", blocks)
      Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: doc_content])

      assert {:error, _} =
               Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset,
                 if_rev: doc.rev
               )

      assert {:error, _} =
               Content.apply_document_block_op_once(
                 doc.doc_id,
                 @doc_type,
                 op,
                 @dataset,
                 Ecto.UUID.generate(),
                 "user:table-editing",
                 if_rev: doc.rev
               )

      {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
      assert stored.content == doc_content
      assert stored.rev == doc.rev
    end
  end

  test "exact-once no-ops and replays retain Paper and document revisions" do
    {slug, paper} = seed_table!()
    op = cells_op(table(), "Original cell")
    before = Content.get_paper(slug)
    request = Ecto.UUID.generate()

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request,
               "user:table-editing",
               if_rev: paper.content["rev"]
             )

    assert receipt.rev == paper.content["rev"]

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request,
               "user:table-editing",
               if_rev: paper.content["rev"]
             )

    assert Content.get_paper(slug) == before

    {doc, _table} = seed_table_document!()
    {:ok, doc_before} = Content.get_document(doc.doc_id, @doc_type, @dataset)

    assert {:ok, %{no_op: true, rev: direct_rev}} =
             Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset, if_rev: doc.rev)

    assert direct_rev == doc.rev
    request = Ecto.UUID.generate()

    assert {:ok, doc_receipt, :applied} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request,
               "user:table-editing",
               if_rev: doc.rev
             )

    assert doc_receipt.rev == doc.rev

    assert {:ok, ^doc_receipt, :replayed} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request,
               "user:table-editing",
               if_rev: doc.rev
             )

    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert stored == doc_before
  end

  test "a net-zero private Table batch does not create a revision" do
    {slug, paper} = seed_table!()
    before = Content.get_paper(slug)

    assert {:ok, receipt} =
             Content.apply_paper_block_ops(
               slug,
               [cells_op(table(), "Temporary"), cells_op(table(), "Original cell")],
               @dataset,
               if_rev: paper.content["rev"]
             )

    assert receipt.rev == paper.content["rev"]
    assert Content.get_paper(slug) == before
  end

  test "editing a strict Table cannot mint IDs into unrelated top-level or nested Tables" do
    idless = Map.delete(table(), "id")

    for sibling <- [idless, %{"id" => "section", "type" => "section", "blocks" => [idless]}] do
      {slug, paper} = seed_table!()
      original = Map.put(paper.content, "blocks", [table(), sibling])
      Repo.update_all(from(d in Document, where: d.id == ^paper.id), set: [content: original])
      op = cells_op(table(), "Must not mint a sibling ID")

      assert {:error, _} =
               Content.apply_paper_block_op(slug, op, @dataset, if_rev: original["rev"])

      assert {:error, _} =
               Content.apply_paper_block_ops(slug, [op], @dataset, if_rev: original["rev"])

      assert Content.get_paper(slug).content == original
    end
  end

  test "document lanes cannot mint an ID into an unrelated Table" do
    {doc, _source} = seed_table_document!()
    idless = Map.delete(table(), "id")
    original = Map.put(doc.content, "blocks", [table(), idless])
    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: original])
    op = cells_op(table(), "Must not mint a sibling ID")

    assert {:error, _} =
             Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset, if_rev: doc.rev)

    assert {:error, _} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               Ecto.UUID.generate(),
               "user:table-editing",
               if_rev: doc.rev
             )

    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert stored.content == original
    assert stored.rev == doc.rev
  end

  defp cells_op(source, text) do
    row_shapes =
      Enum.map(source["rows"], fn row ->
        cells = if is_map(row), do: row["cells"], else: row

        %{
          "kind" => if(is_map(row), do: "cells-map", else: "array"),
          "cells" => Enum.map(cells, &if(is_map(&1), do: "content-map", else: "inline-array"))
        }
      end)

    shape = %{"v" => 1, "head" => %{"state" => "absent"}, "rows" => row_shapes}

    %{
      "op" => "patch-table-cells",
      "id" => source["id"],
      "shape" => shape,
      "cells" => [%{"area" => "body", "row" => 0, "column" => 0, "content" => inline(text)}]
    }
  end

  defp seed_table!(blocks \\ nil) do
    slug = "table-editing-op-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: blocks || [table()]
      })

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp seed_table_document! do
    id = "table-editing-doc-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(@doc_type, %{"doc_id" => id, "title" => "Table"}, @dataset)

    content = %{"title" => "Table", "blocks" => [table()]}
    Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [content: content])
    {:ok, current} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    {current, table()}
  end

  defp table do
    %{
      "id" => "table",
      "type" => "table",
      "rows" => [[[%{"type" => "text", "value" => "Original cell"}]]],
      "table-meta" => %{"keep" => true}
    }
  end

  defp metadata_table do
    %{
      table()
      | "rows" => [
          %{
            "cells" => [%{"content" => inline("Original cell"), "cell-meta" => %{"keep" => true}}],
            "row-meta" => %{"keep" => true}
          }
        ]
    }
  end

  defp inline(text), do: [%{"type" => "text", "value" => text}]
end
