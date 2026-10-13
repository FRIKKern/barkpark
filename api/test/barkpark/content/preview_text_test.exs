defmodule Barkpark.Content.PreviewTextTest do
  @moduledoc """
  `list_preview.subtitle` (task-f3203617ae4cf03e): a referenced title in the
  subtitle, a formatted date, a fallback when empty — the Agency previews — and
  the desk row that shows them.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.PreviewText
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "preview-text-#{System.unique_integer([:positive])}"

  defp read(map), do: fn path -> Map.get(map, path) end

  describe "format/2" do
    test "a path, a date and a fallback" do
      assert PreviewText.format("author.name", read(%{"author.name" => "Kari"})) == "Kari"

      date = %{"parts" => ["publishedAt|date"], "empty" => "Ingen dato"}
      assert PreviewText.format(date, read(%{"publishedAt" => "2026-10-08"})) == "08.10.2026"

      assert PreviewText.format(date, read(%{"publishedAt" => "2026-10-08T23:30:00Z"})) ==
               "08.10.2026"

      assert PreviewText.format(date, read(%{})) == "Ingen dato"
      assert PreviewText.format(date, read(%{"publishedAt" => "not a date"})) == "Ingen dato"
    end

    test "parts join, empty parts drop out" do
      spec = %{"parts" => ["kicker", "author.name"], "join" => " — "}
      assert PreviewText.format(spec, read(%{"kicker" => "K", "author.name" => "A"})) == "K — A"
      assert PreviewText.format(spec, read(%{"kicker" => " ", "author.name" => "A"})) == "A"
      assert PreviewText.format(spec, read(%{})) == nil
    end

    test "refs names the reference fields a spec reads through" do
      assert PreviewText.refs(%{"parts" => ["parent.title", "date|date", "parent.slug"]}) == [
               "parent"
             ]

      assert PreviewText.refs("title") == []
      assert PreviewText.refs(nil) == []
    end
  end

  test "a desk row's subtitle follows the declaration, through one reference" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "category",
          "title" => "Category",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "parent",
              "title" => "Parent",
              "type" => "reference",
              "to" => ["category"]
            }
          ],
          "list_preview" => %{"subtitle" => %{"parts" => ["parent.title"], "empty" => "Toppnivå"}}
        },
        @dataset
      )

    {:ok, schema} = Content.get_schema("category", @dataset)
    assert Content.serialize_schema_for_sdk(schema).listPreview["subtitle"]["empty"] == "Toppnivå"

    for {id, title, content} <- [
          {"top", "Fiction", %{}},
          {"child", "Crime", %{"parent" => %{"_ref" => "top", "_type" => "reference"}}}
        ] do
      {:ok, _} =
        Content.create_document(
          "category",
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "category", @dataset)
    end

    {panes, _editor} = PaneBuilder.build(@dataset, ["category"])

    rows =
      for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.title, item.meta}

    assert rows["Crime"] == "Fiction"
    assert rows["Fiction"] == "Toppnivå"
  end
end
