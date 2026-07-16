defmodule Barkpark.Chat.ToolRowsTest do
  @moduledoc """
  Function-level lock on the pure chat toolrow derivations now that they live in
  core (`Barkpark.Chat.ToolRows`) rather than the web `ChatToolRenderer`. No
  fn-level test existed before the extraction — this proves shape dispatch,
  todo normalization, and the glyph map directly (distrust vacuous green: the
  golden fixture only covers the five canonical variants).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Chat.ToolRows

  describe "classify/1 — dispatch on SHAPE, never tool name" do
    test "an Edit-shaped input classifies :edit" do
      assert ToolRows.classify(%{
               "file_path" => "x.ex",
               "old_string" => "a",
               "new_string" => "b"
             }) == :edit
    end

    test "a Write-shaped input classifies :write" do
      assert ToolRows.classify(%{"file_path" => "x.ex", "content" => "hi"}) == :write
    end

    test "a MultiEdit-shaped input classifies :multi_edit (edits checked before scalar shapes)" do
      assert ToolRows.classify(%{
               "file_path" => "x.ex",
               "edits" => [%{"old_string" => "a", "new_string" => "b"}]
             }) == :multi_edit
    end

    test "an empty edits list falls through to the scalar shapes / :generic" do
      assert ToolRows.classify(%{"file_path" => "x.ex", "edits" => []}) == :generic
    end

    test "anything else is :generic, and a non-map is :generic (never raises)" do
      assert ToolRows.classify(%{"pattern" => "foo"}) == :generic
      assert ToolRows.classify(nil) == :generic
      assert ToolRows.classify("not a map") == :generic
    end
  end

  describe "diff?/1" do
    test "true for a diff shape, false for a generic shape" do
      assert ToolRows.diff?(%{"file_path" => "x.ex", "content" => "hi"})
      refute ToolRows.diff?(%{"pattern" => "foo"})
    end
  end

  describe "parse_todos/1" do
    test "normalizes statuses and carries the modern activeForm" do
      todos =
        ToolRows.parse_todos(%{
          "todos" => [
            %{"content" => "Ship it", "status" => "completed"},
            %{"content" => "Do it", "status" => "in_progress", "activeForm" => "Doing it"},
            %{"content" => "Plan it", "status" => "pending"}
          ]
        })

      assert todos == [
               %{content: "Ship it", status: :completed, active_form: nil},
               %{content: "Do it", status: :in_progress, active_form: "Doing it"},
               %{content: "Plan it", status: :pending, active_form: nil}
             ]
    end

    test "an unknown status normalizes to :pending; a blank activeForm is dropped" do
      assert [%{status: :pending, active_form: nil}] =
               ToolRows.parse_todos(%{
                 "todos" => [%{"content" => "x", "status" => "bogus", "activeForm" => ""}]
               })
    end

    test "a non-list / malformed frame degrades to []" do
      assert ToolRows.parse_todos(%{"todos" => "nope"}) == []
      assert ToolRows.parse_todos(nil) == []
    end
  end

  describe "todo_glyph/1" do
    test "maps each status to its checklist mark" do
      assert ToolRows.todo_glyph(:completed) == "☒"
      assert ToolRows.todo_glyph(:in_progress) == "◐"
      assert ToolRows.todo_glyph(:pending) == "☐"
      assert ToolRows.todo_glyph(:anything_else) == "☐"
    end
  end
end
