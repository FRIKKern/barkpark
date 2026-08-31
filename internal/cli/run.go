package cli

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/httpx"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/mattn/go-isatty"
)

// cliVersion is the binary's CLI version, surfaced by `barkpark version` and
// used for the manifest's min_cli gate when present. Injected at release time
// via -ldflags -X (see Makefile LDFLAGS); "dev" for plain `go build` builds,
// which makes untagged binaries self-evident in bug reports.
var cliVersion = "dev"

// cliCommit and cliDate are release-build provenance, injected alongside
// cliVersion. Empty on dev builds; surfaced only in `bp version -o json` so the
// human output shape stays `barkpark <version>`.
var (
	cliCommit = ""
	cliDate   = ""
)

// manifestRequest is the fully resolved HTTP request for one manifest command:
// method + absolute URL + headers + the body (or a streaming reader for a
// multipart media upload). It is what buildManifestRequest produces and
// sendManifestRequest consumes — the seam between "resolve the request" and
// "send it" that lets both the CLI render path and the headless MCP dispatch
// path share one build+send pipeline without either writing to stdout.
type manifestRequest struct {
	method  string
	url     string
	headers map[string]string
	body    []byte
	stream  io.Reader // non-nil only for a streamed multipart media upload
}

// dispatchError is a build-stage failure (bad args / URL / body) surfaced by
// buildManifestRequest. withUsage records whether the CLI human path should also
// print the per-command usage block (splitArgs/bindArgs do; BuildURL/buildBody
// don't), so runCommand reproduces the exact rendering of the old inline path.
// It satisfies error so execManifestCommand can return it verbatim to headless
// callers, which surface only the message.
type dispatchError struct {
	msg       string
	withUsage bool
}

func (e *dispatchError) Error() string { return e.msg }

// buildManifestRequest resolves tail into a ready-to-send manifestRequest:
// splitArgs → bindArgs → BuildURL → applyQuery → buildBody → authHeaders. It
// writes NOTHING to stdout; every failure comes back as a *dispatchError so the
// caller owns rendering. This is the build half of the dispatch seam — a pure
// resolution step with one caveat: buildBody may consume os.Stdin for --file -,
// so it must run exactly once per invocation.
func buildManifestRequest(g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, ownsProcessStdin bool) (*manifestRequest, *dispatchError) {
	// Split tail into positional args and command-local flags.
	posArgs, cmdFlags, err := splitArgs(cmd, tail)
	if err != nil {
		return nil, &dispatchError{msg: err.Error(), withUsage: true}
	}

	// Bind positional args to the command's declared arg names.
	argMap, err := bindArgs(cmd, posArgs)
	if err != nil {
		return nil, &dispatchError{msg: err.Error(), withUsage: true}
	}

	needsPerspectiveAuth := nonPublishedPerspectiveRequiresAuth(cmd, cmdFlags)
	if needsPerspectiveAuth && ctx.Token == "" {
		perspective := cmdFlags["perspective"][len(cmdFlags["perspective"])-1]
		return nil, &dispatchError{
			msg:       fmt.Sprintf("--perspective %s requires an API token", perspective),
			withUsage: false,
		}
	}

	// Build the absolute URL (fills :placeholders + prepends scoped_prefix).
	rawURL, err := m.BuildURL(cmd, ctx, argMap)
	if err != nil {
		return nil, &dispatchError{msg: err.Error(), withUsage: false}
	}

	// Apply query-string params: pagination, manifest-declared query flags, and
	// any declared arg whose location is query (a non-path arg on a read).
	rawURL = applyQuery(rawURL, g, cmd, cmdFlags, argMap)

	// Build the request body for writes. Declared non-path args seed the JSON
	// object; --set merges over them; mutation commands merge a --file JSON
	// object before --set, while other commands use --file as the whole body; a
	// a POST-bound, declared file-typed arg is sent as multipart/form-data
	// instead (whatever the route is spelled).
	body, stream, contentType, err := buildBodyWithStdinOwnership(cmd, cmdFlags, argMap, ownsProcessStdin)
	if err != nil {
		return nil, &dispatchError{msg: err.Error(), withUsage: false}
	}

	// Tier-appropriate credential.
	headers := authHeaders(cmd, ctx)
	if needsPerspectiveAuth {
		// doc get/ls/query are public at their default published perspective,
		// so their manifest tier must remain `none`. Drafts and raw are
		// identity-sensitive, however: OptionalToken intentionally pins an
		// anonymous request back to published. Attach the already-resolved bearer
		// only for those explicit perspectives so the flag cannot be silently
		// downgraded while the public published request stays byte-for-byte public.
		headers["Authorization"] = "Bearer " + ctx.Token
	}
	if contentType != "" {
		headers["Content-Type"] = contentType
	}

	return &manifestRequest{
		method:  cmd.HTTP.Method,
		url:     rawURL,
		headers: headers,
		body:    body,
		stream:  stream,
	}, nil
}

func nonPublishedPerspectiveRequiresAuth(cmd manifest.Command, flags map[string][]string) bool {
	if cmd.AuthTier != "none" {
		return false
	}
	switch cmd.ID {
	case "doc.get", "doc.ls", "doc.query":
	default:
		return false
	}

	values := flags["perspective"]
	if len(values) == 0 {
		return false
	}
	switch values[len(values)-1] {
	case "drafts", "raw":
		return true
	default:
		return false
	}
}

// sendManifestRequest is the send half of the dispatch seam: it performs the
// HTTP call for an already-built manifestRequest and returns the raw status +
// body, never rendering. A multipart upload rides the streaming transfer client
// (no wall-clock Timeout — a large/slow media body must not be killed at 30s);
// every other request keeps the 30s doRequest client, byte-identical.
func sendManifestRequest(req *manifestRequest) (int, []byte, string, error) {
	if req.stream != nil {
		return doRequestStreamCT(req.method, req.url, req.headers, req.stream, -1)
	}
	return doRequestCT(req.method, req.url, req.headers, req.body)
}

// execManifestCommand is the headless dispatch primitive: it resolves tail into
// a request and sends it, returning the raw HTTP status + response body with no
// dry-run, no prod write-guard, no --all pagination loop, and no rendering. It
// writes NOTHING to stdout. The CLI render path (runCommand) layers the guards
// and the renderer on top; the MCP tool handlers call this directly and turn the
// raw body into a tool result. Headless callers must set g.yes so the prod guard
// (which lives in runCommand, not here) never blocks them.
func execManifestCommand(g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) (int, []byte, error) {
	req, derr := buildManifestRequest(g, ctx, m, cmd, tail, false)
	if derr != nil {
		return 0, nil, derr
	}
	status, respBody, _, err := sendManifestRequest(req)
	return status, respBody, err
}

