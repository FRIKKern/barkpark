package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/apierr"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// apiError is the decoded outcome of a non-2xx (or error-shaped) API response.
// It carries the exit code already mapped per docs/cli/error-exit-table.md, plus
// a human message and the request id for support.
type apiError struct {
	exit       int
	code       string
	message    string
	requestID  string
	serverHint string // envelope `hint` field — the server's per-error fix suggestion
	// localHint is a hint derived from the DISPATCHED COMMAND rather than from
	// the error code alone. The code-keyed table below cannot see which command
	// ran, so its not_found entry had to describe one shape and described the
	// document one: "check the type/id and --dataset; run `bp schema ls` to list
	// types". On `bp token revoke <id>` both halves are wrong — that route
	// carries no :dataset, and `bp schema ls` lists content schemas, which
	// cannot tell you a token id. notFoundHint fills this in when the manifest
	// can name the enumerating sibling verb for real. Ranked below serverHint
	// (the server knows most) and above the code table (which knows least).
	localHint string
	// details is the envelope `details` object VERBATIM, kept as raw JSON. The
	// server sets it on 18 error paths and its shape is per-code — {field:[…]}
	// for validation_failed, {field,rule,fix,index} for label_spine,
	// {similar:[…]} for duplicate_task, {filter:"…"} for invalid_filter. It is
	// deliberately NOT decoded into a typed map: a typed decode fits exactly one
	// of those shapes and fails the whole unmarshal on the others (the
	// mutateErrorMessage bug), so the ONE payload that explains the refusal is
	// the first thing lost. Raw bytes survive every shape and re-serialize
	// byte-identically into the -o json / -o yaml envelope.
	details json.RawMessage
	// arm is the server's own machine-readable discriminator for WHICH refusal
	// arm fired, carried as a TOP-LEVEL sibling of `reason` on the
	// {"ok":false,…} task shape (tasks_controller.not_ready_arm/2 emits
	// "held_by_other" | "queue_gated" | "not_claimable_status" | "unknown").
	// It exists for ONE decision: a bare `not_ready` used to look causeless to
	// the client, so the claim wrapper's read-back was free to guess. It is not
	// causeless — a NAMED arm means the store already stated a positive reason,
	// and no local guess may contradict it. "" means the body carried no arm.
	arm string
	// credentialSent records whether the request that earned this refusal
	// actually carried a credential (an Authorization header). It exists for
	// ONE decision: a 401 must never tell a caller to obtain a credential they
	// already sent. `bp auth me` with a saved instance token was answered
	// "authentication required — set BARKPARK_API_TOKEN or run: bp setup …",
	// which named a remedy the caller had already applied — the real gate is a
	// login SESSION, which the server said in its own message and the CLI threw
	// away. Set from the dispatched request's headers (run.go), so it is a fact
	// about what was sent, not a guess from config.
	credentialSent bool
}

