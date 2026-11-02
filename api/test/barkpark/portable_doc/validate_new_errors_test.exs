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

    test "an id-less broken block keys by its whole path, so moving it adds it" do
      idless = %{"type" => "heading", "level" => 9, "text" => "x"}
      assert {[], [_]} = NewErrors.split([idless], [idless])
      assert {[%{path: "/blocks/1/level"}], []} = NewErrors.split([idless], [para("a"), idless])
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
                 " (1 already in the paper stay as they are)"
    end

    test "refusing: the halt names the added errors and counts the existing ones" do
      Application.put_env(:barkpark, :portable_doc_refuse_new_errors, true)
      Warnings.reset()

      assert {:error, {:halted, message}} = NewErrors.check([], [bad_heading("h")])
      assert message =~ "adds 1 PortableDoc error(s): value_not_allowed at /blocks/0/level"
      assert message =~ "(0 already in the paper"
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
