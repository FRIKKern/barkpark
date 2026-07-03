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

const listEnvelope = `{"ok":true,"resource":"webhook","data":{"webhooks":[` +
	`{"id":"wh_1","name":"prod","url":"https://a.test/hook","dataset":"production","events":["create","update"],"active":true,"consecutive_failures":0,"disable_reason":null},` +
	`{"id":"wh_2","name":"stale","url":"https://b.test/h","dataset":"production","events":[],"active":false,"consecutive_failures":5,"disable_reason":"too_many_failures"}` +
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

// TestWebhookListTableGolden pins the human table (piped, uncolored).
func TestWebhookListTableGolden(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	stdout, _, code := runWebhook(t, "table", false, "list", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	assertGolden(t, "webhook_list_table", stdout)
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
	if !strings.Contains(colored, "\x1b[32m") || !strings.Contains(colored, "\x1b[31m") || !strings.Contains(colored, "\x1b[36m") {
		t.Fatalf("expected green+red+cyan status cells, got:\n%s", colored)
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
