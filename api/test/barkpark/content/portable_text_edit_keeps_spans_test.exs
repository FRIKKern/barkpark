defmodule Barkpark.Content.PortableTextEditKeepsSpansTest do
  @moduledoc """
  task-74ef03a381b961ce: Studio's rich-text editor turns a Portable Text block
  into HTML and back when it is edited. The edited block keeps the `_key` of
  every span the edit did not add, the whitespace characters of its text and
  every field of its mark definitions, also those the HTML does not carry.

  Each test renders the stored value with `to_html/1`, changes the HTML the way
  the browser editor posts it (a no-break space as `&nbsp;`) and reads it back
  with `from_html/2`.

  Synthetic fixtures only.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText

  defp span(key, text, marks \\ []),
    do: %{"_type" => "span", "_key" => key, "text" => text, "marks" => marks}

  defp block(key, children, defs \\ []) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => defs,
      "children" => children
    }
  end

  # What a browser's innerHTML writes for the stored value.
  defp editor_html(stored),
    do: stored |> PortableText.to_html() |> String.replace(" ", "&nbsp;")

  defp edit(stored, from, to) do
    html = editor_html(stored)
    assert html =~ from
    PortableText.from_html(String.replace(html, from, to), stored)
  end

  defp keys(%{"children" => children}), do: Enum.map(children, & &1["_key"])

  defp stored do
    [
      block("intro9", [span("c4f1a7", "An untouched opening line.")]),
      block("para3e", [
        span("8d2e01", "Toast with "),
        span("91ab3c", "plum jam", ["strong"]),
        span("a07f55", " and a cup of "),
        span("b3c912", "mint tea", ["em"]),
        span("c6d0aa", ".")
      ])
    ]
  end

  describe "span keys" do
    test "editing one span of a block keeps every other span _key in that block" do
      [intro, para] = edit(stored(), "and a cup of", "and a mug of")

      assert intro == Enum.at(stored(), 0)
      assert para["_key"] == "para3e"
      assert keys(para) == ~w(8d2e01 91ab3c a07f55 b3c912 c6d0aa)
      assert Enum.at(para["children"], 2)["text"] == " and a mug of "

      assert para ==
               put_in(Enum.at(stored(), 1), ["children", Access.at(2), "text"], " and a mug of ")
    end

    test "editing the text of a marked span keeps its _key" do
      [_intro, para] = edit(stored(), "plum jam", "apricot jam")

      assert keys(para) == ~w(8d2e01 91ab3c a07f55 b3c912 c6d0aa)
      assert %{"text" => "apricot jam", "marks" => ["strong"]} = Enum.at(para["children"], 1)
    end

    test "a span the edit adds gets a fresh key and the others keep theirs" do
      [_intro, para] = edit(stored(), "Toast with ", "Toast <em>warm</em> with ")

      old = ~w(8d2e01 91ab3c a07f55 b3c912 c6d0aa)

      assert ["8d2e01", warm, with, "91ab3c", "a07f55", "b3c912", "c6d0aa"] = keys(para)
      refute warm in old
      refute with in old
      assert warm != with
      assert %{"text" => "warm", "marks" => ["em"]} = Enum.at(para["children"], 1)
    end

    test "a span whose marks change keeps its _key" do
      [_intro, para] = edit(stored(), "<em>mint tea</em>", "<strong>mint tea</strong>")

      assert keys(para) == ~w(8d2e01 91ab3c a07f55 b3c912 c6d0aa)
      assert %{"_key" => "b3c912", "marks" => ["strong"]} = Enum.at(para["children"], 3)
    end
  end

  describe "whitespace" do
    defp nbsp_stored do
      [
        block("ws01", [
          span("e1", "Kettle", ["em"]),
          span("e2", " "),
          span("e3", "on", ["strong"]),
          span("e4", " the stove now")
        ])
      ]
    end

    test "a U+00A0 in an edited block is stored as U+00A0 after save" do
      [b] = edit(nbsp_stored(), "Kettle", "Big kettle")

      assert keys(b) == ~w(e1 e2 e3 e4)
      assert Enum.map(b["children"], & &1["text"]) == ["Big kettle", " ", "on", " the stove now"]
    end

    test "a U+00A0 in the edited span itself stays U+00A0" do
      [b] = edit(nbsp_stored(), "stove", "old stove")

      assert %{"_key" => "e4", "text" => " the old stove now"} = Enum.at(b["children"], 3)
    end

    test "a U+00A0 at the edge of an edited block is text, not markup" do
      stored = [block("ws02", [span("f1", " Indented line ")])]
      [b] = edit(stored, "Indented", "Indented first")

      assert [%{"_key" => "f1", "text" => " Indented first line "}] = b["children"]
    end
  end

  describe "mark definitions" do
    defp defs_stored do
      [
        block(
          "lnk1",
          [
            span("g1", "See "),
            span("g2", "the guide", ["ann1"]),
            span("g3", " or "),
            span("g4", "the map", ["lnk9"]),
            span("g5", ".")
          ],
          [
            %{
              "_type" => "linkAnnotation",
              "_key" => "ann1",
              "linkType" => "external",
              "url" => "https://guide.example.test/",
              "noopener" => true
            },
            %{
              "_type" => "link",
              "_key" => "lnk9",
              "href" => "https://map.example.test/",
              "noopener" => true,
              "rel" => "nofollow"
            }
          ]
        )
      ]
    end

    test "a markDef field the editor does not render survives an edit to its block" do
      [b] = edit(defs_stored(), " or ", " and also ")

      assert b["markDefs"] == Enum.at(defs_stored(), 0)["markDefs"]
      assert keys(b) == ~w(g1 g2 g3 g4 g5)
    end

    test "a markDef field the editor does not render survives an edit of the link text" do
      [b] = edit(defs_stored(), "the map", "the city map")

      assert b["markDefs"] == Enum.at(defs_stored(), 0)["markDefs"]

      assert %{"_key" => "g4", "text" => "the city map", "marks" => ["lnk9"]} =
               Enum.at(b["children"], 3)
    end

    test "a changed link address keeps the fields the editor does not render" do
      [b] = edit(defs_stored(), "https://map.example.test/", "https://atlas.example.test/")

      assert [
               _,
               %{
                 "_key" => "lnk9",
                 "href" => "https://atlas.example.test/",
                 "noopener" => true,
                 "rel" => "nofollow"
               }
             ] =
               b["markDefs"]
    end
  end
end
