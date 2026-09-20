package cloudclient

// site_build_log.go is the client half of the TEAM read path for the black box
// recorder: GET /v1/sites/:id/deployments/:dep_id/build-log, added by
// dr-bl-recorder-http-read-path (cloud PR #16847, merged 2026-09-08) and
// re-pointed at the team door by dr-w19-site-build-log-is-operator-only (cloud
// PR #17693, merged 2026-09-11) — see SiteBuildLog below for the live audience.
//
// WHY THIS ROUTE DOES NOT GO THROUGH cloudError FOR EVERY NON-2xx. The whole
// point of `BarkparkCloud.Sites.BuildLog` is that its answers are separated BY
// STATUS CODE so a client reading nothing but the status cannot conflate them:
//
//	200  the box answered definitively — `log_state` says which definite answer
//	     (available | missing | never_recorded), or the deployment predates
//	     build-keyed recording (build_id null, log_state never_recorded)
//	404  no such deployment, or not this site's
//	409  box_unbound — the site has no instance row, so no box can be asked
//	410  build_log_evicted — a tombstone says the bytes were reclaimed
//	502  box_unreachable — we could not ask, or the box answered with a
//	     `log_state` this control plane does not understand (`box_log_state`)
//
// Four of those five are non-2xx and every one of them is INFORMATION, carrying
// the deployment id, the build id and (for 410) the whole record. Collapsing
// them into a bare *CloudRefusal would throw away exactly the distinctions the
// server went out of its way to make. So the documented set decodes into a
// record that carries its own HTTPStatus, and only the UNdocumented statuses —
// notably the 401 an unauthenticated caller gets and the 403 a PAT without the
// "read" ability gets (`Auth.require_ability/2`) — take the normal refusal path,
// where the auth ladder can still read them. A FOREIGN team is deliberately NOT
// in that set: it is a documented 404, indistinguishable from a deployment that
// does not exist.
//
// THE BYTES ARE NOT HERE. The control plane cannot serve the recorded log bytes
// (the box refuses them: the build env file carries BARKPARK_TOKEN= in
// plaintext), so this struct has no log-content field and never will until a
// scrub-at-write slice lands on the box. LogPath / LogBytes / JournalCommand
// NAME where the bytes are; they are not the bytes.

import (
	"context"
	"encoding/json"
	"fmt"
)

// SiteBuildLogStage is one stage row of the recorder's terminal record
// (`decode_record_stage/1` on the box). Only name+status are decoded: this end
// renders a stage ladder, not the box's whole internal shape.
type SiteBuildLogStage struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

// SiteBuildLogRecord is the build-log answer for ONE deployment, whatever the
// answer was. HTTPStatus is the discriminator — never a field — because the
// server made the status the discriminator on purpose.
//
// LogBytes and ExitCode are POINTERS: the box sends explicit nulls for both on a
// record it never wrote, and a plain int would decode those as 0 — a byte count
// of zero and a clean exit are both meaningful values that must never be
// invented for an absent one.
type SiteBuildLogRecord struct {
	// HTTPStatus is the status the control plane answered with. Not a wire
	// field — set by the client after the response is read.
	HTTPStatus int `json:"-"`

	DeploymentID string `json:"deployment_id"`
	BuildID      string `json:"build_id"`
	Slug         string `json:"slug"`

	// LogState is relayed VERBATIM, never mapped onto a CLI vocabulary. The
	// recorder owns five states (available, evicted, missing, never_recorded,
	// unknown) and the honest render is the word the recorder used.
	LogState  string `json:"log_state"`
	Available bool   `json:"available"`
	Record    string `json:"record"`

	// Error/Detail carry the refusal shape the non-200 answers use.
	Error  string `json:"error"`
	Detail string `json:"detail"`
	Reason string `json:"reason"`

	// BoxLogState is the word the BOX sent when the control plane did not
	// recognise it (the 502 branch of BuildLog.decide/2). It is the only place
	// `unknown` reaches a client, and it reaches it as itself.
	BoxLogState string `json:"box_log_state"`
	BoxStatus   int    `json:"box_status"`

	// BoxError is the box's OWN refusal, and it is deliberately not a string.
	// The producer's box_error/1 emits either a slug or the standard error
	// envelope (a map of code/hint/message/request_id) through this one key; a
	// scalar here failed the WHOLE record decode on the envelope shape and
	// killed every branch below it. See box_error.go for the measurement.
	BoxError BoxError `json:"box_error"`

	// THE SIBLING KEYS, DERIVED FROM THE REDUCER. `BoxErrorEnvelope.fields/1`
	// ALWAYS returns three keys, not one: it REDUCES the box's error envelope
	// so `box_error` stays the string it is typed as, and routes the two facts
	// that actually route an incident — the box's own message and request_id —
	// to keys of their own. A struct that declares only `box_error` reads both
	// as "" forever, and json.Unmarshal says nothing about it.
	BoxErrorMessage   string `json:"box_error_message"`
	BoxErrorRequestID string `json:"box_error_request_id"`

	LogPath        string              `json:"log_path"`
	LogBytes       *int64              `json:"log_bytes"`
	ExitCode       *int                `json:"exit_code"`
	FailureReason  string              `json:"failure_reason"`
	Stages         []SiteBuildLogStage `json:"stages"`
	UnitName       string              `json:"unit_name"`
	JournalCommand string              `json:"journal_command"`
	Mode           string              `json:"mode"`
	RuntimeTarget  string              `json:"runtime_target"`
	StartedAt      string              `json:"started_at"`
	FinishedAt     string              `json:"finished_at"`
	EvictedAt      string              `json:"evicted_at"`
}

