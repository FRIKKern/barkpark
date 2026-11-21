defmodule Barkpark.PortableDoc.BpmlCalloutBodyTest do
  @moduledoc """
  A callout's body survives BPML (task-4c27c15194ae9369). The rule is the paper
  editor's callout-words.js: `content` is the callout's own first paragraph and
  `slots.body` is what comes after it, so neither is a copy of the other.

  A callout with a `slots` key prints in the structured form; one without
  prints inline, byte for byte as before:

      <callout tone="info">
        <content>inline</content>
        <slot name="body">
          <p>blocks</p>
        </slot>
      </callout>

  `push/2` runs what `Papers.BpmlView.push/3` runs, without the database:
  `CalloutBody.resolve/4`, then `Diff.derive/3`. The HTTP rows are in
  `bulldocs_bpml_callout_body_push_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{BlockIds, Bpml}
  alias Barkpark.PortableDoc.Bpml.{CalloutBody, Diff, UnprintableError}
  alias Barkpark.Test.BpmlWords

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp callout(extra) do
    Map.merge(
      %{"id" => "c1", "type" => "callout", "tone" => "info", "title" => "Heads up"},
      extra
    )
  end

  defp two_block_body,
    do: callout(%{"content" => text("Read this first."), "slots" => %{"body" => body()}})

  defp body, do: [p("c1-a", "The second paragraph."), p("c1-b", "The third paragraph.")]
  defp image, do: %{"id" => "c1-i", "type" => "image", "src" => "/m/one.png", "alt" => "Bridge"}
  defp section(id, blocks), do: %{"id" => id, "type" => "section", "blocks" => blocks}

  defp round_trip(blocks) do
    assert {:ok, parsed} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
    parsed
  end

  defp codes(bpml) do
    assert {:error, errors} = Bpml.parse_blocks(bpml)
    Enum.map(errors, & &1.code)
  end

  defp paper(blocks), do: Bpml.print_paper(%{"slug" => "s", "title" => "T", "blocks" => blocks})

  # A pull of `stored`, edited by `edit`, pushed back: {:ok, stored result, notes} or the refusal.
  defp push(stored, edit) do
    bpml = paper(stored)
    {:ok, pulled} = Bpml.parse_copy(bpml)
    pulled = BlockIds.ensure_block_ids(pulled["blocks"])
    {:ok, copy} = Bpml.parse_copy(edit.(bpml))
    copy = Map.update!(copy, "blocks", &BlockIds.ensure_block_ids/1)

    with {:ok, pushed, notes} <- CalloutBody.resolve(stored, stored, pulled, copy),
         {:ok, result, _ops} <- Diff.derive(stored, pushed, pulled) do
      {:ok, result, notes}
    end
  end

  defp refused_code({:refused, %{code: code}}), do: code
  defp refused_code(other), do: other

  # Documents written here, and the <kept> lines each prints, for the words check (U9).
  @documents %{
    "two-block body" => [:two_block_body],
    "a body repeating the content's words" => [:repeated],
    "empty body" => [:empty_body],
    "body, no content" => [:body_no_content],
    "list in body" => [:list_in_body],
    "table and nested callout in body" => [:table_and_nested],
    "callout with body in a section" => [:in_section],
    "callout with body in a card slot" => [:in_card],
    "image body in a section" => [:image_in_section]
  }

  @kept %{
    "image body in a section" => [
      {"s1", "callout c1: its body holds a block BPML cannot write (image)"}
    ]
  }

  defp doc(:two_block_body), do: two_block_body()

  defp doc(:repeated),
    do:
      callout(%{
        "content" => text("Read this."),
        "slots" => %{"body" => [p("c1-a", "Read this.")]}
      })

  defp doc(:empty_body),
    do: callout(%{"content" => text("Nothing below."), "slots" => %{"body" => []}})

  defp doc(:body_no_content), do: callout(%{"slots" => %{"body" => body()}})

  defp doc(:list_in_body) do
    list = %{"id" => "c1-l", "type" => "list", "items" => [text("one"), text("two")]}
    callout(%{"content" => text("Steps:"), "slots" => %{"body" => [list]}})
  end

  defp doc(:table_and_nested) do
    table = %{
      "id" => "c1-t",
      "type" => "table",
      "head" => [text("Name"), text("Value")],
      "rows" => [[text("depth"), text("two")]]
    }

    inner =
      callout(%{"id" => "c2", "content" => text("Inner words."), "slots" => %{"body" => body2()}})

    callout(%{"content" => text("Outer words."), "slots" => %{"body" => [table, inner]}})
  end

  defp doc(:in_section), do: section("s1", [p("s1-p", "Before."), two_block_body()])

  defp doc(:in_card),
    do: %{"id" => "k1", "type" => "card", "slots" => %{"body" => [two_block_body()]}}

  defp doc(:image_in_section) do
    section("s1", [
      p("s1-p", "Before the callout."),
      callout(%{"content" => text("Look."), "slots" => %{"body" => [image()]}})
    ])
  end

  defp body2, do: [p("c2-a", "Nested body words.")]

  # U1, U2, U3
  test "print then parse of a callout with content and a two-block body gives the same block" do
    assert round_trip([two_block_body()]) == [two_block_body()]
  end

  test "the printout spells the content, then the body slot, as the callout's children" do
    assert Bpml.print_blocks([two_block_body()]) ==
             """
             <callout id="c1" tone="info" title="Heads up">
               <content>Read this first.</content>
               <slot name="body">
                 <p id="c1-a">The second paragraph.</p>
                 <p id="c1-b">The third paragraph.</p>
               </slot>
             </callout>
             """
  end

  test "a callout with no slots key prints exactly as before, and its Paper has no mark" do
    block = callout(%{"content" => text("Only inline.")})

    assert Bpml.print_blocks([block]) ==
             ~s(<callout id="c1" tone="info" title="Heads up">Only inline.</callout>\n)

    assert round_trip([block]) == [block]
    refute paper([block]) =~ "print="
    assert paper([two_block_body()]) =~ ~s(<paper slug="s" title="T" print="2">)
  end

  # U4: the empty shapes, each by map equality.
  test "content [] or absent, and body [] or absent, each read back as stored" do
    shapes = [
      callout(%{"content" => [], "slots" => %{"body" => body()}}),
      callout(%{"slots" => %{"body" => body()}}),
      callout(%{"content" => text("x"), "slots" => %{"body" => []}}),
      callout(%{"content" => text("x")})
    ]

    for block <- shapes, do: assert(round_trip([block]) == [block])
    assert Bpml.print_blocks([Enum.at(shapes, 2)]) =~ ~s(<slot name="body"/>)
    refute Bpml.print_blocks([Enum.at(shapes, 1)]) =~ "<content>"
  end

  test "slots with no body prints as <kept>, and an unedited push keeps it as stored" do
    stored = [callout(%{"content" => text("x"), "slots" => %{}})]

    assert Bpml.print_blocks(stored) ==
             ~s(<kept id="c1" type="callout" why="callout c1: its slots hold no body"/>\n)

    assert {:ok, ^stored, []} = push(stored, & &1)
  end

  # U5
  test "a malformed body pulls as <kept>; unedited it stays, changed it is refused" do
    for bad <- [%{"x" => 1}, nil, "words"] do
      stored = [callout(%{"content" => text("x"), "slots" => %{"body" => bad}})]
      assert Bpml.print_blocks(stored) =~ "its body is not a list of blocks"
      assert {:ok, ^stored, []} = push(stored, & &1)

      assert "bpml_kept" ==
               refused_code(push(stored, &String.replace(&1, ~s(id="c1"), ~s(id="c9"))))
    end
  end

  test "a slot other than body pulls as <kept>, naming the slots" do
    block = callout(%{"content" => text("x"), "slots" => %{"body" => [], "aside" => []}})
    assert Bpml.print_blocks([block]) =~ "it has slots other than body (aside, body)"
  end

  # U6
  test "body block ids are printed, read back, and kept when the callout is edited" do
    stored = [two_block_body()]
    assert Bpml.print_blocks(stored) =~ ~s(<p id="c1-a">)

    assert {:ok, [result], []} =
             push(stored, &String.replace(&1, "Read this first.", "Read this first, please."))

    assert result["content"] == text("Read this first, please.")
    assert result["slots"]["body"] == body()
  end

  # U7
  test "the parser reads the structured form past whitespace, and refuses the wrong shapes" do
    spaced = ~s(<callout>\n\n   <content>a</content>\n  <slot name="body"/>\n</callout>)
    assert {:ok, [%{"content" => [_], "slots" => %{"body" => []}}]} = Bpml.parse_blocks(spaced)

    assert "callout-mixed" in codes(
             ~s(<callout>loose <slot name="body"><p>x</p></slot></callout>)
           )

    assert "callout-mixed" in codes(~s(<callout>text <content>a</content></callout>))

    assert "callout-mixed" in codes(
             ~s(<callout><content>a</content>loose<slot name="body"/></callout>)
           )

    assert "callout-mixed" in codes(~s(<callout><content>a</content><p>x</p></callout>))

    assert "callout-content" in codes(
             ~s(<callout><content>a</content><content>b</content><slot name="body"/></callout>)
           )

    assert "callout-content" in codes(
             ~s(<callout><slot name="body"/><content>a</content></callout>)
           )

    assert "callout-slot" in codes(~s(<callout><slot name="body"/><slot name="body"/></callout>))

    assert "callout-slot" in codes(~s(<callout><slot name="aside"><p>x</p></slot></callout>))
    assert "callout-slot" in codes(~s(<callout><slot><p>x</p></slot></callout>))
  end

  test "the structured form without a slot is a callout with no body" do
    assert {:ok, [block]} = Bpml.parse_blocks(~s(<callout id="c1"><content>a</content></callout>))
    assert block == %{"id" => "c1", "type" => "callout", "content" => text("a")}
  end

  test "a <kept> line is an error to every parse but the push's" do
    assert "kept" in codes(~s(<kept id="c1" type="callout" why="x"/>))

    assert {:ok, [%{"type" => "$kept"}]} =
             Bpml.parse_copy_blocks(~s(<kept id="c1" type="callout"/>))
  end

  # U8
  test "a callout with a body round-trips inside a section, a card slot, and another body" do
    for name <- [:in_section, :in_card, :table_and_nested, :list_in_body] do
      assert {name, round_trip([doc(name)])} == {name, [doc(name)]}
    end
  end

  test "a list item holding a callout with a body is refused, never printed without it" do
    callout_item = %{"content" => [two_block_body()]}
    list = %{"id" => "l1", "type" => "list", "items" => [callout_item]}

    case (try do
            {:printed, BpmlWords.check([list], %{})}
          rescue
            e in UnprintableError -> {:refused, e}
          end) do
      {:refused, _} -> :ok
      {:printed, %{missing: missing}} -> assert missing == []
    end
  end

  # U9
  test "every document here keeps its words through the shared words check" do
    for {name, [key]} <- @documents do
      result = BpmlWords.check([doc(key)], %{})
      assert result.missing == [], "#{name}: #{inspect(result.missing)}"
      assert result.kept == Map.get(@kept, name, []), name
    end
  end

  # U10
  test "a callout BPML cannot write keeps its whole top-level section as one <kept> line" do
    stored = [doc(:image_in_section)]

    assert Bpml.print_blocks(stored) ==
             ~s(<kept id="s1" type="section" why="callout c1: ) <>
               ~s(its body holds a block BPML cannot write \(image\)"/>\n)

    assert {:ok, ^stored, []} = push(stored, & &1)
  end

  test "a <kept> line written inside another block is refused, never stored" do
    nested = ~s(<p id="c1-a">The second paragraph.</p>\n<kept id="c1-b" type="paragraph"/>)
    plain = [two_block_body()]

    assert "bpml_kept" ==
             refused_code(
               push(
                 plain,
                 &String.replace(&1, ~s(<p id="c1-a">The second paragraph.</p>), nested)
               )
             )

    kept = [doc(:image_in_section), p("p9", "After.")]
    line = ~s(<p id="p9">After.</p>)

    again =
      &String.replace(
        &1,
        line,
        ~s(<section id="s9">#{line}<kept id="s1" type="section"/></section>)
      )

    assert "bpml_kept" == refused_code(push(kept, again))
  end

  test "an edited callout's body is kept by the diff" do
    stored = [two_block_body()]
    shown = round_trip(stored)
    edited = stored |> Bpml.print_blocks() |> String.replace("Read this first.", "Read on.")
    assert {:ok, pushed} = Bpml.parse_blocks(edited)
    assert {:ok, [result], [_ | _]} = Diff.derive(stored, pushed, shown)
    assert result["slots"]["body"] == body()
  end
end
