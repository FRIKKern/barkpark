defmodule Barkpark.SharedTestDbTest do
  @moduledoc """
  BOTH ARMS of the shared-database detector (task-71dd1eb49e334fbb, criterion 0).

  A detector with only the positive arm cannot be shown to DISCRIMINATE: a
  function that returns a finding unconditionally passes every positive test
  ever written for it. So every probe below is driven from both directions, and
  the two real-database arms differ by ONE controlled fact — a single committed
  row, or a single threshold — with everything else held identical.

  The quiet arms are also checked for NON-VACUITY. `observe/2` degrades a failed
  probe to `:unavailable`, and an `:unavailable` probe produces no residue and no
  drift finding. "No findings" would therefore be the answer both for a clean
  database and for a database nobody looked at. Each real quiet arm asserts the
  probe RETURNED DATA before it asserts the data was clean.
  """
  use ExUnit.Case, async: false

  alias Barkpark.SharedTestDb
  alias Ecto.Adapters.SQL.Sandbox

  @probe_table "bp_shared_db_probe_w7"

  # ── pure layer: assess/1 and banner/1 ─────────────────────────────────────
  #
  # These fix the JUDGMENT against synthetic observations, so a change to the
  # SQL cannot quietly change what counts as a finding.

  defp clean_observation(overrides \\ %{}) do
    Map.merge(
      %{
        database: "barkpark_test_lane",
        partition: "lane",
        residue: [{"epic_assignments", 0}, {"share_links", 0}, {"documents", 0}],
        tables_inspected: ["epic_assignments", "share_links", "documents"],
        applied_versions: [20_260_101_000_000, 20_260_102_000_000],
        checkout_versions: [20_260_101_000_000, 20_260_102_000_000],
        concurrent_backends: 0,
        sibling_partitions: []
      },
      overrides
    )
  end

  test "a clean observation yields no findings and NO banner" do
    assert {:ok, []} = SharedTestDb.assess(clean_observation())
    assert SharedTestDb.banner(clean_observation()) == nil
  end

  describe "pollution class 1 — leftover Assignment rows" do
    test "fires, naming the table and the count" do
      obs = clean_observation(%{residue: [{"epic_assignments", 73}, {"share_links", 0}]})

      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:residue, "epic_assignments", 73} in findings
      # the quiet half of the SAME observation: a zero-count table is silent
      refute Enum.any?(findings, &match?({:residue, "share_links", _}, &1))

      banner = SharedTestDb.banner(obs)
      assert banner =~ SharedTestDb.token()
      assert banner =~ "epic_assignments"
      assert banner =~ "73"
    end

    test "stays quiet when every census table is empty" do
      obs = clean_observation(%{residue: [{"epic_assignments", 0}, {"share_links", 0}]})
      assert {:ok, []} = SharedTestDb.assess(obs)
    end
  end

  describe "pollution class 2 — a stale share_links token column (migration drift)" do
    test "a database carrying a migration this checkout does not have is DB-AHEAD" do
      obs =
        clean_observation(%{
          applied_versions: [20_260_101_000_000, 20_260_102_000_000, 20_260_103_999_999],
          checkout_versions: [20_260_101_000_000, 20_260_102_000_000]
        })

      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:migration_drift, :db_ahead_of_checkout, [20_260_103_999_999]} in findings
    end

    test "a database missing a checkout migration is DB-BEHIND (a mid-flight up/down test)" do
      obs =
        clean_observation(%{
          applied_versions: [20_260_101_000_000],
          checkout_versions: [20_260_101_000_000, 20_260_102_000_000]
        })

      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:migration_drift, :db_behind_checkout, [20_260_102_000_000]} in findings
    end

    test "stays quiet when the two sets are equal, INCLUDING when they are equal but unordered" do
      obs =
        clean_observation(%{
          applied_versions: [20_260_102_000_000, 20_260_101_000_000],
          checkout_versions: [20_260_101_000_000, 20_260_102_000_000]
        })

      assert {:ok, []} = SharedTestDb.assess(obs)
    end
  end

  describe "pollution class 3 — another partition using this database" do
    test "concurrent backends fire" do
      obs = clean_observation(%{concurrent_backends: 3})
      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:concurrent_backends, 3} in findings
    end

    test "zero concurrent backends is quiet" do
      assert {:ok, []} = SharedTestDb.assess(clean_observation(%{concurrent_backends: 0}))
    end

    test "live sibling partitions fire ONLY for a run that is itself unpartitioned" do
      loud = clean_observation(%{partition: nil, sibling_partitions: ["barkpark_test_w3"]})
      quiet = clean_observation(%{partition: "w7", sibling_partitions: ["barkpark_test_w3"]})

      assert {:ok, loud_findings} = SharedTestDb.assess(loud)
      assert {:sibling_partitions, ["barkpark_test_w3"]} in loud_findings

      assert {:ok, []} = SharedTestDb.assess(quiet)
    end
  end

  describe "a probe that could not run is reported, never read as clean" do
    test "an unavailable residue probe produces a finding that says so" do
      obs = clean_observation(%{residue: :unavailable})

      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:probe_unavailable, :residue} in findings

      banner = SharedTestDb.banner(obs)
      assert banner =~ "CANNOT tell you the database is clean"
    end

    test "an unavailable migration probe does not silently pass the drift check" do
      obs = clean_observation(%{applied_versions: :unavailable})
      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:probe_unavailable, :applied_versions} in findings
    end
  end

  # ── real layer: observe/2 against the live database ───────────────────────
  #
  # The pure tests above could all pass against SQL that queries the wrong
  # thing. These run the actual statements.

  describe "REAL: the residue census, controlled by one committed row" do
    setup do
      Sandbox.unboxed_run(Barkpark.Repo, fn ->
        Ecto.Adapters.SQL.query!(
          Barkpark.Repo,
          "CREATE TABLE IF NOT EXISTS \"#{@probe_table}\" (id serial primary key)",
          []
        )
      end)

      on_exit(fn ->
        Sandbox.unboxed_run(Barkpark.Repo, fn ->
          Ecto.Adapters.SQL.query!(Barkpark.Repo, "DROP TABLE IF EXISTS \"#{@probe_table}\"", [])
        end)
      end)

      :ok
    end

    test "empty table -> the census RAN, returned a count, and the banner is silent" do
      obs =
        Sandbox.unboxed_run(Barkpark.Repo, fn ->
          SharedTestDb.observe(Barkpark.Repo, tables: [@probe_table])
        end)

      # NON-VACUITY: refuse a clean verdict we cannot show was measured.
      assert obs.residue != :unavailable,
             "the residue probe did not run; a silent banner here would mean nothing"

      assert [{@probe_table, 0}] = obs.residue

      {:ok, findings} = SharedTestDb.assess(obs)
      refute Enum.any?(findings, &match?({:residue, _, _}, &1))
      refute Enum.any?(findings, &match?({:probe_unavailable, :residue}, &1))
    end

    test "one committed row -> the SAME census fires, naming the table" do
      obs =
        Sandbox.unboxed_run(Barkpark.Repo, fn ->
          Ecto.Adapters.SQL.query!(
            Barkpark.Repo,
            "INSERT INTO \"#{@probe_table}\" DEFAULT VALUES",
            []
          )

          SharedTestDb.observe(Barkpark.Repo, tables: [@probe_table])
        end)

      assert [{@probe_table, 1}] = obs.residue

      {:ok, findings} = SharedTestDb.assess(obs)
      assert {:residue, @probe_table, 1} in findings
      assert SharedTestDb.banner(obs) =~ @probe_table
    end
  end

  describe "REAL: the migration-set diff against the live database" do
    test "the live applied set and the checkout set are both non-empty and equal" do
      obs = Sandbox.unboxed_run(Barkpark.Repo, fn -> SharedTestDb.observe(Barkpark.Repo) end)

      # NON-VACUITY, both sides. Two empty lists also diff to no findings.
      assert is_list(obs.applied_versions) and obs.applied_versions != [],
             "schema_migrations probe returned #{inspect(obs.applied_versions)}"

      assert is_list(obs.checkout_versions) and obs.checkout_versions != [],
             "the checkout migration scan returned #{inspect(obs.checkout_versions)}"

      {:ok, findings} = SharedTestDb.assess(obs)

      drift = Enum.filter(findings, &match?({:migration_drift, _, _}, &1))

      assert drift == [],
             "this database's schema is not this checkout's: #{inspect(drift)}"
    end
  end

  describe "REAL: the concurrent-backend probe, controlled by the threshold alone" do
    test "a threshold our own pool satisfies counts backends; the shipped threshold does not" do
      {loud, quiet} =
        Sandbox.unboxed_run(Barkpark.Repo, fn ->
          {SharedTestDb.observe(Barkpark.Repo, backend_age_seconds: -3600),
           SharedTestDb.observe(Barkpark.Repo, backend_age_seconds: 30)}
        end)

      # Same SQL, same live pool, one number different. The loud arm proves the
      # statement can see backends at all — without it, the quiet arm's 0 could
      # be a query that matches nothing under any condition.
      assert is_integer(loud.concurrent_backends) and loud.concurrent_backends > 0,
             "the backend probe saw no connection even with an hour of slack; it measures nothing"

      assert quiet.concurrent_backends == 0,
             "our own pool is being counted as a foreign suite at the shipped threshold"

      {:ok, quiet_findings} = SharedTestDb.assess(quiet)
      refute Enum.any?(quiet_findings, &match?({:concurrent_backends, _}, &1))
    end
  end
