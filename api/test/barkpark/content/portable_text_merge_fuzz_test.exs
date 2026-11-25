defmodule Barkpark.Content.PortableTextMergeFuzzTest do
  @moduledoc """
  The merge's output on seeded triples (`Barkpark.Test.PtMergeGen`), pinned
  per 25 seeds (task-3fc3cc94b435a5b0, plan /papers/pt-merge-inside-one-block).
  A change to `PortableTextMerge` anywhere but the merge inside one block
  (task-266ffbe9cd115f3c) turns a pin red. A change meant to move a pin
  regenerates the file and says in its PR which seed ranges moved and why:

      PT_MERGE_FUZZ_REGEN=1 mix test test/barkpark/content/portable_text_merge_fuzz_test.exs

  The merge inside one block adds its invariants here (the plan's 2-4, and
  the share of seeds that reach it).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M
  alias Barkpark.Test.PtMergeGen

  @seeds 1..2000
  @pins "test/fixtures/portable_text_merge/fuzz_pins.json"

  # A hash of the result that does not depend on how a map is laid out.
  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(canon(term)))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

  defp canon(%{} = m), do: m |> Enum.map(fn {k, v} -> {k, canon(v)} end) |> Enum.sort()
  defp canon(l) when is_list(l), do: Enum.map(l, &canon/1)
  defp canon(t) when is_tuple(t), do: t |> Tuple.to_list() |> canon() |> List.to_tuple()
  defp canon(x), do: x

  defp results,
    do: Map.new(@seeds, fn s -> {s, apply(M, :merge, Tuple.to_list(PtMergeGen.triple(s)))} end)

  # One pin per 25 seeds keeps the file small; a red names the seed ranges.
  test "every seed's merge equals its pin" do
    now =
      results()
      |> Enum.sort()
      |> Enum.chunk_every(25)
      |> Map.new(fn [{s, _} | _] = chunk -> {"#{s}-#{s + length(chunk) - 1}", digest(chunk)} end)

    if System.get_env("PT_MERGE_FUZZ_REGEN") == "1" do
      sorted =
        Enum.sort_by(now, fn {r, _} -> r |> String.split("-") |> hd() |> String.to_integer() end)

      File.write!(@pins, Jason.encode_to_iodata!(Jason.OrderedObject.new(sorted), pretty: true))
    end

    pins = @pins |> File.read!() |> Jason.decode!()
    moved = for {r, h} <- now, pins[r] != h, do: r
    assert moved == [], "seeds moved from their pin: #{Enum.join(Enum.sort(moved), ", ")}"
  end

  # The seeds are only worth pinning if they reach each branch: a merge, a
  # clash, and a block both sides changed in place (what the merge inside
  # one block takes).
  test "the seeds reach a merge, a clash, and a block both sides changed" do
    counts =
      Enum.reduce(@seeds, %{ok: 0, clash: 0, both: 0}, fn s, acc ->
        {b, m, t} = PtMergeGen.triple(s)

        acc =
          Map.update!(
            acc,
            if(match?({:ok, _}, M.merge(b, m, t)), do: :ok, else: :clash),
            &(&1 + 1)
          )

        if both_changed?(b, m, t), do: Map.update!(acc, :both, &(&1 + 1)), else: acc
      end)

    assert counts.ok >= 40 and counts.clash >= 40 and counts.both >= 40, inspect(counts)
  end

  defp both_changed?(base, mine, theirs) do
    by_key = fn l -> Map.new(l, &{&1["_key"], &1}) end
    {m, t} = {by_key.(mine), by_key.(theirs)}

    Enum.any?(base, fn b ->
      {x, y} = {m[b["_key"]], t[b["_key"]]}
      x != nil and y != nil and x != b and y != b
    end)
  end

  test "inline: false gives the same result while the merge inside one block is not built" do
    for s <- @seeds do
      {b, m, t} = PtMergeGen.triple(s)
      assert M.merge(b, m, t) == M.merge(b, m, t, inline: false), "seed #{s}"
    end
  end
end
