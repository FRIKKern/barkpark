defmodule Barkpark.UserPrefs do
  @moduledoc """
  A small per-account, per-workspace, per-dataset JSON key-value store
  (task-7d2a48dbf7e4bf34) — Sanity-parity for recent searches (J38) and
  list sort/view prefs (J25), which the Studio otherwise has nowhere
  durable to keep per editor (localStorage/cookies do not follow the
  editor to a second browser or device).

  Not a document store: no listen events, no history, no search
  indexing. A value is capped at 16KB by `UserPref.changeset/2`.
  """

  import Ecto.Query, warn: false
  alias Barkpark.Repo
  alias Barkpark.UserPrefs.UserPref

  @doc """
  Read one named value for `user_id` in `workspace_id`/`dataset`.
  `nil` when unset — never an error; an absent pref is not exceptional.
  """
  @spec get(binary(), binary(), String.t(), String.t()) :: map() | nil
  def get(user_id, workspace_id, dataset, key)
      when is_binary(user_id) and is_binary(workspace_id) and is_binary(dataset) and
             is_binary(key) do
    Repo.one(
      from p in UserPref,
        where:
          p.user_id == ^user_id and p.workspace_id == ^workspace_id and p.dataset == ^dataset and
            p.key == ^key,
        select: p.value
    )
  end

  @doc """
  Upsert one named value. `value` must be a JSON-encodable map (the
  changeset enforces the size cap); an invalid value or an over-length
  key/dataset returns `{:error, changeset}` and writes nothing.
  """
  @spec put(binary(), binary(), String.t(), String.t(), map()) ::
          {:ok, UserPref.t()} | {:error, Ecto.Changeset.t()}
  def put(user_id, workspace_id, dataset, key, value) when is_map(value) do
    attrs = %{
      user_id: user_id,
      workspace_id: workspace_id,
      dataset: dataset,
      key: key,
      value: value
    }

    %UserPref{}
    |> UserPref.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:user_id, :workspace_id, :dataset, :key]
    )
  end

  @type list_op :: {:push_front | :add | :remove, String.t(), term(), pos_integer() | nil}

  @doc """
  Edit the list at `value[field]` in one transaction under a row lock, so
  two tabs or devices editing the same key both land. A missing row or
  field is an empty list; the rest of `value` is kept.

    * `:push_front` — move `item` to the front, drop its other copies, keep
      the first `max` (all when `nil`).
    * `:add` — append `item` unless present.
    * `:remove` — drop every copy of `item`.

  Each op applied twice gives the result of applying it once, so a client
  may replay a queued op. `{:error, :not_a_list}` when `value[field]` holds
  anything else; `{:error, changeset}` past the size cap. Neither writes.
  """
  @spec apply_list_op(binary(), binary(), String.t(), String.t(), list_op()) ::
          {:ok, UserPref.t()} | {:error, :not_a_list | Ecto.Changeset.t()}
  def apply_list_op(user_id, workspace_id, dataset, key, {op, field, item, max}) do
    Repo.transaction(fn ->
      pref = lock!(user_id, workspace_id, dataset, key)

      with {:ok, list} <- list_at(pref.value, field),
           value = Map.put(pref.value, field, edit(op, list, item, max)),
           {:ok, pref} <- pref |> UserPref.changeset(%{value: value}) |> Repo.update() do
        pref
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock!(user_id, workspace_id, dataset, key) do
    %UserPref{}
    |> UserPref.changeset(%{
      user_id: user_id,
      workspace_id: workspace_id,
      dataset: dataset,
      key: key,
      value: %{}
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:user_id, :workspace_id, :dataset, :key]
    )

    Repo.one!(
      from p in UserPref,
        where:
          p.user_id == ^user_id and p.workspace_id == ^workspace_id and p.dataset == ^dataset and
            p.key == ^key,
        lock: "FOR UPDATE"
    )
  end

  defp list_at(value, field) do
    case Map.get(value, field, []) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :not_a_list}
    end
  end

  defp edit(:push_front, list, item, max) do
    kept = [item | Enum.reject(list, &(&1 === item))]
    if max, do: Enum.take(kept, max), else: kept
  end

  defp edit(:add, list, item, _max), do: if(item in list, do: list, else: list ++ [item])
  defp edit(:remove, list, item, _max), do: Enum.reject(list, &(&1 === item))

  @doc """
  Delete one named value. Idempotent — deleting an absent key is `{:ok, 0}`.

  Returns the row count, not a bare `:ok` (pds-bl-sentinel-ok-returner-population:
  a callee that performs a Repo write and throws the result away one frame
  below its caller can never report failure upward). There is no failure mode
  today — `delete_all` on this table cannot itself error — but the count is a
  real signal a caller may want (idempotent no-op vs an actual row removed).
  """
  @spec delete(binary(), binary(), String.t(), String.t()) :: {:ok, non_neg_integer()}
  def delete(user_id, workspace_id, dataset, key) do
    {count, _} =
      Repo.delete_all(
        from p in UserPref,
          where:
            p.user_id == ^user_id and p.workspace_id == ^workspace_id and
              p.dataset == ^dataset and p.key == ^key
      )

    {:ok, count}
  end
end
