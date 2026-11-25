defmodule Barkpark.Content.Forms.ObjectRebaseTest do
  @moduledoc """
  task-04e50efa8405b956: an object field's edit is written subfield by
  subfield onto what the store holds now.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Forms.ObjectRebase

  @schema %{
    fields: [
      %{"name" => "notes", "type" => "string"},
      %{
        "name" => "meta",
        "type" => "composite",
        "fields" => [
          %{"name" => "code", "type" => "string"},
          %{"name" => "label", "type" => "string"},
          %{"name" => "rt", "type" => "richText"},
          %{
            "name" => "inner",
            "type" => "composite",
            "fields" => [
              %{"name" => "a", "type" => "string"},
              %{"name" => "b", "type" => "string"}
            ]
          }
        ]
      }
    ]
  }

  defp rebase(mine, base, theirs),
    do:
      ObjectRebase.onto(%{"meta" => mine}, %{"meta" => base}, %{"meta" => theirs}, @schema)[
        "meta"
      ]

  test "a changed subfield is written; an untouched one keeps theirs" do
    assert rebase(%{"code" => "cA", "label" => "l0"}, %{"code" => "c0", "label" => "l0"}, %{
             "code" => "c0",
             "label" => "lB"
           }) == %{"code" => "cA", "label" => "lB"}
  end

  test "a nested object is rebased subfield by subfield" do
    base = %{"inner" => %{"a" => "a0", "b" => "b0"}}
    mine = %{"inner" => %{"a" => "aA", "b" => "b0"}}
    theirs = %{"inner" => %{"a" => "a0", "b" => "bB"}}

    assert rebase(mine, base, theirs) == %{"inner" => %{"a" => "aA", "b" => "bB"}}
  end

  test "a subfield another editor added stays; one the post took off goes" do
    base = %{"code" => "c0", "label" => "l0"}
    mine = %{"label" => "l0"}
    theirs = %{"code" => "c0", "label" => "l0", "extra" => "x"}

    assert rebase(mine, base, theirs) == %{"label" => "l0", "extra" => "x"}
  end

  test "a subfield the post took off that another editor changed stays theirs" do
    assert rebase(%{"label" => "l0"}, %{"code" => "c0", "label" => "l0"}, %{
             "code" => "cB",
             "label" => "l0"
           }) == %{"code" => "cB", "label" => "l0"}
  end

  test "an untouched subfield another editor removed stays removed" do
    assert rebase(%{"code" => "cA", "label" => "l0"}, %{"code" => "c0", "label" => "l0"}, %{
             "code" => "c0"
           }) == %{"code" => "cA"}
  end

  test "not an object in all three, or not a composite field: written as posted" do
    assert ObjectRebase.onto(
             %{"meta" => %{"code" => "cA"}},
             %{},
             %{"meta" => %{"x" => 1}},
             @schema
           ) ==
             %{"meta" => %{"code" => "cA"}}

    assert ObjectRebase.onto(%{"notes" => "nA"}, %{"notes" => "n0"}, %{"notes" => "nB"}, @schema) ==
             %{"notes" => "nA"}
  end

  # #28349 r4, SV1: B's post of meta.rt reached the server before B's tab
  # was told of A's save of it, so the tab could not hold it, and B's whole
  # value was written over A's words. The save reads the store under its
  # lock: blocks only one of them changed are both kept.
  describe "a rich text subfield both changed since the form's base" do
    defp blk(key, text),
      do: %{
        "_type" => "block",
        "_key" => key,
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
      }

    defp words(blocks), do: Enum.map(blocks, fn b -> hd(b["children"])["text"] end)

    test "different blocks: merged block by block" do
      base = [blk("k1", "one two")]
      mine = [blk("k1", "one two"), blk("n1", "B para")]
      theirs = [blk("k1", "one two A")]

      assert words(rebase(%{"rt" => mine}, %{"rt" => base}, %{"rt" => theirs})["rt"]) ==
               ["one two A", "B para"]
    end

    # Both edit the word "two": an overlap, a clash before and after the
    # merge inside one block (task-266ffbe9cd115f3c).
    test "the same block: the post is written, as before" do
      base = [blk("k1", "one two")]
      mine = [blk("k1", "one TWO")]
      theirs = [blk("k1", "one twoA")]

      assert rebase(%{"rt" => mine}, %{"rt" => base}, %{"rt" => theirs})["rt"] == mine
    end

    # #28349 r4 review, OR-a: a base older than what the post already holds
    # read B's X as added by both, and wrote it twice.
    test "both added the same block at one place: the post is written, never X twice" do
      base = [blk("p", "P"), blk("q", "Q"), blk("r", "R")]
      mine = [blk("p", "P"), blk("q", "Q A"), blk("x", "X"), blk("r", "R")]
      theirs = [blk("p", "P"), blk("q", "Q"), blk("x2", "X"), blk("r", "R")]

      assert rebase(%{"rt" => mine}, %{"rt" => base}, %{"rt" => theirs})["rt"] == mine
    end

    test "theirs unchanged from the base: the post is written as it is" do
      base = [blk("k1", "one two")]
      mine = [blk("k1", "one two X")]

      assert rebase(%{"rt" => mine}, %{"rt" => base}, %{"rt" => base})["rt"] == mine
    end
  end
end
