package cli

// hetzner_cmd_test.go drives `bp cloud hetzner …` against an httptest fake of
// api.hetzner.cloud (the PR1 pattern from internal/hetzner/provider_test.go):
// every test asserts the REAL wire request the SDK sent (method/path/body) and
// the rendered output — no mocked client, no tautologies. Action-polling tests
// return the action still RUNNING from the mutate call so a fire-and-forget
// implementation would fail the poll-count assertion.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mattn/go-runewidth"

	"github.com/FRIKKern/barkpark/internal/hetzner"
)

// fakeHzAPI is the httptest stand-in for api.hetzner.cloud, recording every
// request so assertions read the wire shapes the SDK actually sent.
type fakeHzAPI struct {
	t   *testing.T
	mux *http.ServeMux
	srv *httptest.Server

	mu   sync.Mutex
	reqs []hzReq
}

type hzReq struct {
	Method string
	Path   string
	Query  string
	Body   map[string]any
	Auth   string
}

// newFakeHzAPI stands the fake up AND rewires the command surface at it: the
// newHetznerClient seam points at the fake with a ~instant poll interval, the
// create read-back poll is made instant, and HCLOUD_TOKEN is set so token
// resolution succeeds without touching the developer's real credentials.
func newFakeHzAPI(t *testing.T) *fakeHzAPI {
	t.Helper()
	f := &fakeHzAPI{t: t, mux: http.NewServeMux()}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := hzReq{
			Method: r.Method,
			Path:   r.URL.Path,
			Query:  r.URL.RawQuery,
			Auth:   r.Header.Get("Authorization"),
		}
		if r.Body != nil {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			rec.Body = body
		}
		f.mu.Lock()
		f.reqs = append(f.reqs, rec)
		f.mu.Unlock()
		f.mux.ServeHTTP(w, r)
	}))
	t.Cleanup(f.srv.Close)

	oldClient := newHetznerClient
	newHetznerClient = func(token string) *hetzner.Client {
		return hetzner.NewClient(token,
			hetzner.WithEndpoint(f.srv.URL),
			hetzner.WithPollBackoff(time.Millisecond),
		)
	}
	oldPoll := hetznerCreatePoll
	hetznerCreatePoll = time.Millisecond
	t.Cleanup(func() {
		newHetznerClient = oldClient
		hetznerCreatePoll = oldPoll
	})
	t.Setenv("HCLOUD_TOKEN", "test-token")
	return f
}

func (f *fakeHzAPI) requests() []hzReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]hzReq(nil), f.reqs...)
}

func (f *fakeHzAPI) find(method, path string) (hzReq, bool) {
	for _, r := range f.requests() {
		if r.Method == method && r.Path == path {
			return r, true
		}
	}
	return hzReq{}, false
}

func (f *fakeHzAPI) count(method, path string) int {
	n := 0
	for _, r := range f.requests() {
		if r.Method == method && r.Path == path {
			n++
		}
	}
	return n
}

func hzWriteJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = fmt.Fprint(w, body)
}

// runHzCLI drives `bp cloud <args…>` with an in-memory writer, mirroring what
// Execute's noun switch hands runCloud. output "" keeps the piped default
// (json); "table"/"yaml" force that shape like an explicit -o.
func runHzCLI(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{}
	if output != "" {
		g.output = output
		g.outputSet = true
	}
	w.applyGlobals(g)
	code := runCloud(w, g, args)
	return stdout.String(), stderr.String(), code
}

// TestHetznerServerCreate asserts the FULL create conversation: the ssh-key
// resolution, the POST /servers body, the action POLL to completion, the
// running+IP read-back, and the structured receipt.
func TestHetznerServerCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /ssh_keys", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "deploy-key" {
			t.Errorf("ssh_keys lookup name = %q, want deploy-key", got)
		}
		hzWriteJSON(w, 200, `{"ssh_keys":[{"id":7,"name":"deploy-key","fingerprint":"aa:bb"}]}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		// The action rides back RUNNING and the server INITIALIZING, so a
		// fire-and-forget create (or one that skips the running read-back)
		// fails this test.
		hzWriteJSON(w, 201, `{
			"server":{"id":42,"name":"web-1","status":"initializing","public_net":{"ipv4":{"ip":"192.0.2.10"}}},
			"action":{"id":11,"command":"create_server","status":"running","progress":0},
			"next_actions":[{"id":12,"command":"start_server","status":"running","progress":0}]
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":11,"status":"success","progress":100},{"id":12,"status":"success","progress":100}]}`)
	})
	f.mux.HandleFunc("GET /servers/42", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server":{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"},"ipv6":{"ip":"2001:db8::1"}}}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "server", "create",
		"--name", "web-1", "--type", "cx22", "--image", "ubuntu-24.04",
		"--location", "nbg1", "--ssh-key", "deploy-key", "--label", "env=prod")
	if code != exitOK {
		t.Fatalf("create exited %d, stderr: %s", code, stderr)
	}

	// The wire request carried the right body.
	req, ok := f.find("POST", "/servers")
	if !ok {
		t.Fatal("no POST /servers was issued")
	}
	if req.Auth != "Bearer test-token" {
		t.Errorf("Authorization = %q, want Bearer test-token", req.Auth)
	}
	for field, want := range map[string]any{
		"name": "web-1", "server_type": "cx22", "image": "ubuntu-24.04", "location": "nbg1",
	} {
		if got := req.Body[field]; got != want {
			t.Errorf("create body %s = %v, want %v", field, got, want)
		}
	}
	keys, _ := req.Body["ssh_keys"].([]any)
	if len(keys) != 1 || keys[0] != float64(7) {
		t.Errorf("create body ssh_keys = %v, want [7] (the resolved key's id)", req.Body["ssh_keys"])
	}
	labels, _ := req.Body["labels"].(map[string]any)
	if labels["env"] != "prod" {
		t.Errorf("create body labels = %v, want env=prod", labels)
	}

	// The running actions were POLLED and the server re-read until running.
	if f.count("GET", "/actions") == 0 {
		t.Error("create never polled the running actions")
	}
	if f.count("GET", "/servers/42") == 0 {
		t.Error("create never re-read the server for running+IP")
	}

	// The receipt is a machine-readable success with the assigned IP.
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["ok"] != true || payload["action"] != "create" {
		t.Errorf("receipt = %v, want ok=true action=create", payload)
	}
	if payload["ipv4"] != "192.0.2.10" || payload["status"] != "running" {
		t.Errorf("receipt ipv4/status = %v/%v, want 192.0.2.10/running", payload["ipv4"], payload["status"])
	}
	srv, _ := payload["server"].(map[string]any)
	if srv["name"] != "web-1" || srv["id"] != float64(42) {
		t.Errorf("receipt server = %v, want web-1/42", srv)
	}
}

// TestHetznerServerPoweroff asserts the action verb path: name resolution,
// POST …/actions/poweroff, the poll of the still-running action, and the
// POST-CONDITION read-back — the receipt names the state it observed, not the
// pre-action object it was handed.
func TestHetznerServerPoweroff(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "web-1" {
			t.Errorf("server lookup name = %q, want web-1", got)
		}
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /servers/42/actions/poweroff", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":21,"command":"stop_server","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query()["id"]; len(got) != 1 || got[0] != "21" {
			t.Errorf("action poll ids = %v, want [21]", got)
		}
		hzWriteJSON(w, 200, `{"actions":[{"id":21,"status":"success","progress":100}]}`)
	})
	// Shape B is a BOUNDED POLL: the box reports the transient `stopping`
	// before it reports `off`, so a single read-back would false-red it.
	f.mux.HandleFunc("GET /servers/42", hzServerStates(
		`{"id":42,"name":"web-1","status":"stopping"}`,
		`{"id":42,"name":"web-1","status":"off"}`,
	))

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", "poweroff", "web-1")
	if code != exitOK {
		t.Fatalf("poweroff exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("POST", "/servers/42/actions/poweroff"); !ok {
		t.Fatal("no POST /servers/42/actions/poweroff was issued")
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("poweroff never polled the running action — fire-and-forget")
	}
	if n := f.count("GET", "/servers/42"); n < 2 {
		t.Errorf("poweroff read the server back %d time(s); want a bounded POLL through the transient `stopping`", n)
	}
	if !strings.Contains(stdout, "✓ poweroff — server web-1 (id 42)") {
		t.Errorf("poweroff output = %q, want the ✓ receipt line", stdout)
	}
	if !strings.Contains(stdout, "status: off") {
		t.Errorf("poweroff output = %q, want the OBSERVED post-condition (status: off) — "+
			"a receipt carrying only id/name says nothing an action could have changed", stdout)
	}
}

