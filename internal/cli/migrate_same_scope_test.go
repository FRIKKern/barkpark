package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// Stranger walk (2026-09-30): `bp migrate local local` planned "total: 33" and
// would, with --yes, have createOrReplace'd every document back into the
// dataset it came from. One --dataset serves both ends, so the same server +
// workspace + project IS the same scope; it is refused before any request.
func TestMigrateRefusesSameScopeBeforeAnyRequest(t *testing.T) {
	withTempConfigHome(t)

	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"schemas":[]}`))
	}))
	defer srv.Close()

	cfg := &Config{KnownServers: []ServerEntry{{Name: "local", Server: srv.URL, Token: "tok"}}}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}

	for _, args := range [][]string{
		{"local", "local"},
		{"local", "local", "--yes"},
		{"local", srv.URL + "/"}, // the same server named by URL, trailing slash
	} {
		var stdout, stderr bytes.Buffer
		code := runMigrate(newWriter(&stdout, &stderr), globals{}, args)
		if code != exitUsage {
			t.Errorf("migrate %v: exit = %d, want exitUsage (%d); stderr=%q", args, code, exitUsage, stderr.String())
		}
		if !strings.Contains(stderr.String(), "source and target are the same scope") {
			t.Errorf("migrate %v: stderr = %q, want the same-scope refusal", args, stderr.String())
		}
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("a same-scope migrate must refuse before any request; server saw %d", n)
	}
}

func TestSameMigrateScope(t *testing.T) {
	a := migrateEndpoint{url: "http://127.0.0.1:4000", workspace: "default", project: "default"}
	if !sameMigrateScope(a, migrateEndpoint{url: "HTTP://127.0.0.1:4000", workspace: "default", project: "default"}) {
		t.Error("same URL (case aside), workspace and project must be the same scope")
	}
	if sameMigrateScope(a, migrateEndpoint{url: "http://127.0.0.1:4000", workspace: "default", project: "other"}) {
		t.Error("a different project on the same server is a different scope")
	}
	if sameMigrateScope(a, migrateEndpoint{url: "http://127.0.0.1:4001", workspace: "default", project: "default"}) {
		t.Error("a different server is a different scope")
	}
}
