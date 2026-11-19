defmodule Barkpark.PortableDoc.BpmlPrintRoundtripSweepTest do
  @moduledoc """
  Every stored document the test suite carries, through the printer's own
  check: each top-level block is printed and parsed back. The test prints the
  list of block paths BPML cannot carry yet and the count, and fails when that
  list moves from the one pinned below, so a shape that becomes printable (or
  stops being printable) is seen in the diff.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.{Canonical, UnprintableError}

  # The work queue. Each is a real loss: the stored block holds something the
  # print does not show. Depth-limit list items belong to task-c4dc5e0c3d253460;
  # the two span cases store spans no cell can carry.
  @still_refused [
    "api/priv/portable_doc/goldens/limits/list-at-the-depth-limit.golden.json blocks[0].items[0] (list)",
    "api/priv/portable_doc/goldens/limits/list-one-level-above-the-depth-limit.golden.json blocks[0].items[0] (list)",
    "api/priv/portable_doc/goldens/limits/table-span-with-no-stored-origin.golden.json blocks[0].spans (table)",
    "api/priv/portable_doc/goldens/limits/table-spans-sharing-an-origin.golden.json blocks[0].spans[1] (table)"
  ]

  # Refused by the printer's older kinds (block, inline, mark, head cell); this
  # check does not move them.
  @unprintable_already 82

  defp verdicts do
    for {file, blocks} <- Barkpark.BpmlStoredDocuments.all(),
        {block, i} <- Enum.with_index(blocks) do
      verdict =
        try do
          {:ok, parsed} = Bpml.parse_blocks(Bpml.print_blocks([block]))

          if parsed == [block] do
            :same
          else
            {:rewritten,
             Enum.reject(Canonical.rules(), &(Canonical.normalize([block], [&1]) == [block]))}
          end
        rescue
          e in UnprintableError ->
            if e.kind == :round_trip,
              do: {:lost, String.replace_prefix(e.type, "blocks[0]", "blocks[#{i}]")},
              else: {:unprintable, e.message}
        end

      {file, i, block["type"], verdict}
    end
  end

  test "lists what the printer's round trip refuses today" do
    all = verdicts()
    count = fn pred -> Enum.count(all, fn {_f, _i, _t, v} -> pred.(v) end) end
    lost = for {f, _i, t, {:lost, p}} <- all, do: "#{f} #{p} (#{t})"

    per_rule =
      for rule <- Canonical.rules() do
        n =
          count.(fn v -> match?({:rewritten, rs} when is_list(rs), v) and rule in elem(v, 1) end)

        "#{rule} #{n}"
      end

    IO.puts(
      "\nround trip over #{length(all)} top-level blocks: " <>
        "#{count.(&(&1 == :same))} identical, " <>
        "#{count.(&match?({:rewritten, _}, &1))} identical after the rewrites (#{Enum.join(per_rule, ", ")}), " <>
        "#{length(lost)} refused, #{count.(&match?({:unprintable, _}, &1))} unprintable already\n" <>
        Enum.join(lost, "\n")
    )

    assert lost == @still_refused
    assert count.(&match?({:unprintable, _}, &1)) == @unprintable_already
  end
end
