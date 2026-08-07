package cli

// cloud_webhook_cmd_test.go proves the `bp cloud webhook` twin against a FAKE
// instance-API proxy: the envelope-verbatim json contract, the role-painted
// table (and its byte-identical piped form), the toggle-is-a-PUT-{active}
// semantics, the typed-resource delete gate (a mismatch issues zero DELETEs),
// the one-time secret on rotate, and honest degradation for an unreachable /
// too-old instance.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// a canonical UUID instance id — resolveOpenBarkparkID passes a UUID through
// without a fleet-list call, so the ONLY requests a test records are the proxy
// calls under test.
const testInstanceID = "11111111-2222-3333-4444-555555555555"

// recordedReq is one request the fake proxy saw.
type recordedReq struct {
	method string
	path   string
	query  string
	body   string
	auth   string
}

// proxyRecorder wraps a fake control-plane proxy: it records every request and
// delegates the response to a test-supplied handler.
type proxyRecorder struct {
	url string
	mu  sync.Mutex
	rq  []recordedReq
}

func (p *proxyRecorder) add(r recordedReq) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.rq = append(p.rq, r)
}

func (p *proxyRecorder) all() []recordedReq {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]recordedReq, len(p.rq))
	copy(out, p.rq)
	return out
}

// count returns how many recorded requests used method against a path suffix.
func (p *proxyRecorder) count(method, pathSuffix string) int {
	n := 0
	for _, r := range p.all() {
		if r.method == method && strings.HasSuffix(r.path, pathSuffix) {
			n++
		}
	}
	return n
}

// newFakeProxy stands up a recording fake proxy, seeds a cloud login pointed at
// it, and returns the recorder. h writes the proxy envelope for each request.
func newFakeProxy(t *testing.T, h http.HandlerFunc) *proxyRecorder {
	t.Helper()
	rec := &proxyRecorder{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		rec.add(recordedReq{
			method: r.Method,
			path:   r.URL.Path,
			query:  r.URL.RawQuery,
			body:   string(body),
			auth:   r.Header.Get("Authorization"),
		})
		h(w, r)
	}))
	t.Cleanup(srv.Close)
	rec.url = srv.URL
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return rec
}

