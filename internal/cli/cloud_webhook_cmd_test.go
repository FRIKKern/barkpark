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
//
// The rows also span the three TYPES shapes the box can store: a real filter
// (two doc types), the empty-array match-everything sentinel, and a row with
// no "types" key at all (an older record) — which means match-everything too.
const listEnvelope = `{"ok":true,"resource":"webhook","data":{"webhooks":[` +
	`{"id":"wh_1","name":"prod","url":"https://a.test/hook","dataset":"production","events":["create","update"],"types":["article","page"],"active":true,"consecutive_failures":0,"disable_reason":null},` +
	`{"id":"wh_2","name":"stale","url":"https://b.test/h","dataset":"production","events":[],"types":[],"active":false,"consecutive_failures":5,"disable_reason":"too_many_failures"},` +
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

// TestWebhookListTypesColumnDisambiguates is the assertion that FAILS if the
// types column is missing, unlabelled, or reading the wrong key. It does not
// consult the golden: it names the three cell shapes directly.
//
//   - wh_1 carries types ["article","page"] → the cell must show BOTH names.
//   - wh_2 carries types []                 → the match-everything label.
//   - wh_3 carries no types key at all      → the same label (same meaning).
//
// The last check is the one the row exists for: a scoped webhook's cell and an
// unscoped one's cell must not be the same string, or the table reproduces the
// ambiguity this column was added to kill.
func TestWebhookListTypesColumnDisambiguates(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, listEnvelope)
	})
	stdout, _, code := runWebhook(t, "table", false, "list", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(stdout, "types") {
		t.Fatalf("no types column in the header:\n%s", stdout)
	}
	var scoped, empty, missing string
	for _, line := range strings.Split(stdout, "\n") {
		switch {
		case strings.HasPrefix(line, "wh_1"):
			scoped = line
		case strings.HasPrefix(line, "wh_2"):
			empty = line
		case strings.HasPrefix(line, "wh_3"):
			missing = line
		}
	}
	if scoped == "" || empty == "" || missing == "" {
		t.Fatalf("missing a row (wh_1/wh_2/wh_3) in:\n%s", stdout)
	}
	for _, want := range []string{"article", "page"} {
		if !strings.Contains(scoped, want) {
			t.Fatalf("scoped row must name its doc type %q, got: %q", want, scoped)
		}
	}
	const sentinel = "match everything"
	if !strings.Contains(empty, sentinel) {
		t.Fatalf("empty types[] must be labelled %q, got: %q", sentinel, empty)
	}
	if !strings.Contains(missing, sentinel) {
		t.Fatalf("absent types key must be labelled %q, got: %q", sentinel, missing)
	}
	if strings.Contains(scoped, sentinel) {
		t.Fatalf("a scoped webhook must NOT read as match-everything: %q", scoped)
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

// ---------------------------------------------------------------------------
// test-send — the CLI twin of the console's "Send test" button (GR45)
// ---------------------------------------------------------------------------

// webhookTestSendChip is the EXACT string cloud/priv/static/app.js's
// webhookCliChip("test-send", instance, dataset) puts on the clipboard. It is a
// literal here on purpose: this file is the CLI side of that contract, so if the
// verb is ever renamed, the chip a user copies from the console stops parsing and
// these tests are where that is caught. The chip names the verb + instance (the
// same shape every other webhook chip uses); the operator appends the webhook id.
const webhookTestSendChip = "bp cloud webhook test-send"

// chipArgs splits a copied chip into the argv runCloudWebhook receives (the
// leading "bp cloud webhook" is the binary + noun the dispatcher already ate).
func chipArgs(chip string, tail ...string) []string {
	fields := strings.Fields(chip)
	if len(fields) < 3 {
		return append([]string{}, tail...)
	}
	return append(fields[3:], tail...)
}

// okTestSendEnvelope is the instance's answer to a probe the endpoint ACCEPTED.
const okTestSendEnvelope = `{"ok":true,"resource":"webhook","data":{"delivery":` +
	`{"id":"d_test_1","status":"ok","last_status_code":200,"last_latency_ms":42,"attempts":1}}}`

// TestWebhookTestSendRoutesAndPrintsVerdict: the copied chip's EXACT command
// (plus the webhook id the operator appends) POSTs to the test-send proxy route
// and prints the endpoint's real answer — status AND latency — never a canned ok.
func TestWebhookTestSendRoutesAndPrintsVerdict(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/test-send") {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		writeEnvelope(w, 200, okTestSendEnvelope)
	})
	args := chipArgs(webhookTestSendChip+" "+testInstanceID, "wh_1")
	stdout, stderr, code := runWebhook(t, "table", false, args...)
	if code != exitOK {
		t.Fatalf("exit = %d (stderr %q)", code, stderr)
	}
	if rec.count("POST", "/api/webhooks/wh_1/test-send") != 1 {
		t.Fatalf("test-send did not route to the proxy route: %+v", rec.all())
	}
	// The verdict must carry the endpoint's OWN numbers. A line that says only
	// "sent" would pass a mere substring check on the verb, so both are asserted.
	for _, want := range []string{"ACCEPTED it", "code: 200", "latency: 42"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
}

// TestWebhookTestSendChipParses: the chip's verb token is DISPATCHED, not met
// with "unknown webhook command". This is the arm that reds if the verb is
// renamed while the console keeps emitting the ratified spelling.
func TestWebhookTestSendChipParses(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, okTestSendEnvelope)
	})
	_, stderr, _ := runWebhook(t, "table", false, chipArgs(webhookTestSendChip+" "+testInstanceID)...)
	if strings.Contains(stderr, "unknown webhook command") {
		t.Fatalf("the copied chip's verb does not parse: %q", stderr)
	}
}

