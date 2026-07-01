package bootstrap

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/provisioner/catalog"
)

// fakeInstance is a stateful fake of the instance API surface the bootstrap
// drives: POST /api/workspaces (409 on duplicate slug), the scoped schema
// upsert, the scoped mutate (recording seed + publish payloads), and the scoped
// token mint (counting mints). It lets the idempotency test re-run Run against
// the SAME half/fully-bootstrapped state.
type fakeInstance struct {
	mu         sync.Mutex
	workspaces map[string]bool
	schemas    []json.RawMessage // every schema body posted (re-posts append)
	mutates    []json.RawMessage // every mutate body posted (seed + publish)
	mints      int               // token mints — the duplicate-mint counter
	authSeen   map[string]bool   // Authorization header values observed
	failStep   string            // "schema"|"mutate"|"token" → that step 500s
}

func newFakeInstance() *fakeInstance {
	return &fakeInstance{workspaces: map[string]bool{}, authSeen: map[string]bool{}}
}

func (f *fakeInstance) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/workspaces", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.authSeen[r.Header.Get("Authorization")] = true
		var body struct {
			Name string `json:"name"`
			Slug string `json:"slug"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if f.workspaces[body.Slug] {
			// Duplicate slug → the FallbackController's 422 (the real instance's
			// duplicate response). The bootstrap must tolerate this.
			http.Error(w, `{"error":{"code":"unprocessable"}}`, http.StatusUnprocessableEntity)
			return
		}
		f.workspaces[body.Slug] = true
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"workspace": map[string]string{"slug": body.Slug}})
	})

	// The SCOPED routes — assert scoping by matching the /w/<ws>/p/default prefix.
	mux.HandleFunc("/w/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.authSeen[r.Header.Get("Authorization")] = true
		p := r.URL.Path
		var raw json.RawMessage
		_ = json.NewDecoder(r.Body).Decode(&raw)
		switch {
		case strings.Contains(p, "/v1/schemas/"):
			if f.failStep == "schema" {
				http.Error(w, "boom", http.StatusInternalServerError)
				return
			}
			f.schemas = append(f.schemas, raw)
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case strings.Contains(p, "/v1/data/mutate/"):
			if f.failStep == "mutate" {
				http.Error(w, "boom", http.StatusInternalServerError)
				return
			}
			f.mutates = append(f.mutates, raw)
			_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		case strings.HasSuffix(p, "/v1/tokens"):
			if f.failStep == "token" {
				http.Error(w, "boom", http.StatusInternalServerError)
				return
			}
			f.mints++
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]string{"token": fmt.Sprintf("bp_read_fake_%d", f.mints)})
		default:
			http.Error(w, "not found: "+p, http.StatusNotFound)
		}
	})

	return mux
}

// runSpec builds a Spec from the embedded place-directory catalog entry — the
// richest template (schema + seed + publish + full env wiring).
func runSpec(t *testing.T) Spec {
	t.Helper()
	entry, ok := catalog.Get("place-directory")
	if !ok {
		t.Fatal("catalog is missing place-directory")
	}
	schemas, err := entry.SchemaBytes()
	if err != nil {
		t.Fatalf("SchemaBytes: %v", err)
	}
	seed, err := entry.SeedBytes()
	if err != nil {
		t.Fatalf("SeedBytes: %v", err)
	}
	return Spec{
		Template:      entry.Manifest,
		SchemaFiles:   schemas,
		SeedFile:      seed,
		WorkspaceName: "Acme Co",
		WorkspaceSlug: "acme",
	}
}

// TestRunHappyPath drives the full chain against the fake instance and asserts
// every sub-step landed: workspace created, schema applied, seed + explicit
// publish posted (with {id,type} pairs), ONE token minted, and the env map
// resolved per the manifest's env[].source wiring (webhook_secret skipped).
func TestRunHappyPath(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	out, err := Run(context.Background(), c, runSpec(t))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	// ── outputs ──
	if out.Workspace != "acme" || out.Project != "default" || out.Dataset != "production" {
		t.Errorf("outputs = %+v, want workspace=acme project=default dataset=production", out)
	}
	if !strings.HasPrefix(out.ReadToken, "bp_read_fake_") {
		t.Errorf("ReadToken = %q, want the minted fake token", out.ReadToken)
	}
	if out.Template != "place-directory" {
		t.Errorf("Template = %q, want place-directory", out.Template)
	}

	// ── instance state ──
	if !inst.workspaces["acme"] {
		t.Error("workspace acme was not created")
	}
	if len(inst.schemas) != 1 {
		t.Fatalf("schemas posted = %d, want 1", len(inst.schemas))
	}
	if len(inst.mutates) != 2 {
		t.Fatalf("mutate posts = %d, want 2 (seed + publish)", len(inst.mutates))
	}
	if inst.mints != 1 {
		t.Errorf("token mints = %d, want 1", inst.mints)
	}
	if !inst.authSeen["Bearer bp_admin_test"] {
		t.Error("requests did not carry the admin bearer")
	}

	// ── the SECOND mutate is the explicit publish pass with {id,type} pairs
	// (createOrReplace lands drafts — gotcha #2) ──
	var pub struct {
		Mutations []struct {
			Publish map[string]string `json:"publish"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(inst.mutates[1], &pub); err != nil {
		t.Fatalf("parse publish payload: %v", err)
	}
	if len(pub.Mutations) == 0 {
		t.Fatal("publish payload carries no mutations")
	}
	for _, m := range pub.Mutations {
		if m.Publish["id"] == "" || m.Publish["type"] != "place" {
			t.Errorf("publish mutation %+v, want both id and type=place", m.Publish)
		}
	}

	// ── env wiring per env[].source ──
	scoped := srv.URL + "/w/acme/p/default"
	wantEnv := map[string]string{
		"BARKPARK_API_URL":           scoped,
		"BARKPARK_TOKEN":             out.ReadToken,
		"BARKPARK_WORKSPACE":         "acme",
		"BARKPARK_PROJECT":           "default",
		"BARKPARK_DATASET":           "production",
		"NEXT_PUBLIC_FINDER_LANDING": "map", // the literal source
	}
	for k, want := range wantEnv {
		if got := out.Env[k]; got != want {
			t.Errorf("env %s = %q, want %q", k, got, want)
		}
	}
	if len(out.Env) != len(wantEnv) {
		t.Errorf("env has %d keys %v, want exactly %d (webhook_secret must be SKIPPED — dwb-5)", len(out.Env), out.Env, len(wantEnv))
	}
}

