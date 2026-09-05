defmodule Barkpark.Idempotency.SweeperTest do
  @moduledoc """
  bl-api-task-create-idempotency, C4 — the GC story for the dedup store.

  RED before this row: `Idempotency.sweep/1` existed and `grep -rn
  'Idempotency.sweep' api/` matched exactly one call site — `idempotency_test.exs`.
  Nothing in `lib/`, nothing in the crontab. `idempotency_keys` was append-only
  in production, every row carrying a full cached response body.

  These tests pin the two halves of the remedy: the sweep is BOUNDED per
  statement (so a cold first pass over a long-unswept table is not one giant
  transaction), and it is SCHEDULED (the crontab entry exists and names this
  worker).
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Idempotency
  alias Barkpark.Idempotency.Key
  alias Barkpark.Idempotency.Sweeper
  alias Barkpark.Repo

  defp store_aged!(raw, age_seconds) do
    hash = Idempotency.hash_key(raw, "tok-sweeper", "POST", "/v1/data/mutate/production")
    Idempotency.store(hash, "mutation", 200, ~s({"results":[]}), [])

    at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)
    from(k in Key, where: k.key_hash == ^hash) |> Repo.update_all(set: [inserted_at: at])
    hash
  end

  setup do
    # This suite counts rows in a table other cases also write, so start from a
    # known floor. The sandbox owns the connection, so this is test-local.
    Repo.delete_all(Key)
    :ok
  end

  test "a tick removes expired rows and leaves fresh ones" do
    old = store_aged!("sweeper-old", 48 * 3600)
    fresh = store_aged!("sweeper-fresh", 60)

    assert %{deleted: 1} = Sweeper.sweep()

    assert :miss = Idempotency.lookup(old)
    assert {:ok, _} = Idempotency.lookup(fresh)
  end

  test "a tick over an empty backlog is a no-op, not an error" do
    assert %{deleted: 0, passes: 1} = Sweeper.sweep()
  end

  test "one statement is bounded by :sweep_batch_limit, and the loop finishes the backlog" do
    for n <- 1..5, do: store_aged!("bounded-#{n}", 48 * 3600)

    prev = Application.get_env(:barkpark, :idempotency, [])
    Application.put_env(:barkpark, :idempotency, Keyword.put(prev, :sweep_batch_limit, 2))
    on_exit(fn -> Application.put_env(:barkpark, :idempotency, prev) end)

    # BOUNDED: one statement takes at most the limit, never the whole backlog.
    assert Idempotency.sweep_batch() == 2

    # COMPLETE: the worker loops until the backlog is gone — 3 left, 2 passes
    # that delete plus the terminating empty one.
    assert %{deleted: 3, passes: 3} = Sweeper.sweep()
    assert Repo.aggregate(Key, :count) == 0
  end

  # A worker nothing schedules is the defect this row is about. Assert the
  # SCHEDULE, not just the code — reading the same crontab Oban is configured
  # with, so deleting the entry reds here.
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
           "Barkpark.Idempotency.Sweeper is not in the crontab — the key table grows forever again"
  end
end
