defmodule Barkpark.PortableDoc.Validate.NewErrorsTest do
  @moduledoc """
  The PortableDoc ratchet's arithmetic (R4.5): which errors a write ADDS, keyed
  by code and a place named from the nearest block id, counted; and what
  `check/2` does with them, report-only or refusing. Synthetic blocks only.
  """

  use ExUnit.Case, async: false

  alias Barkpark.Content.Warnings
  alias Barkpark.PortableDoc.Validate.NewErrors

  defp para(id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => id}]}

  defp bad_heading(id), do: %{"id" => id, "type" => "heading", "level" => 9, "text" => id}

  setup do
    previous = Application.get_env(:barkpark, :portable_doc_refuse_new_errors)
    on_exit(fn -> Application.put_env(:barkpark, :portable_doc_refuse_new_errors, previous) end)
    Application.delete_env(:barkpark, :portable_doc_refuse_new_errors)
    :ok
  end

  describe "split/2" do
    test "an error the write adds is added, with its /blocks path" do
      assert {[%{code: :value_not_allowed, path: "/blocks/1/level"}], []} =
               NewErrors.split([para("a")], [para("a"), bad_heading("h")])
    end

    test "an error the stored blocks already had is existing, not added" do
      assert {[], [%{code: :value_not_allowed, path: "/blocks/1/level"}]} =
               NewErrors.split([para("a"), bad_heading("h")], [
                 para("a"),
                 bad_heading("h"),
                 para("b")
               ])
    end

    test "a block inserted above a broken one moves its index, not its error" do
      assert {[], [%{path: "/blocks/2/level"}]} =
               NewErrors.split([para("a"), bad_heading("h")], [
                 para("z"),
                 para("a"),
                 bad_heading("h")
               ])
    end

    test "the same error on another block id is added" do
      assert {[%{path: "/blocks/1/level"}], [%{path: "/blocks/0/level"}]} =
               NewErrors.split([bad_heading("h")], [bad_heading("h"), bad_heading("k")])
    end

    test "errors under the block id key by the rest of the path" do
      section = fn level ->
        %{
          "id" => "s",
          "type" => "section",
          "blocks" => [%{"type" => "heading", "level" => level, "text" => "x"}]
        }
      end

      assert {[], [_]} = NewErrors.split([section.(9)], [para("a"), section.(9)])

      assert {[%{path: "/blocks/0/blocks/0/level"}], []} =
               NewErrors.split([section.(2)], [section.(9)])
    end

    test "an item added above a broken list item leaves its error old; a second broken item adds one" do
      item = fn text -> %{"content" => [%{"type" => "text", "value" => text}]} end
      broken = Map.put(item.("b"), "checked", "yes")

      list = fn items ->
        %{"id" => "l", "type" => "list", "ordered" => false, "items" => items}
      end

      assert {[], [%{path: "/blocks/0/items/2/checked"}]} =
               NewErrors.split([list.([item.("a"), broken])], [
                 list.([item.("new"), item.("a"), broken])
               ])

      assert {[_], [_]} =
               NewErrors.split([list.([item.("a"), broken])], [
                 list.([broken, item.("a"), broken])
               ])
    end

    test "text typed before a broken inline node leaves its error old" do
      para = fn content -> %{"id" => "p", "type" => "paragraph", "content" => content} end
      untyped = %{"value" => "x"}

      assert {[], [%{code: :missing_required_field, path: "/blocks/0/content/2/type"}]} =
               NewErrors.split([para.([%{"type" => "text", "value" => "a"}, untyped])], [
                 para.([
                   %{"type" => "text", "value" => "new"},
                   %{"type" => "text", "value" => "a"},
                   untyped
                 ])
               ])
    end

    test "the same code on another field of the same block is added" do
      stored = [%{bad_heading("h") | "level" => true}]
      written = [%{bad_heading("h") | "level" => 2, "text" => 5}]

      assert {[%{code: :wrong_field_type, path: "/blocks/0/text"}], []} =
               NewErrors.split(stored, written)

      assert NewErrors.split_touched(stored, written) == NewErrors.split(stored, written)
    end

    test "another code at the same place is added" do
      assert {[%{code: :wrong_field_type, path: "/blocks/0/level"}], []} =
               NewErrors.split([bad_heading("h")], [%{bad_heading("h") | "level" => true}])
    end

    test "a nested block with an id is followed when it moves to another section" do
      section = fn id, blocks -> %{"id" => id, "type" => "section", "blocks" => blocks} end

      assert {[], [%{path: "/blocks/1/blocks/0/level"}]} =
               NewErrors.split([section.("s1", [bad_heading("k")]), section.("s2", [])], [
                 section.("s1", []),
                 section.("s2", [bad_heading("k")])
               ])
    end

    test "an id-less broken block keys by its whole path, so moving it adds it" do
      idless = %{"type" => "heading", "level" => 9, "text" => "x"}
      assert {[], [_]} = NewErrors.split([idless], [idless])
      assert {[%{path: "/blocks/1/level"}], []} = NewErrors.split([idless], [para("a"), idless])
    end

    test "the broken block itself is the place when it has an id" do
      pt = %{"id" => "pt", "_type" => "block", "children" => []}

      assert {[], [%{code: :portable_text_block, path: "/blocks/1"}]} =
               NewErrors.split([pt], [para("z"), pt])
    end

    test "a blank id is no place" do
      blank = %{"id" => "", "type" => "heading", "level" => 9, "text" => "x"}
      assert {[%{path: "/blocks/1/level"}], []} = NewErrors.split([blank], [para("z"), blank])
    end

    test "errors are counted: a third block on a duplicated id is one more" do
      assert {[%{code: :duplicate_block_id}], [%{code: :duplicate_block_id}]} =
               NewErrors.split([para("d"), para("d")], [para("d"), para("d"), para("d")])
    end

    test "a fixed error is neither added nor existing" do
      assert {[], []} = NewErrors.split([bad_heading("h")], [para("h")])
    end

    test "a block list that is not a list is never checked" do
      assert {[], []} = NewErrors.split(nil, nil)
      assert {[], []} = NewErrors.split([bad_heading("h")], nil)
    end

    test "nothing stored: every error is added" do
      assert {[_], []} = NewErrors.split([], [bad_heading("h")])
    end

    test "a stored block list that is not a list counts as nothing stored" do
      assert {[_], []} = NewErrors.split(%{"html" => "<p>x</p>"}, [bad_heading("h")])
    end
  end

  describe "check/2" do
    test "report-only by default: :ok, and a portable_doc_invalid warning with both lists" do
      Warnings.reset()

      assert :ok = NewErrors.check([bad_heading("old")], [bad_heading("old"), bad_heading("new")])

      assert [
               %{
                 code: "portable_doc_invalid",
                 severity: "warning",
                 message: message,
                 violations: [%{code: :value_not_allowed, path: "/blocks/1/level"}],
                 existing: [%{path: "/blocks/0/level"}]
               }
             ] = Warnings.drain()

      assert message ==
               "this write adds 1 PortableDoc error(s): value_not_allowed at /blocks/1/level" <>
                 " (it keeps 1 old error(s) where it wrote)"
    end

    test "refusing: the halt names the added errors and counts the existing ones" do
      Application.put_env(:barkpark, :portable_doc_refuse_new_errors, true)
      Warnings.reset()

      assert {:error, {:halted, message}} = NewErrors.check([], [bad_heading("h")])
      assert message =~ "adds 1 PortableDoc error(s): value_not_allowed at /blocks/0/level"
      assert message =~ "(it keeps 0 old error(s)"
      assert Warnings.drain() == []
    end

    test "refusing still lets a write through that adds nothing, however broken the paper" do
      Application.put_env(:barkpark, :portable_doc_refuse_new_errors, true)
      assert :ok = NewErrors.check([bad_heading("h")], [para("a"), bad_heading("h")])
    end

    test "only `true` turns refusing on" do
      for value <- ["true", 1, :yes] do
        Application.put_env(:barkpark, :portable_doc_refuse_new_errors, value)
        refute NewErrors.refuse?()
      end
    end

    test "the message names five errors and counts the rest" do
      message = NewErrors.message(Enum.map(1..7, &%{code: :too_deep, path: "/blocks/#{&1}"}), [])
      assert message =~ "adds 7 PortableDoc error(s): too_deep at /blocks/1;"
      assert message =~ "too_deep at /blocks/5 and 2 more"
      refute message =~ "/blocks/6"
    end
  end
end
