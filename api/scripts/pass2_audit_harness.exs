# pass2_audit_harness.exs — reader-side dual-render for the paper edit⇄reader
# parity audit (charter W1.4). STANDALONE STATIC HARNESS — the only sanctioned
# reader-render path locally (mix phx.server dies; NEVER use it).
#
#   Run:   cd api && SHOWCASE_BLOCKS=<blocks.json> OUT_DIR=<dir> \
#              mix run --no-start scripts/pass2_audit_harness.exs
#
# Reproduce the input (the 91-block showcase lives on guerrilla, not in-repo):
#   bp doc get paper portabledoc-showcase -o json \
#     | python3 -c 'import sys,json; json.dump(json.load(sys.stdin)["blocks"], sys.stdout)' \
#     > /tmp/showcase_blocks.json
#   SHOWCASE_BLOCKS=/tmp/showcase_blocks.json
#
# For the FIRST occurrence of each block type it emits the READER HTML the canvas
# must match, via the SAME call the canvas paint makes —
# Barkpark.PortableDoc.Render.render_block(block, %{style: :article}) — writing
# one <hr>-delimited section per type to OUT_DIR/pass2_reader.html plus a
# type→signature table to stdout. Exit 0 unless a type raises a render exception;
# an EMPTY render (unresolved live query, no snapshot) is reported as a NOTE.

alias Barkpark.PortableDoc.Render

out_dir = System.get_env("OUT_DIR") || System.tmp_dir!()

blocks_path =
  System.get_env("SHOWCASE_BLOCKS") ||
    raise "set SHOWCASE_BLOCKS=<path to the showcase blocks .json> (see header for the bp dump one-liner)"

blocks = blocks_path |> File.read!() |> Jason.decode!()

# First occurrence of each block type (the audit classifies per TYPE, not per instance).
by_type =
  Enum.reduce(blocks, %{}, fn b, acc ->
    t = b["type"] || "?"
    Map.put_new(acc, t, b)
  end)

opts = %{style: :article}

rows =
  by_type
  |> Enum.sort_by(fn {t, _} -> t end)
  |> Enum.map(fn {t, block} ->
    html =
      try do
        Render.render_block(block, opts)
      rescue
        e -> "!! RENDER ERROR: #{Exception.message(e)}"
      end

    # Signature: leading tag + class of the reader's outermost element.
    sig =
      case Regex.run(~r/<([a-zA-Z0-9]+)([^>]*class="[^"]*")?/, html) do
        [_, tag, cls] -> "<#{tag}#{cls}>"
        [_, tag] -> "<#{tag}>"
        _ -> String.slice(html, 0, 60)
      end

    {t, html, sig}
  end)

# stdout summary — the per-block signature table.
IO.puts("== READER render_block(:article) per showcase block type (#{length(rows)} types) ==")
Enum.each(rows, fn {t, html, sig} ->
  IO.puts(String.pad_trailing(t, 16) <> " #{byte_size(html)}B  " <> String.slice(sig, 0, 90))
end)

# HTML artifact — full reader markup per type, for the classification table evidence.
doc =
  rows
  |> Enum.map(fn {t, html, _sig} ->
    "<!-- ===== #{t} ===== -->\n<h3 style=\"font-family:monospace\">#{t}</h3>\n#{html}\n<hr>"
  end)
  |> Enum.join("\n")

out = Path.join(out_dir, "pass2_reader.html")
File.write!(out, "<!doctype html><meta charset=utf-8>\n" <> doc)
IO.puts("\nWrote #{out} (#{byte_size(doc)}B, #{length(rows)} block types)")

# Guard: fail only on a RENDER EXCEPTION. An empty string is a legitimate render
# result for a live-query widget with an unresolved query + no snapshot (the
# static harness has no DB) — surfaced as a NOTE, not a failure.
errored = Enum.filter(rows, fn {_t, html, _} -> String.starts_with?(html, "!!") end)
empties = Enum.filter(rows, fn {_t, html, _} -> html == "" end)

if empties != [] do
  IO.puts("\nNOTE — #{length(empties)} type(s) rendered EMPTY (unresolved live query, no snapshot):")
  Enum.each(empties, fn {t, _, _} -> IO.puts("  #{t}") end)
end

if errored != [] do
  IO.puts("\n!! #{length(errored)} block types raised a RENDER EXCEPTION:")
  Enum.each(errored, fn {t, html, _} -> IO.puts("  #{t}: #{String.slice(html, 0, 120)}") end)
  System.halt(1)
end

IO.puts("\nOK — all #{length(rows)} block types rendered without exception.")
