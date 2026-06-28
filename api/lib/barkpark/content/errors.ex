defmodule Barkpark.Content.Errors do
  @moduledoc "Maps internal error tuples to v1 JSON error envelopes."

  # Human-grade, fix-suggesting hints keyed off the STABLE `code` string. Purely
  # additive: merged in `to_envelope/2` only when a hint is registered for the
  # code, so existing `code`/`message`/`status`/`details` stay byte-for-byte
  # stable and every action_fallback controller picks `hint` up for free (no
  # controller edits). Imperative one-liners — tell the caller what to fix.
  @hints %{
    "not_found" =>
      "Check the document _id, type, and dataset in the URL — the resource does not exist in this scope.",
    "unauthorized" =>
      "Send a valid token via the Authorization: Bearer header; tokens are dataset-scoped.",
    "forbidden" => "Use a token with write/admin permission that is a member of this workspace.",
    "cors_forbidden" =>
      "Add this origin to the dataset's allowed origins, or call from a server-side token instead.",
    "csrf_required" => "Add the x-requested-with header to cookie-authenticated mutations.",
    "schema_unknown" =>
      "Register a schema for this type via POST /v1/schemas/:dataset before writing documents of it.",
    "rev_mismatch" => "Re-fetch the document, then retry with its current _rev in ifRevisionID.",
    "precondition_failed" =>
      "Re-fetch the document and retry with the current revision — it changed under you.",
    "malformed" =>
      "Send a well-formed JSON body matching the endpoint's expected shape; check Content-Type: application/json.",
    "conflict" =>
      "The document already exists — use a createOrReplace/patch mutation instead of create.",
    "validation_failed" =>
      "Fix the listed validation errors to match the schema, then resubmit.",
    "rate_limited" =>
      "Back off and retry after the Retry-After header's value; reduce request rate.",
    "internal_error" =>
      "Retry shortly; if it persists, report the request_id to the API operator."
  }

  def to_envelope(reason), do: to_envelope(reason, nil)

  def to_envelope(reason, conn) do
    reason
    |> build()
    |> put_hint()
    |> put_request_id(conn)
  end

  defp build({:error, :not_found}),
    do: %{code: "not_found", message: "document not found", status: 404}

  defp build({:error, :unauthorized}),
    do: %{code: "unauthorized", message: "missing or invalid token", status: 401}

  defp build({:error, :replay}),
    do: %{
      code: "unauthorized",
      message: "preview token replay detected",
      status: 401,
      reason: "replay"
    }

  defp build({:error, :forbidden}),
    do: %{code: "forbidden", message: "token lacks required permission", status: 403}

  defp build({:error, :forbidden_origin}),
    do: %{code: "cors_forbidden", message: "origin not allowed for dataset", status: 403}

  defp build({:error, :csrf_required}),
    do: %{
      code: "csrf_required",
      message: "cookie-authenticated mutation requires the x-requested-with header",
      status: 403
    }

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

    %{
      code: "validation_failed",
      message: "document failed validation",
      status: 422,
      details: details
    }
  end

  # Task content validation (Content.validate_task_kind → Tasks.
  # validate_kind_content): a per-field errors map, e.g. %{"kind" => ["is
  # required"]}. Before this clause it fell through to the catch-all and a
  # missing `kind` surfaced as a bare 500 "unknown error" — a validation
  # failure with ZERO signal about what to fix (found by the typed-verbatim
  # cheatsheet pass, 2026-06-10).
  defp build({:error, {:invalid_task_content, errors}}) when is_map(errors) do
    %{
      code: "validation_failed",
      message: "task content failed validation",
      status: 422,
      details: errors
    }
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

  defp put_hint(env) do
    case @hints[env.code] do
      nil -> env
      hint -> Map.put(env, :hint, hint)
    end
  end

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
