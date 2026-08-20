defmodule BarkparkWeb.Studio.PaneBuilderInspectorTest do
  @moduledoc """
  The Tier-2 ladder's lock suite (spd-b39, charter D148/D151).

  Lives in its OWN file on purpose. `pane_builder_test.exs` holds both
  literal display-state tables — the 40-cell exhaustive table with its
  `map_size == 40` guard and the deep-stack table with `map_size == 6` —
  and D94(a) makes those the desk's geometry lock. Adding `display_state/5`
  must not cost that file a single byte, so nothing here is written there.

  Three obligations, in the order they defend each other:

    1. EQUIVALENCE — with the inspector CLOSED, `/5` is `/4` verbatim.
       Without this the call-site swap in `components.ex` satisfies D94(a)
       LITERALLY while hollowing out its purpose: the 40-cell table would
       still pass, but it would no longer describe what the desk renders.
    2. THE OPEN TABLE — an exhaustive LITERAL table for the inspector-OPEN
       dimension, with its own `map_size` guard, in the same idiom as the
       table it complements. Derived expectations are banned here for the
       reason D94 records: a test that computes its expectation from the
       function it guards moves with the regression and stays green.
    3. NON-VACUITY — proof that the open dimension actually DIVERGES. An
       equivalence suite plus a table that happens to equal `/4` everywhere
       would both be green on a `/5` that ignored its fifth argument.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.PaneBuilder

  @buckets ["wide", "standard", "narrow", "phone"]
  @editor_states [false, true]

  defp row(num_panes, fun) do
    for idx <- 0..(num_panes - 1), do: fun.(idx)
  end

  describe "inspector CLOSED is /4 verbatim (the D94(a) bridge)" do
    test "4 buckets x num_panes 1..8 x both editor states are cell-for-cell identical" do
      # 4 x 8 x 2 = 64 rows. The range reaches 8, not 5, so this bridge
      # covers the deep-stack table's territory too — the whole of what
      # `pane_builder_test.exs` pins, both tables, stays load-bearing for
      # the production call site after the swap.
      checked =
        for bucket <- @buckets,
            num_panes <- 1..8,
            has_editor? <- @editor_states do
          four = row(num_panes, &PaneBuilder.display_state(&1, num_panes, has_editor?, bucket))

          five =
            row(num_panes, &PaneBuilder.display_state(&1, num_panes, has_editor?, bucket, false))

          assert five == four, """
          display_state/5 with the inspector CLOSED diverged from /4.
          bucket=#{bucket} num_panes=#{num_panes} has_editor=#{has_editor?}
            /4 -> #{inspect(four)}
            /5 -> #{inspect(five)}
          The 40-cell table in pane_builder_test.exs no longer describes what \
          the desk renders at this cell. D94(a) is satisfied literally and \
          hollow.
          """

          1
        end

      # Non-vacuity guard on the bridge itself: an empty comprehension
      # would make every assertion above vacuously true.
      assert length(checked) == 64
    end

    test "the default-closed desk is unmoved: a socket that never summons is /4" do
      # The production call site passes `@sidebar_user_opened`, seeded false
      # in mount.ex. This is that path, spelled out as literals rather than
      # delegated, at the one bucket the ladder can move.
      assert row(2, &PaneBuilder.display_state(&1, 2, true, "standard", false)) ==
               [:strip, :full]

      assert row(3, &PaneBuilder.display_state(&1, 3, true, "standard", false)) ==
               [:strip, :strip, :full]

      assert row(3, &PaneBuilder.display_state(&1, 3, false, "standard", false)) ==
               [:strip, :full, :full]
    end
  end

  describe "display_state/5 — the inspector-OPEN table" do
    test "exhaustive literal table: 4 buckets x num_panes 1..5 x has_editor, inspector OPEN" do
      table = %{
        # ── wide: TIER 1 MOVES ZERO CELLS ────────────────────────────────
        # At 1280/1440 the inspector already docks with room to spare, so
        # summoning it buys nothing and would cost navigation. Verbatim /4.
        {"wide", 1, false} => [:full],
        {"wide", 2, false} => [:full, :full],
        {"wide", 3, false} => [:strip, :full, :full],
        {"wide", 4, false} => [:strip, :strip, :full, :full],
        {"wide", 5, false} => [:strip, :strip, :strip, :full, :full],
        {"wide", 1, true} => [:full],
        {"wide", 2, true} => [:strip, :full],
        {"wide", 3, true} => [:strip, :strip, :full],
        {"wide", 4, true} => [:strip, :strip, :strip, :full],
        {"wide", 5, true} => [:strip, :strip, :strip, :strip, :full],
        # ── standard, NO editor: no document, so no Document inspector ───
        # `inspector_open?` cannot be true in a way that renders here.
        # Delegation keeps the desk honest if it ever is.
        {"standard", 1, false} => [:full],
        {"standard", 2, false} => [:full, :full],
        {"standard", 3, false} => [:strip, :full, :full],
        {"standard", 4, false} => [:strip, :strip, :full, :full],
        {"standard", 5, false} => [:strip, :strip, :strip, :full, :full],
        # ── standard, editor open: THE LADDER. The only family that moves.
        # The nav rail yields entirely so the inspector docks IN FLOW: every
        # pane :hidden except the LAST, which survives as a 44px :strip back
        # affordance. Measured at viewport 1024 this takes
        # visible_pane_widths_px from [44, 260] to [44], so panel 720 -> 980,
        # surface border-box 680, gutter 80, content 600 — 60.00ch resolved
        # Iowan Old Style at 18px (10.0000 px/ch), 54.31ch forced Georgia
        # (11.0469 px/ch), 65.42ch forced Source Serif 4 (9.1719 px/ch).
        # Compare the /4 row above cell by cell: this is the divergence.
        {"standard", 1, true} => [:strip],
        {"standard", 2, true} => [:hidden, :strip],
        {"standard", 3, true} => [:hidden, :hidden, :strip],
        {"standard", 4, true} => [:hidden, :hidden, :hidden, :strip],
        {"standard", 5, true} => [:hidden, :hidden, :hidden, :hidden, :strip],
        # ── narrow, no editor: drill navigation, unchanged ───────────────
        {"narrow", 1, false} => [:full],
        {"narrow", 2, false} => [:strip, :full],
        {"narrow", 3, false} => [:strip, :strip, :full],
        {"narrow", 4, false} => [:strip, :strip, :strip, :full],
        {"narrow", 5, false} => [:strip, :strip, :strip, :strip, :full],
        # ── narrow, editor open: already this ladder's TERMINAL state ────
        # D35 got here first. There is nothing left for the rail to yield,
        # which is why the standard rows above are literally these rows.
        {"narrow", 1, true} => [:strip],
        {"narrow", 2, true} => [:hidden, :strip],
        {"narrow", 3, true} => [:hidden, :hidden, :strip],
        {"narrow", 4, true} => [:hidden, :hidden, :hidden, :strip],
        {"narrow", 5, true} => [:hidden, :hidden, :hidden, :hidden, :strip],
        # ── phone: the document already owns the viewport ────────────────
        {"phone", 1, false} => [:full],
        {"phone", 2, false} => [:hidden, :full],
        {"phone", 3, false} => [:hidden, :hidden, :full],
        {"phone", 4, false} => [:hidden, :hidden, :hidden, :full],
        {"phone", 5, false} => [:hidden, :hidden, :hidden, :hidden, :full],
        {"phone", 1, true} => [:hidden],
        {"phone", 2, true} => [:hidden, :hidden],
        {"phone", 3, true} => [:hidden, :hidden, :hidden],
        {"phone", 4, true} => [:hidden, :hidden, :hidden, :hidden],
        {"phone", 5, true} => [:hidden, :hidden, :hidden, :hidden, :hidden]
      }

      # Exhaustiveness guard — the table really covers 4 x 5 x 2, the same
      # shape and the same discipline as the /4 table's `map_size == 40`.
      assert map_size(table) == 40

      for {{bucket, num_panes, has_editor?}, expected} <- table do
        actual =
          row(num_panes, &PaneBuilder.display_state(&1, num_panes, has_editor?, bucket, true))

        assert actual == expected,
               "display_state/5 (inspector OPEN) mismatch: bucket=#{bucket} " <>
                 "num_panes=#{num_panes} has_editor=#{has_editor?} — " <>
                 "got #{inspect(actual)}, want #{inspect(expected)}"
      end
    end

    test "NON-VACUITY: standard + editor + inspector OPEN diverges from /4" do
      # Without this, a `/5` that ignored its fifth argument entirely would
      # pass the equivalence suite AND the table above, because every other
      # cell in that table is deliberately identical to /4. This is the one
      # assertion that can only be green if the ladder actually runs.
      diverging =
        for num_panes <- 1..5,
            four = row(num_panes, &PaneBuilder.display_state(&1, num_panes, true, "standard")),
            five =
              row(num_panes, &PaneBuilder.display_state(&1, num_panes, true, "standard", true)),
            five != four,
            do: {num_panes, four, five}

      assert length(diverging) == 5, """
      the inspector-OPEN dimension changed nothing at standard with a \
      document open. display_state/5 is ignoring its fifth argument, and \
      every other test in this file is green for the wrong reason.
      Diverging rows: #{inspect(diverging)}
      """

      # And it diverges in the DIRECTION the ladder claims: the 260px list
      # column goes away (:full -> :hidden) rather than merely narrowing.
      assert row(2, &PaneBuilder.display_state(&1, 2, true, "standard")) == [:strip, :full]

      assert row(2, &PaneBuilder.display_state(&1, 2, true, "standard", true)) == [
               :hidden,
               :strip
             ]
    end

    test "exactly ONE visible pane survives the ladder, and it is the LAST one" do
      # The measured cell is `visible_pane_widths_px: [44]` — one 44px strip.
      # Pin the shape rather than restating the table: any future clause that
      # kept two strips, or kept the wrong pane, would still be a table edit
      # away from green but could never pass this.
      for num_panes <- 1..8 do
        states = row(num_panes, &PaneBuilder.display_state(&1, num_panes, true, "standard", true))

        assert Enum.count(states, &(&1 != :hidden)) == 1,
               "num_panes=#{num_panes} left #{inspect(states)} — the ladder must leave " <>
                 "exactly one visible pane"

        assert List.last(states) == :strip,
               "num_panes=#{num_panes}: the surviving pane must be the LAST one, as a " <>
                 "44px back affordance — got #{inspect(states)}"

        refute :full in states,
               "num_panes=#{num_panes}: a :full nav column defeats the dock — #{inspect(states)}"
      end
    end
  end

  describe "TIER 1 IS A HARD CONSTRAINT" do
    test "at wide, summoning the inspector moves ZERO cells for any pane count or editor state" do
      # Viewport 1280 and 1440. This is the constraint the whole slice is
      # fenced by: the ladder buys width at standard and must not spend
      # navigation at wide, where there is no shortfall to fix.
      for num_panes <- 1..8, has_editor? <- @editor_states do
        closed = row(num_panes, &PaneBuilder.display_state(&1, num_panes, has_editor?, "wide"))

        opened =
          row(num_panes, &PaneBuilder.display_state(&1, num_panes, has_editor?, "wide", true))

        assert opened == closed, """
        TIER 1 MOVED. At wide with num_panes=#{num_panes} has_editor=#{has_editor?}, \
        opening the inspector changed the pane row:
          closed -> #{inspect(closed)}
          open   -> #{inspect(opened)}
        """
      end
    end
  end
end
