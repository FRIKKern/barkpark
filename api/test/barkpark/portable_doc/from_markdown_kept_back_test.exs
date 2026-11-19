defmodule Barkpark.PortableDoc.FromMarkdownKeptBackTest do
  @moduledoc """
  `FromMarkdown.KeptBack`: the portabledoc fences an import keeps back, and the
  errors of their own blocks, at the place the blocks would have taken.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Warnings
  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.FromMarkdown.KeptBack

  @bad ~s([{"id": "h", "type": "heading", "level": 9, "text": "Nine"}])
  @markdown "# Plan\n\nText.\n\n```portabledoc\n#{@bad}\n```\n"

  test "read lists the kept-back fence at its code block and keeps blocks/1's output" do
    {blocks, fences} = KeptBack.read(@markdown)
    assert blocks == FromMarkdown.blocks(@markdown)
    assert Enum.at(blocks, 2) == %{"type" => "code", "value" => @bad}
    assert fences == [%{source: @bad, path: "/blocks/2"}]
  end

  test "a spliced fence, a plain code fence and a non-list fence report nothing" do
    good = ~s([{"type": "divider"}])
    assert {_, []} = KeptBack.read("```portabledoc\n#{good}\n```\n\n```\n#{@bad}\n```\n")

    {_, fences} =
      KeptBack.read(
        "```portabledoc\n{\"type\": \"divider\"}\n```\n\n```portabledoc\nnot json\n```"
      )

    assert length(fences) == 2
    assert KeptBack.errors(fences) == []
  end

  test "a fence's errors sit where its blocks would have been" do
    second = ~s([{"type": "divider"}, {"type": "heading", "level": 0, "text": "x"}])
    {_, fences} = KeptBack.read("Text.\n\n```portabledoc\n#{second}\n```\n")

    assert [%{code: :value_not_allowed, path: "/blocks/2/level"}] = KeptBack.errors(fences)
  end

  test "check reports a new fence error once, and not again over a paper that holds it" do
    Warnings.reset()
    {blocks, fences} = KeptBack.read(@markdown)

    assert KeptBack.check([], fences) == :ok

    assert [%{code: "portable_doc_invalid", violations: [%{path: "/blocks/2/level"}]}] =
             Warnings.drain()

    assert KeptBack.check(blocks, fences) == :ok
    assert Warnings.drain() == []
  end
end
