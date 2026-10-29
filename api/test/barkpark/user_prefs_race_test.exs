defmodule Barkpark.UserPrefsRaceTest do
  @moduledoc """
  task-f150278ead8dbfb3 — list ops on one pref, on real connections. The
  sandbox puts every process on ONE connection, so a second writer would
  queue there and these tests would pass with the row lock deleted; they run
  `unboxed_run` and tear their rows down themselves.

  A holder connection takes the row first, so every op under test is
  provably waiting on it before the holder acts and commits.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Tenancy, UserPrefs}
  alias Barkpark.UserPrefs.UserPref

  @dataset "prefs_race"
  @key "recents"

  test "two concurrent push_front calls both land" do
    with_user(fn user, ws ->
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"ids" => ["old"]})
      holder = hold(pref, fn -> :ok end)
      pushers = for id <- ["a", "b"], do: push_front_async(user, ws, id)

      await_lock_waiters(2)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = Enum.map(pushers, &Task.await(&1, 10_000))
      ids = UserPrefs.get(user.id, ws.id, @dataset, @key)["ids"]
      assert Enum.sort(ids) == ["a", "b", "old"]
      assert List.last(ids) == "old"
    end)
  end

  test "a push_front waiting on a row that a DELETE removes still lands" do
    with_user(fn user, ws ->
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"ids" => ["old"]})
      holder = hold(pref, fn -> Repo.delete_all(from p in UserPref, where: p.id == ^pref.id) end)
      pusher = push_front_async(user, ws, "a")

      await_lock_waiters(1)
      release(holder)

      assert {:ok, %{"ids" => ["a"]}} = Task.await(pusher, 10_000)
      assert UserPrefs.get(user.id, ws.id, @dataset, @key) == %{"ids" => ["a"]}
    end)
  end

  defp with_user(fun) do
    unboxed(fn ->
      n = System.unique_integer([:positive])
      ws = Barkpark.TenancyFixtures.create_workspace!("prefs-race-#{n}")

      {:ok, user} =
        Accounts.register_user(%{
          email: "prefs-race-#{n}@example.com",
          password: "correct-horse-battery"
        })

      try do
        fun.(user, ws)
      after
        Repo.delete!(user)
        {:ok, _} = Tenancy.delete_workspace(ws)
      end
    end)
  end

  defp hold(pref, on_release) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.one!(from p in UserPref, where: p.id == ^pref.id, lock: "FOR UPDATE")
            send(parent, :held)

            receive do
              :release ->
                on_release.()
                :ok
            after
              10_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive :held, 5_000
    holder
  end

  defp release(holder) do
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
  end

  defp push_front_async(user, ws, id) do
    Task.async(fn ->
      unboxed(fn ->
        UserPrefs.apply_list_op(user.id, ws.id, @dataset, @key, {:push_front, "ids", id, 20})
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp await_lock_waiters(n, tries \\ 250) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query ILIKE '%user_prefs%'"
      )

    cond do
      waiting >= n ->
        :ok

      tries == 0 ->
        flunk("only #{waiting} of #{n} ops reached the row lock")

      true ->
        Process.sleep(20)
        await_lock_waiters(n, tries - 1)
    end
  end
end
