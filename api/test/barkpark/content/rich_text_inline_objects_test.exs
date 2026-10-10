defmodule Barkpark.Content.RichTextInlineObjectsTest do
  @moduledoc """
  task-85fee859cf3bfef6 / task-f72c3157e0476e56 — a richText field's block
  vocabulary may declare inline object types under `blocks.inline` (Sanity's
  `block.of`), stored flat inside prose as `{type: <name>, ...fields}`.

  The real case is post-11 from the Sanity parity seed: a `chip` with `text`
  and `tone` in the middle of a paragraph. A declared inline object is
  accepted by the block-op write path and by the v2 schema walk, with its
  declared fields checked; an inline type the field does not declare is the
  named finding `:inline_type_undeclared`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{SchemaDefinition, Validation}
  alias Barkpark.PortableDoc.FieldVocabulary
  alias Barkpark.Tenancy

  @dataset "production"

  @chip %{
    "name" => "chip",
    "fields" => [
      %{"name" => "text", "type" => "string", "validation" => %{"required" => true}},
      %{"name" => "tone", "type" => "string", "options" => %{"list" => ["positive", "caution"]}}
    ]
  }

  @blocks %{
    "styles" => ["normal"],
    "lists" => ["bullet"],
    "marks" => ["strong"],
    "annotations" => [%{"name" => "link"}],
    "inline" => [@chip, "mention"]
  }

  @field %{"name" => "body", "type" => "richText", "editor" => "blocks", "blocks" => @blocks}
  @schema %{"name" => "post", "fields" => [%{"name" => "title", "type" => "string"}, @field]}

  defp text(v), do: %{"type" => "text", "value" => v}
  defp chip(attrs), do: Map.merge(%{"type" => "chip"}, attrs)
  defp para(content), do: %{"type" => "paragraph", "content" => content}

  # post-11's paragraph as the Sanity seed wrote it: `_type` renamed to
  # `type`, the span sibling's `_key` carried along.
  defp post11,
    do:
      para([
        text("Status "),
        chip(%{"_key" => "k1", "text" => "Reviewed", "tone" => "positive"}),
        text(", written with Ada.")
      ])

  describe "the declaration" do
    test "a field declaring blocks.inline makes the schema a v2 shape" do
      refute SchemaDefinition.flat?(@schema)

      plain = %{@field | "blocks" => Map.delete(@blocks, "inline")}
      assert SchemaDefinition.flat?(%{"name" => "post", "fields" => [plain]})
    end

    test "declared inline names join the allowed inline types; a bare string is a name" do
      vocab = FieldVocabulary.from_field(@field)
      allowed = FieldVocabulary.allowed_inline_types(vocab)

      assert MapSet.member?(allowed, "chip")
      assert MapSet.member?(allowed, "mention")
      refute MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "chip")
    end

    test "declares_inline? is false without a usable entry" do
      refute FieldVocabulary.declares_inline?(%{"blocks" => %{"inline" => []}})
      refute FieldVocabulary.declares_inline?(%{"blocks" => %{"inline" => [%{"fields" => []}]}})
      refute FieldVocabulary.declares_inline?(%{"blocks" => %{"of" => ["image"]}})
      assert FieldVocabulary.declares_inline?(@field)
    end
  end

  describe "block-op vocabulary check (FieldVocabulary.validate/2)" do
    setup do: %{vocab: FieldVocabulary.from_field(@field)}

    test "post-11's chip paragraph is accepted", %{vocab: vocab} do
      assert :ok = FieldVocabulary.validate(vocab, [post11()])
    end

    test "a declared chip missing its required text is refused at its field", %{vocab: vocab} do
      assert {:error, {:out_of_vocabulary, msg}} =
               FieldVocabulary.validate(vocab, [para([chip(%{"tone" => "positive"})])])

      assert msg =~ "paragraph/content/0/text"
      assert msg =~ "Required"
    end

    test "a tone outside options.list is refused", %{vocab: vocab} do
      assert {:error, {:out_of_vocabulary, msg}} =
               FieldVocabulary.validate(vocab, [para([chip(%{"text" => "x", "tone" => "loud"})])])

      assert msg =~ "must be one of positive, caution"
    end

    test "a bare-string declaration admits the type with no field checks", %{vocab: vocab} do
      assert :ok = FieldVocabulary.validate(vocab, [para([%{"type" => "mention", "any" => 1}])])
    end

    test "an undeclared inline type is still refused, with the old wording", %{vocab: vocab} do
      assert {:error, {:out_of_vocabulary, "inline badge is not in this field's vocabulary"}} =
               FieldVocabulary.validate(vocab, [para([%{"type" => "badge"}])])
    end

    test "a chip nested in a strong wrapper and in a list item is checked", %{vocab: vocab} do
      nested = para([%{"type" => "strong", "children" => [chip(%{"tone" => "positive"})]}])
      assert {:error, {:out_of_vocabulary, m1}} = FieldVocabulary.validate(vocab, [nested])
      assert m1 =~ "content/0/children/0/text"

      list = %{"type" => "list", "ordered" => false, "items" => [[chip(%{"text" => "ok"})], []]}
      assert :ok = FieldVocabulary.validate(vocab, [list])

      bad_list = %{list | "items" => [[text("a")], [chip(%{})]]}
      assert {:error, {:out_of_vocabulary, m2}} = FieldVocabulary.validate(vocab, [bad_list])
      assert m2 =~ "items/1/0/text"
    end

    test "a field without blocks.inline keeps refusing a chip" do
      vocab = FieldVocabulary.from_field(%{@field | "blocks" => Map.delete(@blocks, "inline")})

      assert {:error, {:out_of_vocabulary, "inline chip is not in this field's vocabulary"}} =
               FieldVocabulary.validate(vocab, [post11()])
    end
  end

  describe "schema walk (advise/enforce door)" do
    test "post-11 passes, in both stored shapes" do
      assert {:ok, _} = Validation.validate(%{"body" => [post11()]}, "t", @schema)

      assert {:ok, _} =
               Validation.validate(
                 %{"body" => %{"blocks" => [post11()], "html" => ""}},
                 "t",
                 @schema
               )
    end

    test "an undeclared inline type is the named finding inline_type_undeclared" do
      body = [para([text("a"), %{"type" => "badge"}])]

      assert %{errors: [finding], warnings: []} =
               Validation.check_findings(%{"body" => body}, "t", @schema)

      assert finding.path == "/body/0/content/1"
      assert finding.code == :inline_type_undeclared
      assert finding.params == %{type_name: "badge"}
    end

    test "a declared chip's field findings land at the chip" do
      body = [para([text("a"), chip(%{"tone" => "loud"})])]
      assert {:error, %{"body" => msgs}} = Validation.validate(%{"body" => body}, "t", @schema)
      assert Enum.any?(msgs, &(&1 =~ "/body/0/content/1/text" and &1 =~ "Required"))
      assert Enum.any?(msgs, &(&1 =~ "/body/0/content/1/tone" and &1 =~ "must be one of"))
    end

    test "a field that declares no inline types gains no inline finding" do
      plain = %{@field | "blocks" => Map.put(Map.delete(@blocks, "inline"), "of", [@chip])}
      schema = %{"name" => "post", "fields" => [plain]}
      body = [para([%{"type" => "badge"}])]

      assert %{errors: [], warnings: []} =
               Validation.check_findings(%{"body" => body}, "t", schema)
    end

    test "the declared shape wins over the built-in verdict chip" do
      # The built-in chip carries tone/strong/text/note; this field's chip
      # declares text as required, so a built-in-shaped chip with only a note
      # is a finding here.
      body = [para([chip(%{"note" => "n"})])]
      assert {:error, %{"body" => [msg]}} = Validation.validate(%{"body" => body}, "t", @schema)
      assert msg =~ "/body/0/content/0/text"
    end
  end

  describe "block ops through Content" do
    setup do
      suffix = System.unique_integer([:positive])

      {:ok, ws} =
        Tenancy.create_workspace(%{slug: "inlineobj-ws-#{suffix}", name: "IO #{suffix}"})

      {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
      {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => [@field]},
          @dataset,
          scope
        )

      {:ok, doc} =
        Content.create_document(
          "post",
          %{"doc_id" => "post-#{suffix}", "title" => "post-11", "body" => %{"blocks" => []}},
          @dataset,
          scope
        )

      %{scope: scope, doc: doc}
    end

    test "appending post-11's chip paragraph applies and stores the chip as written",
         %{scope: scope, doc: doc} do
      block = Map.put(post11(), "id", "p-chip")

      assert {:ok, %{blocks: blocks}} =
               Content.apply_field_block_ops(
                 doc.doc_id,
                 "post",
                 "body",
                 [%{"op" => "append-block", "block" => block}],
                 @dataset,
                 scope
               )

      stored = Enum.find(blocks, &(&1["id"] == "p-chip"))
      assert Enum.at(stored["content"], 1) == Enum.at(block["content"], 1)
    end

    test "appending a chip without its required text is refused", %{scope: scope, doc: doc} do
      block = %{"id" => "p-bad", "type" => "paragraph", "content" => [chip(%{})]}

      assert {:error, {:out_of_vocabulary, msg}} =
               Content.apply_field_block_ops(
                 doc.doc_id,
                 "post",
                 "body",
                 [%{"op" => "append-block", "block" => block}],
                 @dataset,
                 scope
               )

      assert msg =~ "text"
    end
  end
end
