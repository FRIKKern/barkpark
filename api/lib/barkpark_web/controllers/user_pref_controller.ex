defmodule BarkparkWeb.UserPrefController do
  @moduledoc """
  `GET/PUT /w/:ws/p/:proj/v1/prefs/:dataset/:key` — the per-account JSON
  key-value store (task-7d2a48dbf7e4bf34). Mounted under `:scoped_api` (any
  member identity, token or session cookie) — membership alone gates it;
  no write-permission check, because the value scoped here is the caller's
  OWN, never workspace-shared content.

  Identity: `conn.assigns[:current_user]` (an account session) when
  present, else a personal access token's `owner_user_id`. A token with no
  owner (a shared/admin-minted token, never bound to one editor) has no
  "user" to key by and is refused — this store cannot silently fall back
  to a workspace- or token-wide scope, which would leak one editor's
  recent searches to every holder of that token.
  """
  use BarkparkWeb, :controller

  alias Barkpark.UserPrefs

  def show(conn, %{"dataset" => dataset, "key" => key}) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]} do
      value = UserPrefs.get(user_id, ws_id, dataset, key)
      json(conn, %{key: key, dataset: dataset, value: value})
    else
      {:ws, _} ->
        error(conn, 404, "not_found", "no workspace resolved for this route")

      {:error, :no_user} ->
        no_user_error(conn)
    end
  end

  def update(conn, %{"dataset" => dataset, "key" => key, "value" => value}) when is_map(value) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]},
         {:ok, pref} <- UserPrefs.put(user_id, ws_id, dataset, key, value) do
      json(conn, %{ok: true, key: key, dataset: dataset, value: pref.value})
    else
      {:ws, _} ->
        error(conn, 404, "not_found", "no workspace resolved for this route")

      {:error, :no_user} ->
        no_user_error(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        error(conn, 422, "invalid_pref", changeset_errors(changeset))
    end
  end

  def update(conn, %{"dataset" => _dataset, "key" => _key}) do
    error(conn, 422, "bad_request", "value must be a JSON object")
  end

  def delete(conn, %{"dataset" => dataset, "key" => key}) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]} do
      :ok = UserPrefs.delete(user_id, ws_id, dataset, key)
      json(conn, %{ok: true})
    else
      {:ws, _} ->
        error(conn, 404, "not_found", "no workspace resolved for this route")

      {:error, :no_user} ->
        no_user_error(conn)
    end
  end

  defp resolve_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} when is_binary(id) ->
        {:ok, id}

      _ ->
        case conn.assigns[:api_token] do
          %{owner_user_id: id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :no_user}
        end
    end
  end

  defp no_user_error(conn) do
    error(
      conn,
      403,
      "no_user_identity",
      "this token has no owning account to key a per-user pref by",
      "sign in as an account, or use a personal access token minted via POST /v1/auth/tokens"
    )
  end

  defp error(conn, status, code, message, hint \\ nil) do
    body = %{error: %{code: code, message: message}}
    body = if hint, do: put_in(body, [:error, :hint], hint), else: body

    conn
    |> put_status(status)
    |> json(body)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