// codeExit is the SINGLE canonical error.code -> exit mapping (contract spine
// rule #3). The CLI keys on the envelope's `code` string and NEVER re-derives an
// exit code from the HTTP status. Source: docs/cli/error-exit-table.md.
var codeExit = map[string]int{
	"not_found":      exitNotFound,
	"schema_unknown": exitNotFound,
	"share_expired":  exitNotFound, // 410, bucketed as gone/not-found
	"unauthorized":   exitAuth,
	"forbidden":      exitAuth,
	// A filter/order over a field the caller may not read — semantically a
	// permission denial (use a token that can read the field), so the auth
	// bucket, even though the HTTP status is 422. Added when QueryController /
	// LegacyController moved forbidden_field to the canonical envelope (#571);
	// before that it was a bare-string `error` with no code and fell to exit 1.
	"forbidden_field": exitAuth,
	"cors_forbidden":  exitAuth,
	"csrf_required":   exitAuth,
	// The cloud control plane's team gate: the caller's login has no ACTIVE TEAM.
	// Deliberately NOT the auth bucket even though it now arrives as a 403 — exit 3
	// means "your credential is bad", and here the credential is fine; the fix is
	// `bp team use <team>`, not a re-login. It kept exit 1 for the whole life of the
	// 422 shape and must keep it now that the gate answers 403 with
	// {"error":"forbidden","reason":"no_team"} (cch-w40-s4).
	"no_team":   exitGeneric,
	"malformed": exitUsage,
	// An unknown filter operator (?filter[f][bogus]=x) — a malformed request,
	// same bucket as `malformed`. Added when the query API began rejecting
	// unknown ops instead of silently returning every row (#570).
	"invalid_filter":    exitUsage,
	"validation_failed": exitValidation,
	"invalid_paper":     exitValidation,
	"malformed_op":      exitValidation,
	"invalid_op":        exitValidation,
	"block_not_found":   exitValidation,
	"type_mismatch":     exitValidation,
	"duplicate_id":      exitValidation,
	// Blob-push refusals from the media put_blob route (the sidecar channel
	// `bp cloud workspace import --with-blobs` writes to). Both are 422s emitted
	// BEFORE any byte touches disk — a traversal/malformed relative path, and an
	// empty body (usually a mislabeled content-type Plug.Parsers already ate).
	// Absent from this table they fell to the exit-1 unknown-code bucket, which
	// reads as "unexpected" for what is a plainly invalid payload (PDS-D52).
	"invalid_path":        exitValidation,
	"empty_body":          exitValidation,
	"rev_mismatch":        exitConflict,
	"precondition_failed": exitConflict,
	"conflict":            exitConflict,
	// A plugin lifecycle veto. The bare-string {"error":"halted"} shape is still
	// special-cased in classifyError (exit 6), but once the server moved halt to
	// the CANONICAL {"error":{"code":"halted"}} envelope (#559/#560) it arrives
	// via error.code and MUST be in this table too — otherwise it regressed from
	// exit 6 to the exit-1 unknown-code fallback.
	"halted": exitConflict,
	// Task claim/close contention — all 409 shapes from /v1/tasks/*. Absent
	// from this table they fell to the unknown-reason usage bucket (exit 2),
	// so `bp task close` with a stale epoch exited as if the COMMAND LINE were
	// wrong. The cheatsheet's contract is 6 = conflict.
	"fenced_off":                  exitConflict,
	"stale_claim":                 exitConflict,
	"not_ready":                   exitConflict,
	"blocked_by_unsatisfied_deps": exitConflict,
	"already_claimed":             exitConflict,
	"resource_conflict":           exitConflict,
	// The stamp/close refusal vocabulary (PDS-D371). Every one of these used to
	// land on exit 2 — the SAME code as a malformed `--met --miss` command line —
	// so a retry wrapper could not tell "the world moved, re-claim and retry"
	// apart from "your arguments are wrong, give up". They split by RETRYABILITY:
	//   6 (conflict): the lease/state moved under you — re-read, re-claim, retry.
	"not_holder":      exitConflict,
	"not_in_progress": exitConflict,
	// One id, one row (#16474): the twin resolver REFUSES an ambiguous task id and
	// the producer fence refuses a second copy — both answer 409.
	"ambiguous_dataset":       exitConflict,
	"dataset_twin":            exitConflict,
	"doc_changed_since_claim": exitConflict,
	"claimed_has_worker":      exitConflict,
	//   5 (validation): the REQUEST is wrong — never retryable as sent.
	// illegal_transition is emitted with :unprocessable_entity (a 422) and is the
	// one member of this family that can never succeed on a retry, so it belongs
	// with the payload guards rather than the conflict bucket.
	// The reporter loop. A `done`/`cancelled` close of a `gh-<num>` row born from
	// an outsider's GitHub issue, refused while its ack_gate criterion is unmet.
	// VALIDATION, not conflict: nothing moved under the caller and re-sending the
	// identical command can never succeed — the fix is an action OUTSIDE this
	// request (post the comment, stamp the criterion) or an explicit
	// `--set ack_override="<reason>"`. Mints compound as
	// `acknowledgement_unposted:<issue>`; the family lookup keys on the part
	// before the colon.
	"acknowledgement_unposted":    exitValidation,
	"criteria_mismatch":           exitValidation,
	"criteria_index_out_of_range": exitValidation,
	"criterion_text_required":     exitValidation,
	"note_required":               exitValidation,
	"illegal_transition":          exitValidation,
	// The four the D371 split MISSED, every one measured at exit 2 before this
	// block (probe through the real `bp task close` dispatch, 2026-08-24) — the
	// SAME code as a malformed command line, which is the exact confusion the
	// split exists to remove. Note the shape: the tasks controller refuses with
	// {"ok":false,"reason":…} (tasks_controller.ex conflict/3), whose branch
	// falls back to exitUsage (2), NOT the coded-envelope branch's exitGeneric
	// (1) — so reading the fallback off exitForCode alone gets the wrong number.
	//
	// They bucket as validation and not conflict because nothing moved under
	// the caller in any of the four: re-sending the identical request can never
	// succeed, and every fix is an act OUTSIDE the request.
	//
	//   criteria_unmet:<i,j>      a `done` close over unmet criteria. Fix:
	//                             `bp task stamp` them, or close on the record
	//                             with `--set criteria_override=`.
	//   invalid_lifecycle:<s>     the close names a status the transition table
	//                             disallows (tasks/close.ex:107). A different
	//                             status is a different request.
	//   sentinel_worker_id:<w>    the worker id is a placeholder — "none",
	//                             "null", "nil", "-" (tasks/internal.ex:179).
	//                             A real identity is a different request.
	//   merge_gated_criterion     a builder `--met` on a criterion the LEAD
	//                             closes at merge (tasks/stamp.ex:275). Fix:
	//                             `--merge-gated`, or set "merge_gate": false.
	//
	// The first three carry their detail inline and reach the table through
	// reasonKey's family lookup; merge_gated_criterion is minted bare.
	"criteria_unmet":        exitValidation,
	"invalid_lifecycle":     exitValidation,
	"sentinel_worker_id":    exitValidation,
	"merge_gated_criterion": exitValidation,
	// The close-artifact gate (PDS-D291). A `done` close of a kind:task row with
	// ZERO acceptance criteria whose reason names no PR+sha and pastes no run
	// output. It buckets with `criteria_unmet` and NOT with the conflict family
	// for the same reason the whole 5/6 split exists: nothing moved under the
	// caller, and re-sending the identical command can never succeed. Every fix
	// is an act OUTSIDE this request — name the artifact in the reason, add the
	// acceptance criteria the row should have carried, close it `cancelled`, or
	// pass `--set close_reason_override="<why>"`. Minted BARE (no `:<detail>`
	// suffix): the refusal's whole content is the ruling, which rides the
	// top-level `message` the server computes (tasks_controller/params.ex
	// criteria_hint/2) and `bodyMessage` prints in place of this token.
	"close_reason_needs_artifact": exitValidation,
	// task-650d7844d8fe7199: a `cancelled` close with a blank reason. Same code
	// as its siblings — the request is wrong and re-sending it cannot help.
	"cancel_reason_required": exitValidation,
	"rate_limited":           exitRateLimit,
	"internal_error":         exitServer,

	// ── The API-parity backfill (task-2a774c5536503306) ───────────────────
	//
	// The "code, never status" rule above is safe ONLY while this table is a
	// SUPERSET of what the API can emit. It was not: measured against
	// `Barkpark.Content.Errors.known_codes/0` (api/lib/barkpark/content/
	// errors.ex — the union of @hints keys and @public_inline_codes), 61 of its
	// 81 codes were absent here, so exitForCode fell to exitGeneric (1) for
	// each. The JS SDK got them right, because js/packages/core/src/
	// transport.ts classifies on `status === X || code === '…'` with the status
	// as PRIMARY discriminator. One response, two layers, two answers.
	//
	// The remedy is the TABLE, not the reader: each code below is bucketed by
	// the HTTP status the API actually returns for it, verified at its emitter.
	// TestCodeExitCoversKnownAPICodes now fails when known_codes/0 gains a
	// member neither registered here nor listed in codeExitNotWireBucketable,
	// so this drift cannot silently reopen.

	// 401/403 → auth. The credential (or the second factor) is the problem.
	"mfa_required":           exitAuth, // 401, require_recent_mfa.ex:57
	"invalid_enrollment":     exitAuth, // 401, chat_host_controller.ex:112
	"mfa_enrolment_required": exitAuth, // 403, require_org_mfa_enrolment.ex:73
	"workspace_suspended":    exitAuth, // 403, errors.ex:348
	"bundle_import_disabled": exitAuth, // 403, workspace_controller.ex:450

	// 404 → not-found.
	"webhook_not_found": exitNotFound, // 404, webhook_controller.ex:288
	"event_not_found":   exitNotFound, // 404, webhook_controller.ex:280
	"build_id_mismatch": exitNotFound, // 404, site_deploy_controller.ex:323

	// 400 → usage, the same bucket `malformed` and `invalid_filter` already
	// occupy: the REQUEST as framed is wrong, not the document in it.
	"unsupported_if_match_for_batch": exitUsage, // 400, errors.ex:402
	"import_body_read_failed":        exitUsage, // 400, workspace_controller.ex:1011
	"unknown_format":                 exitUsage, // 400, bulldocs_source_controller.ex:28

	// 422/413/402 → validation. Never retryable AS SENT — the distinction that
	// matters to a wrapper, and the one exit 1 destroyed by folding these in
	// with network timeouts.
	//
	// Two of these carry a name/status tension worth stating rather than
	// quietly "fixing": `source_not_found` sounds like a 404 but the API
	// answers 422 (bulldocs_ingest_controller.ex:1478 — the referenced doc did
	// not resolve, nothing was written), and `payload_too_large` is a 413.
	// Both are bucketed by the status their emitter actually returns, because
	// bucketing on the NAME is exactly the guesswork this table exists to end.
	"label_spine": exitValidation, // 422, errors.ex:561
	"unknown_tag": exitValidation, // 422, errors.ex:620
	// workspace_scope_required: an unscoped WRITE whose credential could mean
	// more than one workspace (task-6fa023cdabdc5f6a ruling, errors.ex:413-425).
	// 422 -> validation; the fix is in the request (a /w/:ws/p/:proj path or a
	// single-workspace token), never a retry.
	"workspace_scope_required":   exitValidation, // 422, errors.ex:417
	"invalid_paper_structure":    exitValidation, // 422, errors.ex:569
	"invalid_epic_paper_quality": exitValidation, // 422, errors.ex:577
	"unsupported_media_type":     exitValidation, // 422, errors.ex:724
	"chat_unsupported":           exitValidation, // 422, chat_controller.ex:948
	"unprocessable":              exitValidation, // 422, search_controller.ex:527
	"batch_too_large":            exitValidation, // 422, sheets/ops_controller.ex:131
	"invalid_request_id":         exitValidation, // 422, sheets/ops_controller.ex:87
	"malformed_ops":              exitValidation, // 422, sheets/ops_controller.ex:100
	"invalid_grant":              exitValidation, // 422, access_controller.ex:189
	"invalid_state_report":       exitValidation, // 422, chat_host_controller.ex:95
	"bpml":                       exitValidation, // 422, bulldocs_ingest_controller.ex:237
	"bpml_unavailable":           exitValidation, // 422, bulldocs_source_controller.ex:77
	"bpml_unprintable":           exitValidation, // 422, bulldocs_ingest_controller.ex:273
	"constraint":                 exitValidation, // 422, bulldocs_ingest_controller.ex:354
	"create_wall":                exitValidation, // 422, bulldocs_ingest_controller.ex:432
	"invalid_conversation":       exitValidation, // 422, bulldocs_ingest_controller.ex:1151
	"invalid_kind":               exitValidation, // 422, bulldocs_ingest_controller.ex:1102
	"invalid_proposal":           exitValidation, // 422, bulldocs_ingest_controller.ex:1493
	"malformed_proposal":         exitValidation, // 422, bulldocs_ingest_controller.ex:1438
	"invalid_text":               exitValidation, // 422, bulldocs_ingest_controller.ex:1635
	"missing_slug":               exitValidation, // 422, bulldocs_ingest_controller.ex:938
	"missing_source":             exitValidation, // 422, bulldocs_ingest_controller.ex:1446
	"paper_rev_unreadable":       exitValidation, // 422, bulldocs_ingest_controller.ex + bulldocs_source_controller.ex
	"slug_mismatch":              exitValidation, // 422, bulldocs_ingest_controller.ex:401
	"source_not_found":           exitValidation, // 422, bulldocs_ingest_controller.ex:1478
	"payload_too_large":          exitValidation, // 413, errors.ex:736
	"import_body_too_large":      exitValidation, // 413, workspace_controller.ex:992
	// 402. There is no payment/quota bucket in the 0-8 scheme, and inventing
	// one would redefine the published table. 5 is the honest neighbour: it
	// says "not retryable as sent", which is the fact a wrapper needs.
	"quota_exceeded": exitValidation, // 402, errors.ex:359

	// 409 → conflict. The world moved, or already holds this — re-read/retry.
	"duplicate_task":              exitConflict, // 409, errors.ex:589
	"duplicate_of":                exitConflict, // 409, errors.ex:604
	"idempotency_key_in_use":      exitConflict, // 409, errors.ex:515
	"schema_has_documents":        exitConflict, // 409, errors.ex:696
	"conflict_retry":              exitConflict, // 409, bulldocs_ingest_controller.ex:1117
	"workspace_slug_conflict":     exitConflict, // 409, workspace_controller.ex:513
	"import_constraint_violation": exitConflict, // 409, workspace_controller.ex:651
	"blob_path_conflict":          exitConflict, // 409, workspace_controller.ex:592

	// 5xx → server. The box failed, not the request: the ONE class where a
	// retry is the right reflex, and the class exit 1 made indistinguishable
	// from a permanently-refused payload.
	"storage_unavailable":       exitServer, // 503, errors.ex:712
	"runtime_unavailable":       exitServer, // 503, chat_controller.ex:943
	"runtime_capacity":          exitServer, // 503, chat_controller.ex:934
	"chat_create_failed":        exitServer, // 503, chat_controller.ex:146
	"deploy_runner_unavailable": exitServer, // 503, site_deploy_controller.ex:299
	"import_failed":             exitServer, // 500, workspace_controller.ex:575
	"import_spill_write_failed": exitServer, // 507, workspace_controller.ex:1035
	"insufficient_disk_space":   exitServer, // 507, workspace_controller.ex:1051

	// THE THREE AMBIGUOUS TOKENS, SPLIT AT THE SOURCE. Each of these used to be
	// one code answering two statuses with OPPOSITE retryability, which is why
	// they sat in codeExitNotWireBucketable at exit 1 — no single exit could be
	// honest about both arms. The API now mints one code per arm, so each token
	// carries exactly one meaning and buckets cleanly.
	"export_transport_failed": exitServer,     // 503, workspace_controller.ex (bundle export transport — RETRY)
	"export_build_failed":     exitValidation, // 422, sheets/export_controller.ex (xlsx build — PERMANENT)
	"invalid_import_mode":     exitValidation, // 422, workspace_controller.ex (bundle import mode)
	"invalid_deploy_mode":     exitValidation, // 400, sites/deploy_request.ex (site deploy mode)
	"session_restarting":      exitServer,     // 503 + retry-after, sheets/ops_controller.ex (crash loop — RETRY)
	"session_start_failed":    exitValidation, // 422, sheets/ops_controller.ex (session could not start — PERMANENT)
	"replay_unavailable":      exitServer,     // 503 + retry-after, sheets/ops_controller.ex (exactly-once ring unreadable; batch NOT applied — RETRY)
}

