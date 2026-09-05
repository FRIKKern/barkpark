package cloudclient

// selfupdate.go is the client half of `bp cloud update <instance>` — the TRIGGER
// verb the console has promised for a whole epic (cloud/priv/static/app.js renders
// cliChipHtml("bp cloud update " + instance)) with no backing code behind it.
//
// It POSTs the control plane's admin-gated self-update relay
// (POST /v1/barkparks/:id/self-update, cloud/lib/barkpark_cloud/web/router.ex:3816).
// The control plane relays POST /v1/admin/self-update to the box server-side with
// the STORED admin token (the token never reaches this client) and RELAYS the
// instance's verdict with its semantics intact — so every outcome this file
// surfaces is the SERVER's, never a locally-invented success.
//
// It is the sibling of Rollback (client.go): the same envelope-is-the-contract
// discipline (Raw retained verbatim for `-o json`), the same typed-refusal shape,
// and it DELIBERATELY reuses decodeRollbackError rather than minting a third
// error decoder — the route emits the same two shapes (the relay's nested
// {"error":{"code","detail"}} and the top-level guard's flat {"error":"..."}),
// so one decoder must serve both or they drift.
//
// The ONE thing self-update carries that rollback does not is the PIN. A pinned
// box refuses an unforced trigger with 409 {"error":{"code":"pinned",
// "pinned_release":"…"}} (isu-w5.2 pin honesty — a pinned box is FROZEN, and a
// silent no-op would be a lie). `force: true` in the request body overrides the
// pin for that one run, which is exactly the console's "Update anyway" button.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// SelfUpdateResult is a STARTED self-update run. Raw is the 202 envelope BYTES
// verbatim so `-o json` re-emits the control plane's contract without reshaping
// (the rollback/verify idiom — the envelope IS the contract, and this client must
// never become a second, drifting definition of it). The scalars are POINTERS on
// purpose: a leaner/older control plane that omits one decodes to nil (an honest
// "not reported"), never a fabricated value the CLI would then print as fact.
type SelfUpdateResult struct {
	Raw    []byte  `json:"-"`
	OK     *bool   `json:"ok"`
	Status *string `json:"status"`
}

// SelfUpdateError is a self-update the control plane REFUSED — a typed contract
// code the CLI maps onto one human sentence and a stable exit. HTTPStatus drives
// the exit FAMILY (the shared rollback ladder: 409 → conflict, 404 → not-found,
// 5xx → server, auth → auth); Code is the specific refusal; Detail is the
// server's optional elaboration; Reason is the CAUSE an authority gate named
// ("no_team") when the code itself is the generic "forbidden".
//
// PinnedRelease is the pin the 409 named — the release the box is FROZEN at. It
// is the one field rollback's refusal has no analogue for, and it is what lets
// the CLI say WHICH version holds the box instead of "it is pinned, somehow".
// Empty when the refusal named no pin.
//
// A 401 is deliberately NOT a SelfUpdateError — it stays a cloudError so it keeps
// the "unauthorized:" prefix contract cloudFail keys on.
type SelfUpdateError struct {
	HTTPStatus    int
	Code          string
	Detail        string
	Reason        string
	PinnedRelease string
}

func (e *SelfUpdateError) Error() string {
	if e.Detail != "" {
		return e.Code + ": " + e.Detail
	}
	return e.Code
}

// TriggerSelfUpdate asks the control plane to start an in-place self-update run on
// ONE managed instance via POST /v1/barkparks/:id/self-update (Bearer,
// team-admin-gated). force overrides a PIN for that one run (and only a pin — it
// is not a general override: already_running, not_enabled and not_live refuse a
// forced call exactly as they refuse an unforced one).
//
// A 202 is a STARTED run, not a finished one. A contract refusal surfaces as
// *SelfUpdateError; a 401 (and anything else outside the contract) via cloudError
// so auth handling stays shared with every other cloud verb.
func (c *Client) TriggerSelfUpdate(ctx context.Context, id string, force bool) (SelfUpdateResult, error) {
	// The relay is SYNCHRONOUS on the box's own admin endpoint (the control plane
	// waits for the instance's verdict before it answers), so give it the same
	// headroom past DefaultTimeout as Rollback/VerifyInstance. An injected HTTP
	// client (tests) is honored untouched; only the lazily-built fallback is widened.
	rc := *c
	if rc.HTTP == nil {
		rc.HTTP = &http.Client{Timeout: VerifyTimeout}
	}
	// The body rides ONLY on a forced call. The route reads
	// `conn.body_params["force"] == true`, so an absent body and {"force":false}
	// mean the same thing to the server — and sending nothing keeps the default
	// request byte-identical to every other unforced trigger.
	var body any
	if force {
		body = map[string]bool{"force": true}
	}
	status, raw, err := rc.do(ctx, "POST", "/v1/barkparks/"+esc(id)+"/self-update", true, body)
	if err != nil {
		return SelfUpdateResult{}, err
	}
	if !ok(status) {
		if status == http.StatusUnauthorized {
			return SelfUpdateResult{}, cloudError(status, raw)
		}
		if code, detail, reason := decodeRollbackError(raw); code != "" {
			return SelfUpdateResult{}, &SelfUpdateError{
				HTTPStatus:    status,
				Code:          code,
				Detail:        detail,
				Reason:        reason,
				PinnedRelease: decodeSelfUpdatePin(raw),
			}
		}
		return SelfUpdateResult{}, cloudError(status, raw)
	}
	res := SelfUpdateResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return SelfUpdateResult{}, fmt.Errorf("decode self-update envelope: %w", err)
	}
	return res, nil
}

// decodeSelfUpdatePin reads the pinned release off a refusal body. It is NOT a
// third error decoder — the code/detail/reason triple still comes from
// decodeRollbackError — it is ONE extra field, read in its OWN Unmarshal exactly
// as that decoder reads `reason` in its own, so a route sending the field as an
// unexpected shape costs that field alone and never the code decode that drives
// the whole refusal path.
//
// Both positions the field is known to ride are read, in the same order the
// console's updateConflict() reads them (app.js): inside the error object first
// (the shape the shipped route emits), then at the envelope top level. A body
// naming no pin yields "" — the honest "not reported", so the caller can pick its
// no-pin wording instead of printing an empty version.
func decodeSelfUpdatePin(body []byte) string {
	var env struct {
		Error         json.RawMessage `json:"error"`
		PinnedRelease string          `json:"pinned_release"`
	}
	if json.Unmarshal(body, &env) != nil {
		return ""
	}
	if len(env.Error) > 0 {
		var obj struct {
			PinnedRelease string `json:"pinned_release"`
		}
		if json.Unmarshal(env.Error, &obj) == nil && strings.TrimSpace(obj.PinnedRelease) != "" {
			return strings.TrimSpace(obj.PinnedRelease)
		}
	}
	return strings.TrimSpace(env.PinnedRelease)
}
