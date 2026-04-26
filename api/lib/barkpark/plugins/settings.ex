defmodule Barkpark.Plugins.Settings do
  @moduledoc """
  CRUD for plugin settings, encrypted at rest with Cloak.
  Every read/write/delete is audited. Telemetry emitted on read/write.
  """
  alias Barkpark.Repo
  alias Barkpark.Plugins.{SettingsRecord, SettingsAudit}

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get(plugin_name, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    case Repo.get(SettingsRecord, plugin_name) do
      nil ->
        {:error, :not_found}

      %SettingsRecord{settings: map} ->
        log_audit(plugin_name, "read", user_id)

        :telemetry.execute(
          [:barkpark, :plugin_settings, :read],
          %{count: 1},
          %{plugin_name: plugin_name}
        )

        {:ok, map}
    end
  end

  @spec put(String.t(), map(), keyword()) ::
          {:ok, SettingsRecord.t()} | {:error, Ecto.Changeset.t()}
  def put(plugin_name, settings_map, opts \\ [])
      when is_binary(plugin_name) and is_map(settings_map) do
    user_id = Keyword.get(opts, :user_id)
    now = DateTime.utc_now()

    attrs = %{
      plugin_name: plugin_name,
      settings: settings_map,
      updated_at: now,
      updated_by: user_id
    }

    record =
      Repo.get(SettingsRecord, plugin_name) || %SettingsRecord{plugin_name: plugin_name}

    record
    |> SettingsRecord.changeset(attrs)
    |> Repo.insert_or_update(
      on_conflict: {:replace_all_except, [:plugin_name]},
      conflict_target: :plugin_name
    )
    |> case do
      {:ok, rec} ->
        log_audit(plugin_name, "write", user_id)

        :telemetry.execute(
          [:barkpark, :plugin_settings, :write],
          %{count: 1},
          %{plugin_name: plugin_name}
        )

        {:ok, rec}

      {:error, _} = err ->
        err
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, :not_found}
  def delete(plugin_name, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    case Repo.get(SettingsRecord, plugin_name) do
      nil ->
        {:error, :not_found}

      rec ->
        Repo.delete!(rec)
        log_audit(plugin_name, "delete", user_id)

        :telemetry.execute(
          [:barkpark, :plugin_settings, :write],
          %{count: 1},
          %{plugin_name: plugin_name, action: "delete"}
        )

        :ok
    end
  end

  @doc """
  Fetch unmasked settings and record a `"reveal"` audit row. Used by
  Studio's settings LiveView when an admin clicks a masked field.
  """
  @spec reveal(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def reveal(plugin_name, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    case Repo.get(SettingsRecord, plugin_name) do
      nil ->
        {:error, :not_found}

      %SettingsRecord{settings: map} ->
        log_audit(plugin_name, "reveal", user_id)
        {:ok, map}
    end
  end

  defp log_audit(plugin_name, action, user_id) do
    %SettingsAudit{}
    |> SettingsAudit.changeset(%{
      plugin_name: plugin_name,
      action: action,
      user_id: user_id,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
