defmodule Barkpark.PortableDoc.BpmlPushGuardTest do
  @moduledoc """
  `Bpml.PushGuard`: a push from a copy without the print mark may not remove a
  block, a list item's children or a callout's body; a marked copy may.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml.PushGuard

  defp t(v), do: %{"type" => "text", "value" => v}
  defp para(id, v), do: %{"id" => id, "type" => "paragraph", "content" => [t(v)]}

  defp nested_list(children) do
    %{
      "id" => "l1",
      "type" => "list",
      "items" => [%{"content" => [t("parent")], "children" => children}]
    }
  end

  defp callout(body) do
    %{"id" => "c1", "type" => "callout", "content" => [t("Lead.")], "slots" => %{"body" => body}}
  end

  @child [%{"type" => "list", "items" => [[%{"type" => "text", "value" => "child"}]]}]
  @body [
    %{"id" => "cb", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "Body."}]}
  ]

  test "an unmarked copy that drops a block is refused, naming it, with the way out" do
    stored = [para("p1", "One"), para("p2", "Two")]

    assert {:error, %{code: "bpml_unshown_removal", message: msg, paths: ["blocks[1]"]}} =
             PushGuard.check(stored, [para("p1", "One")], nil)

    assert msg =~ "blocks[1]"

    assert msg =~
             "Pull again with a current bp (bp paper pull) and make your change in the fresh copy."

    assert msg =~ "written from scratch"
  end

  test "an unmarked old-printer copy of a list whose item children print is refused at the item" do
    stored = [nested_list(@child)]
    old_copy = [put_in(nested_list(@child), ["items"], [[t("parent")]])]

    assert {:error, %{paths: paths}} = PushGuard.check(stored, old_copy, nil)
    assert "blocks[0].items[0].children" in paths
  end

  test "an unmarked copy without a callout's body is refused at the body" do
    stored = [callout(@body)]
    copy = [Map.delete(callout(@body), "slots")]

    assert {:error, %{paths: paths}} = PushGuard.check(stored, copy, nil)
    assert "blocks[0].slots.body" in paths
  end

  defp item(text, children) do
    base = %{"content" => [t(text)]}
    if children, do: Map.put(base, "children", children), else: base
  end

  defp list_of(items), do: %{"id" => "l1", "type" => "list", "items" => items}

  @other_child [%{"type" => "list", "items" => [[%{"type" => "text", "value" => "new child"}]]}]

  test "item children are compared by content: a swap that drops one is refused" do
    stored = [list_of([item("a", @child), item("b", nil)])]
    pushed = [list_of([item("b", @other_child), item("a", nil)])]

    assert {:error, %{paths: ["blocks[0].items[0].children"]}} =
             PushGuard.check(stored, pushed, nil)
  end

  test "item children are compared by content: a pure reorder passes" do
    stored = [list_of([item("a", @child), item("b", nil)])]
    pushed = [list_of([item("b", nil), item("a", @child)])]
    assert :ok = PushGuard.check(stored, pushed, nil)
  end

  test "two equal children stored count twice" do
    stored = [list_of([item("a", @child), item("b", @child)])]
    pushed = [list_of([item("a", @child), item("b", nil)])]

    assert {:error, %{paths: ["blocks[0].items[1].children"]}} =
             PushGuard.check(stored, pushed, nil)
  end

  test "a copy with an older or unknown mark is treated as unmarked" do
    stored = [para("p1", "One"), para("p2", "Two")]
    assert {:error, _} = PushGuard.check(stored, [para("p1", "One")], "0")
  end

  test "a marked copy may remove anything it showed" do
    stored = [para("p1", "One"), nested_list(@child), callout(@body)]
    assert :ok = PushGuard.check(stored, [para("p1", "One")], PushGuard.print_mark())
  end

  test "an unmarked copy that removes nothing is let through" do
    stored = [para("p1", "One"), nested_list(@child)]
    edited = [para("p1", "One, edited"), nested_list(@child), para("p3", "Added")]
    assert :ok = PushGuard.check(stored, edited, nil)
  end

  test "derive refuses before deriving, and derives when allowed" do
    stored = [para("p1", "One"), para("p2", "Two")]
    assert {:error, %{code: _}} = PushGuard.derive(stored, [para("p1", "One")], nil)

    assert {:ok, _minted, [_ | _]} =
             PushGuard.derive(stored, [para("p1", "One")], PushGuard.print_mark())
  end

  test "a sync answer whose bpml printed carries the mark; one without bpml does not" do
    assert PushGuard.mark(%{bpml: "<p>x</p>\n"}).bpmlPrint == PushGuard.print_mark()
    refute Map.has_key?(PushGuard.mark(%{bpml: nil}), :bpmlPrint)
  end
end
