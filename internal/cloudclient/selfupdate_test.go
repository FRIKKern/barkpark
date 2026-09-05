package cloudclient

// selfupdate_test.go pins the self-update TRIGGER client method: a 202 decodes the
// pointer scalars + retains Raw for the -o json passthrough, the request is a
// Bearer-authed POST to the self-update route, --force rides as {"force":true} in
// the BODY (and an unforced call sends none), BOTH control-plane refusal shapes
// become a typed *SelfUpdateError carrying the HTTP status the CLI exit-maps on,
// the 409 pinned refusal carries the PIN, and a 401 stays a plain
// (unauthorized-prefixed) cloudError.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// asSelfUpdate is a tiny errors.As shim kept local (the asRollback idiom) so this
// file needs no extra import churn beyond the standard set.
func asSelfUpdate(err error, target **SelfUpdateError) bool {
	if se, ok := err.(*SelfUpdateError); ok {
		*target = se
		return true
	}
	return false
}

// selfUpdateRec records everything the fake control plane SAW, so no assertion
// here can pass vacuously: the method, the path, the Authorization header and the
// request body bytes.
type selfUpdateRec struct{ method, path, auth, body string }

// selfUpdateServer answers the self-update route with a canned status + body and
// records the request. It asserts nothing itself — the tests do — but it captures
// the body, which is the only place --force is observable.
func selfUpdateServer(t *testing.T, status int, body string) (*Client, *selfUpdateRec) {
	t.Helper()
	rec := &selfUpdateRec{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		rec.method, rec.path, rec.auth, rec.body = r.Method, r.URL.Path, r.Header.Get("Authorization"), string(raw)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return &Client{BaseURL: srv.URL, Token: "tok", HTTP: srv.Client()}, rec
}

// TestTriggerSelfUpdateAcceptedDecodesAndKeepsRaw: the shipped 202 envelope
// ({ok, status}) decodes, Raw is the bytes verbatim, and the wire call is the
// Bearer-authed POST the route expects.
func TestTriggerSelfUpdateAcceptedDecodesAndKeepsRaw(t *testing.T) {
	const body = `{"ok":true,"status":"updating"}`
	c, rec := selfUpdateServer(t, 202, body)
	res, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	if err != nil {
		t.Fatalf("TriggerSelfUpdate: %v", err)
	}
	if rec.method != "POST" || rec.path != "/v1/barkparks/i1/self-update" {
		t.Fatalf("hit %s %s, want POST /v1/barkparks/i1/self-update", rec.method, rec.path)
	}
	if rec.auth != "Bearer tok" {
		t.Fatalf("auth = %q, want Bearer tok", rec.auth)
	}
	if res.Status == nil || *res.Status != "updating" {
		t.Fatalf("status = %v, want updating", res.Status)
	}
	if res.OK == nil || !*res.OK {
		t.Fatalf("ok = %v, want true", res.OK)
	}
	if string(res.Raw) != body {
		t.Fatalf("Raw not retained verbatim for -o json:\n got: %q\nwant: %q", res.Raw, body)
	}
}

// TestTriggerSelfUpdateForceRidesInTheBody: --force is a REAL server field
// (`conn.body_params["force"] == true`), so it must reach the wire. The unforced
// call sends NO body — the two requests must be distinguishable, and this is the
// only place that is observable.
func TestTriggerSelfUpdateForceRidesInTheBody(t *testing.T) {
	c, rec := selfUpdateServer(t, 202, `{"ok":true,"status":"updating"}`)
	if _, err := c.TriggerSelfUpdate(context.Background(), "i1", true); err != nil {
		t.Fatalf("forced: %v", err)
	}
	if !strings.Contains(rec.body, `"force":true`) {
		t.Fatalf("forced call body = %q, want it to carry \"force\":true", rec.body)
	}

	c2, rec2 := selfUpdateServer(t, 202, `{"ok":true,"status":"updating"}`)
	if _, err := c2.TriggerSelfUpdate(context.Background(), "i1", false); err != nil {
		t.Fatalf("unforced: %v", err)
	}
	if strings.Contains(rec2.body, "force") {
		t.Fatalf("unforced call must not send force, body = %q", rec2.body)
	}
}

// TestTriggerSelfUpdateToleratesLeanEnvelope: a 202 that names no state decodes
// without error and leaves the scalars nil — an honest "not reported" the caller
// can word for itself, never a fabricated empty string the CLI would print.
func TestTriggerSelfUpdateToleratesLeanEnvelope(t *testing.T) {
	c, _ := selfUpdateServer(t, 202, `{"ok":true}`)
	res, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	if err != nil {
		t.Fatalf("lean: %v", err)
	}
	if res.Status != nil {
		t.Fatalf("absent status should be nil, got %q", *res.Status)
	}
}

// TestTriggerSelfUpdatePinnedRefusalCarriesThePin: the 409 the route emits for a
// frozen box names WHICH release holds it, and that pin must survive into the
// typed error — it is the whole difference between "it is pinned" and a sentence
// an operator can act on.
func TestTriggerSelfUpdatePinnedRefusalCarriesThePin(t *testing.T) {
	c, _ := selfUpdateServer(t, 409, `{"error":{"code":"pinned","pinned_release":"1.4.2"}}`)
	_, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	var se *SelfUpdateError
	if !asSelfUpdate(err, &se) {
		t.Fatalf("want *SelfUpdateError, got %T (%v)", err, err)
	}
	if se.Code != "pinned" || se.HTTPStatus != 409 {
		t.Fatalf("got code=%q status=%d, want pinned/409", se.Code, se.HTTPStatus)
	}
	if se.PinnedRelease != "1.4.2" {
		t.Fatalf("PinnedRelease = %q, want 1.4.2", se.PinnedRelease)
	}
}

// TestTriggerSelfUpdateNestedRefusalIsTyped: the relay's nested
// {"error":{"code","detail"}} shape → *SelfUpdateError with the status the CLI
// exit-maps on. A refusal that names no pin leaves PinnedRelease empty (never a
// borrowed or invented version).
func TestTriggerSelfUpdateNestedRefusalIsTyped(t *testing.T) {
	c, _ := selfUpdateServer(t, 409, `{"error":{"code":"already_running","detail":"run 7 in flight"}}`)
	_, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	var se *SelfUpdateError
	if !asSelfUpdate(err, &se) {
		t.Fatalf("want *SelfUpdateError, got %T (%v)", err, err)
	}
	if se.Code != "already_running" || se.Detail != "run 7 in flight" || se.HTTPStatus != 409 {
		t.Fatalf("got %+v", se)
	}
	if se.PinnedRelease != "" {
		t.Fatalf("a pinless refusal must not carry a pin, got %q", se.PinnedRelease)
	}
}

// TestTriggerSelfUpdateFlatRefusalIsTyped: the top-level team guard's flat
// {"error":"not_found"} shape must type just as well — the route speaks BOTH, and
// a decoder that reads only one silently swallows half the contract.
func TestTriggerSelfUpdateFlatRefusalIsTyped(t *testing.T) {
	c, _ := selfUpdateServer(t, 404, `{"error":"not_found"}`)
	_, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	var se *SelfUpdateError
	if !asSelfUpdate(err, &se) {
		t.Fatalf("want *SelfUpdateError, got %T (%v)", err, err)
	}
	if se.Code != "not_found" || se.HTTPStatus != 404 {
		t.Fatalf("got code=%q status=%d, want not_found/404", se.Code, se.HTTPStatus)
	}
}

// TestTriggerSelfUpdateCarriesReason: an authority gate names the CAUSE at the top
// level ({"error":"forbidden","reason":"no_team"}); the CLI narrates and exit-codes
// off it, so it must survive the decode.
func TestTriggerSelfUpdateCarriesReason(t *testing.T) {
	c, _ := selfUpdateServer(t, 403, `{"error":"forbidden","reason":"no_team","scope":"team"}`)
	_, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	var se *SelfUpdateError
	if !asSelfUpdate(err, &se) {
		t.Fatalf("want *SelfUpdateError, got %T (%v)", err, err)
	}
	if se.Reason != "no_team" {
		t.Fatalf("Reason = %q, want no_team", se.Reason)
	}
}

// TestTriggerSelfUpdate401StaysCloudError: a 401 must NOT become a
// *SelfUpdateError — it keeps the shared "unauthorized:" prefix contract every
// cloud verb's auth handling keys on.
func TestTriggerSelfUpdate401StaysCloudError(t *testing.T) {
	c, _ := selfUpdateServer(t, 401, `{"error":"unauthorized"}`)
	_, err := c.TriggerSelfUpdate(context.Background(), "i1", false)
	var se *SelfUpdateError
	if asSelfUpdate(err, &se) {
		t.Fatalf("401 must stay a cloudError, got *SelfUpdateError %+v", se)
	}
	if err == nil || !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("401 error = %v, want the unauthorized-prefixed cloudError", err)
	}
}