// runCommand executes one manifest command for the CLI: it resolves the request
// via buildManifestRequest, applies the CLI-only guards (--dry-run, the prod
// write-guard, and the --all pagination loop), sends via sendManifestRequest,
// then renders the result or maps the error envelope to an exit code. The
// build+send machinery is the dispatch seam (buildManifestRequest /
// sendManifestRequest / execManifestCommand) so the MCP server can drive the
// same pipeline headlessly. buildManifestRequest runs exactly once here — the
// guards that need the resolved request (--dry-run, --all) read it in place, so
// os.Stdin (--file -) is never consumed twice.
func runCommand(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	out.resolveOutputForCommand(g, cmd.DefaultOutput)

	// webhook test-send verdict-aware exit (task-60887badc1d2900f decision
	// (a)): the ONE additive, opt-in flag this command understands that the
	// manifest never declares, so it must be stripped out of tail before
	// buildManifestRequest ever reaches splitArgs — which would otherwise
	// refuse it as an unknown command-local flag. Scoped to cmd.ID, not parsed
	// for any other command, so `bp webhook create --fail-on-failed-delivery`
	// still refuses exactly as before.
	var failOnFailedDelivery bool
	if cmd.ID == "webhook.test-send" {
		failOnFailedDelivery, tail = extractFailOnFailedDeliveryFlag(tail)
	}

	// Resolve the request-side view HERE, with the writer in hand — never
	// inside buildManifestRequest, which is pure/writer-less and shared by the
	// headless MCP dispatch (the MCP handlers set g.view themselves).
	g.view = resolveView(out, g, cmd)

	// REFUSE when a pagination knob cannot leave the client for this command.
	// applyQuery is writer-less (it is shared with the headless MCP dispatch),
	// so the check belongs here — the same seam resolveView uses above — and
	// it runs BEFORE buildManifestRequest, so a refused invocation sends
	// nothing and reads nothing.
	if code, refused := refuseDroppedKnobs(out, g, cmd); refused {
		return code
	}

	req, derr := buildManifestRequest(g, ctx, m, cmd, tail, true)
	if derr != nil {
		if !renderErrorEnvelope(out, "usage", derr.msg, "", "") {
			out.userErr("%v", derr)
			if derr.withUsage {
				usageCommand(out, cmd)
			}
		}
		return exitUsage
	}

	// --dry-run: print the resolved request and exit 0 WITHOUT sending (A1).
	if g.dryRun {
		return dryRun(out, cmd, req.url, req.headers, req.body)
	}

	// Prod write-guard: a write against a prod-looking target needs confirmation
	// unless --yes, or unless the server itself advertises production:false on
	// /v1/meta (absence of the field falls back fail-closed). (scoped_admin still
	// attempts — the guard is local UX, not the client preflight-refuse that
	// rule #2 forbids.)
	if cmd.Writes && isProd(ctx, m) && !g.yes && !serverDeclaredNonProd(ctx.Server) {
		if !confirmProdWrite(out, cmd, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}

	// Destroy-tier guard (destroy_confirm.go): a credential/seat destroy names
	// its victim and needs --yes, on EVERY server. The prod guard above cannot
	// cover this — it is keyed on the target being prod, so `bp token revoke`
	// against a local or production:false instance skipped confirmation
	// entirely, and when it did fire it named only the verb and the server.
	// Runs after it (a prod destroy answers both) and before the send.
	if destroyArgs, gated := destroyRefArgs(cmd, tail); gated {
		if !confirmDestroy(out, g, ctx, m, cmd, destroyArgs) {
			out.errf("aborted: destroy not confirmed")
			return exitUsage
		}
	}

	// Paginated reads with --all loop over offset pages.
	if cmd.Paginated && g.all && !cmd.Writes {
		return runPaginatedAll(out, cmd, req.url, req.headers)
	}

	status, respBody, respCT, err := sendManifestRequest(req)
	if err != nil {
		if !renderErrorEnvelope(out, "request_failed", "request failed: "+err.Error(), "", "") {
			out.userErr("request failed: %v", err)
		}
		return exitGeneric
	}
	if status >= 200 && status < 300 {
		if code, refused := refuseUnreadableDefaultPage(out, cmd, status, respBody); refused {
			return code
		}
		if code, handled := screenWriteReceipt(out, cmd, status, respBody); handled {
			return code
		}
		if code, handled := screenUnpaginatedRead(out, cmd, status, respBody, respCT); handled {
			return code
		}
		warnIfDefaultPageMayBeTruncated(out, g, cmd, respBody)
		emitMovementDoctrine(out, cmd)
		emitHelpHints(out, respBody)
	}
	code := handleResponse(out, m, cmd, status, respBody)

	// The flag only ever overrides the HONEST success path (code == exitOK,
	// meaning handleResponse's 2xx branch rendered it, not a screen's own
	// refusal above with its own exit code). Rendering is byte-identical
	// either way — renderSuccess already ran inside handleResponse — only the
	// process exit code changes, and only when the caller opted in.
	if code == exitOK && failOnFailedDelivery && webhookDeliveryVerdictFailed(respBody) {
		return exitGeneric
	}
	return code
}

// resolveView decides the ?view= projection for a CLI invocation (AXI R1,
// charter decision 5 — option B): brief only when ALL of (a) the resolved
// output is machine-readable (json/yaml — folds the piped default and an
// explicit -o json; an explicit -o table while piped stays FULL), (b) the user
// did not force --full, and (c) the command's manifest declares a views
// contract with an agent default. Commands without a views declaration never
// get a view param — they are full-only by contract (task.get IS the escape
// hatch). Empty string means "send no view param" (server default, full).
func resolveView(out *writer, g globals, cmd manifest.Command) string {
	if g.full || !out.machineOut() {
		return ""
	}
	if cmd.Views == nil {
		return ""
	}
	return cmd.Views.DefaultForAgents
}

// agentViewGlobals returns g with the command's manifest-declared agent-default
// view applied — the ONE generic seam by which headless agent surfaces (the MCP
// bridge) inherit brief views from the capabilities contract with zero
// per-tool code. A command without a views declaration passes through
// untouched (no view param, full-only by contract).
func agentViewGlobals(g globals, cmd manifest.Command) globals {
	if !g.full && cmd.Views != nil && cmd.Views.DefaultForAgents != "" {
		g.view = cmd.Views.DefaultForAgents
	}
	return g
}

// emitHelpHints prints a success envelope's top-level {"help":[…]} entries —
// concrete next-step command templates the server authors beside its mutation
// emitters (AXI R5) — to STDERR, one "help: …" line each. It is called from
// runCommand's post-2xx hook (the warnIfDefaultPageMayBeTruncated call-site
// pattern), which fires in ALL four output modes; it must NEVER live inside
// renderSuccess, whose json/yaml arms print the raw payload and are
// structurally silent on advisory fields (see
// TestRenderSuccessJSONSilentOnAdvisories). stdout stays one parseable
// document; json/yaml consumers read the help field itself.
func emitHelpHints(out *writer, respBody []byte) {
	for _, h := range helpEntries(respBody) {
		out.errf("help: %s", h)
	}
}

// helpEntries extracts the non-empty string entries of a top-level "help"
// array from a response envelope, looking first at the raw body (the tasks
// endpoints emit flat envelopes) and then inside a {"result": …} wrapper.
// Absent, empty, or malformed help never prints and never errors.
func helpEntries(body []byte) []string {
	if hs := topLevelHelpStrings(body); len(hs) > 0 {
		return hs
	}
	return topLevelHelpStrings(unwrapResult(body))
}

func topLevelHelpStrings(body []byte) []string {
	var env struct {
		Help []any `json:"help"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Help) == 0 {
		return nil
	}
	hs := make([]string, 0, len(env.Help))
	for _, h := range env.Help {
		if s, ok := h.(string); ok && s != "" {
			hs = append(hs, s)
		}
	}
	return hs
}

// refuseWithRemedy emits ONE refusal on whichever channel the caller's output
// shape uses, and — this is the whole point — carries the remedy on BOTH.
//
// renderErrorEnvelope only carries `hint` for -o json/yaml; it returns false for
// `table` and `minimal`, and every caller then printed `msg` alone. So the
// reader law's own refusals — the --all walk (wave 27), the paginated default
// page (wave 28) and the 93 write verbs (wave 29) — each computed a precise,
// hand-written remedy and then dropped it for exactly the audience that reads
// human output. A person at a terminal saw "unreadable list page: HTTP 200 …"
// and no word about what to do; only a piped `-o json` consumer ever got
// "Retry, then check the server URL and that the API is up."
//
// The human shape is byte-for-byte the one renderError already uses for a
// classified API error (`out.userErr(msg)` then `  hint: …`) and the one
// seed_cmd.go:95 hand-rolled, so this unifies three spellings into one and
// leaves the machine envelope untouched.
func refuseWithRemedy(out *writer, code, msg, hint string) {
	if renderErrorEnvelope(out, code, msg, "", hint) {
		return
	}
	out.userErr("%s", msg)
	if hint != "" {
		out.errf("  hint: %s", hint)
	}
}

// unreadableListPageHint is the one wording both list-page refusals share —
// the --all walk (runPaginatedAll) and the DEFAULT single page
// (refuseUnreadableDefaultPage). It names the transport, not the query,
// because that is what an unreadable 200 always means.
const unreadableListPageHint = "the transport, not the query: a proxy/gateway page, a truncated or non-Barkpark response. Retry, then check the server URL and that the API is up."

// refuseUnreadableDefaultPage is the DEFAULT-read half of the PDS reader law
// (wave 28): no bp verb may report success on an exit code alone. Wave 27
// taught the --all walk to refuse an HTTP-200 body it cannot read as a list
// envelope, but that refusal sits behind `cmd.Paginated && g.all && !cmd.Writes`
// and --all is the RARE invocation. The DEFAULT single-page read — what every
// `bp task ready` / `bp doc ls` actually runs — laundered all nine of wave 27's
// poisons into rc=0: `-o minimal` printed the literal word "ok" over `null`, an
// unknown envelope and `{}`; `-o json` printed an ERROR ENVELOPE as a
// successful body; `-o table` printed nothing at all for `{}`. Twenty-four of
// twenty-seven poison×shape runs said nothing on any channel.
//
// The sentinel was already computed one line below and thrown away:
// warnIfDefaultPageMayBeTruncated does `rows, _ := extractListRows(…)` and then
// goes quiet on exactly these bodies, because an unreadable body yields 0 rows
// and 0 < limit.
//
// PLACEMENT IS LOAD-BEARING (PDS-D396). It lives HERE, at runCommand's post-2xx
// hook — the one site proven to fire in all four output shapes — and NOT:
//
//   - in renderMinimal, where extractListRows returns the "" sentinel for five
//     of seven REAL write receipts (the mutate transaction receipt, the
//     {ok,doc} claim receipt, {ok:false,reason}, the workspace-create slug
//     receipt, the publish {rev,id} receipt), so a fence there would red every
//     write verb in the CLI — measured, not feared
//     (TestExtractListRowsBlindToWriteReceipts);
//   - behind the neighbour's `g.limitSet` skip, which would let
//     `bp task ready --limit 5` against a proxy 502 stay silent — the same lie
//     one flag away;
//   - behind `g.all`, which already returned at the runPaginatedAll branch.
//
// Honest reads are untouched: every one of the seven `paginated: true` commands
// emits a key listEnvelopeKeys knows (TestPaginatedCommandsUseKnownEnvelopeKeys
// re-derives that population from the API source), and an EMPTY array still
// matches its key — a genuinely empty queue is readable, and stays rc=0.
func refuseUnreadableDefaultPage(out *writer, cmd manifest.Command, status int, respBody []byte) (int, bool) {
	if !cmd.Paginated || cmd.Writes {
		return 0, false
	}
	if _, key := extractListRows(unwrapResult(respBody)); key != "" {
		return 0, false
	}

	msg := fmt.Sprintf(
		"unreadable list page: HTTP %d carried no known list envelope (%d bytes): %s",
		status, len(respBody), bodyPreview(respBody),
	)
	refuseWithRemedy(out, "unreadable_list_page", msg, unreadableListPageHint)
	return exitGeneric, true
}

// unreadableWriteReceiptHint is the one wording the write-receipt refusal
// carries. It names the transport like its read-side sibling, but it must ALSO
// say the thing a read never has to: an unconfirmable write is not a failed
// write. The mutation may well have landed; the receipt is what did not arrive.
const unreadableWriteReceiptHint = "the transport, not the write: a proxy/gateway page, a truncated or non-Barkpark response. The write may still have landed — re-read the target before retrying, then check the server URL and that the API is up."

// screenWriteReceipt is the WRITE half of the PDS reader law (wave 29): no bp
// verb may report success on an exit code alone. Waves 27 and 28 fenced the
// --all walk and the DEFAULT single-page read, but BOTH are gated on
// `cmd.Paginated && !cmd.Writes` — so every one of the 93 write verbs sat
// outside them BY CONSTRUCTION. Measured on origin/main against a fake API:
// `bp task next w1` printed `ok` at rc=0 over `null`, `{}`, `{"result":null}`
// and `[]`; `-o table` over `{}` printed ZERO BYTES on both channels at rc=0;
// an HTML 502 proxy page was echoed verbatim; and an ERROR envelope arriving on
// a 2xx was printed as the SUCCESS body under `-o json`.
//
// PLACEMENT IS LOAD-BEARING (PDS-D407), and it is NOT where it looks. It lives
// HERE, at runCommand's post-2xx hook — the one site proven to fire in all four
// output shapes — and NOT inside renderMinimal, whose "ok" fallback was
// instrumented on a clean build and found to be reached by three HONEST write
// receipts as well as five poisons, ONLY in -o minimal: zero bytes, an HTML
// page, an error envelope and plaintext never arrive there at all, and 26 of
// the 93 write verbs never render through renderMinimal in the first place.
//
// THE DISCRIMINATOR IS "did the server say anything at all", NEVER "does the
// body carry a key we recognise". An object under keys the CLI cannot summarise
// PASSES by design (see TestWriteReceiptPassesUnknownKeys): on a write that is
// a receipt the CLI cannot summarise, not a lie — and an allowlist there would
// red `{"ok":true}` and `{"deleted":true,…}` TODAY.
//
// It returns (exit code, handled) and has TWO honest outcomes, not one:
//
//   - a refusal at exitGeneric for a body that said nothing;
//   - a DECLARED empty receipt at exitOK for HTTP 204/205 with an empty body —
//     `chat.approve` really does answer `send_resp(conn, :no_content, "")`, so a
//     naive "empty body ⇒ refuse" would red an honest verb. That arm is not
//     silence: main printed a BARE EMPTY LINE there, and it now names what
//     happened. An UNDECLARED empty 200 still refuses.
func screenWriteReceipt(out *writer, cmd manifest.Command, status int, respBody []byte) (int, bool) {
	if !cmd.Writes {
		return 0, false
	}

	if (status == http.StatusNoContent || status == http.StatusResetContent) &&
		len(bytes.TrimSpace(respBody)) == 0 {
		reason := fmt.Sprintf("HTTP %d, no content returned — the server declared no receipt for this write", status)
		if !out.emitStructured(map[string]any{"ok": true, "confirmed": false, "reason": reason}) {
			out.outf("not confirmed: %s", reason)
		}
		return exitOK, true
	}

	reason := unreadableWriteReceipt(respBody)
	if reason == "" {
		return 0, false
	}

	msg := fmt.Sprintf(
		"unreadable write receipt: HTTP %d %s (%d bytes): %s",
		status, reason, len(respBody), bodyPreview(respBody),
	)
	refuseWithRemedy(out, "unreadable_write_receipt", msg, unreadableWriteReceiptHint)
	return exitGeneric, true
}

// failOnFailedDeliveryFlag is the literal token for `bp webhook test-send
// --fail-on-failed-delivery` — task-60887badc1d2900f's decision (a): exit 0
// stands by default (webhook_controller.test_send/2 reports the delivery
// VERDICT in a 2xx body by design — "Returns the delivery verdict so the SPA
// can show an immediate ok/failed result"), and this is the additive,
// opt-in escape hatch for the one caller that cannot act on a printed line: a
// script. It is NOT declared on webhook.test-send's manifest entry
// (api/lib/barkpark/plugins/capabilities.ex — read, not touched, by this
// task), so it must never reach splitArgs, which would refuse it as an
// unknown command-local flag.
const failOnFailedDeliveryFlag = "--fail-on-failed-delivery"

// extractFailOnFailedDeliveryFlag removes every bare occurrence of
// failOnFailedDeliveryFlag from tail and reports whether it was present. It
// is a bool flag taking no value — an inline `--fail-on-failed-delivery=x`
// form is deliberately left in tail untouched, so it falls through to
// splitArgs' ordinary "unknown flag" refusal instead of silently succeeding
// on a typo'd value.
func extractFailOnFailedDeliveryFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == failOnFailedDeliveryFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// webhookDeliveryVerdictFailed reports whether a webhook test-send response
// body's top-level "delivery" object carries a non-success status.
// webhooks/delivery.ex enumerates exactly three: pending | ok | failed_giveup
// — "ok" is the only success state, so anything else (today, always
// "failed_giveup": both test-send and replay drive ONE synchronous attempt
// with no retry loop, so the verdict this function ever sees is terminal,
// never "pending") counts as failed. Malformed/absent bodies report false
// (no verdict to act on) rather than false-positive a refusal.
func webhookDeliveryVerdictFailed(respBody []byte) bool {
	var env struct {
		Delivery struct {
			Status string `json:"status"`
		} `json:"delivery"`
	}
	if json.Unmarshal(unwrapResult(respBody), &env) != nil {
		return false
	}
	return env.Delivery.Status != "" && env.Delivery.Status != "ok"
}

// unreadableWriteReceipt names WHY a 2xx write body said nothing, or "" when
// the body is a receipt worth rendering. The refusals are exactly the bodies
// that carry no statement about the write: non-JSON bytes (a proxy page, an
// interstitial, plaintext), an empty body with no 204/205 declaration, the JSON
// literal `null`, a `{"result":null}` envelope, an empty object, an empty
// array, and an error envelope that arrived on a 2xx. Everything else — every
// scalar, every non-empty array, every object regardless of its keys — passes.
func unreadableWriteReceipt(body []byte) string {
	if len(bytes.TrimSpace(body)) == 0 {
		return "returned an empty body without declaring one (no 204/205 no-content status)"
	}
	var raw any
	if json.Unmarshal(body, &raw) != nil {
		return "carried a body that is not JSON"
	}
	var payload any
	if json.Unmarshal(unwrapResult(body), &payload) != nil {
		return `carried a {"result": …} envelope whose payload is not JSON`
	}
	switch t := payload.(type) {
	case nil:
		if raw == nil {
			return "carried the JSON literal null"
		}
		return `carried {"result":null} — the envelope was empty`
	case map[string]any:
		if len(t) == 0 {
			return "carried an empty JSON object"
		}
		if code, isErr := errorEnvelopeOn2xx(t); isErr {
			return fmt.Sprintf("carried an ERROR envelope (%s) on a success status", code)
		}
	case []any:
		if len(t) == 0 {
			return "carried an empty JSON array"
		}
	}
	return ""
}

// errorEnvelopeOn2xx reports whether a 2xx payload is really the canonical
// failure envelope — `ok:false` AND an `error` member. That CONJUNCTION is the
// whole discriminator: `{"ok":false,"reason":"no_ready"}` is an HONEST 200 from
// the task queue (an empty queue is an outcome, not an error) and must stay
// rc=0, while `{"ok":false,"error":{…}}` on a 200 is a server contradicting
// itself. The returned code names the error for the refusal message.
func errorEnvelopeOn2xx(m map[string]any) (string, bool) {
	if ok, present := m["ok"].(bool); !present || ok {
		return "", false
	}
	switch e := m["error"].(type) {
	case map[string]any:
		if code, _ := e["code"].(string); code != "" {
			return code, true
		}
		return "unnamed", true
	case string:
		if e != "" {
			return e, true
		}
	}
	return "", false
}

// unreadableReadHint is the wording the non-paginated read refusal carries for
// the transport classes. Same register as its list and write siblings: name the
// transport, because that is what a 200 saying nothing always means on a read.
const unreadableReadHint = "the transport, not the query: a proxy/gateway page or a truncated response. Retry, then check the server URL and that the API is up."

// unreadableReadContradictionHint is for the ONE class that is not a transport
// fault: the server returned a success status carrying its own failure
// envelope. Retrying is the wrong advice there — the error is the answer, and
// the remedy is to read it.
const unreadableReadContradictionHint = "the SERVER contradicted itself — a success status carrying a failure envelope. The error above is the real outcome; do not treat this call as having succeeded, and report the status/body pair if it recurs."

// screenUnpaginatedRead is the THIRD hole in the PDS reader law, and the one
// left open by construction. Waves 27 and 28 fenced the `--all` walk and the
// paginated DEFAULT page; wave 29 fenced the 93 write verbs. All three are
// gated on `cmd.Paginated` or `cmd.Writes`, so the 52 commands that are
// NEITHER — every non-paginated read on the live manifest: doc.get,
// doc.related, doc.history, task.get, task.prime, task.events, media.search,
// media.suggest, schema.get, secret.get, auth.me, graph.*, … — sat outside
// every screen.
//
// MEASURED against a fake API serving HTTP 200 (bp doc get post p1, all four
// output shapes, 28 runs): every single one exited 0. `-o table` over `{}`
// printed ZERO BYTES on both channels — read by a human as "no data", not as
// "it broke". `-o minimal` printed the literal word `ok` over `{}`, `null`,
// `{"result":null}` and `[]`. An HTML 502 proxy page was echoed verbatim in all
// four shapes. And an ERROR ENVELOPE arriving on a 200 was printed as the
// SUCCESS body — `-o minimal` rendered it as `not ok`, at rc=0.
//
// THE DISCRIMINATOR IS NARROWER THAN THE WRITE SIDE, DELIBERATELY. A write has
// no honest empty receipt, so unreadableWriteReceipt refuses `{}` and `[]`. A
// READ does: an empty object from data.counts on a fresh dataset, and an empty
// array from media.collections on an empty library, are correct answers. Only
// bodies that carry no statement AT ALL are refused:
//
//   - an empty body on a status that did not declare one (no 204/205);
//   - an HTML DOCUMENT, which on an API read is always an interposed
//     proxy/gateway page;
//   - a `{"result": …}` envelope the server declared and then filled with
//     non-JSON;
//   - an error envelope on a 2xx — the server contradicting itself.
//
// THE NON-JSON CLASS IS DECIDED BY THE CONTENT-TYPE, NOT BY A PARSE ATTEMPT.
// A blanket "does not parse as JSON" would red onixedit.export, a REAL
// non-paginated read that streams ONIX 3.0 XML through this same dispatch
// (plugins/onixedit/cli.ex:34). The header is the honest discriminator: a
// server that DECLARES application/json and then sends bytes that are not JSON
// is contradicting itself, and that is a transport lie whoever sent it. A
// server that declares text/xml and sends XML is telling the truth.
//
// This closes the measured hole a load-balancer banner walked through: HTTP
// 200, `upstream connect error`, 23 bytes, rendered as the answer at exit 0 in
// all four output shapes. It is screened now only when the response also
// claims to be JSON — a bare gateway that declares text/plain or nothing at
// all still passes, because this function cannot tell that from an honest
// plaintext payload without inventing a rule the manifest does not state.
func screenUnpaginatedRead(out *writer, cmd manifest.Command, status int, respBody []byte, contentType string) (int, bool) {
	if cmd.Writes || cmd.Paginated {
		return 0, false
	}
	if (status == http.StatusNoContent || status == http.StatusResetContent) &&
		len(bytes.TrimSpace(respBody)) == 0 {
		return 0, false
	}

	reason, contradiction := unreadableReadBody(respBody)
	if reason == "" && declaredJSONThatIsNotJSON(contentType, respBody) {
		reason = "declared Content-Type " + contentType +
			" and sent bytes that are not JSON — a transport lie, not an answer"
	}
	if reason == "" {
		return 0, false
	}

	hint := unreadableReadHint
	if contradiction {
		hint = unreadableReadContradictionHint
	}
	msg := fmt.Sprintf(
		"unreadable read: HTTP %d %s (%d bytes): %s",
		status, reason, len(respBody), bodyPreview(respBody),
	)
	refuseWithRemedy(out, "unreadable_read", msg, hint)
	return exitGeneric, true
}

// unreadableReadBody names WHY a 2xx read body carries no statement, or "" when
// it is an answer worth rendering. The second return distinguishes the ONE
// non-transport class (a failure envelope on a success status) so the refusal
// can carry the right remedy instead of advising a retry that cannot help.
//
// Everything not listed in screenUnpaginatedRead's doc comment PASSES —
// including `{}`, `[]`, `null`, every scalar, non-HTML non-JSON bytes, and any
// object regardless of its keys. That is the point: a read has honest empty
// answers, and an allowlist of recognised shapes here would red them.
// declaredJSONThatIsNotJSON reports the one class the body alone cannot name:
// the server SAID application/json and then did not send JSON. A gateway that
// interposes its own plaintext banner keeps the upstream's declared type often
// enough that this catches it, while onixedit.export (application/xml) and any
// other honestly-typed payload are never touched.
//
// An EMPTY body is not judged here — unreadableReadBody already owns that case
// with a better sentence, and double-naming it would produce two reasons for
// one fault.
func declaredJSONThatIsNotJSON(contentType string, body []byte) bool {
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return false
	}
	if mediaType != "application/json" && !strings.HasSuffix(mediaType, "+json") {
		return false
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return false
	}
	return json.Unmarshal(body, new(any)) != nil
}

func unreadableReadBody(body []byte) (string, bool) {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 {
		return "returned an empty body without declaring one (no 204/205 no-content status)", false
	}
	if isHTMLDocument(trimmed) {
		return "carried an HTML document, not an API response", false
	}
	if json.Unmarshal(body, new(any)) != nil {
		// Non-JSON that is not an HTML document: onixedit.export's ONIX XML
		// lives here, and so does a plaintext gateway error. Telling them apart
		// needs the response Content-Type. Pass rather than guess.
		return "", false
	}
	// unwrapResult returns the body unchanged when there is no `result` key, so
	// this ONE check covers both spellings of the envelope — `{"ok":false,
	// "error":…}` bare and nested under `result`.
	var payload any
	if json.Unmarshal(unwrapResult(body), &payload) != nil {
		return `carried a {"result": …} envelope whose payload is not JSON`, false
	}
	if m, ok := payload.(map[string]any); ok {
		if code, isErr := errorEnvelopeOn2xx(m); isErr {
			return fmt.Sprintf("carried an ERROR envelope (%s) on a success status", code), true
		}
	}
	return "", false
}

// isHTMLDocument reports whether b opens as an HTML document — a `<!doctype
// html>` or `<html` root, optionally behind an XML declaration (XHTML). It is
// NOT "looks like markup": ONIX 3.0 opens `<?xml …?><ONIXMessage`, which must
// keep passing, so the check demands the html root specifically.
func isHTMLDocument(b []byte) bool {
	s := bytes.TrimSpace(b)
	if bytes.HasPrefix(s, []byte("<?xml")) {
		if end := bytes.Index(s, []byte("?>")); end >= 0 {
			s = bytes.TrimSpace(s[end+2:])
		}
	}
	if len(s) > 512 {
		s = s[:512]
	}
	lower := bytes.ToLower(s)
	if bytes.HasPrefix(lower, []byte("<!doctype html")) {
		return true
	}
	// `<html` needs a TAG BOUNDARY after it, or `<htmlish>` — a perfectly good
	// element name in someone's XML vocabulary — reads as a proxy page.
	if !bytes.HasPrefix(lower, []byte("<html")) {
		return false
	}
	rest := lower[len("<html"):]
	if len(rest) == 0 {
		return true
	}
	switch rest[0] {
	case '>', '/', ' ', '\t', '\r', '\n':
		return true
	}
	return false
}

// warnIfDefaultPageMayBeTruncated keeps the normal single-page path honest: a
// full default page cannot prove that the server has no next page. The notice is
// stderr-only so JSON/YAML stdout stays machine-readable, and it is deliberately
// suppressed when the caller chose an explicit limit (or --all), for writes, and
// for non-paginated commands.
func warnIfDefaultPageMayBeTruncated(out *writer, g globals, cmd manifest.Command, respBody []byte) {
	if !cmd.Paginated || cmd.Writes || g.all {
		return
	}

	// AN EXPLICIT --limit USED TO SILENCE THIS ENTIRELY, which inverted the
	// guard: `--limit 50` returning exactly 50 rows is the single strongest
	// signal that the page was cut, and it was the one case that said nothing.
	// The flag that was HONOURED silenced the warning that the flag being
	// honoured made necessary. An explicit limit now sets the threshold rather
	// than suppressing the check.
	limit := defaultPageLimit(cmd)
	explicit := false
	if g.limitSet {
		limit, explicit = g.limit, true
	}
	if limit <= 0 {
		return
	}
	rows, _ := extractListRows(unwrapResult(respBody))
	if len(rows) < limit {
		return
	}

	if explicit {
		out.userErr("result page filled your --limit of %d exactly; more may be available — raise --limit or re-run with --all", limit)
		return
	}
	out.userErr("result page reached the default limit of %d; more may be available — re-run with --all", limit)
}

func defaultPageLimit(cmd manifest.Command) int {
	for _, flag := range cmd.Flags {
		if flag.Name != "limit" || flag.Default == nil {
			continue
		}
		limit, err := strconv.Atoi(fmt.Sprint(flag.Default))
		if err == nil && limit > 0 {
			return limit
		}
	}
	return 0
}

// authHeaders returns the tier-appropriate auth headers for cmd. Only `none`
// (public, existence-hiding floor) sends no credential. Every authenticated
// tier — read, write, admin, scoped_admin — carries the resolved api bearer
// token whenever one is present, regardless of scoped_prefix: flat
// auth-required reads (e.g. GET /api/workspaces, GET /v1/tasks/:dataset) need
// the bearer just as much as scoped ones, and an OptionalToken public read
// simply ignores a bearer it doesn't need. `ingest` sends the shared ingest
// secret instead of the bearer. NOTE: a scoped_admin command is NEVER
// client-preflight-refused (rule #2) — it is sent with the bearer token and the
// server's 403, if any, is surfaced cleanly.
func authHeaders(cmd manifest.Command, ctx manifest.Context) map[string]string {
	h := map[string]string{}
	switch cmd.AuthTier {
	case "none":
		// Public, unauthenticated. Send nothing.
	case "read", "write", "admin", "scoped_admin":
		if ctx.Token != "" {
			h["Authorization"] = "Bearer " + ctx.Token
		}
	case "ingest":
		// Ingest commands (e.g. bulldocs writes) authenticate with the shared
		// ingest secret, NOT the api_tokens bearer. The server's
		// RequireIngestToken plug reads `Authorization: Bearer <secret>` and
		// constant-time-compares it against the configured :ingest_token
		// (wired from BARKPARK_INGEST_TOKEN). So the
		// secret rides the standard Authorization: Bearer header — same header,
		// different credential source than the bearer api token.
		if secret := ingestSecret(ctx); secret != "" {
			h["Authorization"] = "Bearer " + secret
		}
	default:
		// Unknown tier: be permissive and attach the token if we have one.
		if ctx.Token != "" {
			h["Authorization"] = "Bearer " + ctx.Token
		}
	}
	return h
}

// ingestSecret resolves the shared ingest secret for an `auth_tier: ingest`
// command. It reads BARKPARK_INGEST_TOKEN first, then the legacy
// PAPERFLOW_INGEST_TOKEN env var the server still honours. As a last
// resort it falls back to the resolved bearer token — best-effort only, for the
// single-secret dev setup where both happen to be the same value. The server's
// RequireIngestToken plug compares this against :ingest_token.
func ingestSecret(ctx manifest.Context) string {
	if s := os.Getenv("BARKPARK_INGEST_TOKEN"); s != "" {
		return s
	}
	if s := os.Getenv("PAPERFLOW_INGEST_TOKEN"); s != "" {
		return s
	}
	return ctx.Token
}

// shortFlagAliases maps a single-dash short flag to the canonical long flag
// name it stands for. Only -f/--file is wired today (the universal batch-payload
// short form); the table keeps it discoverable and additive. A short alias is
// only honoured when the command actually declares the long flag — so it never
// invents a flag the manifest didn't.
var shortFlagAliases = map[string]string{
	"-f": "file",
}

// flagShaped reports whether tok names a flag DECLARED on this command — long
// form (--name, --name=val) or a dash-prefixed form (-name, or a registered
// short alias like -f) whose resolved name is in byName. It exists solely to
// stop a value-flag from silently swallowing the next flag as its value
// (`--foo --bar` binding --foo="--bar"): a dash-prefixed token that does NOT
// resolve to a declared flag (a negative number, an arbitrary literal) is left
// alone and still binds as the value.
func flagShaped(tok string, byName map[string]manifest.Flag) bool {
	if tok == "-" || !strings.HasPrefix(tok, "-") {
		return false
	}
	if long, aliased := shortFlagAliases[tok]; aliased {
		_, ok := byName[long]
		return ok
	}
	name := strings.TrimLeft(tok, "-")
	if name == "" {
		return false
	}
	if eq := strings.IndexByte(name, '='); eq >= 0 {
		name = name[:eq]
	}
	_, ok := byName[name]
	return ok
}

// splitArgs separates positional args from command-local flags in tail.
// Command flags are looked up in cmd.Flags; an unknown -flag is an error so a
// typo doesn't get silently swallowed as a positional. Long flags use
// --name[=val]; the -f short form aliases --file when the command declares it.
func splitArgs(cmd manifest.Command, tail []string) (pos []string, flags map[string][]string, err error) {
	flags = map[string][]string{}
	byName := map[string]manifest.Flag{}
	for _, f := range cmd.Flags {
		byName[f.Name] = f
	}

	i := 0
	for i < len(tail) {
		a := tail[i]

		// Long flag: --name or --name=value.
		if len(a) >= 2 && strings.HasPrefix(a, "--") {
			name := a[2:]
			val := ""
			hasInline := false
			if eq := strings.IndexByte(name, '='); eq >= 0 {
				val = name[eq+1:]
				name = name[:eq]
				hasInline = true
			}
			f, ok := byName[name]
			if !ok {
				return nil, nil, fmt.Errorf("unknown flag --%s for %s %s", name, cmd.Noun, cmd.Verb)
			}
			if f.Type == "bool" {
				// `--force=false` must not silently set the flag true: an inline
				// value on a bool is a usage error, mirroring parseGlobals.
				if hasInline {
					return nil, nil, fmt.Errorf("flag --%s takes no value", name)
				}
				flags[name] = append(flags[name], "true")
			} else {
				if !hasInline {
					if i+1 >= len(tail) {
						return nil, nil, fmt.Errorf("flag --%s needs a value", name)
					}
					if flagShaped(tail[i+1], byName) {
						return nil, nil, fmt.Errorf("flag --%s needs a value", name)
					}
					val = tail[i+1]
					i++
				}
				flags[name] = append(flags[name], val)
			}
			i++
			continue
		}

		// Short flag: -f (and any future -x aliases). Resolve to its canonical
		// long flag, then reuse the long-flag value-consume path.
		if len(a) == 2 && a[0] == '-' && a != "-" {
			long, aliased := shortFlagAliases[a]
			if !aliased {
				return nil, nil, fmt.Errorf("unknown flag %s for %s %s", a, cmd.Noun, cmd.Verb)
			}
			f, ok := byName[long]
			if !ok {
				return nil, nil, fmt.Errorf("unknown flag %s for %s %s", a, cmd.Noun, cmd.Verb)
			}
			if f.Type == "bool" {
				flags[long] = append(flags[long], "true")
				i++
				continue
			}
			if i+1 >= len(tail) {
				return nil, nil, fmt.Errorf("flag %s needs a value", a)
			}
			if flagShaped(tail[i+1], byName) {
				return nil, nil, fmt.Errorf("flag %s needs a value", a)
			}
			flags[long] = append(flags[long], tail[i+1])
			i += 2
			continue
		}

		pos = append(pos, a)
		i++
	}
	return pos, flags, nil
}

// bindArgs maps positional values onto the command's declared args by position,
// enforcing required args. An empty-string positional counts as absent: a
// required arg then yields the friendly missing-arg error (with the usage block)
// instead of a cryptic unresolved-placeholder failure downstream, and an
// optional arg simply produces no map key. Extra positionals beyond the declared
// args are an error.
func bindArgs(cmd manifest.Command, pos []string) (map[string]string, error) {
	m := map[string]string{}
	for i, arg := range cmd.Args {
		if i < len(pos) && pos[i] != "" {
			m[arg.Name] = pos[i]
		} else if arg.Required {
			return nil, fmt.Errorf("missing required argument <%s> for %s %s", arg.Name, cmd.Noun, cmd.Verb)
		}
	}
	if len(pos) > len(cmd.Args) {
		return nil, fmt.Errorf("too many arguments for %s %s (expected %d)", cmd.Noun, cmd.Verb, len(cmd.Args))
	}
	return m, nil
}

// applyQuery appends query-string parameters: pagination (--limit/--offset for a
// paginated command), any manifest-declared string/int flags that are not the
// body-carrying file/set flags, and any declared positional arg whose location
// resolves to "query" (a non-path arg on a read — e.g. search's `q`). Path
// placeholders are already consumed by BuildURL and are skipped here.
func applyQuery(rawURL string, g globals, cmd manifest.Command, flags map[string][]string, args map[string]string) string {
	q := url.Values{}

	// The resolved response projection (AXI brief views). g.view is set only by
	// resolveView (CLI, gated on a manifest views declaration) or deliberately
	// by an MCP handler — so a non-empty value is always intentional.
	if g.view != "" {
		q.Set("view", g.view)
	}

	// --limit / --offset are GLOBAL flags: parseGlobals consumes them wherever
	// they appear in argv, so a command-local `limit`/`offset` flag the manifest
	// declares can NEVER see them — the same trap globals.go documents for
	// --dataset (globals.go:52). Gating the forward on `cmd.Paginated` alone
	// therefore DROPPED them, silently and before the request was built, on
	// every command that declares its own limit/offset without being paginated.
	// Six on the live manifest, all measured with --dry-run against
	// guerrilla.barkpark.cloud:
	//
	//	bp doc related X --limit 25   -> /v1/data/related/production/X   (no limit)
	//	bp doc history post p1 --limit 3 -> /v1/data/history/…/post/p1   (no limit)
	//	bp media search --limit 100 --offset 200 -> /v1/media/…/search   (NEITHER)
	//	bp media suggest --limit 20   -> /v1/media/…/search/suggestions  (no limit)
	//	bp task prime --limit 50      -> /v1/tasks/prime?view=brief      (no limit)
	//	bp task events --limit 25     -> /v1/tasks/events                (no limit)
	//
	// Each answered with the SERVER's default (10, 10, 50, 8, 10, 500) at rc=0,
	// so the caller read a page it had not asked for as the page it had.
	// media.search is the sharpest: its own flag summary reads "Hits to skip
	// (paginate with --limit)", and neither knob could ever leave the CLI, so
	// every "next page" was page one. The discriminator is the globals table,
	// not the route — on the same commands `--since 99` and `--kind image` rode
	// fine, because parseGlobals does not recognise them.
	//
	// The rule is DECLARATION-driven, not paginated-driven: forward the knob
	// when the command's own manifest says it accepts it. `paginated: true`
	// stays in the disjunction because those seven commands take limit/offset
	// as protocol whether or not they also enumerate them as flags.
	if g.limitSet && (cmd.Paginated || commandDeclaresFlag(cmd, "limit")) {
		q.Set("limit", strconv.Itoa(g.limit))
	}
	if g.offsetSet && (cmd.Paginated || commandDeclaresFlag(cmd, "offset")) {
		q.Set("offset", strconv.Itoa(g.offset))
	}

	// Declared positional args that belong in the query string (e.g. search.query
	// `q` against /v1/data/search/:dataset, which has no :q placeholder).
	for _, a := range cmd.Args {
		if cmd.ArgLocation(a) != "query" {
			continue
		}
		if v, ok := args[a.Name]; ok && v != "" {
			q.Add(a.Name, v)
		}
	}

	// Flags the CLI consumes itself — never forwarded as query params. `all` is a
	// global (client-side pagination); `file`/`set`/`quiet` carry the request body.
	clientOnly := map[string]bool{"file": true, "set": true, "quiet": true, "all": true}
	for _, f := range cmd.Flags {
		if clientOnly[f.Name] || f.Type == "file" || commandFlagBelongsInBody(cmd, f.Name) {
			continue
		}
		// limit/offset are already resolved above from the globals, which is the
		// ONLY place they can arrive from (parseGlobals consumes them wherever
		// they appear, so `flags` never holds them). Skipping the name we
		// already set keeps that provable rather than assumed: were a caller to
		// populate both, `q.Add` here would append a SECOND scalar `limit=` and
		// Plug would keep one of the two by decode order — the duplicate-key
		// coin-flip the repeatable-flag branch below exists to avoid.
		if (f.Name == "limit" || f.Name == "offset") && q.Has(f.Name) {
			continue
		}
		if f.Type == "bool" {
			// A set bool flag rides as `?name=true` (server reads the string).
			if vals, ok := flags[f.Name]; ok && len(vals) > 0 && vals[len(vals)-1] == "true" {
				q.Set(f.Name, "true")
			}
			continue
		}
		if vals, ok := flags[f.Name]; ok {
			// A repeated flag given MORE THAN ONCE rides as the bracket list form
			// (`filter[]=a&filter[]=b`) rather than a duplicate scalar key. Plug
			// decodes a duplicate scalar key by keeping ONE value — which one
			// depends on decode order, so `--filter a --filter b` silently
			// answered a different question than it asked (Gyldendal #16: the
			// same pair returned 3 rows or 17 depending purely on order, 200 OK,
			// no warning). The list form reaches the server as a LIST, which
			// QueryController.normalize_filter_map/1 AND-composes. A single
			// value keeps the plain `name=v` spelling, so nothing that works
			// today changes shape.
			name := f.Name
			if f.Repeatable && len(vals) > 1 {
				name = f.Name + "[]"
			}
			for _, v := range vals {
				q.Add(name, v)
			}
		}
	}

	if len(q) == 0 {
		return rawURL
	}
	sep := "?"
	if strings.Contains(rawURL, "?") {
		sep = "&"
	}
	return rawURL + sep + q.Encode()
}

// buildBody builds the request body for a write command. Sources, in increasing
// precedence:
//
//  1. --file <path> (or - for stdin) when this is a mutation command; the file
//     must contain a JSON object and seeds the mutation payload. For other
//     commands, --file remains the complete request body.
//  2. declared non-path positional args (arg name -> value) whose location
//     resolves to "body" — e.g. webhook.create `url` -> {"url":"…"},
//     workspace.project-create `name` -> {"name":"…"}.
//  3. --set k=v pairs, merged last so repeated --set values win per key.
//
// A POST-bound, declared file-typed arg is special-cased FIRST, regardless of
// route: it ships as multipart/form-data with the file under the "file" form
// field, not as JSON —
// and as a streaming io.Reader (returned in stream, with body nil) so a large
// upload is neither buffered whole in memory nor killed by the 30s wall-clock.
// Reads return nil; a write with no body source sends an empty JSON object so a
// POST/PUT that expects JSON does not choke on an empty body.
func buildBody(cmd manifest.Command, flags map[string][]string, args map[string]string) (body []byte, stream io.Reader, contentType string, err error) {
	return buildBodyWithStdinOwnership(cmd, flags, args, true)
}

// buildBodyWithStdinOwnership keeps process-stdin policy at the existing
// human/headless dispatch seam. Direct CLI commands own stdin and therefore
// reject redirected input unless --file - consumes it. Headless dispatchers
// (MCP stdio and HTTP) do not own process stdin: it may be a protocol transport,
// so they neither inspect nor consume it.
func buildBodyWithStdinOwnership(cmd manifest.Command, flags map[string][]string, args map[string]string, ownsProcessStdin bool) (body []byte, stream io.Reader, contentType string, err error) {
	if !cmd.Writes {
		return nil, nil, "", nil
	}

	// Media upload (or any POST command with a declared file-typed arg):
	// multipart, streamed via io.Pipe so it rides doRequestStream's transfer
	// client.
	if path, ok := mediaUploadFileArg(cmd, args); ok {
		r, ct, err := buildMultipartFile(path)
		return nil, r, ct, err
	}

	stdinRedirected := ownsProcessStdin && stdinHasRedirectedInput()

	// For ordinary writes, --file is the whole request body. Mutation commands
	// instead treat it as the document object that declared args and --set merge
	// into before the mutation wrapper is applied.
	var obj map[string]any
	if files, ok := flags["file"]; ok && len(files) > 0 {
		path := files[len(files)-1]
		if path == "-" && !ownsProcessStdin {
			return nil, nil, "", fmt.Errorf("--file - is unavailable in headless dispatch")
		}
		if path != "-" && stdinRedirected {
			return nil, nil, "", fmt.Errorf("piped stdin is unused; pass --file - to consume it")
		}
		var raw []byte
		if path == "-" {
			raw, err = io.ReadAll(os.Stdin)
		} else {
			raw, err = os.ReadFile(path)
		}
		if err != nil {
			return nil, nil, "", fmt.Errorf("read --file %q: %w", path, err)
		}
		// A plain (non-mutation) write with no body flags to merge ships the file
		// verbatim. But when the command has body-membership flags set (e.g.
		// bulldocs.patch --if-rev), the file is the base object those flags merge
		// into — parse it so the guard joins the payload instead of being dropped.
		if cmd.MutationOp == "" && !commandHasSetBodyFlags(cmd, flags) {
			return raw, nil, "application/json", nil
		}
		bodyKind := "mutation body"
		if cmd.MutationOp == "" {
			bodyKind = "--file body"
		}
		if err := json.Unmarshal(raw, &obj); err != nil {
			return nil, nil, "", fmt.Errorf("read --file %q: %s must be a JSON object: %w", path, bodyKind, err)
		}
		if obj == nil {
			return nil, nil, "", fmt.Errorf("read --file %q: %s must be a JSON object", path, bodyKind)
		}
	} else if stdinRedirected {
		// Recommend --file - only where the manifest actually declares the
		// flag — `doc patch` declares [set] only, and telling its user to
		// pass a flag the parser rejects with exit 2 is worse than no hint.
		if commandHasFileFlag(cmd) {
			return nil, nil, "", fmt.Errorf("piped stdin is unused; pass --file - to consume it")
		}
		// A mutation command (create/patch/etc via --set) has NO file flag but
		// its payload is still plausibly meant to come from a piped body — a
		// user might reasonably expect `cat doc.json | bp doc patch task <id>`
		// to work the way `--file -` does. Keep the hard refusal there so that
		// expectation never silently loses data (the doc-patch boundary,
		// gfr-w1-stdin-guard-altitude — decided explicitly, not by omission).
		if cmd.MutationOp != "" {
			return nil, nil, "", fmt.Errorf("piped stdin is unused and %s %s does not accept --file; remove the stdin redirect", cmd.Noun, cmd.Verb)
		}
		// Every other write command (task close, task next, webhook create,
		// media upload, most cloud verbs — 59 of the 72 write commands in the
		// served manifest) has NEITHER a file flag NOR a mutation_op: there is
		// NO way for it to read a body from stdin at all, so a piped/redirected
		// stdin can never be silently swallowed here. Refusing anyway only
		// serves to abort `while read -r id; do bp task close "$id" …; done`
		// on every iteration (Gyldendal finding #20 — 'knekker enhver
		// while-read-lokke'). Proceed: the command was going to ignore stdin
		// either way, so nothing about its behavior changes.
	}

	// Seed the body object from declared body-location args, then merge --set.
	if obj == nil {
		obj = map[string]any{}
	}
	for _, a := range cmd.Args {
		if cmd.ArgLocation(a) != "body" {
			continue
		}
		if v, ok := args[a.Name]; ok && v != "" {
			obj[a.Name] = v
		}
	}
	for _, f := range cmd.Flags {
		if !commandFlagBelongsInBody(cmd, f.Name) {
			continue
		}
		if values := flags[f.Name]; len(values) > 0 {
			obj[bodyFlagKey(f.Name)] = values[len(values)-1]
		}
	}
	// --set fields target: nested under SetKey (e.g. patch's `set`) or, by
	// default, merged flat into the body object.
	setTarget := obj
	if cmd.SetKey != "" {
		setTarget = map[string]any{}
	}
	if sets, ok := flags["set"]; ok && len(sets) > 0 {
		for _, kv := range sets {
			// key:=raw-json sends a TYPED value (httpie convention): the
			// server's patch path merges verbatim with no coercion, so
			// `--set priority=3` stores the STRING "3" (task validators
			// 422 it; untyped schemas silently flip the JSONB type).
			// `--set priority:=3` sends the number; arrays/objects/bools/
			// null ride the same way. Plain key=value stays a string —
			// type is the caller's explicit choice, never sniffed from the
			// value (a title that LOOKS numeric must stay a string).
			if eq := strings.Index(kv, ":="); eq >= 0 && !strings.Contains(kv[:eq], "=") {
				var typed any
				if err := json.Unmarshal([]byte(kv[eq+2:]), &typed); err != nil {
					return nil, nil, "", fmt.Errorf("invalid --set %q: %q is not valid JSON (key:=value sends raw JSON; use key=value for strings)", kv, kv[eq+2:])
				}
				setTarget[kv[:eq]] = typed
				continue
			}
			eq := strings.IndexByte(kv, '=')
			if eq < 0 {
				return nil, nil, "", fmt.Errorf("invalid --set %q (want key=value, or key:=json for typed values)", kv)
			}
			setTarget[kv[:eq]] = kv[eq+1:]
		}
	}
	if cmd.SetKey != "" {
		obj[cmd.SetKey] = setTarget
	}

	// A mutation command (doc publish/unpublish/delete) wraps its body-arg object
	// into the mutate batch shape: {mutations: [{<op>: {type, id, …}}]}.
	if cmd.MutationOp != "" {
		wrapped := map[string]any{
			"mutations": []any{map[string]any{cmd.MutationOp: obj}},
		}
		raw, _ := json.Marshal(wrapped)
		return raw, nil, "application/json", nil
	}

	if len(obj) == 0 {
		// A write with no body source: send an empty JSON object so a POST/PUT
		// that expects JSON does not choke on an empty body.
		return []byte("{}"), nil, "application/json", nil
	}
	raw, _ := json.Marshal(obj)
	return raw, nil, "application/json", nil
}

// commandFlagBelongsInBody reports whether a command-local flag rides in the
// JSON request body instead of the query string. The rule is MANIFEST-DRIVEN,
// not a table of command ids:
//
//   - A BATCH write command's payload IS a JSON body (the `ops` array), so its
//     scalar control flags belong at the body head. bulldocs.patch's `--if-rev`
//     optimistic-concurrency guard is the motivating case: the server reads
//     `Map.get(params, "ifRev")`, so a `?if-rev=1` query param never matched and
//     the guard was a silent no-op (a stale patch overwrote a newer paper
//     instead of 412). Routed through the body (as camelCase `ifRev`, see
//     bodyFlagKey) the guard fires. Client-consumed flags (`file` carries the
//     payload via the --file path; `set`/`quiet`/`all` are consumed by the CLI
//     itself) are excluded — this MUST mirror applyQuery's clientOnly set, or a
//     batch write's own control flag (e.g. `doc mutate --quiet`) would both skip
//     the query string AND leak into the wire body.
//   - cycle.open predates the batch rule: it is a non-batch write whose *_json
//     contract flags ride the body by id. Retained verbatim.
func commandFlagBelongsInBody(cmd manifest.Command, name string) bool {
	// clientConsumed mirrors applyQuery's clientOnly set: these flags never ride
	// the wire (as query OR body) — the CLI consumes them locally.
	switch name {
	case "file", "set", "quiet", "all":
		return false
	}
	if cmd.Writes && cmd.Batch {
		return true
	}
	if cmd.ID == "cycle.open" {
		switch name {
		case "experiment_contract_json", "correction_of_json", "correction_of_digest", "release_gate_receipt_json":
			return true
		}
	}
	return false
}

// commandHasSetBodyFlags reports whether the caller actually set any body-membership
// flag on cmd. When true, a --file payload for a non-mutation write must be parsed
// and merged (so e.g. bulldocs.patch's --if-rev joins the ops object at the body
// head) rather than shipped verbatim.
func commandHasSetBodyFlags(cmd manifest.Command, flags map[string][]string) bool {
	for _, f := range cmd.Flags {
		if commandFlagBelongsInBody(cmd, f.Name) && len(flags[f.Name]) > 0 {
			return true
		}
	}
	return false
}

// bodyFlagKey maps a hyphenated CLI flag name to the camelCase JSON key the API
// reads for it (`if-rev` → `ifRev`). Names without a hyphen — cycle.open's
// snake_case *_json contract flags, single-word flags — pass through unchanged,
// so the server-side spelling is preserved exactly.
func bodyFlagKey(name string) string {
	if !strings.Contains(name, "-") {
		return name
	}
	parts := strings.Split(name, "-")
	var b strings.Builder
	b.WriteString(parts[0])
	for _, p := range parts[1:] {
		if p == "" {
			continue
		}
		b.WriteString(strings.ToUpper(p[:1]))
		b.WriteString(p[1:])
	}
	return b.String()
}

// commandHasFileFlag reports whether cmd's manifest declares the --file body
// flag (by name or file type — the same dual test applyQuery uses to keep the
// flag client-side). The manifest is authoritative: help text and guard
// messages must never mention --file for a command whose parser rejects it.
func commandHasFileFlag(cmd manifest.Command) bool {
	for _, f := range cmd.Flags {
		if f.Name == "file" || f.Type == "file" {
			return true
		}
	}
	return false
}

// stdinHasRedirectedInput reports whether redirected (non-terminal) stdin
// currently carries bytes that a write would silently discard. Redirection
// alone is not enough: CI `run:` steps, cron, and Makefile pipelines routinely
// hand the process an EMPTY pipe, and a guard against swallowing data must not
// hard-error when there is no data. It deliberately never reads — --file -
// remains the sole stdin consumer — and never blocks: the byte count comes
// from a non-blocking readiness probe (see stdinPendingBytes), so an
// open-but-empty pipe with a live writer proceeds without the warning rather
// than hanging. Regular-file redirects are sized via Stat. When the probe
// cannot answer (exotic file types, or platforms without one), it falls back
// to the historical conservative answer: redirected means guarded.
func stdinHasRedirectedInput() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	if info.Mode()&os.ModeCharDevice != 0 {
		return false
	}
	if info.Mode().IsRegular() {
		// SIZE is not BYTES REMAINING: a `while read ... done < file` loop
		// shares this fd's offset with the shell's own `read` builtin (both
		// inherited it from the same open file description), so by the time
		// bp runs mid-loop the file has already been partially or fully
		// consumed. info.Size() reports the file's total length regardless of
		// offset, so a fully-drained regular-file redirect (0 bytes left to
		// read) still measured as "has data" and tripped this guard on every
		// iteration — the offset-blind half of the Gyldendal while-read
		// finding (gfr-w1-stdin-guard-altitude). Compare size against the
		// CURRENT offset instead. A Seek failure (a regular file that somehow
		// can't report position) falls back to the historical size-only
		// answer rather than silently disabling the guard.
		if pos, err := os.Stdin.Seek(0, io.SeekCurrent); err == nil {
			return info.Size() > pos
		}
		return info.Size() > 0
	}
	n, ok := stdinPendingBytes(os.Stdin)
	if !ok {
		return true
	}
	return n > 0
}

// mediaUploadFileArg returns the bound file path when cmd has a POST-bound,
// file-typed DECLARED ARG — the signal that the payload must be sent as
// multipart/form-data rather than JSON. This used to also require the route's
// path_template to contain the substring "/media", which stood in for "this
// command uploads a file" instead of reading the manifest's own declaration
// of that fact. A plugin's own ingest route (e.g. a sheets or bulldocs import
// endpoint spelled without "/media" anywhere) has a legitimate file-typed arg
// too, and fell through to the JSON path: the file's PATH STRING got shipped
// as a JSON value ({"file":"/abs/path"}) instead of the file's BYTES as a
// multipart part, and the server answered "multipart field \"file\" is
// required". The manifest's own `type: "file"` on a declared ARG (as opposed
// to a `--file` FLAG — see commandHasFileFlag — which reads a local JSON
// payload off disk and is not this at all) is the authoritative signal by
// itself; the route text was never load-bearing beyond restating what the one
// existing holder (media.upload) already declares structurally.
func mediaUploadFileArg(cmd manifest.Command, args map[string]string) (string, bool) {
	if cmd.HTTP.Method != "POST" {
		return "", false
	}
	for _, a := range cmd.Args {
		if a.Type != "file" {
			continue
		}
		if v, ok := args[a.Name]; ok && v != "" {
			return v, true
		}
	}
	return "", false
}

// buildMultipartFile streams path as a multipart/form-data body under the "file"
// form field (the field name the server's media upload plug expects) via
// io.Pipe, so the file is never buffered whole in memory. It opens+stats the
// file up front (keeping the friendly missing-file error text), then a goroutine
// writes the form part and io.Copies the file into the pipe, calling
// pw.CloseWithError on any failure so the in-flight HTTP request aborts with that
// error. The returned reader is NOT replayable — safe only because
// doRequestStream never retries. The content type carries the generated boundary.
func buildMultipartFile(path string) (io.Reader, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", fmt.Errorf("read upload file %q: %w", path, err)
	}
	if _, err := f.Stat(); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("read upload file %q: %w", path, err)
	}
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		defer f.Close()
		fw, err := mw.CreateFormFile("file", filepath.Base(path))
		if err != nil {
			pw.CloseWithError(fmt.Errorf("multipart create: %w", err))
			return
		}
		if _, err := io.Copy(fw, f); err != nil {
			pw.CloseWithError(fmt.Errorf("multipart write: %w", err))
			return
		}
		if err := mw.Close(); err != nil {
			pw.CloseWithError(fmt.Errorf("multipart close: %w", err))
			return
		}
		pw.Close()
	}()
	return pr, mw.FormDataContentType(), nil
}

