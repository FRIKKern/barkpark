defmodule Barkpark.Content.RichTextObjectBlocksTest do
  @moduledoc """
  task-152cacba913a4724 — a richText field's block vocabulary may declare a
  custom object block (`blocks.of` entry `{name, fields}`, Sanity's
  `defineArrayMember({type: 'object', …})`), and every block of that type has
  its declared fields checked: on the v2 schema walk and on the Studio block-op
  write path.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.{SchemaDefinition, Validation}
  alias Barkpark.PortableDoc.FieldVocabulary

  @callout %{
    "name" => "callout",
    "fields" => [
      %{
        "name" => "tone",
        "type" => "string",
        "options" => %{"list" => [%{"title" => "Info", "value" => "info"}, "warning"]},
        "validation" => %{"required" => true}
      },
      %{"name" => "text", "type" => "text", "validation" => %{"required" => true}}
    ]
  }

  @field %{
    "name" => "body",
    "type" => "richText",
    "editor" => "blocks",
    "blocks" => %{"styles" => ["normal", "h2"], "of" => ["image", @callout]}
  }

  @schema %{"name" => "post", "fields" => [%{"name" => "title", "type" => "string"}, @field]}

  defp para(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}

  defp callout(attrs), do: Map.merge(%{"type" => "callout"}, attrs)

  describe "schema validation" do
    test "an object entry in blocks.of makes the schema a v2 shape" do
      refute SchemaDefinition.flat?(@schema)

      assert SchemaDefinition.flat?(%{
               "name" => "x",
               "fields" => [%{@field | "blocks" => %{"of" => ["image"]}}]
             })
    end

    test "a valid callout passes, beside other blocks" do
      body = [para("hi"), callout(%{"tone" => "info", "text" => "Note"}), %{"type" => "image"}]
      assert {:ok, _} = Validation.validate(%{"body" => body}, "t", @schema)
    end

    test "a tone outside options.list and a missing text are reported at the block" do
      body = [para("hi"), callout(%{"tone" => "loud"})]
      assert {:error, %{"body" => msgs}} = Validation.validate(%{"body" => body}, "t", @schema)
      assert Enum.any?(msgs, &(&1 =~ "/body/1/tone" and &1 =~ "must be one of info, warning"))
      assert Enum.any?(msgs, &(&1 =~ "/body/1/text" and &1 =~ "Required"))
    end
  end

  describe "FieldVocabulary (the block-op write path)" do
    test "the object block's name joins the allowed block types" do
      vocab = FieldVocabulary.from_field(@field)
      assert MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "callout")
      assert MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "image")
    end

    test "a valid callout is admitted" do
      vocab = FieldVocabulary.from_field(@field)

      assert :ok =
               FieldVocabulary.validate(vocab, [callout(%{"tone" => "warning", "text" => "x"})])
    end

    test "an invalid callout is refused naming the field" do
      vocab = FieldVocabulary.from_field(@field)

      assert {:error, {:out_of_vocabulary, reason}} =
               FieldVocabulary.validate(vocab, [callout(%{"tone" => "loud", "text" => "x"})])

      assert reason =~ "callout/tone"
    end

    test "a vocabulary of plain strings is unchanged" do
      vocab = FieldVocabulary.from_field(%{@field | "blocks" => %{"of" => ["image"]}})
      refute MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "callout")
      assert {:error, {:out_of_vocabulary, _}} = FieldVocabulary.validate(vocab, [callout(%{})])
    end
  end
end
