defmodule BarkparkWeb.Studio.PaperEditor.TechnicalBlockEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor

  describe "scalar technical blocks" do
    test "diff and filetree preserve omitted metadata while accepting explicit clears" do
      diff = %{"type" => "diff", "diff" => "+old", "file" => "lib/a.ex", "lang" => "elixir"}
      assert TechnicalBlockEditor.build_patch(diff, %{"diff" => "+new"}) == %{"diff" => "+new"}

      assert TechnicalBlockEditor.build_patch(diff, %{"file" => "", "lang" => ""}) == %{
               "file" => "",
               "lang" => ""
             }

      tree = %{"type" => "filetree", "text" => "lib/", "legend" => "● added"}
      assert TechnicalBlockEditor.build_patch(tree, %{"text" => "src/"}) == %{"text" => "src/"}
      assert TechnicalBlockEditor.build_patch(tree, %{"legend" => ""}) == %{"legend" => ""}
    end

    test "renders the complete authored scalar fields" do
      diff_html =
        render_editor(%{
          "id" => "d",
          "type" => "diff",
          "diff" => "+x",
          "file" => "a",
          "lang" => "go"
        })

      assert inputs(diff_html) == ["block_id", "file", "lang", "diff"]

      tree_html =
        render_editor(%{"id" => "t", "type" => "filetree", "text" => "lib/", "legend" => "● new"})

      assert inputs(tree_html) == ["block_id", "text", "legend"]
    end
  end

  describe "footnote collection" do
    test "edits and clears fields without dropping row metadata or ignored legacy rows" do
      legacy = "legacy note"

      block = %{
        "type" => "footnote",
        "notes" => [%{"id" => "a", "text" => "Old", "href" => "kept"}, legacy]
      }

      patch =
        TechnicalBlockEditor.build_patch(block, %{
          "note-count" => "2",
          "note-0-id" => "",
          "note-0-text" => "New"
        })

      assert patch["notes"] == [%{"id" => "", "text" => "New", "href" => "kept"}, legacy]
      assert TechnicalBlockEditor.build_patch(block, %{"note-count" => "1"}) == %{}

      assert TechnicalBlockEditor.validate_patch(block, %{"note-count" => "1"}) ==
               {:error, {:malformed_collection, "notes"}}

      assert TechnicalBlockEditor.validate_patch(block, %{"note-action" => "remove:0"}) ==
               {:error, {:malformed_collection, "notes"}}

      assert TechnicalBlockEditor.validate_patch(block, %{"note-0-text" => "Lost"}) ==
               {:error, {:malformed_collection, "notes"}}
    end

    test "adds, removes, and reorders whole rows" do
      block = %{"type" => "footnote", "notes" => [%{"id" => "a"}, %{"id" => "b"}]}

      assert %{"notes" => [%{"id" => "a"}, %{"id" => "b"}, %{"id" => "", "text" => ""}]} =
               TechnicalBlockEditor.build_patch(block, %{
                 "note-count" => "2",
                 "note-action" => "add"
               })

      assert %{"notes" => [%{"id" => "b"}]} =
               TechnicalBlockEditor.build_patch(block, %{
                 "note-count" => "2",
                 "note-action" => "remove:0"
               })

      assert %{"notes" => [%{"id" => "b"}, %{"id" => "a"}]} =
               TechnicalBlockEditor.build_patch(block, %{
                 "note-count" => "2",
                 "note-action" => "down:0"
               })

      assert TechnicalBlockEditor.validate_patch(
               %{"type" => "footnote"},
               %{"note-count" => "0", "note-action" => "add"}
             ) == {:ok, %{"notes" => [%{"id" => "", "text" => ""}]}}
    end
  end

  describe "code-tabs collection" do
    test "preserves unknown metadata and the legacy code spelling while editing" do
      block = %{
        "type" => "code-tabs",
        "syncKey" => "install",
        "tabs" => [%{"label" => "JS", "language" => "js", "code" => "old", "theme" => "dark"}]
      }

      patch =
        TechnicalBlockEditor.build_patch(block, %{
          "syncKey" => "",
          "tab-count" => "1",
          "tab-0-label" => "Node",
          "tab-0-language" => "javascript",
          "tab-0-value" => "new"
        })

      assert patch["syncKey"] == ""

      assert patch["tabs"] == [
               %{
                 "label" => "Node",
                 "language" => "javascript",
                 "code" => "new",
                 "theme" => "dark"
               }
             ]
    end

    test "an unchanged effective legacy code value preserves a null value alias" do
      block = %{
        "type" => "code-tabs",
        "syncKey" => "install",
        "tabs" => [
          %{
            "label" => "JS",
            "language" => "js",
            "value" => nil,
            "code" => "npm i",
            "theme" => "dark"
          }
        ]
      }

      params = %{
        "tab-count" => "1",
        "tab-0-label" => "JS",
        "tab-0-language" => "js",
        "tab-0-value" => "npm i"
      }

      assert TechnicalBlockEditor.validate_patch(block, params) ==
               {:ok, %{"tabs" => block["tabs"]}}

      assert TechnicalBlockEditor.validate_patch(block, %{"syncKey" => "shared"}) ==
               {:ok, %{"syncKey" => "shared"}}
    end

    test "explicit edits synchronize dual code aliases across readers" do
      row = %{"value" => "current", "code" => "legacy", "metadata" => "retained"}
      block = %{"type" => "code-tabs", "tabs" => [row]}

      assert {:ok, %{"tabs" => [^row]}} =
               TechnicalBlockEditor.validate_patch(block, %{
                 "tab-count" => "1",
                 "tab-0-value" => "current"
               })

      for value <- ["replacement", ""] do
        assert {:ok, %{"tabs" => [changed]}} =
                 TechnicalBlockEditor.validate_patch(block, %{
                   "tab-count" => "1",
                   "tab-0-value" => value
                 })

        assert changed == %{"value" => value, "code" => value, "metadata" => "retained"}
      end
    end

    test "adds canonical rows and supports removal and both reorder directions" do
      tabs = [%{"label" => "A", "value" => "a"}, %{"label" => "B", "value" => "b"}]
      block = %{"type" => "code-tabs", "tabs" => tabs}
      [first, second] = tabs

      assert %{"tabs" => [_, _, %{"label" => "", "language" => "", "value" => ""}]} =
               TechnicalBlockEditor.build_patch(block, %{
                 "tab-count" => "2",
                 "tab-action" => "add"
               })

      assert %{"tabs" => [^second]} =
               TechnicalBlockEditor.build_patch(block, %{
                 "tab-count" => "2",
                 "tab-action" => "remove:0"
               })

      assert %{"tabs" => [^second, ^first]} =
               TechnicalBlockEditor.build_patch(block, %{
                 "tab-count" => "2",
                 "tab-action" => "up:1"
               })
    end

    test "renders every row including an explicit retained legacy row" do
      html =
        render_editor(%{
          "id" => "ct",
          "type" => "code-tabs",
          "syncKey" => "install",
          "tabs" => [%{"label" => "JS", "language" => "js", "code" => "npm i"}, "legacy"]
        })

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, ~s(input[name="tab-count"])), "value") == [
               "2"
             ]

      assert doc |> LazyHTML.query(~s([data-test-id="tab-row"])) |> Enum.count() == 2
      assert LazyHTML.text(LazyHTML.query(doc, ~s([data-test-id="tab-legacy-row"]))) =~ "retained"

      assert inputs(html) == [
               "block_id",
               "syncKey",
               "tab-count",
               "tab-0-label",
               "tab-0-language",
               "tab-0-value"
             ]
    end
  end

  defp render_editor(block) do
    render_component(&TechnicalBlockEditor.technical_block_editor/1,
      block: block,
      id: block["id"]
    )
  end

  defp inputs(html) do
    doc = LazyHTML.from_fragment(html)

    LazyHTML.attribute(LazyHTML.query(doc, "input[name], textarea[name]"), "name")
  end
end