// checkRedirect and maxRedirects come from internal/httpx, the single owner of
// bp's redirect policy: a WRITE is never followed, a READ is (capped at
// maxRedirects hops). Installed on BOTH generic request clients here — the 30s
// doRequest client and the header-timeout-only transfer client — so no bp call
// path can quietly fall back to Go's default policy, which downgrades a POST to
// a bodyless GET and reported the redirect target's 200 as a successful write.
// See httpx.CheckRedirect for the full reasoning and the reconciliation with the
// five ErrUseLastResponse probe sites elsewhere in internal/.
const maxRedirects = httpx.MaxRedirects

var checkRedirect = httpx.CheckRedirect

// transferResponseHeaderTimeout bounds only the wait for a response's headers on
// the streaming transfer client (media upload, upgrade download) — NOT the
// transfer body's wall-clock. A var, not a const, so tests can shrink it.
var transferResponseHeaderTimeout = 60 * time.Second

// newTransferClient builds an HTTP client with NO absolute Timeout — only
// connection-phase deadlines (dial, TLS handshake, response-header wait). A
// media upload or binary download whose BODY legitimately takes minutes must not
// be killed mid-transfer the way the 30s doRequest client kills any upload
// >30s wall-clock. Mirrors curl/gh/stripe: cap the connection, never the body.
// Reads transferResponseHeaderTimeout at call time so a test's shrunk value
// takes effect.
func newTransferClient() *http.Client {
	return &http.Client{
		CheckRedirect: checkRedirect,
		Transport: &http.Transport{
			Proxy: http.ProxyFromEnvironment,
			DialContext: (&net.Dialer{
				Timeout:   10 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: transferResponseHeaderTimeout,
		},
	}
}

// doRequestStream is doRequest for a streaming, non-replayable body (the
// multipart media upload io.Pipe): it takes an io.Reader and drives the
// header-timeout-only transfer client so a large/slow upload is not killed by
// doRequest's 30s wall-clock cap. contentLength >= 0 sets Content-Length; -1
// leaves it unknown (chunked). It performs NO retries — required, since a pipe
// body cannot be replayed.
func doRequestStream(method, rawURL string, headers map[string]string, body io.Reader, contentLength int64) (int, []byte, error) {
	status, respBody, _, err := doRequestStreamCT(method, rawURL, headers, body, contentLength)
	return status, respBody, err
}

// doRequestStreamCT is doRequestStream plus the response Content-Type. The
// header is the ONLY thing that separates a plaintext gateway banner from an
// honest non-JSON payload, and dropping it is why a load-balancer's "upstream
// connect error" at HTTP 200 used to render as the answer at exit 0.
//
// Added ALONGSIDE doRequestStream rather than replacing it so no existing
// caller has to change: the three-value form stays the signature every current
// call site compiles against, and only the manifest dispatch reaches for the
// fourth value.
func doRequestStreamCT(method, rawURL string, headers map[string]string, body io.Reader, contentLength int64) (int, []byte, string, error) {
	req, err := http.NewRequest(method, rawURL, body)
	if err != nil {
		return 0, nil, "", err
	}
	if contentLength >= 0 {
		req.ContentLength = contentLength
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := newTransferClient().Do(req)
	if err != nil {
		return 0, nil, "", err
	}
	defer resp.Body.Close()
	ct := resp.Header.Get("Content-Type")
	respBody, err := readCapped(resp.Body, maxResponseBytes)
	if err != nil {
		return resp.StatusCode, nil, ct, err
	}
	return resp.StatusCode, respBody, ct, nil
}

// doRequest performs the HTTP call and returns status + body. It is the
// three-value form 30 call sites across seed/migrate/paper/vercel/tinker/
// scaffy/builtins compile against; it discards the Content-Type that
// doRequestCT reads, so none of them had to change when the screen started
// needing the header.
func doRequest(method, rawURL string, headers map[string]string, body []byte) (int, []byte, error) {
	status, respBody, _, err := doRequestCT(method, rawURL, headers, body)
	return status, respBody, err
}

// doRequestCT is doRequest plus the response Content-Type — the discriminator
// screenUnpaginatedRead needs to tell a plaintext gateway banner from an
// honest non-JSON payload like onixedit.export's ONIX 3.0 XML.
func doRequestCT(method, rawURL string, headers map[string]string, body []byte) (int, []byte, string, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, rawURL, rdr)
	if err != nil {
		return 0, nil, "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: checkRedirect}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, "", err
	}
	defer resp.Body.Close()
	ct := resp.Header.Get("Content-Type")
	respBody, err := readCapped(resp.Body, maxResponseBytes)
	if err != nil {
		return resp.StatusCode, nil, ct, err
	}
	return resp.StatusCode, respBody, ct, nil
}

// maxResponseBytes caps how much of an HTTP response body the generic request
// paths will buffer.
const maxResponseBytes = 64 << 20 // 64MB — generous cap for query/doc bodies; hostile or runaway responses fail loudly instead of OOMing

// readCapped reads at most max bytes from r, failing loudly rather than silently
// truncating: it reads one byte past the cap so an over-limit body is detected
// (io.LimitReader alone would just truncate). Used by the generic HTTP request
// paths so a malformed/hostile server cannot OOM the process.
func readCapped(r io.Reader, max int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("response exceeds %d bytes — refusing to parse a truncated body", max)
	}
	return b, nil
}

// renderError renders a classified API error. Under -o json/yaml it emits the
// canonical {ok:false, error:{code, message, request_id, hint, details}} envelope
// on stdout (same contract as the cloud built-ins' useError, richer because
// apiError carries request_id + hint + details) so a scripted `bp … -o json | jq`
// gets a parseable body rather than empty stdout. For table/minimal it prints the
// human shape to stderr: the message line, the server's `details` as sorted
// `key: value` lines (per-code actionable lines for the two publish-wall codes
// — see detailLinesForCode), an indented fix-suggestion hint when one is registered,
// and — under -v — the machine code and request id for support. details comes
// FIRST of the continuation lines because it is the specific fact (which filter,
// which field, which rule) while the hint is the generic advice; a reader who
// stops after one line should get the fact. Centralised so every error path
// (single request, paginated reads) is identical.
func renderError(out *writer, ae apiError) {
	if renderErrorEnvelopeDetailed(out, ae.code, ae.errorMessage(), ae.requestID, ae.hint(), ae.details) {
		return
	}
	out.userErr("%s", ae.errorMessage())
	for _, line := range detailLinesForCode(ae.code, ae.details) {
		out.errf("  %s", line)
	}
	if h := ae.hint(); h != "" {
		out.errf("  hint: %s", h)
	}
	if ae.code != "" {
		out.info("  code: %s", ae.code)
	}
	if ae.requestID != "" {
		out.info("  request_id: %s", ae.requestID)
	}
}

// handleResponse renders a success or maps an error body to an exit code. It
// takes the manifest, not just the command, so a refusal can name the command
// that would ANSWER it — see notFoundHint.
func handleResponse(out *writer, m *manifest.Manifest, cmd manifest.Command, status int, respBody []byte) int {
	if status >= 200 && status < 300 {
		renderSuccess(out, cmd, respBody)
		return exitOK
	}
	ae := classifyError(status, respBody)
	// Record WHICH refusal this was, for the client-side wrappers that layer a
	// second read on top of a failed dispatch (runTaskClaim). They only get an
	// exit code back from runCommand, and exit 6 covers the whole task
	// claim/close contention row of the exit table — six different reasons whose
	// diagnoses are not interchangeable. Per-invocation state on the writer, not
	// a package global: one writer per bp run.
	out.lastErrorCode = ae.code
	// A not_found the server did not annotate gets the remedy derived from the
	// command that was actually dispatched, rather than the code table's
	// one-size-fits-all document answer. serverHint still outranks it — the
	// server knows more than we do — and notFoundHint returns "" rather than
	// inventing a verb the manifest cannot confirm.
	if ae.code == "not_found" && ae.serverHint == "" {
		ae.localHint = notFoundHint(m, cmd)
	}
	renderError(out, ae)
	return ae.exit
}

// renderSuccess prints a successful body in the resolved output shape. The API
// wraps data in {"result": …}; the CLI unwraps it for display so the user sees
// the payload, not the envelope. minimal/quiet prints rev + ids only.
func renderSuccess(out *writer, cmd manifest.Command, respBody []byte) {
	payload := unwrapResult(respBody)

	// Handoff-card shape: a 2xx object carrying a non-empty string "quickstart"
	// (the ticket-key mint / rotate receipt) prints that block verbatim as the
	// primary human output — the 2-minute-onboarding card the operator forwards.
	// Shape-keyed, never verb-keyed (like emitWarnings): any response may opt in
	// by carrying the field. Only the human `table` default shows the card;
	// `json`/`yaml` consumers read the structured field and `minimal` stays the
	// terse agent receipt.
	if out.output == "table" {
		if card := quickstartCard(payload); card != "" {
			out.outf("%s", card)
			emitWarnings(out, payload)
			emitNotices(out, payload)
			return
		}
	}

	switch out.output {
	case "minimal":
		renderMinimal(out, payload)
		emitWarnings(out, payload)
		emitNotices(out, payload)
	case "yaml":
		var v any
		if json.Unmarshal(payload, &v) == nil {
			out.renderYAML(v)
		} else {
			out.outf("%s", string(payload))
		}
	case "table":
		renderTable(out, payload)
		emitWarnings(out, payload)
		emitNotices(out, payload)
	default: // json
		out.renderRaw(payload)
	}
}

// quickstartCard returns the value of a top-level string "quickstart" field on
// a 2xx object payload (the ticket-key mint/rotate handoff card), or "" when the
// field is absent, empty, or not a string. Pure/shape-keyed so any endpoint can
// opt into the plain-block render by carrying the field.
func quickstartCard(payload []byte) string {
	var env struct {
		Quickstart string `json:"quickstart"`
	}
	if json.Unmarshal(payload, &env) != nil {
		return ""
	}
	return strings.TrimRight(env.Quickstart, "\n")
}

// emitWarnings prints a top-level {"warnings":[…]} advisory list to stderr for
// the human output shapes (minimal/table). Shape-keyed, never verb-keyed: any
// 2xx envelope may carry advisories — bare strings (e.g. the tasks close endpoint
// warns when a task is closed done with unmet acceptance_criteria, lvw-t6) OR the
// authoring wall's {code,severity,message} objects on the mutate success envelope
// (ae-w1). Both shapes render; an object without a non-empty message is skipped
// (malformed entries never print). Advisory only: exit code and stdout payload are
// untouched; json/yaml consumers read the field itself.
func emitWarnings(out *writer, payload []byte) {
	var env struct {
		Warnings []any `json:"warnings"`
	}
	if json.Unmarshal(payload, &env) != nil {
		return
	}
	for _, w := range env.Warnings {
		switch v := w.(type) {
		case string:
			if v != "" {
				out.errf("warning: %s", v)
			}
		case map[string]any:
			msg, _ := v["message"].(string)
			if msg == "" {
				continue // malformed / message-less object — stay silent
			}
			if code, _ := v["code"].(string); code != "" {
				out.errf("warning[%s]: %s", code, msg)
			} else {
				out.errf("warning: %s", msg)
			}
		}
	}
}

// emitNotices prints a top-level {"notices":[…]} typed list to stderr for the
// human output shapes (minimal/table), mirroring emitWarnings. Rail-awareness
// (rail-l1): a claim/close/prime 2xx envelope may carry advisory multi-agent
// notices — blocked_while_claimed (a blocker was filed onto a task you hold) or
// rail_changed (the parent rail you observed moved). Each renders as
// "notice: <type> …" with the salient fields. Advisory only: exit code and
// stdout payload are untouched; json/yaml consumers read the field itself.
// Shape-keyed, never verb-keyed; malformed or absent notices never crash.
func emitNotices(out *writer, payload []byte) {
	var env struct {
		Notices []map[string]any `json:"notices"`
	}
	if json.Unmarshal(payload, &env) != nil {
		return
	}
	for _, n := range env.Notices {
		typ, _ := n["type"].(string)
		switch typ {
		case "":
			continue
		case "blocked_while_claimed":
			task, _ := n["task_id"].(string)
			out.errf("notice: blocked_while_claimed task=%s blockers=%s", task, joinStrings(n["blockers"]))
		case "rail_changed":
			parent, _ := n["parent_id"].(string)
			rev, _ := n["rail_rev"].(string)
			out.errf("notice: rail_changed parent=%s rail_rev=%s", parent, rev)
		default:
			out.errf("notice: %s", typ)
		}
	}
}

// joinStrings renders a decoded JSON array of strings as a comma-separated
// list, skipping non-string entries. Returns "" for a non-array value.
func joinStrings(v any) string {
	items, ok := v.([]any)
	if !ok {
		return ""
	}
	parts := make([]string, 0, len(items))
	for _, it := range items {
		if s, ok := it.(string); ok {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, ",")
}

// emitTaskHelpLines is the TYPED twin of emitHelpHints (which parses raw JSON):
// it prints a claim/close outcome's already-decoded help[] templates to stderr,
// one "help: …" line each, exactly as runCommand does for the manifest path.
// The typed-helper claim/close surfaces (frontier, cmux dispatch) hold the help
// as a []string on the apiclient outcome, not raw bytes, so they call this rather
// than re-marshalling. Empty/absent help prints nothing (charter D18).
func emitTaskHelpLines(out *writer, help []string) {
	for _, h := range help {
		if h == "" {
			continue
		}
		out.errf("help: %s", h)
	}
}

// emitTaskNoticeLines is the TYPED twin of emitNotices: it renders a claim/close
// outcome's already-decoded rail-awareness notices to stderr in the same
// "notice: <type> …" shape emitNotices prints from raw JSON. The frontier/cmux
// claim paths decode notices into []apiclient.TaskNotice but never surfaced them
// — this closes that gap without a second decode. Unknown future notice types
// print their bare type (never guessed); an empty/nil slice prints nothing.
func emitTaskNoticeLines(out *writer, notices []apiclient.TaskNotice) {
	for _, n := range notices {
		switch n.Type {
		case "":
			continue
		case "blocked_while_claimed":
			out.errf("notice: blocked_while_claimed task=%s blockers=%s", n.TaskID, strings.Join(n.Blockers, ","))
		case "rail_changed":
			out.errf("notice: rail_changed parent=%s rail_rev=%s", n.ParentID, n.RailRev)
		default:
			out.errf("notice: %s", n.Type)
		}
	}
}

// unwrapResult strips a top-level {"result": X} envelope, returning X's raw
// bytes. A body without that envelope is returned unchanged.
func unwrapResult(body []byte) []byte {
	var env map[string]json.RawMessage
	if err := json.Unmarshal(body, &env); err != nil {
		return body
	}
	if r, ok := env["result"]; ok {
		return r
	}
	return body
}

// renderMinimal prints the token-efficient receipt: the rev and any document
// ids found in the payload. It is the default write receipt (default_output
// "minimal") and the -q shape.
func renderMinimal(out *writer, payload []byte) {
	var v any
	if json.Unmarshal(payload, &v) != nil {
		out.outf("%s", strings.TrimSpace(string(payload)))
		return
	}
	// Shape-keyed receipts for {"ok":…} envelopes (e.g. the tasks endpoints) —
	// keyed off the response shape, never off a verb:
	//
	//   * {"ok":false,"reason":…} on a 2xx (the tasks queue-claim returns
	//     {"ok":false,"reason":"no_ready"} with HTTP 200 on an empty queue — a
	//     valid outcome, not an error; exit stays 0 and non-2xx ok:false shapes
	//     still route through classifyError) prints the reason token. A bare
	//     "ok" there would be actively misleading.
	//   * {"ok":true,"doc":{…}} (a claim-style write returning the affected
	//     doc) prints the doc's identifying line — doc_id plus the fencing
	//     epoch when the doc carries a claim — because the caller needs both
	//     to act on what it just claimed. Falls through to the generic
	//     rev/ids/ok receipt when the doc has no recognisable id.
	if m, isMap := v.(map[string]any); isMap {
		if okv, present := m["ok"].(bool); present {
			if !okv {
				if reason, _ := m["reason"].(string); reason != "" {
					out.outf("%s", reason)
				} else {
					out.outf("not ok")
				}
				return
			}
			if doc, isDoc := m["doc"].(map[string]any); isDoc {
				if line := docReceiptLine(doc); line != "" {
					out.outf("%s", line)
					return
				}
			}
		}
		// Workspace/project create receipts ({"workspace":{…}} / {"project":
		// {…}}): the actionable handle is the SLUG — the -w/-p globals take
		// slugs, not row uuids — so the receipt prints it. A bare "ok" here
		// forced a second call just to learn the handle the next command needs.
		// Skipped when the payload ALSO carries a list envelope: project-ls
		// returns {"workspace":{…},"projects":[…]} — the user wants the projects
		// listed, not the workspace-context slug echoed back.
		if _, hasList := envelopeRows(m); !hasList {
			for _, k := range []string{"workspace", "project"} {
				if obj, ok := m[k].(map[string]any); ok {
					if slug, ok := obj["slug"].(string); ok && slug != "" {
						out.outf("%s: %s", k, slug)
						return
					}
				}
			}
		}
	}
	// An outcome-bearing receipt is printed BEFORE the generic id/rev harvest,
	// because that harvest cannot see an outcome: it collects ids and a rev, and
	// prints a bare "ok" when it finds neither. On the writes whose body reports
	// what actually happened, that is the difference between a receipt and a
	// lie. The rev still prints below it — a doc delete's rev is worth keeping.
	if m, isMap := v.(map[string]any); isMap {
		if line := outcomeReceiptLine(m); line != "" {
			out.outf("%s", line)
			if rev := findRev(v); rev != "" {
				out.outf("rev: %s", rev)
			}
			return
		}
	}
	ids := collectIDs(v)
	rev := findRev(v)
	if rev != "" {
		out.outf("rev: %s", rev)
	}
	for _, id := range ids {
		out.outf("id: %s", id)
	}
	if rev == "" && len(ids) == 0 {
		out.outf("ok")
	}
}

// outcomeKeys are the receipt fields that name WHAT A WRITE DID, in the order
// they are consulted. The API uses each of them in three different value
// shapes, and the shape decides how the line reads: a NUMBER is a tally
// (`share rm` -> {"removed": 2}), a STRING is the thing itself (`schema delete`
// -> {"deleted": "Post"}), an OBJECT is the row that was affected (`token
// revoke` -> {"revoked": {id, label, revoked_at}}).
var outcomeKeys = []string{
	"removed", "deleted", "revoked", "updated", "purged",
	"affected", "applied", "cleared", "pruned",
}

// receiptIdentKeys are the fields that identify a row inside an outcome object,
// most specific first. It is deliberately wider than collectIDs' list: that one
// is tuned for document and list rows, and the admin receipts key their subject
// differently — a removed workspace seat carries principal_id/identity and no
// "id" at all, which is why `bp workspace member-rm` printed a bare "ok".
var receiptIdentKeys = []string{
	"_id", "doc_id", "id", "principal_id", "identity", "email",
	"label", "name", "slug", "scope",
}

// failedStatuses are the verdict tokens that mean the operation a receipt
// describes did NOT succeed, even though the HTTP call did.
var failedStatuses = map[string]bool{
	"failed": true, "failure": true, "error": true, "dead": true, "refused": true,
}

// outcomeReceiptLine renders the one line that says what a write actually did,
// or "" when the payload carries no such field and the generic id/rev receipt
// is the right answer.
//
// renderMinimal harvests ids and a rev and prints "ok" when it finds neither,
// so a field that reports the OUTCOME is invisible to it. Measured against the
// server's real bodies, eight receipts across SEVEN bp verbs lost the only
// field that said what happened — and three printed a different identifier in
// its place, which reads as confirmation of something that did not occur:
//
//	verb                 server said              printed        now
//	share rm             removed: 0               id: <scope>    removed: 0 (<scope>)
//	share rm             removed: 2               id: <scope>    removed: 2 (<scope>)
//	media delete         deleted: <asset id>      ok             deleted: <asset id>
//	webhook delete       deleted: <id>            id: <name>     deleted: <id>
//	schema delete        deleted: <name>          id: <row uuid> deleted: <name>
//	workspace member-rm  removed: {seat}          ok             removed: <principal>
//	token revoke         revoked: {id,label,…}    ok             revoked: <id>
//	webhook test-send    delivery.status: failed  ok             delivery: failed: …
//
// `bp doc delete` is deliberately NOT in that list, though an earlier draft of
// this comment claimed it: doc.delete rides POST /v1/data/mutate/:dataset with
// mutation_op "delete" and gets the mutate envelope, not the flat
// {deleted, type, rev} body legacy_controller returns. That flat shape is still
// rendered correctly below — the rev prints beneath the outcome line — but no
// bp verb produces it today, so it is COVERED, not FIXED.
//
// Two are worth naming. `share rm` printed a BYTE-IDENTICAL receipt for "two
// shares revoked" and "nothing was revoked", both at exit 0 — on a revocation
// verb, that is the failure mode that matters: you walk away believing access
// is gone. And `bp token revoke`, the verb you reach for when a credential has
// leaked, answered "ok" without ever echoing the revoked_at the server returned.
//
// `bp webhook test-send` is the odd one: the controller returns HTTP 200 with
// the delivery VERDICT in the body by design (webhook_controller.test_send/2
// says so), so an endpoint that refused the connection produced a 200, and the
// nested verdict was invisible to the top-level id harvest. A command whose
// whole purpose is to tell you whether an endpoint works answered "ok" for one
// that had just failed.
//
// NOTE ON THE EXIT CODE, deliberately unchanged: a failed test delivery still
// exits 0. The exit ladder is keyed on the error envelope's `code` and this is
// a 2xx, so renumbering it is a change to the contract spine rather than a
// rendering fix, and it belongs to whoever owns that table. This removes the
// false statement; it does not touch the ladder.
func outcomeReceiptLine(m map[string]any) string {
	// A DOCUMENT is not a receipt. Envelope.render (api) flattens a document's
	// content fields to the top level, so `bp doc get <type> <id> -q` can hand
	// this function a payload whose own author-controlled field happens to be
	// called `updated` or `removed` — and a numeric one would then be printed as
	// this write's outcome, replacing the id the -q receipt exists to give. The
	// "_id" guard is the same one envelopeRows uses in table.go, for the same
	// reason: only a wrapper envelope is a receipt.
	if _, isDoc := m["_id"]; isDoc {
		return ""
	}

	for _, k := range outcomeKeys {
		switch val := m[k].(type) {
		case float64:
			// A tally. The scope rides along because it is what the caller asked
			// about, and `removed: 0` alone does not say 0 of what.
			if scope, ok := m["scope"].(string); ok && scope != "" {
				return fmt.Sprintf("%s: %d (%s)", k, int64(val), scope)
			}
			return fmt.Sprintf("%s: %d", k, int64(val))
		case string:
			if val != "" {
				return fmt.Sprintf("%s: %s", k, val)
			}
		case map[string]any:
			// The affected row. Falls through to the old receipt when the object
			// carries nothing that identifies it — never replace a receipt with a
			// worse one.
			if id := receiptIdent(val); id != "" {
				return fmt.Sprintf("%s: %s", k, id)
			}
		}
	}

	// A nested verdict object one level down, carrying a string "status". Only a
	// FAILING status is surfaced: a succeeding one is already consistent with
	// what the caller was told, and hijacking that receipt would trade
	// information for noise.
	for _, k := range sortedKeys(m) {
		obj, isObj := m[k].(map[string]any)
		if !isObj {
			continue
		}
		status, _ := obj["status"].(string)
		if status == "" || !failedStatuses[strings.ToLower(status)] {
			continue
		}
		line := fmt.Sprintf("%s: %s", k, status)
		if code, ok := obj["last_status_code"].(float64); ok {
			line += fmt.Sprintf(" (HTTP %d)", int64(code))
		}
		if txt, ok := obj["last_error_text"].(string); ok && txt != "" {
			line += ": " + txt
		}
		return line
	}
	return ""
}

// receiptIdent returns the field that identifies the row an outcome object
// describes, or "" when the object carries none.
func receiptIdent(obj map[string]any) string {
	for _, k := range receiptIdentKeys {
		if s, ok := obj[k].(string); ok && s != "" {
			return s
		}
	}
	return ""
}

// docReceiptLine renders the one-line minimal receipt for a single returned
// doc object: its doc_id (falling back to _id / id), plus the fencing epoch
// when the doc carries a claim, plus the doc's rev when present — e.g.
// "<doc_id> epoch=<n> rev=<rev>". The rev is what a close pins to fence its
// write, so a claim receipt that carries one echoes it. Returns "" when no id
// is found, so the caller falls through to the generic rev/ids receipt.
func docReceiptLine(doc map[string]any) string {
	id := ""
	for _, k := range []string{"doc_id", "_id", "id"} {
		if s, ok := doc[k].(string); ok && s != "" {
			id = s
			break
		}
	}
	if id == "" {
		return ""
	}
	line := id
	if claim, ok := doc["claim"].(map[string]any); ok {
		// JSON numbers decode to float64; the epoch is an integer by contract
		// (content.claim.epoch, bumped on every claim).
		if e, ok := claim["epoch"].(float64); ok {
			line += fmt.Sprintf(" epoch=%d", int64(e))
		}
	}
	// Rev rides the top-level doc object (render_doc emits "rev"; older/other
	// shapes may use "_rev"). Shape-keyed only — appended whenever the claim-
	// style doc carries one, no verb-specific logic.
	if rev := scalarString(doc["rev"], doc["_rev"]); rev != "" {
		line += " rev=" + rev
	}
	return line
}

// scalarString returns the first argument that renders as a non-empty scalar
// (string or JSON number), formatted as a string. Used so a rev decoded as
// either a hex string or a bare number both print cleanly.
func scalarString(vals ...any) string {
	for _, v := range vals {
		switch t := v.(type) {
		case string:
			if t != "" {
				return t
			}
		case float64:
			return strconv.FormatInt(int64(t), 10)
		}
	}
	return ""
}

func findRev(v any) string {
	switch t := v.(type) {
	case map[string]any:
		for _, k := range []string{"_rev", "rev", "transactionId", "results"} {
			if val, ok := t[k]; ok {
				if s, ok := val.(string); ok {
					return s
				}
			}
		}
	}
	return ""
}

func collectIDs(v any) []string {
	var ids []string
	switch t := v.(type) {
	case map[string]any:
		// ONE id per object, first match wins: _id (documents), doc_id (task
		// rows — their "id" is the row uuid, but every task verb takes the
		// doc_id), then id (media assets). The name/scope fallbacks cover the
		// admin list rows that carry no id at all — schema.ls / plugin.ls rows
		// are keyed by "name", share.ls rows by "scope". Without them those
		// commands printed a bare "ok" under -o minimal (zero information).
		// Order matters: id-bearing rows (docs/tasks/media/workspaces/projects)
		// match before the fallbacks, so their output is unchanged.
		// Appending every present key printed two lines per task row.
		for _, k := range []string{"_id", "doc_id", "id", "from_doc_id", "name", "scope"} {
			if val, ok := t[k]; ok {
				if s, ok := val.(string); ok && s != "" {
					ids = append(ids, s)
					break
				}
			}
		}
		if rows, ok := envelopeRows(t); ok {
			for _, d := range rows {
				ids = append(ids, collectIDs(d)...)
			}
		}
	case []any:
		for _, item := range t {
			ids = append(ids, collectIDs(item)...)
		}
	}
	return ids
}

// runPaginatedAll fetches every offset page of a paginated read and prints the
// concatenated documents in the resolved output shape.
func runPaginatedAll(out *writer, cmd manifest.Command, baseURL string, headers map[string]string) int {
	const pageSize = 100
	offset := 0
	var all []json.RawMessage
	seenFullPages := map[string]int{}
	// Detected on page 1, then held for every page and the final re-wrap so the
	// renderer sees the envelope shape the command emits (docs/hits/… not just
	// documents). Empty until the first page is extracted.
	key := ""
	for {
		pageURL := withOffsetLimit(baseURL, offset, pageSize)
		status, respBody, err := doRequest(cmd.HTTP.Method, pageURL, headers, nil)
		if err != nil {
			if !renderErrorEnvelope(out, "request_failed", "request failed: "+err.Error(), "", "") {
				out.userErr("request failed: %v", err)
			}
			return exitGeneric
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, respBody)
			renderError(out, ae)
			return ae.exit
		}
		docs, k := extractListRows(unwrapResult(respBody))
		// PDS wave 27 — the reader half of the epic's law. extractListRows
		// returns the "" sentinel for ANY body it cannot read as a list
		// envelope, and an HTTP 200 is no proof the body came from Barkpark: a
		// proxy 502 interstitial, a truncated write, `null`, `{}`, a bare array
		// and plaintext all arrive at 200. This clause REVERSES the previous
		// fallback (`if key == "" { key = "documents" }`), which laundered every
		// one of those into a well-formed EMPTY SUCCESS envelope byte-identical
		// to a genuinely empty queue — a reader lying to the worker who most
		// needs the truth. Refuse PER PAGE (page 5 of a walk is as unreadable as
		// page 1) with a named code, never a bare exit.
		if k == "" {
			msg := fmt.Sprintf(
				"unreadable list page at offset %d: HTTP %d carried no known list envelope (%d bytes): %s",
				offset, status, len(respBody), bodyPreview(respBody),
			)
			refuseWithRemedy(out, "unreadable_list_page", msg, unreadableListPageHint)
			return exitGeneric
		}
		if key == "" {
			key = k
		}
		if len(docs) == pageSize {
			identity := paginatedPageIdentity(docs)
			if firstOffset, seen := seenFullPages[identity]; seen {
				msg := fmt.Sprintf("pagination stalled at offset %d: full page repeats offset %d", offset, firstOffset)
				if !renderErrorEnvelope(out, "pagination_stalled", msg, "", "") {
					out.userErr("%s", msg)
				}
				return exitGeneric
			}
			seenFullPages[identity] = offset
		}
		all = append(all, docs...)
		if len(docs) < pageSize {
			// A walk that never advanced past page one has the server's OWN
			// envelope in hand — render it VERBATIM, exactly as the non---all
			// path would. The re-wrap below marshals a nil []json.RawMessage as
			// JSON null and drops every sibling field (`count` first among
			// them), so `--all` over an honest empty queue printed
			// {"documents":null} — a corrupted twin of the {"count":0,
			// "documents":[]} the server sent, breaking `jq '.documents[]'` on
			// exactly the emptiest page (pds-w27-bl-task-next-and-all-corrupt-
			// the-honest-shape). Multi-page walks keep the re-wrap: a stitched
			// result has no single server body to pass through.
			if offset == 0 {
				renderSuccess(out, cmd, respBody)
				return exitOK
			}
			break
		}
		offset += pageSize
	}

	// key is always set here: the loop runs at least once and refuses (above)
	// any page it could not read a key from, so an unknown envelope can no
	// longer reach the success renderer.
	wrapped, _ := json.Marshal(map[string]any{key: json.RawMessage(mustArray(all))})
	renderSuccess(out, cmd, mustResult(wrapped))
	return exitOK
}

func paginatedPageIdentity(rows []json.RawMessage) string {
	hash := sha256.New()
	var length [8]byte
	for _, row := range rows {
		binary.BigEndian.PutUint64(length[:], uint64(len(row)))
		_, _ = hash.Write(length[:])
		_, _ = hash.Write(row)
	}
	return string(hash.Sum(nil))
}

func withOffsetLimit(rawURL string, offset, limit int) string {
	sep := "?"
	if strings.Contains(rawURL, "?") {
		// Replace existing offset/limit by appending — last value wins on the server.
		sep = "&"
	}
	return fmt.Sprintf("%s%soffset=%d&limit=%d", rawURL, sep, offset, limit)
}

// extractListRows pulls the row array out of a list envelope, trying the known
// envelope keys (table.go's listEnvelopeKeys) in order. It returns the rows and
// the matched key; the first key whose value is a JSON array wins — an EMPTY
// array still counts as a match so key detection works on an empty first page.
// key is "" when the payload carries no known list envelope.
func extractListRows(payload []byte) ([]json.RawMessage, string) {
	var env map[string]json.RawMessage
	if json.Unmarshal(payload, &env) != nil {
		return nil, ""
	}
	for _, k := range listEnvelopeKeys {
		raw, ok := env[k]
		if !ok {
			continue
		}
		var rows []json.RawMessage
		if json.Unmarshal(raw, &rows) == nil {
			return rows, k
		}
	}
	return nil, ""
}

// bodyPreview renders a short, single-line, printable excerpt of a response
// body for the unreadable_list_page message — enough to tell a proxy HTML page
// from `null` from empty bytes without dumping an arbitrary payload into the
// error envelope.
func bodyPreview(body []byte) string {
	const max = 120
	if len(body) == 0 {
		return "<empty body>"
	}
	// Truncate on a RUNE boundary: a body cut mid-sequence would render as
	// U+FFFD noise in the very message meant to help identify it.
	s := string(body)
	if len(s) > max {
		cut := max
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut] + "…"
	}
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return '.'
		}
		return r
	}, s)
	return strings.TrimSpace(s)
}