// codeExitNotWireBucketable names the members of known_codes/0 that are
// DELIBERATELY absent from codeExit, each with the reason. It exists so the
// parity gate can tell "considered and excluded, here is why" apart from
// "nobody noticed" — the whole failure mode this row retired. Adding a code
// here instead of to codeExit is a decision that must be argued in review, not
// a way to silence the gate.
//
// TWO KINDS live here, and they are not the same problem:
//
//  1. NEVER A TOP-LEVEL `error.code`. These are violation-list entries nested
//     inside another response's body (`paper_structure_violations` /
//     `structure_violation`), so classifyError never sees them in `error.code`
//     and an exit mapping for them would be dead weight. They are legitimately
//     in known_codes/0 because a client must still recognise them INSIDE that
//     list.
//
//  2. THE API ANSWERED TWO DIFFERENT STATUSES FOR ONE CODE. This kind is now
//     EMPTY, and that is the point. `export_failed`, `invalid_mode` and
//     `session_unavailable` each answered two statuses with opposite
//     retryability, so no single exit could be honest about both arms — exit 8
//     would spin a retry wrapper forever on the permanent arm, exit 5 would
//     abandon a recoverable one. They were parked here at exitGeneric (1),
//     which was at least true ("unknown"), while the fix was filed against the
//     API. The API has since SPLIT each into one code per arm
//     (export_transport_failed/export_build_failed,
//     invalid_import_mode/invalid_deploy_mode,
//     session_restarting/session_start_failed), so all six now live in codeExit
//     above with a real bucket. If this kind ever reappears, the fix belongs in
//     the API — splitting the token — not in a new entry here.
var codeExitNotWireBucketable = map[string]string{
	"hollow_paper": "never a top-level error.code — a violation map inside the paper structure list (bulldocs_ingest_controller.ex:163), returned under an outer 200 (dry-run validate) or 422 (create_wall)",
	"structure":    "never a top-level error.code — structure_violation/1's fallback violation map (bulldocs_ingest_controller.ex:589-590), same outer-body story as hollow_paper",
}

// reasonKey reduces a COMPOUND server reason token to its table key. The tasks
// controller mints reasons that carry their detail inline — `not_holder:<worker>`,
// `not_in_progress:<status>`, `criteria_unmet:<indices>`, `invalid_lifecycle:<s>`,
// `sentinel_worker_id:<w>` (api/lib/barkpark_web/controllers/tasks_controller/
// params.ex, reason_to_string/1) — and a literal map key misses every one of
// them. Splitting at the FIRST ':' keeps the family name and drops the detail.
// It reads the reason STRING only; it never consults the HTTP status, so the
// contract-spine rule at the top of this file (code, never status) holds.
func reasonKey(code string) string {
	if i := strings.IndexByte(code, ':'); i >= 0 {
		return code[:i]
	}
	return code
}

// lookupExit is the ONE codeExit lookup — the literal code first, then its
// compound-token family name. It reports whether the code was KNOWN, because
// the two callers disagree about the fallback: exitForCode falls back to
// exitGeneric (the table's documented unknown-envelope-code rule) while the
// {"ok":false,"reason":…} branch falls back to exitUsage (preserving the
// historical add-edge `invalid_edge` behaviour). Both MUST consult the same
// table the same way: before this existed, classifyError did a second LITERAL
// codeExit lookup that overrode a compound-token match back to exit 2.
func lookupExit(code string) (int, bool) {
	if e, ok := codeExit[code]; ok {
		return e, true
	}
	if key := reasonKey(code); key != code {
		if e, ok := codeExit[key]; ok {
			return e, true
		}
	}
	return exitGeneric, false
}

// exitForCode maps an envelope error.code to a process exit code. An unknown or
// empty code falls back to exitGeneric (1), per the table's documented fallback.
func exitForCode(code string) int {
	e, _ := lookupExit(code)
	return e
}

// requestIDHeader is the response header Plug.RequestId stamps on EVERY reply
// the API sends, error or not. It is the id an operator quotes to correlate a
// failure against the server's logs.
const requestIDHeader = "X-Request-Id"

