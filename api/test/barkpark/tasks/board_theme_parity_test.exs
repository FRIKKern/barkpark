defmodule Barkpark.Tasks.BoardThemeParityTest do
  @moduledoc """
  Cross-surface glyph parity gate (charter D17).

  The GUI board (`Barkpark.Tasks.Board.glyphs/0`) and the terminal TUI
  (`internal/taskboard` `StatusGlyph`, sourced from the generated
  `GenLifecycle` table) speak the §1 white-ladder glyphs
  (`.claude/workflows/bp-task-design-language-spec.md`) — the anti-drift risk
  the wish's "same icons as TUI precisely" forbids. This test parses the Go
  TUI's generated glyph table (`internal/taskboard/tokens_gen.go`'s
  `GenLifecycle` map + `GenBrailleFrames` array, emitted from
  `design/tokens.json`) into a `{lifecycle => glyph}` map and asserts it is
  codepoint-EQUAL to `Board.glyphs/0` for the shared lifecycle keys, so a
  restyle on EITHER surface fails the build. A hard-coded expected map is the
  triple-check: a dropped glyph fails loudly, not silently.

  Pure string/regex parsing — no `ConnCase`, no DB. The Go TUI is READ-ONLY
  here; the fix for any failure is to re-align a glyph, never to edit this test.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Board

  # The mix root is `api/`; the Go TUI lives one level up. The TUI's glyph truth
  # is the GENERATED `GenLifecycle` map + `GenBrailleFrames` array in
  # `tokens_gen.go` (emitted from `design/tokens.json` via `design/emit.mjs`).
  # #1394 ("consume generated lifecycle tokens, delete hand-tuned twin") moved
  # both here from the retired hand-tuned twins — the `StatusGlyph` `switch
  # lifecycle` in `components.go` and the inline `brailleFrames` literal in
  # `spinner.go`. Read the generated single source, not the retired locations.
  @tokens_gen_go "../internal/taskboard/tokens_gen.go"

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

  # Parse the Go TUI's glyph table into `%{lifecycle => glyph}`. Since #1394
  # ("consume generated lifecycle tokens, delete hand-tuned twin") `StatusGlyph`
  # is a `GenLifecycle[lifecycle].Glyph` lookup against the GENERATED
  # `tokens_gen.go` map (emitted from `design/tokens.json`) — the hand-authored
  # `switch lifecycle` this used to parse in `components.go` is retired. So the
  # parity now reads from the same generated single source the TUI itself paints
  # from: a `"key": {Glyph: "x"…}` entry binds each lifecycle to its glyph.
  #
  # `in_progress`'s steady glyph is resolved from `GenBrailleFrames[0]` (the
  # animation's frame-0 codepoint), exactly as the retired switch's
  # `brailleFrames[0]` return did — so the braille array stays the genuine,
  # codepoint-driven source for in_progress, not a hard-coded assumption.
  defp parse_status_glyphs do
    braille = braille_frames()
    block = gen_lifecycle_block(File.read!(@tokens_gen_go))

    ~r/"([^"]+)":\s*\{\s*Glyph:\s*"([^"]*)"/
    |> Regex.scan(block)
    |> Map.new(fn [_, key, glyph] -> {key, glyph} end)
    |> Map.put("in_progress", Enum.at(braille, 0))
  end

  # Isolate the `var GenLifecycle = map[…]{ … }` literal so the neighbouring
  # `GenLifecycleToken` struct and `GenLifecycleOrder` slice never leak into the
  # scan.
  defp gen_lifecycle_block(source) do
    case Regex.run(~r/var GenLifecycle = map\[string\]GenLifecycleToken\{(.*?)\n\}/s, source) do
      [_, block] -> block
      _ -> flunk("could not locate the `GenLifecycle` map in #{@tokens_gen_go}")
    end
  end

  # Read the braille frames array literal so `brailleFrames[0]` resolves to the
  # real codepoint (⠋), not a hard-coded assumption. The frames are GENERATED
  # into `tokens_gen.go` as `GenBrailleFrames` (emitted from `design/tokens.json`),
  # moved there by #1394 ("consume generated lifecycle tokens, delete hand-tuned
  # twin") from the now-retired inline `brailleFrames` literal in `spinner.go`.
  # We read the generated single source so a future move re-points cleanly.
  defp braille_frames do
    arr =
      case Regex.run(~r/GenBrailleFrames\s*=\s*\[\d+\]string\{([^}]*)\}/, File.read!(@tokens_gen_go)) do
        [_, inner] -> inner
        _ -> flunk("could not locate the GenBrailleFrames array in #{@tokens_gen_go}")
      end

    ~r/"([^"]*)"/
    |> Regex.scan(arr)
    |> Enum.map(fn [_, g] -> g end)
  end
end
