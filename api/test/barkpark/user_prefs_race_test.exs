defmodule Barkpark.UserPrefsRaceTest do
  @moduledoc """
  task-f150278ead8dbfb3 — list ops (and task-e016c981d677f3aa's `set`) on
  one pref, on real connections. The
  sandbox puts every process on ONE connection, so a second writer would
  queue there and these tests would pass with the row lock deleted; they run
  `unboxed_run` and tear their rows down themselves.

  A holder connection takes the row first (locks it, or inserts it and
  leaves the insert uncommitted), so every op under test is provably
  waiting on it before the holder acts and commits. Each op runs through
  `Barkpark.LockWaiter`, and the wait checks that op's own backend in this
  database (task-f12c42bbdaaeb965), so a lock waiter in another worktree's
  test database cannot release the holder early.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, LockWaiter, Tenancy, UserPrefs}
  alias Barkpark.UserPrefs.UserPref

  @dataset "prefs_race"
  @key "recents"

  test "two concurrent push_front calls both land" do
    with_user(fn user, ws ->
      {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"ids" => ["old"]})
      holder = hold(lock_row(pref), fn -> :ok end)
      pushers = start(for id <- ["a", "b"], do: fn -> push_front(user, ws, id) end)

      await_locks(pushers)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = await_all(pushers)
      ids = UserPrefs.get(user.id, ws.id, @dataset, @key)["ids"]
      assert Enum.sort(ids) == ["a", "b", "old"]
      assert List.last(ids) == "old"
    end)
  end

  test "two first writes to an unset key both land" do
    with_user(fn user, ws ->
      holder = hold(fn -> UserPrefs.put(user.id, ws.id, @dataset, @key, %{}) end, fn -> :ok end)
      pushers = start(for id <- ["a", "b"], do: fn -> push_front(user, ws, id) end)

      await_locks(pushers)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = await_all(pushers)
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

      pusher = start([fn -> push_front(user, ws, "a") end])

      await_locks(pusher)
      release(holder)

      assert [{:ok, %{"ids" => ["a"]}}] = await_all(pusher)
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
        start(
          for {field, item} <- [{"name", "renamed"}, {"session_id", "s1"}] do
            fn ->
              UserPrefs.apply_list_op(user.id, ws.id, @dataset, @key, {:set, field, item, nil})
            end
          end
        )

      await_locks(setters)
      release(holder)

      assert [{:ok, _}, {:ok, _}] = await_all(setters)

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
        start(
          for name <- ["a", "b"] do
            fn ->
              UserPrefs.put_if_match(user.id, ws.id, @dataset, @key, %{"name" => name}, [tag])
            end
          end
        )

      await_locks(putters)
      release(holder)

      results = await_all(putters)
      assert [{:ok, written}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, {:precondition_failed, actual}}] =
               Enum.reject(results, &match?({:ok, _}, &1))

      assert actual == UserPrefs.etag(written.value)
      assert UserPrefs.get(user.id, ws.id, @dataset, @key) == written.value
    end)
  end

  # task-c1f9452e1b8216ee: two creates of one unset key. A holder's insert,
  # uncommitted, makes both wait on the key; it then rolls back, so both find
  # the key unset and race the insert. Exactly one writes; the other sees the
  # winner's row and is refused, never written over it.
  test "two concurrent creates (If-None-Match: *) of one unset key: one writes, the other is refused" do
    with_user(fn user, ws ->
      holder =
        hold(
          fn -> UserPrefs.put(user.id, ws.id, @dataset, @key, %{"name" => "holder"}) end,
          fn -> Repo.rollback(:undo) end
        )

      creators =
        start(
          for name <- ["a", "b"] do
            fn -> UserPrefs.put_if_absent(user.id, ws.id, @dataset, @key, %{"name" => name}) end
          end
        )

      await_locks(creators)
      send(holder.pid, :release)
      assert {:error, :undo} = Task.await(holder, 10_000)

      results = await_all(creators)
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

  defp push_front(user, ws, id),
    do: UserPrefs.apply_list_op(user.id, ws.id, @dataset, @key, {:push_front, "ids", id, 20})

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  # Each op on its own connection, reporting its backend; every one of them
  # must be waiting on the holder's lock before the holder lets go.
  defp start(funs), do: Enum.map(funs, &LockWaiter.start/1)

  defp await_locks(ops),
    do: Enum.each(ops, fn {_task, backend} -> LockWaiter.await_lock!(backend) end)

  defp await_all(ops), do: Enum.map(ops, fn {task, _backend} -> Task.await(task, 10_000) end)
end