// hzServerStates serves a `GET /servers/<id>` that walks a script of server
// bodies, repeating the last one forever. That is how the transient states
// (`starting`, `stopping`) that make a single read-back a lie get into a test.
func hzServerStates(bodies ...string) http.HandlerFunc {
	var mu sync.Mutex
	i := 0
	return func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		body := bodies[i]
		if i < len(bodies)-1 {
			i++
		}
		mu.Unlock()
		hzWriteJSON(w, 200, `{"server":`+body+`}`)
	}
}

// hzReceiptSite is one derived completed-verb receipt: the verb it names, the
// file and line that emits it, and — the part the gate turns on — the CALL
// SHAPE, because the shape is what decides whether the verb's post-condition
// is EXECUTED or merely DECLARED.
type hzReceiptSite struct {
	verb  string
	file  string
	line  int
	shape hzReceiptShape
}

type hzReceiptShape string

const (
	// hzShapeExecutor — runHetznerServerAction, which READS
	// hzServerPostConditions and re-reads the server through hzReadBack.
	hzShapeExecutor hzReceiptShape = "runHetznerServerAction"
	// hzShapeFlagVerb — hzFlagVerbDone, which reads the SAME table through
	// hzBoundPost and re-reads through hzReadBack.
	hzShapeFlagVerb hzReceiptShape = "hzFlagVerbDone"
	// hzShapeLiteral — a bare hzDone("verb", …). This shape reaches NEITHER
	// consumer of hzServerPostConditions, so a table entry for a verb whose
	// only receipt is this shape is a declaration nothing runs.
	hzShapeLiteral hzReceiptShape = "hzDone"
)

// hzReceiptSourceFiles is the population the derivation scans: every non-test
// hetzner_*.go in this package. It is a GLOB, deliberately — the file list is
// derived from the tree, so a tenth hetzner_*.go added tomorrow is scanned the
// day it lands instead of the day someone remembers to add it here.
func hzReceiptSourceFiles(t *testing.T) []string {
	t.Helper()
	all, err := filepath.Glob(filepath.Join(".", "hetzner_*.go"))
	if err != nil {
		t.Fatalf("glob hetzner_*.go: %v", err)
	}
	var srcs []string
	for _, p := range all {
		if strings.HasSuffix(p, "_test.go") {
			continue
		}
		srcs = append(srcs, p)
	}
	sort.Strings(srcs)
	if len(srcs) < 2 {
		t.Fatalf("globbed %d hetzner sources (%v) — the scan is measuring itself, not the package", len(srcs), srcs)
	}
	return srcs
}

// hzReceiptSitesFromSource DERIVES, at test time, every verb in the package's
// hetzner sources that reaches a completed-verb receipt for a server. Three
// shapes reach one:
//
//  1. the runHetznerServerAction call sites — the verb is the enclosing `case`
//  2. the flag verbs' hzFlagVerbDone sites — the verb is the first quoted token
//  3. the LITERAL-verb receipts (bare hzDone with a quoted verb)
//
// Shapes 2 and 3 are why this scan was widened once (PDS-D366): the older read
// saw only shape 1, so the five flag verbs were structurally invisible to the
// gate that exists to catch exactly them. It is widened AGAIN here (PDS wave
// 27) across FILES: it read one hard-coded hetzner_cmd.go, so the four
// `instance` verbs whose receipts live in hetzner_instance_cmd.go — archive,
// resurrect, adopt, eject — were invisible for exactly the same reason one file
// over. The gate exists at all because a charter (PDS-D344) said six and the
// source said nine: a list transcribed by hand is a claim, and this file's
// whole subject is claims nobody re-read. So the population is COUNTED —
// glob + scan — and never quoted.
func hzReceiptSitesFromSource(t *testing.T) []hzReceiptSite {
	t.Helper()
	quoted := regexp.MustCompile(`"([^"]+)"`)
	literalReceipt := regexp.MustCompile(`\b(hzDone|hzFlagVerbDone)\([^)]*"`)
	var sites []hzReceiptSite
	for _, path := range hzReceiptSourceFiles(t) {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		var pending []string
		for i, raw := range strings.Split(string(src), "\n") {
			line := strings.TrimSpace(raw)
			switch {
			case strings.HasPrefix(line, "//"):
				// A comment quoting a call shape is prose, not a call site.
			case strings.HasPrefix(line, `case "`):
				pending = nil
				for _, m := range quoted.FindAllStringSubmatch(line, -1) {
					pending = append(pending, m[1])
				}
			case strings.Contains(line, "runHetznerServerAction(out") && !strings.HasPrefix(line, "func "):
				for _, v := range pending {
					sites = append(sites, hzReceiptSite{verb: v, file: path, line: i + 1, shape: hzShapeExecutor})
				}
				pending = nil
			case literalReceipt.MatchString(line) && !strings.HasPrefix(line, "func "):
				if m := quoted.FindStringSubmatch(line); m != nil {
					shape := hzShapeLiteral
					if strings.Contains(line, "hzFlagVerbDone(") {
						shape = hzShapeFlagVerb
					}
					sites = append(sites, hzReceiptSite{verb: m[1], file: path, line: i + 1, shape: shape})
				}
				pending = nil
			}
		}
	}
	return sites
}

// hzReceiptVerbsFromSource is the verb list the anti-undercount gate reads —
// the derived sites with their shapes dropped.
func hzReceiptVerbsFromSource(t *testing.T) []string {
	t.Helper()
	var verbs []string
	for _, s := range hzReceiptSitesFromSource(t) {
		verbs = append(verbs, s.verb)
	}
	return verbs
}

