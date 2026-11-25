defmodule Barkpark.Content.PortableTextMergeFuzzTest do
  @moduledoc """
  The merge's output on seeded triples (`Barkpark.Test.PtMergeGen`), pinned
  per 25 seeds (task-3fc3cc94b435a5b0, plan /papers/pt-merge-inside-one-block).
  The pins hash the merge with `inline: false`, which leaves out the merge
  inside one block (`PortableTextMerge.Inline`, task-da701626f5be2143): a
  change to `PortableTextMerge` anywhere else turns a pin red, and work on
  `Inline` never moves one. Where `Inline` merges no block, the merge equals
  that pinned one (the plan's invariant 1). A change meant to move a pin
  regenerates the file and says in its PR which seed ranges moved and why:

      PT_MERGE_FUZZ_REGEN=1 mix test test/barkpark/content/portable_text_merge_fuzz_test.exs

  The triples are drawn with `:rand` (`exsss`) and `Enum.random/1`. An
  Elixir or OTP release that changes how either draws moves every pin with
  no change to the merge: a plain regen, with no code change, is then the
  fix, and its PR says so.

  The merge inside one block is checked on the same seeds: the share that
  reach it, and the plan's invariants 1-3.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextMerge, as: M
  alias Barkpark.Content.PortableTextMerge.Inline
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
    do:
      Map.new(@seeds, fn s ->
        {b, m, t} = PtMergeGen.triple(s)
        {s, M.merge(b, m, t, inline: false)}
      end)

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
  # clash, and `pick/4` with a block both sides changed differently in a
  # certain line-up, which the merge inside one block takes. That is counted
  # on the code itself (a call trace on `pick/4`), not by keys: a block both
  # changed in a line-up the merge does not trust never gets there (#28747
  # review: 694 by key, 325 real). At least 30% of the seeds merge a block
  # there (`{:inline, _}`).
  test "the seeds reach the merge inside one block, which keeps the plan's invariants 1-3" do
    Code.ensure_loaded!(M)
    spec = [{[:_, {:changed, :_}, {:changed, :_}, :_], [], [{:return_trace}]}]
    assert :erlang.trace_pattern({M, :pick, 4}, spec, [:local]) == 1
    on_exit(fn -> :erlang.trace_pattern({M, :pick, 4}, false, [:local]) end)

    # A process does not trace itself: the seeds run in `worker`, one at a
    # time, and each seed's trace is read once `trace_delivered` says all of
    # it is here.
    me = self()

    worker =
      spawn_link(fn ->
        for mode <- [:all, :text], s <- @seeds do
          receive do: (:next -> :ok)
          {b, m, t} = PtMergeGen.triple(s, mode)
          send(me, {:merged, s, M.merge(b, m, t)})
        end
      end)

    :erlang.trace(worker, true, [:call])

    counts =
      for(mode <- [:all, :text], s <- @seeds, do: {mode, s})
      |> Enum.reduce(%{}, fn {mode, s}, acc ->
        send(worker, :next)
        r = receive do: ({:merged, ^s, r} -> r)
        ref = :erlang.trace_delivered(worker)
        receive do: ({:trace_delivered, ^worker, ^ref} -> :ok)
        {calls, returns} = drain([], [])
        invariants({s, mode}, r, calls, Enum.count(returns, &match?({:inline, _}, &1)))
        inline? = Enum.any?(returns, &match?({:inline, _}, &1))
        kind = if match?({:ok, _}, r), do: :ok, else: :clash
        up = fn acc, k, add -> Map.update(acc, {mode, k}, add, &(&1 + add)) end

        acc
        |> up.(kind, 1)
        |> up.(:both, if(returns != [], do: 1, else: 0))
        |> up.(:inline, if(inline?, do: 1, else: 0))
      end)

    # The pinned triples reach a merge, a clash and a block both changed;
    # the text ones merge a block inside it in at least 30% of the seeds.
    assert counts[{:all, :ok}] >= 400 and counts[{:all, :clash}] >= 400 and
             counts[{:all, :both}] >= 600,
           inspect(counts)

    assert counts[{:text, :inline}] >= 600, inspect(counts)
  end

  # The traced `pick/4` calls' blocks and their returns; empties the trace.
  defp drain(calls, returns) do
    receive do
      {:trace, _, :call, {M, :pick, [blk, {:changed, m}, {:changed, t}, true]}} ->
        drain([{blk, m, t} | calls], returns)

      {:trace, _, :return_from, {M, :pick, 4}, r} ->
        drain(calls, [r | returns])

      {:trace, _, _, _} ->
        drain(calls, returns)
    after
      0 -> {calls, returns}
    end
  end

  defp invariants({s, mode}, r, calls, n) do
    {b, m, t} = PtMergeGen.triple(s, mode)
    r0 = M.merge(b, m, t, inline: false)

    # 1: no block merged inside it: the same bytes as without `Inline`.
    # 2: else only as many blocks differ (keys set aside) as it merged.
    if n == 0 do
      assert r == r0, "seed #{s}: invariant 1"
    else
      {now, before} = {blocks(r), blocks(r0)}
      assert length(now) == length(before), "seed #{s}: invariant 2"

      assert Enum.count(Enum.zip(now, before), fn {x, y} -> unkeyed(x) != unkeyed(y) end) <= n,
             "seed #{s}: invariant 2"
    end

    # 3: the merge either way round gives the same letters and fields.
    for {blk, mb, tb} <- calls do
      case {Inline.merge(blk, mb, tb), Inline.merge(blk, tb, mb)} do
        {:clash, :clash} ->
          :ok

        {{:ok, x}, {:ok, y}} ->
          assert letters(x) == letters(y) and fields(x) == fields(y), "seed #{s}: invariant 3"

        other ->
          flunk("seed #{s}: invariant 3, #{inspect(other, limit: 6)}")
      end
    end
  end

  defp blocks({:ok, bs}), do: bs
  defp blocks({:clash, _texts, bs}), do: bs

  defp unkeyed(%{} = m), do: m |> Map.delete("_key") |> Map.new(fn {k, v} -> {k, unkeyed(v)} end)
  defp unkeyed(l) when is_list(l), do: Enum.map(l, &unkeyed/1)
  defp unkeyed(x), do: x

  # (grapheme, marks) in order, a link by its def without `_key`.
  defp letters(blk) do
    defs = Map.new(blk["markDefs"] || [], &{&1["_key"], Map.delete(&1, "_key")})

    for span <- blk["children"],
        g <- String.graphemes(span["text"]),
        do: {g, Enum.sort(Enum.map(span["marks"] || [], &Map.get(defs, &1, &1)))}
  end

  defp fields(blk), do: Map.drop(blk, ~w(_key children markDefs))
end
