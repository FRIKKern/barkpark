defmodule Barkpark.Content.Papers.ClearBlocksPredicateParityTest do
  @moduledoc """
  THE ANTI-RE-INLINE TRIPWIRE for the `clear_blocks` opt-in.

  ## What it guards

  "Did the caller explicitly ask to drop the canonical blocks?" is read at TWO
  points on ONE request: `Barkpark.Content.Papers.MixedWriteGuard.check/1`
  decides whether the ingest 422 fires, and
  `Barkpark.Content.Papers.BlockOps.put_or_clear_blocks/3` decides whether the
  blocks are actually dropped. If those two ever disagree, a POST carrying the
  disputed value passes the guard WITHOUT a refusal while the write declines to
  clear: the verbatim `body_html` lands on a still-blocks-backed row, answers
  200, and is discarded by the next read — exactly the hazard the refusal slice
  exists to close, restored behind a success receipt.

  That is not hypothetical. The two readers WERE two hand-written copies, and
  the divergence was invisible: narrowing the BlockOps side alone to `[true]`
  compiled and ran 672 tests with 0 failures.

  ## Why this file is not tautological today — do NOT delete it as dead weight

  Both names currently resolve to ONE function (`MixedWriteGuard` delegates to
  `BlockOps`), so the parity half of this test cannot fail against the CURRENT
  shape. That is the point: it is dormant against the fix and fires on the
  REGRESSION, which is someone re-inlining a second copy.

  The two modules now share a namespace — both are `Content.Papers.*` since the
  guard moved out of `Plugins.Bulldocs` to keep host code off a removable
  plugin — and that changes nothing here. What this file pins is that two
  CALLABLE NAMES agree; which namespace they sit in is irrelevant to a
  re-inline, and both mutation arms below still fire.

    * Re-inline as a PRIVATE copy and drop the delegate → this file stops
      compiling, because `MixedWriteGuard.clear_blocks?/1` is no longer callable
      by name. A build break is a louder tripwire than a red test.
    * Re-inline behind a public wrapper that diverges → the table reds, naming
      the value the two now disagree about.

  Either way the re-inline cannot land silently, which is what happened the
  first time.

  The parity assertion alone would be a blind spot: two copies can agree on a
  WRONG value. So every row also carries the intended absolute verdict — only
  `true` and the string `"true"` clear; every other spelling, the absent key
  included, does not.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.Content.Papers.MixedWriteGuard

  # {value, does it clear?} — the ABSOLUTE contract, not merely "they agree".
  @table [
    {true, true},
    {"true", true},
    {false, false},
    {"false", false},
    # the absent key: `attrs["clear_blocks"]` on a payload that never sent it
    {nil, false},
    {"", false},
    {1, false},
    {"1", false},
    # case matters — a destructive opt-in is not spelled loosely on purpose
    {"TRUE", false},
    {"True", false},
    {:true_atom_lookalike, false},
    {%{}, false},
    {[], false}
  ]

  describe "the two readers of clear_blocks agree, value by value" do
    for {value, expected} <- @table do
      test "#{inspect(value)} -> #{expected}, from BOTH the write and the guard" do
        value = unquote(Macro.escape(value))
        expected = unquote(expected)

        core = BlockOps.clear_blocks?(value)
        guard = MixedWriteGuard.clear_blocks?(value)

        assert core == expected,
               "BlockOps.clear_blocks?(#{inspect(value)}) returned #{inspect(core)}, " <>
                 "expected #{inspect(expected)} — the write side changed its mind about " <>
                 "a destructive opt-in"

        assert guard == expected,
               "MixedWriteGuard.clear_blocks?(#{inspect(value)}) returned #{inspect(guard)}, " <>
                 "expected #{inspect(expected)} — the ingest guard changed its mind about " <>
                 "a destructive opt-in"

        assert core == guard,
               "SPLIT BRAIN on #{inspect(value)}: the write says #{inspect(core)} and the " <>
                 "ingest guard says #{inspect(guard)}. A POST carrying this value now " <>
                 "passes one and not the other, so a verbatim body_html write lands on a " <>
                 "still-blocks-backed row behind a 200 and is discarded by the next read. " <>
                 "Restore the single shared predicate (BlockOps.clear_blocks?/1) instead of " <>
                 "keeping two copies."
      end
    end
  end

  test "the guard's predicate is the write's predicate, not a copy of it" do
    # Structural, not behavioural: same function identity, so no table of
    # values can ever separate them while this holds. `defdelegate` compiles to
    # a body that calls BlockOps, so a re-inlined local copy would break the
    # equality of results above even where this check still passes — both are
    # kept.
    Code.ensure_loaded!(MixedWriteGuard)
    Code.ensure_loaded!(BlockOps)

    assert function_exported?(MixedWriteGuard, :clear_blocks?, 1),
           "MixedWriteGuard.clear_blocks?/1 must stay PUBLIC. The delegate being public " <>
             "is what makes the cross-module parity check above expressible; privatising " <>
             "it silently disarms this file."

    assert function_exported?(BlockOps, :clear_blocks?, 1),
           "BlockOps.clear_blocks?/1 is the canonical predicate and must stay public — " <>
             "the ingest guard delegates to it."
  end
end
