defmodule Barkpark.Release.EntrypointEvalScopeTest do
  @moduledoc """
  `api/entrypoint.sh` may only `bin/barkpark eval` an entry point whose BOOT
  SCOPE has been proven (task shb-bl-release-load-app).

  The defect this row was filed for was not a bug inside `Release.migrate/0`;
  it was a bug in WHAT THE CONTAINER EVALS. A first-ever boot ran
  `Barkpark.Release.migrate()` while `load_app/0` was
  `Application.ensure_all_started/1`, so the whole tree — `BarkparkWeb.Endpoint`
  included — came up against a schema with no tables and a stranger's first log
  was a crash storm. The two fixes (`Application.load/1` for migrate,
  `seed_boot!/0`'s `:seed` mode for seed) are each guarded by their own test:

    * `Barkpark.Release.LoadAppBootScopeTest` — `load_app/0` starts nothing, on
      a fresh `:peer` node;
    * `Barkpark.ApplicationBootModeTest` — `:seed` mode drops the Endpoint and
      makes Oban inert, and `seed/0` calls `seed_boot!/0`.

  Neither notices a THIRD eval line, or an eval swapped to `start_app/0` — both
  reopen the exact defect while every existing test stays green. That is the
  hole this file covers, and it is the reason the allowlist is keyed by the
  proven function rather than by "looks like a Release call".

  This is the CHEAP, always-on arm. The expensive arm —
  `api/scripts/release-cold-boot-check.sh` — drives a real assembled release
  against a real empty database, because a release-only property is invisible
  to `mix test` by construction.

  Anti-vacuity: the same private predicate that judges the real file is run
  against fixtures that MUST be rejected, so a parser that finds no eval calls
  at all (or a predicate that returns `:ok` for everything) fails here.
  """

  use ExUnit.Case, async: true

  @entrypoint Path.expand("../../../entrypoint.sh", __DIR__)

  # Entry points whose boot scope is PROVEN by a named test. Adding a line to
  # this list without adding that proof is the thing the file exists to stop.
  @proven_evals %{
    "Barkpark.Release.migrate()" => "Barkpark.Release.LoadAppBootScopeTest",
    "Barkpark.Release.seed()" => "Barkpark.ApplicationBootModeTest"
  }

  describe "the real entrypoint" do
    test "exists and is the file the container runs" do
      assert File.regular?(@entrypoint),
             "no entrypoint at #{@entrypoint} — every assertion below is vacuous"
    end

    test "every `bin/barkpark eval` names a boot-scope-proven entry point" do
      calls = eval_calls(File.read!(@entrypoint))

      # Precondition, not decoration: if the parser finds nothing, `Enum.each`
      # over it passes trivially.
      assert length(calls) >= 2,
             "parsed #{length(calls)} eval calls out of entrypoint.sh — the parser is blind"

      assert :ok = audit(File.read!(@entrypoint))
    end

    test "the eval steps are exactly the two proven ones, in migrate-then-seed order" do
      assert eval_calls(File.read!(@entrypoint)) == [
               "Barkpark.Release.migrate()",
               "Barkpark.Release.seed()"
             ]
    end

    test "the serving boot is the LAST command, so no eval can run after it" do
      assert :ok = audit(File.read!(@entrypoint))

      last =
        File.read!(@entrypoint)
        |> String.split("\n", trim: true)
        |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
        |> List.last()

      assert last =~ ~r/bin\/barkpark start/,
             "the last command is #{inspect(last)}, not the serving boot"
    end
  end

  describe "the predicate rejects what it must (controls)" do
    test "an eval of an unproven entry point is rejected" do
      script = """
      #!/bin/sh
      bin/barkpark eval "Barkpark.Release.migrate()"
      bin/barkpark eval "Barkpark.Release.start_app()"
      exec bin/barkpark start
      """

      assert {:error, reason} = audit(script)
      assert reason =~ "Barkpark.Release.start_app()"
    end

    test "a third eval line nobody proved is rejected" do
      script = """
      #!/bin/sh
      bin/barkpark eval "Barkpark.Release.migrate()"
      bin/barkpark eval "Barkpark.Release.seed()"
      bin/barkpark eval "Barkpark.Backfill.run()"
      exec bin/barkpark start
      """

      assert {:error, reason} = audit(script)
      assert reason =~ "Barkpark.Backfill.run()"
    end

    test "an entrypoint that never boots the server is rejected" do
      script = """
      #!/bin/sh
      bin/barkpark eval "Barkpark.Release.migrate()"
      bin/barkpark eval "Barkpark.Release.seed()"
      """

      assert {:error, reason} = audit(script)
      assert reason =~ "bin/barkpark start"
    end

    test "the predicate ACCEPTS the shape it is supposed to accept" do
      # Without this, every rejection above could come from a predicate that
      # rejects everything.
      script = """
      #!/bin/sh
      set -e
      bin/barkpark eval "Barkpark.Release.migrate()"
      bin/barkpark eval "Barkpark.Release.seed()"
      exec bin/barkpark start
      """

      assert :ok = audit(script)
    end

    test "a commented-out eval is not counted (the parser reads commands, not prose)" do
      script = """
      #!/bin/sh
      # bin/barkpark eval "Barkpark.Release.start_app()"
      bin/barkpark eval "Barkpark.Release.migrate()"
      bin/barkpark eval "Barkpark.Release.seed()"
      exec bin/barkpark start
      """

      assert :ok = audit(script)
      assert eval_calls(script) == ["Barkpark.Release.migrate()", "Barkpark.Release.seed()"]
    end
  end

  # ── the predicate under test ────────────────────────────────────────────
  defp audit(contents) do
    unproven = Enum.reject(eval_calls(contents), &Map.has_key?(@proven_evals, &1))

    cond do
      unproven != [] ->
        {:error,
         "entrypoint evals an entry point with no proven boot scope: " <>
           Enum.join(unproven, ", ") <>
           " — prove it starts no endpoint, then add it to @proven_evals"}

      not starts_server?(contents) ->
        {:error, "entrypoint never reaches `bin/barkpark start`"}

      true ->
        :ok
    end
  end

  defp eval_calls(contents) do
    contents
    |> command_lines()
    |> Enum.flat_map(fn line ->
      Regex.scan(~r/bin\/barkpark\s+eval\s+["']([^"']+)["']/, line, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp starts_server?(contents) do
    Enum.any?(command_lines(contents), &(&1 =~ ~r/bin\/barkpark\s+start\b/))
  end

  defp command_lines(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end
