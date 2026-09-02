# BPML corpus replay — the fixed-point check for `bp paper pull` / `push`.
#
#   mix run --no-start scripts/bpml_corpus_replay.exs <corpus.json> [--out <report.json>]
#
# `<corpus.json>` is a dump of the published papers, either a bare JSON list or
# the `bp doc ls paper --all -o json` envelope (`{"documents": [...]}`). Every
# entry needs `_id` and `blocks`; drafts and block-less rows are skipped.
#
#   env -u BARKPARK_TOKEN bp doc ls paper --all -o json > /tmp/corpus.json
#
# WHY A SCRIPT AND NOT A TEST: the corpus is ~43 MB of live production papers
# and cannot be committed. The committed REGRESSIONS are the golden cases in
# test/barkpark/portable_doc/bpml_roundtrip_property_test.exs; this replays the
# real corpus on demand so a claim about "N papers" is a measurement, not an
# estimate.
#
# Per paper it answers four questions, in order:
#
#   refused      print 1 raised the typed UnprintableError — an honest 422 pull.
#                Bucketed by `kind:type` so a coverage change is countable.
#   crashed      print 1 raised something ELSE — a printer bug (a raw 500).
#   reparse_fail the printed BPML does not parse back — the isomorphism is broken.
#   unstable     print 2 differs from print 1 BYTE-WISE. This is the churn
#                defect: pulling and pushing WITHOUT editing rewrites the stored
#                paper and `bp paper diff` reports a change on an unedited file.
#   text_loss    print 2 differs from print 1 with the TAGS STRIPPED — characters
#                did not survive the round trip. A strict subset of `unstable`,
#                and the one that is destruction rather than churn.
#
# Exit status is 0 unless `--max-unstable N` / `--max-refused N` are given and
# exceeded, so the script can be wired into a gate later without changing shape.

defmodule BpmlCorpusReplay do
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  def main(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [out: :string, max_unstable: :integer, max_refused: :integer, list: :boolean]
      )

    path =
      case args do
        [p | _] -> p
        [] -> abort("usage: mix run --no-start scripts/bpml_corpus_replay.exs <corpus.json>")
      end

    papers = load(path)
    results = Enum.map(papers, &replay/1)
    report(papers, results, opts)
  end

  defp load(path) do
    unless File.exists?(path), do: abort("no such corpus file: #{path}")

    path
    |> File.read!()
    |> Jason.decode!()
    |> case do
      %{"documents" => docs} -> docs
      docs when is_list(docs) -> docs
      _ -> abort("corpus must be a JSON list or a {\"documents\": [...]} envelope")
    end
    |> Enum.reject(&Map.get(&1, "_draft", false))
    |> Enum.filter(&match?([_ | _], Map.get(&1, "blocks")))
  end

  defp replay(%{"_id" => id, "blocks" => blocks}) do
    try do
      first = Bpml.print_blocks(blocks)

      case Bpml.parse_blocks(first) do
        {:ok, reparsed} ->
          second = Bpml.print_blocks(reparsed)

          cond do
            second == first -> {id, :stable, nil}
            strip_tags(second) != strip_tags(first) -> {id, :text_loss, nil}
            true -> {id, :unstable, nil}
          end

        {:error, errors} ->
          {id, :reparse_fail, errors |> Enum.map(& &1[:code]) |> Enum.uniq() |> Enum.join(",")}
      end
    rescue
      e in UnprintableError -> {id, :refused, "#{e.kind}:#{e.type}"}
      e -> {id, :crashed, Exception.message(e) |> String.slice(0, 120)}
    end
  end

  # Everything OUTSIDE angle brackets, whitespace-normalised: the characters a
  # reader sees. Two prints that agree here but differ byte-wise moved element
  # BOUNDARIES only — churn. Two that disagree here dropped content.
  defp strip_tags(bpml) do
    bpml
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp report(papers, results, opts) do
    by = Enum.group_by(results, fn {_id, status, _d} -> status end)
    count = fn s -> by |> Map.get(s, []) |> length() end

    printable =
      count.(:stable) + count.(:unstable) + count.(:text_loss) + count.(:reparse_fail)

    IO.puts("BPML corpus replay — #{length(papers)} block-bearing published papers")
    IO.puts("  printable (print 1 succeeded) : #{printable}")
    IO.puts("    byte-stable on print 2      : #{count.(:stable)}")
    IO.puts("    UNSTABLE on print 2         : #{count.(:unstable)}")
    IO.puts("    TEXT LOSS on print 2        : #{count.(:text_loss)}")
    IO.puts("    reparse failures            : #{count.(:reparse_fail)}")
    IO.puts("  typed refusals (honest 422)   : #{count.(:refused)}")
    IO.puts("  CRASHES (printer bug)         : #{count.(:crashed)}")

    IO.puts("\n  refusals by kind:type")

    by
    |> Map.get(:refused, [])
    |> Enum.frequencies_by(fn {_id, _s, detail} -> detail end)
    |> Enum.sort_by(fn {_k, n} -> -n end)
    |> Enum.each(fn {k, n} -> IO.puts("    #{String.pad_trailing(k, 26)} #{n}") end)

    if opts[:list] do
      for status <- [:unstable, :text_loss, :reparse_fail, :crashed] do
        rows = Map.get(by, status, [])

        unless rows == [] do
          IO.puts("\n  #{status}:")
          Enum.each(rows, fn {id, _s, d} -> IO.puts("    #{id}#{d && " — #{d}"}") end)
        end
      end
    end

    if out = opts[:out] do
      json =
        results
        |> Enum.map(fn {id, status, detail} ->
          %{"id" => id, "status" => to_string(status), "detail" => detail}
        end)
        |> Jason.encode!()

      File.write!(out, json)
      IO.puts("\n  wrote #{out}")
    end

    fail =
      [
        opts[:max_unstable] && count.(:unstable) + count.(:text_loss) > opts[:max_unstable] &&
          "unstable",
        opts[:max_refused] && count.(:refused) > opts[:max_refused] && "refused"
      ]
      |> Enum.filter(&is_binary/1)

    unless fail == [], do: abort("ceiling exceeded: #{Enum.join(fail, ", ")}")
  end

  defp abort(msg) do
    IO.puts(:stderr, "bpml_corpus_replay: #{msg}")
    System.halt(1)
  end
end

BpmlCorpusReplay.main(System.argv())
