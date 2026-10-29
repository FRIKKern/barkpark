defmodule Barkpark.UserPrefsRaceTest do
  @moduledoc """
  task-f150278ead8dbfb3 — two `push_front`s on the same pref, on two real
  connections, both land. The sandbox puts every process on ONE connection,
  so a second writer would queue there and the test would pass with the row
  lock deleted; this runs `unboxed_run` and tears its rows down itself.

  A third connection holds the row first, so both pushers are provably
  waiting on it at once. Without `FOR UPDATE` they would both read the old
  list and the second write would drop the first id.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Tenancy, UserPrefs}
  alias Barkpark.UserPrefs.UserPref

  @dataset "prefs_race"
  @key "recents"

  test "two concurrent push_front calls both land" do
    unboxed(fn ->
      n = System.unique_integer([:positive])
      ws = Barkpark.TenancyFixtures.create_workspace!("prefs-race-#{n}")

      {:ok, user} =
        Accounts.register_user(%{
          email: "prefs-race-#{n}@example.com",
          password: "correct-horse-battery"
        })

      try do
        {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, @key, %{"ids" => ["old"]})
        parent = self()

        holder =
          Task.async(fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                Repo.one!(from p in UserPref, where: p.id == ^pref.id, lock: "FOR UPDATE")
                send(parent, :held)

                receive do
                  :release -> :ok
                after
                  10_000 -> :timeout
                end
              end)
            end)
          end)

        assert_receive :held, 5_000

        pushers =
          for id <- ["a", "b"] do
            Task.async(fn ->
              unboxed(fn ->
                UserPrefs.apply_list_op(
                  user.id,
                  ws.id,
                  @dataset,
                  @key,
                  {:push_front, "ids", id, 20}
                )
              end)
            end)
          end

        await_lock_waiters(2)
        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 10_000)

        assert [{:ok, _}, {:ok, _}] = Enum.map(pushers, &Task.await(&1, 10_000))
        ids = UserPrefs.get(user.id, ws.id, @dataset, @key)["ids"]
        assert Enum.sort(ids) == ["a", "b", "old"]
        assert List.last(ids) == "old"
      after
        Repo.delete!(user)
        {:ok, _} = Tenancy.delete_workspace(ws)
      end
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
        flunk("only #{waiting} of #{n} pushers reached the row lock")

      true ->
        Process.sleep(20)
        await_lock_waiters(n, tries - 1)
    end
  end
end