// TestWebhookTestSendForwardsDataset: the chip's off-default `--dataset <ds>`
// reaches the proxy as the dataset selector, so a staging probe never fires at
// the production endpoint.
func TestWebhookTestSendForwardsDataset(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, okTestSendEnvelope)
	})
	chip := webhookTestSendChip + " " + testInstanceID + " --dataset staging"
	if _, stderr, code := runWebhook(t, "table", false, chipArgs(chip, "wh_1")...); code != exitOK {
		t.Fatalf("exit = %d (stderr %q)", code, stderr)
	}
	reqs := rec.all()
	if len(reqs) != 1 {
		t.Fatalf("want exactly one proxy call, got %+v", reqs)
	}
	if reqs[0].query != "dataset=staging" {
		t.Fatalf("dataset not forwarded: query = %q", reqs[0].query)
	}
	// CONTROL: with no --dataset the same call must carry the documented default,
	// so the assertion above is measuring forwarding and not just "a query exists".
	rec2 := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, okTestSendEnvelope)
	})
	if _, _, code := runWebhook(t, "table", false, "test-send", testInstanceID, "wh_1"); code != exitOK {
		t.Fatalf("default-dataset exit = %d", code)
	}
	if got := rec2.all()[0].query; got != "dataset=production" {
		t.Fatalf("default dataset = %q, want dataset=production", got)
	}
}