// requestIDFromHeader reads the correlation id off a response header set.
// http.Header canonicalises keys, so the wire casing (`x-request-id`) does not
// matter here.
func requestIDFromHeader(h http.Header) string {
	if h == nil {
		return ""
	}
	return strings.TrimSpace(h.Get(requestIDHeader))
}

// lastResponse holds the header set of the most recent HTTP response this
// process received. It exists because the request id lives in TWO places and
// only one of them is reliable: the API stamps `x-request-id` on every reply at
// the endpoint, before the router, while the BODY field `request_id` is written
// per-emitter — and dozens of hand-built error envelopes never write it. The
// JS SDK already resolves this the right way round (body field first, response
// header second) and therefore reports an id where bp reported none, on the
// same response.
//
// Recorded at the ONE send every dispatch path funnels through rather than
// threaded through ~40 classifyError call sites, none of which asked for a
// header and most of which sit behind three-value helpers (doRequest,
// doRequestStream) that discard it by design. Every response overwrites it,
// including one with no such header (which clears it), so the value can only
// ever describe the latest reply — never a stale one from an earlier command.
var lastResponse struct {
	mu     sync.Mutex
	header http.Header
}

// noteResponseHeader records a response's headers for the request-id fallback.
// Called on every send, with whatever came back — including nil.
func noteResponseHeader(h http.Header) {
	lastResponse.mu.Lock()
	lastResponse.header = h
	lastResponse.mu.Unlock()
}

// lastResponseHeader returns the headers of the most recent response, or nil
// when this process has not made a request yet.
func lastResponseHeader() http.Header {
	lastResponse.mu.Lock()
	defer lastResponse.mu.Unlock()
	return lastResponse.header
}

// classifyError decodes an error response body and, when that body carries no
// request_id, falls back to the `x-request-id` header of the response it came
// from. Body first: an emitter that wrote the field meant that exact id, and a
// proxy could in principle rewrite the header.
func classifyError(status int, body []byte) apiError {
	return classifyErrorWithHeader(status, body, lastResponseHeader())
}

// classifyErrorWithHeader is classifyError with the response headers passed
// explicitly, for callers that hold them (and for tests that must not depend on
// process-wide state).
func classifyErrorWithHeader(status int, body []byte, hdr http.Header) apiError {
	ae := classifyErrorBody(status, body)
	if ae.requestID == "" {
		ae.requestID = requestIDFromHeader(hdr)
	}
	return ae
}

// classifyErrorBody decodes an error response body into an apiError with the mapped
// exit code. It handles, in order:
//
//   - the canonical envelope {"error":{"code":…,"message":…,"request_id":…}}
//   - the bare-string lifecycle veto {"error":"halted",…}     -> exit 6
//   - the tasks add-edge shape {"ok":false,"reason":"invalid_edge"} -> exit 2
//   - the intents/plugin-settings string error {"error":"not_found"} / "invalid"
//   - the message-only no-code envelope {"error":{"message":…}}  -> 2 (or 4 if
//     the message reads like a not-found)
//
// (See docs/cli/error-exit-table.md "Codes that don't cleanly fit".) Anything it
// cannot recognise becomes exitGeneric with the raw body as the message.
//
// This is the body-only decode; classifyError layers the header fallback on
// top of it.
func classifyErrorBody(status int, body []byte) apiError {
	// First: the canonical {"error": <object>} envelope, read through
	// internal/apierr — the ONE parser every surface shares. The struct that
	// used to live here was copied into seven other decoders that then drifted
	// (five stopped reading `hint`, one typed `details` and lost whole
	// envelopes); apierr exists so there is nothing left to copy. Only the
	// PARSE moved: the code→exit-code table below, the four alternative body
	// shapes, and this file's rendering are CLI-specific and stay here.
	//
	// The admission test is unchanged in effect — classifyError has always
	// required a non-empty code to claim this branch, so a message-only
	// envelope still falls through to the no-code arm further down that decides
	// between exit 2 and exit 4.
	if env, ok := apierr.Parse(body); ok && env.Code != "" {
		return apiError{
			exit:       exitForCode(env.Code),
			code:       env.Code,
			message:    env.Message,
			requestID:  env.RequestID,
			serverHint: env.Hint,
			details:    normalizeDetails(env.Details),
		}
	}

	// Bare string-valued `error` (lifecycle veto / intents / plugin-settings).
	var strErr struct {
		Error  string `json:"error"`
		Reason string `json:"reason"`
		OK     *bool  `json:"ok"`
		// Arm rides beside `reason` on the task refusal shape and names which
		// gate fired. See apiError.arm.
		Arm string `json:"arm"`
	}
	if err := json.Unmarshal(body, &strErr); err == nil && strErr.Error != "" {
		switch strErr.Error {
		case "halted":
			return apiError{exit: exitConflict, code: "halted", message: vetoMessage(strErr.Reason)}
		case "not_found":
			return apiError{exit: exitNotFound, code: "not_found", message: "not found"}
		case "invalid", "settings_object_required":
			return apiError{exit: exitUsage, code: strErr.Error, message: strErr.Error}
		default:
			// A refusal that names its CAUSE alongside a generic code — the shape
			// the cloud control plane's authority gates emit,
			// {"error":"forbidden","reason":"no_team","scope":"team"} — is classified
			// by the CAUSE. "forbidden" alone buckets as exit 3 ("your credential is
			// bad") and prints one word, which is a LIE for a login that merely has
			// no active team. Only a reason the canonical table KNOWS may re-key the
			// exit, so an unrecognised cause can never silently move an exit code;
			// the message keeps BOTH tokens so the machine code the server sent is
			// never hidden from the user.
			if strErr.Reason != "" {
				if e, known := lookupExit(strErr.Reason); known {
					return apiError{exit: e, code: strErr.Reason, message: strErr.Error + ": " + strErr.Reason}
				}
			}
			// A bare-string error the two branches above don't name (the cloud
			// router emits {"error":"illegal_transition"} this way). Route it
			// through the SAME table as the coded envelope so one token cannot
			// mean two exit codes depending on which shape carried it; an
			// unknown string still buckets conservatively as usage.
			if e, known := lookupExit(strErr.Error); known {
				return apiError{exit: e, code: strErr.Error, message: strErr.Error}
			}
			return apiError{exit: exitUsage, code: strErr.Error, message: strErr.Error}
		}
	}

	// {"ok":false,"reason":…} (tasks claim/add-edge). Route the reason through the
	// canonical code->exit table so a not_found reason lands on exit 4 (not the
	// blanket exit 2 this branch used to apply, which mislabeled task 404s). A
	// reason absent from the table still falls back to exitGeneric via
	// exitForCode; we keep usage for the historical add-edge `invalid_edge` shape
	// by letting the table miss surface there.
	if strErr.OK != nil && !*strErr.OK && strErr.Reason != "" {
		exit, known := lookupExit(strErr.Reason)
		if !known {
			// Unknown reason (e.g. invalid_edge): bucket conservatively as usage,
			// preserving the prior behaviour for the add-edge validation shape.
			exit = exitUsage
		}
		msg := strErr.Reason
		if m := bodyMessage(body); m != "" {
			msg = m
		}
		// The tasks 409 carries its remedy in a TOP-LEVEL `conflicts` array, a
		// sibling of `reason` rather than a member of an `error` object, so the
		// canonical branch above never sees it and this branch used to drop it.
		// Measured against guerrilla — the server sent
		//   {"ok":false,"reason":"resource_conflict",
		//    "conflicts":[{"worker":"build-lane-j","doc_id":"task-4b338…",
		//                  "resources":["internal/cli/run.go"]}]}
		// and `bp task claim … -o json` printed
		//   {"error":{"code":"resource_conflict","message":"resource_conflict"},"ok":false}
		// while `-o table` printed the single word `resource_conflict`. The
		// holder, the worker and the exact overlapping path — everything the
		// caller needs to wait, renegotiate or narrow the fence — was thrown
		// away by the client after the server had already computed it.
		// docs/cli/error-exit-table.md:110 has promised "`resource_conflict`
		// carries `conflicts[]` naming the holders" the whole time.
		// The SAME lift for the edited-under-you 409, whose two recovery values
		// (`current_rev`, `changed_fields`) are top-level siblings of `reason`
		// for exactly the same reason the conflicts array is — so this branch
		// dropped them too, and the hint below promised data the CLI had thrown
		// away. A body carries one shape or the other, never both, so the
		// conflicts payload keeps its bytes byte-for-byte.
		details := topLevelConflicts(body)
		if details == nil {
			details = topLevelDrift(body)
		}
		return apiError{exit: exit, code: strErr.Reason, message: msg, details: details, arm: strErr.Arm}
	}

	// Message-only no-code envelope: default usage, downgrade to not-found when
	// the message text reads like one.
	// Same shared parser as the canonical branch — this arm differs only in
	// that it accepts an envelope with NO code, which apierr.Parse admits (it
	// requires code OR message). Reaching here means the canonical branch above
	// already declined for want of a code.
	if env, ok := apierr.Parse(body); ok && env.Message != "" {
		exit := exitUsage
		if looksLikeNotFound(env.Message) {
			exit = exitNotFound
		}
		return apiError{exit: exit, message: env.Message}
	}

	// Truly unrecognised body: a non-JSON gateway/proxy page (nginx 502·503·504
	// HTML, a plain-text load-balancer banner) or JSON without any error field.
	// We could NOT read a `code`, so — unlike every envelope branch above — the
	// HTTP status is the ONLY signal. Key the exit bucket off it (statusExit) and
	// CAP the raw body (capBody) so a multi-KB HTML page never spews to stderr and
	// a 502 no longer misfiles as exit 1. Genuinely-JSON errors already returned
	// above, so the cap only ever trims opaque non-envelope bodies.
	return apiError{exit: statusExit(status), message: capBody(body)}
}

