defmodule Barkpark.Plugins.OnixEdit.ResolveDocActionsTest do
  @moduledoc """
  Pins the proof of Goal `barkpark-cjs`: `OnixEdit.resolve_doc_actions/2`
  hides the `publish_to_bokbasen` editor-header action while the book's
  Bokbasen submission is in-flight (`queued | staging | staged | polling`)
  and leaves it visible otherwise.

  See `~/docs/paperflow/plans/2026-05-17-plugin-resolvers.html` §3.

  The resolver in `lib/barkpark/plugins/onixedit.ex` reads
  `bp_export_status.state` via THREE fall-through paths (in order):

    1. `get_in(doc, [Access.key(:content, %{}), "bp_export_status", "state"])`
       — atom-key `:content`, string-key inner (struct + string content)
    2. `get_in(doc, ["content", "bp_export_status", "state"])`
       — all string keys (plain map from JSON decode)
    3. `get_in(doc, [Access.key(:content, %{}), :bp_export_status, :state])`
       — all atom keys (struct with atom-key content map)

  These tests exercise both the string-key path (most common — that's how
  documents arrive from `Content.get_document/3` after JSON decode) and the
  all-atom-key path (used by callers that construct docs in-process).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit

  @publish_action %{
    "name" => "publish_to_bokbasen",
    "label" => "Publish to Bokbasen",
    "kind" => "modal",
    "scope" => "editor_header",
    "opts" => []
  }
  @other_action %{
    "name" => "publish",
    "label" => "Publish",
    "kind" => "event",
    "scope" => "editor_header",
    "opts" => []
  }
  @prev [@publish_action, @other_action]

  # String-key doc — matches the resolver's path #2
  # (`get_in(doc, ["content", "bp_export_status", "state"])`).
  defp book_ctx(state) do
    %{
      dataset: "production",
      doc_id: "book-test",
      doc_type: "book",
      doc: %{"content" => %{"bp_export_status" => %{"state" => state}}}
    }
  end

  defp non_book_ctx(state) do
    %{book_ctx(state) | doc_type: "post"}
  end

  describe "resolve_doc_actions/2 — book mid-Bokbasen-submission" do
    for state <- ~w(queued staging staged polling) do
      @tag state: state
      test "hides publish_to_bokbasen when state == #{state}", %{state: state} do
        result = OnixEdit.resolve_doc_actions(@prev, book_ctx(state))
        names = Enum.map(result, & &1["name"])
        refute "publish_to_bokbasen" in names
        # The unrelated action stays — we filter one entry, not the whole list.
        assert "publish" in names
      end
    end
  end

  describe "resolve_doc_actions/2 — book NOT mid-submission" do
    for state <- ["accepted", "rejected", "draft", nil] do
      @tag state: state
      test "keeps publish_to_bokbasen when state == #{inspect(state)}", %{state: state} do
        result = OnixEdit.resolve_doc_actions(@prev, book_ctx(state))
        names = Enum.map(result, & &1["name"])
        assert "publish_to_bokbasen" in names
        assert result == @prev
      end
    end
  end

  describe "resolve_doc_actions/2 — non-book docs" do
    test "never filters publish_to_bokbasen for post documents (even with in-flight state)" do
      result = OnixEdit.resolve_doc_actions(@prev, non_book_ctx("polling"))
      assert result == @prev
    end
  end

  describe "resolve_doc_actions/2 — defensive cases" do
    test "missing bp_export_status entirely → keeps publish_to_bokbasen" do
      ctx = %{
        dataset: "production",
        doc_id: "x",
        doc_type: "book",
        doc: %{"content" => %{}}
      }

      result = OnixEdit.resolve_doc_actions(@prev, ctx)
      assert "publish_to_bokbasen" in Enum.map(result, & &1["name"])
      assert result == @prev
    end

    test "completely empty doc → keeps publish_to_bokbasen" do
      ctx = %{dataset: "production", doc_id: "x", doc_type: "book", doc: %{}}
      result = OnixEdit.resolve_doc_actions(@prev, ctx)
      assert result == @prev
    end

    test "ctx without a :doc key → keeps publish_to_bokbasen (defensive head fails)" do
      ctx = %{dataset: "production", doc_id: "x", doc_type: "book"}
      result = OnixEdit.resolve_doc_actions(@prev, ctx)
      assert result == @prev
    end
  end

  describe "resolve_doc_actions/2 — all-atom-key path" do
    # Exercises the third fall-through:
    # `get_in(doc, [Access.key(:content, %{}), :bp_export_status, :state])`.
    test "hides publish_to_bokbasen when atom-keyed content holds polling" do
      ctx = %{
        dataset: "production",
        doc_id: "book-atom",
        doc_type: "book",
        doc: %{content: %{bp_export_status: %{state: "polling"}}}
      }

      result = OnixEdit.resolve_doc_actions(@prev, ctx)
      refute "publish_to_bokbasen" in Enum.map(result, & &1["name"])
    end

    test "keeps publish_to_bokbasen when atom-keyed content holds accepted" do
      ctx = %{
        dataset: "production",
        doc_id: "book-atom",
        doc_type: "book",
        doc: %{content: %{bp_export_status: %{state: "accepted"}}}
      }

      result = OnixEdit.resolve_doc_actions(@prev, ctx)
      assert "publish_to_bokbasen" in Enum.map(result, & &1["name"])
    end
  end
end
