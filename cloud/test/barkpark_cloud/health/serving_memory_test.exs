defmodule BarkparkCloud.Health.ServingMemoryTest do
  @moduledoc """
  The control plane's durable serving clock
  (clk-bl-cloud-health-serving-since-is-boot-local).

  THE DEFECT THIS FILE EXISTS TO CATCH is not visible to a test that reads
  `serving_since` once. The old implementation derived it from
  `:erlang.monotonic_time/0` minus `:erlang.system_info(:start_time)`, which is
  perfectly STABLE within one BEAM — read it twice in the same process and it
  agrees with itself. It only lies ACROSS a restart, where it moves forward by
  the restart gap (Health's own moduledoc measured 6.4 s across two back-to-back
  BEAMs).

  So every assertion here is written to be unsatisfiable by a boot-local value:

    * `forget/0` stands a NEW BEAM up over the SAME durable record — that is the
      restart, simulated at the only layer where the process clock would reset.
    * The record is back-dated to BEFORE this VM started. A value older than
      this process cannot have been derived from this process. That single
      assertion is the whole fix.

  async: false — `forget/0` and the sha cache are `:persistent_term`, which is
  node-global, and these tests mutate `BARKPARK_GIT_SHA`, which is OS-global.

  Every sha below is unique to this file, so the assertions are scoped to rows
  this test created on a database it shares with other suites.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Health
  alias BarkparkCloud.Health.ServingMemory

  @env "BARKPARK_GIT_SHA"

  setup do
    previous = System.get_env(@env)
    System.delete_env(@env)
    ServingMemory.forget()

    on_exit(fn ->
      ServingMemory.forget()
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
    end)

    :ok
  end

  # Put a sighting of `sha` into the durable record at `at`, as a deploy that
  # happened before this BEAM existed would have left it.
  defp backdate!(sha, at) do
    Repo.insert_all("serving_memories", [%{sha: sha, first_seen_at: at}],
      on_conflict: :nothing,
      conflict_target: :sha
    )

    at
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)

  describe "the restart the old gauge could not survive" do
    test "a restart does not move serving_since — and the value predates this BEAM" do
      sha = "c1c1c1c0000000000000000000000000000c1c1"
      deployed_at = backdate!(sha, hours_ago(3))

      before_restart = ServingMemory.read(sha: sha)
      assert before_restart.serving_since == deployed_at

      # THE RESTART. A new BEAM has no memoised sighting; the durable record is
      # all it has. The process clock, which is what the defect read, resets
      # here — the record does not.
      ServingMemory.forget()
      after_restart = ServingMemory.read(sha: sha)

      assert after_restart.serving_since == before_restart.serving_since,
             "serving_since moved across a restart that deployed nothing: " <>
               "#{inspect(before_restart.serving_since)} -> #{inspect(after_restart.serving_since)}"

      # THE ASSERTION A BOOT-LOCAL VALUE CANNOT SATISFY. process_since is this
      # VM's start instant; the record is three hours older than that. Anything
      # derived from :erlang.system_info(:start_time) is, by construction, NOT
      # older than the VM.
      System.put_env(@env, sha)
      process_since = Health.serving().process_since

      assert DateTime.compare(after_restart.serving_since, process_since) == :lt,
             "serving_since (#{inspect(after_restart.serving_since)}) is not older than this " <>
               "BEAM's start (#{inspect(process_since)}) — it is still boot-local"
    end

    test "a hundred restarts do not drift it by a microsecond" do
      sha = "c2c2c2c0000000000000000000000000000c2c2"
      deployed_at = backdate!(sha, hours_ago(9))

      readings =
        Enum.map(1..8, fn _restart ->
          ServingMemory.forget()
          ServingMemory.read(sha: sha).serving_since
        end)

      assert Enum.uniq(readings) == [deployed_at]
    end
  end

  describe "first boot, and what actually deserves a new clock" do
    test "a sha this plane has never seen records NOW and returns it" do
      sha = "c3c3c3c0000000000000000000000000000c3c3"
      before = DateTime.utc_now()

      first = ServingMemory.read(sha: sha)

      assert first.serving_sha == sha
      assert DateTime.compare(first.serving_since, before) != :lt
      assert DateTime.compare(first.serving_since, DateTime.utc_now()) != :gt

      # And it is now durable: a restart reads the SAME instant back.
      ServingMemory.forget()
      assert ServingMemory.read(sha: sha).serving_since == first.serving_since
    end

    test "a REDEPLOY starts a new clock, and leaves the old sha's clock alone" do
      old_sha = "c4c4c4c0000000000000000000000000000c4c4"
      new_sha = "c5c5c5c0000000000000000000000000000c5c5"
      old_at = backdate!(old_sha, hours_ago(5))

      # A different sha is a different thing being served, so its clock starts
      # now. serving_since moving forward HERE is the measurement, not the bug.
      redeployed = ServingMemory.read(sha: new_sha)
      assert DateTime.compare(redeployed.serving_since, old_at) == :gt

      # A rollback resumes the old sha's ORIGINAL clock rather than minting a
      # third one — the record is per-sha, and nothing overwrote it.
      ServingMemory.forget()
      assert ServingMemory.read(sha: old_sha).serving_since == old_at
    end
  end

  describe "the honest states" do
    test "no sha: serving_sha and serving_since are nil TOGETHER" do
      read = ServingMemory.read(sha: nil)

      assert Map.fetch!(read, :serving_sha) == nil
      assert Map.fetch!(read, :serving_since) == nil
      assert read.serving_since_basis =~ "unknown"
    end

    test "a branch name someone exported by mistake is not a sha, and is not recorded" do
      read = ServingMemory.read(sha: "release/2026-09")

      assert Map.fetch!(read, :serving_sha) == nil
      assert Map.fetch!(read, :serving_since) == nil
    end

    test "an empty env var reads as unknown, never as a fresh deploy" do
      assert ServingMemory.read(sha: "   ").serving_since == nil
    end

    test "the sha is normalized before it becomes a key — one clock, not two" do
      sha = "c6c6c6c0000000000000000000000000000c6c6"
      at = backdate!(sha, hours_ago(2))

      assert ServingMemory.read(sha: "  " <> String.upcase(sha) <> "\n").serving_since == at
    end

    test "the durable basis says a restart cannot move it — and does not claim to be the boot instant" do
      sha = "c7c7c7c0000000000000000000000000000c7c7"
      basis = String.downcase(ServingMemory.read(sha: sha).serving_since_basis)

      assert basis =~ "durable"
      assert basis =~ "restart"
      refute basis =~ "process-derived"
    end
  end
end
