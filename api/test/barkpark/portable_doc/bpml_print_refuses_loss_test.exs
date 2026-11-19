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

  for {name, content, mark} <- [
        {"a bold link", [link([marked("bold link", ["strong"])])], "strong"},
        {"an italic link", [link([marked("italic link", ["em"])])], "em"},
        {"a link inside a bold run",
         [
           marked("before ", ["strong"]),
           link([marked("in", ["strong"])]),
           marked(" after", ["strong"])
         ], "strong"}
      ] do
    test "#{name} round-trips with the mark on every link character" do
      blocks = [%{"type" => "paragraph", "content" => unquote(Macro.escape(content))}]
      assert {:ok, parsed} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
      assert parsed == Canonical.normalize(blocks)

      chars = link_marks(parsed)
      assert chars != []
      assert Enum.all?(chars, &(unquote(mark) in &1))
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