// statusExit maps a raw HTTP status to an exit bucket for a body we could NOT
// decode into a known error shape. It is the status-keyed fallback the canonical
// code->exit table (exitForCode) cannot cover because there is no `code`. A
// status of 0 or an unrecognised class falls to exitGeneric.
func statusExit(status int) int {
	switch {
	case status == 429:
		return exitRateLimit
	case status >= 500:
		return exitServer
	case status == 401, status == 403:
		return exitAuth
	case status == 404, status == 410:
		return exitNotFound
	case status >= 400:
		return exitUsage
	default:
		return exitGeneric
	}
}

// capBody trims an opaque (non-envelope) error body to a short, single-flavour
// message. A gateway 502/503/504 often returns a multi-KB HTML page or proxy
// banner; dumping it verbatim to stderr is noise. Keep the first ~200 runes
// (rune-safe, so a multibyte char is never split) and append an ellipsis. An
// empty body becomes "request failed".
func capBody(body []byte) string {
	msg := strings.TrimSpace(string(body))
	if msg == "" {
		return "request failed"
	}
	const maxRunes = 200
	if r := []rune(msg); len(r) > maxRunes {
		return strings.TrimSpace(string(r[:maxRunes])) + "…"
	}
	return msg
}

// renderErrorEnvelope emits the canonical {ok:false, error:{code, message,
// request_id, hint}} failure envelope on stdout when the resolved output is a
// machine shape (json/yaml), and reports whether it did (table/minimal return
// false so the caller prints its human stderr line instead). Empty request_id
// and hint keys are omitted, so a call passing only code+message reproduces
// useError's original two-field shape byte-for-byte. This is the ONE emitter the
// cloud/hetzner built-ins (via useError) and the manifest runner (via
// renderError) both route through, so a failing `bp <anything> -o json | jq`
// gets a parseable body on stdout rather than empty stdout.
func renderErrorEnvelope(out *writer, code, msg, requestID, hint string) bool {
	return renderErrorEnvelopeDetailed(out, code, msg, requestID, hint, nil)
}

// renderErrorEnvelopeDetailed is renderErrorEnvelope plus the envelope `details`
// object — the per-code payload that names WHICH field/filter/rule the server
// refused. docs/cli/error-exit-table.md has declared details part of the v1
// envelope since :15 (and tells the CLI to print it at :97, to read
// details.retry_after at :117, and names error.details as wire contract at :153);
// the CLI never complied, because the canon struct in classifyError did not
// declare the key and encoding/json dropped it. This is that compliance, and it
// is purely ADDITIVE: no existing key moves or changes type, and an empty/absent
// details is omitted, so renderErrorEnvelope's ~60 detail-less call sites emit
// byte-identical bytes through this delegation.
func renderErrorEnvelopeDetailed(out *writer, code, msg, requestID, hint string, details json.RawMessage) bool {
	errObj := map[string]any{"code": code, "message": msg}
	if requestID != "" {
		errObj["request_id"] = requestID
	}
	if hint != "" {
		errObj["hint"] = hint
	}
	if d := normalizeDetails(details); d != nil {
		errObj["details"] = d
	}
	m := map[string]any{"ok": false, "error": errObj}
	switch out.output {
	case "json":
		out.renderJSON(m)
		return true
	case "yaml":
		out.renderYAML(toGeneric(m))
		return true
	}
	return false
}

// useErrorDetailed is useError plus the envelope `details` payload — the same
// two-channel contract (machine envelope on stdout for -o json/yaml, human line
// on stderr otherwise) with a per-error `details` object routed through
// renderErrorEnvelopeDetailed. A nil/empty details reproduces useError's bytes
// exactly, so it is a safe superset. The human line NEVER carries the raw
// details — the caller folds whatever a human needs into `msg`; details is the
// machine-only channel a script parses.
func useErrorDetailed(out *writer, code, msg string, exit int, details json.RawMessage) int {
	if renderErrorEnvelopeDetailed(out, code, msg, "", "", details) {
		return exit
	}
	out.userErr("%s", msg)
	return exit
}

// normalizeDetails reduces a raw `details` value to either nil (nothing worth
// showing) or its COMPACT bytes. Nothing-worth-showing is: absent, JSON null,
// the empty object, the empty array, or bytes that are not valid JSON at all —
// the last so a malformed server payload can never make stdout unparseable under
// -o json. Compacting keeps key ORDER as the server sent it (raw bytes are never
// re-marshalled through a Go map, which would alphabetize them — the exact
// fingerprint that proved issue #4938 was observing bp and not the server).
func normalizeDetails(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return nil
	}
	switch buf.String() {
	case "", "null", "{}", "[]":
		return nil
	}
	return json.RawMessage(buf.Bytes())
}

