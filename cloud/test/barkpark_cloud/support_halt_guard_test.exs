defmodule BarkparkCloud.SupportHaltGuardTest do
  @moduledoc """
  MECHANICAL replacement for a comment.

  `cloud/test/support/tier_lens_harness/` holds standalone `.exs` runners that
  call `System.halt/1` when invoked with no argv. They are harmless ONLY because
  their filenames do not match the `mix test` discovery glob. One of them was
  named `run_test.exs` for exactly one commit: `mix test` LOADED it, it ran with
  no argv, printed its usage and halted the BEAM — taking the entire cloud suite
  down with it (fixed by renaming, PR #14496).

  `elixirc_paths(:test)` compiling only `.ex` is a fact about COMPILATION and
  says nothing about test DISCOVERY. Discovery is `Path.wildcard("test/**/*_test.exs")`,
  and `test/support/` is under `test/`.

  Until this file existed the ONLY protection was a prose comment in ONE of the
  three scripts. This test makes the invariant mechanical: it DERIVES the set of
  halting files by reading every file under `cloud/test/support/`, and refuses if
  any of them would be picked up by the discovery glob.
  """

  use ExUnit.Case, async: true

  @support_root Path.expand("../support", __DIR__)

  # The discovery glob `mix test` itself uses (Mix.Tasks.Test's default
  # `test_pattern` is "*_test.exs", joined under each test path with "**/").
  @test_pattern "*_test.exs"

  # Named ANCHORS for the positive control only. The guard below does NOT read
  # this list — it derives its own set by grepping. These three are here so that
  # a derivation which silently found nothing cannot pass vacuously.
  @known_halt_scripts [
    "tier_lens_harness/probe.exs",
    "tier_lens_harness/prove_lens.exs",
    "tier_lens_harness/rows.exs"
  ]

  defp all_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp halting_files do
    @support_root
    |> all_files()
    |> Enum.filter(fn path -> File.read!(path) =~ "System.halt" end)
    |> Enum.map(&Path.relative_to(&1, @support_root))
    |> Enum.sort()
  end

  defp discoverable_files do
    @support_root
    |> Path.join("**/#{@test_pattern}")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, @support_root))
    |> Enum.sort()
  end

  describe "positive control (the guard must have a subject)" do
    test "the support tree is readable and non-trivial" do
      files = all_files(@support_root)

      assert length(files) > 5,
             "expected cloud/test/support/ to hold files; found #{length(files)} under " <>
               "#{@support_root}. A guard over an empty tree proves nothing."
    end

    test "the derivation finds halting files, and finds the three known runners among them" do
      derived = halting_files()

      refute derived == [],
             "DERIVATION FOUND NOTHING. No file under cloud/test/support/ contains " <>
               "`System.halt`. Either the tree moved or the read is broken — either way " <>
               "the guard below would pass vacuously. Fix the derivation, do not delete it."

      for known <- @known_halt_scripts do
        path = Path.join(@support_root, known)

        assert File.regular?(path),
               "known halt runner #{known} is missing from cloud/test/support/. " <>
                 "If it was renamed, check the NEW name does not end in `_test.exs` " <>
                 "and update this anchor list."

        assert File.read!(path) =~ "System.halt",
               "known halt runner #{known} no longer contains `System.halt` — this " <>
                 "anchor no longer anchors anything."

        assert known in derived,
               "#{known} contains `System.halt` but the derivation did not return it. " <>
                 "The walk is broken: derived = #{inspect(derived)}"
      end
    end

    test "the discovery predicate recognises the name that caused the incident" do
      # Guards the matcher itself against a predicate that matches nothing:
      # `run_test.exs` is the exact name `mix test` loaded when it halted the suite.
      in_tmp = fn name ->
        dir =
          Path.join(
            System.tmp_dir!(),
            "bp_support_halt_guard_#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(dir)
        File.write!(Path.join(dir, name), "# fixture\n")
        on_exit_paths = Path.wildcard(Path.join(dir, "**/#{@test_pattern}"))
        File.rm_rf!(dir)
        Enum.map(on_exit_paths, &Path.basename/1)
      end

      assert in_tmp.("run_test.exs") == ["run_test.exs"],
             "the discovery glob #{@test_pattern} must pick up run_test.exs"

      assert in_tmp.("probe.exs") == [],
             "the discovery glob #{@test_pattern} must NOT pick up probe.exs"
    end
  end

  describe "the guard" do
    test "no file under cloud/test/support/ both is discovered by mix test and calls System.halt" do
      offenders =
        MapSet.intersection(MapSet.new(halting_files()), MapSet.new(discoverable_files()))
        |> MapSet.to_list()
        |> Enum.sort()

      assert offenders == [],
             """
             A file under cloud/test/support/ matches the `mix test` discovery glob
             `test/**/#{@test_pattern}` AND calls `System.halt`.

             OFFENDERS (relative to cloud/test/support/):
             #{Enum.map_join(offenders, "\n", &("  - " <> &1))}

             `mix test` will LOAD each of these at suite start. A top-level
             `System.halt` in a loaded file kills the BEAM and takes the WHOLE cloud
             suite down — no failures reported, no summary, just an exit code.

             FIX: rename the file so it does not end in `_test.exs` (the runners in
             tier_lens_harness/ are named probe.exs / prove_lens.exs / rows.exs for
             exactly this reason), or move it out of cloud/test/.
             """
    end
  end
end
