defmodule Barkpark.Content.Errors do
  @moduledoc "Maps internal error tuples to v1 JSON error envelopes."

  def to_envelope(reason), do: to_envelope(reason, nil)

  def to_envelope(reason, conn) do
    reason
    |> build()
    |> put_request_id(conn)
  end

  defp build({:error, :not_found}),
    do: %{code: "not_found", message: "document not found", status: 404}

  defp build({:error, :unauthorized}),
    do: %{code: "unauthorized", message: "missing or invalid token", status: 401}

  defp build({:error, :forbidden}),
    do: %{code: "forbidden", message: "token lacks required permission", status: 403}

  defp build({:error, :forbidden_origin}),
    do: %{code: "cors_forbidden", message: "origin not allowed for dataset", status: 403}

  defp build({:error, :schema_unknown}),
    do: %{code: "schema_unknown", message: "no schema for type", status: 404}

  defp build({:error, :rev_mismatch}),
    do: %{code: "rev_mismatch", message: "document was modified by another writer", status: 409}

  defp build({:error, {:rev_mismatch, %{expected: expected, actual: actual}}}),
    do: %{
      status: 412,
      code: "precondition_failed",
      message: "document revision mismatch",
      details: %{expected: expected, actual: actual}
    }

  defp build({:error, :malformed}),
    do: %{code: "malformed", message: "request body is malformed", status: 400}

  defp build({:error, :conflict}),
    do: %{code: "conflict", message: "document already exists", status: 409}

  defp build({:error, %Ecto.Changeset{} = cs}) do
    details =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    %{code: "validation_failed", message: "document failed validation", status: 422, details: details}
  end

  defp build({:error, :rate_limited}),
    do: %{code: "rate_limited", message: "rate limit exceeded", status: 429}

  defp build({:error, :rate_limited, %{retry_after: retry_after}}),
    do: %{
      status: 429,
      code: "rate_limited",
      message: "too many requests",
      details: %{retry_after: retry_after}
    }

  defp build({:error, reason}) when is_binary(reason),
    do: %{code: "internal_error", message: reason, status: 500}

  defp build(_),
    do: %{code: "internal_error", message: "unknown error", status: 500}

  defp put_request_id(env, conn) do
    case request_id(conn) do
      nil -> env
      id -> Map.put(env, :request_id, id)
    end
  end

  defp request_id(conn) do
    case Logger.metadata()[:request_id] do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case conn do
          %Plug.Conn{} ->
            case Plug.Conn.get_resp_header(conn, "x-request-id") do
              [id | _] when is_binary(id) and id != "" -> id
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end
end
