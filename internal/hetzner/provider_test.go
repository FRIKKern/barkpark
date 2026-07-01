package hetzner

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// fakeHetzner is an httptest stand-in for api.hetzner.cloud: a mux the tests
// register JSON handlers on, plus a recorder of every request (method, path,
// query, decoded body) so assertions read the REAL wire shapes the SDK sent.
type fakeHetzner struct {
	t   *testing.T
	mux *http.ServeMux
	srv *httptest.Server

	mu   sync.Mutex
	reqs []recordedReq
}

type recordedReq struct {
	Method string
	Path   string
	Query  string
	Body   map[string]any
	Auth   string
}

func newFakeHetzner(t *testing.T) *fakeHetzner {
	t.Helper()
	f := &fakeHetzner{t: t, mux: http.NewServeMux()}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := recordedReq{
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
	return f
}

func (f *fakeHetzner) provider() *APIProvider {
	return NewAPIProvider(NewClient("test-token",
		WithEndpoint(f.srv.URL),
		WithPollBackoff(time.Millisecond),
	))
}

// requests returns a snapshot of everything the SDK sent.
func (f *fakeHetzner) requests() []recordedReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recordedReq(nil), f.reqs...)
}

func (f *fakeHetzner) find(method, path string) (recordedReq, bool) {
	for _, r := range f.requests() {
		if r.Method == method && r.Path == path {
			return r, true
		}
	}
	return recordedReq{}, false
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = fmt.Fprint(w, body)
}

