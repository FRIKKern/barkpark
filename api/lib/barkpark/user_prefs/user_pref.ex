defmodule Barkpark.UserPrefs.UserPref do
  @moduledoc """
  One named JSON value for one account, in one workspace, in one dataset
  (task-7d2a48dbf7e4bf34). `key` is a caller-chosen name
  ("recent_searches", "list_prefs.taskList", ...) — the dataset is its own
  column, never baked into the key string.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_key_length 200
  # Small values only — this is a prefs store, not a document store.
  @max_value_bytes 16_384

  schema "user_prefs" do
    field :dataset, :string
    field :key, :string
    field :value, :map, default: %{}

    belongs_to :user, Barkpark.Accounts.User
    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(pref, attrs) do
    pref
    |> cast(attrs, [:user_id, :workspace_id, :dataset, :key, :value])
    |> validate_required([:user_id, :workspace_id, :dataset, :key, :value])
    |> validate_length(:key, max: @max_key_length)
    |> validate_length(:dataset, max: 200)
    |> validate_value_size()
    |> unique_constraint([:user_id, :workspace_id, :dataset, :key],
      name: :user_prefs_user_workspace_dataset_key_idx
    )
  end

  defp validate_value_size(changeset) do
    case get_change(changeset, :value) do
      nil ->
        changeset

      value ->
        size = value |> Jason.encode!() |> byte_size()

        if size > @max_value_bytes do
          add_error(changeset, :value, "is too large (#{size} bytes, max #{@max_value_bytes})")
        else
          changeset
        end
    end
  end
end