// TestWebhookTestSendRejectedIsNotOK is the heart of the row: the control plane
// says 200/ok:true while the ENDPOINT answered 500. A canned "sent" would print a
// success here. The verdict must be a REJECTION on stdout, with the auto-disable
// note so the operator knows the probe is harmless.
//
// The EXIT stays 0 by default — that is the ratified `bp webhook test-send`
// contract (run.go failOnFailedDeliveryFlag / docs/cli/error-exit-table.md), and
// the second half of this test is the control that proves the exit is reading the
// VERDICT and not the flag: the same flag against an ACCEPTED probe exits 0.
func TestWebhookTestSendRejectedIsNotOK(t *testing.T) {
	const rejected = `{"ok":true,"resource":"webhook","data":{"delivery":` +
		`{"id":"d_test_2","status":"failed_giveup","last_status_code":500,"last_latency_ms":9,"attempts":1}}}`

	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, rejected)
	})
	stdout, _, code := runWebhook(t, "table", false, "test-send", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("default exit = %d, want 0 (the verdict rides a 2xx body by design)", code)
	}
	for _, want := range []string{"REJECTED it", "code: 500", "auto-disable streak"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "ACCEPTED it") {
		t.Fatalf("a rejected probe claimed acceptance:\n%s", stdout)
	}

	// Opt-in: the flag turns the SAME rejected verdict into a non-zero exit, and
	// must not change a byte of what is printed.
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, rejected)
	})
	flagged, _, flaggedCode := runWebhook(t, "table", false, "test-send", testInstanceID, "wh_1", "--fail-on-failed-delivery")
	if flaggedCode != exitGeneric {
		t.Fatalf("--fail-on-failed-delivery on a rejected probe: exit = %d, want %d", flaggedCode, exitGeneric)
	}
	if flagged != stdout {
		t.Fatalf("the flag changed the rendered verdict:\nflagged: %q\ndefault: %q", flagged, stdout)
	}

	// CONTROL: the flag is reading the VERDICT, not its own presence — an accepted
	// probe with the flag set still exits 0.
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, okTestSendEnvelope)
	})
	if _, _, okCode := runWebhook(t, "table", false, "test-send", testInstanceID, "wh_1", "--fail-on-failed-delivery"); okCode != exitOK {
		t.Fatalf("--fail-on-failed-delivery on an ACCEPTED probe: exit = %d, want 0", okCode)
	}
}

// TestWebhookTestSendUnconfirmedIsNeitherTickNorAccusation: a delivery with no
// status code and no recognisable status (a pending row, or an instance too old
// to echo a verdict) is reported AS unknown — not a green tick, and not an
// accusation against a possibly-fine endpoint. It stays exit 0: the REQUEST
// succeeded and nothing refuted the delivery.
func TestWebhookTestSendUnconfirmedIsNeitherTickNorAccusation(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, `{"ok":true,"resource":"webhook","data":{"delivery":{"id":"d_test_3","status":"pending"}}}`)
	})
	stdout, _, code := runWebhook(t, "table", false, "test-send", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 for an unconfirmed verdict", code)
	}
	if !strings.Contains(stdout, "verdict unknown") || !strings.Contains(stdout, "reported no verdict") {
		t.Fatalf("unconfirmed verdict not reported as unknown:\n%s", stdout)
	}
	if strings.Contains(stdout, "ACCEPTED it") || strings.Contains(stdout, "REJECTED it") {
		t.Fatalf("an unknown verdict was rendered as a decision:\n%s", stdout)
	}
}

// TestWebhookTestSendServerErrors: a refused proxy call exits on the SHARED
// ladder and prints NO verdict — "I could not send" must never read as a send.
func TestWebhookTestSendServerErrors(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   int
		hint   string
	}{
		{"upstream 404", 404,
			`{"ok":false,"error":{"code":"upstream_error","status":404,"detail":{"error":{"code":"not_found","message":"webhook not found"}}}}`,
			exitNotFound, "webhook not found"},
		{"unreachable", 502,
			`{"ok":false,"reachable":false,"error":{"code":"instance_unreachable"}}`,
			exitGeneric, "unreachable"},
		{"too old", 502,
			`{"ok":false,"error":{"code":"capability_unavailable","hint":"update this instance"}}`,
			exitGeneric, "update this instance"},
		{"upstream 500", 500,
			`{"ok":false,"error":{"code":"upstream_error","status":500,"detail":{"error":{"code":"server_error","message":"boom"}}}}`,
			exitGeneric, "boom"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
				writeEnvelope(w, tc.status, tc.body)
			})
			stdout, stderr, code := runWebhook(t, "table", false, "test-send", testInstanceID, "wh_1")
			if code != tc.want {
				t.Fatalf("exit = %d, want %d (stderr %q)", code, tc.want, stderr)
			}
			if !strings.Contains(stderr, tc.hint) {
				t.Fatalf("stderr = %q, want it to carry %q", stderr, tc.hint)
			}
			if strings.Contains(stdout, "ACCEPTED it") || strings.Contains(stdout, "test event sent") {
				t.Fatalf("a refused call printed a send verdict:\n%s", stdout)
			}
		})
	}
}