// TestHetznerActionVerbsAllDeclareAPostCondition is the anti-undercount gate:
// EVERY verb that reports a completed-verb receipt in ANY of this package's
// hetzner sources must declare what it re-reads — or declare, IN WORDS, why it
// has nothing to re-read — and neither map may carry entries for verbs that no
// longer exist. A verb added tomorrow, in any hetzner_*.go, fails here instead
// of silently shipping a receipt that asserts nothing.
func TestHetznerActionVerbsAllDeclareAPostCondition(t *testing.T) {
	sites := hzReceiptSitesFromSource(t)
	verbs := hzReceiptVerbsFromSource(t)
	// The census, printed under -v: what was DERIVED, from which files, in
	// which shape — the evidence that the population was counted and not
	// transcribed from a charter.
	t.Logf("derived %d receipt sites across %v:", len(sites), hzReceiptSourceFiles(t))
	for _, s := range sites {
		class := "BARE (neither keyed nor exempt)"
		if _, keyed := hzServerPostConditions[s.verb]; keyed {
			class = "keyed"
		}
		if _, exempt := hzServerPostConditionExemptions[s.verb]; exempt {
			class = "exempt"
		}
		if _, foreign := hzForeignPostConditions[s.verb]; foreign {
			class = "foreign post-condition"
		}
		t.Logf("  %-14s %-22s %s:%d — %s", s.verb, s.shape, s.file, s.line, class)
	}
	// The floor is a self-measurement guard, not a census: it only has to be
	// high enough that a scan which silently stopped finding call sites (a
	// renamed helper, a moved file) fails loudly instead of passing vacuously.
	// It is deliberately BELOW the measured count so adding a verb never has to
	// touch it — the keyed/exempt requirement below is what covers new verbs.
	const receiptFloor = 18
	if len(verbs) < receiptFloor {
		t.Fatalf("derived %d receipt verbs (%v) across %v — below the floor of %d. The scan measured 20 when it was "+
			"widened (9 through runHetznerServerAction, 4 through hzFlagVerbDone, 7 bare hzDone), so a count this "+
			"low means the SCAN stopped finding call sites — a renamed helper, a moved file, a changed call shape — "+
			"not that verbs were deleted. Re-derive before trusting anything below",
			len(verbs), verbs, hzReceiptSourceFiles(t), receiptFloor)
	}
	for _, verb := range verbs {
		post, keyed := hzServerPostConditions[verb]
		reason, exempt := hzServerPostConditionExemptions[verb]
		// THE THIRD CLASSIFICATION (pds-w26-create-image-image-postcondition):
		// a verb whose post-condition is real but lands on ANOTHER resource.
		// Before it existed create-image had to choose between claiming a
		// server field it never moves and declaring that nothing is re-read;
		// it now re-reads GET /images/<id>, so both of those are false.
		foreignRead, foreign := hzForeignPostConditions[verb]
		if n := hzClassCount(keyed, exempt, foreign); n > 1 {
			t.Errorf("`server %s` is classified %d ways at once (keyed=%t exempt=%t foreign=%t) — the three maps "+
				"make INCOMPATIBLE claims about what the receipt is built from, so at least one of them is a lie",
				verb, n, keyed, exempt, foreign)
		}
		switch {
		case exempt && keyed:
			// Already reported above; kept so the arms below stay exclusive.
		case foreign:
			if strings.TrimSpace(foreignRead) == "" {
				t.Errorf("`server %s` declares a post-condition on another resource with an empty description — "+
					"a foreign read nobody can name is indistinguishable from no read at all", verb)
			}
		case exempt:
			if strings.TrimSpace(reason) == "" {
				t.Errorf("`server %s` takes a post-condition exemption with an empty reason — "+
					"an exemption without an argument is just an omission wearing a map key", verb)
			}
		case !keyed:
			// TRUTH IN REFUSAL. These verbs do not share one receipt shape, so
			// the refusal may not claim they do: only the bare-hzDone sites
			// necessarily report a PRE-action server, while a verb whose srv is
			// itself a post-action read-back (resurrect, adopt) is guilty of
			// something narrower — asserting state nobody named. Say which.
			t.Errorf("`%s` reports a completed-verb receipt (%s) but declares neither a post-condition nor an "+
				"exemption — nothing states what its receipt is built from, so nobody can tell whether it "+
				"reports an OBSERVED state or the object resolved before the action fired", verb, hzShapesOf(sites, verb))
		}
		if !keyed {
			continue
		}
		if post.observe == nil {
			t.Errorf("`server %s` declares a post-condition with no observe() — the receipt would carry "+
				"only id and name, the two fields an action cannot change", verb)
		}
		if post.holds != nil && post.bindHolds != nil {
			t.Errorf("`server %s` declares both a static holds and a bindHolds — hzBoundPost would silently "+
				"overwrite one of them, so which predicate ran is unknowable", verb)
		}
		if post.holds != nil && post.unmet == nil {
			t.Errorf("`server %s` can fail its post-condition but has no sentence for saying so", verb)
		}
		if post.bindHolds != nil {
			holds, unmet := post.bindHolds("probe-ref")
			if holds == nil || unmet == nil {
				t.Errorf("`server %s` binds its post-condition to the requested ref but bindHolds returned "+
					"holds=%v unmet=%v — a bound predicate that can fail needs both", verb, holds != nil, unmet != nil)
			}
		}
	}
	declared := map[string]bool{}
	for _, v := range verbs {
		declared[v] = true
	}
	for verb := range hzServerPostConditions {
		if !declared[verb] {
			t.Errorf("hzServerPostConditions declares %q, which reports no verb receipt in any of %v — "+
				"a stale entry makes the map look more complete than it is", verb, hzReceiptSourceFiles(t))
		}
	}
	for verb := range hzServerPostConditionExemptions {
		if !declared[verb] {
			t.Errorf("hzServerPostConditionExemptions excuses %q, which reports no verb receipt in any of %v — "+
				"a stale exemption excuses nothing and hides the next verb that needs one", verb, hzReceiptSourceFiles(t))
		}
	}
	for verb := range hzForeignPostConditions {
		if !declared[verb] {
			t.Errorf("hzForeignPostConditions describes a read for %q, which reports no verb receipt in any of %v — "+
				"a stale entry describes a confirmation nothing performs", verb, hzReceiptSourceFiles(t))
		}
	}
}

// hzClassCount counts how many of the three post-condition classifications one
// verb claims. They are mutually exclusive by construction: keyed asserts a
// SERVER field, foreign asserts another resource, exempt asserts nothing is
// re-read at all.
func hzClassCount(keyed, exempt, foreign bool) int {
	n := 0
	for _, b := range []bool{keyed, exempt, foreign} {
		if b {
			n++
		}
	}
	return n
}

// hzShapesOf names the receipt shapes one verb emits, for refusal messages that
// have to be true about THAT verb rather than about the majority of verbs.
func hzShapesOf(sites []hzReceiptSite, verb string) string {
	seen := map[hzReceiptShape]bool{}
	var shapes []string
	for _, s := range sites {
		if s.verb == verb && !seen[s.shape] {
			seen[s.shape] = true
			shapes = append(shapes, string(s.shape))
		}
	}
	sort.Strings(shapes)
	return strings.Join(shapes, "+")
}

// TestHetznerPostConditionsAreExecutedNotJustDeclared is the anti-DISARM gate,
// and it is the half that makes the widening above worth shipping. The gate
// over the maps certifies MAP MEMBERSHIP: a verb passes it by acquiring a table
// entry, and the table is reached through exactly two receipt SHAPES —
// runHetznerServerAction and hzFlagVerbDone (three index expressions: those two
// plus hzActionObserved, a helper both of them call and nothing else does; the
// premise guard below counts the expressions, not the shapes, because an index
// added anywhere is what would invalidate this classification). A verb whose
// only receipt is a
// bare hzDone reaches NEITHER, so four table entries added without touching a
// single code path would turn the widened gate green while the four receipts
// stayed exactly as unverified as before.
//
// So: a keyed verb must emit its receipt through a shape that READS the table.
// A verb that re-reads on its own terms (archive's image read-back, resurrect's
// running+IPv4 poll) belongs in the exemptions map with that reason stated,
// where a reviewer can refuse the argument — never in the table, which would
// claim an execution path it does not take.
func TestHetznerPostConditionsAreExecutedNotJustDeclared(t *testing.T) {
	sites := hzReceiptSitesFromSource(t)
	consumers := map[hzReceiptShape]bool{hzShapeExecutor: true, hzShapeFlagVerb: true}

	// Guard the guard: the two consumers named above must still be the ONLY
	// readers of the table, or this test's premise has quietly expired.
	src, err := os.ReadFile(filepath.Join(".", "hetzner_cmd.go"))
	if err != nil {
		t.Fatalf("read hetzner_cmd.go: %v", err)
	}
	reads := 0
	for _, raw := range strings.Split(string(src), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "//") || strings.HasPrefix(line, "var hzServerPostConditions") {
			continue
		}
		if strings.Contains(line, "hzServerPostConditions[") {
			reads++
		}
	}
	if reads != 3 {
		t.Errorf("hzServerPostConditions is indexed at %d sites, not the 3 this gate knows about "+
			"(runHetznerServerAction, hzBoundPost via hzFlagVerbDone, hzActionObserved) — re-derive which shapes "+
			"EXECUTE a post-condition before trusting the shape classification below", reads)
	}

	byVerb := map[string][]hzReceiptShape{}
	for _, s := range sites {
		byVerb[s.verb] = append(byVerb[s.verb], s.shape)
	}
	for verb := range hzServerPostConditions {
		shapes, seen := byVerb[verb]
		if !seen {
			continue // the stale-entry arm of the gate above owns this case.
		}
		for _, shape := range shapes {
			if consumers[shape] {
				continue
			}
			t.Errorf("`%s` is keyed in hzServerPostConditions but reports its receipt through %s, which reads "+
				"neither hzServerPostConditions nor hzBoundPost — the post-condition is DECLARED and never RUN, "+
				"so the receipt asserts exactly what it asserted before the entry was added. Either route the verb "+
				"through runHetznerServerAction/hzFlagVerbDone, or state its own read-back in "+
				"hzServerPostConditionExemptions where the argument can be refused", verb, shape)
		}
	}
}