// runWebhook drives runCloudWebhook with an in-memory writer at the chosen
// output shape + color, returning stdout, stderr, exit.
func runWebhook(t *testing.T, output string, color bool, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = color
	code := runCloudWebhook(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// writeEnvelope is a tiny helper to write a compact JSON body with a status.
func writeEnvelope(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

// Three rows, one per STATUS state: active → ok, auto-disabled (disable_reason
// present) → failed, manually switched off (active:false, NO disable_reason) →
// inactive.
const listEnvelope = `{"ok":true,"resource":"webhook","data":{"webhooks":[` +
	`{"id":"wh_1","name":"prod","url":"https://a.test/hook","dataset":"production","events":["create","update"],"active":true,"consecutive_failures":0,"disable_reason":null},` +
	`{"id":"wh_2","name":"stale","url":"https://b.test/h","dataset":"production","events":[],"active":false,"consecutive_failures":5,"disable_reason":"too_many_failures"},` +
	`{"id":"wh_3","name":"paused","url":"https://c.test/h","dataset":"production","events":["publish"],"active":false,"consecutive_failures":0,"disable_reason":null}` +
	`]}}`

// TestWebhookDispatch: the verbs route, an unknown verb is usage, and no login
// is auth.
func TestWebhookDispatch(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	if _, _, code := runWebhook(t, "table", false, "list", testInstanceID); code != exitOK {
		t.Fatalf("list exit = %d", code)
	}
	if _, _, code := runWebhook(t, "table", false, "bogus", testInstanceID); code != exitUsage {
		t.Fatalf("unknown verb exit = %d, want %d", code, exitUsage)
	}
	// routed through runCloud too.
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloud(w, globals{}, []string{"webhook", "list", testInstanceID}); code != exitOK {
		t.Fatalf("`bp cloud webhook list` via runCloud exit = %d\n%s", code, serr.String())
	}
}

func TestWebhookRequiresLogin(t *testing.T) {
	withTempConfigHome(t) // no cloud token seeded
	_, stderr, code := runWebhook(t, "table", false, "list", testInstanceID)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("stderr = %q, want a `bp login` hint", stderr)
	}
}

// TestWebhookListJSONVerbatim: -o json emits the proxy envelope byte-for-byte
// (the envelope IS the contract — no reshaping).
func TestWebhookListJSONVerbatim(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	stdout, _, code := runWebhook(t, "json", false, "list", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if strings.TrimRight(stdout, "\n") != listEnvelope {
		t.Fatalf("json not verbatim:\n got: %s\nwant: %s", stdout, listEnvelope)
	}
}

// TestWebhookListTableGolden pins the human table (piped, uncolored) and the
// tty STATUS paint: active=green(ok), auto-disabled=red(failed), manually
// off=yellow(inactive — NOT "suspended", which means an instance suspension).
func TestWebhookListTableGolden(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	stdout, _, code := runWebhook(t, "table", false, "list", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	assertGolden(t, "webhook_list_table", stdout)

	colored, _, _ := runWebhook(t, "table", true, "list", testInstanceID)
	if !strings.Contains(colored, "\x1b[32mok") || !strings.Contains(colored, "\x1b[31mfailed") || !strings.Contains(colored, "\x1b[33minactive") {
		t.Fatalf("expected green ok + red failed + yellow inactive cells, got:\n%q", colored)
	}
	if rtrimLines(stripANSI(colored)) != rtrimLines(stdout) {
		t.Fatalf("colored (ansi-stripped) != piped:\n%s", stripANSI(colored))
	}
}

// TestWebhookPerVerbHelp: -h anywhere in the tail prints help and exits 0 — a
// verb-level `bp cloud webhook list -h` must never be an unknown-flag error.
func TestWebhookPerVerbHelp(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("help must not call the proxy: %s %s", r.Method, r.URL.Path)
	})
	for _, args := range [][]string{
		{"-h"},
		{"list", "-h"},
		{"rm", testInstanceID, "wh_1", "--help"},
	} {
		stdout, _, code := runWebhook(t, "table", false, args...)
		if code != exitOK {
			t.Fatalf("%v exit = %d, want 0", args, code)
		}
		if !strings.Contains(stdout, "bp cloud webhook — control") {
			t.Fatalf("%v did not print help:\n%s", args, stdout)
		}
	}
	if len(rec.all()) != 0 {
		t.Fatalf("help hit the network: %+v", rec.all())
	}
}

// TestWebhookListYAML: -o yaml is a faithful re-encode of the envelope.
func TestWebhookListYAML(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	stdout, _, code := runWebhook(t, "yaml", false, "list", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	for _, want := range []string{"ok: true", "webhooks:", "wh_1", "https://a.test/hook"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("yaml missing %q:\n%s", want, stdout)
		}
	}
}

// TestWebhookDatasetPassedThrough: --dataset rides as ?dataset= on the proxy.
func TestWebhookDatasetPassedThrough(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"webhooks":[]}}`)
	})
	if _, _, code := runWebhook(t, "table", false, "list", testInstanceID, "--dataset", "staging"); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	reqs := rec.all()
	if len(reqs) != 1 || reqs[0].query != "dataset=staging" {
		t.Fatalf("query = %+v, want dataset=staging", reqs)
	}
	// and the default is production when omitted.
	if _, _, code := runWebhook(t, "table", false, "list", testInstanceID); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if q := rec.all()[1].query; q != "dataset=production" {
		t.Fatalf("default query = %q, want dataset=production", q)
	}
}

// TestWebhookAuthIsCloudToken: the proxy is called with the CLOUD Bearer, never
// an instance token.
func TestWebhookAuthIsCloudToken(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	if _, _, code := runWebhook(t, "table", false, "list", testInstanceID); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if got := rec.all()[0].auth; got != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", got)
	}
}

// TestWebhookDeliveriesColoring: the STATUS cell is role-painted on a tty
// (ok=green, failed=red, pending=cyan) and the piped form is byte-identical
// once ANSI is stripped — the D12 seam guarantee.
func TestWebhookDeliveriesColoring(t *testing.T) {
	const env = `{"ok":true,"resource":"webhook","data":{"deliveries":[` +
		`{"id":"d1","status":"ok","last_status_code":200,"attempts":1,"last_latency_ms":42,"updated_at":"2026-07-03T10:00:00Z"},` +
		`{"id":"d2","status":"failed_giveup","last_status_code":500,"attempts":6,"last_latency_ms":88,"updated_at":"2026-07-03T10:05:00Z"},` +
		`{"id":"d3","status":"pending","last_status_code":null,"attempts":0,"last_latency_ms":null,"updated_at":"2026-07-03T10:06:00Z"}` +
		`]}}`
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) { writeEnvelope(w, 200, env) })

	colored, _, code := runWebhook(t, "table", true, "deliveries", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	// info is BLUE (34) at the basic-16 floor — the deliberate S6 retint (was cyan 36).
	if !strings.Contains(colored, "\x1b[32m") || !strings.Contains(colored, "\x1b[31m") || !strings.Contains(colored, "\x1b[34m") {
		t.Fatalf("expected green+red+blue(info) status cells, got:\n%s", colored)
	}
	// a pending row's null code/latency shows an em dash, not a blank.
	if !strings.Contains(stripANSI(colored), "—") {
		t.Fatalf("pending row should dash its null cells:\n%s", stripANSI(colored))
	}
	piped, _, _ := runWebhook(t, "table", false, "deliveries", testInstanceID, "wh_1")
	if strings.Contains(piped, "\x1b[") {
		t.Fatalf("piped output must carry NO ansi:\n%q", piped)
	}
	if rtrimLines(stripANSI(colored)) != rtrimLines(piped) {
		t.Fatalf("colored (ansi-stripped) != piped:\n--- colored ---\n%s\n--- piped ---\n%s", stripANSI(colored), piped)
	}
	assertGolden(t, "webhook_deliveries_table", piped)
}

// TestWebhookToggleSendsPutActiveOnly: toggle reads the current state, then PUTs
// EXACTLY {"active": <flipped>} — no bespoke toggle route, no extra fields.
func TestWebhookToggleSendsPutActiveOnly(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_1","active":true,"consecutive_failures":0,"disable_reason":null}}}`)
		case "PUT":
			writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_1","active":false,"consecutive_failures":0,"disable_reason":null}}}`)
		default:
			t.Errorf("unexpected %s", r.Method)
		}
	})
	stdout, _, code := runWebhook(t, "table", false, "toggle", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if rec.count("PUT", "/webhooks/wh_1") != 1 {
		t.Fatalf("want exactly one PUT, reqs=%+v", rec.all())
	}
	var putBody map[string]any
	for _, r := range rec.all() {
		if r.method == "PUT" {
			if err := json.Unmarshal([]byte(r.body), &putBody); err != nil {
				t.Fatalf("PUT body not json: %q", r.body)
			}
		}
	}
	if len(putBody) != 1 {
		t.Fatalf("PUT body must be ONLY {active}, got %v", putBody)
	}
	if active, ok := putBody["active"].(bool); !ok || active != false {
		t.Fatalf("PUT body active = %v, want false (flipped from true)", putBody["active"])
	}
	if !strings.Contains(stdout, "is now inactive") {
		t.Fatalf("stdout should report the new state:\n%s", stdout)
	}
	// D55 truth: the response's consecutive_failures + disable_reason are shown.
	if !strings.Contains(stdout, "consecutive_failures") || !strings.Contains(stdout, "disable_reason") {
		t.Fatalf("toggle must surface the auto-disable substrate:\n%s", stdout)
	}
}

