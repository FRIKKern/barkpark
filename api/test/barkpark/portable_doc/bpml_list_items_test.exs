defmodule Barkpark.PortableDoc.BpmlListItemsTest do
  @moduledoc """
  A nested list survives BPML (task-0b448ea0847a6b4f): every level, every item
  id and the reader's words print, and read back. What the printer cannot
  round-trip prints the whole top-level block as `<kept>` (`ListItems`'
  fallback rows). The push rows, with the database and the write wall, are in
  `bulldocs_bpml_list_items_push_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Bpml, Render, Validate}
  alias Barkpark.PortableDoc.Bpml.{ListItems, PrintMark, UnprintableError}
  alias Barkpark.Test.BpmlWords

  @max Validate.max_depth()

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp list(items), do: %{"type" => "list", "items" => items}
  defp list(id, items), do: %{"id" => id, "type" => "list", "items" => items}

  # The shared nested fixture's list (test/support/fixtures/nested-list-carriers.json).
  defp carriers do
    list("nested-list", [
      %{
        "id" => "plan",
        "content" => [%{"type" => "strong", "children" => text("Plan")}],
        "text" => "Inactive parent fallback",
        "audit" => %{"keep" => true},
        "children" => [
          %{
            "type" => "list",
            "ordered" => true,
            "items" => [
              %{"id" => "build", "text" => "Build", "children" => [list(["Verify"])]},
              "Ship"
            ]
          }
        ]
      },
      "Flat sibling",
      %{
        "id" => "fallback",
        "content" => [],
        "text" => "Fallback parent",
        "children" => [%{"type" => "ordered-list", "items" => ["Alias child"]}]
      }
    ])
  end

  @carriers_bpml """
  <ul id="nested-list">
    <li id="plan"><b>Plan</b>
      <ul ordered="true">
        <li id="build">Build
          <ul>
            <li>Verify</li>
          </ul>
        </li>
        <li>Ship</li>
      </ul>
    </li>
    <li>Flat sibling</li>
    <li id="fallback">Fallback parent
      <ul ordered="true">
        <li>Alias child</li>
      </ul>
    </li>
  </ul>
  """

  defp parse!(bpml) do
    assert {:ok, blocks} = Bpml.parse_copy_blocks(bpml)
    blocks
  end

  defp codes(bpml) do
    assert {:error, errors} = Bpml.parse_copy_blocks(bpml)
    Enum.map(errors, & &1.code)
  end

  # `levels` lists, each the only child of the one item above it (Validate's own nest).
  defp nest(levels) do
    Enum.reduce(2..levels//1, list(["leaf"]), fn _, inner -> list([%{"children" => [inner]}]) end)
    |> Map.put("id", "deep")
  end

  defp depth(%{"items" => [%{"children" => [inner]}]}), do: 1 + depth(inner)
  defp depth(%{"items" => _}), do: 1

  defp html(blocks), do: Render.render_blocks(blocks, %{style: :article})

  describe "print" do
    test "every level, item id and the reader's words print, as nested <ul>" do
      assert Bpml.print_blocks([carriers()]) == @carriers_bpml
    end

    test "read back, the levels, ids and words are there; aliases and strings normalize" do
      assert [
               %{
                 "id" => "nested-list",
                 "type" => "list",
                 "items" => [
                   %{
                     "id" => "plan",
                     "content" => [%{"type" => "text", "marks" => ["strong"], "value" => "Plan"}],
                     "children" => [
                       %{
                         "type" => "list",
                         "ordered" => true,
                         "items" => [
                           %{
                             "id" => "build",
                             "content" => [%{"type" => "text", "value" => "Build"}],
                             "children" => [%{"type" => "list", "items" => [verify]}]
                           },
                           ship
                         ]
                       }
                     ]
                   },
                   sibling,
                   %{
                     "id" => "fallback",
                     "content" => fallback,
                     "children" => [%{"type" => "list", "ordered" => true, "items" => [alias]}]
                   }
                 ]
               }
             ] = parse!(@carriers_bpml)

      assert {verify, ship, sibling, alias} ==
               {text("Verify"), text("Ship"), text("Flat sibling"), text("Alias child")}

      assert fallback == text("Fallback parent")
    end

    # Missing: the `text` the reader does not show (not printed; the write wall
    # refuses an edit to its block), and the word "ordered" of the alias type
    # name `ordered-list`.
    test "every word the reader shows is in the parsed printout" do
      missing = [{"Inactive", 1, 0}, {"fallback", 2, 1}, {"ordered", 1, 0}, {"parent", 2, 1}]
      assert %{missing: ^missing, kept: []} = BpmlWords.check([carriers()], %{})
    end

    test "an ordered alias renders the same as the list it reads back as" do
      stored = [list("l1", [%{"id" => "a", "text" => "A", "children" => [alias_list()]}])]
      assert html(parse!(Bpml.print_blocks(stored))) == html(stored)
    end

    test "a bare string item renders the same as the inline array it reads back as" do
      stored = [list("l1", ["One", %{"id" => "b", "text" => "Two", "children" => [list(["x"])]}])]
      parsed = parse!(Bpml.print_blocks(stored))
      assert hd(hd(parsed)["items"]) == text("One")
      assert html(parsed) == html(stored)
    end

    test "a line break that ends an item's words is kept; only the printer's own is not" do
      stored = [list("l1", [%{"id" => "a", "text" => "Words\n", "children" => [list(["x"])]}])]

      assert [%{"items" => [%{"content" => [%{"value" => "Words\n"}]}]}] =
               parse!(Bpml.print_blocks(stored))
    end
  end

  defp alias_list, do: %{"type" => "numbered_list", "items" => ["One"]}

  describe "fallback rows: the whole top-level block prints as <kept>" do
    test "the rows are one table" do
      assert ListItems.fallbacks() |> Map.keys() |> Enum.sort() == [:f1, :f2, :f3, :f4]
    end

    for {name, item, why} <- [
          {"F1 an item without an id holding a field BPML cannot write",
           %{"text" => "A", "audit" => %{"keep" => true}},
           "list l1: its item 1 holds a field BPML cannot write (audit)"},
          {"F1 an item without an id whose text the reader does not show",
           %{"content" => [%{"type" => "text", "value" => "A"}], "text" => "Hidden"},
           "list l1: its item 1 holds a field BPML cannot write (text)"},
          {"F1 any item whose content is not a list, id or not",
           %{"id" => "a", "content" => "A string", "text" => "Shown"},
           "list l1: its item 1 holds a field BPML cannot write (content)"},
          {"F2 an item without an id holding a child that is not a list",
           %{"text" => "A", "children" => [%{"type" => "paragraph", "text" => "Hidden"}]},
           "list l1: its item 1 holds children that are not lists"},
          {"F3 a string item holding JSON inline nodes", ~s([{"type":"text","value":"A"}]),
           "list l1: its item 1 is a JSON string of inline nodes"}
        ] do
      @item item
      @why why
      test name do
        bpml = Bpml.print_blocks([list("l1", [@item])])
        assert bpml == ~s(<kept id="l1" type="list" why="#{@why}"/>\n)
        assert [%{"type" => "$kept", "id" => "l1", "of" => "list", "why" => @why}] = parse!(bpml)
      end
    end

    test "F4 lists nested deeper than a stored Paper may nest them" do
      assert Bpml.print_blocks([nest(@max + 1)]) =~
               ~s(<kept id="deep" type="list" why="a list: its item 1 nests lists deeper than #{@max} levels")
    end

    test "an item with an id prints its words whatever else it holds" do
      item = %{"id" => "a", "text" => "A", "audit" => 1, "children" => ["x", list(["y"])]}
      assert Bpml.print_blocks([list("l1", [item])]) =~ ~s(<li id="a">A\n)
    end

    test "inside a section the section is kept; a top-level list with no id is refused" do
      section = %{"id" => "s1", "type" => "section", "blocks" => [list([%{"audit" => 1}])]}
      assert Bpml.print_blocks([section]) =~ ~s(<kept id="s1" type="section")

      assert_raise UnprintableError, ~r/"list"/, fn ->
        Bpml.print_blocks([list([%{"audit" => 1}])])
      end
    end
  end

  describe "the print mark (Bpml.PrintMark)" do
    defp paper(blocks), do: Bpml.print_paper(%{"slug" => "s", "title" => "T", "blocks" => blocks})

    defp callout_body,
      do: %{
        "id" => "c1",
        "type" => "callout",
        "tone" => "info",
        "slots" => %{
          "body" => [%{"id" => "c1-a", "type" => "paragraph", "content" => text("Body.")}]
        }
      }

    test "a callout body marks 2, a nested list or an item id 3, the highest wins, a flat list none" do
      flat = list("f", [text("a"), %{"content" => text("b"), "checked" => true}])
      with_id = list("f", [%{"id" => "a", "content" => text("a")}])
      nested = list("n", [%{"content" => text("a"), "children" => [list([text("b")])]}])

      assert paper([callout_body()]) =~ ~s(<paper slug="s" title="T" print="2">\n)
      assert paper([with_id]) =~ ~s(<paper slug="s" title="T" print="3">\n)
      assert paper([nested]) =~ ~s(<paper slug="s" title="T" print="3">\n)
      assert paper([callout_body(), nested]) =~ ~s(<paper slug="s" title="T" print="3">\n)
      assert paper([flat]) =~ ~s(<paper slug="s" title="T">\n)
    end

    test "a copy marked 2 is old for nested lists only; one marked 3 for none" do
      nested = list("n", [%{"id" => "a", "content" => text("a")}])
      assert PrintMark.newer([callout_body(), nested], 2) == [{3, ListItems}]
      assert PrintMark.newer([callout_body(), nested], 3) == []
      assert PrintMark.newer([callout_body(), nested], 1) == PrintMark.forms()
    end

    test "the old printer's list is the list without item ids and children" do
      stored =
        list("l", [%{"id" => "a", "content" => text("a"), "children" => [list(["b"])]}, "c"])

      assert Bpml.print_blocks([PrintMark.before(stored, 2)]) ==
               "<ul id=\"l\">\n  <li>a</li>\n  <li>c</li>\n</ul>\n"
    end
  end

  describe "parse" do
    test "lists at Validate's depth limit read back at every level" do
      assert Validate.validate(%{"blocks" => [nest(@max)]}) == :ok
      assert [deep] = parse!(Bpml.print_blocks([nest(@max)]))
      assert depth(deep) == @max
    end

    test "one level more is refused" do
      leaf = ~s(<li>leaf</li>)
      bpml = Bpml.print_blocks([nest(@max)])
      deeper = String.replace(bpml, leaf, ~s(<li>leaf<ul><li>past</li></ul></li>))
      assert "too-deep" in codes(deeper)
    end

    test "an item's words go before its nested lists" do
      assert codes(~s(<ul><li>a<ul><li>b</li></ul>after</li></ul>)) == ["text-after-list"]
      assert codes(~s(<ul><li>a<ul><li>b</li></ul><p>c</p></li></ul>)) == ["wrong-child"]
    end

    test "a plain item stays an inline array; id or checked make a map" do
      assert [%{"items" => [plain, with_id, done]}] =
               parse!(~s(<ul><li>a</li><li id="b">b</li><li checked="true">c</li></ul>))

      assert plain == text("a")
      assert with_id == %{"id" => "b", "content" => text("b")}
      assert done == %{"content" => text("c"), "checked" => true}
    end
  end
end