// TestCreate asserts the FULL create conversation: the ssh-key lookup, the
// POST /servers body (name/type/image/location/ssh_keys/labels incl.
// barkpark-managed=true), the action POLL to completion, and the returned IP.
func TestCreate(t *testing.T) {
	t.Setenv("BARKPARK_SSH_KEY", "deploy-key")
	f := newFakeHetzner(t)

	f.mux.HandleFunc("GET /ssh_keys", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "deploy-key" {
			t.Errorf("ssh_keys lookup name = %q, want deploy-key", got)
		}
		writeJSON(w, 200, `{"ssh_keys":[{"id":7,"name":"deploy-key","fingerprint":"","public_key":""}]}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		// Return the action still RUNNING so the provider must poll — a fake
		// that returns success immediately would make the wait vacuous.
		writeJSON(w, 201, `{
			"server":{"id":42,"name":"web-1","status":"initializing","public_net":{"ipv4":{"ip":"192.0.2.10"}},"labels":{"barkpark-managed":"true"}},
			"action":{"id":11,"command":"create_server","status":"running","progress":0},
			"next_actions":[]
		}`)
	})
	var polls int
	var pollMu sync.Mutex
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		pollMu.Lock()
		polls++
		pollMu.Unlock()
		if got := r.URL.Query()["id"]; len(got) != 1 || got[0] != "11" {
			t.Errorf("action poll ids = %v, want [11]", got)
		}
		writeJSON(w, 200, `{"actions":[{"id":11,"command":"create_server","status":"success","progress":100}]}`)
	})

	srv, err := f.provider().Create(context.Background(), cloud.ServerSpec{
		Name: "web-1", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if srv.Name != "web-1" || srv.IP != "192.0.2.10" || srv.ID != "42" {
		t.Errorf("Create returned %+v, want name=web-1 ip=192.0.2.10 id=42", srv)
	}

	// The create request carried the right body.
	req, ok := f.find("POST", "/servers")
	if !ok {
		t.Fatal("no POST /servers was issued")
	}
	if req.Auth != "Bearer test-token" {
		t.Errorf("Authorization = %q, want Bearer test-token", req.Auth)
	}
	for field, want := range map[string]any{
		"name": "web-1", "server_type": "cx23", "image": "ubuntu-22.04", "location": "nbg1",
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
	if labels[cloud.ManagedLabelKey] != "true" {
		t.Errorf("create body labels = %v, want %s=true", labels, cloud.ManagedLabelKey)
	}

	// The running action WAS polled to completion.
	pollMu.Lock()
	defer pollMu.Unlock()
	if polls == 0 {
		t.Error("Create never polled the running action")
	}
}

// TestCreateNumericImageSendsSnapshotID asserts a numeric BARKPARK-style image
// (a snapshot id) rides as an integer, not a name string.
func TestCreateNumericImageSendsSnapshotID(t *testing.T) {
	t.Setenv("BARKPARK_SSH_KEY", "deploy-key")
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /ssh_keys", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"ssh_keys":[{"id":7,"name":"deploy-key"}]}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 201, `{
			"server":{"id":43,"name":"web-2","status":"initializing","public_net":{"ipv4":{"ip":"192.0.2.11"}}},
			"action":{"id":12,"status":"success","progress":100},
			"next_actions":[]
		}`)
	})

	if _, err := f.provider().Create(context.Background(), cloud.ServerSpec{
		Name: "web-2", Region: "nbg1", ServerType: "cx23", Image: "324589431",
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	req, ok := f.find("POST", "/servers")
	if !ok {
		t.Fatal("no POST /servers was issued")
	}
	if got := req.Body["image"]; got != float64(324589431) {
		t.Errorf("create body image = %v (%T), want the numeric snapshot id 324589431", got, got)
	}
}

// TestCreateFailedWaitDeletesOrphan asserts the no-billed-orphan guarantee:
// when the create action FAILS after the box exists, the provider deletes the
// just-created box before surfacing the error.
func TestCreateFailedWaitDeletesOrphan(t *testing.T) {
	t.Setenv("BARKPARK_SSH_KEY", "deploy-key")
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /ssh_keys", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"ssh_keys":[{"id":7,"name":"deploy-key"}]}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 201, `{
			"server":{"id":44,"name":"web-3","status":"initializing","public_net":{"ipv4":{"ip":"192.0.2.12"}}},
			"action":{"id":13,"status":"running","progress":0},
			"next_actions":[]
		}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"actions":[{"id":13,"status":"error","progress":100,"error":{"code":"server_error","message":"boom"}}]}`)
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"servers":[{"id":44,"name":"web-3","status":"initializing","public_net":{"ipv4":{"ip":"192.0.2.12"}}}]}`)
	})
	f.mux.HandleFunc("DELETE /servers/44", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"action":{"id":14,"status":"success","progress":100}}`)
	})

	_, err := f.provider().Create(context.Background(), cloud.ServerSpec{
		Name: "web-3", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04",
	})
	if err == nil {
		t.Fatal("Create succeeded despite a failed create action")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error %q does not surface the action's failure", err)
	}
	if _, ok := f.find("DELETE", "/servers/44"); !ok {
		t.Error("failed create did NOT delete the orphan box (billed leak)")
	}
}

// TestIP asserts the by-name lookup and IPv4 read-back.
func TestIP(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("name"); got != "web-1" {
			t.Errorf("server lookup name = %q, want web-1", got)
		}
		writeJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	ip, err := f.provider().IP(context.Background(), "web-1")
	if err != nil {
		t.Fatalf("IP: %v", err)
	}
	if ip != "192.0.2.10" {
		t.Errorf("IP = %q, want 192.0.2.10", ip)
	}
}

// TestDeleteIsIdempotent asserts BOTH not-found tolerances: an unknown name is
// a no-op (no DELETE ever issued), and a 404 on the DELETE itself (a lost
// race) is swallowed.
func TestDeleteIsIdempotent(t *testing.T) {
	t.Run("unknown name", func(t *testing.T) {
		f := newFakeHetzner(t)
		f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, 200, `{"servers":[]}`)
		})
		if err := f.provider().Delete(context.Background(), "gone"); err != nil {
			t.Fatalf("Delete of an absent server errored: %v", err)
		}
		for _, r := range f.requests() {
			if r.Method == http.MethodDelete {
				t.Errorf("Delete of an absent server issued %s %s", r.Method, r.Path)
			}
		}
	})
	t.Run("404 on the delete call", func(t *testing.T) {
		f := newFakeHetzner(t)
		f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
		})
		f.mux.HandleFunc("DELETE /servers/42", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, 404, `{"error":{"code":"not_found","message":"server not found"}}`)
		})
		if err := f.provider().Delete(context.Background(), "web-1"); err != nil {
			t.Fatalf("Delete racing a 404 errored: %v", err)
		}
	})
}

// TestDelete asserts the happy path: lookup by name, DELETE by id, wait the
// returned action.
func TestDelete(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}]}`)
	})
	f.mux.HandleFunc("DELETE /servers/42", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"action":{"id":15,"status":"success","progress":100}}`)
	})
	if err := f.provider().Delete(context.Background(), "web-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok := f.find("DELETE", "/servers/42"); !ok {
		t.Error("no DELETE /servers/42 was issued")
	}
}

// TestListByLabel asserts the label selector goes over the wire server-side
// and the labels ride back on the result (SweepOrphans reads barkpark-fqdn off
// them).
func TestListByLabel(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("label_selector"); got != "barkpark-orphaned=true" {
			t.Errorf("label_selector = %q, want barkpark-orphaned=true", got)
		}
		writeJSON(w, 200, `{"servers":[{"id":9,"name":"dead-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.9"}},"labels":{"barkpark-orphaned":"true","barkpark-fqdn":"dead-1.barkpark.cloud"}}]}`)
	})
	servers, err := f.provider().ListByLabel(context.Background(), cloud.OrphanedLabelKey, "true")
	if err != nil {
		t.Fatalf("ListByLabel: %v", err)
	}
	if len(servers) != 1 {
		t.Fatalf("ListByLabel returned %d servers, want 1", len(servers))
	}
	got := servers[0]
	if got.Name != "dead-1" || got.IP != "192.0.2.9" {
		t.Errorf("server = %+v, want name=dead-1 ip=192.0.2.9", got)
	}
	if got.Labels[cloud.FQDNLabelKey] != "dead-1.barkpark.cloud" {
		t.Errorf("labels did not ride back: %v", got.Labels)
	}
}

// TestList asserts the plain list maps name+IP and leaves Labels nil (the
// documented cloud.Server contract for the non-label-aware path).
func TestList(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"servers":[{"id":1,"name":"a","status":"running","public_net":{"ipv4":{"ip":"192.0.2.1"}},"labels":{"x":"y"}}]}`)
	})
	servers, err := f.provider().List(context.Background())
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(servers) != 1 || servers[0].Name != "a" || servers[0].IP != "192.0.2.1" {
		t.Fatalf("List = %+v, want one server a/192.0.2.1", servers)
	}
	if servers[0].Labels != nil {
		t.Errorf("plain List populated Labels %v; contract says nil", servers[0].Labels)
	}
}