// TestWebhookRotateShowsSecretOnce: the new secret prints once with a warning,
// and the raw envelope is the json contract.
func TestWebhookRotateShowsSecretOnce(t *testing.T) {
	const env = `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_1","active":true},"secret":"whsec_TOPSECRET"}}`
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/rotate") {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		writeEnvelope(w, 200, env)
	})
	stdout, _, code := runWebhook(t, "table", false, "rotate", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if n := strings.Count(stdout, "whsec_TOPSECRET"); n != 1 {
		t.Fatalf("secret must appear exactly once, saw %d:\n%s", n, stdout)
	}
	if !strings.Contains(stdout, "shown ONCE") {
		t.Fatalf("missing shown-once warning:\n%s", stdout)
	}
	// json path emits the envelope verbatim (secret included, one-time reveal).
	jout, _, _ := runWebhook(t, "json", false, "rotate", testInstanceID, "wh_1")
	if strings.TrimRight(jout, "\n") != env {
		t.Fatalf("json not verbatim:\n%s", jout)
	}
}

// TestWebhookRmMismatchNoDelete: an interactive typed-confirm mismatch aborts
// with a non-zero exit and NO DELETE reaches the proxy (the wave-1 pattern).
func TestWebhookRmMismatchNoDelete(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		// the pre-confirm read of the endpoint (to offer the URL back).
		writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_1","url":"https://a.test/hook","active":true}}}`)
	})
	forceHzTTY(t)
	swapHzStdin(t, strings.NewReader("not-the-id\n"))

	_, stderr, code := runWebhook(t, "table", true, "rm", testInstanceID, "wh_1")
	if code != exitGeneric {
		t.Fatalf("mismatch exit = %d, want %d (the human declined)", code, exitGeneric)
	}
	if rec.count("DELETE", "/webhooks/wh_1") != 0 {
		t.Fatalf("a DELETE was issued despite a mismatched confirmation: %+v", rec.all())
	}
	if !strings.Contains(stderr, "does not match") {
		t.Fatalf("abort stderr should explain the mismatch:\n%s", stderr)
	}
}