// detailLines renders a `details` payload as the sorted `key: value` lines the
// human shapes (table/minimal) print above the hint. Scalars print VERBATIM (a
// string without its JSON quotes, so `filter: zzzgarbage` reads like a value and
// not like a fragment of a document); objects and arrays print as compact JSON,
// so a heterogeneous payload — {field,rule,fix,index}, {similar:[…]},
// {title:["can't be blank"]} — survives whole rather than being flattened to the
// one shape the CLI happened to expect. A details that is not an object at all
// (an array, or a bare scalar) prints as a single `details: …` line. Returns nil
// when there is nothing to print.
func detailLines(raw json.RawMessage) []string {
	d := normalizeDetails(raw)
	if d == nil {
		return nil
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(d, &obj); err != nil || len(obj) == 0 {
		return []string{"details: " + string(d)}
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	lines := make([]string, 0, len(keys))
	for _, k := range keys {
		lines = append(lines, k+": "+detailValue(obj[k]))
	}
	return lines
}

// detailLinesForCode renders the human (table/minimal) detail lines for ONE
// error code. The two publish-wall codes get an ACTIONABLE per-fact rendering —
// unknown_tag prints one line per unknown tag name with its trgm-nearest
// registered suggestions, and duplicate_of leads with the incumbent published
// id — because the generic compact-JSON lines bury exactly the token the author
// must copy into the retry (the per-name pairing, the one claimable id). Every
// other code, and a wall payload whose shape is not the contracted one, falls
// back to the generic sorted key:value lines (detailLines), so no payload is
// ever silently dropped. The machine channel (-o json/yaml) never routes
// through here — it carries `details` verbatim.
func detailLinesForCode(code string, raw json.RawMessage) []string {
	d := normalizeDetails(raw)
	if d == nil {
		return nil
	}
	switch code {
	case "unknown_tag":
		if lines := unknownTagLines(d); lines != nil {
			return lines
		}
	case "duplicate_of":
		if lines := duplicateOfLines(d); lines != nil {
			return lines
		}
	case "resource_conflict":
		if lines := resourceConflictLines(d); lines != nil {
			return lines
		}
	}
	return detailLines(raw)
}

// maxConflictHolders bounds how many holders a resource_conflict prints, for the
// same reason maxTagSuggestions exists: the fence scan is bounded by the caller's
// tenancy, not by a small number.
const maxConflictHolders = 10

// resourceConflictLines renders the 409 resource_conflict payload
// {conflicts:[{doc_id, worker, resources}]} as one line per HOLDER, pairing the
// row id, the worker and the exact overlapping paths. The generic sorted
// rendering would print the array as one compact-JSON blob under a `conflicts:`
// key, which buries the three tokens the caller must act on — and the whole
// point of this refusal is that the server already knows all three.
//
// It reads the holder id through apiclient.TaskConflict.HolderID, so the
// `doc_id`-vs-`task` wire spelling is resolved in ONE place; a payload whose
// shape is not the contracted one returns nil and falls back to detailLines,
// exactly like its two publish-wall siblings.
func resourceConflictLines(d json.RawMessage) []string {
	var payload struct {
		Conflicts []apiclient.TaskConflict `json:"conflicts"`
	}
	if err := json.Unmarshal(d, &payload); err != nil || len(payload.Conflicts) == 0 {
		return nil
	}
	lines := make([]string, 0, len(payload.Conflicts)+1)
	for i, c := range payload.Conflicts {
		if i == maxConflictHolders {
			lines = append(lines, fmt.Sprintf("… and %d more holder(s)", len(payload.Conflicts)-maxConflictHolders))
			break
		}
		who := c.HolderID()
		if who == "" {
			who = "(holder id absent from the refusal)"
		}
		if c.Worker != "" {
			who += " (worker " + c.Worker + ")"
		}
		if len(c.Resources) > 0 {
			who += ": " + strings.Join(c.Resources, ", ")
		} else {
			who += ": an overlapping resource the refusal did not name"
		}
		lines = append(lines, "held by "+who)
	}
	return lines
}

// maxTagSuggestions bounds the per-name suggestion list unknown_tag prints —
// the server sends the trgm-nearest few, but a hostile/buggy payload must not
// flood stderr.
const maxTagSuggestions = 5

// unknownTagLines renders the unknown_tag wall payload {unknown:[name],
// suggestions:{name=>[nearest]}} (api tag_registry.ex, validate_publish) as one
// line per unknown name carrying ITS OWN suggestions — the pairing the generic
// sorted rendering destroys by printing the two maps as unrelated blobs. Names
// keep the server's `unknown` order (the document's tag order). Returns nil
// when the shape is not the contracted one, so the caller falls back to the
// generic lines.
func unknownTagLines(d json.RawMessage) []string {
	var p struct {
		Unknown     []string            `json:"unknown"`
		Suggestions map[string][]string `json:"suggestions"`
	}
	if err := json.Unmarshal(d, &p); err != nil || len(p.Unknown) == 0 {
		return nil
	}
	lines := make([]string, 0, len(p.Unknown))
	for _, name := range p.Unknown {
		sugg := p.Suggestions[name]
		if len(sugg) > maxTagSuggestions {
			sugg = sugg[:maxTagSuggestions]
		}
		if len(sugg) == 0 {
			lines = append(lines, "unknown tag "+strconv.Quote(name)+" — no similar registered tag; publish a type:tag doc with this _id, or drop it")
		} else {
			lines = append(lines, "unknown tag "+strconv.Quote(name)+" — did you mean: "+strings.Join(sugg, ", "))
		}
	}
	return lines
}

// duplicateOfLines renders the duplicate_of wall payload {duplicate_of:<id>,
// similar:[…], advise:…} (api content/errors.ex) with the incumbent published
// id FIRST and verbatim — the one token the author needs to claim or extend the
// incumbent instead of republishing. The remaining keys keep their generic
// sorted rendering below it, so similar/advise (or any future key) survive
// whole. Returns nil when the incumbent id is absent or not a string, so the
// caller falls back to the generic lines.
func duplicateOfLines(d json.RawMessage) []string {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(d, &obj); err != nil {
		return nil
	}
	var id string
	if err := json.Unmarshal(obj["duplicate_of"], &id); err != nil || id == "" {
		return nil
	}
	lines := []string{"duplicate of: " + id + " — claim or extend the incumbent instead of republishing"}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		if k != "duplicate_of" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		lines = append(lines, k+": "+detailValue(obj[k]))
	}
	return lines
}

// detailValue renders ONE details value for the human line: a JSON string loses
// its quotes, every other shape (number, bool, null, object, array) prints as
// compact JSON.
func detailValue(raw json.RawMessage) string {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return strings.TrimSpace(string(raw))
	}
	return buf.String()
}

// usageErrf reports a usage-level (exit 2) failure from a BUILT-IN command's
// dispatch or flag validation. On a machine output (json/yaml) it emits the
// canonical {ok:false,error:{code:"usage",message}} envelope on stdout — so
// `bp <typo> -o json | jq` gets a parseable body instead of empty stdout —
// otherwise it prints the human "bp: <msg>" stderr line followed by the
// optional usageHelp (suppressed in machine mode). It is the built-in-dispatch
// counterpart to run.go's manifest-path usage guard, giving both paths the same
// machine-output parity. Always returns exitUsage.
func usageErrf(out *writer, usageHelp func(), format string, args ...any) int {
	return usageErrHintf(out, usageHelp, "", format, args...)
}

// usageErrHintf is usageErrf with an explicit envelope `hint` — the machine-mode
// carrier for the did-you-mean suggestion. The dispatch sites that report an
// unknown noun/verb already compute the nearest known token for the HUMAN usage
// help block (usageSuggestNouns / usageSuggestVerb print it to stderr), but
// usageErrf hardcodes hint="" so that suggestion never reached the `-o json`
// error envelope — the exact surface agents (always piped) read. This threads
// the same suggestion into error.hint. usageErrf delegates here with hint="" so
// its ~60 no-op call sites stay byte-identical; only the four suggestion sites
// pass a real hint (via nounHint/verbHint). Table/minimal output is unaffected —
// renderErrorEnvelope emits nothing on stdout there, and the hint never appears
// on the human stderr line (the usageHelp block already shows it). Always
// returns exitUsage.
func usageErrHintf(out *writer, usageHelp func(), hint, format string, args ...any) int {
	msg := fmt.Sprintf(format, args...)
	if !renderErrorEnvelope(out, "usage", msg, "", hint) {
		out.userErr("%s", msg)
		if usageHelp != nil {
			usageHelp()
		}
	}
	return exitUsage
}

// fetchSnapshotErr reports a failed taskboard.FetchSnapshotFull as the shared
// board-fetch failure path for the client-side read verbs that intercept
// entirely before manifest dispatch (`bp task frontier`, `bp task lint`,
// `bp task next --frontier`, `bp cmux dispatch`). FetchSnapshotFull returns a
// plain wrapped Go error (a transport failure or a bare non-200 status,
// wrapped via fmt.Errorf in taskboard/fetch.go) rather than a decoded API
// envelope, so there is no server `code` for classifyError to key on; this
// mints the one fresh "fetch_failed" code for it instead of inventing a
// per-verb variant. On a machine output (json/yaml) it emits the canonical
// {ok:false,error:{code,message}} envelope on stdout via renderErrorEnvelope —
// closing exactly the gap renderErrorEnvelope's own doc comment describes:
// these four verbs used to `out.userErr(...)` unconditionally, leaving
// `bp task frontier -o json | jq` with empty stdout on a failed fetch even
// though the same verb emits proper json/yaml on success. Otherwise it prints
// the unchanged human "bp: <verb>: <err>" stderr line. Always returns
// exitGeneric — a board-fetch failure is operational, never a usage error.
func fetchSnapshotErr(out *writer, verb string, err error) int {
	msg := fmt.Sprintf("%s: %v", verb, err)
	if !renderErrorEnvelope(out, "fetch_failed", msg, "", "") {
		out.userErr("%s", msg)
	}
	return exitGeneric
}

