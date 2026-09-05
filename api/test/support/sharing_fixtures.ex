defmodule Barkpark.SharingFixtures do
  @moduledoc """
  The ONE way a test plants a scoped share — refresh-proof by construction.

  ## The hazard this closes (arpss-w8)

  `Barkpark.Sharing.refresh/0` recomputes the live list as
  `shares_env() ++ list_stored()`. A share planted by a bare
  `Application.put_env(:barkpark, :shares, …)` is in NEITHER input, so the very
  next `refresh/0` — fired by `Sharing.add_share/1`, `Sharing.remove_share/3`,
  `POST`/`DELETE /v1/shares`, and the Studio `shares-add`/`shares-remove`
  handlers — ERASES it. The failure is a fake GREEN, not a red: a cross-tenant
  proof whose baseline share silently vanished asserts over an empty registry,
  so `refute status == 201` passes with the confinement code deleted.

  `plant_shares!/1` writes a real `StoredShare` row inside the test's sandbox
  transaction, so `list_stored/0` rebuilds the fixture on EVERY refresh and it
  rolls back at test end. `snapshot_shares!/0` saves and restores BOTH keys —
  `:shares` and `:shares_env` — because `refresh/0` reads the second one and a
  suite that restores only the first leaks an env baseline into its neighbours.

  ## Trap

  `Sharing.parse/1` splits entries on `";"`, never on `","` (commas separate
  SURFACES inside one entry). A comma-joined multi-scope string is one
  malformed entry and is dropped whole — silently under `put_env`, loudly here.
  """

  alias Barkpark.Repo
  alias Barkpark.Sharing
  alias Barkpark.Sharing.StoredShare

  @doc """
  Snapshot `:shares` AND `:shares_env`, restoring both `on_exit`.

  Safe to call more than once in a test: `on_exit` callbacks run LIFO, so the
  earliest snapshot is restored last and the original value wins.
  """
  @spec snapshot_shares!() :: :ok
  def snapshot_shares! do
    prior = Application.fetch_env(:barkpark, :shares)
    prior_env = Application.fetch_env(:barkpark, :shares_env)

    ExUnit.Callbacks.on_exit(fn ->
      restore(:shares, prior)
      restore(:shares_env, prior_env)
    end)

    :ok
  end

  @doc """
  Plant `env_string` (`";"`-separated `"<scope>:<surfaces>:<access>"` entries)
  as PERSISTED shares and make them the whole live list.

  Replaces the live registry the way a bare `put_env` did — the env baseline is
  emptied and every pre-existing stored row is deleted first — but every entry
  lands as a `StoredShare` row, so `Sharing.refresh/0` rebuilds it instead of
  erasing it. Raises if an entry does not persist (a wildcard scope, an unknown
  surface, a comma-joined multi-scope string), so a dropped fixture can never
  masquerade as a passing assertion.
  """
  @spec plant_shares!(binary()) :: :ok
  def plant_shares!(env_string) when is_binary(env_string) do
    clear_shares!()

    env_string
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn entry ->
      case Sharing.add_share(entry) do
        {:ok, _share} ->
          :ok

        other ->
          raise ArgumentError, """
          plant_shares!/1 could not persist #{inspect(entry)} (#{inspect(other)}).

          Sharing.add_share/1 takes exactly ONE valid entry. Remember that
          Sharing.parse/1 splits entries on ";" and NEVER on "," — a
          comma-joined multi-scope string is one malformed entry.
          """
      end
    end)

    :ok
  end

  @doc """
  Force the live registry to Default-OFF (`:shares == []`) in a refresh-proof
  way: empty the env baseline, delete every stored row, then `refresh/0`.
  """
  @spec clear_shares!() :: :ok
  def clear_shares! do
    snapshot_shares!()
    Application.put_env(:barkpark, :shares_env, [])
    Repo.delete_all(StoredShare)
    Sharing.refresh()
    :ok
  end

  defp restore(key, {:ok, val}), do: Application.put_env(:barkpark, key, val)
  defp restore(key, :error), do: Application.delete_env(:barkpark, key)
end