// hzActionFake stands up the common wire for one action verb: name resolution,
// the action POST, and the action poll. The caller adds the read-back.
func hzActionFake(t *testing.T, verb string) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /servers/42/actions/"+verb, func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":21,"status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":21,"status":"success","progress":100}]}`)
	})
	return f
}

// TestHetznerServerPoweronPollsToRunning covers shape A: `starting` is
// transient, so the verb polls, and the receipt carries the state it saw.
func TestHetznerServerPoweronPollsToRunning(t *testing.T) {
	f := hzActionFake(t, "poweron")
	f.mux.HandleFunc("GET /servers/42", hzServerStates(
		`{"id":42,"name":"web-1","status":"starting"}`,
		`{"id":42,"name":"web-1","status":"starting"}`,
		`{"id":42,"name":"web-1","status":"running"}`,
	))

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server", "poweron", "web-1")
	if code != exitOK {
		t.Fatalf("poweron exited %d, stderr: %s", code, stderr)
	}
	if n := f.count("GET", "/servers/42"); n < 3 {
		t.Errorf("poweron read the server back %d time(s); want a poll through the transient `starting`", n)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("poweron -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["status"] != "running" {
		t.Errorf("poweron receipt status = %v, want the observed `running`", payload["status"])
	}
}

// TestHetznerServerPoweronReportsAStateItNeverReached is the core anti-lie
// assertion: the action succeeds, the box never comes up, and the verb must NOT
// print the same ✓ it prints when the box does come up.
func TestHetznerServerPoweronReportsAStateItNeverReached(t *testing.T) {
	f := hzActionFake(t, "poweron")
	f.mux.HandleFunc("GET /servers/42", hzServerStates(`{"id":42,"name":"web-1","status":"off"}`))

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", "poweron", "web-1")
	if code == exitOK {
		t.Fatalf("poweron exited 0 with the server still off — the receipt claims a state it never re-read; stdout: %s", stdout)
	}
	if strings.Contains(stdout, "✓") {
		t.Errorf("stdout = %q carries a checkmark for a server that never came up", stdout)
	}
	if !strings.Contains(stderr, "still reports") || !strings.Contains(stderr, "off") {
		t.Errorf("stderr = %q, want the OBSERVED state named", stderr)
	}
	if n := f.count("GET", "/servers/42"); n < 2 {
		t.Errorf("poweron gave up after %d read(s) — the bound must be a poll, not a single shot", n)
	}
}

// TestHetznerServerShutdownIsAnHonestPartialOnTimeout covers shape D. ACPI needs
// the guest to react; a guest that has not reacted inside the window is a slow
// guest, not a failed verb. So: exit 0, no ✓, and a receipt that says exactly
// what was sent and what was observed.
func TestHetznerServerShutdownIsAnHonestPartialOnTimeout(t *testing.T) {
	f := hzActionFake(t, "shutdown")
	f.mux.HandleFunc("GET /servers/42", hzServerStates(`{"id":42,"name":"web-1","status":"running"}`))

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", "shutdown", "web-1")
	if code != exitOK {
		t.Fatalf("shutdown exited %d on a guest that simply had not reacted yet — a slow ACPI guest is not a failed verb; stderr: %s", code, stderr)
	}
	if strings.Contains(stdout, "✓") {
		t.Errorf("stdout = %q claims completion for a server still running", stdout)
	}
	for _, want := range []string{"signal sent", "has not powered off", "status: running"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout = %q, want the honest partial to contain %q", stdout, want)
		}
	}
	if n := f.count("GET", "/servers/42"); n < 2 {
		t.Errorf("shutdown read back %d time(s) — a SINGLE GetByID false-reds a healthy ACPI shutdown", n)
	}

	// …and the machine shape says so too.
	f2 := hzActionFake(t, "shutdown")
	f2.mux.HandleFunc("GET /servers/42", hzServerStates(`{"id":42,"name":"web-1","status":"running"}`))
	jsonOut, _, code2 := runHzCLI(t, "json", "hetzner", "server", "shutdown", "web-1")
	if code2 != exitOK {
		t.Fatalf("shutdown -o json exited %d", code2)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &payload); err != nil {
		t.Fatalf("shutdown -o json emitted invalid JSON: %v\n%s", err, jsonOut)
	}
	if payload["complete"] != false {
		t.Errorf("shutdown partial receipt complete = %v, want false", payload["complete"])
	}
}

// TestHetznerServerShutdownConfirmsOff is the same verb's happy path: the guest
// reacts and the receipt is a real ✓ carrying the observed `off`.
func TestHetznerServerShutdownConfirmsOff(t *testing.T) {
	f := hzActionFake(t, "shutdown")
	f.mux.HandleFunc("GET /servers/42", hzServerStates(
		`{"id":42,"name":"web-1","status":"running"}`,
		`{"id":42,"name":"web-1","status":"off"}`,
	))

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", "shutdown", "web-1")
	if code != exitOK {
		t.Fatalf("shutdown exited %d, stderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, "✓ shutdown") || !strings.Contains(stdout, "status: off") {
		t.Errorf("stdout = %q, want a ✓ carrying the observed `off`", stdout)
	}
}

// TestHetznerServerRebootNarrowsItsClaim covers shape C. hcloud.Server carries
// no boot time, so nothing distinguishes "rebooted" from "never went down" —
// the receipt must SAY that rather than assert a restart, and it must still move
// when the observed state moves (otherwise "✓ reboot" is vacuous again).
func TestHetznerServerRebootNarrowsItsClaim(t *testing.T) {
	up := hzActionFake(t, "reboot")
	up.mux.HandleFunc("GET /servers/42", hzServerStates(`{"id":42,"name":"web-1","status":"running"}`))
	cameUp, _, code := runHzCLI(t, "table", "hetzner", "server", "reboot", "web-1")
	if code != exitOK {
		t.Fatalf("reboot exited %d on a running server", code)
	}
	if !strings.Contains(cameUp, "does not confirm the OS restarted") {
		t.Errorf("reboot receipt = %q — it must name what it CANNOT confirm; there is no boot-time field to key on", cameUp)
	}

	down := hzActionFake(t, "reboot")
	down.mux.HandleFunc("GET /servers/42", hzServerStates(`{"id":42,"name":"web-1","status":"off"}`))
	stayedDown, _, code := runHzCLI(t, "table", "hetzner", "server", "reboot", "web-1")
	if code != exitOK {
		t.Fatalf("reboot exited %d — shape C has no discriminator, so it must not INVENT a failure either", code)
	}
	if cameUp == stayedDown {
		t.Fatalf("reboot printed BYTE-IDENTICAL output whether the machine came up or stayed down — "+
			"that is the defect this slice exists to kill.\ncame up:     %q\nstayed down: %q", cameUp, stayedDown)
	}
	if !strings.Contains(stayedDown, "status: off") {
		t.Errorf("reboot receipt for a machine that stayed down = %q, want the observed `off`", stayedDown)
	}
}

// TestHetznerServerMetadataVerbsReadTheFlipBack covers shape E: one read is
// enough, and enable-backup's window is information the owner cannot get any
// other way (the SDK's window argument is deprecated and ignored, so the SERVER
// picks it).
func TestHetznerServerMetadataVerbsReadTheFlipBack(t *testing.T) {
	for _, tc := range []struct {
		verb    string
		path    string
		readsAs string
		want    []string
	}{
		{"enable-backup", "enable_backup", `{"id":42,"name":"web-1","status":"running","backup_window":"22-02"}`,
			[]string{"backups_enabled: true", "backup_window: 22-02"}},
		{"disable-backup", "disable_backup", `{"id":42,"name":"web-1","status":"running"}`,
			[]string{"backups_enabled: false"}},
		{"disable-rescue", "disable_rescue", `{"id":42,"name":"web-1","status":"running","rescue_enabled":false}`,
			[]string{"rescue_enabled: false"}},
		{"detach-iso", "detach_iso", `{"id":42,"name":"web-1","status":"running"}`,
			[]string{"iso_attached: false"}},
	} {
		t.Run(tc.verb, func(t *testing.T) {
			f := hzActionFake(t, tc.path)
			f.mux.HandleFunc("GET /servers/42", hzServerStates(tc.readsAs))
			stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", tc.verb, "web-1")
			if code != exitOK {
				t.Fatalf("%s exited %d, stderr: %s", tc.verb, code, stderr)
			}
			if f.count("GET", "/servers/42") != 1 {
				t.Errorf("%s issued %d read-backs; a settled metadata flip needs exactly one", tc.verb, f.count("GET", "/servers/42"))
			}
			for _, want := range tc.want {
				if !strings.Contains(stdout, want) {
					t.Errorf("%s receipt = %q, want %q", tc.verb, stdout, want)
				}
			}
		})
	}
}

// TestHetznerServerMetadataFlipNotAppliedFails is the other half of shape E: the
// action reported success but the field did not move, so the verb must not ✓.
func TestHetznerServerMetadataFlipNotAppliedFails(t *testing.T) {
	f := hzActionFake(t, "detach_iso")
	f.mux.HandleFunc("GET /servers/42", hzServerStates(
		`{"id":42,"name":"web-1","status":"running","iso":{"id":5,"name":"virtio-win"}}`))

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", "detach-iso", "web-1")
	if code == exitOK {
		t.Fatalf("detach-iso exited 0 with the ISO still attached; stdout: %s", stdout)
	}
	if !strings.Contains(stderr, "still reports an ISO attached") {
		t.Errorf("stderr = %q, want the unmet post-condition named", stderr)
	}
}

// hzFlagVerbCase is one flag verb's whole conversation: the CLI args, the
// action the fake must answer, and the two read-backs that decide the receipt —
// one that AGREES with what was asked for and one that DISAGREES.
type hzFlagVerbCase struct {
	verb      string
	args      []string
	action    string
	agrees    string
	disagrees string
	want      []string // substrings the agreeing receipt must carry
	unwanted  []string // substrings it must NOT carry (request echoes)
	unmet     string   // the sentence the disagreeing run must print
}

func hzFlagVerbCases() []hzFlagVerbCase {
	return []hzFlagVerbCase{
		{
			verb:      "rebuild",
			args:      []string{"rebuild", "web-1", "--image", "ubuntu-24.04", "--yes"},
			action:    "rebuild",
			agrees:    `{"id":42,"name":"web-1","status":"running","image":{"id":7,"name":"ubuntu-24.04","description":"Ubuntu 24.04"}}`,
			disagrees: `{"id":42,"name":"web-1","status":"running","image":{"id":3,"name":"debian-12","description":"Debian 12"}}`,
			want:      []string{"image: ubuntu-24.04", "image_id: 7", "image_observed: true"},
			unmet:     `reports image "debian-12", not the requested "ubuntu-24.04"`,
		},
		{
			verb:      "resize",
			args:      []string{"resize", "web-1", "--type", "cpx21", "--upgrade-disk"},
			action:    "change_type",
			agrees:    `{"id":42,"name":"web-1","status":"running","server_type":{"id":22,"name":"cpx21"},"primary_disk_size":80}`,
			disagrees: `{"id":42,"name":"web-1","status":"running","server_type":{"id":11,"name":"cpx11"},"primary_disk_size":40}`,
			want:      []string{"server_type: cpx21", "server_type_id: 22", "primary_disk_size: 80"},
			// `--upgrade-disk` used to ride the receipt as a pure request echo.
			unwanted: []string{"upgrade_disk", "upgraded"},
			unmet:    `reports type "cpx11", not the requested "cpx21"`,
		},
		{
			verb:      "enable-rescue",
			args:      []string{"enable-rescue", "web-1"},
			action:    "enable_rescue",
			agrees:    `{"id":42,"name":"web-1","status":"running","rescue_enabled":true}`,
			disagrees: `{"id":42,"name":"web-1","status":"running","rescue_enabled":false}`,
			want:      []string{"rescue_enabled: true"},
			unmet:     "does not report rescue mode enabled",
		},
		{
			verb:      "attach-iso",
			args:      []string{"attach-iso", "web-1", "virtio-win"},
			action:    "attach_iso",
			agrees:    `{"id":42,"name":"web-1","status":"running","iso":{"id":5,"name":"virtio-win"}}`,
			disagrees: `{"id":42,"name":"web-1","status":"running"}`,
			want:      []string{"iso_attached: true", "iso: virtio-win"},
			unmet:     "reports no ISO attached",
		},
	}
}

// TestHetznerFlagVerbsReportTheServerTheyReadBack is the BEHAVIOURAL proof for
// the four flag verbs (PDS-D366) — a green post-condition map only proves a key
// exists. Each verb ran against a fake whose post-action GET AGREES with the
// request: the receipt must carry what that GET said, and the request echoes it
// used to print must be gone.
func TestHetznerFlagVerbsReportTheServerTheyReadBack(t *testing.T) {
	for _, tc := range hzFlagVerbCases() {
		t.Run(tc.verb, func(t *testing.T) {
			f := hzActionFake(t, tc.action)
			f.mux.HandleFunc("GET /servers/42", hzServerStates(tc.agrees))

			stdout, stderr, code := runHzCLI(t, "table", append([]string{"hetzner", "server"}, tc.args...)...)
			if code != exitOK {
				t.Fatalf("%s exited %d, stderr: %s", tc.verb, code, stderr)
			}
			if n := f.count("GET", "/servers/42"); n != 1 {
				t.Errorf("%s issued %d read-backs; a settled flag verb needs exactly one", tc.verb, n)
			}
			for _, want := range tc.want {
				if !strings.Contains(stdout, want) {
					t.Errorf("%s receipt = %q, want %q read off the POST-action server", tc.verb, stdout, want)
				}
			}
			for _, never := range tc.unwanted {
				if strings.Contains(stdout, never) {
					t.Errorf("%s receipt = %q, still carries the request echo %q", tc.verb, stdout, never)
				}
			}
		})
	}
}

// TestHetznerFlagVerbsFailWhenTheReadBackDisagrees is the other half: the same
// verb, the same action success, a post-action GET that DISAGREES with what was
// asked for — the receipt must differ, and it must not be a ✓.
func TestHetznerFlagVerbsFailWhenTheReadBackDisagrees(t *testing.T) {
	for _, tc := range hzFlagVerbCases() {
		t.Run(tc.verb, func(t *testing.T) {
			f := hzActionFake(t, tc.action)
			f.mux.HandleFunc("GET /servers/42", hzServerStates(tc.disagrees))

			stdout, stderr, code := runHzCLI(t, "table", append([]string{"hetzner", "server"}, tc.args...)...)
			if code == exitOK {
				t.Fatalf("%s exited 0 against a server that disagrees with the request; stdout: %s", tc.verb, stdout)
			}
			if !strings.Contains(stderr, tc.unmet) {
				t.Errorf("%s stderr = %q, want the unmet post-condition named (%q)", tc.verb, stderr, tc.unmet)
			}
			if strings.Contains(stdout, "✓") {
				t.Errorf("%s printed a ✓ (%q) while its post-condition did not hold", tc.verb, stdout)
			}
		})
	}
}

// TestHetznerServerRebuildUnreadableImageIsConfirmationUnavailable pins the
// asymmetry rebuild adds: a server that comes back with NO image is a
// confirmation we could not make, never a rebuild that failed. Exit 0, and the
// receipt says so instead of claiming an image.
func TestHetznerServerRebuildUnreadableImageIsConfirmationUnavailable(t *testing.T) {
	f := hzActionFake(t, "rebuild")
	f.mux.HandleFunc("GET /servers/42", hzServerStates(`{"id":42,"name":"web-1","status":"running"}`))

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server", "rebuild", "web-1", "--image", "ubuntu-24.04", "--yes")
	if code != exitOK {
		t.Fatalf("rebuild exited %d because the image could not be READ — the action itself succeeded; stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("rebuild -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["confirmation"] != "unavailable" {
		t.Errorf("receipt confirmation = %v, want \"unavailable\"", payload["confirmation"])
	}
	if _, claimed := payload["image"]; claimed {
		t.Errorf("receipt claims image %v it never read back", payload["image"])
	}
}

// TestHetznerServerReadBackErrorIsConfirmationUnavailable pins the hazard the
// fix introduces. Every post-condition read is a NEW way for a verb to fail
// where it previously could not: a rate-limited or otherwise erroring GetByID
// after a SUCCESSFUL reboot must never tell the owner the reboot failed. That is
// the same lie pointing the other way.
func TestHetznerServerReadBackErrorIsConfirmationUnavailable(t *testing.T) {
	f := hzActionFake(t, "reboot")
	f.mux.HandleFunc("GET /servers/42", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 403, `{"error":{"code":"forbidden","message":"token is read-only"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server", "reboot", "web-1")
	if code != exitOK {
		t.Fatalf("reboot exited %d because the CONFIRMING read failed — the action itself succeeded and was waited to success; stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("reboot -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if payload["confirmation"] != "unavailable" {
		t.Errorf("receipt confirmation = %v, want \"unavailable\" — the receipt must distinguish "+
			"'action succeeded, could not confirm' from 'post-condition not met'", payload["confirmation"])
	}
	if msg, _ := payload["confirmation_error"].(string); !strings.Contains(msg, "read-only") {
		t.Errorf("receipt confirmation_error = %v, want the read failure surfaced", payload["confirmation_error"])
	}
	if _, claimed := payload["status"]; claimed {
		t.Errorf("receipt carries an observed status (%v) it never successfully read", payload["status"])
	}
}

// TestHetznerServerActionFailureSurfaces asserts a FAILED action is reported
// as an error, not swallowed as success.
func TestHetznerServerActionFailureSurfaces(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("POST /servers/42/actions/reboot", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":22,"status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":22,"status":"error","progress":100,"error":{"code":"server_error","message":"hypervisor exploded"}}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server", "reboot", "web-1")
	if code == exitOK {
		t.Fatalf("reboot exited 0 despite a failed action; stdout: %s", stdout)
	}
	if !strings.Contains(stderr, "hypervisor exploded") {
		t.Errorf("stderr = %q, want the action's failure message surfaced", stderr)
	}
	if strings.Contains(stdout, "✓") {
		t.Errorf("stdout = %q claims success on a failed action", stdout)
	}
}

// TestHetznerSSHKeyCreate asserts the POST /ssh_keys body — including the
// --public-key-file read — and the structured receipt.
func TestHetznerSSHKeyCreate(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("POST /ssh_keys", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"ssh_key":{"id":7,"name":"deploy-key","fingerprint":"aa:bb:cc","public_key":"ssh-ed25519 AAAA test"}}`)
	})

	keyPath := filepath.Join(t.TempDir(), "id_ed25519.pub")
	if err := writeTempFile(keyPath, "ssh-ed25519 AAAA test\n"); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "ssh-key", "create", "--name", "deploy-key", "--public-key-file", keyPath)
	if code != exitOK {
		t.Fatalf("ssh-key create exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/ssh_keys")
	if !ok {
		t.Fatal("no POST /ssh_keys was issued")
	}
	if req.Body["name"] != "deploy-key" {
		t.Errorf("create body name = %v, want deploy-key", req.Body["name"])
	}
	if req.Body["public_key"] != "ssh-ed25519 AAAA test" {
		t.Errorf("create body public_key = %v, want the trimmed file content", req.Body["public_key"])
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("ssh-key create -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	key, _ := payload["ssh_key"].(map[string]any)
	if payload["ok"] != true || key["id"] != float64(7) || key["fingerprint"] != "aa:bb:cc" {
		t.Errorf("receipt = %v, want ok=true ssh_key.id=7 fingerprint=aa:bb:cc", payload)
	}
}

// TestHetznerServerTypesTable asserts the discovery read hits GET
// /server_types and renders an aligned, human-readable table.
func TestHetznerServerTypesTable(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /server_types", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server_types":[
			{"id":1,"name":"cx22","description":"CX22","cores":2,"memory":4,"disk":40,"storage_type":"local","cpu_type":"shared","architecture":"x86"},
			{"id":2,"name":"cax11","description":"CAX11","cores":2,"memory":4,"disk":40,"storage_type":"local","cpu_type":"shared","architecture":"arm"}
		]}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server-types")
	if code != exitOK {
		t.Fatalf("server-types exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("GET", "/server_types"); !ok {
		t.Fatal("no GET /server_types was issued")
	}
	lines := strings.Split(strings.TrimRight(stdout, "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("table has %d lines, want header + 2 rows:\n%s", len(lines), stdout)
	}
	if !strings.HasPrefix(lines[0], "ID  NAME") || !strings.Contains(lines[0], "CORES") || !strings.Contains(lines[0], "ARCH") {
		t.Errorf("header = %q, want ID/NAME/CORES/…/ARCH columns", lines[0])
	}
	if !strings.Contains(lines[1], "cx22") || !strings.Contains(lines[1], "4 GB") || !strings.Contains(lines[1], "x86") {
		t.Errorf("row = %q, want cx22 with 4 GB memory and x86", lines[1])
	}
	// Alignment: both rows start their NAME column at the same rune offset.
	if strings.Index(lines[1], "cx22") != strings.Index(lines[2], "cax11") {
		t.Errorf("columns misaligned:\n%s", stdout)
	}
}

// TestHetznerServerListJSON asserts the -o json list shape (the contract
// scripts consume) straight off GET /servers.
func TestHetznerServerListJSON(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[
			{"id":1,"name":"web-1","status":"running","server_type":{"id":1,"name":"cx22"},"public_net":{"ipv4":{"ip":"192.0.2.1"}},"labels":{"env":"prod"}},
			{"id":2,"name":"web-2","status":"off","server_type":{"id":1,"name":"cx22"},"public_net":{}}
		]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server", "list")
	if code != exitOK {
		t.Fatalf("server list exited %d, stderr: %s", code, stderr)
	}
	var payload struct {
		Servers []map[string]any `json:"servers"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("server list -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if len(payload.Servers) != 2 {
		t.Fatalf("servers = %d rows, want 2", len(payload.Servers))
	}
	first := payload.Servers[0]
	if first["id"] != float64(1) || first["name"] != "web-1" || first["status"] != "running" ||
		first["type"] != "cx22" || first["ipv4"] != "192.0.2.1" {
		t.Errorf("row = %v, want id/name/status/type/ipv4 populated", first)
	}
	if _, hasIP := payload.Servers[1]["ipv4"]; hasIP {
		t.Errorf("row without a public IP still carries ipv4: %v", payload.Servers[1])
	}
}

// TestHetznerImagesTypeFilter asserts --type rides as the server-side query
// filter, not a client-side afterthought.
func TestHetznerImagesTypeFilter(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /images", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"images":[{"id":9,"description":"nightly","type":"snapshot","status":"available","architecture":"x86"}]}`)
	})

	_, stderr, code := runHzCLI(t, "json", "hetzner", "images", "--type", "snapshot")
	if code != exitOK {
		t.Fatalf("images exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("GET", "/images")
	if !ok {
		t.Fatal("no GET /images was issued")
	}
	if !strings.Contains(req.Query, "type=snapshot") {
		t.Errorf("images query = %q, want type=snapshot server-side", req.Query)
	}
}

// TestHetznerServerNotFound asserts the clean miss: exit 4 and a message that
// names the target and points at list.
func TestHetznerServerNotFound(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[]}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "poweroff", "ghost")
	if code != exitNotFound {
		t.Fatalf("poweroff of an absent server exited %d, want %d", code, exitNotFound)
	}
	if !strings.Contains(stderr, `server "ghost" not found`) {
		t.Errorf("stderr = %q, want the named not-found message", stderr)
	}
	for _, r := range f.requests() {
		if r.Method == http.MethodPost {
			t.Errorf("a missing server still issued %s %s", r.Method, r.Path)
		}
	}
}

// TestHetznerNoToken asserts the empty-ladder error: no flag, no env, no
// hcloud context → exit 3 with the remediation ladder in the message.
func TestHetznerNoToken(t *testing.T) {
	t.Setenv("HCLOUD_TOKEN", "")
	t.Setenv("HCLOUD_CONFIG", filepath.Join(t.TempDir(), "no-such-cli.toml"))

	_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "list")
	if code != exitAuth {
		t.Fatalf("no-token exited %d, want %d", code, exitAuth)
	}
	for _, hint := range []string{"--token", "HCLOUD_TOKEN", "hcloud context"} {
		if !strings.Contains(stderr, hint) {
			t.Errorf("stderr = %q, missing the %s rung of the ladder", stderr, hint)
		}
	}
}

