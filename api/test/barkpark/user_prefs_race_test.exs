defmodule Barkpark.UserPrefsRaceTest do
  @moduledoc """
  task-f150278ead8dbfb3 — list ops (and task-e016c981d677f3aa's `set`) on
  one pref, on real connections. The
  sandbox puts every process on ONE connection, so a second writer would
  queue there and these tests would pass with the row lock deleted; they run
  `unboxed_run` and tear their rows down themselves.

  A holder connection takes the row first (locks it, or inserts it and
  leaves the insert uncommitted), so every op under test is provably
  waiting on it before the holder acts and commits.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Tenancy, UserPrefs}
  alias Barkpark.UserPrefs.UserPref

  @dataset "prefs_race"
  @key "recents"

  test "two concurrent push_front calls both land" do
    with_user(fn user, ws ->
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"ids" => ["old"]})
      holder = hold(lock_row(pref), fn -> :ok end)
      pushers = for id <- ["a", "b"], do: push_front_async(user, ws, id)

      await_lock_waiters(2)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = Enum.map(pushers, &Task.await(&1, 10_000))
      ids = UserPrefs.get(user.id, ws.id, @dataset, @key)["ids"]
      assert Enum.sort(ids) == ["a", "b", "old"]
      assert List.last(ids) == "old"
    end)
  end

  test "two first writes to an unset key both land" do
    with_user(fn user, ws ->
      holder = hold(fn -> UserPrefs.put(user.id, ws.id, @dataset, @key, %{}) end, fn -> :ok end)
      pushers = for id <- ["a", "b"], do: push_front_async(user, ws, id)

      await_lock_waiters(2)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = Enum.map(pushers, &Task.await(&1, 10_000))
      assert Enum.sort(UserPrefs.get(user.id, ws.id, @dataset, @key)["ids"]) == ["a", "b"]
    end)
  end

  test "a push_front waiting on a row that a DELETE removes still lands" do
    with_user(fn user, ws ->
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"ids" => ["old"]})

      holder =
        hold(lock_row(pref), fn ->
          Repo.delete_all(from p in UserPref, where: p.id == ^pref.id)
        end)

      pusher = push_front_async(user, ws, "a")

      await_lock_waiters(1)
      release(holder)

      assert {:ok, %{"ids" => ["a"]}} = Task.await(pusher, 10_000)
      assert UserPrefs.get(user.id, ws.id, @dataset, @key) == %{"ids" => ["a"]}
    end)
  end

  # task-e016c981d677f3aa: a read-change-PUT of the whole object loses one of
  # these two changes; `set` takes the row lock, so both land.
  test "two concurrent sets of different fields of one object both land" do
    with_user(fn user, ws ->
      bot = %{"name" => "old", "session_id" => "s0", "host" => "h"}
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, bot)
      holder = hold(lock_row(pref), fn -> :ok end)

      setters =
        for {field, item} <- [{"name", "renamed"}, {"session_id", "s1"}] do
          Task.async(fn ->
            unboxed(fn ->
              UserPrefs.apply_list_op(user.id, ws.id, @dataset, @key, {:set, field, item, nil})
            end)
          end)
        end

      await_lock_waiters(2)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = Enum.map(setters, &Task.await(&1, 10_000))

      assert UserPrefs.get(user.id, ws.id, @dataset, @key) ==
               %{"name" => "renamed", "session_id" => "s1", "host" => "h"}
    end)
  end

  # task-f88365602c49be57: two PUTs made from one read both carry its tag.
  # The compare and the write are one step under the row lock, so the second
  # sees the first's value and is refused; without the lock both would write.
  test "two concurrent PUTs with the same If-Match: one writes, the other is refused" do
    with_user(fn user, ws ->
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"name" => "old"})
      tag = UserPrefs.etag(pref.value)
      holder = hold(lock_row(pref), fn -> :ok end)

      putters =
        for name <- ["a", "b"] do
          Task.async(fn ->
            unboxed(fn ->
              UserPrefs.put_if_match(user.id, ws.id, @dataset, @key, %{"name" => name}, [tag])
            end)
          end)
        end

      await_lock_waiters(2)
      release(holder)

      results = Enum.map(putters, &Task.await(&1, 10_000))
      assert [{:ok, written}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, {:precondition_failed, actual}}] =
               Enum.reject(results, &match?({:ok, _}, &1))

      assert actual == UserPrefs.etag(written.value)
      assert UserPrefs.get(user.id, ws.id, @dataset, @key) == written.value
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

  defp lock_row(pref),
    do: fn -> Repo.one!(from p in UserPref, where: p.id == ^pref.id, lock: "FOR UPDATE") end

  defp hold(take, on_release) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            take.()
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
