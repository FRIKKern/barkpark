defmodule Barkpark.PortableDoc.Render.StoredWordsRenderTest do
  @moduledoc """
  Every word stored in a document shows on the page (task-e70b11497064225b, criterion
  [1]). For each document in the conformance pack (`priv/portable_doc/goldens/blocks`,
  one input per block kind) and each shared fixture under `test/support/fixtures/`
  that holds one, every word of every stored string appears in the rendered text, in
  the article and in the email.

  A stored string that is not words a reader reads (an id, a URL, a tone, a status
  code, …) is skipped by its key, and each skip below says why. A key is never
  skipped silently: a word missing from the page under any other key reds the test.
  A fixture file that holds no document is named on `@not_documents` with its reason.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @pack Path.expand("../../../../priv/portable_doc/goldens/blocks", __DIR__)
  @fixtures Path.expand("../../../support/fixtures", __DIR__)

  # Keys skipped in every block, with why. A skip names only a field that carries
  # no words a reader reads: an id, a key, a style, an address, a code or a number.
  # A field whose words a reader sees is never skipped; if it fails, that is a
  # finding, not a skip.
  @skip %{
    "type" => "a key: the kind of a block or a run",
    "id" => "an id: a block's, a note's or a question's identity",
    "tone" => "a style: drawn as a color or an icon",
    "kind" => "a style: picks how the block is drawn",
    "mode" => "a style: picks how a section lays out its blocks",
    "gap" => "a style: the space between a section's blocks",
    "priority" => "a style or a number: an action's emphasis, a task's rank",
    "status" => "a code: a task's or a todo's state, drawn as its label or column",
    "syncKey" => "a key: ties code tabs together across a page",
    "lang" => "a code: a language tag, set as an attribute",
    "href" => "an address: a link target",
    "src" => "an address: a media file",
    "poster" => "an address or a time: a media still or start point",
    "anchor" => "a key: a link target inside the page",
    "slug" => "a key: a Paper's address, the target of its title link",
    "ref" => "a key: the sheet the block embeds",
    "source" => "an address or a key: where a value or a node comes from",
    "sourceDefault" => "an address or a key: where a duel's values come from",
    "polyline" => "a code: an encoded route, drawn as a line"
  }

  # Paths skipped in one block kind only (the top-level block's type, then the keys
  # down to the string, list indexes left out), with why. Same rule as above.
  @skip_in %{
    {"field-select", "options.value"} => "a key: an option's stored value, not its label",
    {"field-datetime", "value"} => "a number: a timestamp, drawn formatted",
    {"field-image", "value"} => "an address: the image file"
  }

  # Fixture files that hold no Portable Doc document, by pattern, with why.
  @not_documents [
    {"box_*.json", "box status payloads"},
    {"chat_*.json", "chat transcript, label and capability rows"},
    {"code-*.json", "code language and emphasis rows"},
    {"from-markdown.json", "Markdown import cases, not stored documents"},
    {"inline-*.json", "inline run cases"},
    {"merge_gate_*.json", "merge gate wording rows"},
    {"portable-doc-limits.json", "limit cases"},
    {"preview-parity.json", "preview parity rows"},
    {"sdk-capabilities-parity.json", "SDK route rows"},
    {"section-boundary-rules.json", "section boundary cases"},
    {"sheet-*.json", "sheet engine rows"},
    {"table-col-types.json", "table column type rows"}
  ]

  defp documents do
    pack =
      for file <- Path.wildcard(Path.join(@pack, "*.golden.json")) |> Enum.sort() do
        golden = file |> File.read!() |> Jason.decode!()
        {"goldens/blocks/" <> Path.basename(file), [golden["input"]]}
      end

    fixtures =
      for file <- Path.wildcard(Path.join(@fixtures, "*.json")) |> Enum.sort(),
          blocks = file |> File.read!() |> Jason.decode!() |> document_blocks(),
          blocks != nil,
          do: {"fixtures/" <> Path.basename(file), blocks}

    pack ++ fixtures
  end

  defp document_blocks(%{"input" => %{"type" => _} = block}), do: [block]
  defp document_blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks

  defp document_blocks([%{"type" => _} | _] = blocks),
    do: if(Enum.all?(blocks, &match?(%{"type" => _}, &1)), do: blocks)

  defp document_blocks(_), do: nil

  defp matches?(pattern, name) do
    regex = pattern |> Regex.escape() |> String.replace("\\*", "[^/]*")
    Regex.match?(~r/^#{regex}$/, name)
  end

  # {path, string} for every stored string under a top-level block, the path being
  # the map keys down to it (a list's strings take the list's key), last key first.
  defp leaves(value, path, acc) when is_binary(value), do: [{path, value} | acc]

  defp leaves(value, path, acc) when is_list(value),
    do: Enum.reduce(value, acc, &leaves(&1, path, &2))

  defp leaves(value, path, acc) when is_map(value),
    do: Enum.reduce(value, acc, fn {k, v}, acc -> leaves(v, [k | path], acc) end)

  defp leaves(_value, _path, acc), do: acc

  defp skipped?(_type, [key | _]) when is_map_key(@skip, key), do: true

  defp skipped?(type, path),
    do: Map.has_key?(@skip_in, {type, path |> Enum.reverse() |> Enum.join(".")})

  defp words(s) do
    s
    |> String.downcase()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/u, ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp decode(s) do
    s
    |> String.replace(~r/&#(\d+);/, fn m ->
      <<String.to_integer(String.slice(m, 2..-2//1))::utf8>>
    end)
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn m ->
      <<String.to_integer(String.slice(m, 3..-2//1), 16)::utf8>>
    end)
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end

  # The page's words two ways: with each tag as a space, and the text run together
  # (a word split by inline markup, <strong>care</strong>ful, reads as one). The words
  # a reader gets from an attribute (an image's alt, a hover title, an aria-label)
  # count as shown.
  defp shown(html) do
    attrs =
      ~r/\s(?:alt|title|aria-label)="([^"]*)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map_join(" ", &hd/1)

    spaced = (html |> String.replace(~r/<[^>]*>/, " ")) <> " " <> attrs
    spaced = decode(spaced)
    joined = html |> String.replace(~r/<[^>]*>/, "") |> decode() |> String.downcase()
    {MapSet.new(words(spaced)), joined}
  end

  defp missing(blocks, style) do
    {set, joined} = shown(Render.render_blocks(blocks, %{style: style}))

    for block <- blocks,
        type = block["type"],
        {path, string} <- leaves(block, [], []),
        not skipped?(type, path),
        word <- words(string),
        not MapSet.member?(set, word) and not String.contains?(joined, word),
        uniq: true,
        do: "#{type} #{path |> Enum.reverse() |> Enum.join(".")}: #{inspect(word)}"
  end

  test "every fixture file is read as a document or named as holding none" do
    names = @fixtures |> Path.join("*.json") |> Path.wildcard() |> Enum.map(&Path.basename/1)

    unread =
      for name <- names,
          @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!() |> document_blocks() ==
            nil,
          not Enum.any?(@not_documents, fn {pattern, _} -> matches?(pattern, name) end),
          do: name

    assert unread == [], "fixture files neither read nor named: #{inspect(unread)}"

    unused =
      for {pattern, _} <- @not_documents,
          not Enum.any?(names, &matches?(pattern, &1)),
          do: pattern

    assert unused == [], "named patterns that match no file: #{inspect(unused)}"
  end

  test "the walk reads the pack and the shared fixtures" do
    docs = documents()
    assert Enum.count(docs, fn {name, _} -> String.starts_with?(name, "goldens/") end) == 80

    assert {"fixtures/nested-list-carriers.json", _} =
             List.keyfind(docs, "fixtures/nested-list-carriers.json", 0)
  end

  for style <- [:article, :email] do
    test "#{style}: every stored word shows on the page" do
      failures =
        for {name, blocks} <- documents(),
            miss = missing(blocks, unquote(style)),
            miss != [],
            do: "#{name}: #{Enum.join(miss, ", ")}"

      assert failures == [],
             "#{unquote(style)}: stored words the page does not show:\n" <>
               Enum.join(failures, "\n")
    end
  end
end
