defmodule Barkpark.Tasks.BoardThemeParityTest do
  @moduledoc """
  Cross-surface glyph parity gate (charter D17).

  The GUI board (`Barkpark.Tasks.Board.glyphs/0`) and the terminal TUI
  (`internal/taskboard/components.go` `StatusGlyph`) each hard-code the §1
  white-ladder glyphs (`.claude/workflows/bp-task-design-language-spec.md`) —
  the anti-drift risk the wish's "same icons as TUI precisely" forbids. This
  test parses the Go source's `StatusGlyph` switch into a `{lifecycle => glyph}`
  map and asserts it is codepoint-EQUAL to `Board.glyphs/0` for the shared
  lifecycle keys, so a restyle on EITHER surface fails the build. A hard-coded
  expected map is the triple-check: a Go `case` drop fails loudly, not silently.

  Pure string/regex parsing — no `ConnCase`, no DB. The Go TUI is READ-ONLY
  here; the fix for any failure is to re-align a glyph, never to edit this test.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Board

  # The mix root is `api/`; the Go TUI lives one level up.
  @components_go "../internal/taskboard/components.go"
  @spinner_go "../internal/taskboard/spinner.go"

  # The lifecycle keys BOTH surfaces speak. The board folds `cancelled` to a
  # tally (no rendered column), but the glyph is still shared truth — the glyph
  # is shared, its placement isn't (D17).
  @shared_keys ~w(open ready in_progress blocked done cancelled)

  # The §1 manifest, hard-coded as an independent third witness so a silent
  # drift on EITHER side (the Board map OR the Go switch) trips this gate.
  @expected %{
    "open" => "○",
    "ready" => "○",
    "in_progress" => "⠋",
    "blocked" => "!",
    "done" => "✓",
    "cancelled" => "✕"
  }

  # Canonical string→atom map for the lifecycle keys, folded at COMPILE time
  # from the app's own source of truth — `Board.glyphs/0`'s atom keys.
  #
  # WHY this exists (do not revert to `String.to_existing_atom/1` on a raw
  # string): `to_existing_atom/1` raises `ArgumentError` when its atom is not
  # yet in the atom table, and under `async: true` interning is LOAD-ORDER
  # DEPENDENT. If this test happened to run before any module that references
  # e.g. `:in_progress` had loaded, the atom was absent and the conversion
  # raised — a ~1-in-8000, seed-dependent flake that still passed 186/0 in
  # isolation. Folding `Board.glyphs/0` here embeds every lifecycle atom as a
  # literal in this module, so they are interned the instant it loads (long
  # before any test runs), regardless of order. The witness stays honest: each
  # atom is a REAL app atom sourced from `Board`, and an unknown key resolves
  # to `nil` (never a fabricated atom), so drift still fails loudly.
  @lifecycle_atom Map.new(Board.glyphs(), fn {atom, _glyph} -> {Atom.to_string(atom), atom} end)

  describe "GUI ↔ TUI glyph parity (charter D17)" do
    test "Board.glyphs/0 matches the §1 manifest exactly" do
      expected_atoms = Map.new(@expected, fn {k, v} -> {@lifecycle_atom[k], v} end)
      assert Board.glyphs() == expected_atoms
    end

    test "the TUI StatusGlyph switch matches the §1 manifest for every shared key" do
      tui = parse_status_glyphs()

      for key <- @shared_keys do
        assert Map.fetch!(tui, key) == @expected[key],
               "TUI StatusGlyph for #{key} drifted from the §1 manifest"
      end
    end

    test "Board.glyphs/0 is codepoint-equal to the TUI StatusGlyph table" do
      tui = parse_status_glyphs()
      board = Board.glyphs()

      for key <- @shared_keys do
        atom = @lifecycle_atom[key]

        assert Map.fetch!(tui, key) == Map.fetch!(board, atom),
               "GUI/TUI glyph drift on #{key}: TUI=#{inspect(Map.get(tui, key))} " <>
                 "GUI=#{inspect(Map.get(board, atom))}"
      end
    end
  end

  # ── the parser ─────────────────────────────────────────────────────────────

  # Parse `components.go`'s `StatusGlyph` switch into `%{lifecycle => glyph}`. A
  # `case "a", "b":` line binds every listed lifecycle to the following `return`
  # glyph. `in_progress` returns `brailleFrames[0]`, resolved against the array
  # in `spinner.go` so the parity is genuinely codepoint-driven, not a comment
  # read.
  defp parse_status_glyphs do
    braille = braille_frames()
    body = status_glyph_body(File.read!(@components_go))

    ~r/case\s+([^:\n]+):\s*\n\s*return\s+([^\n]+)/
    |> Regex.scan(body)
    |> Enum.flat_map(fn [_, labels, ret] ->
      case resolve_glyph(ret, braille) do
        nil -> []
        glyph -> for l <- parse_labels(labels), do: {l, glyph}
      end
    end)
    |> Map.new()
  end

  # Isolate the StatusGlyph function's `switch lifecycle { ... }` body so the
  # `asciiMode()` branch and neighbouring functions never leak into the scan.
  defp status_glyph_body(source) do
    fn_body =
      case Regex.run(~r/func StatusGlyph\([^)]*\)\s*string\s*\{(.*?)\n\}/s, source) do
        [_, body] -> body
        _ -> flunk("could not locate func StatusGlyph in #{@components_go}")
      end

    case Regex.run(~r/switch\s+lifecycle\s*\{(.*)\}/s, fn_body) do
      [_, switch_body] -> switch_body
      _ -> flunk("could not locate the `switch lifecycle` block in StatusGlyph")
    end
  end

  # `"in_progress", "blocked"` → ["in_progress", "blocked"].
  defp parse_labels(labels) do
    ~r/"([^"]*)"/
    |> Regex.scan(labels)
    |> Enum.map(fn [_, l] -> l end)
  end

  # A return expression → its glyph: a quoted literal, or `brailleFrames[n]`.
  defp resolve_glyph(ret, braille) do
    ret = String.trim(ret)

    cond do
      match = Regex.run(~r/^"([^"]*)"/, ret) ->
        Enum.at(match, 1)

      match = Regex.run(~r/brailleFrames\[(\d+)\]/, ret) ->
        Enum.at(braille, String.to_integer(Enum.at(match, 1)))

      true ->
        nil
    end
  end

  # Read the `brailleFrames` array literal from `spinner.go` so `brailleFrames[0]`
  # resolves to the real codepoint (⠋), not a hard-coded assumption.
  defp braille_frames do
    arr =
      case Regex.run(~r/brailleFrames\s*=\s*\[\d+\]string\{([^}]*)\}/, File.read!(@spinner_go)) do
        [_, inner] -> inner
        _ -> flunk("could not locate the brailleFrames array in #{@spinner_go}")
      end

    ~r/"([^"]*)"/
    |> Regex.scan(arr)
    |> Enum.map(fn [_, g] -> g end)
  end
end
