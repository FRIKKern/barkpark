package cloudclient

// rollback_test.go pins the isu-w6 instance-rollback client method: a 202 decodes
// the pointer scalars + retains Raw for the -o json passthrough, the request is a
// Bearer-authed POST to the rollback route, and BOTH control-plane refusal shapes
// — the nested {"error":{"code"}} the relay emits and the flat {"error":"..."} its
// team guard emits — become a typed *RollbackError carrying the HTTP status the CLI
// exit-maps on. A 401 stays a plain (unauthorized-prefixed) cloudError.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// asRollback is a tiny errors.As shim kept local (the asRoute idiom) so this test
// file needs no extra import churn beyond the standard set.
func asRollback(err error, target **RollbackError) bool {
	if re, ok := err.(*RollbackError); ok {
		*target = re
		return true
	}
	return false
}

// rollbackServer records the method/path/auth it saw and answers with a canned
// status + body — unlike the shared fakeCP it asserts the Bearer header, so this
// is no vacuous green.
func rollbackServer(t *testing.T, status int, body string) (*Client, *struct{ method, path, auth string }) {
	t.Helper()
	rec := &struct{ method, path, auth string }{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.method, rec.path, rec.auth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return &Client{BaseURL: srv.URL, Token: "tok", HTTP: srv.Client()}, rec
}

func TestRollbackStartedDecodesAndKeepsRaw(t *testing.T) {
	const body = `{"status":"started","target_sha":"abcdef0123","pinned_release":"1.4.2"}`
	c, rec := rollbackServer(t, 202, body)
	res, err := c.Rollback(context.Background(), "i1")
	if err != nil {
		t.Fatalf("Rollback: %v", err)
	}
	if rec.method != "POST" || rec.path != "/v1/barkparks/i1/rollback" {
		t.Fatalf("hit %s %s, want POST /v1/barkparks/i1/rollback", rec.method, rec.path)
	}
	if rec.auth != "Bearer tok" {
		t.Fatalf("auth = %q, want Bearer tok", rec.auth)
	}
	if res.Status == nil || *res.Status != "started" {
		t.Fatalf("status = %v, want started", res.Status)
	}
	if res.TargetSHA == nil || *res.TargetSHA != "abcdef0123" {
		t.Fatalf("target_sha = %v", res.TargetSHA)
	}
	if res.PinnedRelease == nil || *res.PinnedRelease != "1.4.2" {
		t.Fatalf("pinned_release = %v", res.PinnedRelease)
	}
	if string(res.Raw) != body {
		t.Fatalf("Raw not retained verbatim for -o json:\n got: %q\nwant: %q", res.Raw, body)
	}
}

func TestRollbackToleratesLeanEnvelope(t *testing.T) {
	// A leaner 202 (only status) must decode without error; the omitted scalars
	// stay nil (an honest "not reported"), never a fabricated empty string.
	c, _ := rollbackServer(t, 202, `{"status":"started"}`)
	res, err := c.Rollback(context.Background(), "i1")
	if err != nil {
		t.Fatalf("Rollback lean: %v", err)
	}
	if res.TargetSHA != nil {
		t.Fatalf("absent target_sha should be nil, got %q", *res.TargetSHA)
	}
	if res.PinnedRelease != nil {
		t.Fatalf("absent pinned_release should be nil, got %q", *res.PinnedRelease)
	}
}

func TestRollbackNestedRefusalIsTyped(t *testing.T) {
	// The relay's nested {"error":{"code","detail"}} shape → *RollbackError with the
	// HTTP status the CLI exit-maps on.
	c, _ := rollbackServer(t, 409, `{"error":{"code":"no_previous_slot","detail":"idle slot has no stamp"}}`)
	_, err := c.Rollback(context.Background(), "i1")
	var re *RollbackError
	if err == nil || !asRollback(err, &re) {
		t.Fatalf("want *RollbackError, got %v", err)
	}
	if re.HTTPStatus != 409 || re.Code != "no_previous_slot" || re.Detail != "idle slot has no stamp" {
		t.Fatalf("rollback error = %+v", re)
	}
}

func TestRollbackFlatRefusalIsTyped(t *testing.T) {
	// The top-level team guard's flat {"error":"not_found"} shape → *RollbackError.
	c, _ := rollbackServer(t, 404, `{"error":"not_found"}`)
	_, err := c.Rollback(context.Background(), "i1")
	var re *RollbackError
	if err == nil || !asRollback(err, &re) {
		t.Fatalf("want *RollbackError, got %v", err)
	}
	if re.HTTPStatus != 404 || re.Code != "not_found" {
		t.Fatalf("rollback error = %+v", re)
	}
}

func TestRollback502IsTyped(t *testing.T) {
	c, _ := rollbackServer(t, 502, `{"error":{"code":"instance_unreachable"}}`)
	_, err := c.Rollback(context.Background(), "i1")
	var re *RollbackError
	if err == nil || !asRollback(err, &re) || re.HTTPStatus != 502 || re.Code != "instance_unreachable" {
		t.Fatalf("want *RollbackError 502 instance_unreachable, got %v", err)
	}
}

func TestRollbackUnauthorizedStaysCloudError(t *testing.T) {
	// A 401 is NOT a RollbackError — it keeps the shared "unauthorized:" prefix so
	// cloudFail turns it into the session-expired hint.
	c, _ := rollbackServer(t, 401, `{"error":"bad token"}`)
	_, err := c.Rollback(context.Background(), "i1")
	if err == nil {
		t.Fatal("want an error on 401")
	}
	var re *RollbackError
	if asRollback(err, &re) {
		t.Fatalf("401 must not be a RollbackError, got %+v", re)
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("401 must keep the unauthorized prefix, got %q", err.Error())
	}
}
