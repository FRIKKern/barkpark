defmodule Barkpark.PortableDoc.BpmlPrintRefusesLossTest do
  @moduledoc """
  Pulling a Paper never drops part of it: a print whose parse does not give the
  document back is refused, naming the block path, and nothing is printed.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.{Canonical, UnprintableError}

  defp t(v), do: %{"type" => "text", "value" => v}

  defp refusal(blocks) do
    assert_raise UnprintableError, fn -> Bpml.print_blocks(blocks) end
  end

  defp paper(blocks), do: %{"slug" => "s", "title" => "T", "blocks" => blocks}

  defp callout,
    do: %{
      "type" => "callout",
      "tone" => "info",
      "content" => [t("Heads up.")],
      "slots" => %{
        "body" => [
          %{"type" => "paragraph", "content" => [t("First body paragraph.")]},
          %{"type" => "list", "items" => [[t("a body item")]]}
        ]
      }
    }

  defp nested_list,
    do: %{
      "type" => "list",
      "items" => [
        %{"content" => [t("a")], "children" => [%{"type" => "list", "items" => [[t("b")]]}]}
      ]
    }

  defp paragraph_child,
    do: %{
      "type" => "list",
      "items" => [
        %{
          "content" => [t("a")],
          "children" => [%{"type" => "paragraph", "content" => [t("under a")]}]
        }
      ]
    }

  test "a callout with content and a two-block body is refused at its body" do
    e = refusal([%{"type" => "paragraph", "content" => [t("before")]}, callout()])
    assert e.kind == :round_trip
    assert e.type =~ ~r/^blocks\[1\]/
    assert Exception.message(e) =~ "BPML cannot carry blocks[1]"
    assert_raise UnprintableError, fn -> Bpml.print_paper(paper([callout()])) end
  end

  test "a list item holding a nested list is refused at that item" do
    e = refusal([nested_list()])
    assert e.kind == :round_trip
    assert e.type =~ ~r/^blocks\[0\]\.items\[0\]/
    assert_raise UnprintableError, fn -> Bpml.print_paper(paper([nested_list()])) end
  end

  test "a list item holding a paragraph is refused at that item" do
    e = refusal([paragraph_child()])
    assert e.kind == :round_trip
    assert e.type =~ ~r/^blocks\[0\]\.items\[0\]/
  end

  test "the markdown nested list from step 0 is refused at blocks[0].items[0]" do
    blocks = Barkpark.PortableDoc.FromMarkdown.blocks("- a\n  - b")
    assert [%{"items" => [%{"children" => [_]}]}] = blocks

    e = refusal(blocks)
    assert e.kind == :round_trip
    assert e.type =~ ~r/^blocks\[0\]\.items\[0\]/
  end

  # Marked links: the mark on every link character survives the round trip.
  defp marked(v, marks), do: %{"type" => "text", "value" => v, "marks" => marks}
  defp link(children), do: %{"type" => "link", "href" => "/x", "children" => children}

  defp link_marks(blocks) do
    for %{"content" => content} <- blocks,
        %{"type" => "link", "children" => cs} <- content,
        %{"value" => v} = c <- cs,
        _char <- String.graphemes(v),
        do: Map.get(c, "marks", [])
  end

  @marked_links [
    {"a bold link", [{"bold link", ["strong"], :link}], "strong"},
    {"an italic link", [{"italic link", ["em"], :link}], "em"},
    {"a link inside a bold run",
     [{"before ", ["strong"], :text}, {"in", ["strong"], :link}, {" after", ["strong"], :text}],
     "strong"}
  ]

  defp runs(spec) do
    for {v, marks, kind} <- spec do
      node = marked(v, marks)
      if kind == :link, do: link([node]), else: node
    end
  end

  for {name, spec, mark} <- @marked_links do
    test "#{name} round-trips with the mark on every link character" do
      blocks = [%{"type" => "paragraph", "content" => runs(unquote(Macro.escape(spec)))}]
      assert {:ok, parsed} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
      assert parsed == Canonical.normalize(blocks)

      chars = link_marks(parsed)
      assert chars != []
      assert Enum.all?(chars, &(unquote(mark) in &1))
    end
  end

  # A mark node holding more than its type and children: the print keeps only
  # the children, so the rest would be lost.
  @lossy_mark_nodes [
    {"a strong node also holding a value", %{"type" => "strong", "value" => "HIDDEN"}},
    {"a strong node carrying its own em mark", %{"type" => "strong", "marks" => ["em"]}},
    {"an em node carrying an annotation mark", %{"type" => "em", "marks" => ["k1"]}},
    {"a strong node carrying a link", %{"type" => "strong", "href" => "/x"}}
  ]

  for {name, node} <- @lossy_mark_nodes do
    test "#{name} is refused at that node" do
      node = Map.put(unquote(Macro.escape(node)), "children", [t("seen")])
      e = refusal([%{"type" => "paragraph", "content" => [node]}])
      assert e.kind == :round_trip
      assert e.type =~ ~r/^blocks\[0\]\.content/
    end
  end

  test "a document the text carries prints as before" do
    blocks = [
      %{"type" => "paragraph", "content" => [t("plain")]},
      %{"type" => "callout", "tone" => "info", "content" => [t("only content")]},
      %{"type" => "list", "items" => [[t("one")], [t("two")]]}
    ]

    printed = Bpml.print_blocks(blocks)
    assert {:ok, ^blocks} = Bpml.parse_blocks(printed)
  end
end
