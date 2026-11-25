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
  # clash, and `pick/3` with a block both sides changed differently in a
  # certain line-up, the branch the merge inside one block takes. That one
  # is counted on the code itself (a call trace on `pick/3`'s returns), not
  # by keys: a block both changed in a line-up the merge does not trust
  # never gets there (#28747 review: 694 by key, 325 real).
  test "the seeds reach a merge, a clash, and a block both sides changed" do
    Code.ensure_loaded!(M)
    spec = [{[:_, {:changed, :_}, {:changed, :_}], [], [{:return_trace}]}]
    assert :erlang.trace_pattern({M, :pick, 3}, spec, [:local]) == 1

    # A process does not trace itself: the seeds run in `worker`, one at a
    # time, and each seed's trace is read once `trace_delivered` says all of
    # it is here.
    me = self()

    worker =
      spawn_link(fn ->
        for s <- @seeds do
          receive do: (:next -> :ok)
          {b, m, t} = PtMergeGen.triple(s)
          send(me, {:merged, match?({:ok, _}, M.merge(b, m, t))})
        end
      end)

    :erlang.trace(worker, true, [:call])

    counts =
      Enum.reduce(@seeds, %{ok: 0, clash: 0, both: 0}, fn _s, acc ->
        send(worker, :next)
        ok? = receive do: ({:merged, ok?} -> ok?)
        ref = :erlang.trace_delivered(worker)
        receive do: ({:trace_delivered, ^worker, ^ref} -> :ok)
        acc = Map.update!(acc, if(ok?, do: :ok, else: :clash), &(&1 + 1))
        if both_clashed?(), do: Map.update!(acc, :both, &(&1 + 1)), else: acc
      end)

    :erlang.trace_pattern({M, :pick, 3}, false, [:local])
    IO.puts("REACH #{inspect(counts)}")
    assert counts.ok >= 400 and counts.clash >= 400 and counts.both >= 600, inspect(counts)
  end

  # Whether a traced `pick/3` returned a clash; empties the trace messages.
  defp both_clashed?(hit \\ false) do
    receive do
      {:trace, _, :return_from, {M, :pick, 3}, {:clash, _, _}} -> both_clashed?(true)
      {:trace, _, _, _} -> both_clashed?(hit)
      {:trace, _, _, _, _} -> both_clashed?(hit)
    after
      0 -> hit
    end
  end

  test "inline: false gives the same result while the merge inside one block is not built" do
    for s <- @seeds do
      {b, m, t} = PtMergeGen.triple(s)
      assert M.merge(b, m, t) == M.merge(b, m, t, inline: false), "seed #{s}"
    end
  end
end