// TestLabelServer asserts add-label --overwrite semantics: the PUT body
// carries the box's EXISTING labels plus the new key — never a wipe down to
// one label.
func TestLabelServer(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"servers":[{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}},"labels":{"barkpark-managed":"true"}}]}`)
	})
	f.mux.HandleFunc("PUT /servers/42", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"server":{"id":42,"name":"web-1","status":"running","public_net":{"ipv4":{"ip":"192.0.2.10"}}}}`)
	})

	err := f.provider().LabelServer(context.Background(), "web-1", cloud.OrphanedLabelKey, "true")
	if err != nil {
		t.Fatalf("LabelServer: %v", err)
	}
	req, ok := f.find("PUT", "/servers/42")
	if !ok {
		t.Fatal("no PUT /servers/42 was issued")
	}
	labels, _ := req.Body["labels"].(map[string]any)
	if labels[cloud.OrphanedLabelKey] != "true" {
		t.Errorf("update body labels = %v, missing the new %s=true", labels, cloud.OrphanedLabelKey)
	}
	if labels[cloud.ManagedLabelKey] != "true" {
		t.Errorf("update body labels = %v — the pre-existing %s label was wiped", labels, cloud.ManagedLabelKey)
	}
}

// TestResolveToken asserts the env resolution both ways. HCLOUD_CONFIG is
// pinned to a path that does not exist so the hcloud-context fallback can
// never pick up a REAL cli.toml from the developer's machine — the "no token
// anywhere" branch must be reproducible.
func TestResolveToken(t *testing.T) {
	t.Setenv("HCLOUD_CONFIG", filepath.Join(t.TempDir(), "no-such-cli.toml"))
	t.Setenv("HCLOUD_TOKEN", "abc123")
	tok, err := ResolveToken()
	if err != nil || tok != "abc123" {
		t.Fatalf("ResolveToken = %q, %v; want abc123, nil", tok, err)
	}
	t.Setenv("HCLOUD_TOKEN", "  ")
	if _, err := ResolveToken(); err == nil {
		t.Fatal("ResolveToken with a blank env and no hcloud context did not error")
	}
}
