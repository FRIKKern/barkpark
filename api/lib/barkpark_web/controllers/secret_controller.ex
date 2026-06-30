defmodule BarkparkWeb.SecretController do
  @moduledoc """
  Admin-only REST endpoints for cloud run-secrets (`/v1/secrets`).

  Routes are pipelined through `:api` + `:require_admin`, so a non-admin caller
  receives 403 (`{:error, :forbidden}`) and an un-authenticated caller 401.

  Unlike `PluginSettingsController` (whose `show` MASKS), `GET /v1/secrets/:name`
  REVEALS the unmasked value and writes a `"reveal"` audit row — that's the whole
  point: an authenticated admin can always retrieve a run-secret. The list
  endpoint stays masked.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Secrets

  def index(conn, _params) do
    json(conn, %{secrets: Secrets.list()})
  end

  def show(conn, %{"name" => name}) do
    case Secrets.reveal(name, actor: actor(conn)) do
      {:ok, value} ->
        json(conn, %{name: name, value: value})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def update(conn, %{"name" => name, "value" => value}) when is_binary(value) do
    case Secrets.put(name, value, actor: actor(conn)) do
      {:ok, _rec} ->
        json(conn, %{ok: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid", details: changeset_errors(changeset)})
    end
  end

  def update(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "value_string_required"})
  end

  def delete(conn, %{"name" => name}) do
    case Secrets.delete(name, actor: actor(conn)) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp actor(conn) do
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