// PreRecorder reports the "this deployment predates build-keyed recording" case:
// a 200 whose Deployment row carried no build_id, answered by
// `BuildLog.unkeyed/1` WITHOUT ever calling the box. It is neither an error nor
// a missing log, and a client that renders it as either is reproducing the
// wrong-key bug the route was built to remove.
func (r SiteBuildLogRecord) PreRecorder() bool {
	return r.HTTPStatus == 200 && r.BuildID == "" && r.LogState == "never_recorded"
}

// siteBuildLogDocumented reports whether a status is one of the five answers
// `Sites.BuildLog` documents. Anything else (401, 403, a proxy's 500) is not
// this route speaking and goes down the ordinary refusal path.
func siteBuildLogDocumented(status int) bool {
	switch status {
	case 200, 404, 409, 410, 502:
		return true
	}
	return false
}

// SiteBuildLog reads the recorder's durable record for ONE deployment, BY
// DEPLOYMENT ID.
//
// AUDIENCE: any member of the OWNING TEAM. The router wraps the route in
// `with_team_site(conn, {:ability, "read"}, ...)` — the same door its sibling
// GET /v1/sites/:id/deployments/:dep_id uses — which accepts a browser SESSION
// or a Bearer PAT carrying the "read" ability, and this client sends the latter.
// It is NOT gated on the platform-operator allowlist. It shipped behind
// `Auth.require_platform_operator`, whose `:platform_admin_emails` allowlist is
// empty and unsettable on prod, so the route answered ZERO accounts until cloud
// PR #17693 re-pointed it at the team door. That platform gate survives only on
// the SIBLING bytes route (.../build-log/bytes, whose client half is
// `site_build_log_bytes.go`), which serves the un-scrubbed bytes THIS route has
// never carried.
//
// The wrapper resolves the site with `Registry.get_team_site/2`, so a site — or
// a deployment — belonging to ANOTHER team is a 404, not a 403: the same answer
// as one that does not exist. The site scoping is likewise part of the URL by
// design, matching GET /v1/sites/:id/deployments/:dep_id exactly.
//
// A documented answer comes back as a record with HTTPStatus set and a nil
// error, INCLUDING the 404/409/410/502 ones. err is non-nil only for a transport
// failure, an undecodable body, or a status this route does not document.
func (c *Client) SiteBuildLog(ctx context.Context, siteID, deploymentID string) (SiteBuildLogRecord, error) {
	path := "/v1/sites/" + esc(siteID) + "/deployments/" + esc(deploymentID) + "/build-log"
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return SiteBuildLogRecord{}, err
	}
	if !siteBuildLogDocumented(status) {
		return SiteBuildLogRecord{HTTPStatus: status}, cloudError(status, body)
	}
	var rec SiteBuildLogRecord
	if err := json.Unmarshal(body, &rec); err != nil {
		return SiteBuildLogRecord{HTTPStatus: status}, fmt.Errorf("decode build log response: %w", err)
	}
	rec.HTTPStatus = status
	return rec, nil
}
