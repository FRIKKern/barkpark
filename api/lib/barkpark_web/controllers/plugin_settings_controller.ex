defmodule BarkparkWeb.PluginSettingsController do
  @moduledoc """
  Admin-only REST endpoints for `plugin_settings`.

  Routes are pipelined through `:api` + `:require_admin` so callers without
  the `admin` permission receive 403 (`{:error, :forbidden}` envelope) and
  un-authenticated callers receive 401 (`{:error, :unauthorized}`).
  """

  use BarkparkWeb, :controller

  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.Settings.Masking

  def show(conn, %{"plugin_name" => name}) do
    user_id = current_user_id(conn)

    case Settings.get(name, user_id: user_id) do
      {:ok, map} when is_map(map) ->
        json(conn, %{plugin_name: name, settings: Masking.mask(map)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def update(conn, %{"plugin_name" => name, "settings" => settings_map})
      when is_map(settings_map) do
    user_id = current_user_id(conn)

    case Settings.put(name, settings_map, user_id: user_id) do
      {:ok, _rec} ->
        json(conn, %{ok: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid", details: changeset_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  def update(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "settings_object_required"})
  end

  def delete(conn, %{"plugin_name" => name}) do
    user_id = current_user_id(conn)

    case Settings.delete(name, user_id: user_id) do
      :ok ->
        json(conn, %{ok: true})

      {:ok, _} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp current_user_id(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end

  defp changeset_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
