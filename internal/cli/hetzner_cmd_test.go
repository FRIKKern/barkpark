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
	"strings"
	"sync"
	"testing"
	"time"

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
// POST …/actions/poweroff, and the poll of the still-running action.
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
	if !strings.Contains(stdout, "✓ poweroff — server web-1 (id 42)") {
		t.Errorf("poweroff output = %q, want the ✓ receipt line", stdout)
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

// writeTempFile is a tiny helper so the test body reads linearly.
func writeTempFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}
