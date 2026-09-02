defmodule Barkpark.Tasks.BoardThemeParityTest do
  @moduledoc """
  Cross-surface glyph parity gate (charter D17).

  The GUI board (`Barkpark.Tasks.Board.glyphs/0`) and the terminal TUI
  (`internal/taskboard/` `StatusGlyph`) each carry the §1 white-ladder glyphs
  (`.claude/workflows/bp-task-design-language-spec.md`) — the anti-drift risk
  the wish's "same icons as TUI precisely" forbids. Since #1394 the TUI side is
  the GENERATED `GenLifecycle` table in `tokens_gen.go` (emitted from
  `design/tokens.json`), consumed by `StatusGlyph`. This test parses that table
  into a `{lifecycle => glyph}` map and asserts it is codepoint-EQUAL to
  `Board.glyphs/0` for the shared lifecycle keys, so a restyle on EITHER
  surface fails the build. A hard-coded expected map is the triple-check: a
  dropped lifecycle fails loudly, not silently.

  Pure string/regex parsing — no `ConnCase`, no DB. The Go TUI is READ-ONLY
  here; the fix for any failure is to re-align a glyph, never to edit this test.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Board

  # The mix root is `api/`; the Go TUI lives one level up. The glyph table and
  # braille frames moved from hand-tuned literals (components.go switch +
  # spinner.go array) to the generated tokens_gen.go (#1394).
  @components_go "../internal/taskboard/components.go"
  @tokens_gen_go "../internal/taskboard/tokens_gen.go"

  # The lifecycle keys BOTH surfaces speak. The board folds `cancelled` to a
  # tally (no rendered column), but the glyph is still shared truth — the glyph
  # is shared, its placement isn't (D17).
  @shared_keys ~w(open ready in_progress blocked done cancelled considering researching)

  # The GUI's own fail-open mark (tlv-s5): `unknown` is NOT a stored lifecycle
  # state and has no `GenLifecycle` row, so it is deliberately OUT of
  # @shared_keys — it exists only so `Board.glyph_for/1` is total. It IS in
  # @expected below, because that map is a full-equality witness over
  # `Board.glyphs/0`; if a future emitter ever grows an `unknown` lifecycle,
  # this comment is where the two lists reconcile.
  @gui_only_keys ~w(unknown)

  # The §1 manifest, hard-coded as an independent third witness so a silent
  # drift on EITHER side (the Board map OR the generated Go table) trips this
  # gate.
  @expected %{
    "open" => "○",
    "ready" => "○",
    "in_progress" => "⠋",
    "blocked" => "!",
    "done" => "✓",
    "cancelled" => "✕",
    "considering" => "◌",
    "researching" => "◎",
    "unknown" => "·"
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

    test "the GUI-only fail-open mark is absent from the generated TUI table" do
      # The complement of the parity assertions above: `unknown` must NOT sneak
      # into the shared vocabulary. If someone adds it to design/tokens.json
      # this reds, and the fix is to decide deliberately — not to widen
      # @shared_keys until the gate stops discriminating.
      tui = parse_status_glyphs()

      for key <- @gui_only_keys do
        refute Map.has_key?(tui, key),
               "#{key} is the GUI's fail-open mark, not a lifecycle state — " <>
                 "it must not appear in the generated GenLifecycle table"

        assert Map.has_key?(Board.glyphs(), @lifecycle_atom[key]),
               "#{key} must still exist in Board.glyphs/0 — glyph_for/1 falls back to it"
      end
    end

    test "in_progress's steady glyph is the first braille spinner frame" do
      # `StatusGlyph("in_progress")` shows the steady ⠋ while the board
      # animates GenBrailleFrames — frame 0 IS the steady glyph, kept
      # codepoint-equal so reduced-motion and animated renders agree.
      assert Enum.at(braille_frames(), 0) == Map.fetch!(parse_status_glyphs(), "in_progress")
    end
  end

  # ── the parser ─────────────────────────────────────────────────────────────

  # Parse the generated `GenLifecycle` map literal in `tokens_gen.go` into
  # `%{lifecycle => glyph}`. Guarded by a check that `StatusGlyph` in
  # `components.go` actually consumes `GenLifecycle`, so this parity stays
  # wired to the real render path — if the lookup moves again, this flunks
  # loudly instead of silently validating a dead table.
  defp parse_status_glyphs do
    status_glyph_consumes_gen_lifecycle!()

    body =
      case Regex.run(
             ~r/GenLifecycle\s*=\s*map\[string\]GenLifecycleToken\{(.*?)\n\}/s,
             File.read!(@tokens_gen_go)
           ) do
        [_, inner] -> inner
        _ -> flunk("could not locate the GenLifecycle map in #{@tokens_gen_go}")
      end

    ~r/"([a-z_]+)":\s*\{Glyph:\s*"([^"]*)"/
    |> Regex.scan(body)
    |> Map.new(fn [_, key, glyph] -> {key, glyph} end)
  end

  defp status_glyph_consumes_gen_lifecycle! do
    fn_body =
      case Regex.run(
             ~r/func StatusGlyph\([^)]*\)\s*string\s*\{(.*?)\n\}/s,
             File.read!(@components_go)
           ) do
        [_, body] -> body
        _ -> flunk("could not locate func StatusGlyph in #{@components_go}")
      end

    unless fn_body =~ "GenLifecycle[lifecycle]" do
      flunk(
        "StatusGlyph in #{@components_go} no longer reads GenLifecycle[lifecycle] — " <>
          "re-point this parity test at the new glyph source"
      )
    end
  end

  # Read the `GenBrailleFrames` array literal from `tokens_gen.go` so frame 0
  # resolves to the real codepoint (⠋), not a hard-coded assumption.
  defp braille_frames do
    arr =
      case Regex.run(
             ~r/GenBrailleFrames\s*=\s*\[\d+\]string\{([^}]*)\}/,
             File.read!(@tokens_gen_go)
           ) do
        [_, inner] -> inner
        _ -> flunk("could not locate the GenBrailleFrames array in #{@tokens_gen_go}")
      end

    ~r/"([^"]*)"/
    |> Regex.scan(arr)
    |> Enum.map(fn [_, g] -> g end)
  end
end
