defmodule BarkparkCloud.UnavailableVocabularyCensusTest do
  @moduledoc """
  cch-w58-bl — THE PIN under `BarkparkCloud.UnavailableVocabulary`.

  Wave 58 shipped two closed vocabularies for ONE class of fact — "we asked a
  customer's box something and did not get an answer we could use" — on two
  surfaces, in two idioms, with different words for the same thing
  (`identity_refused` on the registry side, `unauthorized` on the meter side).
  Neither is wrong. What was missing is that nothing STATED the mapping, so the
  THIRD surface to need this vocabulary would have minted a third word and no
  test in this repo would have noticed.

  `UnavailableVocabulary` is the document. This file is what makes it a guard.

  ## The two detectors, and why there are two

    * DECLARATION scan — a module attribute whose name ends in
      `unavailable_reasons`, bound to a `~w(...)`. That is the shape BOTH
      existing surfaces use. It is matched over the whole source (usage.ex's
      list wraps across two lines, so a line-at-a-time reader finds half of it
      and silently under-reports).
    * LITERAL scan — a code line that mentions `unavailable_reason` AND carries
      a quoted slug. This is the one that catches a surface which never declares
      a list at all: `sites/box_relay.ex` pattern-matches the bare string
      `"identity_refused"` today, and a copy of that idiom naming a fresh word
      is exactly the drift the row describes.

  A declaration detector alone is defeated by a surface that writes literals; a
  literal detector alone is defeated by a surface that declares a list and reads
  it through a variable. Neither alone is enough, and saying so is cheaper than
  discovering it.

  ## Limits, stated so nobody over-reads a green run

    * It is a SOURCE scan of `cloud/lib`, not a call graph. A word minted at
      runtime from a variable is invisible to both detectors — the arm below on
      `Atom.to_string(reason)` is the honest note that this shape EXISTS in
      registry.ex and is covered instead by that module's own
      `validate_inclusion` against `update_unavailable_reasons/0`.
    * Whole-line comment stripping only. Every mention of a rung inside prose in
      `cloud/lib` today is on a `#` line, so the literal scan sees none of them;
      a future comment could not fabricate a NEW word without the scan reading
      it as real, which fails LOUD (a red naming a word nobody minted), never silent.
    * It does not argue the two idioms should merge. Charter says they should
      not. It argues that a third word for the same fact has to arrive in the
      mapping table first.

  ## MUTATION (run before trusting the green)

  Add a third surface — one line in any `cloud/lib` module:

      @fleet_unavailable_reasons ~w(credential_rejected)

  Two arms red: the declaring-surface roster (an unlisted file declares one of
  these vocabularies) and the unmapped-word arm (`credential_rejected` is in
  neither vocabulary). Change `box_relay.ex`'s `"identity_refused"` match to
  `"credential_rejected"` and the LITERAL arm reds on its own.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.UnavailableVocabulary, as: Vocab

  @lib_root Path.expand("../../lib", __DIR__)

  # The surfaces that DECLARE one of the two vocabularies, each with the role
  # that makes its idiom the right one there. A file that starts declaring one
  # and is not here reds — that is the third-surface case, caught at the moment
  # the list is written rather than the moment a word drifts.
  @declaring_surfaces %{
    "barkpark_cloud/registry/barkpark.ex" =>
      "the REGISTRY vocabulary: persisted on barkparks.update_unavailable_reason and " <>
        "clamped by the schema's own validate_inclusion. Its idiom is a stored admin " <>
        "credential being refuted.",
    "barkpark_cloud/usage.ex" =>
      "the USAGE vocabulary: carried per-meter in the usage envelope. Its idiom is an " <>
        "HTTP status a paying customer's meter has to explain."
  }

  # Floors — a broken extractor must RED, not report a clean tree.
  @registry_floor 9
  @usage_floor 8
  @literal_floor 1

  @declaration ~r/@([a-z_]*unavailable_reasons)\s+~w\(([^)]*)\)/
  @slug ~r/"([a-z][a-z0-9_]*)"/

  # Words that appear in this fact's context and are DELIBERATELY outside both
  # vocabularies. Named one by one with a reason — never a wildcard — because an
  # unexplained exemption is how a census stops discriminating. Keyed
  # {relpath, word} so an exemption earned in one module does not silently
  # excuse the same word appearing anywhere else.
  @out_of_vocabulary %{
    {"barkpark_cloud/usage.ex", "unknown"} =>
      "THE NORMALISATION FLOOR, not a rung. `unavailable_reason/1` emits it for any atom " <>
        "OUTSIDE the closed set, so that no raw internal atom ever reaches the browser. It " <>
        "is the mechanism that makes the set closed; adding it to the vocabulary would make " <>
        "the vocabulary open."
  }

  defp lib_files, do: Path.wildcard(Path.join(@lib_root, "**/*.ex"))

  # Whole-line comments AND heredoc bodies — see the moduledoc's limits. The
  # heredoc half is not optional: `registry/barkpark.ex`'s @doc discusses the
  # column and quotes a word inside a heredoc, and a reader that counts it
  # reports a drift nobody wrote.
  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      cond do
        in_heredoc? -> {"", not String.contains?(line, ~s("""))}
        odd_heredoc_marker?(line) -> {hd(String.split(line, ~s("""))), true}
        String.starts_with?(String.trim(line), "#") -> {"", false}
        true -> {line, false}
      end
    end)
    |> elem(0)
  end

  defp odd_heredoc_marker?(line) do
    line |> String.split(~s(""")) |> length() |> Kernel.-(1) |> rem(2) == 1
  end

  defp code_source(path), do: path |> code_lines() |> Enum.join("\n")

  defp rel(path), do: Path.relative_to(path, @lib_root)

  # {relpath, attribute_name, [words]} for every declared vocabulary.
  defp declarations do
    for path <- lib_files(),
        [_, attr, body] <- Regex.scan(@declaration, code_source(path)),
        do: {rel(path), attr, body |> String.split(~r/\s+/, trim: true)}
  end

  # {relpath, slug} for every quoted slug on a code line that names this fact
  # class. The line must mention `unavailable_reason` — that is what makes the
  # slug a claim about THIS vocabulary and not some unrelated string.
  defp context_literals do
    for path <- lib_files(),
        line <- code_lines(path),
        String.contains?(line, "unavailable_reason"),
        [_, slug] <- Regex.scan(@slug, line),
        do: {rel(path), slug}
  end

  describe "floors — a broken reader reds instead of certifying" do
    test "both vocabularies are still large, and read from their owners" do
      assert length(Vocab.registry_words()) >= @registry_floor,
             "the registry vocabulary returned #{inspect(Vocab.registry_words())} — below the " <>
               "floor of #{@registry_floor}. Either it was gutted or the accessor changed shape."

      assert length(Vocab.usage_words()) >= @usage_floor,
             "the usage vocabulary returned #{inspect(Vocab.usage_words())} — below the floor " <>
               "of #{@usage_floor}."

      assert "identity_refused" in Vocab.registry_words()
      assert "unauthorized" in Vocab.usage_words()
    end

    test "the declaration scan finds BOTH surfaces (a wrapped ~w list is not half a list)" do
      found = declarations() |> Enum.map(fn {path, _attr, _words} -> path end) |> Enum.sort()

      assert found == Enum.sort(Map.keys(@declaring_surfaces)),
             "the declaration scan resolved #{inspect(found)}. If that is short of two, the " <>
               "regex stopped matching (usage.ex's list wraps across two lines) and every arm " <>
               "below has gone vacuous."

      usage_words =
        declarations()
        |> Enum.find_value([], fn {path, _a, w} -> path == "barkpark_cloud/usage.ex" && w end)

      assert Enum.sort(usage_words) == Enum.sort(Vocab.usage_words()),
             "the scan read #{inspect(Enum.sort(usage_words))} out of usage.ex's declaration " <>
               "but the module exports #{inspect(Enum.sort(Vocab.usage_words()))}. A reader " <>
               "that sees only the first line of a wrapped ~w list reports a clean tree while " <>
               "missing half the vocabulary."
    end

    test "the literal scan still finds the bare-string surface" do
      literals = context_literals()

      assert length(literals) >= @literal_floor,
             "the literal scan found #{length(literals)} slugs. box_relay.ex matches the bare " <>
               "string \"identity_refused\" on a code line naming update_unavailable_reason — " <>
               "if this is zero the detector is broken, not the tree."

      assert {"barkpark_cloud/sites/box_relay.ex", "identity_refused"} in literals
    end
  end

  describe "the mapping is EXHAUSTIVE over both vocabularies" do
    test "every declared word is mapped, in its own column" do
      mapped_registry = for f <- Vocab.facts(), f.registry, do: f.registry
      mapped_usage = for f <- Vocab.facts(), f.usage, do: f.usage

      assert Enum.sort(mapped_registry) == Enum.sort(Vocab.registry_words()),
             """
             The mapping table and the REGISTRY vocabulary disagree.

                 only in the vocabulary: #{inspect(Enum.sort(Vocab.registry_words() -- mapped_registry))}
                 only in the mapping:    #{inspect(Enum.sort(mapped_registry -- Vocab.registry_words()))}

             A rung that grew without a mapping row is the drift this file exists to stop: the
             next surface to need that fact has nothing to read. Add the row — say what the OTHER
             vocabulary calls the same fact, or that it has no occasion for it.
             """

      assert Enum.sort(mapped_usage) == Enum.sort(Vocab.usage_words()),
             """
             The mapping table and the USAGE vocabulary disagree.

                 only in the vocabulary: #{inspect(Enum.sort(Vocab.usage_words() -- mapped_usage))}
                 only in the mapping:    #{inspect(Enum.sort(mapped_usage -- Vocab.usage_words()))}
             """
    end

    test "every row is shaped, and its relation matches the words it carries" do
      malformed =
        for f <- Vocab.facts(),
            not (is_binary(f.fact) and f.fact != "" and is_binary(f.note) and
                   String.length(f.note) >= 40 and
                   f.relation in [:same_word, :same_fact_different_word, :one_sided]),
            do: f

      assert malformed == [],
             "these mapping rows are not machine-checkable: #{inspect(malformed)}. A row is " <>
               "{fact, relation, registry, usage, note} with a substantive note — a bare pair " <>
               "of words is read by nothing and explains nothing."

      wrong =
        Vocab.facts()
        |> Enum.map(fn f ->
          expected =
            cond do
              is_nil(f.registry) or is_nil(f.usage) -> :one_sided
              f.registry == f.usage -> :same_word
              true -> :same_fact_different_word
            end

          {f.fact, f.relation, expected}
        end)
        |> Enum.reject(fn {_fact, actual, expected} -> actual == expected end)

      assert wrong == [],
             """
             These rows declare a relation their own words contradict:

                 #{inspect(wrong)}

             The relation is DERIVABLE from the pair, so a wrong one is a claim the table
             already refutes — the cheapest possible lie to catch, and worth catching because
             `:same_word` is what makes today's three-word agreement a CONTRACT rather than a
             coincidence.
             """
    end

    test "the pair the row is named for is present and is NOT a rename" do
      pair = Enum.find(Vocab.facts(), &(&1.registry == "identity_refused"))

      assert pair, "the identity_refused row is gone — the mapping no longer states the pair."
      assert pair.usage == "unauthorized"
      assert pair.relation == :same_fact_different_word

      # Charter: do NOT rename either vocabulary. Both idioms stay.
      assert "identity_refused" in Vocab.registry_words()
      assert "unauthorized" in Vocab.usage_words()
      refute "unauthorized" in Vocab.registry_words()
      refute "identity_refused" in Vocab.usage_words()
    end
  end

  describe "THE THIRD-SURFACE ARM — a third word for the same fact reds" do
    test "no surface declares a vocabulary this mapping does not know" do
      unlisted =
        for {path, attr, _words} <- declarations(),
            not Map.has_key?(@declaring_surfaces, path),
            do: "#{path}: @#{attr}"

      assert Enum.sort(unlisted) == [],
             """
             These files declare a vocabulary for this fact class and are not on the roster:

                 #{Enum.map_join(Enum.sort(unlisted), "\n    ", & &1)}

             This is the drift the filing predicted: a third surface needing to say "we could
             not read the box" and inventing its own words for it. Either name the fact with a
             word one of the two vocabularies already has, or add the surface to
             @declaring_surfaces here AND its words to the mapping table in
             BarkparkCloud.UnavailableVocabulary — so the FOURTH surface has one thing to read.
             """
    end

    test "every declared word is in the mapped union" do
      unmapped =
        for {path, attr, words} <- declarations(),
            word <- words,
            not Vocab.known_word?(word),
            uniq: true,
            do: "#{path}: @#{attr} declares #{inspect(word)}"

      assert Enum.sort(unmapped) == [],
             """
             These declared words are in NEITHER vocabulary:

                 #{Enum.map_join(Enum.sort(unmapped), "\n    ", & &1)}

             A word for this fact that neither owner declares is a third vocabulary of one.
             """
    end

    test "every quoted word used in this fact's context is in the mapped union" do
      unmapped =
        for {path, slug} = site <- context_literals(),
            not Vocab.known_word?(slug),
            not Map.has_key?(@out_of_vocabulary, site),
            uniq: true,
            do: "#{path}: #{inspect(slug)}"

      assert Enum.sort(unmapped) == [],
             """
             These code lines name this fact class and carry a word neither vocabulary declares:

                 #{Enum.map_join(Enum.sort(unmapped), "\n    ", & &1)}

             This is the literal-idiom half of the drift. `sites/box_relay.ex` reads a rung as a
             bare string in a pattern match; a copy of that idiom naming a word nobody declared
             compiles, runs, matches nothing, and fails silently forever.
             """
    end

    test "the @out_of_vocabulary exemptions are honest — no stale entries" do
      observed = MapSet.new(context_literals())

      stale =
        for {site, _reason} <- @out_of_vocabulary,
            not MapSet.member?(observed, site),
            do: site

      assert Enum.sort(stale) == [],
             "these exemptions excuse a word that is no longer written there: " <>
               "#{inspect(Enum.sort(stale))}. Delete them, or the next real drift at that " <>
               "site is waved through by an entry nobody re-read."

      adopted =
        for {{_path, word} = site, _reason} <- @out_of_vocabulary,
            Vocab.known_word?(word),
            do: site

      assert Enum.sort(adopted) == [],
             "these words are now IN a vocabulary and no longer need excusing: " <>
               "#{inspect(Enum.sort(adopted))}."

      thin =
        for {site, reason} <- @out_of_vocabulary,
            not (is_binary(reason) and String.length(reason) >= 60),
            do: site

      assert thin == [],
             "an exemption with no substantive reason is a bare name with an exit code: " <>
               "#{inspect(thin)}"
    end

    test "the arm can LOSE — an invented word is rejected by known_word?/1" do
      # NON-VACUITY. Both arms above pass trivially if known_word?/1 says yes to
      # everything, which is exactly how a census goes quietly green.
      refute Vocab.known_word?("credential_rejected"),
             "known_word?/1 accepts an invented word — both third-surface arms above are vacuous."

      refute Vocab.known_word?("box_said_no")
      assert Vocab.known_word?("identity_refused")
      assert Vocab.known_word?("unauthorized")
    end
  end
end