// TestWebhookTestSendJSONVerbatim: `-o json` emits the proxy envelope unchanged
// (D4) — the CLI never becomes a second, drifting definition of the contract.
func TestWebhookTestSendJSONVerbatim(t *testing.T) {
	newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		writeEnvelope(w, 200, okTestSendEnvelope)
	})
	stdout, _, code := runWebhook(t, "json", false, "test-send", testInstanceID, "wh_1")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if strings.TrimSpace(stdout) != okTestSendEnvelope {
		t.Fatalf("json output is not the envelope verbatim:\n%s", stdout)
	}
}

// TestWebhookTestSendUsage: a missing webhook id is a usage error that issues NO
// probe — a half-typed command must never fire a live request at an endpoint.
func TestWebhookTestSendUsage(t *testing.T) {
	rec := newFakeProxy(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("a usage error fired a probe: %s %s", r.Method, r.URL.Path)
	})
	for _, args := range [][]string{
		{"test-send", testInstanceID},
		{"test-send", testInstanceID, "wh_1", "extra"},
		{"test-send"},
	} {
		if _, _, code := runWebhook(t, "table", false, args...); code != exitUsage {
			t.Fatalf("%v exit = %d, want %d", args, code, exitUsage)
		}
	}
	if len(rec.all()) != 0 {
		t.Fatalf("usage errors hit the network: %+v", rec.all())
	}
}

// TestWebhookTestSendHelpListsVerb: `bp cloud webhook -h` advertises the verb.
// The console's chip is copied by people who then read the help; a verb missing
// from the help is a verb nobody finds.
func TestWebhookTestSendHelpListsVerb(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloudWebhook(w, globals{}, []string{"-h"}); code != exitOK {
		t.Fatalf("help exit = %d", code)
	}
	if !strings.Contains(sout.String(), "test-send  <instance> <webhook-id>") {
		t.Fatalf("help does not list test-send:\n%s", sout.String())
	}
}

// TestWebhookTestVerdictShapes pins the verdict function itself against the shapes
// the box and its older releases actually emit. The status CODE wins whenever
// there is one; the status STRING only speaks when there is no code; anything
// else is unconfirmed rather than a guess.
func TestWebhookTestVerdictShapes(t *testing.T) {
	cases := []struct {
		name string
		del  map[string]any
		want string
	}{
		{"2xx code", map[string]any{"last_status_code": float64(204)}, webhookTestAccepted},
		{"lean status_code spelling", map[string]any{"status_code": float64(201)}, webhookTestAccepted},
		{"4xx code", map[string]any{"last_status_code": float64(404)}, webhookTestRejected},
		{"5xx code beats an ok status string", map[string]any{"last_status_code": float64(503), "status": "ok"}, webhookTestRejected},
		{"string-typed code", map[string]any{"last_status_code": "200"}, webhookTestAccepted},
		{"null code falls through to the status", map[string]any{"last_status_code": nil, "status": "ok"}, webhookTestAccepted},
		{"failed_giveup, no code", map[string]any{"status": "failed_giveup"}, webhookTestRejected},
		{"pending", map[string]any{"status": "pending"}, webhookTestUnconfirmed},
		{"empty row", map[string]any{}, webhookTestUnconfirmed},
	}
	for _, tc := range cases {
		if got := webhookTestVerdict(tc.del); got != tc.want {
			t.Errorf("%s: verdict = %q, want %q", tc.name, got, tc.want)
		}
	}
}
