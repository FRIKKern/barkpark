package cloudclient

// refusal_test.go pins the REFUSAL EVIDENCE decode (cch-w40-s4): a control-plane
// refusal carries more than a slug — a 403 names the CAUSE (`reason`), what it
// wanted (`required`) and over what (`scope`); a 422 names the offending fields
// (`details`). Dropping those left the user with a bare word, and left the CLI
// unable to tell a teamless caller from a wrong-role one — so a server that
// re-classifies a refusal's STATUS (422 no_team -> 403 forbidden + reason:no_team)
// silently changed both the sentence and the exit code with no test able to fail.

import (
	"errors"
	"strings"
	"testing"
)

// asRefusal is the local errors.As shim (the asRollback idiom in rollback_test.go)
// so this file needs nothing beyond the standard set.
func asRefusal(t *testing.T, err error) *CloudRefusal {
	t.Helper()
	var ref *CloudRefusal
	if !errors.As(err, &ref) {
		t.Fatalf("want a *CloudRefusal, got %T (%v)", err, err)
	}
	return ref
}

// TestCloudErrorDecodesAuthorityEvidence: the post-#9956 403 body — the exact
// bytes require_primary_team_admin/1 will emit — keeps its reason and scope
// instead of degrading to the bare word "forbidden".
func TestCloudErrorDecodesAuthorityEvidence(t *testing.T) {
	err := cloudError(403, []byte(`{"error":"forbidden","reason":"no_team","scope":"team","required":"team_admin"}`))
	ref := asRefusal(t, err)
	if ref.Code != "forbidden" || ref.Reason != "no_team" || ref.Scope != "team" || ref.Required != "team_admin" {
		t.Fatalf("evidence dropped: %+v", ref)
	}
	if ref.HTTPStatus != 403 {
		t.Fatalf("status = %d, want 403", ref.HTTPStatus)
	}
	// The user-facing line must NAME the cause, not just the slug.
	if !strings.Contains(err.Error(), "no_team") {
		t.Fatalf("message drops the cause: %q", err.Error())
	}
}

// TestCloudErrorDecodesDetails: the 422 per-field map (the cch-w37 `invalid`
// bare-slug row) surfaces the offending fields, tolerating BOTH the string and
// the list-of-strings value shapes the servers emit.
func TestCloudErrorDecodesDetails(t *testing.T) {
	err := cloudError(422, []byte(`{"error":"invalid","details":{"name":"is required","slug":["is taken","is too long"]}}`))
	ref := asRefusal(t, err)
	if ref.Details["name"] != "is required" {
		t.Fatalf("string detail dropped: %+v", ref.Details)
	}
	if ref.Details["slug"] != "is taken, is too long" {
		t.Fatalf("list detail not flattened: %+v", ref.Details)
	}
	msg := err.Error()
	if !strings.Contains(msg, "name: is required") || !strings.Contains(msg, "slug: is taken") {
		t.Fatalf("message stayed a bare slug: %q", msg)
	}
}

// TestCloudErrorEvidenceDegradesOnMixedTypes: each evidence field is decoded in
// its OWN Unmarshal, so a route that sends one of them as the WRONG type (an
// object where a string is contracted) costs only that field — it can never
// poison the whole decode and dump a raw body at the user.
func TestCloudErrorEvidenceDegradesOnMixedTypes(t *testing.T) {
	err := cloudError(403, []byte(`{"error":"forbidden","reason":{"code":"no_team"},"scope":"team","details":[1,2]}`))
	ref := asRefusal(t, err)
	if ref.Code != "forbidden" {
		t.Fatalf("a non-string reason poisoned the decode: %+v", ref)
	}
	if ref.Reason != "" {
		t.Fatalf("a non-string reason must degrade to empty, got %q", ref.Reason)
	}
	if ref.Scope != "team" {
		t.Fatalf("a sibling field must survive its neighbour's bad type: %+v", ref)
	}
	if len(ref.Details) != 0 {
		t.Fatalf("a non-object details must degrade to empty: %+v", ref.Details)
	}
	if !strings.Contains(err.Error(), "forbidden") {
		t.Fatalf("message lost the code: %q", err.Error())
	}
}

// TestCloudErrorKeepsUnauthorizedContract: the "unauthorized:" prefix cloudFail
// keys on survives the typed refusal (a dead session must still route to
// `bp login`), and a codeless body still falls back to the clamped raw body.
func TestCloudErrorKeepsUnauthorizedContract(t *testing.T) {
	if got := cloudError(401, []byte(`{"error":"unauthorized"}`)).Error(); got != "unauthorized: unauthorized" {
		t.Fatalf("401 prefix contract broke: %q", got)
	}
	if got := cloudError(502, []byte(`<html>bad gateway</html>`)).Error(); got != "<html>bad gateway</html>" {
		t.Fatalf("codeless body fallback broke: %q", got)
	}
}

// TestRollbackErrorCarriesReason: the rollback route's own decoder keeps the
// reason too — the CLI's rollback narration reads it, so a 403 whose cause is
// no_team cannot be narrated as a role problem.
func TestRollbackErrorCarriesReason(t *testing.T) {
	c, _ := rollbackServer(t, 403, `{"error":"forbidden","reason":"no_team","scope":"team"}`)
	_, err := c.Rollback(t.Context(), "i1")
	var re *RollbackError
	if !asRollback(err, &re) {
		t.Fatalf("want *RollbackError, got %T (%v)", err, err)
	}
	if re.HTTPStatus != 403 || re.Code != "forbidden" || re.Reason != "no_team" {
		t.Fatalf("rollback refusal dropped its evidence: %+v", re)
	}
}
