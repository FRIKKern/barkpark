defmodule Barkpark.Content.PreviewTextTextMaxTypeTest do
  @moduledoc """
  task-38ae9ed78acabff4: three parts a Sanity `prepare` writes in code.
  `|max:N` cuts a text to N characters, as `text.slice(0, N) + "..."` does.
  `|text` reads the text of a Portable Text value. `|type` shows a referenced
  document's type by its schema title. Made-up content only.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.PreviewText
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "preview-text-max-type-#{System.unique_integer([:positive])}"

  defp nobody, do: fn _id -> nil end

  defp block(text, style \\ "normal"),
    do: %{
      "_type" => "block",
      "style" => style,
      "children" => [%{"_type" => "span", "text" => text}]
    }

  test "|max:N cuts a text longer than N characters and adds ..." do
    root = %{"summary" => "A short note about the spring garden fair", "code" => "abc"}

    assert PreviewText.format("summary|max:12", root, nobody()) == "A short note..."
    assert PreviewText.format("summary|max:80", root, nobody()) == root["summary"]
    assert PreviewText.format("summary|max:12:…", root, nobody()) == "A short note…"
    # An empty end cuts with nothing after it, so a template can always add "...".
    assert PreviewText.format("{summary|max:12:}...", root, nobody()) == "A short note..."
    assert PreviewText.format("{code|max:12:}...", root, nobody()) == "abc..."
    assert PreviewText.format("summary|max:7|upper", root, nobody()) == "A SHORT..."
    assert PreviewText.format("summary|max:0", root, nobody()) == root["summary"]
    # Characters are code points: an emoji counts once.
    assert PreviewText.format("t|max:3", %{"t" => "🌱🌱🌱🌱"}, nobody()) == "🌱🌱🌱..."
  end

  test "|text joins the spans; :line and :heading take the first that holds text" do
    body = [
      block("  "),
      %{
        "_type" => "block",
        "children" => [
          %{"_type" => "span", "text" => "First line, "},
          %{"_type" => "span", "text" => "in two spans."}
        ]
      },
      %{"_type" => "image", "asset" => %{"_ref" => "image-abc-10x10-png"}},
      block(" A heading ", "h3"),
      block("Last line.")
    ]

    root = %{"body" => body}

    assert PreviewText.format("body|text", root, nobody()) ==
             "First line, in two spans.  A heading  Last line."

    assert PreviewText.format("body|text:line", root, nobody()) == "First line, in two spans."
    assert PreviewText.format("body|text:heading", root, nobody()) == "A heading"
    assert PreviewText.format("body.4|text", root, nobody()) == "Last line."
    assert PreviewText.format("body|text|max:10", root, nobody()) == "First line..."

    assert PreviewText.format(
             ["body|text:heading", "body|text:line"],
             %{"body" => Enum.take(body, 2)},
             nobody()
           ) == "First line, in two spans."

    # A string is its own text; :line takes its first line that holds text.
    assert PreviewText.format("body|text", %{"body" => "Plain answer"}, nobody()) ==
             "Plain answer"

    assert PreviewText.format("body|text:line", %{"body" => "\n  Top line \nNext"}, nobody()) ==
             "Top line"

    empty = ["body|text", %{"text" => "Empty"}]
    assert PreviewText.format(empty, %{"body" => [%{"_type" => "image"}]}, nobody()) == "Empty"
    assert PreviewText.format(empty, %{}, nobody()) == "Empty"
  end

  test "|type shows a type name by its schema title, or as stored" do
    titles = %{"guide" => "Guide"}

    targets = %{
      "g1" => %{"_type" => "guide", "title" => "Planting"},
      "r1" => %{"_type" => "recipe"}
    }

    deref = &Map.get(targets, &1)
    opts = [type_title: &Map.get(titles, &1)]

    assert PreviewText.format(
             "{target._type|type}: {target.title}",
             %{"target" => %{"_ref" => "g1"}},
             deref,
             opts
           ) == "Guide: Planting"

    assert PreviewText.format("target._type|type", %{"target" => "r1"}, deref, opts) == "recipe"
    assert PreviewText.format("target._type|type", %{"target" => "g1"}, deref) == "guide"
  end

  test "a desk row reads a referenced document's type and Portable Text" do
    dataset = @dataset

    for {name, title} <- [{"guide", "Guide"}, {"recipe", "Recipe"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          dataset
        )
    end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "card",
          "title" => "Card",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "target", "title" => "Target", "type" => "reference"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "list_preview" => %{
            "subtitle" => "{target._type|type}: {target.title}",
            "description" => "body|text|max:12"
          }
        },
        dataset
      )

    {:ok, _} =
      Content.create_document(
        "guide",
        %{"doc_id" => "guide-1", "title" => "Planting"},
        dataset
      )

    {:ok, _} = Content.publish_document("guide-1", "guide", dataset)

    {:ok, _} =
      Content.create_document(
        "card",
        %{
          "doc_id" => "card-1",
          "title" => "Spring card",
          "content" => %{
            "target" => %{"_ref" => "guide-1"},
            "body" => [block("Seeds go in after the frost.")]
          }
        },
        dataset
      )

    {panes, _editor} = PaneBuilder.build(dataset, ["card"])
    [row] = for %{type: :doc} = item <- List.last(panes).items, do: item

    assert row.meta == "Guide: Planting"
    assert row.description == "Seeds go in ..."
  end
end