// TestHetznerTokenFlagWins asserts --token outranks HCLOUD_TOKEN on the wire.
func TestHetznerTokenFlagWins(t *testing.T) {
	f := newFakeHzAPI(t) // sets HCLOUD_TOKEN=test-token
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[]}`)
	})

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{token: "flag-token", output: "json", outputSet: true}
	w.applyGlobals(g)
	if code := runCloud(w, g, []string{"hetzner", "server", "list"}); code != exitOK {
		t.Fatalf("list exited %d, stderr: %s", code, stderr.String())
	}
	req, ok := f.find("GET", "/servers")
	if !ok {
		t.Fatal("no GET /servers was issued")
	}
	if req.Auth != "Bearer flag-token" {
		t.Errorf("Authorization = %q, want the --token flag to win over HCLOUD_TOKEN", req.Auth)
	}
}

// TestHetznerUnknownResource asserts the usage miss path exits 2 with help.
func TestHetznerUnknownResource(t *testing.T) {
	_, stderr, code := runHzCLI(t, "table", "hetzner", "buckets")
	if code != exitUsage {
		t.Fatalf("unknown resource exited %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr, `unknown hetzner resource "buckets"`) {
		t.Errorf("stderr = %q, want the unknown-resource message", stderr)
	}
}

// TestHetznerUnknownResourceJSON: an unknown resource under -o json emits the
// shared {ok:false,error:{code,message}} envelope on stdout (exit 2) with a
// clean stderr — never a help wall a `2>/dev/null` can't silence, and never
// non-JSON bytes an `| jq` would choke on.
func TestHetznerUnknownResourceJSON(t *testing.T) {
	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "buckets")
	if code != exitUsage {
		t.Fatalf("unknown resource exited %d, want %d", code, exitUsage)
	}
	if strings.TrimSpace(stderr) != "" {
		t.Errorf("stderr = %q, want clean stderr under -o json", stderr)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a parseable JSON envelope: %v\n%s", err, stdout)
	}
	if ok, _ := env["ok"].(bool); ok {
		t.Fatalf("ok = %v, want false", env["ok"])
	}
	errObj, _ := env["error"].(map[string]any)
	if errObj["code"] != "usage" {
		t.Fatalf("error.code = %v, want usage (%v)", errObj["code"], env)
	}
	if msg, _ := errObj["message"].(string); !strings.Contains(msg, "buckets") {
		t.Fatalf("error.message = %q, want the unknown-resource message", msg)
	}
}

// TestHetznerMissingVerbJSON: a group with no verb (here `server`) under -o json
// is the same structured usage error — the no-verb branch no longer dumps the
// help wall to stdout with exit 2.
func TestHetznerMissingVerbJSON(t *testing.T) {
	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server")
	if code != exitUsage {
		t.Fatalf("missing verb exited %d, want %d", code, exitUsage)
	}
	if strings.TrimSpace(stderr) != "" {
		t.Errorf("stderr = %q, want clean stderr under -o json", stderr)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a parseable JSON envelope: %v\n%s", err, stdout)
	}
	if ok, _ := env["ok"].(bool); ok {
		t.Fatalf("ok = %v, want false", env["ok"])
	}
	errObj, _ := env["error"].(map[string]any)
	if errObj["code"] != "usage" {
		t.Fatalf("error.code = %v, want usage (%v)", errObj["code"], env)
	}
}

// TestHetznerHelp asserts -h renders the namespace help (exit 0) at both the
// provider and resource levels.
func TestHetznerHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{help: true, output: "table", outputSet: true}
	w.applyGlobals(g)
	if code := runCloud(w, g, []string{"hetzner"}); code != exitOK {
		t.Fatalf("hetzner -h exited %d, stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "bp cloud hetzner <resource> <verb>") {
		t.Errorf("namespace help = %q, want the usage line", stdout.String())
	}

	stdout.Reset()
	w2 := newWriter(&stdout, &stderr)
	w2.applyGlobals(g)
	if code := runCloud(w2, g, []string{"hetzner", "server"}); code != exitOK {
		t.Fatalf("server -h exited %d", code)
	}
	if !strings.Contains(stdout.String(), "enable-rescue") || !strings.Contains(stdout.String(), "create --name") {
		t.Errorf("server help = %q, want the verb list", stdout.String())
	}
}

// TestRenderHzTableWideGlyphAlignment guards the renderHzTable width math
// against double-width glyphs. A CJK server name is one rune per ideograph but
// two terminal cells wide; a byte/rune width would under-pad it and shear every
// column after it. The second column must therefore begin at the same display
// offset on every row.
func TestRenderHzTableWideGlyphAlignment(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	rows := [][]string{
		{"数据库", "running"}, // wide (CJK): 3 runes, 6 display cells
		{"web-01", "running"},
	}
	renderHzTable(w, []string{"NAME", "STATUS"}, rows)

	lines := strings.Split(strings.TrimRight(stdout.String(), "\n"), "\n")
	if len(lines) != 3 { // header + 2 rows
		t.Fatalf("expected 3 lines, got %d: %q", len(lines), stdout.String())
	}
	// The STATUS column starts right after the padded NAME cell + 2-space gutter.
	// Measure the display width of each line's prefix up to its second-column
	// value — it must match across all three lines regardless of the CJK glyph.
	secondCol := []string{"STATUS", "running", "running"}
	want := -1
	for i, ln := range lines {
		idx := strings.Index(ln, secondCol[i])
		if idx < 0 {
			t.Fatalf("line %q missing second column %q", ln, secondCol[i])
		}
		got := runewidth.StringWidth(ln[:idx])
		if want < 0 {
			want = got
		} else if got != want {
			t.Errorf("STATUS column offset drift: line %q starts at cell %d, want %d", ln, got, want)
		}
	}
}

// TestRenderHzTableClampsLongCells guards the cellMaxRunes clamp: renderHzTable
// (like table.go's renderRows) must truncate a long cell so one server
// description, DNS TXT record, or label can't shear every row past the terminal.
// The long cell mixes CJK (each ideograph is one rune but two display cells) so
// the clamp is exercised on display width, not rune count.
func TestRenderHzTableClampsLongCells(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	// A cell far over the 60-cell budget: ASCII prefix + 60 CJK ideographs
	// (120 display cells) so a rune-count cap wouldn't bound the display width.
	long := "desc-" + strings.Repeat("中", 60)
	rows := [][]string{
		{"srv-01", long},
		{"srv-02", "small"},
	}
	renderHzTable(w, []string{"NAME", "NOTE"}, rows)

	lines := strings.Split(strings.TrimRight(stdout.String(), "\n"), "\n")
	if len(lines) != 3 { // header + 2 rows
		t.Fatalf("expected 3 lines, got %d: %q", len(lines), stdout.String())
	}
	// (a) The long cell is rendered truncated with the "..." suffix.
	if strings.Contains(stdout.String(), long) {
		t.Errorf("long cell was not truncated:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "...") {
		t.Errorf("expected the clamped cell to end in \"...\":\n%s", stdout.String())
	}
	// (b) No line exceeds the header + clamped-cell display budget: the NAME
	// column is at most len("srv-01")=6, the NOTE column at most cellMaxRunes,
	// plus a 2-cell gutter.
	max := 6 + 2 + cellMaxRunes
	for _, ln := range lines {
		if wdt := runewidth.StringWidth(ln); wdt > max {
			t.Errorf("line exceeds clamped budget (%d cells, max %d), clamp not bounding it:\n%q",
				wdt, max, ln)
		}
	}
	// The short sibling row still aligns: its NOTE value sits at the same display
	// offset as the header's NOTE column.
	noteCol := []string{"NOTE", "", "small"}
	want := -1
	for i, ln := range lines {
		if noteCol[i] == "" {
			continue // the truncated long row: value is variable, offset checked via (b)
		}
		idx := strings.Index(ln, noteCol[i])
		if idx < 0 {
			t.Fatalf("line %q missing NOTE column %q", ln, noteCol[i])
		}
		got := runewidth.StringWidth(ln[:idx])
		if want < 0 {
			want = got
		} else if got != want {
			t.Errorf("NOTE column offset drift: line %q starts at cell %d, want %d", ln, got, want)
		}
	}
}

// writeTempFile is a tiny helper so the test body reads linearly.
func writeTempFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}

// hzCreateImageFake stands up the create-image wire: name resolution, the
// snapshot POST whose response ECHOES an image, and the action poll. The
// caller adds GET /images/9 — the read-back this row exists for.
func hzCreateImageFake(t *testing.T) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	// The RESPONSE ECHO: the create action hands back an image that already
	// claims to be available with the description that was requested. Every
	// assertion below is about the receipt NOT being built from this.
	f.mux.HandleFunc("POST /servers/42/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"image":{"id":9,"description":"nightly","status":"available","type":"snapshot"},
			"action":{"id":21,"status":"running","progress":0}
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":21,"status":"success","progress":100}]}`)
	})
	return f
}

