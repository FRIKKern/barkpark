package cloudclient

// autoupdate_test.go pins the isu-w5 self-update TRUTH decode + the policy /
// rollout methods. The decode is proven BOTH ways — a full control plane that
// emits every field, and an older one that omits them all (which must yield zero
// values, never an error).

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBarkparkDecodesFullUpdateTruth(t *testing.T) {
	raw := `{
	  "id":"i1","name":"mkt","host":"h",
	  "update_state":"behind",
	  "update_running_release":"1.4.2",
	  "update_latest_release":"1.5.0",
	  "update_checked_at":"2026-07-10T10:00:00Z",
	  "autoupdate_enabled":false,
	  "autoupdate_paused":true,
	  "pinned_release":"1.4.2",
	  "channel":"canary"
	}`
	var b Barkpark
	if err := json.Unmarshal([]byte(raw), &b); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if b.UpdateRunningRelease != "1.4.2" || b.UpdateLatestRelease != "1.5.0" {
		t.Fatalf("releases = %q → %q", b.UpdateRunningRelease, b.UpdateLatestRelease)
	}
	if b.UpdateCheckedAt != "2026-07-10T10:00:00Z" {
		t.Fatalf("checked_at = %q", b.UpdateCheckedAt)
	}
	if b.AutoupdateEnabled == nil || *b.AutoupdateEnabled != false {
		t.Fatalf("autoupdate_enabled = %v, want present false", b.AutoupdateEnabled)
	}
	if !b.AutoupdatePaused || b.PinnedRelease != "1.4.2" || b.Channel != "canary" {
		t.Fatalf("policy fields wrong: paused=%v pin=%q chan=%q", b.AutoupdatePaused, b.PinnedRelease, b.Channel)
	}
}

func TestBarkparkToleratesOlderControlPlane(t *testing.T) {
	// An older CP emits none of the isu-w5 fields — decode must not error and
	// every new field is its zero value (enabled nil = "policy unknown").
	raw := `{"id":"i1","name":"legacy","host":"h","health_status":"up","agent_status":"online"}`
	var b Barkpark
	if err := json.Unmarshal([]byte(raw), &b); err != nil {
		t.Fatalf("decode older CP row errored: %v", err)
	}
	if b.UpdateRunningRelease != "" || b.UpdateLatestRelease != "" || b.UpdateCheckedAt != "" {
		t.Fatalf("absent release fields should be empty: %+v", b)
	}
	if b.AutoupdateEnabled != nil {
		t.Fatalf("absent autoupdate_enabled should be nil (unknown), got %v", *b.AutoupdateEnabled)
	}
	if b.AutoupdatePaused || b.PinnedRelease != "" || b.Channel != "" {
		t.Fatalf("absent policy fields should be zero: %+v", b)
	}
}

// fakeCP stands up a control plane recording the last request and answering with
// a canned status + body.
func fakeCP(t *testing.T, status int, body string) (*Client, *struct{ method, path, body string }) {
	t.Helper()
	rec := &struct{ method, path, body string }{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		rec.method, rec.path, rec.body = r.Method, r.URL.Path, string(raw)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return &Client{BaseURL: srv.URL, Token: "tok", HTTP: srv.Client()}, rec
}

func TestSetAutoupdateDecodesPolicy(t *testing.T) {
	c, rec := fakeCP(t, 200, `{"ok":true,"autoupdate":{"enabled":true,"paused":false,"pinned_release":"v1.4.2"}}`)
	p, err := c.SetAutoupdate(context.Background(), "i1", map[string]any{"pinned_release": "v1.4.2"})
	if err != nil {
		t.Fatalf("SetAutoupdate: %v", err)
	}
	if rec.method != "PATCH" || rec.path != "/v1/barkparks/i1/autoupdate" {
		t.Fatalf("hit %s %s", rec.method, rec.path)
	}
	if !p.Enabled || p.Paused || p.PinnedRelease != "v1.4.2" {
		t.Fatalf("policy = %+v", p)
	}
}

func TestSetAutoupdateNotFoundIsRouteError(t *testing.T) {
	c, _ := fakeCP(t, 404, `{"error":"not_found"}`)
	_, err := c.SetAutoupdate(context.Background(), "i1", map[string]any{"autoupdate_paused": true})
	var re *CloudRouteError
	if err == nil || !asRoute(err, &re) || re.Code != "not_found" {
		t.Fatalf("want CloudRouteError not_found, got %v", err)
	}
}

// TestSetAutoupdateInvalidNestedIsRouteError pins the REAL 422 shape the
// autoupdate route emits — {"error":{"code":"invalid"}}, nested, not the flat
// {"error":"invalid"} string — so routeError's tolerant decode never regresses
// back to swallowing this into a raw cloudError body dump.
func TestSetAutoupdateInvalidNestedIsRouteError(t *testing.T) {
	c, _ := fakeCP(t, 422, `{"error":{"code":"invalid"}}`)
	_, err := c.SetAutoupdate(context.Background(), "i1", map[string]any{"pinned_release": "bad"})
	var re *CloudRouteError
	if err == nil || !asRoute(err, &re) || re.Code != "invalid" {
		t.Fatalf("want CloudRouteError invalid, got %v", err)
	}
}

func TestRolloutMethodsAndDecode(t *testing.T) {
	c, rec := fakeCP(t, 200, `{"ok":true,"halted":true,"eligible":3,"behind":2,"in_flight":1}`)

	st, err := c.RolloutStatus(context.Background())
	if err != nil {
		t.Fatalf("RolloutStatus: %v", err)
	}
	if rec.method != "GET" || rec.path != "/v1/admin/autoupdate" {
		t.Fatalf("status hit %s %s", rec.method, rec.path)
	}
	if !st.Halted || st.Eligible == nil || *st.Eligible != 3 || st.Behind == nil || *st.Behind != 2 || st.InFlight == nil || *st.InFlight != 1 {
		t.Fatalf("rollout state = %+v", st)
	}
	if len(st.Raw) == 0 {
		t.Fatalf("rollout Raw not retained for -o json passthrough")
	}

	if _, err := c.RolloutHalt(context.Background()); err != nil {
		t.Fatalf("RolloutHalt: %v", err)
	}
	if rec.method != "POST" || rec.path != "/v1/admin/autoupdate/halt" {
		t.Fatalf("halt hit %s %s", rec.method, rec.path)
	}
	if _, err := c.RolloutResume(context.Background()); err != nil {
		t.Fatalf("RolloutResume: %v", err)
	}
	if rec.path != "/v1/admin/autoupdate/resume" {
		t.Fatalf("resume hit %s", rec.path)
	}
}

func TestRolloutToleratesLeanEnvelope(t *testing.T) {
	// A CP that reports only `halted` — the counters stay nil (not fake zeros).
	c, _ := fakeCP(t, 200, `{"halted":false}`)
	st, err := c.RolloutStatus(context.Background())
	if err != nil {
		t.Fatalf("RolloutStatus: %v", err)
	}
	if st.Halted || st.Eligible != nil || st.Behind != nil || st.InFlight != nil {
		t.Fatalf("lean envelope should leave counters nil: %+v", st)
	}
}

// asRoute is a tiny errors.As shim kept local so this test file needs no extra
// import churn beyond the standard set.
func asRoute(err error, target **CloudRouteError) bool {
	if re, ok := err.(*CloudRouteError); ok {
		*target = re
		return true
	}
	return false
}
