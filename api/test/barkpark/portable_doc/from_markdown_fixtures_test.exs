defmodule Barkpark.PortableDoc.FromMarkdownFixturesTest do
  @moduledoc """
  `FromMarkdown` against the shared from-markdown cases in the golden pack
  (`priv/portable_doc/goldens/from-markdown/<name>.json`, each
  `{"markdown": ..., "blocks": [...]}`). `@portable-doc/text` `fromMarkdown`
  runs the same files after the pack syncs, so both importers give the same
  blocks for the same Markdown. The cases' source is
  `test/support/fixtures/from-markdown.json`; the pack copies it.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render.Util
  alias Barkpark.PortableDoc.Validate
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Pack

  @dir Path.join(Pack.dir(), "from-markdown")

  defp cases do
    @dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.basename(&1, ".json"), Jason.decode!(File.read!(&1))})
  end

  test "the pack holds the from-markdown cases" do
    assert length(cases()) == 13
  end

  test "FromMarkdown gives each case's blocks" do
    failures =
      for {name, %{"markdown" => md, "blocks" => want}} <- cases(),
          (got = FromMarkdown.blocks(md)) != want,
          do: "#{name}:\n  got  #{Jason.encode!(got)}\n  want #{Jason.encode!(want)}"

    assert failures == [], "from-markdown cases that differ:\n" <> Enum.join(failures, "\n")
  end

  test "every case's blocks validate" do
    for {name, %{"markdown" => md, "blocks" => want}} <- cases() do
      assert Validate.validate(want) == :ok, "#{name}: the case's own blocks"
      assert Validate.validate(FromMarkdown.blocks(md)) == :ok, "#{name}: FromMarkdown's blocks"
    end
  end

  describe "hostile input" do
    @hostile [
      {"deep quotes", String.duplicate("> ", 5_000) <> "x"},
      {"deep lists", Enum.map_join(0..400, "\n", &(String.duplicate("  ", &1) <> "- x"))},
      {"deep emphasis", String.duplicate("*", 20_000) <> "x" <> String.duplicate("*", 20_000)},
      {"open brackets", String.duplicate("[", 50_000) <> "x"},
      {"huge", String.duplicate("word **bold** [l](https://example.com) `c`\n", 20_000)},
      {"script",
       "<script>alert(1)</script>\n\nhi <script>bad()</script>there <style>p{}</style>"},
      {"js links",
       "[a](javascript:alert(1)) ![b](JaVaScRiPt:x) [c]( javascript:x) [d](//evil.example)"},
      {"js fence",
       ~s(```portabledoc\n[{"type":"paragraph","content":[{"type":"link","href":" javascript:x","children":[]}]}]\n```)},
      {"deep fence", "```portabledoc\n" <> String.duplicate("[", 5_000) <> "\n```"}
    ]

    for {label, md} <- @hostile do
      @md md
      test "#{label} validates and links only to safe URLs" do
        blocks = FromMarkdown.blocks(@md)
        assert is_list(blocks)
        assert Validate.validate(blocks) == :ok
        for href <- hrefs(blocks), do: assert(Util.safe_url(href) == href, inspect(href))
      end
    end

    test "non-string input gives no blocks" do
      for input <- [nil, 1, %{}, ["# x"]], do: assert(FromMarkdown.blocks(input) == [])
    end
  end

  defp hrefs(%{"href" => href} = map),
    do: [href | map |> Map.delete("href") |> Map.values() |> Enum.flat_map(&hrefs/1)]

  defp hrefs(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&hrefs/1)
  defp hrefs(list) when is_list(list), do: Enum.flat_map(list, &hrefs/1)
  defp hrefs(_), do: []
end
