defmodule BarkparkCloud.SharedTestDbTest do
  @moduledoc """
  The cloud port of api's per-checkout database + drift red
  (task-b169445c9f0031b3, mirroring #20107 / api/test/barkpark/shared_test_db_test.exs).

  Every arm is driven from both directions, and each REAL quiet arm asserts the
  probe RETURNED DATA before it asserts the data was clean: `observe/2` degrades
  a failed probe to `:unavailable`, and "no drift" would otherwise be the answer
  both for a clean database and for one nobody looked at.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.SharedTestDb
  alias Ecto.Adapters.SQL.Sandbox

  defp clean_observation(overrides \\ %{}) do
    Map.merge(
      %{
        database: "barkpark_cloud_test_lane",
        partition: "lane",
        partition_source: :explicit,
        applied_versions: [20_260_101_000_000, 20_260_102_000_000],
        checkout_versions: [20_260_101_000_000, 20_260_102_000_000]
      },
      overrides
    )
  end

  describe "pure: the drift predicate" do
    test "a clean observation yields no findings and no drift report" do
      assert {:ok, []} = SharedTestDb.assess(clean_observation())
      assert SharedTestDb.drift_report(clean_observation()) == nil
    end

    test "equal sets in a different order are still clean" do
      obs = clean_observation(%{applied_versions: [20_260_102_000_000, 20_260_101_000_000]})
      assert {:ok, []} = SharedTestDb.assess(obs)
    end

    test "a database carrying a version this checkout lacks is DB-AHEAD, named with its database" do
      obs =
        clean_observation(%{
          applied_versions: [20_260_101_000_000, 20_260_102_000_000, 20_260_103_999_999]
        })

      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:migration_drift, :db_ahead_of_checkout, [20_260_103_999_999]} in findings

      report = SharedTestDb.drift_report(obs)
      assert report =~ "20260103999999"
      assert report =~ ~s("barkpark_cloud_test_lane")
      assert report =~ ~s("lane")
      assert report =~ "another branch migrated this database"
    end

    test "a database missing a checkout version is DB-BEHIND" do
      obs = clean_observation(%{applied_versions: [20_260_101_000_000]})

      assert {:ok, findings} = SharedTestDb.assess(obs)
      assert {:migration_drift, :db_behind_checkout, [20_260_102_000_000]} in findings
      assert SharedTestDb.drift_report(obs) =~ "is missing migration(s) 20260102000000"
    end

    test "drift_report names EVERY version, not a preview" do
      many = Enum.map(1..5, &(20_260_200_000_000 + &1))

      obs =
        clean_observation(%{applied_versions: [20_260_101_000_000, 20_260_102_000_000 | many]})

      report = SharedTestDb.drift_report(obs)
      for v <- many, do: assert(report =~ Integer.to_string(v))
    end

    test "an unavailable probe is a finding, never a silent clean" do
      obs = clean_observation(%{applied_versions: :unavailable})
      assert {:ok, [{:probe_unavailable, :applied_versions}]} = SharedTestDb.assess(obs)
    end
  end

  describe "REAL: the migration-set diff against the live database" do
    test "the live applied set and the checkout set are both non-empty and equal" do
      obs =
        Sandbox.unboxed_run(BarkparkCloud.Repo, fn ->
          SharedTestDb.observe(BarkparkCloud.Repo)
        end)

      # NON-VACUITY, both sides. Two empty lists also diff to no findings.
      assert is_list(obs.applied_versions) and obs.applied_versions != [],
             "schema_migrations probe returned #{inspect(obs.applied_versions)}"

      assert is_list(obs.checkout_versions) and obs.checkout_versions != [],
             "the checkout migration scan returned #{inspect(obs.checkout_versions)}"

      {:ok, findings} = SharedTestDb.assess(obs)
      drift = Enum.filter(findings, &match?({:migration_drift, _, _}, &1))

      assert drift == [],
             "this database's schema is not this checkout's: " <>
               "#{SharedTestDb.drift_report(obs)} (raw: #{inspect(drift)})"
    end
  end

  describe "REAL: the ahead-of-checkout red, forced, names the version and the database" do
    # The fake version is inserted INSIDE this test's sandbox transaction, so it
    # is never committed: `observe/2` runs in this process on the sandbox
    # connection and sees it, every other connection does not, and the rollback
    # at test end removes it even if the test crashes. 9999-12-31 23:59:59 is
    # later than any migration a checkout can carry.
    @fake_version 99_991_231_235_959

    test "an uncommitted foreign schema_migrations row reds with version AND database" do
      :ok = Sandbox.checkout(BarkparkCloud.Repo)

      Ecto.Adapters.SQL.query!(
        BarkparkCloud.Repo,
        "INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, now())",
        [@fake_version]
      )

      obs = SharedTestDb.observe(BarkparkCloud.Repo)

      # NON-VACUITY: the probe ran against the database this suite is on.
      assert obs.database == BarkparkCloud.Repo.config()[:database]
      assert is_list(obs.applied_versions) and @fake_version in obs.applied_versions
      refute @fake_version in obs.checkout_versions

      # `@fake_version in ahead`, not `ahead == [@fake_version]`: on a database
      # that has REAL drift the ahead list also carries that version, and the
      # one red this file should show then is the drift test above, not this one.
      {:ok, findings} = SharedTestDb.assess(obs)
      ahead = for {:migration_drift, :db_ahead_of_checkout, vs} <- findings, v <- vs, do: v
      assert @fake_version in ahead

      report = SharedTestDb.drift_report(obs)
      assert report =~ Integer.to_string(@fake_version)
      assert report =~ inspect(obs.database)
      assert report =~ "chosen by"
    end

    test "CONTROL: the fake version never reached any other connection" do
      applied =
        Sandbox.unboxed_run(BarkparkCloud.Repo, fn ->
          %{rows: rows} =
            Ecto.Adapters.SQL.query!(
              BarkparkCloud.Repo,
              "SELECT version FROM schema_migrations WHERE version = $1",
              [@fake_version]
            )

          rows
        end)

      assert applied == []
    end
  end

  describe "which database this run is on" do
    test "the always-printed line names the database, the partition, and why" do
      line = SharedTestDb.which_line(clean_observation())
      assert line =~ "BARKPARK-CLOUD-TEST-DB"
      assert line =~ ~s("barkpark_cloud_test_lane")
      assert line =~ "MIX_TEST_PARTITION (set explicitly)"

      default =
        SharedTestDb.which_line(
          clean_observation(%{partition: "_wt_x_1", partition_source: :worktree_default})
        )

      assert default =~ "per-checkout default"

      ci = SharedTestDb.which_line(clean_observation(%{partition: nil, partition_source: :ci}))
      assert ci =~ "unpartitioned"
      assert ci =~ "CI"
    end

    test "the live run's partition comes from config, and matches the database name" do
      %{suffix: suffix} = Application.fetch_env!(:barkpark_cloud, :test_db_partition)
      assert BarkparkCloud.Repo.config()[:database] == "barkpark_cloud_test" <> suffix
    end
  end
end
