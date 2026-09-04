defmodule Barkpark.Content.FieldBlockOpsTest do
  @moduledoc """
  Gyldendal parity stage E1 — the field-scoped block op path
  (`Content.apply_field_block_ops/6`). A `richText` field with
  `"editor": "blocks"` is edited as a portable-doc block array stored in the
  projected body shape `%{"blocks", "html"}`; the document-level
  `content["blocks"]` partition is never touched.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias Barkpark.Tenancy

  @dataset "production"

  @vocab %{
    "styles" => ["normal", "h2", "h3", "blockquote"],
    "lists" => ["bullet", "number"],
    "marks" => ["strong", "em"],
    "annotations" => [%{"name" => "link"}],
    "of" => ["image"]
  }

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "e1-ws-#{suffix}", name: "E1 #{suffix}"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "description",
              "title" => "Beskrivelse",
              "type" => "richText",
              "editor" => "blocks",
              "blocks" => @vocab
            },
            %{"name" => "notes", "title" => "Notes", "type" => "richText"}
          ]
        },
        @dataset,
        scope
      )

    {:ok, scope: scope}
  end

  defp create!(scope, content) do
    {:ok, doc} =
      Content.create_document(
        "publication",
        Map.merge(
          %{"doc_id" => "pub-#{System.unique_integer([:positive])}", "title" => "T"},
          content
        ),
        @dataset,
        scope
      )

    doc
  end

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  test "append-block writes content[field] as the projected body shape and re-renders html", %{
    scope: scope
  } do
    doc = create!(scope, %{})

    assert {:ok, %{field: "description", blocks: [%{"id" => "p1"}], written_doc_id: written}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "publication",
               "description",
               [%{"op" => "append-block", "block" => para("p1", "Hello")}],
               @dataset,
               scope
             )

    {:ok, saved} = Content.get_document(written, "publication", @dataset, scope)

    assert %{"blocks" => [%{"id" => "p1", "type" => "paragraph"}], "html" => html} =
             saved.content["description"]

    assert html =~ "Hello"
    refute Map.has_key?(saved.content, "blocks"), "the document-level partition must not appear"
  end

  test "a document with BOTH a document-level blocks partition and a block field keeps both", %{
    scope: scope
  } do
    top = [
      %{"id" => "t1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "top"}]}
    ]

    doc = create!(scope, %{"blocks" => top})

    {:ok, %{written_doc_id: written}} =
      Content.apply_field_block_ops(
        doc.doc_id,
        "publication",
        "description",
        [%{"op" => "append-block", "block" => para("p1", "field")}],
        @dataset,
        scope
      )

    {:ok, saved} = Content.get_document(written, "publication", @dataset, scope)
    assert saved.content["blocks"] == top
    assert [%{"id" => "p1"}] = saved.content["description"]["blocks"]
  end

  test "a legacy plain-string value is upgraded to one paragraph on the first op", %{scope: scope} do
    doc = create!(scope, %{"description" => "Old prose"})

    {:ok, %{blocks: blocks}} =
      Content.apply_field_block_ops(
        doc.doc_id,
        "publication",
        "description",
        [%{"op" => "append-block", "block" => para("p2", "New")}],
        @dataset,
        scope
      )

    assert [%{"type" => "paragraph", "content" => [%{"value" => "Old prose"}]}, %{"id" => "p2"}] =
             blocks
  end

  test "an out-of-vocabulary block is refused BY NAME and nothing is written", %{scope: scope} do
    doc = create!(scope, %{})

    assert {:error, {:out_of_vocabulary, "heading level 1" <> _}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "publication",
               "description",
               [
                 %{
                   "op" => "append-block",
                   "block" => %{"id" => "h", "type" => "heading", "level" => 1, "text" => "x"}
                 }
               ],
               @dataset,
               scope
             )

    case Content.get_document(DraftId.draft_id(doc.doc_id), "publication", @dataset, scope) do
      {:ok, d} -> refute Map.has_key?(d.content || %{}, "description")
      _ -> :ok
    end
  end

  test "a richText field WITHOUT editor: blocks is refused — the Classic form owns it", %{
    scope: scope
  } do
    doc = create!(scope, %{})

    assert {:error, {:not_a_blocks_field, "notes"}} =
             Content.apply_field_block_ops(
               doc.doc_id,
               "publication",
               "notes",
               [%{"op" => "append-block", "block" => para("p1", "x")}],
               @dataset,
               scope
             )
  end

  test "Content.doc_to_form keeps the block field as its map and flattens the plain richText to html",
       %{
         scope: scope
       } do
    doc =
      create!(scope, %{
        "description" => %{"blocks" => [para("p1", "b")], "html" => "<p>b</p>"},
        "notes" => %{"blocks" => [], "html" => "<p>n</p>"}
      })

    {:ok, schema} = Content.resolve_schema("publication", @dataset, scope)
    form = Content.doc_to_form(doc, schema)
    assert %{"blocks" => [%{"id" => "p1"}], "html" => _} = form["description"]
    assert form["notes"] == "<p>n</p>"
  end

  # task-c46967eb3dc49e77 — site (4), block_ops.ex `apply_field_block_ops/6`.
  # The projected field body is read on a SCREEN, so the caller names
  # `:article`; before this row it handed style-less opts and
  # `Render.render_block/2`'s `Map.get(opts, :style, :email)` default stamped
  # mail typography into a persisted field. Siblings: #15973, #16037.
  test "the projected field html names the ARTICLE surface, not the :email default", %{
    scope: scope
  } do
    doc = create!(scope, %{})
    blocks = [para("p1", "field body copy that must not carry mail type")]

    {:ok, %{written_doc_id: written}} =
      Content.apply_field_block_ops(
        doc.doc_id,
        "publication",
        "description",
        [
          %{
            "op" => "append-block",
            "block" => para("p1", "field body copy that must not carry mail type")
          }
        ],
        @dataset,
        scope
      )

    {:ok, saved} = Content.get_document(written, "publication", @dataset, scope)
    stored = saved.content["description"]["html"]

    article_html = Barkpark.PortableDoc.Render.render_blocks(blocks, %{style: :article})
    email_html = Barkpark.PortableDoc.Render.render_blocks(blocks, %{style: :email})

    # Not one byte of the `:email` paragraph stamp is persisted.
    refute stored =~ "font-family:"
    refute stored =~ "font-size:"
    refute stored =~ "line-height:"

    assert stored == article_html

    # ANTI-VACUITY: the two surfaces really do differ for this very block, so
    # the equality above is a CHOICE of surface, not two renders coincidentally
    # agreeing (pre-stamp they were the same bytes, which is why this hid).
    refute stored == email_html
    assert email_html =~ "font-size:17px"
  end
end