// TestHetznerCreateImageReportsTheImageItReRead is the behavioural half of
// pds-w26-create-image-image-postcondition. The fake's GET /images/9
// DISAGREES with the CreateImage response on every field that matters, so a
// receipt built from the echo and a receipt built from the read-back cannot
// print the same thing. Before this row they did.
func TestHetznerCreateImageReportsTheImageItReRead(t *testing.T) {
	f := hzCreateImageFake(t)
	f.mux.HandleFunc("GET /images/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"image":{"id":9,"description":"nightly (server side)","status":"creating","type":"snapshot"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "server", "create-image", "web-1", "--description", "nightly")
	if code != exitOK {
		t.Fatalf("create-image exited %d, stderr: %s", code, stderr)
	}
	if f.count("GET", "/images/9") == 0 {
		t.Fatalf("no GET /images/9 was issued — the receipt is still the CreateImage response echo. requests: %v",
			f.requests())
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("create-image receipt is not JSON (%v): %s", err, stdout)
	}
	// The OBSERVED status, not the response's "available".
	if got := payload["image_status"]; got != "creating" {
		t.Errorf("image_status = %v, want %q — the receipt is not reporting what GET /images/9 said", got, "creating")
	}
	if got := payload["image_description"]; got != "nightly (server side)" {
		t.Errorf("image_description = %v, want the OBSERVED %q (the request asked for %q)",
			got, "nightly (server side)", "nightly")
	}
	// CARRIED CRITERION: a fresh image reports `creating`, and NOTHING in the
	// receipt may imply the snapshot is usable.
	if got, ok := payload["image_ready"].(bool); !ok || got {
		t.Errorf("image_ready = %v, want false — a `creating` snapshot cannot be restored from, so a receipt that "+
			"omits this or reports true tells an operator the opposite of what the API said", payload["image_ready"])
	}
	if payload["confirmation"] != nil {
		t.Errorf("confirmation = %v, want absent — the read-back SUCCEEDED; `creating` is an observed state, "+
			"not a failure to observe", payload["confirmation"])
	}
	t.Logf("OBSERVED RECEIPT %v", payload)
}

// TestHetznerCreateImageAvailableImageReadsReady is the other side of the
// image_ready discrimination: without it, a test suite that only ever saw
// `creating` could not tell a receipt that reports readiness honestly from one
// that hardcodes false.
func TestHetznerCreateImageAvailableImageReadsReady(t *testing.T) {
	f := hzCreateImageFake(t)
	f.mux.HandleFunc("GET /images/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"image":{"id":9,"description":"nightly","status":"available","type":"snapshot"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "server", "create-image", "web-1", "--description", "nightly")
	if code != exitOK {
		t.Fatalf("create-image exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("create-image receipt is not JSON (%v): %s", err, stdout)
	}
	if got, ok := payload["image_ready"].(bool); !ok || !got {
		t.Errorf("image_ready = %v, want true for an image GET /images/9 reports as available", payload["image_ready"])
	}
	if got := payload["image_status"]; got != "available" {
		t.Errorf("image_status = %v, want available", got)
	}
}

// TestHetznerCreateImageUnreadableImageIsConfirmationUnavailable pins the
// escape: the action was fired AND waited to success, so a failed CONFIRMING
// read is not a failed verb. Exit 0, the two hzFlagVerbDone keys, and no claim
// about the image's state.
func TestHetznerCreateImageUnreadableImageIsConfirmationUnavailable(t *testing.T) {
	f := hzCreateImageFake(t)
	f.mux.HandleFunc("GET /images/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 500, `{"error":{"code":"service_error","message":"images unavailable"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json",
		"hetzner", "server", "create-image", "web-1", "--description", "nightly")
	if code != exitOK {
		t.Fatalf("create-image exited %d (want 0 — only the CONFIRMING read failed), stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("create-image receipt is not JSON (%v): %s", err, stdout)
	}
	if payload["confirmation"] != "unavailable" {
		t.Errorf("confirmation = %v, want %q — the same key hzFlagVerbDone sets when the read-back fails",
			payload["confirmation"], "unavailable")
	}
	if s, _ := payload["confirmation_error"].(string); s == "" {
		t.Errorf("confirmation_error is empty — an unavailable confirmation that does not say WHY is a shrug")
	}
	// NOTHING may be claimed about a state nobody could read.
	for _, key := range []string{"image_status", "image_description", "image_ready"} {
		if _, present := payload[key]; present {
			t.Errorf("%s = %v is present on a receipt whose read-back FAILED — a value nobody observed is exactly "+
				"the request echo this row deleted", key, payload[key])
		}
	}
	if payload["image_id"] == nil {
		t.Errorf("image_id is absent — the id is the operator's only handle on the snapshot and it came from the " +
			"action response, which did happen")
	}
	t.Logf("UNCONFIRMED RECEIPT %v", payload)
}

// TestHetznerCreateImageDeclaresAForeignPostCondition asserts the DATA half:
// create-image no longer excuses itself, and the map that now describes it says
// which read it performs.
func TestHetznerCreateImageDeclaresAForeignPostCondition(t *testing.T) {
	if reason, exempt := hzServerPostConditionExemptions["create-image"]; exempt {
		t.Errorf("create-image still takes a post-condition EXEMPTION (%q) — it re-reads GET /images/<id> now, "+
			"so the exemption is false", reason)
	}
	read, foreign := hzForeignPostConditions["create-image"]
	if !foreign {
		t.Fatalf("create-image declares no foreign post-condition — the derivation gate would then read it as a " +
			"verb that states nothing about what its receipt is built from")
	}
	if !strings.Contains(read, "/images/") {
		t.Errorf("the create-image foreign post-condition does not name the read it performs: %q", read)
	}
}
