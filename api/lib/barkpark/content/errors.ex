defmodule Barkpark.Content.Errors do
  @moduledoc "Maps internal error tuples to v1 JSON error envelopes."

  require Logger

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
    "duplicate_of" =>
      "This publish near-duplicates an already-published document; the details.duplicate_of id names it. Extend that document — or, if this publish REPLACES it, declare content.supersedes with that id and republish.",
    "validation_failed" => "Fix the listed validation errors to match the schema, then resubmit.",
    "schema_has_documents" =>
      "Delete the documents of this type first, or repeat the request with ?force=true to remove the schema and orphan them.",
    "invalid_filter" =>
      "Use one of the documented filter operators (eq, neq, in, nin, has, hasStrong, contains, startsWith, endsWith, gt, gte, lt, lte, is) — check for a typo or wrong case.",
    "forbidden_field" =>
      "Filter/order only on fields your token can read; use an admin/owner token, or query a field that isn't private in this schema.",
    "halted" =>
      "A plugin's lifecycle hook vetoed this write — read the message for the policy that rejected it, then adjust the document to satisfy it (or disable the plugin).",
    "label_spine" =>
      "Give the document a non-trivial description and 1-12 weighted tags — [{tag, strength 1-100 (all distinct), rationale}] — then republish; details lists each field, the rule it broke, and the fix, and you can repair the SAME draft in place rather than re-filing. If a published document appears to break the same rule, it is probably GRANDFATHERED: the wall reads an exemption once at entry and lets an exempt doc past a spine failure unchanged, while a birth is never exempt — so an incumbent is not evidence that your content passes. Learn where the authoring standards live in the doctrine papers /papers/portabledoc-doctrine and /papers/composition-doctrine-plan.",
    "invalid_paper_structure" =>
      "Fix the listed block paths so every list item, table row/cell, and nested block has a reader-supported content shape, then republish.",
    "invalid_epic_paper_quality" =>
      "Repair the canonical Epic Paper's opening, outline, empty spacers, and any declared reader checks; details.failures names every hard gate that failed.",
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
      "This task duplicates an existing one — claim/extend the task in details.similar, or resend with distinct_from set to that id to confirm it is genuinely different.",
    # Authoring-excellence publish wall, E3 gate (charter D3/D5).
    "unknown_tag" =>
      "Every tags[].tag must be a registered tag — publish a type:tag document whose _id is the tag name, or switch to one of the registered tags in details.suggestions, then publish again.",
    # Per-workspace quota gate at the mutate seam (perfect-plan-build W1, D11).
    "workspace_suspended" =>
      "This workspace is suspended — no writes are accepted until an operator reinstates it. Contact your workspace admin; details.reason names why.",
    # The unscoped-WRITE ruling (task-6fa023cdabdc5f6a, main 2026-09-05).
    "workspace_scope_required" =>
      "This write named no workspace and your credential could mean more than one (or none), so it was refused rather than attributed to a tenant nobody chose. Say where it goes: send the write to /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset, or use a token bound to a single workspace. details.workspaces lists the slugs this credential can write to.",
    # THE ONE RULE's refusal (task-49eef068420df918 + task-baf9b74a0ffc83f4) —
    # `Barkpark.Tasks.TwinResolver`: a task doc_id living in more than one
    # dataset of one workspace/project, asked for by a caller who named none.
    "ambiguous_dataset" =>
      "This task id exists in more than one dataset in this workspace/project, so the door refused rather than pick one for you. Name the dataset you mean (?dataset=<name> on the task route), or collapse the twin — details.datasets lists every dataset that holds the id.",
    # The PRODUCER half of the same rule — `Barkpark.Tasks.DatasetTwinFence`.
    "dataset_twin" =>
      "A task with this _id already exists in another dataset of this workspace/project, and a second copy would make the id ambiguous for every by-id reader. Write to the dataset that already holds it (details.datasets), use a different _id, or — if a genuinely separate copy is intended — resend with content.dataset_twin_intended: true.",
    # quota_exceeded stays the LAST entry: scaffy/commands/add-error-shape.scaffy
    # anchors its hint-append on this exact comma-free tail.
    "quota_exceeded" =>
      "This workspace has reached its write quota (details.quota). Remove documents to free capacity, or raise the workspace's quota."
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
                         "invalid_enrollment",
                         # Herd-s6 fenced state report (chat_host_controller.ex
                         # report_state): an off-vocabulary state or a
                         # missing/non-integer lease epoch — refused before the
                         # store is touched.
                         "invalid_state_report",
                         # Site-deploy status by build_id (search-template W6 D34) —
                         # site_deploy_controller.ex: a status probe naming a build
                         # this box is not running answers an honest 404, never a
                         # stale slug-keyed ghost.
                         "build_id_mismatch",
                         # Site-deploy trigger — site_deploy_controller.ex
                         # `runner_unavailable/1`: a 503 (with `retry-after`)
                         # for a deploy runner that did not answer in time. It
                         # is deliberately NOT `feature_not_configured`: the box
                         # is busy or wedged, and an operator sent to "set the
                         # apply flag" is sent to a flag that is already set.
                         # PUBLIC, so it is declared here rather than excluded —
                         # a spec-generated SDK must expect this variant on a
                         # deploy trigger.
                         "deploy_runner_unavailable",
                         # Papers ingest / block-ops / proposals — bulldocs_ingest_controller.ex
                         "invalid_paper",
                         "invalid_text",
                         "malformed_op",
                         "invalid_op",
                         # BPML (masterplan W0–W2) — bulldocs_ingest_controller.ex +
                         # bulldocs_source_controller.ex. `bpml` wraps the parser's
                         # teaching errors (parse failure on publish or an op
                         # fragment); the others are the format=bpml read path and
                         # the validate-all dry-run's violation codes.
                         "bpml",
                         "bpml_unavailable",
                         "bpml_unprintable",
                         "unknown_format",
                         "hollow_paper",
                         "structure",
                         "malformed_proposal",
                         "invalid_proposal",
                         "missing_source",
                         "source_not_found",
                         "constraint",
                         # BPML create-on-push (masterplan W3, charter D41) —
                         # bulldocs_ingest_controller.ex sync_create/6. A push to
                         # an ABSENT slug births the paper through the full publish
                         # wall; `slug_mismatch` (422) refuses when the document's
                         # own <paper slug> disagrees with the pushed path, and
                         # `create_wall` (422) carries EVERY wall violation under
                         # `errors` when the birth is refused — both write NOTHING.
                         # PUBLIC on /v1/plugins/bulldocs, so a spec-generated SDK
                         # must expect these variants on the sync route. Each
                         # envelope carries its own controller-owned `hint`, so
                         # (like every code in this set) they take no @hints entry.
                         "slug_mismatch",
                         "create_wall",
                         # BPML working-copy rev anchor — bulldocs_source_controller.ex
                         # (the format=bpml pull) + bulldocs_ingest_controller.ex
                         # (the sync precondition). Both read ONE owner,
                         # `Content.Papers.op_rev/1`: an ABSENT `content["rev"]`
                         # is the legitimate revless shape and anchors on 0, but a
                         # `content["rev"]` that is PRESENT and not an integer is a
                         # failed READ, and a failed read must never be spelled as
                         # a rev mismatch. Both routes refuse it with this 422
                         # naming the doc and the field instead of comparing
                         # against a value nobody could derive. PUBLIC on both
                         # /papers/:slug/source and /v1/plugins/bulldocs, so a
                         # spec-generated SDK must expect this variant on either.
                         "paper_rev_unreadable",
                         # Session-handoff (tasks 3-4) — the session legs of the
                         # SAME controller. `missing_slug` (422, an upsert body
                         # with no slug), `invalid_kind` (422, an event kind
                         # outside `Content.Sessions.event_kinds/0` — the
                         # envelope carries the allowed list) and
                         # `conflict_retry` (409, the append-only trail's
                         # CAS-on-rev lost a race; the caller retries the
                         # append, nothing was written). Registered rather than
                         # folded into the canonical `malformed`/`conflict`
                         # because each names a distinct, actionable condition
                         # the neighbours above already set the precedent for.
                         "missing_slug",
                         "invalid_kind",
                         "conflict_retry",
                         # Session-conversations slice: a touch_session_conversation
                         # call with a nil/non-binary/empty conversation id
                         # (`Barkpark.Content.Sessions.touch_conversation/5`).
                         "invalid_conversation",
                         # Sheets ops API — plugins/sheets/web/ops_controller.ex
                         "malformed_ops",
                         "batch_too_large",
                         # SPLIT (was one `session_unavailable` answering two
                         # statuses): 503 when the session is restarting after a
                         # crash loop (retryable, carries retry-after), 422 when
                         # it could not start at all (permanent). One token could
                         # not carry both retryability contracts.
                         "session_restarting",
                         "session_start_failed",
                         "invalid_request_id",
                         # 503 + retry-after: the exactly-once replay ring has no
                         # table to read, so the session refuses the batch
                         # (fail-CLOSED) rather than re-apply a non-idempotent op
                         # it can no longer recognise. Nothing was applied; the
                         # same request_id succeeds once the ring is back. Its own
                         # token rather than `session_restarting` because the
                         # SESSION is fine — only the ring is gone.
                         "replay_unavailable",
                         # Media collection share link expired — v1/media_collections_controller.ex
                         "share_expired",
                         # Access-grant claim + token / ticket-key create (422) —
                         # access_controller.ex, token_controller.ex, ticket_keys_controller.ex
                         "invalid_grant",
                         "unprocessable",
                         # Step-up auth challenges — require_recent_mfa.ex,
                         # require_org_mfa_enrolment.ex (an SDK must branch on these)
                         "mfa_required",
                         "mfa_enrolment_required",
                         # Workspace bundle merge-import (PDS W1) —
                         # v1/workspace_controller.ex: import disabled by the
                         # fail-closed guard (403), an unknown import mode (422),
                         # and a workspace-slug collision on adopt (409).
                         "bundle_import_disabled",
                         # SPLIT (was `invalid_mode`, shared with the UNRELATED
                         # site-deploy mode validator at a different status):
                         # this is the bundle-IMPORT mode (422).
                         "invalid_import_mode",
                         # …and this is the site-DEPLOY mode (400,
                         # sites/deploy_request.ex).
                         "invalid_deploy_mode",
                         "workspace_slug_conflict",
                         # A bundle row colliding with resident target content on
                         # a constraint the merge arbiter does not cover (any
                         # non-PK unique index) — 409 naming constraint + table
                         # (task-63a199c0a0ce2a06; used to escape as a blind 500).
                         "import_constraint_violation",
                         # A bundle carrying media blob paths a RESIDENT
                         # workspace (or an unscoped legacy row) already owns
                         # (409, task-918106d49c62563e). The blob keyspace is
                         # flat, so two owners at one path make the loser's own
                         # scoped media read serve the winner's bytes — refused
                         # at row-copy time, never imported silently.
                         "blob_path_conflict",
                         # The import engine returned an {:error, term} no
                         # clause names — a logged, NAMED 500 whose message
                         # carries the term, replacing the silent internal_error
                         # the round-3 live fire died on (task-96d8ab2b582818a4).
                         "import_failed",
                         # Bounded import (PDS W23) — v1/workspace_controller.ex
                         # spills the request body to disk and extracts member by
                         # member instead of materialising the bundle in memory.
                         # Each names a distinct operational failure the caller can
                         # act on, and each replaces what would otherwise be a
                         # blind 500: the socket read failed mid-body (400), the
                         # body exceeded the configured ceiling (413), the spill
                         # file could not be written (500), and the spill target
                         # had no room for it (507).
                         "import_body_read_failed",
                         "import_body_too_large",
                         "import_spill_write_failed",
                         "insufficient_disk_space",
                         # Workspace bundle EXPORT (PDS W3) — v1/workspace_controller.ex:
                         # the export stream failed or timed out before the tar completed.
                         # SPLIT (was one `export_failed` answering two statuses
                         # with opposite retryability): the workspace bundle
                         # export's transport failure is 503 and RETRYABLE…
                         "export_transport_failed",
                         # …while the sheets xlsx build failure is 422 and
                         # PERMANENT (plugins/sheets/web/export_controller.ex).
                         "export_build_failed",
                         # Chat transport send/create failures (chat_controller.ex,
                         # charter D26 reason split — mobile/TUI clients branch on
                         # these: 5xx → transient retry, 4xx → refused/permanent).
                         # 503 + Retry-After: the managed runtime pool is full.
                         "runtime_capacity",
                         # 503: the runtime is not there right now (dead process,
                         # closed port, runtime-gone) — retryable.
                         "runtime_unavailable",
                         # 422: the provider/operation combination can never
                         # succeed as asked — permanent, do not retry.
                         "chat_unsupported",
                         # 503: creating the session row/spawn failed — a store
                         # defect distinct from runtime availability.
                         "chat_create_failed"
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
    |> stamp(conn)
  end

  @doc """
  Stamp the additive `hint` (code-keyed) and `request_id` onto an ALREADY-built
  envelope map (`%{code, message, status, ...}`).

  This is the ONE place `request_id` is resolved — from `Logger.metadata()`
  (populated by `Plug.RequestId` at the endpoint, which runs BEFORE the router)
  with an `x-request-id` response-header fallback. `to_envelope/2` and the
  plug/inline emitters in `BarkparkWeb.ErrorResponse` both funnel through here,
  so no error path (auth plug, parse-body rescue, controller) can silently drop
  the id an operator greps the logs with.
  """
  @spec stamp(map(), Plug.Conn.t() | nil) :: map()
  def stamp(env, conn) when is_map(env) do
    env
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

  # MEMBERSHIP refusal, deliberately distinct from the permission-tier refusal
  # above (gyldendal field report #15). `ResolveWorkspace` halts here when the
  # caller is simply not a member of the workspace named in the URL — a question
  # about WHO the caller is, not about which permissions their credential
  # carries. The generic arm's copy ("token lacks required permission", hinting
  # "use a token with write/admin permission") names a tier this gate never
  # consulted, and that one sentence is what filed a Studio AUTHENTICATION bug
  # as a permission bug: the reporter went hunting for a token scope while the
  # browser was in fact sending no credential at all.
  #
  # `code` stays "forbidden" (stable machine key, already in the OpenAPI enum —
  # clients keying on it are unchanged) and the STATUS stays 403: a read denial
  # surfaces as 403, never as a 404 not-found. `reason` discriminates for a
  # client that wants it, exactly as the `:replay` arm does under
  # "unauthorized", and the arm carries its OWN hint — `put_hint/1` only fills
  # in the code-keyed default when a `build/1` arm has not spoken for itself.
  defp build({:error, :forbidden_membership}),
    do: %{
      code: "forbidden",
      message: "caller is not a member of this workspace",
      status: 403,
      reason: "not_a_member",
      hint:
        "This is a MEMBERSHIP check, not a permission tier: sign in as — or send a token belonging to — a member of this workspace. A browser session authenticates on any route that reads the session cookie, including the scoped media writes — no data-token is required for those."
    }

  # Per-workspace quota gate (perfect-plan-build W1, D11). Suspended = a hard
  # 403 write-block; over-quota = 402 Payment Required (the honest "you hit your
  # plan's write cap" semantic, distinct from a 429 rate limit that clears on
  # backoff). `reason`/`quota` ride details so a client can surface the wall.
  defp build({:error, :workspace_suspended}),
    do: %{code: "workspace_suspended", message: "workspace is suspended", status: 403}

  defp build({:error, {:workspace_suspended, reason}}),
    do: %{
      code: "workspace_suspended",
      message: "workspace is suspended",
      status: 403,
      details: %{reason: reason}
    }

  # ── The unscoped-WRITE refusal (task-6fa023cdabdc5f6a) ──────────────────────
  #
  # A write arrived with NO workspace scope and its principal could have meant
  # zero workspaces (a platform / global-admin token) or several. The ruling is
  # infer-when-unambiguous, REFUSE-when-ambiguous: nothing is written and the
  # caller is told which door to send it through.
  #
  # 422, not 400/409/403 — read off this module's own vocabulary:
  #
  #   * `malformed` (400) is a BODY-SHAPE failure ("send a well-formed JSON body
  #     matching the endpoint's expected shape"). This body is perfectly well
  #     formed; the request is unprocessable for a reason the parser cannot see.
  #   * `conflict` (409) is a resource-STATE collision ("the document already
  #     exists"). Nothing collided; no state is involved.
  #   * `forbidden` (403) would be a lie: the caller is very likely ENTITLED to
  #     write — to one of several workspaces. It must choose, not be denied.
  #
  # 422 is the slot this codebase already uses for "well-formed, but I cannot
  # act on it as sent" — `slug_mismatch`, `create_wall`, `invalid_grant`,
  # `batch_too_large`. This is that.
  #
  # `details.workspaces` carries the slugs the caller CAN write to (empty for a
  # platform token), so the refusal is actionable in one hop instead of a
  # round-trip to GET /v1/workspaces.
  defp build({:error, :workspace_scope_required}),
    do: %{
      code: "workspace_scope_required",
      message: "this write named no workspace and the caller's scope is ambiguous",
      status: 422
    }

  defp build({:error, {:workspace_scope_required, workspaces}}) when is_list(workspaces),
    do: %{
      code: "workspace_scope_required",
      message: "this write named no workspace and the caller's scope is ambiguous",
      status: 422,
      details: %{workspaces: workspaces}
    }

  defp build({:error, :quota_exceeded}),
    do: %{code: "quota_exceeded", message: "workspace write quota exceeded", status: 402}

  defp build({:error, {:quota_exceeded, quota}}),
    do: %{
      code: "quota_exceeded",
      message: "workspace write quota exceeded",
      status: 402,
      details: %{quota: quota}
    }

  # Oversize mutate batch — BarkparkWeb.Plugs.RequireWithinQuota. Deliberately
  # REUSES the sheets ops door's already-registered `batch_too_large` (422): the
  # meaning ("your batch exceeds this endpoint's cap — split and resend") and the
  # status are identical, and a second token for it would have grown the public
  # Error.code enum and docs/api-v1.md §9 for no client-visible gain. The hint is
  # set here rather than in @hints because the code lives in
  # @public_inline_codes, whose entries are owned by their inline emitters.
  defp build({:error, {:batch_too_large, n, max}}) when is_integer(n) and is_integer(max),
    do: %{
      code: "batch_too_large",
      message: "the mutations list carries #{n} mutations; the cap is #{max} per request",
      status: 422,
      details: %{count: n, max: max},
      hint: "Split the batch into requests of at most #{max} mutations and resend."
    }

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

  # A block list carrying an element that is not an object. `render_blocks/2`
  # guards the LIST (`is_list`) but `render_block/2` guards the ELEMENT
  # (`is_map`), so `{"body":{"blocks":["notamap"]}}` used to clear the outer
  # guard and raise FunctionClauseError inside the WRITE projection — an
  # uncaught 500 whose body was an HTML debug page, violating §9 ("all errors
  # are {code, message, request_id}") and leaving the caller no request_id to
  # correlate. Refused at the writer door instead (Content.Writer
  # `refuse_non_map_block_elements/1`), under the EXISTING `malformed` code —
  # this is a request-body shape error, not a schema validation failure, and
  # reusing the registered code keeps `known_codes/0` (and therefore the
  # OpenAPI `Error.code` enum + docs/api-v1.md §9) unchanged. `details.blocks`
  # names every offending path so a client can fix the exact element.
  defp build({:error, {:malformed_blocks, details}}),
    do: %{
      code: "malformed",
      message: "block list contains an element that is not an object",
      status: 400,
      details: details
    }

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
          "valid operators: " <>
          Enum.join(Barkpark.Content.Query.valid_filter_ops(), ", "),
      status: 400,
      details: %{field: field, op: op}
    }

  # The SAME refusal, raised from INSIDE the query builder rather than caught at
  # a controller door — `Barkpark.Content.InvalidFilterError` (defined at the
  # bottom of this file). Every door that does not pre-guard its filter map now
  # inherits this envelope through `BarkparkWeb.ErrorJSON`, so the code stays
  # `invalid_filter` and the status stays 400 instead of collapsing to a generic
  # `internal_error` 500.
  #
  # It names the OP but NOT the field: a builder-raised refusal does not inherit
  # `QueryController.forbidden_query_field/4`'s ordering (that gate runs before
  # the query is built, and never runs at all for internal doors), so echoing a
  # caller-supplied field name back out of the builder would sit past the
  # field-visibility gate. See the exception's moduledoc.
  defp build({:error, %Barkpark.Content.InvalidFilterError{} = e}),
    do: %{
      code: "invalid_filter",
      message: e.message,
      status: 400,
      # `op` is caller data of ANY shape (an atom key, a nested map from
      # array-bracket syntax), so it is rendered to a string here — a raw term
      # would raise inside Jason and cost the client its response.
      details: %{op: if(is_binary(e.op), do: e.op, else: inspect(e.op))}
    }

  # The modern /v1/data/query flat `--filter` string (QueryController.
  # normalize_filter_map/1). A non-empty string neither grammar family parses
  # used to fall through to an EMPTY filter map — fail-OPEN, the filter
  # silently discarded and every row returned (D75). Fail CLOSED with the same
  # "invalid_filter" code, naming the accepted flat grammar so the caller can
  # fix the string instead of trusting a result that was never filtered.
  defp build({:error, {:invalid_flat_filter, raw}}),
    do: %{
      code: "invalid_filter",
      message:
        "malformed filter #{inspect(raw)}; expected field<op>value " <>
          "(op: = == != > >= < <= ^= $= *=), '<field> is [not] null', " <>
          "'<field> [not] in a,b,c', or '<field> hasStrong <tag>:<min>'",
      status: 400,
      details: %{filter: raw}
    }

  # A filter clause that names a DOCUMENTED operator but whose value or shape
  # this route cannot honour — a non-scalar `eq`, a malformed `hasStrong`
  # value, an out-of-range `is`, a `$or` boolean group, two conflicting clauses
  # on one field. Same "invalid_filter" code (so it inherits the registered
  # @hints entry) as its siblings, but the MESSAGE is caller-supplied: the
  # shared `invalid_filter_op` wording CONTRADICTED ITSELF here — a malformed
  # `hasStrong` VALUE was reported as `unknown filter operator "hasStrong"` by
  # a message that went on to list hasStrong among the valid operators, and a
  # `filter[$or][0][…]` group reported `"0"` as the offending operator. Details
  # keep `field`/`op` where they are meaningful, so a caller parsing the
  # envelope reads the same keys `invalid_filter_op` emits.
  defp build({:error, {:invalid_filter_clause, message, details}})
       when is_binary(message) and is_map(details),
       do: %{code: "invalid_filter", message: message, status: 400, details: details}

  # The legacy `/api/documents/:type?filter=...` surface's flat "field=value"
  # string parser (LegacyController.parse_legacy_filter/1). A non-empty string
  # that doesn't split into a field=value pair (e.g. "price>10") used to fall
  # through to an empty filter map — fail-OPEN, silently returning every
  # document. Fail CLOSED with the same "invalid_filter" code the modern
  # /v1/data/query surface uses for filter garbage (no new envelope code).
  defp build({:error, {:invalid_filter, raw}}),
    do: %{
      code: "invalid_filter",
      message: "malformed filter #{inspect(raw)}; expected \"field=value\"",
      status: 400,
      details: %{filter: raw}
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

  # The task dedup gate could not RUN (PDS wave 24). It carries its OWN internal
  # tag rather than reusing `:halted`, and that distinction is load-bearing
  # rather than cosmetic: `halted` means a policy DELIBERATELY vetoed the write,
  # so consumers treat it as deterministic and stop retrying —
  # `Plugins.Github.Intake` answers a clean 2xx on `{:halted, _}` on the explicit
  # reasoning that "GitHub redelivery would only hit the same veto forever". A
  # dedup outage is the opposite: TRANSIENT. Sharing the tag made a DB hiccup
  # into a permanently dropped GitHub issue, logged as a policy refusal that
  # never happened. The tag split is what lets Intake route the two apart.
  #
  # ON THE WIRE it is a 503 carrying its OWN hint — the same transient shape
  # `storage_unavailable` (below) already uses, and the answer a caller can act
  # on: the scan never ran, so nothing was written and nothing was refused on
  # the merits, and the correct move is to RESEND THE IDENTICAL REQUEST. It
  # shipped as a 409 whose code-keyed `halted` hint reads "adjust the document
  # to satisfy it" — an OUTAGE described to the caller as a policy decision,
  # sending an author to edit a document that is fine (charter D542). 409 also
  # told every generic client the opposite of the truth: a 4xx is the caller's
  # fault and terminal, while this is the server's and retryable.
  #
  # WHY THE `code` IS "storage_unavailable" AND NOT "halted". One public code
  # maps to ONE status: the CLI's exit-code table (internal/cli/errors.go) is
  # keyed on `code`, and internal/cli/errors_api_parity_test.go refuses a code
  # that this file emits at two statuses — `halted` at 409 (the plugin veto)
  # AND 503 (this arm) reddened main on 2026-09-02. Minting `dedup_unavailable`
  # as a new code is blocked too: a code must be registered in `@hints`, which
  # puts it in `known_codes/0`, which drives the served OpenAPI `Error.code`
  # enum (docs/openapi.json, behind a CI drift gate) and the documented
  # vocabulary `docs/api-v1.md` §9 UNION `docs/api/error-codes.md`
  # (errors_doc_coverage_test). PDS wave 25's relocation freed the §9 bytes
  # that used to make that unaffordable, so minting the code is now a cheap
  # change filed on its own row — what stays unaffordable is a SECOND status
  # for `halted`, which is the constraint this arm actually answers. So the arm
  # wears the code that already IS the transient-storage shape — public, 503,
  # exit 8, retry-is-the-right-reflex — and `reason: "dedup_unavailable"`
  # discriminates it from a media-volume fault, exactly as `:replay` does under
  # "unauthorized". The arm carries its OWN `hint`, so `put_hint/1` never
  # reaches the media-volume sentence for this term.
  defp build({:error, {:dedup_unavailable, reason}}),
    do: %{
      code: "storage_unavailable",
      message: halt_message(reason),
      status: 503,
      reason: "dedup_unavailable",
      hint:
        "Transient: the duplicate-scan could not complete, so this write was " <>
          "neither stored nor refused on its merits. Resend the identical " <>
          "request. If it keeps failing the database is degraded — this is an " <>
          "outage to report, not a document to fix."
    }

  # The database connection was lost MID-WRITE on the create path
  # (`Content.Writer.do_create_document/5`'s rescue): a pool checkout dropped
  # from the queue, a `tcp recv: closed`, a statement killed with the
  # connection. Before this arm existed the raise escaped the Writer entirely
  # and Phoenix RenderErrors rendered it through `BarkparkWeb.ErrorJSON` as 500
  # `internal_error / "unknown error (DBConnection.ConnectionError)"` — the
  # WRONG CLASS of answer. `BarkparkCloud.Sites.Deploy.transient_refusal?/1`
  # grants retry grace by matching the error CODE and `internal_error` is not on
  # its transient list, and the CLI's `internal_error` hint says to "report the
  # request_id to the API operator": a condition that clears on its own was
  # described to every caller as a permanent server defect to escalate.
  #
  # WHY THE `code` IS "storage_unavailable" (the `dedup_unavailable` reasoning
  # above, applied a second time). One public code maps to ONE status —
  # `internal/cli/errors.go` keys the CLI exit code on `code` and
  # `internal/cli/errors_api_parity_test.go` refuses a code this file emits at
  # two statuses — and minting a brand-new code is a four-place change
  # (`@hints` → `known_codes/0` → the served OpenAPI `Error.code` enum behind a
  # drift gate → `docs/api-v1.md` §9 under a byte cap). This arm is the same
  # transient-storage SHAPE the sibling already wears: public, 503, CLI exit 8,
  # retry-is-the-right-reflex. `reason: "connection_unavailable"` discriminates
  # it from a media-volume fault and from the dedup-scan outage, exactly as
  # `:replay` does under "unauthorized".
  #
  # THE MESSAGE CARRIES THE AMBIGUITY. Unlike the dedup outage — where the scan
  # never ran, so provably nothing was written — a connection lost mid-write
  # leaves the caller unable to know whether the draft row landed. The Writer
  # builds that sentence (it names `bp doc ls task --perspective drafts`) and it
  # rides through verbatim, because telling a caller to "resend the identical
  # request" without telling them to CHECK FIRST walks them into the dedup wall
  # and a duplicate-of-your-own-first-attempt refusal.
  defp build({:error, {:connection_unavailable, reason}}),
    do: %{
      code: "storage_unavailable",
      message: halt_message(reason),
      status: 503,
      reason: "connection_unavailable",
      hint:
        "Transient: the database connection dropped mid-write, so this write " <>
          "was neither confirmed nor refused on its merits. CHECK WHETHER IT " <>
          "LANDED before retrying — `bp doc ls task --perspective drafts` for " <>
          "a task, otherwise re-read the id you sent — then resend the " <>
          "identical request only if it did not. If it keeps failing the " <>
          "database is degraded: an outage to report, not a document to fix."
    }

  # The publish wall's label spine (authoring-excellence D5): the document
  # failed `Barkpark.Content.LabelSpine.validate` at publish and is not in the
  # legacy exemption ledger. 422 with the validator's documentation-grade
  # details (field / rule / fix per violation) verbatim, so the one agent
  # retry can be exact. A NEW top-level atom — deliberately NOT the
  # task-scoped invalid_task_content and NOT the plugin {:halted, _} shape
  # (this is core enforcement, not a plugin veto).
  defp build({:error, {:label_spine, details}}),
    do: %{
      code: "label_spine",
      message: "document failed the publish wall's label spine",
      status: 422,
      details: details
    }

  defp build({:error, {:invalid_paper_structure, details}}),
    do: %{
      code: "invalid_paper_structure",
      message: "paper contains block content that readers cannot render",
      status: 422,
      details: details
    }

  defp build({:error, {:invalid_epic_paper_quality, details}}),
    do: %{
      code: "invalid_epic_paper_quality",
      message: "canonical Epic Paper failed the publish-quality floor",
      status: 422,
      details: details
    }

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

  # THE ONE RULE, READ SIDE (task-49eef068420df918 + task-baf9b74a0ffc83f4).
  # `Barkpark.Tasks.TwinResolver` RAISES this rather than picking a row when a
  # task doc_id lives in more than one dataset and the caller named none. 409 —
  # the `conflict` family: a resource-STATE collision, never a server fault, so
  # it must not collapse to `internal_error` on the RenderErrors path (the
  # pass-through clause in `BarkparkWeb.ErrorJSON` is what keeps this body).
  # `details.datasets` is the caller's remedy: it names every dataset that holds
  # the id, which is exactly what `?dataset=` needs.
  defp build({:error, %Barkpark.Tasks.AmbiguousTwinError{} = e}),
    do: %{
      code: "ambiguous_dataset",
      message: e.message,
      status: 409,
      details: %{doc_id: e.doc_id, datasets: e.datasets}
    }

  # THE ONE RULE, PRODUCER SIDE (task-49eef068420df918 C2).
  # `Barkpark.Tasks.DatasetTwinFence` refuses a task birth that would put an
  # existing (doc_id, type) into a SECOND dataset of the same workspace+project
  # — the 2026-08-07 sequence that made the eleven live twins. 409, same family
  # as `duplicate_task`: the row is not invalid, the LEDGER state collides.
  defp build({:error, {:dataset_twin, payload}}) when is_map(payload),
    do: %{
      code: "dataset_twin",
      message:
        Map.get(payload, :message, "task id already exists in another dataset of this project"),
      status: 409,
      details: Map.take(payload, [:doc_id, :datasets, :dataset, :advise])
    }

  # Publish dedup wall (authoring-excellence E4): a publish near-duplicates an
  # already-published document. 409 Conflict; the incumbent published id rides in
  # `details.duplicate_of` so the author can claim/extend it, and `details.similar`
  # lists every near-match with its similarity score. UNLIKE `duplicate_task`
  # above, this code carries a registered `@hints` entry (so it is a member of
  # `known_codes/0` and truthful in the served OpenAPI enum) — the drift-guard is
  # a tautology, so a DELIBERATE membership test pins it (see errors_test.exs).
  defp build({:error, {:duplicate_of, payload}}) when is_map(payload),
    do: %{
      code: "duplicate_of",
      message: Map.get(payload, :message, "document duplicates an already-published document"),
      status: 409,
      details: Map.take(payload, [:duplicate_of, :similar, :advise])
    }

  # Authoring-excellence publish wall, E3 gate (TagRegistry.validate_publish):
  # a publish referenced weighted tags[].tag names with no PUBLISHED type:tag
  # doc in the dataset scope. 422 with the unknown names and the trgm-nearest
  # registered tags in `details`, so an authoring agent's retry is one edit
  # away. NEW top-level code per charter D1 — never reuses the task-scoped
  # `invalid_task_content` or the plugin `{:halted, _}` shape.
  defp build({:error, {:unknown_tag, payload}}) when is_map(payload) do
    unknown = Map.get(payload, :unknown, [])

    %{
      code: "unknown_tag",
      message: "publish references unregistered tag(s): " <> Enum.join(unknown, ", "),
      status: 422,
      details: Map.take(payload, [:unknown, :suggestions])
    }
  end

  # A write's `dataset` STRING was REFUSED by dataset-row resolution
  # (WriteScope fail-closed contract, felix-w26-bl-write-scope-swallow-nil):
  # the Tenancy.Dataset changeset rejected the slug (format/length). 422 under
  # the canonical `validation_failed` code — already an @hints member, so
  # known_codes/OpenAPI are untouched — with the changeset messages re-keyed
  # under "dataset" (the key the caller actually sent; the row's :slug is an
  # internal name). Replaces the old silent degrade to a dataset_id=NULL stamp.
  defp build({:error, {:invalid_dataset, details}}) when is_map(details),
    do: %{
      code: "validation_failed",
      message: "dataset failed validation",
      status: 422,
      details: details
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
  # Mutate-path schema validation, ENFORCE arm (task-41a740fd6701ec28). Only
  # reachable when the write's dataset opted in via
  # `config :barkpark, Barkpark.Content.Validation, enforce_datasets: [...]` —
  # the DEFAULT advises (warnings in the success envelope) and never reaches
  # here. Same canonical `validation_failed` code and same per-field `details`
  # map shape as the `unknown_fields` refusal already on that door, so the CLI
  # and SDK need no new code path.
  defp build({:error, {:schema_validation_failed, errors}}) when is_map(errors) do
    %{
      code: "validation_failed",
      message: "document content failed schema validation",
      status: 422,
      details: errors
    }
  end

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

  # THE DELIBERATE "no fault in scope" SENTINEL, narrowed OUT of the catch-all.
  # `BarkparkWeb.ErrorJSON` renders `{:error, :unknown}` when Phoenix's
  # RenderErrors hands it a 500 carrying no `:kind`/`:reason` at all — there is
  # genuinely nothing to name, and its moduledoc promises the message is then
  # exactly "unknown error". Giving it its own clause is what lets the catch-all
  # below speak and LOG freely: every term that still reaches the catch-all is by
  # definition an unanticipated shape, never this one, so its log line is signal
  # rather than noise.
  defp build({:error, :unknown}),
    do: %{code: "internal_error", message: "unknown error", status: 500}

  # ── CATCH-ALL: an unanticipated reason term. NEVER BARE, NEVER SILENT ───────
  #
  # This clause used to render `message: "unknown error"` and log nothing, so an
  # operator holding the request_id learned exactly two things: that it was a
  # 500, and nothing else. THE REMEDY FOR THAT ALREADY EXISTED — TWICE — AND THE
  # CODE PATH ROUTES AROUND BOTH:
  #
  #   * the 2026-08-09 fault-family fix (#11364), which makes a crash-path 500
  #     name its fault family, lives in `BarkparkWeb.ErrorJSON` — and a RETURNED
  #     `{:error, term}` never reaches ErrorJSON at all; and
  #   * `BarkparkWeb.FallbackController`'s "NEVER SILENT ON 5xx" log
  #     (task-96d8ab2b582818a4) fires only for controllers that actually delegate
  #     to it — `BarkparkWeb.MutateController`, the write door the whole task
  #     ledger is filed through, declares `action_fallback` but renders these
  #     envelopes itself from `Errors.to_envelope/2`, so it never triggers.
  #
  # Both remedies are therefore re-seated HERE, in the one place every caller of
  # `to_envelope/2` inherits them without a controller edit: the message carries
  # a shape DESCRIPTOR in the same `unknown error (<family>)` form ErrorJSON
  # established, and the term is logged BEFORE the envelope is returned. A caller
  # that also routes through FallbackController now logs twice; two lines about
  # one defect is the cheap side of that trade.
  #
  # WHAT IS DISCLOSED, AND WHAT IS NOT. The descriptor speaks TAGS and TYPE NAMES
  # only — `{:some_tag, map}`, `%Ecto.StaleEntryError{}`, `:whatever` — never a
  # value. Binaries, numbers, list elements and map KEYS (which is where a JSON
  # body's caller-supplied strings land) all collapse to a type name, so no
  # document field, token, filter string or user text can ride out on a 500. The
  # full term is still `inspect`ed into the SERVER-SIDE log, bounded exactly as
  # FallbackController already bounds it.
  #
  # The `code` stays byte-identical "internal_error":
  # `BarkparkCloud.Sites.Deploy.transient_refusal?/1` grants its retry grace by
  # matching the CODE, and moving it turns that grace terminal (error_json.ex).
  defp build(other) do
    descriptor = reason_descriptor(other)

    Logger.error(
      "Barkpark.Content.Errors: no build/1 clause matched a returned error term — " <>
        "rendering 500 internal_error (#{descriptor}). " <>
        "term=#{inspect(other, limit: 25, printable_limit: 500)}"
    )

    %{code: "internal_error", message: "unknown error (#{descriptor})", status: 500}
  end

  # Longest descriptor the envelope will carry. A pathological term (a deeply
  # nested tuple) can only cost this many graphemes of the message.
  @descriptor_max_chars 120

  # `{:error, reason}` is described by its REASON — the tag the caller actually
  # returned. Anything else (a bare term, or an unmatched 3-tuple such as
  # `{:error, :rate_limited, opts}`) is described whole.
  defp reason_descriptor({:error, reason}), do: clamp_descriptor(term_family(reason))
  defp reason_descriptor(term), do: clamp_descriptor(term_family(term))

  # A struct is named by its MODULE (a compile-time name); a tuple by its
  # elements' families, so a tagged tuple keeps its tag; everything else by its
  # type name alone.
  defp term_family(%{__struct__: mod}), do: "%#{inspect(mod)}{}"

  defp term_family(tuple) when is_tuple(tuple),
    do: "{" <> (tuple |> Tuple.to_list() |> Enum.map_join(", ", &term_family/1)) <> "}"

  defp term_family(term), do: type_name(term)

  # Atoms are code-authored vocabulary — every `{:error, tag}` in this tree is a
  # literal, and a decoded JSON body yields STRINGS, never atoms — so an atom is
  # spoken verbatim; it is the part an operator routes on. Everything that can
  # carry caller bytes is reduced to its type and nothing else.
  defp type_name(v) when is_atom(v), do: inspect(v)
  defp type_name(v) when is_binary(v), do: "binary"
  defp type_name(v) when is_bitstring(v), do: "bitstring"
  defp type_name(v) when is_integer(v), do: "integer"
  defp type_name(v) when is_float(v), do: "float"
  defp type_name(%{__struct__: mod}), do: "%#{inspect(mod)}{}"
  defp type_name(v) when is_map(v), do: "map"
  defp type_name(v) when is_list(v), do: "list"
  defp type_name(v) when is_function(v), do: "function"
  defp type_name(v) when is_pid(v), do: "pid"
  defp type_name(v) when is_reference(v), do: "reference"
  defp type_name(v) when is_port(v), do: "port"
  defp type_name(_v), do: "term"

  defp clamp_descriptor(s) when byte_size(s) <= @descriptor_max_chars, do: s
  defp clamp_descriptor(s), do: String.slice(s, 0, @descriptor_max_chars) <> "…"

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

  # Code-keyed DEFAULT hint. A `build/1` arm that already set its own `:hint`
  # has spoken more precisely than the code-wide table can — two arms may share
  # one `code` and still need different fixes (`:forbidden` vs
  # `:forbidden_membership`) — so the arm's hint wins.
  defp put_hint(%{hint: hint} = env) when is_binary(hint) and hint != "", do: env

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