// TestRunIsIdempotent is the dwb-4 ACCEPTANCE test: re-running Run against an
// already-bootstrapped instance CONVERGES — the duplicate workspace create is
// tolerated (422 → already exists), schema/seed re-posts are upserts, and the
// token mint is NOT repeated (store-once: the second run passes the first run's
// stored token as PriorReadToken). Both runs produce equivalent outputs.
func TestRunIsIdempotent(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	spec := runSpec(t)

	first, err := Run(context.Background(), c, spec)
	if err != nil {
		t.Fatalf("Run #1: %v", err)
	}

	// Re-run against the SAME instance — the control plane stored the read token
	// once, so the retry carries it (store-once semantics).
	spec.PriorReadToken = first.ReadToken
	second, err := Run(context.Background(), c, spec)
	if err != nil {
		t.Fatalf("Run #2 (the idempotent re-run) must converge, got: %v", err)
	}

	// ── NO duplicate workspace / NO duplicate token mint ──
	if got := len(inst.workspaces); got != 1 {
		t.Errorf("workspaces = %d, want 1 (no duplicate on re-run)", got)
	}
	if inst.mints != 1 {
		t.Errorf("token mints across two runs = %d, want exactly 1 (store-once — never a duplicate mint)", inst.mints)
	}

	// ── the runs converge on identical outputs ──
	if second.ReadToken != first.ReadToken {
		t.Errorf("re-run read token %q != first %q", second.ReadToken, first.ReadToken)
	}
	if second.Workspace != first.Workspace || second.Dataset != first.Dataset || second.Project != first.Project {
		t.Errorf("re-run outputs diverged: %+v vs %+v", second, first)
	}
	for k, v := range first.Env {
		if second.Env[k] != v {
			t.Errorf("re-run env[%s] = %q, want %q", k, second.Env[k], v)
		}
	}

	// ── seed re-applied (createOrReplace is the idempotent upsert; 2 mutate
	// posts per run: seed + publish) ──
	if len(inst.mutates) != 4 {
		t.Errorf("mutate posts across two runs = %d, want 4 (seed+publish twice — both idempotent server-side)", len(inst.mutates))
	}
}

// TestRunHalfBootstrappedConverges proves convergence from a HALF-bootstrapped
// instance: run #1 dies at the token step (workspace + schema + seed already
// landed), run #2 completes everything — one workspace, one mint, no error.
func TestRunHalfBootstrappedConverges(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	spec := runSpec(t)

	inst.failStep = "token"
	if _, err := Run(context.Background(), c, spec); err == nil {
		t.Fatal("Run with a red token step returned nil, want an error")
	}

	inst.failStep = ""
	out, err := Run(context.Background(), c, spec)
	if err != nil {
		t.Fatalf("Run #2 against the half-bootstrapped instance must converge, got: %v", err)
	}
	if len(inst.workspaces) != 1 {
		t.Errorf("workspaces = %d, want 1", len(inst.workspaces))
	}
	if inst.mints != 1 {
		t.Errorf("mints = %d, want 1 (the failed run minted nothing)", inst.mints)
	}
	if out.ReadToken == "" {
		t.Error("converged run returned no read token")
	}
}

// TestRunFailsClosedOnSchemaError proves a red sub-step surfaces as an error
// (which the provisioner chain turns into a torn-down box + a failed job via
// the existing machinery) — never a partial success.
func TestRunFailsClosedOnSchemaError(t *testing.T) {
	inst := newFakeInstance()
	inst.failStep = "schema"
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	out, err := Run(context.Background(), c, runSpec(t))
	if err == nil {
		t.Fatal("Run with a red schema step returned nil, want an error")
	}
	if out != nil {
		t.Errorf("Run returned outputs %+v alongside an error, want nil", out)
	}
	if !strings.Contains(err.Error(), "schema") {
		t.Errorf("error %q does not name the failing sub-step", err)
	}
}

// TestRunNeverLogsTokens proves the narration contract: with a Logf capturing
// every line, neither the admin token nor the minted read token appears in any
// logged output.
func TestRunNeverLogsTokens(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	var lines []string
	c := Client{
		BaseURL:    srv.URL,
		AdminToken: "bp_admin_supersecret",
		HTTPClient: srv.Client(),
		Logf:       func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) },
	}
	out, err := Run(context.Background(), c, runSpec(t))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(lines) == 0 {
		t.Fatal("no narration lines were logged — the SSE sub-step contract needs them")
	}
	joined := strings.Join(lines, "\n")
	if strings.Contains(joined, "bp_admin_supersecret") {
		t.Error("the admin token leaked into the narration log")
	}
	if strings.Contains(joined, out.ReadToken) {
		t.Error("the minted read token leaked into the narration log")
	}
}
