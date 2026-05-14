defmodule BarkparkWeb.Components.DraftDiffTest do
  @moduledoc """
  Coverage for `BarkparkWeb.Components.DraftDiff` (Task `barkpark-uix`).

  Pins the four field-level statuses (`:unchanged`, `:added`, `:removed`,
  `:changed`) and the no-published fallback. The component is read-only
  output (no events, no streams) so we render once and assert against
  the resulting HTML — the data-test-id hooks on each row + status cell
  make assertions stable against CSS / markup churn.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.DraftDiff

  defp schema(field_names) do
    %{
      "name" => "test",
      "fields" => Enum.map(field_names, fn n -> %{"name" => n, "type" => "string"} end)
    }
  end

  defp doc(content), do: %{content: content}

  describe "draft_diff/1 — status computation" do
    test "all fields equal → 0 changes, every row :unchanged" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Hello", "body" => "x"}),
          published: doc(%{"title" => "Hello", "body" => "x"}),
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(data-test-id="draft-diff")
      assert html =~ ~s(0 changes)
      assert html =~ ~s(bp-diff-unchanged)
      refute html =~ ~s(bp-diff-changed)
      refute html =~ ~s(bp-diff-added)
      refute html =~ ~s(bp-diff-removed)
    end

    test "field present in draft, absent in published → :added" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Hello", "body" => "new para"}),
          published: doc(%{"title" => "Hello"}),
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(1 change)
      assert html =~ ~s(bp-diff-added)

      assert html =~
               ~s(data-test-id="draft-diff-status-body")
    end

    test "field present in published, absent in draft → :removed" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Hello"}),
          published: doc(%{"title" => "Hello", "body" => "old para"}),
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(1 change)
      assert html =~ ~s(bp-diff-removed)
    end

    test "field present on both sides with different values → :changed" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Updated"}),
          published: doc(%{"title" => "Original"}),
          schema: schema(["title"])
        })

      assert html =~ ~s(1 change)
      assert html =~ ~s(bp-diff-changed)
      assert html =~ "Updated"
      assert html =~ "Original"
    end

    test "no published doc → every row collapses to :added, table still renders" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "Brand new", "body" => "first draft"}),
          published: nil,
          schema: schema(["title", "body"])
        })

      assert html =~ ~s(data-test-id="draft-diff")
      assert html =~ ~s(2 changes)
      assert html =~ ~s(bp-diff-added)
    end

    test "composite (map) values render as JSON in the column" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"meta" => %{"author" => "Alice", "tags" => ["a", "b"]}}),
          published: doc(%{"meta" => %{"author" => "Bob"}}),
          schema: schema(["meta"])
        })

      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ ~s(bp-diff-changed)
    end

    test "atom-keyed schema + struct-style doc (content map) work" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: %{content: %{"title" => "A"}},
          published: %{content: %{"title" => "B"}},
          schema: %{fields: [%{name: "title", type: "string"}]}
        })

      assert html =~ ~s(bp-diff-changed)
      assert html =~ "A"
      assert html =~ "B"
    end
  end

  describe "draft_diff/1 — pluralisation" do
    test "uses 'change' (singular) for exactly one diff" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"title" => "x"}),
          published: doc(%{"title" => "y"}),
          schema: schema(["title"])
        })

      assert html =~ "1 change"
      refute html =~ "1 changes"
    end

    test "uses 'changes' (plural) for zero or many diffs" do
      html =
        render_component(&DraftDiff.draft_diff/1, %{
          draft: doc(%{"a" => "1", "b" => "1"}),
          published: doc(%{"a" => "2", "b" => "2"}),
          schema: schema(["a", "b"])
        })

      assert html =~ "2 changes"
    end
  end
end
