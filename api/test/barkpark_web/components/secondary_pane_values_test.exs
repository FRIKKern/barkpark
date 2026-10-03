defmodule BarkparkWeb.Components.SecondaryPaneValuesTest do
  @moduledoc """
  The read-only secondary pane ("Open another") must show a structured field
  value as something a person can read. Found dogfooding: a post's Featured
  Image rendered as Elixir source — `%{"assetId" => "a97b…", "height" => 630,
  "lqip" => "data:image/jpeg;base64,/9j/4QC8…"` — a screenful of base64 in a
  360px pane, because the formatter fell back to `inspect/2`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.EditorFields

  defp render_pane(content, fields) do
    render_component(&EditorFields.secondary_editor_card/1,
      secondary_doc: %{doc_id: "drafts.p2", status: "draft", title: "P2", content: content},
      secondary_schema: %{fields: fields},
      secondary_type: "post",
      width_bucket: "wide"
    )
  end

  test "an image value shows its URL, not an Elixir map with the base64 placeholder" do
    html =
      render_pane(
        %{
          "cover" => %{
            "url" => "/media/files/og.jpg",
            "assetId" => "a97b",
            "width" => 1200,
            "lqip" => "data:image/jpeg;base64,/9j/4QC8RXhpZgAASUkqAAgAAAAGABIBAwABAAAAAQAAAB"
          }
        },
        [%{"name" => "cover", "title" => "Cover", "type" => "image"}]
      )

    assert html =~ "/media/files/og.jpg"
    refute html =~ "%{"
    refute html =~ "base64"
  end

  test "other structured values read as JSON, not Elixir syntax" do
    html =
      render_pane(
        %{"keywords" => ["k1", "k2"], "author" => %{"_ref" => "a1", "_type" => "reference"}},
        [
          %{"name" => "keywords", "title" => "Keywords", "type" => "arrayOf"},
          %{"name" => "author", "title" => "Author", "type" => "reference"}
        ]
      )

    assert html =~ "a1"
    refute html =~ "%{"
    refute html =~ "=&gt;"
    assert html =~ "k1"
  end
end
