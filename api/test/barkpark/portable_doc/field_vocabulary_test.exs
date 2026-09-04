defmodule Barkpark.PortableDoc.FieldVocabularyTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.FieldVocabulary, as: V

  # The agency Sanity blockContent registry, verbatim in shape.
  @agency %{
    "type" => "richText",
    "name" => "description",
    "editor" => "blocks",
    "blocks" => %{
      "styles" => ["normal", "h2", "h3", "blockquote"],
      "lists" => ["bullet", "number"],
      "marks" => ["strong", "em"],
      "annotations" => [
        %{"name" => "link", "fields" => [%{"name" => "href", "type" => "string"}]}
      ],
      "of" => ["image"]
    }
  }

  defp p(text, inlines \\ nil),
    do: %{
      "id" => "p1",
      "type" => "paragraph",
      "content" => inlines || [%{"type" => "text", "value" => text}]
    }

  test "blocks_field?/1 is the opt-in" do
    assert V.blocks_field?(@agency)
    refute V.blocks_field?(%{"type" => "richText", "name" => "body"})
  end

  test "the agency vocabulary maps onto exactly the portable-doc types it names" do
    vocab = V.from_field(@agency)

    assert V.allowed_block_types(vocab) ==
             MapSet.new(["paragraph", "heading", "pullquote", "list", "image"])

    assert V.allowed_heading_levels(vocab) == MapSet.new([2, 3])
    assert V.allowed_inline_types(vocab) == MapSet.new(["text", "strong", "em", "link"])
  end

  test "an empty declaration admits nothing but text-less nothing" do
    vocab = V.from_field(%{"editor" => "blocks"})
    assert V.allowed_block_types(vocab) == MapSet.new([])
    assert {:error, {:out_of_vocabulary, _}} = V.validate(vocab, [p("hi")])
  end

  test "an in-vocabulary agency body validates" do
    vocab = V.from_field(@agency)

    blocks = [
      %{"id" => "h", "type" => "heading", "level" => 2, "text" => "Praise"},
      p("x", [
        %{"type" => "text", "value" => "a "},
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "b"}]},
        %{
          "type" => "link",
          "href" => "https://x",
          "children" => [%{"type" => "text", "value" => "c"}]
        }
      ]),
      %{
        "id" => "l",
        "type" => "list",
        "ordered" => true,
        "items" => [[%{"type" => "text", "value" => "one"}]]
      },
      %{
        "id" => "q",
        "type" => "pullquote",
        "content" => [%{"type" => "text", "value" => "quote"}]
      },
      %{"id" => "i", "type" => "image", "src" => "/x.png", "alt" => "x"}
    ]

    assert :ok == V.validate(vocab, blocks)
  end

  test "it refuses by NAME: an h1, a wrong mark, an un-listed block, a wrong list kind" do
    vocab = V.from_field(@agency)

    assert {:error, {:out_of_vocabulary, "heading level 1" <> _}} =
             V.validate(vocab, [%{"id" => "h", "type" => "heading", "level" => 1, "text" => "no"}])

    assert {:error, {:out_of_vocabulary, "inline strikethrough" <> _}} =
             V.validate(vocab, [
               p("x", [
                 %{"type" => "strikethrough", "children" => [%{"type" => "text", "value" => "z"}]}
               ])
             ])

    assert {:error, {:out_of_vocabulary, "block type code" <> _}} =
             V.validate(vocab, [%{"id" => "c", "type" => "code", "value" => "x"}])

    bullet_only = V.from_field(put_in(@agency, ["blocks", "lists"], ["bullet"]))

    assert {:error, {:out_of_vocabulary, "numbered lists" <> _}} =
             V.validate(bullet_only, [
               %{
                 "id" => "l",
                 "type" => "list",
                 "ordered" => true,
                 "items" => [[%{"type" => "text", "value" => "1"}]]
               }
             ])
  end
end