// mustArray marshals rows for the multi-page re-wrap. A nil slice would render
// as JSON null — the empty-page corruption the single-page pass-through above
// exists to prevent — so it is pinned to []. (Multi-page walks always carry
// rows today; this is the belt to that suspender.)
func mustArray(items []json.RawMessage) []byte {
	if items == nil {
		items = []json.RawMessage{}
	}
	b, _ := json.Marshal(items)
	return b
}

func mustResult(inner []byte) []byte {
	b, _ := json.Marshal(map[string]json.RawMessage{"result": inner})
	return b
}

// warnDroppedPagination names the pagination knobs the caller set that this
// command cannot carry, instead of dropping them in silence.
//
// applyQuery forwards --limit/--offset only when the command is `paginated` or
// declares the flag itself (the DECLARATION rule, documented at its call site
// with the six live commands that motivated it). What it has never done is SAY
// so. The result is the sharpest lie a read can tell: `bp token ls --limit 5`
// exits 0 having asked for, and printed, the server's whole unpaginated
// inventory — the caller reads a page it did not ask for as the page it did.
// `bp workspace member-ls --offset 50` is the same shape; both list every seat
// or credential in the workspace, which is exactly where a silent truncation
// (or a silent NON-truncation the caller believes is a page) misleads most.
//
// THIS REFUSES. It used to warn, and the reversal is deliberate and owned —
// see the note below, because the code must not carry a rationale it no longer
// follows.
//
// THE OLD RATIONALE, VERBATIM, SO THE REVERSAL IS LEGIBLE: "This warns rather
// than refuses on purpose: the request is still correct and still answers the
// question, and refusing would break every existing script that passes a
// harmless global." That reasoning rested on a caller population that could be
// enumerated. It cannot: a repo-wide sweep finds ZERO
// `bp … --all/--limit/--offset` invocations in scripts/ or .github/, and the
// callers that actually pass these flags are AGENTS, which live outside this
// repo entirely. An enumeration that returns zero because it cannot see the
// callers is not evidence of safety.
//
// So the register flips to the #13620 precedent — refuse a knob you cannot
// honour — on the ground that a flag honoured in APPEARANCE and discarded in
// FACT is the same class of defect as every other silent drop: the caller
// believes it asked for something it did not get, and nothing on any channel
// contradicts them. A refusal is loud and recoverable; a silent drop is
// neither. THIS IS A BEHAVIOUR BREAK for any caller that sprinkles --all across
// mixed verbs, and it is meant to be trivially reversible: delete the two
// `refused` returns and restore out.errf to get the notice back.
//
// WHAT WAS ACTUALLY SILENT, measured against the live manifest before the
// change (bp doc get post p1 --dry-run, BOTH channels captured — capturing
// stdout alone is what made all three look silent):
//
//	--limit 7    stderr: note: --limit ignored — `doc get` does not accept …
//	--offset 5   stderr: note: --offset ignored — `doc get` does not accept …
//	--all        stderr: (nothing)
//
// --all is honoured by exactly one branch of runCommand — `cmd.Paginated &&
// g.all && !cmd.Writes` — so a paginated WRITE swallows it too, not just the
// non-paginated reads the limit/offset arm covers. Hence the separate
// condition: that arm is keyed on how --all is actually CONSUMED, not on
// cmd.Paginated alone.
func refuseDroppedKnobs(out *writer, g globals, cmd manifest.Command) (int, bool) {
	// --all rides only the paginated-READ walk; a write or a non-paginated
	// command drops it.
	if g.all && (!cmd.Paginated || cmd.Writes) {
		what := "does not paginate"
		if cmd.Writes {
			what = "is a write, and a write is never paginated"
		}
		return useError(out, "usage", fmt.Sprintf(
			"--all cannot be honoured: `%s %s` %s. Nothing was sent. Re-run without --all — the answer is a single result, not a walked collection.",
			cmd.Noun, cmd.Verb, what,
		), exitUsage), true
	}

	if cmd.Paginated {
		return 0, false
	}
	var dropped []string
	if g.limitSet && !commandDeclaresFlag(cmd, "limit") {
		dropped = append(dropped, "--limit")
	}
	if g.offsetSet && !commandDeclaresFlag(cmd, "offset") {
		dropped = append(dropped, "--offset")
	}
	if len(dropped) == 0 {
		return 0, false
	}
	return useError(out, "usage", fmt.Sprintf(
		"%s cannot be honoured: `%s %s` does not accept pagination. Nothing was sent. Re-run without %s — the answer is the server's full result, not a page.",
		strings.Join(dropped, " and "), cmd.Noun, cmd.Verb, strings.Join(dropped, " or "),
	), exitUsage), true
}

