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

  @doc "Delete one named value. Idempotent — deleting an absent key is `:ok`."
  @spec delete(binary(), binary(), String.t(), String.t()) :: :ok
  def delete(user_id, workspace_id, dataset, key) do
    {_count, _} =
      Repo.delete_all(
        from p in UserPref,
          where:
            p.user_id == ^user_id and p.workspace_id == ^workspace_id and
              p.dataset == ^dataset and p.key == ^key
      )

    :ok
  end
end
