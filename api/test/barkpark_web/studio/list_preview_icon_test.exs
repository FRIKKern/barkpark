defmodule BarkparkWeb.Studio.ListPreviewIconTest do
  @moduledoc """
  A desk row draws the icon its `list_preview.media` picks by a stored value
  in place of the type's icon, and keeps the type's icon when the pick names
  nothing this Studio draws. A date-time `|date` subtitle renders as a
  `<time>` for the browser to show in the workspace time zone.
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "list-preview-icon-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "icon" => "tag",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "kind", "title" => "Kind", "type" => "string"},
            %{"name" => "at", "title" => "At", "type" => "datetime"}
          ],
          "list_preview" => %{
            "subtitle" => "at|date",
            "media" => %{
              "icon" => %{
                "path" => "kind",
                "map" => %{"guide" => "compass", "odd" => "no-such-glyph"},
                "else" => "home"
              }
            }
          }
        },
        @dataset
      )

    for {id, content} <- [
          {"n-guide", %{"kind" => "guide", "at" => "2026-10-08T23:30:00Z"}},
          {"n-other", %{"kind" => "recipe"}},
          {"n-odd", %{"kind" => "odd"}},
          {"n-none", %{}}
        ] do
      {:ok, _} =
        Content.create_document(
          "note",
          %{"doc_id" => id, "title" => id, "content" => content},
          @dataset
        )
    end

    :ok
  end

  defp rows do
    {panes, _editor} = PaneBuilder.build(@dataset, ["note"])
    for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.id, item}
  end

  test "each row's icon follows the pick, and an undrawable pick keeps the type icon" do
    icons = Map.new(rows(), fn {id, row} -> {id, row.type_icon} end)

    assert icons == %{
             "n-guide" => "compass",
             "n-other" => "home",
             "n-odd" => "tag",
             "n-none" => "tag"
           }

    assert Enum.all?(rows(), fn {_, row} -> is_nil(row.media) end)
  end

  test "a date-time subtitle renders as a time element holding the UTC day" do
    row = rows()["n-guide"]
    assigns = %{text: row.meta}

    html = rendered_to_string(~H|<BarkparkWeb.PreviewDay.text text={@text} />|)

    assert html =~ ~s(<time datetime="2026-10-08T23:30:00Z" data-preview-day>08.10.2026</time>)
  end
end