// confirmProdWrite prompts on stderr and reads a [y/N] answer from stdin.
func confirmProdWrite(out *writer, cmd manifest.Command, ctx manifest.Context) bool {
	// Gate on the ANSWER stream (stdin) and the PROMPT stream (stderr) — the two
	// streams this prompt actually uses — deliberately NOT stdout. That keeps
	// `bp … -o json > file` interactive: redirecting the JSON receipt leaves the
	// operator at a terminal that can still answer. (uninstall_cmd.go gates on
	// stdout because its prompt is on stdout; ours is on stderr, so we diverge.)
	// Non-TTY stdin (CI, piped, `echo | bp …`) can't answer the prompt: ReadString
	// hits EOF, the answer is empty, and the caller's "aborted" message never names
	// the flag that unblocks it. Name --yes here instead.
	if !(isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stderr.Fd())) {
		out.userErr("prod write to %s needs confirmation — re-run with --yes", ctx.Server)
		return false
	}
	fmt.Fprintf(out.stderr, "⚠ PROD: %s %s writes to %s. Continue? [y/N] ", cmd.Noun, cmd.Verb, ctx.Server)
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	return line == "y" || line == "yes"
}

// isLocalHost is THE pinned classifier for the prod write-guard: true only
// when server dials a provably-loopback target, decided by EXACT host (hostOf)
// — never substring. Both guard twins (isProd here, isProdServer in
// tasks_create_cmd.go) collapse onto it; there must never be a second copy.
//
// EXACT-HOST (onb-backlog-isprod-localhost-substring-corner): the previous
// shape substring-matched "localhost"/"127.0.0.1"/"0.0.0.0" anywhere in the
// URL, so a hostile hostname that merely EMBEDS a local token
// (localhost.evil.com, my-127.0.0.1.attacker.net) classified local and
// skipped the destructive-write confirm — the last fail-open escape after the
// #12033 fail-closed flip. Now the host is parsed out, lowercased, ONE
// trailing dot stripped (DNS root form), and matched exactly:
// {localhost, 0.0.0.0, ::1, [::1]} ∪ IPv4 127.0.0.0/8 (covers Debian's
// 127.0.1.1). Empty/unparseable → NOT local (the guard fails closed).
//
// Deliberately NARROWER than ServerKind (config.go), which is a UX classifier:
// RFC1918 LAN ranges, *.local mDNS names, and *.localhost stay PROD here —
// those dial OTHER machines (or resolver-dependent names), and a false prompt
// is the safe failure; --yes and /v1/meta production:false are the sanctioned
// exits. Do NOT "unify" the two — the divergence pin test in
// isprod_localhost_test.go reds if someone tries.
func isLocalHost(server string) bool {
	host := strings.ToLower(hostOf(server))
	host = strings.TrimSuffix(host, ".")
	if host == "" {
		return false // fail closed: no provable host means PROD
	}
	switch host {
	case "localhost", "0.0.0.0", "::1", "[::1]":
		return true
	}
	if isIPv4(host) {
		return atoiByte(strings.Split(host, ".")[0]) == 127 // loopback 127.0.0.0/8
	}
	return false
}

