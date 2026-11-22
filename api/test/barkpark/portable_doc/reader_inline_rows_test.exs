defmodule Barkpark.PortableDoc.ReaderInlineRowsTest do
  @moduledoc """
  The rows that tie the editor's copy of the reader's prose fallbacks
  (`api/assets/paper-editor/src/markdown/reader-inline.js`) to the reader
  (`test/support/fixtures/paper-editor/reader_inline_rows.json`). Each row holds a
  block and the inline runs the reader shows for it; the editor runs the same rows
  (`src/markdown/__reader_inline_rows.test.mjs`).

  Which keys the reader takes words from is derived here, not listed: every line
  type (the types the editor's Markdown writes as a line of words) is rendered with
  each key that can hold words set alone (every word-holding field
  `Spec.Fields` declares on any type, plus every key the BPML printer reads through
  its alias lists), and a pair is derived wherever that key's word comes out of the
  render. Each derived pair needs a row, so a reader that starts reading a new key
  reds this test.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Spec.Fields

  @path Path.expand("../../support/fixtures/paper-editor/reader_inline_rows.json", __DIR__)
  @printer Path.expand("../../../lib/barkpark/portable_doc/bpml/printer.ex", __DIR__)
  @external_resource @path
  @external_resource @printer
  @fixture @path |> File.read!() |> Jason.decode!()
  @inline_keys ~w(content text)

  defp render(block), do: Render.render_block(block, %{style: :article})

  # The block a row says the reader shows: its own keys, with the first-line words
  # put in `content` as the row's runs. A callout's body slot stays: it is drawn as
  # blocks after the first line, not as its words.
  defp shown(block, inline), do: block |> Map.drop(@inline_keys) |> Map.put("content", inline)

  defp words?(shape) do
    case shape do
      s when s in [:string, :scalar, :inline] -> true
      {:any_of, shapes} -> Enum.any?(shapes, &words?/1)
      {:object, fields} -> Enum.any?(Map.values(fields), &(&1 in [:block, :blocks]))
      _ -> false
    end
  end

  # key => the declared shapes it has anywhere.
  defp word_keys do
    declared =
      for {_type, fields} <- Fields.all(), {key, shape} <- fields, words?(shape), reduce: %{} do
        acc -> Map.update(acc, key, [shape], &[shape | &1])
      end

    printer =
      Regex.scan(~r/(?:alias_get|plain_alias)\(\w+, \[([^\]]+)\]\)/, File.read!(@printer))
      |> Enum.flat_map(fn [_, list] ->
        Regex.scan(~r/"([^"]+)"/, list, capture: :all_but_first)
      end)
      |> List.flatten()

    Enum.reduce(printer, declared, fn key, acc -> Map.put_new(acc, key, [:string]) end)
  end

  # Each value a key can hold, carrying `word`.
  defp probes(shapes, word) do
    para = %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => word}]}

    objects =
      for {:object, fields} <- shapes,
          do: Map.new(for({k, s} <- fields, s in [:block, :blocks], do: {k, [para]}))

    [word, [%{"type" => "text", "value" => word}]] ++ objects
  end

  defp base(type),
    do: %{"type" => type, "tone" => "note", "level" => 2} |> Map.take(base_keys(type))

  defp base_keys("callout"), do: ["type", "tone"]
  defp base_keys("heading"), do: ["type", "level"]
  defp base_keys(_), do: ["type"]

  defp derived do
    for type <- @fixture["line_types"],
        {key, shapes} <- word_keys(),
        word = "Probe#{:erlang.phash2({type, key})}",
        Enum.any?(probes(shapes, word), &(render(Map.put(base(type), key, &1)) =~ word)),
        do: {type, key}
  end

  test "the reader's text keys are derived, not listed" do
    pairs = MapSet.new(derived())

    for pair <- [
          {"paragraph", "text"},
          {"heading", "text"},
          {"blockquote", "text"},
          {"callout", "text"}
        ] do
      assert pair in pairs, "derived pairs hold #{inspect(pair)}: #{inspect(Enum.sort(pairs))}"
    end
  end

  test "every derived pair has a row with that key alone" do
    alone =
      for row <- @fixture["rows"],
          keys = Map.keys(row["block"]) -- base_keys(row["block"]["type"]),
          match?([_], keys),
          into: MapSet.new(),
          do: {row["block"]["type"], hd(keys)}

    missing = Enum.reject(derived(), &(&1 in alone))
    assert missing == [], "derived pairs with no row: #{inspect(missing)}"
  end

  for row <- @fixture["rows"] do
    @row row

    test "#{row["row"]}" do
      assert render(@row["block"]) == render(shown(@row["block"], @row["inline"]))
    end
  end
end
