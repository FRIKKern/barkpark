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
    "unsupported_if_match_for_batch" =>
      "A single If-Match header can't fence a multi-op batch — drop the header and put an ifRevisionID (or ifMatch) inside each mutation instead.",
    "conflict" =>
      "The document already exists — use a createOrReplace/patch mutation instead of create.",
    "validation_failed" => "Fix the listed validation errors to match the schema, then resubmit.",
    "schema_has_documents" =>
      "Delete the documents of this type first, or repeat the request with ?force=true to remove the schema and orphan them.",
    "invalid_filter" =>
      "Use one of the documented filter operators (eq, neq, in, nin, has, contains, startsWith, endsWith, gt, gte, lt, lte, is) — check for a typo or wrong case.",
    "forbidden_field" =>
      "Filter/order only on fields your token can read; use an admin/owner token, or query a field that isn't private in this schema.",
    "halted" =>
      "A plugin's lifecycle hook vetoed this write — read the message for the policy that rejected it, then adjust the document to satisfy it (or disable the plugin).",
    "rate_limited" =>
      "Back off and retry after the Retry-After header's value; reduce request rate.",
    "idempotency_key_in_use" =>
      "Another request with this Idempotency-Key is still in flight — wait for it to finish, then retry to replay its result (or use a fresh key for a distinct operation).",
    "storage_unavailable" =>
      "Media storage could not be written (disk full, read-only mount, or permissions). Retry shortly; if it persists, check the server's media volume.",
    "payload_too_large" =>
      "Reduce the request body — it exceeds the maximum allowed size (100 MB). Upload a smaller file or split the request.",
    "unsupported_media_type" =>
      "This file's type is not permitted by the server's media allowlist. Upload one of the allowed MIME types / extensions, or ask the operator to widen the allowlist.",
    "internal_error" =>
      "Retry shortly; if it persists, report the request_id to the API operator.",
    # Resource-coded not_found pair for the webhook console routes: consumers
    # (cloud proxy/SPA) must tell a REAL not-found apart from a route-missing
    # capability_unavailable 404, and on replay tell WHICH resource was absent.
    "webhook_not_found" =>
      "Check the webhook id and :dataset in the URL — the endpoint does not exist in this scope.",
    "event_not_found" =>
      "Check the event id — GET /v1/webhooks/:dataset/:id/deliveries lists this endpoint's recent event ids.",
    # `duplicate_task` is BUILT below (find-or-create gate) but had no hint, so
    # it was silently absent from known_codes/0 → the served enum omitted a code
    # every task-create caller can receive. Registering the hint re-enters it.
    "duplicate_task" =>
      "This task duplicates an existing one — claim/extend the task in details.similar, or resend with distinct_from set to that id to confirm it is genuinely different."
  }

  # ── Public codes emitted INLINE by other v1 controllers / plugs ──────────────
  # These never pass through build/1 (the controller or plug writes the error
  # envelope directly), yet they DO reach the wire on PUBLIC /v1 endpoints that a
  # spec-generated SDK consumes. Registering them here keeps known_codes/0 — and
  # therefore the OpenAPI `Error.code` enum (openapi.ex) and docs/api-v1.md §9 —
  # a truthful SUPERSET of what public endpoints emit, so a generated client can
  # never meet an undeclared enum variant and throw/drop the response. Each entry
  # names its emitter. The subset invariant (every public-endpoint code ∈
  # known_codes ∪ off-spec exclusions) is guarded by
  # test/barkpark_web/contract/error_code_coverage_test.exs.
  #
  # These have no hint (the hint table is a fix-suggestion index for envelopes
  # THIS module builds; the emitting controllers own their own messages), so they
  # are kept separate from @hints rather than diluting it.
  @public_inline_codes MapSet.new([
                         # Papers ingest / block-ops / proposals — bulldocs_ingest_controller.ex
                         "invalid_paper",
                         "malformed_op",
                         "invalid_op",
                         "malformed_proposal",
                         "invalid_proposal",
                         "missing_source",
                         "source_not_found",
                         "constraint",
                         # Sheets ops API — plugins/sheets/web/ops_controller.ex
                         "malformed_ops",
                         "batch_too_large",
                         "session_unavailable",
                         "invalid_request_id",
                         # Media collection share link expired — v1/media_collections_controller.ex
                         "share_expired",
                         # Access-grant claim + token / ticket-key create (422) —
                         # access_controller.ex, token_controller.ex, ticket_keys_controller.ex
                         "invalid_grant",
                         "unprocessable",
                         # Step-up auth challenges — require_recent_mfa.ex,
                         # require_org_mfa_enrolment.ex (an SDK must branch on these)
                         "mfa_required",
                         "mfa_enrolment_required"
                       ])

  def to_envelope(reason), do: to_envelope(reason, nil)

  @doc """
  The set of stable `code` strings the public v1 surface can emit — the
  canonical §9 error vocabulary (docs/api-v1.md). It is the union of the @hints
  keys (codes `build/1` produces, each with a fix-suggesting hint) and
  @public_inline_codes (codes emitted directly by other v1 controllers/plugs).
  `Barkpark.Api.OpenApi` reads this to build the `Error.code` enum, and a test
  pins spec↔runtime parity so a code added here without a spec regen fails CI;
  a second test (error_code_coverage_test.exs) pins the reverse — that every
  code a public endpoint emits is a member here (or an explicit off-spec
  exclusion) — so the vocabulary can never silently under-report reality again.
  """
  @spec known_codes() :: MapSet.t()
  def known_codes do
    @hints |> Map.keys() |> MapSet.new() |> MapSet.union(@public_inline_codes)
  end

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

  # Resource-CODED not_found — same 404 semantics, but a resource-specific code
  # for the few endpoints whose consumers must discriminate which resource was
  # missing (webhook replay: endpoint vs event) or a real not-found from a
  # route-missing capability_unavailable 404. The code MUST be registered in
  # @hints — that keeps it in known_codes/0 (so the served OpenAPI Error.code
  # enum stays truthful) and gives the envelope a matching hint.
  defp build({:error, {:not_found, code, message}})
       when is_binary(code) and is_binary(message) do
    true = Map.has_key?(@hints, code)
    %{code: code, message: message, status: 404}
  end

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

  # A multi-op batch mutation carried an HTTP If-Match header. One ETag cannot
  # unambiguously gate N potentially-different documents, and silently dropping
  # it (the pre-fix behavior) discarded the caller's optimistic-lock intent →
  # lost update with no 412. Fail CLOSED with a 400 that steers the caller to the
  # per-op ifRevisionID/ifMatch fence, which is batch-size-independent.
  defp build({:error, :unsupported_if_match_for_batch}),
    do: %{
      code: "unsupported_if_match_for_batch",
      message:
        "If-Match is unsupported on a multi-op batch; put an ifRevisionID/ifMatch " <>
          "inside each mutation instead",
      status: 400
    }

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

  # Claim-first idempotency: a concurrent request already holds a fresh claim on
  # this Idempotency-Key. 409 so the client retries (Stripe-style) — the handler
  # never runs, so a non-idempotent mutation cannot double-apply.
  defp build({:error, :idempotency_key_in_use}),
    do: %{
      code: "idempotency_key_in_use",
      message: "a request with this Idempotency-Key is already in progress",
      status: 409
    }

  # A plugin lifecycle hook (before_save / before_publish) returned
  # {:halt, reason}, vetoing the write. 409 Conflict with the CANONICAL
  # envelope so the bp CLI + SDK can key on error.code and read request_id —
  # MutateController used to emit a bare %{error: "halted", reason: reason}
  # here that carried no code/request_id and was invisible to every machine
  # consumer. The plugin's reason string becomes the message verbatim.
  defp build({:error, {:halted, reason}}),
    do: %{code: "halted", message: halt_message(reason), status: 409}

  # Find-or-create gate (task-obsession layer 1): a new task duplicates an
  # existing one. 409 Conflict; the similar-candidate list rides in `details` so
  # the CLI/SDK can show the author which task to claim/extend, or which id to
  # pass in `distinct_from` to confirm it is genuinely different.
  defp build({:error, {:duplicate_task, payload}}) when is_map(payload),
    do: %{
      code: "duplicate_task",
      message: Map.get(payload, :message, "task duplicates an existing task"),
      status: 409,
      details: Map.take(payload, [:similar, :advise])
    }

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

  # A schema upsert (`POST /v1/schemas/:dataset`) whose `fields` payload is
  # structurally invalid — `SchemaDefinition.parse/2` rejected it (missing field
  # name, unknown v2 type, reserved `plugin:` prefix, non-list fields, …). Fail
  # CLOSED with a 422 at write time under the canonical `validation_failed` code,
  # instead of persisting the bad definition and blowing up later when a document
  # of the type is validated. The parse reason rides in `details` so the caller
  # can see exactly which rule tripped.
  defp build({:error, {:invalid_schema_fields, reason}}),
    do: %{
      code: "validation_failed",
      message: "schema fields failed validation: #{schema_reason(reason)}",
      status: 422,
      details: %{reason: schema_reason(reason)}
    }

  # DELETE /v1/schemas/:dataset/:name refused because documents of the type still
  # exist — deleting the schema would orphan them (afterwards every public read
  # of those docs 404s, since `schema_public?` is false). 409 Conflict; the
  # caller either deletes the documents first or repeats with `?force=true`. The
  # orphan `count` rides in `details` so the caller can gauge the blast radius.
  defp build({:error, {:schema_has_documents, count}}) when is_integer(count),
    do: %{
      code: "schema_has_documents",
      message:
        "schema still has #{count} document(s) of this type; " <>
          "delete them or pass ?force=true to remove the schema and orphan them",
      status: 409,
      details: %{count: count}
    }

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

  # A media upload was rejected by the config-gated allowlist (Media.upload →
  # validate_upload): the server-derived MIME / extension is not in the operator's
  # allowlist. 422 Unprocessable Entity with the canonical envelope. Only fires
  # when an allowlist is configured — an unconfigured server is allow-all and
  # never emits this.
  defp build({:error, :unsupported_media_type}),
    do: %{
      code: "unsupported_media_type",
      message: "media type is not allowed",
      status: 422
    }

  # A media upload exceeded the config-gated per-upload byte cap (Media.upload →
  # validate_upload). Reuses the canonical `payload_too_large`/413 envelope the
  # endpoint's 100 MB body bound also emits, so a caller keys on one code for
  # "too big" regardless of which bound tripped. Only fires when max_upload_bytes
  # is configured — an unconfigured server has no media-layer cap.
  defp build({:error, :payload_too_large}),
    do: %{
      code: "payload_too_large",
      message: "media file exceeds the maximum allowed size",
      status: 413
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

  # Render a `SchemaDefinition.parse/2` error term into a short, caller-facing
  # phrase. A `{tag, detail}` tuple keeps its detail (e.g. the reserved field
  # name); a bare atom is spelled out; anything else is inspected verbatim.
  defp schema_reason({tag, detail}) when is_atom(tag),
    do: "#{humanize_atom(tag)} (#{inspect(detail)})"

  defp schema_reason(reason) when is_atom(reason), do: humanize_atom(reason)
  defp schema_reason(reason), do: inspect(reason)

  defp humanize_atom(atom), do: atom |> to_string() |> String.replace("_", " ")

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