end

defmodule Barkpark.TestCaptureTest do
  @moduledoc """
  Criterion 2: a truncated or garbled capture must not be mistakable for a
  result. Every fixture below is REAL ExUnit output, captured from this
  checkout; the unusable ones are that same capture with bytes removed, so the
  difference between the arms is the damage and nothing else.
  """
  use ExUnit.Case, async: true

  alias Barkpark.TestCapture

  @real_capture File.read!(
                  Path.expand(
                    "../support/fixtures/shared_test_db_real_exunit_capture.txt",
                    __DIR__
                  )
                )

  test "the undamaged capture reads as a result" do
    assert {:ok, %{tests: tests, failures: failures, seed: seed}} =
             TestCapture.read(@real_capture)

    assert is_integer(tests) and tests > 0
    assert is_integer(failures)
    assert is_integer(seed)
    assert TestCapture.describe(@real_capture) =~ ~r/\AUSABLE: \d+ tests, \d+ failures/
    assert %{exit_cause: nil} = elem(TestCapture.read(@real_capture), 1)
  end

  test "THE MEASURED FAILURE MODE: the same capture with the seed line removed is UNUSABLE" do
    damaged =
      @real_capture
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~r/\A(?:Running ExUnit with seed: |Randomized with seed )/))
      |> Enum.join("\n")

    # The summary line is still there and still perfectly plausible.
    assert damaged =~ ~r/\d+ tests?, \d+ failures?/

    assert {:unusable, reasons} = TestCapture.read(damaged)
    assert :no_seed_line in reasons

    line = TestCapture.describe(damaged)
    assert String.starts_with?(line, "UNUSABLE")
    assert line =~ "no ExUnit seed line"
    refute line =~ ~r/\A\S*\s*\d+ tests/
  end

  test "'2 failures' with no failure bodies is UNUSABLE, not two findings" do
    # This is the exact shape of the session's second measurement.
    capture =
      "Running ExUnit with seed: 123456, max_cases: 8\n\nFinished in 40.0 seconds\n1911 tests, 2 failures\n"

    assert {:unusable, reasons} = TestCapture.read(capture)
    assert {:failure_bodies_missing, 0, 2} in reasons
    assert TestCapture.describe(capture) =~ "carries 0 failure body"
  end

  test "a real failure WITH its body reads as a result" do
    capture = """
    Running ExUnit with seed: 987654, max_cases: 8

      1) test it works (Some.Test)
         test/some_test.exs:4
         Assertion with == failed
         code:  assert 1 == 2

    Finished in 0.1 seconds
    3 tests, 1 failure
    """

    assert {:ok, %{tests: 3, failures: 1, seed: 987_654, bodies: 1}} = TestCapture.read(capture)
  end

  test "a capture with no summary line at all is UNUSABLE" do
    assert {:unusable, reasons} =
             TestCapture.read("Running ExUnit with seed: 1, max_cases: 8\nCompiling 3 files\n")

    assert :no_summary_line in reasons
  end

  describe "a capture whose exit code is not its failure count" do
    # MEASURED on run 35662807156 (PR #19715): `0 failures` and exit 1, with the
    # cause printed 2,567 lines earlier. Two readers in one evening quoted the
    # summary alone and drew the wrong conclusion from it.
    test "a 0-failure summary carrying a NODE-GLOBAL LEAK banner refuses to be quoted alone" do
      capture = """
      Running ExUnit with seed: 343107, max_cases: 1

      ================================================================
      NODE-GLOBAL LEAK: :barkpark, :boot_mode left set by a MODULE
      ================================================================

        module:            Barkpark.Plugins.OnixEdit.Tasks.BokbasenListTest
        value left behind: :one_shot

      30 doctests, 22051 tests, 0 failures, 33 excluded
      """

      # The counts are REAL, so this is not `:unusable` — that would be the
      # wrong verdict and would send a reader to re-run a run that measured fine.
      assert {:ok, %{tests: 22_051, failures: 0, exit_cause: why}} = TestCapture.read(capture)
      assert why =~ "NODE-GLOBAL LEAK"

      line = TestCapture.describe(capture)
      assert line =~ "THE EXIT CODE IS NOT THE FAILURE COUNT"
      assert line =~ "22051 tests, 0 failures"
    end

    test "THE QUIET ARM: the same summary without the banner carries no exit cause" do
      capture = """
      Running ExUnit with seed: 343107, max_cases: 1

      30 doctests, 22051 tests, 0 failures, 33 excluded
      """

      assert {:ok, %{tests: 22_051, failures: 0, exit_cause: nil}} = TestCapture.read(capture)
      assert String.starts_with?(TestCapture.describe(capture), "USABLE: 22051 tests")
    end

    test "the EXIT-CAUSE line test_helper prints is recognised on its own" do
      capture = """
      Running ExUnit with seed: 1, max_cases: 1

      3 tests, 0 failures

      EXIT-CAUSE: this run exits NON-ZERO and its "N tests, M failures" line does NOT explain it.
      """

      assert {:ok, %{exit_cause: why}} = TestCapture.read(capture)
      assert why =~ "EXIT-CAUSE"
    end
  end

  test "a doctest-prefixed summary is still read correctly" do
    capture = "Running ExUnit with seed: 42, max_cases: 8\n\n5 doctests, 1764 tests, 0 failures\n"
    assert {:ok, %{tests: 1764, failures: 0}} = TestCapture.read(capture)
  end
end