// topLevelConflicts lifts a non-empty top-level `conflicts` array out of an
// {"ok":false,"reason":…} body and returns it as the `details` payload
// {"conflicts":[…]}, so it reaches BOTH channels the envelope already has: the
// machine one carries it verbatim (renderErrorEnvelopeDetailed) and the human
// one renders it through detailLinesForCode. Returns nil when the key is absent
// or empty, so every other reason's envelope stays byte-identical.
//
// Shape-keyed, never reason-keyed: any tasks refusal that names its holders the
// same way inherits the rendering without a new case here.
func topLevelConflicts(body []byte) json.RawMessage {
	var env struct {
		Conflicts []json.RawMessage `json:"conflicts"`
	}
	if err := json.Unmarshal(body, &env); err != nil || len(env.Conflicts) == 0 {
		return nil
	}
	wrapped, err := json.Marshal(map[string]any{"conflicts": env.Conflicts})
	if err != nil {
		return nil
	}
	return json.RawMessage(wrapped)
}

// topLevelDrift lifts the edited-under-you 409's two recovery values out of an
// {"ok":false,"reason":"doc_changed_since_claim",…} body and returns them as the
// `details` payload {"current_rev":…,"changed_fields":[…]} — the sibling of
// topLevelConflicts, for the sibling shape.
//
// pds-bl-close-409-hint-promises-absent-fields: the server has ALWAYS put both
// on the wire (tasks_controller.ex, the :doc_changed_since_claim arm), and the
// CLI hint has always told the operator "the 409 body names current_rev +
// changed_fields" — but this branch declared only Error/Reason/OK, so both
// values died in the client and `bp task close … -o json` printed
//
//	{"error":{"code":"doc_changed_since_claim","message":"…"},"ok":false}
//
// The promise was true of the wire and unreachable from the output, which is
// worse than not promising: the operator went looking for a field that the tool
// itself had deleted.
//
// Shape-keyed, never reason-keyed: current_rev must be a non-empty string, and
// changed_fields (when present) an array. A body carrying neither returns nil,
// so every other ok:false reason's envelope stays byte-identical.
func topLevelDrift(body []byte) json.RawMessage {
	var env struct {
		CurrentRev    string            `json:"current_rev"`
		ChangedFields []json.RawMessage `json:"changed_fields"`
	}
	if err := json.Unmarshal(body, &env); err != nil || env.CurrentRev == "" {
		return nil
	}
	payload := map[string]any{"current_rev": env.CurrentRev}
	if len(env.ChangedFields) > 0 {
		payload["changed_fields"] = env.ChangedFields
	}
	wrapped, err := json.Marshal(payload)
	if err != nil {
		return nil
	}
	return json.RawMessage(wrapped)
}

// driftRev reads `current_rev` back out of an apiError's details payload, or ""
// when the body did not carry one. It is what lets the doc_changed_since_claim
// hint SUBSTITUTE the rev into the recovery command instead of printing a
// `<current_rev>` placeholder the operator has to go fetch — and, when it is
// absent, what makes the hint say so honestly rather than promise it.
func (e apiError) driftRev() string {
	d := normalizeDetails(e.details)
	if d == nil {
		return ""
	}
	var obj struct {
		CurrentRev string `json:"current_rev"`
	}
	if err := json.Unmarshal(d, &obj); err != nil {
		return ""
	}
	return strings.TrimSpace(obj.CurrentRev)
}

// bodyMessage extracts a top-level "message" string from an error body, used to
// give the {"ok":false,"reason":…} shape a human one-liner (e.g. "task not
// found") instead of the bare reason token. Returns "" when absent.
func bodyMessage(body []byte) string {
	var m struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(body, &m); err == nil {
		return strings.TrimSpace(m.Message)
	}
	return ""
}

func vetoMessage(reason string) string {
	if reason == "" {
		return "halted: write refused by a lifecycle veto"
	}
	return "halted: " + reason
}

func looksLikeNotFound(msg string) bool {
	m := strings.ToLower(msg)
	return strings.Contains(m, "not found") || strings.Contains(m, "no such") || strings.Contains(m, "does not exist")
}

// hint returns a code-keyed suggestion of the LIKELY FIX for an apiError, or ""
// when no useful hint applies. It is purely ADDITIVE UX — the runner prints it
// on a second stderr line below errorMessage(). It does NOT touch the 8-code
// exit ladder (codeExit / exitForCode / classifyError / errorMessage are the
// contract spine and stay byte-stable); a wrong or missing hint never changes
// an exit code.
func (e apiError) hint() string {
	// The server's per-error `hint` (envelope field) is the most specific, so
	// prefer it. The local code-keyed map below is the fallback — for codes the
	// server didn't send a hint for, and for older servers that send none. This
	// is what lets NEW error codes (mfa_required, share_expired, …) surface a
	// useful hint without adding a case here for each.
	if e.serverHint != "" {
		return e.serverHint
	}
	if e.localHint != "" {
		return e.localHint
	}
	switch e.code {
	case "not_found", "schema_unknown":
		return "check the type/id and --dataset; run `bp schema ls` to list types"
	case "validation_failed", "invalid_op", "malformed_op", "type_mismatch", "duplicate_id", "block_not_found", "invalid_paper":
		return "re-run with -v for field errors; check required/pattern fields"
	case "rev_mismatch", "precondition_failed", "conflict":
		return "re-fetch the doc to get the current _rev, then retry"
	case "fenced_off":
		// SPLIT from the claim-race codes below, because the usual cause is
		// neither a sweep nor a blocker: `bp task pulse` INCREMENTS the epoch
		// (measured 1→2→3→4 across four pulses), so the obvious loop — claim,
		// pulse while you work, close on the epoch the CLAIM printed — fences
		// you with your own heartbeat. The old copy named only "lease swept or
		// a blocker/move", so a caller fenced by their own pulse went hunting a
		// cause that had not happened. Name the common one first, and give the
		// recovery that always works: re-read the epoch rather than reusing a
		// remembered one. See docs/contracts/roster-reading.md, Trap 7.
		return "your claim epoch is stale — most often your own `bp task pulse` bumped it (a re-claim, a swept lease, or a blocker/move on the task do too); re-read `claim.epoch` and retry with that, never the epoch the claim printed"
	case "stale_claim", "claimed_has_worker", "already_claimed":
		// The claim-race codes: the epoch moved because someone else acted on
		// the row, so the recovery is a re-claim under YOUR OWN worker id
		// (which mints a fresh epoch) rather than a generic `task next`.
		return "your claim epoch is stale (lease swept, or another worker claimed it) — re-claim under your worker id, then retry"
	case "not_ready":
		// not_ready is NOT a stale-epoch case: the targeted claim hit a task held by
		// ANOTHER worker, or one that is done/cancelled/blocked-by-deps. The fix is
		// not "re-claim to advance the epoch" — it is either wait for the holder, or
		// (if the holder is YOU) re-claim under your own id to renew the lease.
		return "the task isn't claimable — someone else holds it or it isn't ready; if YOU hold it, re-claim with your own worker id to renew the lease"
	case "doc_changed_since_claim":
		// TWO wordings, chosen by what the body ACTUALLY carried. The old single
		// wording promised "the 409 body names current_rev + changed_fields" and
		// then printed a literal `<current_rev>` placeholder — a promise the
		// operator could not spend, because this branch of classifyError had
		// dropped the value. With the rev in hand the command is COMPLETE (copy
		// it, run it); without it the hint says plainly that the rev must be
		// read, and never claims the refusal already named it.
		if rev := e.driftRev(); rev != "" {
			return "the task's brief changed since you claimed it — reconcile the changed fields above, then close with `--set observed_rev=" + rev + "` (strict full-rev CAS, bypasses the digest fence; the rev is from this refusal, no re-read needed to run it). A plain re-read then close repeats the 409 — a same-worker re-read preserves the claim-time work digest"
		}
		return "the task's brief changed since you claimed it — re-read with `bp task get <id> -o json` to learn the current rev, reconcile, then close with `--set observed_rev=<that rev>` (strict full-rev CAS, bypasses the digest fence). A plain re-read then close repeats the 409 — a same-worker re-read preserves the claim-time work digest"
	case "resource_conflict":
		// NOT a stale-lease case, and that distinction is the whole hint: a
		// re-claim under your own worker id mints a fresh epoch and changes
		// NOTHING here, because the fence is held by a DIFFERENT row's live
		// claim. The holder lines above name the row, the worker and the paths.
		return "another live claim fences one of your --resources paths (the holders are named above) — wait for it to close, narrow your --resources to paths nobody holds, or ask that worker to hand off. Re-claiming under your own worker id does NOT clear it"
	case "rate_limited":
		return "retry with backoff"
	case "unauthorized":
		// Telling someone to go get a token is only useful when they did not
		// send one. When they DID, minting another changes nothing: the
		// credential reached the server and the server refused it, so the cause
		// is elsewhere — a route gated on a login session rather than a bearer
		// (`bp auth me`), a token minted for a different server, or an expired
		// one. Naming the remedy they already applied is what made the original
		// refusal unactionable.
		if e.credentialSent {
			return "the request DID carry a credential and the server still refused it, so minting another will not help — this refusal's own message names the gate; check `bp whoami` for the identity this token actually has, and note that some routes require an interactive login session rather than an API token"
		}
		return "set BARKPARK_API_TOKEN or run `bp setup --target connect`"
	case "forbidden", "cors_forbidden", "csrf_required":
		return "token needs write/admin — check `bp whoami`"
	case "no_team":
		return "your Cloud login has no active team — run `bp team use <team>`"
	default:
		return ""
	}
}

