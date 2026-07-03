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
    "validation_failed" => "Fix the listed validation errors to match the schema, then resubmit.",
    "invalid_filter" =>
      "Use one of the documented filter operators (eq, neq, in, nin, has, contains, startsWith, endsWith, gt, gte, lt, lte, is) — check for a typo or wrong case.",
    "forbidden_field" =>
      "Filter/order only on fields your token can read; use an admin/owner token, or query a field that isn't private in this schema.",
    "halted" =>
      "A plugin's lifecycle hook vetoed this write — read the message for the policy that rejected it, then adjust the document to satisfy it (or disable the plugin).",
    "rate_limited" =>
      "Back off and retry after the Retry-After header's value; reduce request rate.",
    "storage_unavailable" =>
      "Media storage could not be written (disk full, read-only mount, or permissions). Retry shortly; if it persists, check the server's media volume.",
    "payload_too_large" =>
      "Reduce the request body — it exceeds the maximum allowed size (100 MB). Upload a smaller file or split the request.",
    "internal_error" =>
      "Retry shortly; if it persists, report the request_id to the API operator."
  }

  def to_envelope(reason), do: to_envelope(reason, nil)

  @doc """
  The set of stable `code` strings this module can emit — the canonical §9
  error vocabulary (docs/api-v1.md). Each registered hint key is a code, so the
  hint table doubles as the code index. `Barkpark.Api.OpenApi` reads this to
  build the `Error.code` enum, and a test pins spec↔runtime parity so a code
  added here without a spec regen fails CI.
  """
  @spec known_codes() :: MapSet.t()
  def known_codes, do: @hints |> Map.keys() |> MapSet.new()

  def to_envelope(reason, conn) do
    reason
    |> build()
    |> put_hint()
    |> put_request_id(conn)
  end

  defp build({:error, :not_found}),
    do: %{code: "not_found", message: "document not found", status: 404}

  # Parameterized not_found — same canonical code/status, but a resource-specific
  # message. Non-document endpoints (secrets, shares, plugin settings) reuse the
  # `not_found` CODE (so clients key on it uniformly) without the misleading
  # "document not found" text.
  defp build({:error, {:not_found, message}}) when is_binary(message),
    do: %{code: "not_found", message: message, status: 404}

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

  # An unknown filter operator (e.g. ?filter[status][bogus]=x). Fail CLOSED with
  # a 400 instead of the old fail-OPEN behaviour, where an unrecognized op fell
  # through the query builder's catch-all and silently returned EVERY row —
  # querying with a typo'd op looked like it filtered but didn't. Lists the valid
  # ops so the caller can fix it (Sanity/Strapi reject unknown operators too).
  defp build({:error, {:invalid_filter_op, field, op}}),
    do: %{
      code: "invalid_filter",
      message:
        "unknown filter operator #{inspect(op)} on field #{inspect(field)}; " <>
          "valid operators: eq, neq, in, nin, has, contains, startsWith, endsWith, " <>
          "gt, gte, lt, lte, is",
      status: 400,
      details: %{field: field, op: op}
    }

  # A filter/order targets a field the caller may not READ. 422 so the WHERE/ORDER
  # never runs over a hidden field (an oracle to binary-search or sort by its
  # value even though the body is redacted). Canonical envelope — QueryController
  # used to emit a bare %{error: "forbidden_field", field: field} with no code /
  # request_id, the same shape the halt/invalid_filter fixes replaced.
  defp build({:error, {:forbidden_field, field}}),
    do: %{
      code: "forbidden_field",
      message: "filter/order references a field you are not authorized to read",
      status: 422,
      details: %{field: field}
    }

  defp build({:error, :conflict}),
    do: %{code: "conflict", message: "document already exists", status: 409}

  # A plugin lifecycle hook (before_save / before_publish) returned
  # {:halt, reason}, vetoing the write. 409 Conflict with the CANONICAL
  # envelope so the bp CLI + SDK can key on error.code and read request_id —
  # MutateController used to emit a bare %{error: "halted", reason: reason}
  # here that carried no code/request_id and was invisible to every machine
  # consumer. The plugin's reason string becomes the message verbatim.
  defp build({:error, {:halted, reason}}),
    do: %{code: "halted", message: halt_message(reason), status: 409}

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

  # The media storage write path (Media.upload) could not persist the blob —
  # ENOSPC / EACCES / read-only mount. 503 Service Unavailable (transient,
  # retryable) with the canonical envelope, so a disk fault returns a typed
  # error instead of an uncaught File.*! raise → bare 500.
  defp build({:error, :storage_unavailable}),
    do: %{
      code: "storage_unavailable",
      message: "media storage is temporarily unavailable",
      status: 503
    }

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

  # A halt reason is normally a human string the plugin author chose; use it
  # verbatim so "plugin authors can rely on it" stays true. Fall back to a
  # descriptive line for structured/blank reasons so the message is never empty.
  defp halt_message(reason) when is_binary(reason) and reason != "", do: reason

  defp halt_message(reason),
    do: "mutation vetoed by a plugin lifecycle hook: #{inspect(reason)}"

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
