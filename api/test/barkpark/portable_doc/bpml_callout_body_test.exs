defmodule Barkpark.PortableDoc.BpmlCalloutBodyTest do
  @moduledoc """
  A callout's body survives BPML (task-4c27c15194ae9369). The rule is the paper
  editor's callout-words.js: `content` is the callout's own first paragraph and
  `slots.body` is what comes after it, so neither is a copy of the other.

  A callout with a `slots` key prints its children, never inline beside them:

      <callout tone="info">
        <content>inline</content>
        <slot name="body">
          <p>blocks</p>
        </slot>
      </callout>

  `<content>` is printed only when the block has a `content` key; an empty body
  is `<slot name="body"/>`. A callout with no `slots` key prints exactly as it
  did before. `body` is the only slot a callout has.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.{Diff, UnprintableError}

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp callout(extra) do
    Map.merge(%{"id" => "c1", "type" => "callout", "tone" => "info", "title" => "Heads up"}, extra)
  end

  defp two_block_body,
    do: callout(%{"content" => text("Read this first."), "slots" => %{"body" => body()}})

  defp body, do: [p("c1-a", "The second paragraph."), p("c1-b", "The third paragraph.")]

  defp round_trip(blocks) do
    assert {:ok, parsed} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
    parsed
  end

  defp codes(bpml) do
    assert {:error, errors} = Bpml.parse_blocks(bpml)
    Enum.map(errors, & &1.code)
  end

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

  test "a callout with no slots key prints exactly as before, inline" do
    block = callout(%{"content" => text("Only inline.")})

    assert Bpml.print_blocks([block]) ==
             ~s(<callout id="c1" tone="info" title="Heads up">Only inline.</callout>\n)

    assert round_trip([block]) == [block]
  end

  test "an empty body prints as a self-closed slot and reads back empty" do
    block = callout(%{"content" => text("Nothing below."), "slots" => %{"body" => []}})

    assert Bpml.print_blocks([block]) =~ ~s(<slot name="body"/>)
    assert round_trip([block]) == [block]
  end

  test "a callout with a body and no content key reads back with no content key" do
    block = callout(%{"slots" => %{"body" => body()}})

    refute Bpml.print_blocks([block]) =~ "<content>"
    assert round_trip([block]) == [block]
  end

  test "a body holding a block with its own children keeps them" do
    list = %{"id" => "c1-l", "type" => "list", "items" => [text("one"), text("two")]}

    block = callout(%{"content" => text("Steps:"), "slots" => %{"body" => [list]}})
    assert round_trip([block]) == [block]
  end

  test "a slot other than body is refused by the printer, naming the callout" do
    block = callout(%{"content" => text("x"), "slots" => %{"body" => [], "aside" => []}})
    e = assert_raise UnprintableError, fn -> Bpml.print_blocks([block]) end
    assert e.kind == :block
    assert e.type == "callout"
  end

  test "the parser refuses a slot other than body, and the mixed and doubled forms, by name" do
    assert "callout-slot" in codes(~s(<callout><slot name="aside"><p>x</p></slot></callout>))

    assert "callout-mixed" in codes(
             ~s(<callout>loose text<slot name="body"><p>x</p></slot></callout>)
           )

    assert "callout-mixed" in codes(
             ~s(<callout><content>a</content>loose<slot name="body"/></callout>)
           )

    assert "callout-content" in codes(
             ~s(<callout><content>a</content><content>b</content><slot name="body"/></callout>)
           )

    assert "callout-slot" in codes(~s(<callout><content>a</content></callout>))
  end

  test "an edited push keeps the callout's body" do
    stored = [two_block_body()]
    shown = round_trip(stored)

    edited =
      stored
      |> Bpml.print_blocks()
      |> String.replace("Read this first.", "Read this first, please.")

    assert {:ok, pushed} = Bpml.parse_blocks(edited)
    assert {:ok, result, [_ | _]} = Diff.derive(stored, pushed, shown)

    assert [%{"content" => [%{"value" => edited_text}], "slots" => %{"body" => kept}}] = result
    assert edited_text == "Read this first, please."
    assert kept == body()
  end
end
