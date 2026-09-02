defmodule Barkpark.PortableDoc.TiersTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Tiers

  describe "tier_of/1" do
    test "classifies representative types per tier" do
      assert Tiers.tier_of("paragraph") == :element
      assert Tiers.tier_of("action") == :element
      assert Tiers.tier_of("field-image") == :element
      assert Tiers.tier_of("localizedText") == :element

      assert Tiers.tier_of("callout") == :widget
      assert Tiers.tier_of("cards") == :widget
      # STEP 4: the NEW `card` WIDGET (the cards-grid split) — distinct from the
      # legacy `cards` fleet grid (also :widget). Both classify :widget; the
      # completeness invariant below auto-covers the new compose_block(card) clause.
      assert Tiers.tier_of("card") == :widget
      # The notes-grid split: the NEW singular `note` WIDGET (byte-identical to ONE
      # legacy `notes` item), distinct from the plural `notes` fleet grid (also :widget).
      assert Tiers.tier_of("note") == :widget
      assert Tiers.tier_of("notes") == :widget
      # The NEW `stage` WIDGET (the pipeline-node split) — distinct from the legacy
      # `pipeline` fleet grid (also :widget). The completeness invariant below
      # auto-covers the new compose_block(stage) clause.
      assert Tiers.tier_of("stage") == :widget
      assert Tiers.tier_of("terminal") == :widget
      assert Tiers.tier_of("table") == :widget

      assert Tiers.tier_of("section") == :section
      assert Tiers.tier_of("columns") == :section
    end

    test "reads the type off a block map" do
      assert Tiers.tier_of(%{"type" => "heading", "level" => 2}) == :element
      assert Tiers.tier_of(%{"type" => "columns"}) == :section
    end

    test "tier is by type ONLY — a role never changes it" do
      assert Tiers.tier_of(%{"type" => "image", "role" => "featured"}) == :element
      assert Tiers.tier_of(%{"type" => "heading", "role" => "title"}) == :element
    end

    test "unknown / malformed → nil" do
      assert Tiers.tier_of("no-such-block") == nil
      assert Tiers.tier_of(%{"role" => "title"}) == nil
      assert Tiers.tier_of(%{}) == nil
      assert Tiers.tier_of(nil) == nil
      assert Tiers.tier_of(42) == nil
    end
  end

  describe "the classification is well-formed" do
    test "the three tiers are disjoint (no type in two tiers)" do
      %{element: e, widget: w, section: s} = Tiers.by_tier()

      assert MapSet.disjoint?(MapSet.new(e), MapSet.new(w))
      assert MapSet.disjoint?(MapSet.new(e), MapSet.new(s))
      assert MapSet.disjoint?(MapSet.new(w), MapSet.new(s))
    end

    test "known_types has no duplicates and covers all three tiers" do
      known = Tiers.known_types()
      assert length(known) == length(Enum.uniq(known))
      # non-vacuous: each tier actually contributes
      for {_tier, types} <- Tiers.by_tier(), do: assert(types != [])
    end

    test "classify/1 pairs each block with its tier, nil for unknown" do
      blocks = [%{"type" => "heading"}, %{"type" => "cards"}, %{"type" => "mystery"}]

      assert Tiers.classify(blocks) == [
               {%{"type" => "heading"}, :element},
               {%{"type" => "cards"}, :widget},
               {%{"type" => "mystery"}, nil}
             ]
    end
  end

  describe "completeness vs. the render surface (distrust-vacuous-green)" do
    # The reader's compose_block/2 clauses ARE the set of renderable block types.
    # Every one MUST have a tier, and this module must not claim a type the reader
    # cannot produce. This is the hard invariant that keeps the classification from
    # drifting: add a block type → it fails here until it lands in Tiers.
    @compose_path Path.expand(
                    "../../../lib/barkpark/portable_doc/render/compose.ex",
                    __DIR__
                  )

    defp renderable_types do
      source = File.read!(@compose_path)

      direct =
        Regex.scan(~r/compose_block\(%\{"type" => "([A-Za-z0-9-]+)"/, source)
        |> Enum.map(&List.last/1)

      # the `when t in ["tasks", "task-list"]` guard clause
      guard =
        Regex.scan(~r/when t in \[([^\]]+)\]/, source)
        |> Enum.flat_map(fn [_, inner] ->
          Regex.scan(~r/"([A-Za-z0-9-]+)"/, inner) |> Enum.map(&List.last/1)
        end)

      (direct ++ guard) |> Enum.uniq() |> Enum.sort()
    end

    test "the extraction actually found the render surface (parser sanity)" do
      types = renderable_types()
      # anchor to types that MUST exist, so a broken regex reds instead of passing empty
      assert "paragraph" in types
      assert "section" in types
      assert "tasks" in types, "the `when t in [...]` guard clause was not parsed"
      assert length(types) > 30, "only #{length(types)} types parsed — compose.ex moved?"
    end

    test "EVERY renderable block type has a tier" do
      unclassified = renderable_types() |> Enum.reject(&Tiers.classified?/1)

      assert unclassified == [],
             "these renderable block types have no tier — classify them in Tiers: " <>
               inspect(unclassified)
    end

    test "Tiers claims NO type the reader cannot produce" do
      renderable = MapSet.new(renderable_types())
      phantom = Tiers.known_types() |> Enum.reject(&MapSet.member?(renderable, &1))

      assert phantom == [],
             "Tiers classifies types with no compose_block clause (stale?): " <>
               inspect(phantom)
    end
  end

  describe "THE CANONICAL COUNT ANCHOR (mob-zb-bl-canonical-anchor)" do
    # ONE number, run-derived, in one place.
    #
    # WHY A PIN AT ALL. The tests above prove the classification is well-FORMED
    # (disjoint, duplicate-free, and set-equal to compose.ex's render surface).
    # None of them says HOW MANY, and that absence is what kept the block-type
    # number war alive across three waves: every rival count in circulation
    # (Go-76, Go-82, Elixir-75, react-66/59, 79-vs-83) was a quoted-string
    # census, and every one of them was wrong. This is the L1 run-proof those
    # static claims lacked — a number a reader can cite because a test executed
    # it, not because someone counted lines.
    #
    # WHY GREP CANNOT ANSWER THIS AND THE LANGUAGE CAN. `Tiers`'s :section list
    # is an UNQUOTED `~w()` sigil, so a quoted-string census silently drops all
    # three of its types; the two camelCase types (`arrayOf`, `localizedText`)
    # are dropped again by any lowercase-only character class. Both mistakes are
    # documented in the wave's own re-derivation ledgers. `length/1` over
    # `known_types/0` is immune to both by construction: it counts the map the
    # module actually built.
    #
    # WHEN THIS REDS, IT IS DOING ITS JOB. A block type landed or left. Fix the
    # number here (and in the exclusions ledger,
    # docs/decisions/0006-canonical-block-type-count.md) as part of that change —
    # never the other way round. The number is downstream of the code; nothing
    # is allowed to pin a count to make a sentence somewhere else come true.
    @canonical_block_type_count 79

    test "length(known_types/0) is EXACTLY the pinned canonical count" do
      assert length(Tiers.known_types()) == @canonical_block_type_count
    end

    test "the tier lists SUM to the same number (the pin cannot hide a double-count)" do
      # known_types/0 reads Map.keys(@tier_of), which silently de-duplicates. If
      # the pin were checked only against that, a type appearing in two tiers
      # would leave both counts equal and the drift invisible. Summing the raw
      # lists is the independent arithmetic: sum > pin means a duplicate.
      sum =
        Tiers.by_tier()
        |> Enum.map(fn {_tier, types} -> length(types) end)
        |> Enum.sum()

      assert sum == @canonical_block_type_count,
             "tier lists sum to #{sum} but known_types/0 pins " <>
               "#{@canonical_block_type_count} — a type is classified twice"
    end

    test "compose.ex's render surface carries the SAME count — two modules, one number" do
      # The completeness tests above assert the two SETS are equal, so this is
      # arithmetically implied — and it is written out anyway, because the whole
      # point of the anchor is that a reader can cite the number for the RENDERER
      # (not just for the classifier) and point at a line that executed it.
      assert length(renderable_types()) == @canonical_block_type_count
    end
  end
end
