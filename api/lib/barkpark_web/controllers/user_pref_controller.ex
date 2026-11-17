defmodule BarkparkWeb.UserPrefController do
  @moduledoc """
  `GET/PUT/PATCH/DELETE /w/:ws/p/:proj/v1/prefs/:dataset/:key` — the per-account JSON
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
  alias BarkparkWeb.ErrorResponse

  def show(conn, %{"dataset" => dataset, "key" => key}) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]} do
      value = UserPrefs.get(user_id, ws_id, dataset, key)
      conn |> tagged(value) |> json(%{key: key, dataset: dataset, value: value})
    else
      {:ws, _} ->
        not_found(conn)

      {:error, :no_user} ->
        no_user_error(conn)
    end
  end

  def update(conn, %{"dataset" => dataset, "key" => key, "value" => value}) when is_map(value) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]},
         {:ok, pref} <- write(conn, {user_id, ws_id, dataset, key}, value) do
      # The tag is the STORED value's (Postgres rewrites some numbers, 1e20 to
      # 100000000000000000000); the body is the value as sent, as it always was.
      conn
      |> tagged(pref.value)
      |> json(%{ok: true, key: key, dataset: dataset, value: value})
    else
      {:ws, _} ->
        not_found(conn)

      {:error, :no_user} ->
        no_user_error(conn)

      {:error, {:precondition_failed, actual}} ->
        precondition_failed(conn, actual)

      {:error, :bad_if_none_match} ->
        ErrorResponse.emit_custom(
          conn,
          422,
          "bad_request",
          "If-None-Match takes only *: create the key only if it is unset"
        )

      {:error, :both_preconditions} ->
        ErrorResponse.emit_custom(
          conn,
          422,
          "bad_request",
          "send If-Match or If-None-Match, not both"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        # emit_fields/3, not emit_custom/5: the changeset's own traversed
        # errors are a MAP (field => messages), not the string emit_custom's
        # `message` guard requires — this is exactly the "a minority carry no
        # string message" case that verb exists for.
        ErrorResponse.emit_fields(conn, 422, %{
          code: "invalid_pref",
          message: changeset_errors(changeset)
        })
    end
  end

  def update(conn, %{"dataset" => _dataset, "key" => _key}) do
    ErrorResponse.emit_custom(conn, 422, "bad_request", "value must be a JSON object")
  end

  # A PUT with If-Match writes only over the value a tag names
  # (task-f88365602c49be57); with If-None-Match: * only when the key is unset
  # (task-c1f9452e1b8216ee); without either it is the plain upsert it always
  # was. A header's presence decides: one that holds no tag names no value, so
  # it is refused, never read as "no header". Any If-None-Match but `*`, or
  # both headers, is refused rather than a precondition left unchecked.
  defp write(conn, {user_id, ws_id, dataset, key}, value) do
    case {get_req_header(conn, "if-match"), get_req_header(conn, "if-none-match")} do
      {[], []} ->
        UserPrefs.put(user_id, ws_id, dataset, key, value)

      {headers, []} ->
        UserPrefs.put_if_match(user_id, ws_id, dataset, key, value, tags(headers))

      {[], headers} ->
        if tags(headers) == ["*"],
          do: UserPrefs.put_if_absent(user_id, ws_id, dataset, key, value),
          else: {:error, :bad_if_none_match}

      {_, _} ->
        {:error, :both_preconditions}
    end
  end

  defp precondition_failed(conn, actual) do
    {message, expected, hint} =
      case get_req_header(conn, "if-match") do
        [] ->
          {"the key already holds a value; If-None-Match: * creates only an unset key", nil,
           "GET the key to see the value another writer made"}

        headers ->
          {"the stored pref is not one the If-Match names", Enum.join(headers, ", "),
           "GET the key again, apply your change to that value, and PUT it with the new ETag"}
      end

    ErrorResponse.emit_custom(
      conn,
      412,
      "precondition_failed",
      message,
      %{expected: expected, actual: actual},
      hint
    )
  end

  defp tags(headers) do
    headers
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Every answer that carries a stored value carries its tag; an unset key has none.
  defp tagged(conn, value) do
    case UserPrefs.etag(value) do
      nil -> conn
      tag -> put_resp_header(conn, "etag", tag)
    end
  end

  def patch(conn, %{"dataset" => dataset, "key" => key} = params) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]},
         {:ok, op} <- list_op(params),
         {:ok, value} <- UserPrefs.apply_list_op(user_id, ws_id, dataset, key, op) do
      conn |> tagged(value) |> json(%{key: key, dataset: dataset, value: value})
    else
      {:ws, _} ->
        not_found(conn)

      {:error, :no_user} ->
        no_user_error(conn)

      {:error, :bad_op} ->
        ErrorResponse.emit_custom(
          conn,
          422,
          "bad_request",
          "body must be {op: push_front | add | remove | set, field: string, item: non-null, max?: positive integer}"
        )

      {:error, :not_a_list} ->
        ErrorResponse.emit_fields(conn, 422, %{
          code: "invalid_pref",
          message: %{value: ["#{params["field"]} is not a list"]}
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorResponse.emit_fields(conn, 422, %{
          code: "invalid_pref",
          message: changeset_errors(changeset)
        })
    end
  end

  @list_ops %{"push_front" => :push_front, "add" => :add, "remove" => :remove, "set" => :set}

  defp list_op(%{"op" => op, "field" => field, "item" => item} = params)
       when is_binary(field) and field != "" and not is_nil(item) do
    case {Map.fetch(@list_ops, op), cap(Map.get(params, "max"))} do
      {{:ok, op}, {:ok, max}} -> {:ok, {op, field, item, max}}
      _ -> {:error, :bad_op}
    end
  end

  defp list_op(_params), do: {:error, :bad_op}

  defp cap(nil), do: {:ok, nil}
  defp cap(max) when is_integer(max) and max > 0, do: {:ok, max}

  defp cap(max) when is_binary(max) do
    case Integer.parse(max) do
      {max, ""} when max > 0 -> {:ok, max}
      _ -> :error
    end
  end

  defp cap(_max), do: :error

  def delete(conn, %{"dataset" => dataset, "key" => key}) do
    with {:ok, user_id} <- resolve_user_id(conn),
         {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]} do
      {:ok, _count} = UserPrefs.delete(user_id, ws_id, dataset, key)
      json(conn, %{ok: true})
    else
      {:ws, _} ->
        not_found(conn)

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

  defp not_found(conn),
    do: ErrorResponse.emit_custom(conn, 404, "not_found", "no workspace resolved for this route")

  defp no_user_error(conn) do
    ErrorResponse.emit_custom(
      conn,
      403,
      "no_user_identity",
      "this token has no owning account to key a per-user pref by",
      %{},
      "sign in as an account, or use a personal access token minted via POST /v1/auth/tokens"
    )
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
