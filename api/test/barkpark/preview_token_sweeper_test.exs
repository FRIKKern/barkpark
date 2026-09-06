defmodule Barkpark.PreviewToken.SweeperTest do
  @moduledoc """
  clk-bl-idempotency-preview-token-sweeps-have-no-caller, PreviewToken half.

  RED before this row: `PreviewToken.sweep/1` existed and `git grep -rn
  'PreviewToken.sweep' origin/main` matched exactly two call sites, both in
  `test/barkpark/preview_token_test.exs`. Nothing in `lib/`, nothing in the
  Oban crontab, nothing in the supervision tree. `preview_token_jti` was
  therefore APPEND-ONLY in production — a row per preview request, retained
  forever, on a table `record_jti/1` INSERTs into and `revoked?/1` SELECTs from
  on the hot path of every preview-token request.

  These tests pin three things:

    * the sweep is BOUNDED per statement (`sweep_batch/1`), so a cold first
      pass over a never-swept table is not one giant transaction;
    * it is SCHEDULED — the crontab entry exists and names this worker (an
      unwired worker reads exactly like a wired one from its own tests);
    * deleting a row does NOT reopen replay, which is the safety property the
      `@grace_seconds` window exists to protect.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.PreviewToken
  alias Barkpark.PreviewToken.Sweeper
  alias Barkpark.Repo

  @secret "sweeper-test-secret-vvvvvvvvvvvvvvvv"

  defp stringify(claims), do: Map.new(claims, fn {k, v} -> {to_string(k), v} end)

  # Record a JTI whose `expires_at` is `age_seconds` in the PAST. The sweep
  # cutoff is `now - @grace_seconds`, so anything older than 3600s is eligible.
  defp record_expired!(label, age_seconds) do
    {_, claims} = PreviewToken.sign(%{dataset: "production", doc_ids: [label]}, @secret)
    string_claims = stringify(claims)
    {:ok, _} = PreviewToken.record_jti(string_claims)

    at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

    from(j in "preview_token_jti", where: j.jti == ^string_claims["jti"])
    |> Repo.update_all(set: [expires_at: at])

    string_claims["jti"]
  end

  defp count, do: Repo.aggregate(from(j in "preview_token_jti"), :count)

  setup do
    # This suite counts rows in a table other cases also write, so start from a
    # known floor. The sandbox owns the connection, so this is test-local.
    Repo.delete_all(from(j in "preview_token_jti"))
    :ok
  end

  describe "sweep_batch/1 — bounded by construction" do
    test "one statement takes at most :sweep_batch_limit, oldest first" do
      for n <- 1..5, do: record_expired!("bounded-#{n}", 7200 + n * 60)

      prev = Application.get_env(:barkpark, :preview_token, [])
      Application.put_env(:barkpark, :preview_token, Keyword.put(prev, :sweep_batch_limit, 2))
      on_exit(fn -> Application.put_env(:barkpark, :preview_token, prev) end)

      # BOUNDED: one statement takes the limit, never the whole backlog.
      assert PreviewToken.sweep_batch() == 2
      assert count() == 3
    end

    test "returns 0 over an empty backlog — the loop terminator" do
      assert PreviewToken.sweep_batch() == 0
    end

    test "leaves rows still inside the grace window alone" do
      # Expired 10 minutes ago: past `exp`, but well inside the 3600s grace.
      record_expired!("young", 600)

      assert PreviewToken.sweep_batch() == 0
      assert count() == 1
    end
  end

  describe "Sweeper.sweep/1 — the worker" do
    test "a tick removes expired rows and leaves in-grace ones" do
      old = record_expired!("old", 48 * 3600)
      young = record_expired!("young", 600)

      assert %{deleted: 1} = Sweeper.sweep()

      refute jti_present?(old)
      assert jti_present?(young)
    end

    test "a tick over an empty backlog is a no-op, not an error" do
      assert %{deleted: 0, passes: 1} = Sweeper.sweep()
    end

    test "the loop finishes a backlog deeper than one batch" do
      for n <- 1..5, do: record_expired!("deep-#{n}", 7200 + n * 60)

      prev = Application.get_env(:barkpark, :preview_token, [])
      Application.put_env(:barkpark, :preview_token, Keyword.put(prev, :sweep_batch_limit, 2))
      on_exit(fn -> Application.put_env(:barkpark, :preview_token, prev) end)

      # 2 + 2 + 1 deleting passes, plus the terminating empty one.
      assert %{deleted: 5, passes: 4} = Sweeper.sweep()
      assert count() == 0
    end
  end

  # THE WIRE. A worker nothing schedules is the defect this row is about.
  # Assert the SCHEDULE by reading the same crontab Oban is configured with, so
  # deleting the entry reds here — the module's own tests cannot tell a wired
  # worker from an unwired one.
  test "the sweeper is actually scheduled in the Oban crontab" do
    crontab =
      Application.get_env(:barkpark, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _ -> nil
      end)

    assert Enum.any?(crontab, fn
             {_expr, Sweeper} -> true
             {_expr, Sweeper, _opts} -> true
             _ -> false
           end),
           "Barkpark.PreviewToken.Sweeper is not in the crontab — preview_token_jti grows forever again"
  end

  # The sweep deletes REPLAY-PROTECTION rows, so the one thing it must never do
  # is make an expired token usable again. It cannot: `verify/2` runs
  # `check_expiry` BEFORE `check_revocation`, so a token past `exp` is rejected
  # whether or not its JTI row survives. The `@grace_seconds` window is the
  # clock-skew margin on top of that. Pin it, because a future refactor that
  # reordered those checks would turn this GC into a replay hole.
  test "sweeping a row does not make its expired token usable again" do
    now = System.system_time(:second)
    {jwt, claims} = PreviewToken.sign(%{dataset: "production", exp: now - 7200}, @secret)
    string_claims = stringify(claims)
    {:ok, _} = PreviewToken.record_jti(string_claims)

    assert {:error, :expired} = PreviewToken.verify(jwt, @secret)

    assert %{deleted: 1} = Sweeper.sweep()
    refute jti_present?(string_claims["jti"])

    # Row gone, token STILL rejected — on expiry, not on the missing row.
    assert {:error, :expired} = PreviewToken.verify(jwt, @secret)
  end

  defp jti_present?(jti) do
    Repo.exists?(from(j in "preview_token_jti", where: j.jti == ^jti))
  end
end