// isProd decides whether the target is production via a name/url heuristic on
// the manifest's server identity and the dialed server URL.
//
// FAIL CLOSED (onb-backlog-isprod-custom-host-write-confirm): the old shape
// defaulted to non-prod unless the host matched a substring allowlist
// (api.barkpark.cloud / "prod"), so a custom production hostname like
// cms.gyldendal.no skipped the destructive-write confirm entirely — and every
// live fleet host emits the generic server.name "barkpark", so the name leg
// caught no real prod either. Now any host that is not provably local IS prod:
// localhost/loopback/0.0.0.0 stay unprompted, everything else confirms. The
// two ways out are --yes (the sole client-side bypass — no env carve-out) and
// the server itself advertising production:false on /v1/meta
// (serverDeclaredNonProd — consulted by the write-guard call sites, not here,
// so this stays a pure offline heuristic that whoami can always evaluate).
//
// Classification reads ctx.Server ALONE (D35): m.Server.BaseURL is the
// server's own echo of the dialed host — display-only elsewhere — and letting
// it into the classifier handed the server a guard-suppression channel (a
// manifest base_url containing "localhost" masked a non-local ctx.Server).
// The name leg below only ever ADDS prod, so a server can tighten the guard
// on itself but never loosen it.
func isProd(ctx manifest.Context, m *manifest.Manifest) bool {
	name := strings.ToLower(m.Server.Name)
	if name == "prod" || name == "production" {
		return true
	}
	return !isLocalHost(ctx.Server)
}

