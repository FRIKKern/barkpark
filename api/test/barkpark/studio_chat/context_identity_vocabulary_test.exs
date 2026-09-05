defmodule Barkpark.StudioChat.ContextIdentityVocabularyTest do
  @moduledoc """
  THE ELIXIR HALF of the chat context band vocabulary lock
  (task-b6b9a4424d653937).

  The connection band ships on two surfaces from one conceptual contract, and
  until this file the contract existed as TWO independent hand-maintained
  copies: `Barkpark.StudioChat.ContextIdentity` here, and
  `apps/mobile/src/chat/context.ts` there. Both were well tested INTERNALLY —
  which is exactly the trap, because an internal test cannot see the other
  surface. Nothing failed when someone reworded `"(not a git repo)"` on one side
  only, or reordered the six fields on one side only. Users would then see two
  different bands describing the same session.

  The lock is ONE checked-in fixture,
  `test/support/fixtures/chat_context_band_vocabulary.json`, read by BOTH this
  test and `apps/mobile/__tests__/chatContextVocabulary.test.ts`. Same shape as
  the fold-label lock (`chat_fold_labels.json`, PRs #15434 and #15457): a
  fixture only one side checks is half a lock, so the mobile test reads the SAME
  bytes.

  RED IN BOTH DIRECTIONS by construction. Change a marker in
  `context_identity.ex` alone and THIS file reds; change the same marker in
  `context.ts` alone and the jest file reds. Neither surface can move on its
  own; the fixture is the thing you edit first.

  ORDER IS PART OF THE CONTRACT. `field_names/0` is the PAINT order, so the
  comparison below is a list equality — never a set, never sorted. A sorted
  comparison would wave through exactly the reorder this file exists to catch.

  Run: `CC=/usr/bin/clang mix test test/barkpark/studio_chat/context_identity_vocabulary_test.exs`
  """
  # async: true — every assertion is a pure function read plus one file read.
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.ContextIdentity

  @vocabulary_fixture Path.expand("../../support/fixtures/chat_context_band_vocabulary.json", __DIR__)

  # Read once, at compile time, so a missing or malformed fixture is a LOUD
  # failure of the whole module rather than a quiet nil flowing into an
  # assertion that then compares nothing against nothing.
  @vocabulary @vocabulary_fixture |> File.read!() |> Jason.decode!()
  @external_resource @vocabulary_fixture

  describe "the shared fixture is readable and populated" do
    # NON-VACUITY. Every equality below is only as good as the fixture actually
    # holding values. A moved, renamed or emptied fixture must red HERE, with a
    # message that says so, rather than leave the locks comparing nothing.
    test "the fixture file exists at the path both surfaces read" do
      assert File.exists?(@vocabulary_fixture),
             "the shared vocabulary fixture is missing at #{@vocabulary_fixture}. " <>
               "apps/mobile/__tests__/chatContextVocabulary.test.ts reads the SAME " <>
               "file by relative path — moving it breaks the lock on both surfaces."
    end

    test "the fixture carries all four markers, each a non-empty parenthesised string" do
      markers = Map.fetch!(@vocabulary, "markers")

      for key <- ~w(unset unknown no_repo server_local) do
        value = Map.get(markers, key)

        assert is_binary(value) and value != "",
               "fixture markers.#{key} must be a non-empty string, got: #{inspect(value)}"

        assert String.starts_with?(value, "(") and String.ends_with?(value, ")"),
               "fixture markers.#{key} must be parenthesised — that is what makes a " <>
                 "marker unmistakable for a host name, slug, URL or path. Got: #{inspect(value)}"
      end
    end

    test "the fixture carries exactly six field names, all non-empty strings" do
      names = Map.fetch!(@vocabulary, "field_names")

      assert is_list(names) and length(names) == 6,
             "fixture field_names must be the six band fields in paint order, got: #{inspect(names)}"

      assert Enum.all?(names, &(is_binary(&1) and &1 != "")),
             "every fixture field name must be a non-empty string, got: #{inspect(names)}"
    end

    test "the four markers are distinct from one another" do
      # Law 2 of the band: a reader must be able to tell "nothing is set" from
      # "nobody can tell" from "the server runs it" at a glance. Two markers
      # collapsing to the same string destroys that distinction on BOTH
      # surfaces at once, so the fixture itself refuses it.
      values = @vocabulary |> Map.fetch!("markers") |> Map.values()

      assert length(Enum.uniq(values)) == length(values),
             "the four absence markers must be distinct strings, got: #{inspect(values)}"
    end
  end

  describe "ContextIdentity's markers equal the shared fixture" do
    test "unset_marker/0 equals fixture markers.unset" do
      expected = get_in(@vocabulary, ["markers", "unset"])

      assert ContextIdentity.unset_marker() == expected,
             "ContextIdentity.unset_marker/0 drifted from the shared fixture. " <>
               "Elixir says #{inspect(ContextIdentity.unset_marker())}, the fixture " <>
               "says #{inspect(expected)}. apps/mobile/src/chat/context.ts's " <>
               "ABSENT_UNSET is pinned to the same fixture value — change the " <>
               "fixture and BOTH surfaces, or neither."
    end

    test "unknown_marker/0 equals fixture markers.unknown" do
      expected = get_in(@vocabulary, ["markers", "unknown"])

      assert ContextIdentity.unknown_marker() == expected,
             "ContextIdentity.unknown_marker/0 drifted from the shared fixture. " <>
               "Elixir says #{inspect(ContextIdentity.unknown_marker())}, the fixture " <>
               "says #{inspect(expected)}. The mobile mirror is ABSENT_UNKNOWN."
    end

    test "no_repo_marker/0 equals fixture markers.no_repo" do
      expected = get_in(@vocabulary, ["markers", "no_repo"])

      assert ContextIdentity.no_repo_marker() == expected,
             "ContextIdentity.no_repo_marker/0 drifted from the shared fixture. " <>
               "Elixir says #{inspect(ContextIdentity.no_repo_marker())}, the fixture " <>
               "says #{inspect(expected)}. The mobile mirror is ABSENT_NO_REPO."
    end

    test "server_local_marker/0 equals fixture markers.server_local" do
      expected = get_in(@vocabulary, ["markers", "server_local"])

      assert ContextIdentity.server_local_marker() == expected,
             "ContextIdentity.server_local_marker/0 drifted from the shared fixture. " <>
               "Elixir says #{inspect(ContextIdentity.server_local_marker())}, the " <>
               "fixture says #{inspect(expected)}. The mobile mirror is ABSENT_SERVER_LOCAL."
    end
  end

  describe "ContextIdentity.field_names/0 equals the shared fixture IN PAINT ORDER" do
    test "the names match one-for-one, in order" do
      expected = Map.fetch!(@vocabulary, "field_names")
      actual = ContextIdentity.field_names()

      assert actual == expected,
             "ContextIdentity.field_names/0 drifted from the shared fixture. " <>
               "Elixir says #{inspect(actual)}, the fixture says #{inspect(expected)}. " <>
               "This is a LIST comparison on purpose: the band paints in this order, " <>
               "so a reorder is a real visible defect and must not pass as a set match. " <>
               "apps/mobile/src/chat/context.ts's CONTEXT_FIELD_NAMES is pinned to the " <>
               "same list."
    end

    test "a reordered list would NOT satisfy this lock" do
      # The guard's own non-vacuity check: proves the equality above is
      # order-sensitive rather than accidentally set-shaped. If someone ever
      # relaxes the assertion to a sort-then-compare, THIS test still red-flags
      # the loss, because a permutation must remain unequal.
      expected = Map.fetch!(@vocabulary, "field_names")
      [a, b | rest] = expected
      permuted = [b, a | rest]

      refute permuted == ContextIdentity.field_names(),
             "a permutation of the field names compared EQUAL to field_names/0, " <>
               "which means the order check above cannot bite."
    end
  end
end