// TestWebhookRmYesDeletes: --yes skips the prompt (and the pre-fetch) and fires
// the DELETE straight away.
func TestWebhookRmYesDeletes(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" {
			t.Errorf("unexpected %s (–-yes must not pre-fetch)", r.Method)
		}
		writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"deleted":"wh_1"}}`)
	})
	stdout, _, code := runWebhook(t, "table", false, "rm", testInstanceID, "wh_1", "--yes")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if rec.count("DELETE", "/webhooks/wh_1") != 1 {
		t.Fatalf("want exactly one DELETE, reqs=%+v", rec.all())
	}
	if rec.count("GET", "/webhooks/wh_1") != 0 {
		t.Fatalf("--yes must not pre-fetch the webhook: %+v", rec.all())
	}
	if !strings.Contains(stdout, "deleted webhook wh_1") {
		t.Fatalf("stdout = %s", stdout)
	}
}

// TestWebhookRmInteractiveMatchDeletes: typing the exact id proceeds.
func TestWebhookRmInteractiveMatchDeletes(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_1","url":"https://a.test/hook","active":true}}}`)
		case "DELETE":
			writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"deleted":"wh_1"}}`)
		}
	})
	forceHzTTY(t)
	swapHzStdin(t, strings.NewReader("wh_1\n"))
	_, _, code := runWebhook(t, "table", false, "rm", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("confirmed delete exit = %d", code)
	}
	if rec.count("DELETE", "/webhooks/wh_1") != 1 {
		t.Fatalf("no DELETE after a correct confirmation: %+v", rec.all())
	}
}

// TestWebhookUnreachableDegrades: a 502 {reachable:false} envelope renders as
// 'instance unreachable — …', exit generic (never a hang).
func TestWebhookUnreachableDegrades(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 502, `{"ok":false,"error":{"code":"instance_unreachable"},"reachable":false}`)
	})
	_, stderr, code := runWebhook(t, "table", false, "list", testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if !strings.Contains(stderr, "instance unreachable") {
		t.Fatalf("stderr = %q, want the unreachable hint", stderr)
	}
}

// TestWebhookCapabilityUnavailable: a too-old instance (502
// capability_unavailable) renders the update-instance hint.
func TestWebhookCapabilityUnavailable(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 502, `{"ok":false,"error":{"code":"capability_unavailable","hint":"update this instance"}}`)
	})
	_, stderr, code := runWebhook(t, "table", false, "deliveries", testInstanceID, "wh_1")
	if code != exitGeneric {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(stderr, "update this instance") {
		t.Fatalf("stderr = %q, want the update hint", stderr)
	}
}

// TestWebhookUpstreamNotFound: an upstream 404 relays as a not_found exit.
func TestWebhookUpstreamNotFound(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 404, `{"ok":false,"error":{"code":"upstream_error","status":404,"detail":{"error":{"code":"not_found","message":"webhook not found"}}}}`)
	})
	_, stderr, code := runWebhook(t, "table", false, "show", testInstanceID, "wh_missing")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (not_found)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "webhook not found") {
		t.Fatalf("stderr = %q, want the relayed instance message", stderr)
	}
}

// TestWebhookReplayInactiveNote: replay succeeds even to an inactive webhook and
// prints the informational manual-redelivery note (wave-C1 ratification d).
func TestWebhookReplayInactiveNote(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/replay") {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"delivery":{"id":"d9","status":"ok","last_status_code":200,"last_latency_ms":31,"attempts":1}}}`)
	})
	stdout, _, code := runWebhook(t, "table", false, "replay", testInstanceID, "wh_1", "evt_7")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if rec.count("POST", "/deliveries/evt_7/replay") != 1 {
		t.Fatalf("replay path wrong: %+v", rec.all())
	}
	if !strings.Contains(stdout, "replayed event evt_7") {
		t.Fatalf("stdout = %s", stdout)
	}
	if !strings.Contains(stdout, "even when the webhook is inactive") {
		t.Fatalf("missing the inactive-replay note:\n%s", stdout)
	}
}

// TestWebhookCreateSendsURL: create posts {url,...} and reports the new id.
func TestWebhookCreateSendsURL(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 201, `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_new","url":"https://c.test/hook","active":true}}}`)
	})
	stdout, _, code := runWebhook(t, "table", false, "create", testInstanceID, "https://c.test/hook", "--events", "create,update")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(rec.all()[0].body), &body); err != nil {
		t.Fatalf("create body not json: %q", rec.all()[0].body)
	}
	if body["url"] != "https://c.test/hook" {
		t.Fatalf("create body url = %v", body["url"])
	}
	events, _ := body["events"].([]any)
	if len(events) != 2 {
		t.Fatalf("create events = %v, want two", body["events"])
	}
	if !strings.Contains(stdout, "created webhook wh_new") {
		t.Fatalf("stdout = %s", stdout)
	}
}

// editEnvelope is a canonical edit success used by the edit-verb tests.
const editEnvelope = `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh_1","name":"renamed","url":"https://new.test/hook","active":true}}}`