// dryRun prints the resolved method/path/headers(redacted)/body and exits 0
// WITHOUT calling (M0 decision A1). Since the manifest's dry_run is false in v1,
// it announces the client-side-preview degradation.
func dryRun(out *writer, cmd manifest.Command, rawURL string, headers map[string]string, body []byte) int {
	out.errf("dry-run: client-side preview only (server validate-only not available)")
	redacted := redactHeaders(headers)

	// Machine-readable modes emit the preview as a structured document so a
	// `--dry-run -o json | jq` pipe stays parseable. The stderr notice above is
	// off-stdout and does not pollute it.
	if out.output == "json" || out.output == "yaml" {
		// The YAML emitter only recurses into map[string]any, so widen the
		// redacted header map (JSON handles either shape).
		hdrs := make(map[string]any, len(redacted))
		for k, v := range redacted {
			hdrs[k] = v
		}
		payload := map[string]any{
			"method":  cmd.HTTP.Method,
			"url":     rawURL,
			"headers": hdrs,
		}
		if len(body) > 0 {
			var parsed any
			if json.Unmarshal(body, &parsed) == nil {
				payload["body"] = parsed
			} else {
				payload["body"] = string(body)
			}
		}
		if out.output == "json" {
			out.renderJSON(payload)
		} else {
			out.renderYAML(payload)
		}
		return exitOK
	}

	out.outf("%s %s", cmd.HTTP.Method, rawURL)
	keys := make([]string, 0, len(redacted))
	for k := range redacted {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out.outf("%s: %s", k, redacted[k])
	}
	if len(body) > 0 {
		out.outf("")
		out.outf("%s", string(body))
	}
	return exitOK
}

// redactHeaders masks credential header values so a dry-run never prints a token.
func redactHeaders(h map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range h {
		lk := strings.ToLower(k)
		if lk == "authorization" || strings.Contains(lk, "secret") || strings.Contains(lk, "token") {
			out[k] = redact(v)
		} else {
			out[k] = v
		}
	}
	return out
}

func redact(v string) string {
	if strings.HasPrefix(v, "Bearer ") {
		return "Bearer ****"
	}
	return "****"
}