// enumeratingVerbs are the verb names a noun uses for "show me what exists",
// most specific first. `ls` is the house style; `browse` is the tag reads and
// `inbox` the tickets operator queue, both of which are the only enumeration
// their noun has. `mine` is deliberately absent — `access mine` lists only the
// caller's own grants, so naming it as the way to find an id you were refused
// would point at a strictly smaller set than the one you are looking in.
var enumeratingVerbs = []string{"ls", "list", "browse", "inbox"}

// notFoundHint derives the remedy for a not_found refusal from the command that
// was actually dispatched, or returns "" when it cannot name one honestly.
//
// The code-keyed hint table cannot see the command, so its single not_found
// entry describes the document shape for every noun: "check the type/id and
// --dataset; run `bp schema ls` to list types". That text only reaches the user
// when the SERVER sent no hint of its own, which is the case for the twelve
// controllers carrying a private not_found/2 that emits {code, message} and
// nothing else. Measured live against guerrilla.barkpark.cloud, six of twelve
// probed refusals landed there: token revoke, workspace member-rm, access show,
// ticket show, ticket-key rotate and task get. The rest — doc, media, secret,
// schema, webhook — carry a server hint, which still outranks this.
//
// On `bp token revoke <id>`, the verb you reach for when a credential has
// leaked, both halves of the fallback are false: that route is
// /w/:ws/p/:proj/v1/tokens/:id and carries no :dataset, and `bp schema ls`
// lists content schemas, which can never tell you a token id. The remedy was
// `bp token ls`, one command away, and the refusal did not mention it.
//
// The verb is looked up in the SAME manifest that produced the failing command,
// never guessed. That is the point: a hint naming a command that does not exist
// costs the reader an extra failed run and teaches them to stop trusting hints,
// so when the manifest cannot confirm a sibling this returns "" and the
// code-keyed table answers exactly as before.
func notFoundHint(m *manifest.Manifest, cmd manifest.Command) string {
	if m == nil || cmd.Noun == "" {
		return ""
	}
	verb := enumeratingSibling(m, cmd)
	if verb == "" {
		return ""
	}
	// The dataset clause is earned, not assumed: it is added only when the route
	// actually carries a :dataset placeholder. Telling someone to check
	// --dataset on a workspace-scoped route is the same species of wrong answer
	// this function exists to remove.
	if cmd.PathPlaceholders()["dataset"] {
		return fmt.Sprintf("run `bp %s %s` to see what exists, and check --dataset — this route is dataset-scoped", cmd.Noun, verb)
	}
	return fmt.Sprintf("run `bp %s %s` to see what exists (this route is not dataset-scoped, so --dataset cannot affect it)", cmd.Noun, verb)
}

// enumeratingSibling picks the verb under cmd's noun that lists the things cmd
// was looking for, or "" when the manifest declares none.
//
// The noun alone is too coarse. `workspace` carries ls, member-ls, project-ls
// and dataset-ls, so a `workspace member-rm` refusal answered with `bp
// workspace ls` names a command that lists WORKSPACES — it cannot show the seat
// whose id was rejected, and pointing at it would reproduce the exact defect
// this hint exists to remove. So a hyphenated verb is matched inside its family
// first: `member-rm` looks for `member-ls`, `scoped-get` for `scoped-ls`,
// `collection-assets` for `collections`. Only a verb with no family, or one
// whose family has no list, falls back to the noun-wide enumeration.
func enumeratingSibling(m *manifest.Manifest, cmd manifest.Command) string {
	var candidates []string
	if family, _, hyphenated := strings.Cut(cmd.Verb, "-"); hyphenated && family != "" {
		candidates = append(candidates, family+"-ls", family+"-list", family+"s")
	}
	candidates = append(candidates, enumeratingVerbs...)

	for _, want := range candidates {
		if want == cmd.Verb {
			// cmd IS the list verb; a refusal from it is not an id lookup, and
			// telling the reader to re-run what just failed is noise.
			return ""
		}
		for _, c := range m.Commands {
			if c.Noun == cmd.Noun && c.Verb == want {
				return want
			}
		}
	}
	return ""
}

// errorMessage renders the user-facing one-liner for an apiError, following the
// "CLI message guidance" column of the table where a code is known.
func (e apiError) errorMessage() string {
	switch e.code {
	case "not_found", "schema_unknown":
		if e.message != "" {
			return "not found: " + e.message
		}
		return "not found"
	case "unauthorized":
		// The SERVER's message outranks the local constant, exactly as it does
		// for not_found and forbidden two cases over. The constant used to win
		// unconditionally, so a 401 whose body said "a valid login session is
		// required" (GET /v1/auth/me sits behind require_user, not behind the
		// bearer) rendered as "set BARKPARK_API_TOKEN" — the ONE fact that
		// explains the refusal, dropped, and replaced by advice that cannot fix
		// it. The generic line survives only where the server said nothing.
		if e.message != "" {
			return "unauthorized: " + e.message
		}
		if e.credentialSent {
			return "unauthorized: the credential sent with this request was rejected"
		}
		return "authentication required — set BARKPARK_API_TOKEN or run: bp setup --target connect --server <url> --token <token>"
	case "forbidden", "cors_forbidden", "csrf_required":
		if e.message != "" {
			return "forbidden: " + e.message
		}
		return "forbidden: token lacks permission for this command"
	case "rate_limited":
		return "rate limited; retry later"
	case "internal_error":
		if e.requestID != "" {
			return "server error (" + e.requestID + ")"
		}
		return "server error"
	default:
		if e.message != "" {
			return e.message
		}
		return "request failed"
	}
}
