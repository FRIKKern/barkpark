defmodule Barkpark.UserPrefsTest do
  @moduledoc "task-7d2a48dbf7e4bf34 — the context layer under UserPrefController."
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, UserPrefs}

  @dataset "production"

  defp user! do
    {:ok, user} =
      Accounts.register_user(%{
        email: "ctx-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  test "get/4 on an unset key returns nil" do
    ws = create_workspace!("ctx-#{System.unique_integer([:positive])}")
    assert UserPrefs.get(user!().id, ws.id, @dataset, "k") == nil
  end

  test "put/5 then get/4 round-trips" do
    ws = create_workspace!("ctx-#{System.unique_integer([:positive])}")
    user = user!()
    assert {:ok, pref} = UserPrefs.put(user.id, ws.id, @dataset, "k", %{"a" => 1})
    assert pref.value == %{"a" => 1}
    assert UserPrefs.get(user.id, ws.id, @dataset, "k") == %{"a" => 1}
  end

  test "put/5 is an upsert — a second call replaces, never appends" do
    ws = create_workspace!("ctx-#{System.unique_integer([:positive])}")
    user = user!()
    {:ok, _} = UserPrefs.put(user.id, ws.id, @dataset, "k", %{"a" => 1})
    {:ok, _} = UserPrefs.put(user.id, ws.id, @dataset, "k", %{"a" => 2})
    assert UserPrefs.get(user.id, ws.id, @dataset, "k") == %{"a" => 2}
  end

  test "delete/4 clears it, idempotently" do
    ws = create_workspace!("ctx-#{System.unique_integer([:positive])}")
    user = user!()
    {:ok, _} = UserPrefs.put(user.id, ws.id, @dataset, "k", %{"a" => 1})
    assert {:ok, 1} = UserPrefs.delete(user.id, ws.id, @dataset, "k")
    assert UserPrefs.get(user.id, ws.id, @dataset, "k") == nil
    assert {:ok, 0} = UserPrefs.delete(user.id, ws.id, @dataset, "k")
  end

  test "scoped independently by user, workspace, dataset and key" do
    ws_a = create_workspace!("ctx-a-#{System.unique_integer([:positive])}")
    ws_b = create_workspace!("ctx-b-#{System.unique_integer([:positive])}")
    user_a = user!()
    user_b = user!()

    {:ok, _} = UserPrefs.put(user_a.id, ws_a.id, @dataset, "k", %{"who" => "a-wsA"})
    {:ok, _} = UserPrefs.put(user_a.id, ws_b.id, @dataset, "k", %{"who" => "a-wsB"})
    {:ok, _} = UserPrefs.put(user_b.id, ws_a.id, @dataset, "k", %{"who" => "b-wsA"})
    {:ok, _} = UserPrefs.put(user_a.id, ws_a.id, "other_dataset", "k", %{"who" => "a-otherds"})
    {:ok, _} = UserPrefs.put(user_a.id, ws_a.id, @dataset, "other_key", %{"who" => "a-otherkey"})

    assert UserPrefs.get(user_a.id, ws_a.id, @dataset, "k") == %{"who" => "a-wsA"}
    assert UserPrefs.get(user_a.id, ws_b.id, @dataset, "k") == %{"who" => "a-wsB"}
    assert UserPrefs.get(user_b.id, ws_a.id, @dataset, "k") == %{"who" => "b-wsA"}
    assert UserPrefs.get(user_a.id, ws_a.id, "other_dataset", "k") == %{"who" => "a-otherds"}
    assert UserPrefs.get(user_a.id, ws_a.id, @dataset, "other_key") == %{"who" => "a-otherkey"}
  end

  test "a value over the 16KB cap is refused, and writes nothing" do
    ws = create_workspace!("ctx-#{System.unique_integer([:positive])}")
    user = user!()
    big = %{"blob" => String.duplicate("x", 20_000)}
    assert {:error, changeset} = UserPrefs.put(user.id, ws.id, @dataset, "k", big)
    assert "is too large" <> _ = errors_on(changeset).value |> List.first()
    assert UserPrefs.get(user.id, ws.id, @dataset, "k") == nil
  end
end
