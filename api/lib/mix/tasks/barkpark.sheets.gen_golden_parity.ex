defmodule Mix.Tasks.Barkpark.Sheets.GenGoldenParity do
  @moduledoc """
  Generate the cross-surface **golden parity fixture** and write it to all three
  mirror paths. ONE canonical golden sheet — the executable source of truth that
  the Elixir renderer (`Core.snapshot_for` + `Fmt.display`), the api parity tests,
  the web SDK and the Go TUI (`internal/pdrender`) must all agree on.

      mix barkpark.sheets.gen_golden_parity

  Emits pretty-printed JSON (`snapshot`, `expected`, `head`, `spans`,
  `right_aligned`, `error_refs`, `fmt_vocabulary`, `sv`) to:

    * `api/test/support/fixtures/sheet-golden-parity.json`
    * `web/__tests__/fixtures/sheet-golden-parity.json`
    * `internal/pdrender/testdata/sheet-golden-parity.json`

  The three mirrors are byte-identical. Do NOT hand-edit any of them — re-run this
  task and re-verify all five surfaces (the failure message on the api lock says
  exactly this). The freshness lock lives in
  `test/barkpark/plugins/sheets/golden_parity_fixture_test.exs` (asserts the
  committed api mirror equals `build/0`, the three mirrors decode term-identical,
  and `sv == Core.snapshot_schema_version/0`). The Go golden assertion lives in
  `internal/pdrender/sheet_golden_test.go`.

  `build/0` is pure (only `Core.snapshot_for/2` + `Core.snapshot_schema_version/0`
  + `Fmt.vocabulary/0`) so the freshness test can regenerate in-memory without
  `Mix.Task`.
  """
  @shortdoc "Regenerate the cross-surface sheet golden-parity fixture (three mirrors)"

  use Mix.Task

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Fmt

  # ── the canonical golden sheet ───────────────────────────────────────────────
  #
  # Mirrors the parity contract sheet (sheets_parity_test.exs) — every value type,
  # fmt hint, a computed formula (A5 =B2*2 -> 2400), a stale cell, single- and
  # multi-row merges (B3:C3, B4:C5), col widths, row heights, a frozen head + col,
  # bools, a date, percent/currency/thousands/fixed fmt classes, and a whole float
  # >= 1e6 (C7, the scientific-notation lock) — PLUS row 9 exercising two more
  # error codes so the TUI's error rendering is pinned.
  #
  # Engine error vocabulary is `Engine.error_values/0`
  #   = #CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM! #SPILL! #NAME?
  # (#NUM! IS in the vocabulary as of #843 — the domain-error code; #NAME? as of
  # the unsupported-function ruling; reconciled from engine.ex @error_values).
  # Row 9 stores #N/A (A9, =NA()) and #VALUE! (B9).
  # Row 10 stores a SPARKLINE cell (E10, t "s") — a unicode block-bar string that
  # every surface must render verbatim; it's the in-cell-sparkline parity lock.
  # The snapshot never validates a stored error string against this list — it just
  # renders the cell's "v" verbatim — so the fixture is stable across engine
  # vocabulary bumps; the list is documented here (and in the JSON `_comment`) so a
  # cold reader knows which codes are legal.
  #
  # Coverage extensions (w16-3 — shapes that shipped BEFORE the lock covered them):
  #   D1  fmt-carrying FROZEN-HEAD cell (percent) — the head band must show the
  #       formatted "50.00%", not the raw 0.5 (locks the frozen-head-fmt class
  #       at the generator, not just in unit tests).
  #   B7  datetime fmt on an ISO string -> "2026-06-12 08:30:00".
  #   D2  checkbox fmt on a boolean — display-only class, still snapshots "TRUE".
  #   D4  a NOTE-carrying cell ("NOTE-LEAK-CANARY") — the note must NEVER leak
  #       into the snapshot/expected (refuted in golden_parity_fixture_test.exs).
  #   Row 11 the remaining error codes: A11 #NUM! (=SQRT(-1)), B11 #REF!,
  #       C11 #CYCLE! — error_refs grows 3 -> 6, all six engine codes now pinned.
  #   A12 a 60-char string — the long-cell width/truncation-interaction probe.
  #   Row 19 the #NAME? arm of the unsupported-function ruling: B19 is a TYPED
  #       formula naming a function the engine does not implement, with NOTHING
  #       cached to fall back on, so the engine writes #NAME? (t "e"). Every
  #       surface must render it as an error cell, not a blank behind a dot.
  #       error_refs grows 6 -> 7 — the ONE case here that is a `t: "e"` cell,
  #       so it moves the exactly-asserted error_refs lock. (The OTHER arm — an
  #       import that KEEPS its cached value — is B6, already here.) ADDITIVE
  #       only: columns A..E, no existing case touched, outside every
  #       cond_format range. Row 19 and not 13: rows 13-15 are the
  #       everyday-function batch (#15338) and rows 16-18 are reserved by the
  #       open financial-functions PR (#15413).
  #
  # DO NOT add a hyperlink cell here — #882 owns the hyperlink parity lock and
  # will extend this generator itself.
  #
  # Conditional-formatting coverage (CF-E, arc 2 — pins the CF snapshot weave in
  # the committed fixture itself, so every mirror carries composed CF styles):
  #   cf-gt      numeric `gt 1000` on B2:B10 → matches B2 (1200) and B8 (1234.5),
  #              NOT B10 (1, below) nor the non-numeric B cells (CF-D5). The
  #              matched cells earn a CF-only styles entry (no manual "s").
  #   cf-overlap `gt 100` on B2:C8 OVERLAPS cf-gt on B2/B8 — first-match-wins
  #              (CF-D4) keeps those red; the rule independently paints C7 (1e6)
  #              green, proving the lower-priority rule is still live.
  #   cf-compose `contains "ote"` on A4 (the b/i/bg/al=right manual cell) — CF
  #              wins `bg` (#123456) while the manual `al`/`b`/`i` survive (CF-D3
  #              per-key compose over a manually-styled cell).
  #   cf-head    `contains "Q"` on A1:D1 covers the FROZEN head row — B1/C1 match
  #              at eval, but the snapshot drops head-row CF (CF-D3/CF-AM2), so
  #              the styles map carries NO entry for any head cell.
  # All four rules are CF-B-gate-valid (#rrggbb bg, whitelisted ops, unique ids,
  # in-bounds ranges) so this fixture is a legitimately storable sheet.
  @content %{
    "tabs" => [
      %{
        "name" => "Data",
        "frozen_rows" => 1,
        "frozen_cols" => 1,
        "col_widths" => %{"1" => 120, "2" => 64},
        "row_heights" => %{"2" => 40},
        "merges" => ["B3:C3", "B4:C5"],
        "cond_formats" => [
          %{
            "id" => "cf-gt",
            "range" => "B2:B10",
            "when" => %{"op" => "gt", "value" => 1000},
            "style" => %{"bg" => "#ff0000"}
          },
          %{
            "id" => "cf-overlap",
            "range" => "B2:C8",
            "when" => %{"op" => "gt", "value" => 100},
            "style" => %{"bg" => "#00ff00"}
          },
          %{
            "id" => "cf-compose",
            "range" => "A4",
            "when" => %{"op" => "contains", "value" => "ote"},
            "style" => %{"bg" => "#123456"}
          },
          %{
            "id" => "cf-head",
            "range" => "A1:D1",
            "when" => %{"op" => "contains", "value" => "Q"},
            "style" => %{"bg" => "#abcdef"}
          }
        ],
        "cells" => %{
          "A1" => %{"v" => "Metric"},
          "B1" => %{"v" => "Q3"},
          "C1" => %{"v" => "Q4"},
          # Frozen-head cell WITH a fmt — the head band goes through the same
          # display_value/Fmt.display seam as the body, so it must read "50.00%".
          "D1" => %{"v" => 0.5, "t" => "n", "fmt" => "percent"},
          "A2" => %{"v" => "Revenue", "s" => %{"b" => true}},
          "B2" => %{"v" => 1200, "t" => "n", "fmt" => "thousands"},
          "C2" => %{"v" => 3.5, "t" => "n", "fmt" => "fixed", "s" => %{"i" => true}},
          # checkbox is the display-only fmt class — snapshots as plain "TRUE".
          "D2" => %{"v" => true, "t" => "b", "fmt" => "checkbox"},
          "A3" => %{"v" => "Active?", "s" => %{"bg" => "#ffee00"}},
          "B3" => %{"v" => true, "t" => "b", "s" => %{"al" => "center"}},
          "A4" => %{
            "v" => "Note",
            "s" => %{"b" => true, "i" => true, "bg" => "#e0f0ff", "al" => "right"}
          },
          "B4" => %{"v" => "spans"},
          # Note-leak canary: the "note" key must NEVER reach the snapshot or
          # the expected values (refuted in golden_parity_fixture_test.exs).
          "D4" => %{"v" => "has note", "note" => "NOTE-LEAK-CANARY"},
          "A5" => %{"f" => "=B2*2", "v" => 2400, "t" => "n"},
          "A6" => %{"f" => "=1/0", "v" => "#DIV/0!", "t" => "e"},
          "B6" => %{"v" => "old", "stale" => true},
          "C6" => %{"v" => false, "t" => "b"},
          "A7" => %{"v" => "2026-06-12", "t" => "date", "fmt" => "date"},
          "B7" => %{"v" => "2026-06-12T08:30:00", "t" => "date", "fmt" => "datetime"},
          "C7" => %{"v" => 1_000_000.0, "t" => "n"},
          "A8" => %{"v" => 0.25, "t" => "n", "fmt" => "percent"},
          "B8" => %{"v" => 1234.5, "t" => "n", "fmt" => "currency"},
          "A9" => %{"f" => "=NA()", "v" => "#N/A", "t" => "e"},
          "B9" => %{"v" => "#VALUE!", "t" => "e"},
          # Row 10 locks a SPARKLINE cell — a unicode block-bar string (t "s")
          # that must survive every surface (walk.ex html, Go pdrender) unmangled.
          # v is the real Engine output of =SPARKLINE(B10:D10) over [1, 5, 9].
          "A10" => %{"v" => "Trend", "s" => %{"b" => true}},
          "B10" => %{"v" => 1, "t" => "n"},
          "C10" => %{"v" => 5, "t" => "n"},
          "D10" => %{"v" => 9, "t" => "n"},
          "E10" => %{"f" => "=SPARKLINE(B10:D10)", "v" => "▁▅█", "t" => "s"},
          # Row 11 pins the three error codes rows 6/9 don't cover — with these,
          # all six Engine.error_values/0 codes are locked (error_refs = 6).
          "A11" => %{"f" => "=SQRT(-1)", "v" => "#NUM!", "t" => "e"},
          "B11" => %{"v" => "#REF!", "t" => "e"},
          "C11" => %{"v" => "#CYCLE!", "t" => "e"},
          # A 60-char string — long-cell probe (width math / truncation seams).
          "A12" => %{"v" => "sixty-character-wide-cell-padding-parity-lock-XYZ-0123456789"},
          # Rows 13-15 — the everyday-function batch (TRANSPOSE / CONCAT /
          # SUBTOTAL / HSTACK / VSTACK, plus SEQUENCE's 2-D arity). Each `v` is
          # the REAL Engine output for its `f`, so every surface renders a value
          # the engine can actually produce. Deliberate constraints, so the
          # additions can never disturb a pre-existing case:
          #   * columns A..E only — the grid stays 5 wide, so every existing
          #     row array is byte-identical after the regen;
          #   * NO cell of type "e" — `error_refs` is asserted EXACTLY (six
          #     entries) in golden_parity_fixture_test.exs, so an error cell here
          #     would red a lock that has nothing to do with this batch;
          #   * rows 13+ sit outside every cond_format range (cf-gt B2:B10,
          #     cf-overlap B2:C8, cf-compose A4, cf-head A1:D1), so the composed
          #     `styles` map is unchanged.
          # A13 is CONCAT over a RANGE — the single thing CONCATENATE refuses.
          "A13" => %{"f" => "=CONCAT(B10:D10)", "v" => "159", "t" => "s"},
          # B13/C13 pin the DOCUMENTED SUBTOTAL gap in the fixture itself: code
          # 9 and code 109 must render the SAME 15, because this engine has no
          # row-visibility input to make the 101-band skip hidden rows.
          "B13" => %{"f" => "=SUBTOTAL(9, B10:D10)", "v" => 15, "t" => "n"},
          "C13" => %{"f" => "=SUBTOTAL(109, B10:D10)", "v" => 15, "t" => "n"},
          # D13 vs E13: TRANSPOSE really flips (1;3;2;4) where VSTACK of the same
          # two rows preserves reading order (1;2;3;4) — the pair is the lock.
          "D13" => %{
            "f" => "=TEXTJOIN(\";\", 0, TRANSPOSE(A14:B15))",
            "v" => "1;3;2;4",
            "t" => "s"
          },
          "E13" => %{
            "f" => "=TEXTJOIN(\";\", 0, VSTACK(A14:B14, A15:B15))",
            "v" => "1;2;3;4",
            "t" => "s"
          },
          # The 2x2 source the three array cases above and C14 below read.
          "A14" => %{"v" => 1, "t" => "n"},
          "B14" => %{"v" => 2, "t" => "n"},
          "C14" => %{"f" => "=SUM(HSTACK(A14:A15, B14:B15))", "v" => 10, "t" => "n"},
          "D14" => %{
            "f" => "=TEXTJOIN(\";\", 0, SEQUENCE(2, 3))",
            "v" => "1;2;3;4;5;6",
            "t" => "s"
          },
          "A15" => %{"v" => 3, "t" => "n"},
          "B15" => %{"v" => 4, "t" => "n"},
          # Row 19 — the #NAME? lock (the unsupported-function ruling). A TYPED
          # unknown function with NOTHING cached has nothing honest to show, so
          # it IS an error cell, not a blank behind a quiet stale dot. Same
          # additive constraints as rows 13-15 above (columns A..E, outside every
          # cond_format range) with ONE deliberate difference: this case IS a
          # `t: "e"` cell, and it bumps the exactly-asserted `error_refs` lock in
          # golden_parity_fixture_test.exs from six entries to seven. Row 19
          # because rows 13-15 are the everyday-function batch and rows 16-18 are
          # reserved by the open financial-functions PR (#15413).
          # (The OTHER arm of the ruling — an import that KEEPS its cached value
          # — is B6, already here.)
          "A19" => %{"v" => "Unsupported"},
          "B19" => %{"f" => "=FOO(B10)", "v" => "#NAME?", "t" => "e"}
        }
      },
      %{"name" => "Extra", "cells" => %{"A1" => %{"v" => "tab2"}}}
    ]
  }

  @comment "Generated by `mix barkpark.sheets.gen_golden_parity` — DO NOT hand-edit. " <>
             "Cross-surface golden parity lock (api tests + web SDK + internal/pdrender). " <>
             "Engine error vocabulary is Engine.error_values/0 = " <>
             "#CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM! #SPILL! #NAME? " <>
             "(#NUM! IS present as of #843; #NAME? as of the unsupported-function ruling)."

  @api_path Path.expand("../../../test/support/fixtures/sheet-golden-parity.json", __DIR__)
  @web_path Path.expand("../../../../web/__tests__/fixtures/sheet-golden-parity.json", __DIR__)
  @go_path Path.expand("../../../../internal/pdrender/testdata/sheet-golden-parity.json", __DIR__)

  @doc "The three mirror paths the fixture is written to (also read by the freshness test)."
  def mirror_paths, do: [@api_path, @web_path, @go_path]

  @impl Mix.Task
  def run(_args) do
    json = Jason.encode!(build(), pretty: true) <> "\n"

    for path <- mirror_paths() do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json)
      Mix.shell().info("wrote #{path}")
    end

    Mix.shell().info("gen_golden_parity: 3 mirror(s) written — re-verify all five surfaces.")
  end

  @doc """
  Build the golden fixture data map (pure — `Core.snapshot_for/2` +
  `Core.snapshot_schema_version/0` + `Fmt.vocabulary/0`; no app boot). The
  freshness test regenerates through this and asserts term-equality with the
  committed api mirror.

  Every term is JSON-safe (string keys, lists not tuples) so a Jason encode →
  decode round-trip is the identity, and `build/0 == Jason.decode!(committed)`.
  """
  def build do
    snapshot = Core.snapshot_for(@content, 0)

    %{
      "_comment" => @comment,
      "sv" => Core.snapshot_schema_version(),
      "content" => @content,
      "snapshot" => snapshot,
      "expected" => expected_from_snapshot(snapshot),
      "head" => Map.get(snapshot, "head", []),
      "spans" => spans_from_content(@content),
      "right_aligned" => refs_with_type(@content, "n"),
      "error_refs" => refs_with_type(@content, "e"),
      "fmt_vocabulary" => Fmt.vocabulary()
    }
  end

  # ── derivations (from the REAL snapshot / content, never hand-typed) ──────────

  # Every shown value by A1 ref, read straight off the dense snapshot the renderer
  # consumes (head is row 1, rows start at row 2 when a head is present). Empty
  # (merge-covered / blank) cells are dropped — surfaces need only the shown set.
  defp expected_from_snapshot(snapshot) do
    head = Map.get(snapshot, "head")
    rows = Map.get(snapshot, "rows", [])

    head_pairs =
      case head do
        list when is_list(list) ->
          list |> Enum.with_index(1) |> Enum.map(fn {v, c} -> {ref(c, 1), v} end)

        _ ->
          []
      end

    data_start = if is_list(head), do: 2, else: 1

    row_pairs =
      rows
      |> Enum.with_index(data_start)
      |> Enum.flat_map(fn {row, r} ->
        row |> Enum.with_index(1) |> Enum.map(fn {v, c} -> {ref(c, r), v} end)
      end)

    (head_pairs ++ row_pairs)
    |> Enum.reject(fn {_ref, v} -> v == "" or is_nil(v) end)
    |> Map.new()
  end

  # Merge anchors -> [colspan, rowspan], parsed from the content's merge ranges.
  defp spans_from_content(content) do
    case get_in(content, ["tabs", Access.at(0), "merges"]) do
      merges when is_list(merges) ->
        Map.new(merges, fn range ->
          [a, b] = String.split(range, ":")
          {ac, ar} = parse_ref(a)
          {bc, br} = parse_ref(b)
          {a, [bc - ac + 1, br - ar + 1]}
        end)

      _ ->
        %{}
    end
  end

  # Sorted A1 refs of tab-0 cells carrying the given `"t"` type marker.
  defp refs_with_type(content, type) do
    case get_in(content, ["tabs", Access.at(0), "cells"]) do
      cells when is_map(cells) ->
        cells
        |> Enum.filter(fn {_ref, cell} -> Map.get(cell, "t") == type end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      _ ->
        []
    end
  end

  # ── A1 helpers (self-contained; Core's parse_ref is private) ──────────────────
  defp ref(col, row), do: col_letters(col) <> Integer.to_string(row)

  defp col_letters(col) when col >= 1, do: do_letters(col, [])
  defp do_letters(0, acc), do: List.to_string(acc)

  defp do_letters(n, acc) do
    rem = Integer.mod(n - 1, 26)
    do_letters(div(n - 1, 26), [rem + ?A | acc])
  end

  defp parse_ref(cell_ref) do
    {letters, digits} =
      cell_ref |> String.to_charlist() |> Enum.split_while(&(&1 in ?A..?Z))

    {letters_to_col(letters), digits |> List.to_string() |> String.to_integer()}
  end

  defp letters_to_col(letters) do
    Enum.reduce(letters, 0, fn ch, acc -> acc * 26 + (ch - ?A + 1) end)
  end
end
