defmodule BarkparkWeb.PluginSettingsController do
  @moduledoc """
  Admin-only REST endpoints for `plugin_settings`.

  Routes are pipelined through `:api` + `:require_admin` so callers without
  the `admin` permission receive 403 (`{:error, :forbidden}` envelope) and
  un-authenticated callers receive 401 (`{:error, :unauthorized}`).
  """

  use BarkparkWeb, :controller

  # v1 structured error envelope (code + request_id) on every error path — the
  # same contract as the content endpoints. Was bare `%{error: "…"}` strings
  # (incl. an `inspect(reason)` leak) with no request_id and no keyable code.
  action_fallback BarkparkWeb.FallbackController

  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking

  def show(conn, %{"plugin_name" => name}) do
    user_id = current_user_id(conn)

    case Settings.get(name, user_id: user_id) do
      {:ok, map} when is_map(map) ->
        json(conn, %{plugin_name: name, settings: Masking.mask(map)})

      {:error, :not_found} ->
        {:error, {:not_found, "plugin settings not found"}}
    end
  end

  def update(conn, %{"plugin_name" => name, "settings" => settings_map})
      when is_map(settings_map) do
    user_id = current_user_id(conn)

    # Settings.put/3 only errors with an Ecto changeset (its txn rolls back with
    # one); to_envelope renders that as validation_failed + details. The former
    # `{:error, reason} -> inspect(reason)` branch was dead code.
    case Settings.put(name, settings_map, user_id: user_id) do
      {:ok, _rec} -> json(conn, %{ok: true})
      {:error, _} = err -> err
    end
  end

  def update(_conn, _params), do: {:error, :malformed}

  def delete(conn, %{"plugin_name" => name}) do
    user_id = current_user_id(conn)

    case Settings.delete(name, user_id: user_id) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        {:error, {:not_found, "plugin settings not found"}}
    end
  end

  defp current_user_id(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end
end
