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

    # ── THE EXTRACTOR: compose_block CLAUSE HEADS, read off the AST ───────────
    # This was a FILE-WIDE regex pair, and the `when t in [...]` half read ANY
    # such guard anywhere in compose.ex as a list of block types. #17811 tripped
    # it: a column-type whitelist (`when t in ["text", "num", "delta", "spark"]`)
    # inside the private `table_col_types/2` helper moved this anchor 80 → 84
    # with no block type added, and the workaround was a comment in PRODUCTION
    # code forbidding a legal Elixir form because a TEST's regex could not parse
    # it — a fence around the instrument instead of a fix.
    #
    # The extractor now quotes the source and reads ONLY `def compose_block/2,3`
    # clause heads, so nothing outside a clause head can move the number.
    # Everything else is UNCHANGED, deliberately: a type is named either by a
    # literal `"type" => "x"` in the first-argument map pattern, or by a literal
    # `t in ["x", "y"]` guard over the variable that pattern binds. On compose.ex
    # as of this commit the two extractors agree exactly — 80 types, empty set
    # difference both ways — so this is a re-anchoring, not a re-count.
    #
    # The `t == "x"` and `t in @attr` variable-guard forms stay OUT, as they were
    # before: that is compose.ex's documented ALIAS form (see its comments above
    # @unordered_list_aliases and @heading_aliases). An alias has no tier of its
    # own — it borrows its target's — so it is not a member of this set.
    defp renderable_types, do: @compose_path |> File.read!() |> compose_block_clause_types()

    defp compose_block_clause_types(source) do
      source
      |> Code.string_to_quoted!()
      |> compose_block_clause_heads()
      |> Enum.flat_map(&clause_head_types/1)
      |> Enum.uniq()
      |> Enum.sort()
    end

    defp compose_block_clause_heads(ast) do
      {_, heads} =
        Macro.prewalk(ast, [], fn
          {:def, _, [head | _]} = node, acc -> {node, [head | acc]}
          node, acc -> {node, acc}
        end)

      Enum.filter(heads, fn head ->
        match?(
          {:compose_block, _, args} when is_list(args) and length(args) in [2, 3],
          call_of(head)
        )
      end)
    end

    defp call_of({:when, _, [call, _guard]}), do: call
    defp call_of(call), do: call

    defp guard_of({:when, _, [_call, guard]}), do: guard
    defp guard_of(_head), do: nil

    defp clause_head_types(head) do
      {:compose_block, _, args} = call_of(head)

      case type_pattern(hd(args)) do
        {:ok, literal} when is_binary(literal) ->
          [literal]

        {:ok, {var, _, ctx}} when is_atom(var) and is_atom(ctx) ->
          guard_literals(guard_of(head), var)

        _ ->
          []
      end
    end

    # the first argument is `%{"type" => …}`, or `%{"type" => …} = b`
    defp type_pattern({:=, _, parts}) do
      Enum.find_value(parts, :error, fn part ->
        case type_pattern(part) do
          {:ok, value} -> {:ok, value}
          :error -> nil
        end
      end)
    end

    defp type_pattern({:%{}, _, pairs}) when is_list(pairs) do
      case List.keyfind(pairs, "type", 0) do
        {"type", value} -> {:ok, value}
        nil -> :error
      end
    end

    defp type_pattern(_other), do: :error

    defp guard_literals(nil, _var), do: []

    defp guard_literals(guard, var) do
      {_, acc} =
        Macro.prewalk(guard, [], fn
          {:in, _, [{^var, _, _}, list]} = node, acc when is_list(list) ->
            {node, acc ++ Enum.filter(list, &is_binary/1)}

          node, acc ->
            {node, acc}
        end)

      acc
    end

    # The RETIRED file-wide regex, kept for exactly one purpose: it is the
    # control arm. A test below feeds it the same fixtures as the extractor and
    # asserts it MISBEHAVES on them — without that, "the guard in a non-block
    # helper does not move the count" would pass on a fixture that never had a
    # trap in it, and the control would be vacuous.
    defp legacy_regex_types(source) do
      direct =
        Regex.scan(~r/compose_block\(%\{"type" => "([A-Za-z0-9-]+)"/, source)
        |> Enum.map(&List.last/1)

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

    # ── CONTROLS ON THE INSTRUMENT ────────────────────────────────────────────
    # This anchor's whole failure mode is an extractor that answers confidently
    # about a population it never measured, so a green on the real file proves
    # nothing on its own. Each control below runs the extractor on a FIXTURE
    # whose correct answer is known by construction.

    @fixture_two_clause_forms """
    defmodule Fixture do
      def compose_block(%{"type" => "alpha"} = b, style), do: {b, style}
      def compose_block(%{"type" => t} = b, style) when t in ["beta", "gamma"], do: {b, style}
    end
    """

    @fixture_guard_in_non_block_helper """
    defmodule Fixture do
      def compose_block(%{"type" => "alpha"} = b, style), do: {b, style}

      defp table_col_types(cols) do
        Enum.map(cols, fn
          %{"type" => t} when t in ["text", "num", "delta", "spark"] -> t
          _ -> "text"
        end)
      end
    end
    """

    @fixture_multiline_clause_head """
    defmodule Fixture do
      def compose_block(
            %{"type" => "alpha"} = b,
            style
          ),
          do: {b, style}
    end
    """

    @fixture_no_compose_block """
    defmodule Fixture do
      defp helper(t) when t in ["alpha", "beta"], do: t
    end
    """

    test "POSITIVE CONTROL: the extractor finds BOTH clause-head forms it claims to read" do
      # literal `"type" => "alpha"` head AND the `t in [...]` guard head.
      assert compose_block_clause_types(@fixture_two_clause_forms) == ["alpha", "beta", "gamma"]
    end

    test "EMPTY-POPULATION REFUSAL: nothing to read yields [], and the real file is NOT empty" do
      # An extractor that silently returns [] makes every membership assertion
      # below it pass vacuously. Both halves are asserted: the extractor CAN
      # return empty (so `== []` elsewhere is a real outcome, not an impossibility),
      # and on the file this anchor is actually about it does not.
      assert compose_block_clause_types(@fixture_no_compose_block) == []

      real = renderable_types()
      refute real == [], "the extractor parsed compose.ex to an EMPTY set — it measured nothing"

      assert length(real) > 30,
             "only #{length(real)} clause-head types parsed — compose.ex moved?"
    end

    test "NEGATIVE CONTROL (#17811's trap): a `when t in [...]` guard in a NON-block helper cannot move the count" do
      assert compose_block_clause_types(@fixture_guard_in_non_block_helper) == ["alpha"]

      # …and the control is not vacuous: the retired file-wide regex swallows the
      # column-type whitelist whole, which is exactly the 80 → 84 inflation that
      # produced the ban comment in compose.ex.
      assert legacy_regex_types(@fixture_guard_in_non_block_helper) ==
               ["alpha", "delta", "num", "spark", "text"]
    end

    test "OLD-BLIND / NEW-SIGHTED: a multi-line clause head is invisible to the retired regex" do
      # The retired regex needed `compose_block(%{"type" => "` contiguous on one
      # line, so a clause head the formatter wrapped was silently dropped — the
      # same class of error as the over-count, in the other direction.
      assert compose_block_clause_types(@fixture_multiline_clause_head) == ["alpha"]
      assert legacy_regex_types(@fixture_multiline_clause_head) == []
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
    # 80 → 81: `master-ref`, the linked master instance (task-59f078a2fd248698).
    @canonical_block_type_count 81

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
