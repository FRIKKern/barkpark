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

  # v1 structured error envelope (code + request_id + message) for every error
  # path — the same contract as the content endpoints. Was bare `%{error: "…"}`
  # strings that carried no request_id and no machine-keyable code.
  action_fallback BarkparkWeb.FallbackController

  alias Barkpark.Secrets

  def index(conn, _params) do
    json(conn, %{secrets: Secrets.list()})
  end

  def show(conn, %{"name" => name}) do
    case Secrets.reveal(name, actor: actor(conn)) do
      {:ok, value} ->
        json(conn, %{name: name, value: value})

      {:error, :not_found} ->
        {:error, {:not_found, "secret not found"}}
    end
  end

  def update(conn, %{"name" => name, "value" => value}) when is_binary(value) do
    case Secrets.put(name, value, actor: actor(conn)) do
      {:ok, _rec} ->
        json(conn, %{ok: true})

      {:error, %Ecto.Changeset{}} = err ->
        err
    end
  end

  def update(_conn, _params), do: {:error, :malformed}

  def delete(conn, %{"name" => name}) do
    case Secrets.delete(name, actor: actor(conn)) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        {:error, {:not_found, "secret not found"}}
    end
  end

  defp actor(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end
end