// TestWebhookEditPartialBody proves the partial-update contract: each flag alone
// PUTs ONLY that key, combined flags PUT exactly the passed set (and nothing
// else), and events/types split on commas.
func TestWebhookEditPartialBody(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want map[string]any
	}{
		{"name only", []string{"--name", "renamed"}, map[string]any{"name": "renamed"}},
		{"url only", []string{"--url", "https://new.test/hook"}, map[string]any{"url": "https://new.test/hook"}},
		{"events only", []string{"--events", "create,update"}, map[string]any{"events": []any{"create", "update"}}},
		{"types only", []string{"--types", "post,page"}, map[string]any{"types": []any{"post", "page"}}},
		{"combined", []string{"--name", "renamed", "--url", "https://new.test/hook", "--events", "publish"},
			map[string]any{"name": "renamed", "url": "https://new.test/hook", "events": []any{"publish"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "PUT" || !strings.HasSuffix(r.URL.Path, "/webhooks/wh_1") {
					t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
				}
				writeEnvelope(w, 200, editEnvelope)
			})
			args := append([]string{"edit", testInstanceID, "wh_1"}, tc.args...)
			_, _, code := runWebhook(t, "table", false, args...)
			if code != exitOK {
				t.Fatalf("exit = %d", code)
			}
			if rec.count("PUT", "/webhooks/wh_1") != 1 {
				t.Fatalf("want exactly one PUT, reqs=%+v", rec.all())
			}
			var body map[string]any
			if err := json.Unmarshal([]byte(rec.all()[0].body), &body); err != nil {
				t.Fatalf("PUT body not json: %q", rec.all()[0].body)
			}
			if len(body) != len(tc.want) {
				t.Fatalf("PUT body = %v, want exactly the passed keys %v", body, tc.want)
			}
			for k, want := range tc.want {
				got := body[k]
				if wantSlice, ok := want.([]any); ok {
					gotSlice, _ := got.([]any)
					if len(gotSlice) != len(wantSlice) {
						t.Fatalf("body[%q] = %v, want %v", k, got, want)
					}
					for i := range wantSlice {
						if gotSlice[i] != wantSlice[i] {
							t.Fatalf("body[%q][%d] = %v, want %v", k, i, gotSlice[i], wantSlice[i])
						}
					}
					continue
				}
				if got != want {
					t.Fatalf("body[%q] = %v, want %v", k, got, want)
				}
			}
		})
	}
}

// TestWebhookEditNoFlags: an edit with no editable flags is a usage error that
// resolves no instance and issues no PUT.
func TestWebhookEditNoFlags(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("a no-flag edit must not call the proxy: %s %s", r.Method, r.URL.Path)
	})
	_, stderr, code := runWebhook(t, "table", false, "edit", testInstanceID, "wh_1")
	if code != exitUsage {
		t.Fatalf("no-flag edit exit = %d, want %d (usage)", code, exitUsage)
	}
	if !strings.Contains(stderr, "nothing to edit") {
		t.Fatalf("stderr = %q, want the nothing-to-edit hint", stderr)
	}
	if len(rec.all()) != 0 {
		t.Fatalf("no-flag edit hit the network: %+v", rec.all())
	}
}

// TestWebhookEditHappyPath: a full edit reports the updated id and the `update`
// alias routes to the same verb; -o json emits the server receipt verbatim.
func TestWebhookEditHappyPath(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, editEnvelope)
	})
	stdout, _, code := runWebhook(t, "table", false, "edit", testInstanceID, "wh_1", "--name", "renamed")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(stdout, "updated webhook wh_1") {
		t.Fatalf("stdout = %s", stdout)
	}
	// the `update` alias routes to the same runner.
	if _, _, code := runWebhook(t, "table", false, "update", testInstanceID, "wh_1", "--name", "renamed"); code != exitOK {
		t.Fatalf("update alias exit = %d", code)
	}
	// -o json emits the proxy envelope byte-for-byte (the contract).
	jout, _, _ := runWebhook(t, "json", false, "edit", testInstanceID, "wh_1", "--name", "renamed")
	if strings.TrimRight(jout, "\n") != editEnvelope {
		t.Fatalf("json not verbatim:\n%s", jout)
	}
}

// TestWebhookEditClearsList: an explicit empty --events PUTs an empty list (a
// deliberate clear), not a null and not an omission.
func TestWebhookEditClearsList(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, editEnvelope)
	})
	if _, _, code := runWebhook(t, "table", false, "edit", testInstanceID, "wh_1", "--events", ""); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(rec.all()[0].body), &body); err != nil {
		t.Fatalf("PUT body not json: %q", rec.all()[0].body)
	}
	ev, present := body["events"]
	if !present {
		t.Fatalf("an explicit --events \"\" must PUT the events key, body=%v", body)
	}
	if evSlice, ok := ev.([]any); !ok || len(evSlice) != 0 {
		t.Fatalf("cleared events = %v, want an empty list []", ev)
	}
}

// TestWebhookUsageErrors: wrong positional counts are usage errors that touch no
// network.
func TestWebhookUsageErrors(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("a usage error must not call the proxy: %s %s", r.Method, r.URL.Path)
	})
	cases := [][]string{
		{"show", testInstanceID},           // missing webhook id
		{"replay", testInstanceID, "wh_1"}, // missing event id
		{"list", testInstanceID, "extra"},  // too many
		{"create", testInstanceID},         // missing url
		{"edit", testInstanceID},           // missing webhook id
	}
	for _, args := range cases {
		if _, _, code := runWebhook(t, "table", false, args...); code != exitUsage {
			t.Fatalf("%v exit = %d, want %d", args, code, exitUsage)
		}
	}
	if len(rec.all()) != 0 {
		t.Fatalf("usage errors hit the network: %+v", rec.all())
	}
}

// ---------------------------------------------------------------------------
// reconcile — the doc-type filter, re-assertable
// ---------------------------------------------------------------------------

// The site ids the reconcile fixtures use as their site-autodeploy suffixes.
const (
	reconcileSiteA = "aaaaaaaa-1111-2222-3333-444444444444"
	reconcileSiteB = "bbbbbbbb-1111-2222-3333-444444444444"
	reconcileSiteC = "cccccccc-1111-2222-3333-444444444444"
)

// reconcileListEnvelope builds a webhook-list envelope: two site-autodeploy rows
// carrying `types`, plus one hand-made endpoint reconcile must never touch.
func reconcileListEnvelope(typesA, typesB string) string {
	return `{"ok":true,"resource":"webhook","data":{"webhooks":[` +
		`{"id":"wh_a","name":"site-autodeploy-` + reconcileSiteA + `","url":"https://cp.test/a","active":true,"events":["publish"],"types":` + typesA + `,"consecutive_failures":0,"disable_reason":null},` +
		`{"id":"wh_b","name":"site-autodeploy-` + reconcileSiteB + `","url":"https://cp.test/b","active":true,"events":["publish"],"types":` + typesB + `,"consecutive_failures":0,"disable_reason":null},` +
		`{"id":"wh_hand","name":"my-own-hook","url":"https://x.test/h","active":true,"events":["publish"],"types":[],"consecutive_failures":0,"disable_reason":null}` +
		`]}}`
}

// newReconcileProxy stands up a fake control plane that answers BOTH the webhook
// proxy (list + PUT) and GET /v1/sites/:id, so reconcile's doc-type lookup is
// exercised for real. docTypes maps a site id to the doc_type its row carries; a
// site absent from the map 404s (the "cannot determine" branch).
func newReconcileProxy(t *testing.T, list string, docTypes map[string]string) *proxyRecorder {
	t.Helper()
	return newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/sites/"):
			id := strings.TrimPrefix(r.URL.Path, "/v1/sites/")
			dt, ok := docTypes[id]
			if !ok {
				writeEnvelope(w, 404, `{"error":"not_found"}`)
				return
			}
			writeEnvelope(w, 200, `{"site":{"id":"`+id+`","name":"s","doc_type":"`+dt+`"}}`)
		case r.Method == "PUT":
			writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"webhook":{"id":"wh","types":["paper"]}}}`)
		default:
			writeEnvelope(w, 200, list)
		}
	})
}

// TestWebhookReconcileRepairsDriftedRows: an empty filter ({} = MATCH EVERYTHING
// on the box) is PUT back to the site's own doc_type through the partial-PUT
// path — types ONLY, so nothing else on the row is disturbed — and the hand-made
// endpoint is left alone.
func TestWebhookReconcileRepairsDriftedRows(t *testing.T) {
	rec := newReconcileProxy(t, reconcileListEnvelope("[]", "[]"), map[string]string{
		reconcileSiteA: "paper",
		reconcileSiteB: "article",
	})
	stdout, _, code := runWebhook(t, "table", false, "reconcile", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if n := rec.count("PUT", "/wh_a"); n != 1 {
		t.Fatalf("PUTs to wh_a = %d, want 1", n)
	}
	if n := rec.count("PUT", "/wh_b"); n != 1 {
		t.Fatalf("PUTs to wh_b = %d, want 1", n)
	}
	if n := rec.count("PUT", "/wh_hand"); n != 0 {
		t.Fatalf("reconcile wrote to a hand-made webhook (%d PUTs) — it owns only the site-autodeploy rows", n)
	}
	for _, r := range rec.all() {
		if r.method != "PUT" {
			continue
		}
		var body map[string]any
		if err := json.Unmarshal([]byte(r.body), &body); err != nil {
			t.Fatalf("PUT body not json: %q", r.body)
		}
		if len(body) != 1 {
			t.Fatalf("PUT body = %v, want ONLY the types key (a partial update)", body)
		}
		ty, _ := body["types"].([]any)
		if len(ty) != 1 {
			t.Fatalf("PUT types = %v, want exactly one doc type", body["types"])
		}
	}
	if !strings.Contains(stdout, "UPDATED") || !strings.Contains(stdout, "[paper]") || !strings.Contains(stdout, "[article]") {
		t.Fatalf("report did not name the before/after:\n%s", stdout)
	}
	if !strings.Contains(stdout, "match everything") {
		t.Fatalf("an empty filter must be labelled as MATCH EVERYTHING:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 updated") || !strings.Contains(stdout, "1 other webhook(s) left untouched") {
		t.Fatalf("summary wrong:\n%s", stdout)
	}
}

// runWebhookArgv drives a FULL command line — `bp cloud webhook …` — through
// parseGlobals exactly as Execute does, then into the dispatcher. This is the
// only faithful harness for a GLOBAL flag: parseGlobals lifts `--dry-run` out of
// the line before the verb's own parser runs, so a test that calls runCloudWebhook
// directly with globals{} proves nothing about the real binary's dry run (it
// passed green here while the shipped binary WROTE to production).
func runWebhookArgv(t *testing.T, output string, argv ...string) (string, string, int) {
	t.Helper()
	g, rest, err := parseGlobals(argv)
	if err != nil {
		t.Fatalf("parseGlobals(%v): %v", argv, err)
	}
	if len(rest) < 2 || rest[0] != "cloud" || rest[1] != "webhook" {
		t.Fatalf("argv did not start with `cloud webhook`: %v", rest)
	}
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudWebhook(w, g, rest[2:])
	return sout.String(), serr.String(), code
}

// TestWebhookReconcileDryRunWritesNothing: --dry-run reports the exact intended
// change for every drifted row and issues ZERO writes — driven through the real
// global-flag path (see runWebhookArgv).
func TestWebhookReconcileDryRunWritesNothing(t *testing.T) {
	rec := newReconcileProxy(t, reconcileListEnvelope("[]", "[]"), map[string]string{
		reconcileSiteA: "paper",
		reconcileSiteB: "paper",
	})
	stdout, _, code := runWebhookArgv(t, "table", "cloud", "webhook", "reconcile", testInstanceID, "--dry-run")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	for _, r := range rec.all() {
		if r.method != "GET" {
			t.Fatalf("--dry-run issued a %s %s — it must write NOTHING", r.method, r.path)
		}
	}
	if !strings.Contains(stdout, "DRY RUN") || !strings.Contains(stdout, "(would update)") {
		t.Fatalf("dry run did not print the intended change:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 would update") {
		t.Fatalf("dry-run summary wrong:\n%s", stdout)
	}
	// …and the verb-local flag holds the same line, so a future de-globalisation
	// of --dry-run cannot silently turn a preview back into a write.
	rec2 := newReconcileProxy(t, reconcileListEnvelope("[]", "[]"), map[string]string{
		reconcileSiteA: "paper",
		reconcileSiteB: "paper",
	})
	if _, _, code := runWebhook(t, "table", false, "reconcile", testInstanceID, "--dry-run"); code != exitOK {
		t.Fatalf("verb-local --dry-run exit = %d", code)
	}
	for _, r := range rec2.all() {
		if r.method != "GET" {
			t.Fatalf("verb-local --dry-run issued a %s %s", r.method, r.path)
		}
	}
}

// TestWebhookReconcileGlobalDryRunReachesTheVerb pins the trap directly:
// parseGlobals STRIPS --dry-run from the command line, so the flag arrives only
// on globals. If the verb ever stops reading it there, this fails.
func TestWebhookReconcileGlobalDryRunReachesTheVerb(t *testing.T) {
	g, rest, err := parseGlobals([]string{"cloud", "webhook", "reconcile", testInstanceID, "--dry-run"})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	if !g.dryRun {
		t.Fatalf("--dry-run did not land on globals")
	}
	for _, tok := range rest {
		if tok == "--dry-run" {
			t.Fatalf("--dry-run reached the verb args — the global parser is expected to strip it: %v", rest)
		}
	}
	rec := newReconcileProxy(t, reconcileListEnvelope("[]", "[]"), map[string]string{
		reconcileSiteA: "paper",
		reconcileSiteB: "paper",
	})
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloudWebhook(w, g, rest[2:]); code != exitOK {
		t.Fatalf("exit = %d\n%s%s", code, sout.String(), serr.String())
	}
	for _, r := range rec.all() {
		if r.method != "GET" {
			t.Fatalf("a global --dry-run issued a %s %s — the verb ignored globals.dryRun", r.method, r.path)
		}
	}
	if !strings.Contains(sout.String(), "DRY RUN") {
		t.Fatalf("global --dry-run did not announce itself:\n%s", sout.String())
	}
}

// TestWebhookReconcileIsIdempotent: run it against rows that are ALREADY correct
// and it reports "already correct" and issues no writes — the second run of the
// pair, so a repair is safe to re-assert by hand or on a schedule.
func TestWebhookReconcileIsIdempotent(t *testing.T) {
	rec := newReconcileProxy(t, reconcileListEnvelope(`["paper"]`, `["paper"]`), map[string]string{
		reconcileSiteA: "paper",
		reconcileSiteB: "paper",
	})
	stdout, _, code := runWebhook(t, "table", false, "reconcile", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	for _, r := range rec.all() {
		if r.method != "GET" {
			t.Fatalf("a no-op run issued a %s %s", r.method, r.path)
		}
	}
	if !strings.Contains(stdout, "already correct") || !strings.Contains(stdout, "2 already correct") {
		t.Fatalf("idempotent run did not report already-correct rows:\n%s", stdout)
	}
}

// TestWebhookReconcileSkipsUndeterminableDocType is the FAIL-CLOSED proof, by
// MUTATION of the fixture: site A carries an EMPTY doc_type and site B does not
// resolve at all. Neither is guessed — both are reported and skipped, no write is
// issued for them, and the run exits non-zero so a script cannot read the repair
// as complete. The one determinable row is still repaired.
func TestWebhookReconcileSkipsUndeterminableDocType(t *testing.T) {
	list := `{"ok":true,"resource":"webhook","data":{"webhooks":[` +
		`{"id":"wh_a","name":"site-autodeploy-` + reconcileSiteA + `","url":"https://cp.test/a","active":true,"types":[],"consecutive_failures":0,"disable_reason":null},` +
		`{"id":"wh_b","name":"site-autodeploy-` + reconcileSiteB + `","url":"https://cp.test/b","active":true,"types":[],"consecutive_failures":0,"disable_reason":null},` +
		`{"id":"wh_c","name":"site-autodeploy-` + reconcileSiteC + `","url":"https://cp.test/c","active":true,"types":[],"consecutive_failures":0,"disable_reason":null}` +
		`]}}`
	// site A: a row predating the doc_type column. site C: determinable, still
	// repaired. site B: absent from the map → the control plane 404s it.
	rec := newReconcileProxy(t, list, map[string]string{
		reconcileSiteA: "",
		reconcileSiteC: "paper",
	})
	stdout, stderr, code := runWebhook(t, "table", false, "reconcile", testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d — an unrepaired row must be loud", code, exitGeneric)
	}
	if n := rec.count("PUT", "/wh_a"); n != 0 {
		t.Fatalf("a site with no doc_type was WRITTEN (%d PUTs) — it must be skipped, never guessed", n)
	}
	if n := rec.count("PUT", "/wh_b"); n != 0 {
		t.Fatalf("an unreadable site was WRITTEN (%d PUTs) — it must be skipped", n)
	}
	if n := rec.count("PUT", "/wh_c"); n != 1 {
		t.Fatalf("the determinable row was not repaired (%d PUTs, want 1)", n)
	}
	if !strings.Contains(stdout, "SKIPPED — site "+reconcileSiteA+" has no doc_type") {
		t.Fatalf("the empty doc_type was not reported:\n%s", stdout)
	}
	if !strings.Contains(stdout, "SKIPPED — control plane could not read site "+reconcileSiteB) {
		t.Fatalf("the unreadable site was not reported:\n%s", stdout)
	}
	if !strings.Contains(stderr, "skipped site-autodeploy-"+reconcileSiteA) {
		t.Fatalf("a skip must also reach stderr, got:\n%s", stderr)
	}
	if !strings.Contains(stdout, "2 skipped") || !strings.Contains(stdout, "exiting non-zero") {
		t.Fatalf("summary did not carry the skips:\n%s", stdout)
	}
}

// TestWebhookReconcileJSONReport: -o json emits the machine report — one element
// per site-autodeploy row with its action — and the exit still carries the
// non-zero verdict a skip earns.
func TestWebhookReconcileJSONReport(t *testing.T) {
	newReconcileProxy(t, reconcileListEnvelope("[]", "[]"), map[string]string{
		reconcileSiteA: "paper",
	})
	stdout, _, code := runWebhook(t, "json", false, "reconcile", testInstanceID)
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	var report struct {
		DryRun   bool `json:"dry_run"`
		Webhooks []struct {
			ID           string   `json:"id"`
			SiteID       string   `json:"site_id"`
			CurrentTypes []string `json:"current_types"`
			DesiredTypes []string `json:"desired_types"`
			Action       string   `json:"action"`
			Detail       string   `json:"detail"`
		} `json:"webhooks"`
		OtherRows int            `json:"other_rows"`
		Summary   map[string]int `json:"summary"`
	}
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("-o json is not parseable: %v\n%s", err, stdout)
	}
	if len(report.Webhooks) != 2 || report.OtherRows != 1 {
		t.Fatalf("report shape = %+v", report)
	}
	if report.Webhooks[0].Action != "updated" || len(report.Webhooks[0].DesiredTypes) != 1 || report.Webhooks[0].DesiredTypes[0] != "paper" {
		t.Fatalf("row 0 = %+v, want an updated paper row", report.Webhooks[0])
	}
	if report.Webhooks[1].Action != "skipped" || report.Webhooks[1].Detail == "" {
		t.Fatalf("row 1 = %+v, want a skip carrying its reason", report.Webhooks[1])
	}
	if report.Summary["updated"] != 1 || report.Summary["skipped"] != 1 {
		t.Fatalf("summary = %v", report.Summary)
	}
}

// TestWebhookReconcileUnreadableListWritesNothing: "I could not look" never
// authorizes a repair — a failed list degrades honestly and issues no PUT.
func TestWebhookReconcileUnreadableListWritesNothing(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, `{"ok":false,"resource":"webhook","error":{"code":"instance_unreachable"}}`)
	})
	_, stderr, code := runWebhook(t, "table", false, "reconcile", testInstanceID)
	if code == exitOK {
		t.Fatalf("an unreadable list exited 0")
	}
	if !strings.Contains(stderr, "instance unreachable") {
		t.Fatalf("stderr = %q, want the honest degradation line", stderr)
	}
	if n := rec.count("PUT", ""); n != 0 {
		t.Fatalf("a failed list issued %d writes", n)
	}
}

// TestWebhookReconcileEmptyFleet: an instance with no site-autodeploy rows says
// so plainly and exits 0.
func TestWebhookReconcileEmptyFleet(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope) // three hand-made rows, no site-autodeploy
	})
	stdout, _, code := runWebhook(t, "table", false, "reconcile", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "nothing to reconcile") || !strings.Contains(stdout, "3 other webhook(s)") {
		t.Fatalf("empty report:\n%s", stdout)
	}
}
