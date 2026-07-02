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
	"github.com/FRIKKern/barkpark/internal/template"
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
	failStep   string            // "schema"|"mutate"|"token"|"webhook" → that step 500s

	webhooks       []*webhookRow // registered webhook endpoints (upsert by name)
	webhookCreates int           // POST /v1/webhooks — the duplicate-create counter
	webhookUpdates int           // PUT  /v1/webhooks — secret re-bind counter
}

// webhookRow is the fake's server-side webhook record. The secret is stored but
// NEVER echoed on list/show (mirroring the real render), so the bootstrap can
// only ever get it back via the store-once PriorWebhookSecret path.
type webhookRow struct {
	id, name, url, secret string
	active                bool
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
		case strings.Contains(p, "/v1/webhooks"):
			if f.failStep == "webhook" {
				http.Error(w, "boom", http.StatusInternalServerError)
				return
			}
			f.serveWebhook(w, r, p, raw)
		default:
			http.Error(w, "not found: "+p, http.StatusNotFound)
		}
	})

	return mux
}

// serveWebhook fakes the scoped admin webhook endpoints the bootstrap upserts
// against: GET lists (WITHOUT the secret, mirroring the real render), POST
// creates, PUT re-binds the secret. Called with f.mu already held.
func (f *fakeInstance) serveWebhook(w http.ResponseWriter, r *http.Request, p string, raw json.RawMessage) {
	switch r.Method {
	case http.MethodGet:
		list := make([]map[string]any, 0, len(f.webhooks))
		for _, wh := range f.webhooks {
			// NOTE: no "secret" — the real controller never renders it.
			list = append(list, map[string]any{"id": wh.id, "name": wh.name, "url": wh.url, "active": wh.active})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"webhooks": list})

	case http.MethodPost:
		var in struct {
			Name, URL, Secret string
			Active            bool
		}
		_ = json.Unmarshal(raw, &in)
		wh := &webhookRow{
			id:     fmt.Sprintf("wh-%d", len(f.webhooks)+1),
			name:   in.Name,
			url:    in.URL,
			secret: in.Secret,
			active: in.Active,
		}
		f.webhooks = append(f.webhooks, wh)
		f.webhookCreates++
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"webhook": map[string]any{"id": wh.id, "name": wh.name, "url": wh.url, "active": wh.active},
		})

	case http.MethodPut:
		id := p[strings.LastIndex(p, "/")+1:]
		var in struct{ Secret string }
		_ = json.Unmarshal(raw, &in)
		for _, wh := range f.webhooks {
			if wh.id == id && in.Secret != "" {
				wh.secret = in.Secret
				f.webhookUpdates++
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"webhook": map[string]any{"id": id}})

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// webhookByName returns the fake's stored row for a name, or nil.
func (f *fakeInstance) webhookByName(name string) *webhookRow {
	for _, wh := range f.webhooks {
		if wh.name == name {
			return wh
		}
	}
	return nil
}

// runSpec builds a Spec from the embedded place-directory catalog entry — the
// richest template (schema + seed + publish + full env wiring, now incl. the
// dwb-5 webhook_secret source).
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
// publish posted (with {id,type} pairs), ONE token minted, ONE webhook endpoint
// registered (disabled, placeholder URL, crypto secret), and the env map
// resolved per the manifest's env[].source wiring (incl. BARKPARK_WEBHOOK_SECRET).
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

	// ── webhook endpoint registered for ISR revalidation (dwb-5) ──
	if inst.webhookCreates != 1 {
		t.Fatalf("webhook creates = %d, want 1", inst.webhookCreates)
	}
	wh := inst.webhookByName(WebhookName)
	if wh == nil {
		t.Fatalf("no webhook named %q was registered", WebhookName)
	}
	if wh.active {
		t.Error("webhook was registered ACTIVE — it must be disabled until dwb-6 wires the real URL")
	}
	if wh.url != WebhookPlaceholderURL {
		t.Errorf("webhook url = %q, want the placeholder %q", wh.url, WebhookPlaceholderURL)
	}
	// The secret must be a 32-byte (64 hex char) crypto secret bound to the endpoint.
	if len(wh.secret) != 64 {
		t.Errorf("webhook secret len = %d, want 64 hex chars (32 bytes)", len(wh.secret))
	}

	// ── env wiring per env[].source ──
	scoped := srv.URL + "/w/acme/p/default"
	wantEnv := map[string]string{
		"BARKPARK_API_URL":           scoped,
		"BARKPARK_TOKEN":             out.ReadToken,
		"BARKPARK_WORKSPACE":         "acme",
		"BARKPARK_PROJECT":           "default",
		"BARKPARK_DATASET":           "production",
		"NEXT_PUBLIC_FINDER_LANDING": "map",     // the literal source
		"BARKPARK_WEBHOOK_SECRET":    wh.secret, // dwb-5: bound to the endpoint above
	}
	for k, want := range wantEnv {
		if got := out.Env[k]; got != want {
			t.Errorf("env %s = %q, want %q", k, got, want)
		}
	}
	if len(out.Env) != len(wantEnv) {
		t.Errorf("env has %d keys %v, want exactly %d", len(out.Env), out.Env, len(wantEnv))
	}
	// The webhook secret is a real secret: it must NOT collide with the read token.
	if out.Env["BARKPARK_WEBHOOK_SECRET"] == out.ReadToken {
		t.Error("webhook secret equals the read token — they must be independent secrets")
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
	// AND the webhook secret once, so the retry carries both (store-once semantics).
	spec.PriorReadToken = first.ReadToken
	spec.PriorWebhookSecret = first.Env["BARKPARK_WEBHOOK_SECRET"]
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

	// ── NO duplicate webhook / NO secret rotation on re-run ──
	if inst.webhookCreates != 1 {
		t.Errorf("webhook creates across two runs = %d, want exactly 1 (upsert by name — never a duplicate)", inst.webhookCreates)
	}
	if inst.webhookUpdates != 0 {
		t.Errorf("webhook secret updates = %d, want 0 (store-once — never a rotation with a prior secret)", inst.webhookUpdates)
	}
	if second.Env["BARKPARK_WEBHOOK_SECRET"] != first.Env["BARKPARK_WEBHOOK_SECRET"] {
		t.Errorf("re-run webhook secret %q != first %q", second.Env["BARKPARK_WEBHOOK_SECRET"], first.Env["BARKPARK_WEBHOOK_SECRET"])
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
	if secret := out.Env["BARKPARK_WEBHOOK_SECRET"]; secret == "" || strings.Contains(joined, secret) {
		if secret == "" {
			t.Fatal("no webhook secret was produced — the redaction check needs one")
		}
		t.Error("the generated webhook secret leaked into the narration log")
	}
}

// TestRunEmitsCaptionsAtSubBoundaries (dwb-19) proves the curated live captions
// fire at each real content sub-boundary — workspace, schemas (with a count),
// seed/publish (with a count), and webhook — in order, carry the document/schema
// COUNTS, and NEVER leak a token (captions are the plain-language middle layer,
// not the raw journal).
func TestRunEmitsCaptionsAtSubBoundaries(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	var caps []string
	c := Client{
		BaseURL:    srv.URL,
		AdminToken: "bp_admin_supersecret",
		HTTPClient: srv.Client(),
		Caption:    func(s string) { caps = append(caps, s) },
	}
	out, err := Run(context.Background(), c, runSpec(t))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	joined := strings.Join(caps, "\n")
	// The workspace, schema, publish, and webhook boundaries each narrated.
	for _, want := range []string{
		"Creating your workspace",
		"Installing 1 schema",            // the fixture ships exactly one schema (singular)
		"Publishing 12 sample documents", // the place-directory seed has 12 published places (plural, counted)
		"Wiring instant updates",         // the place-directory template wires a webhook
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("caption %q was not emitted; got:\n%s", want, joined)
		}
	}

	// Order: workspace caption precedes the schema caption precedes the publish
	// caption (the honest walk order).
	iWs := indexOfContains(caps, "Creating your workspace")
	iSchema := indexOfContains(caps, "Installing 1 schema")
	iPub := indexOfContains(caps, "Publishing 12 sample")
	if !(iWs >= 0 && iWs < iSchema && iSchema < iPub) {
		t.Errorf("captions out of order: workspace=%d schema=%d publish=%d (%v)", iWs, iSchema, iPub, caps)
	}

	// Redaction posture: no token ever rides in a caption (curated copy only).
	if strings.Contains(joined, "bp_admin_supersecret") || strings.Contains(joined, out.ReadToken) {
		t.Errorf("a token leaked into a caption: %q", joined)
	}
	if secret := out.Env["BARKPARK_WEBHOOK_SECRET"]; secret != "" && strings.Contains(joined, secret) {
		t.Error("the webhook secret leaked into a caption")
	}
}

// indexOfContains returns the first index whose element contains sub, or -1.
func indexOfContains(ss []string, sub string) int {
	for i, s := range ss {
		if strings.Contains(s, sub) {
			return i
		}
	}
	return -1
}

// TestRunSkipsWebhookWhenNoSource proves the webhook step is gated on the
// manifest: a template WITHOUT a webhook_secret env source registers no
// endpoint and produces no BARKPARK_WEBHOOK_SECRET (the pre-dwb-5 behaviour).
func TestRunSkipsWebhookWhenNoSource(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	spec := runSpec(t)
	// Clone the manifest and strip every webhook_secret env source.
	m := *spec.Template
	var trimmed []template.EnvVar
	for _, e := range m.Env {
		if e.Source != template.SourceWebhookSecret {
			trimmed = append(trimmed, e)
		}
	}
	m.Env = trimmed
	spec.Template = &m

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	out, err := Run(context.Background(), c, spec)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if inst.webhookCreates != 0 {
		t.Errorf("webhook creates = %d, want 0 (no webhook_secret source)", inst.webhookCreates)
	}
	if _, ok := out.Env["BARKPARK_WEBHOOK_SECRET"]; ok {
		t.Error("BARKPARK_WEBHOOK_SECRET present with no webhook_secret source")
	}
}

// TestRunWebhookFailsClosed proves a red webhook step surfaces as an error — a
// half-wired site (no revalidation) is never reported as success.
func TestRunWebhookFailsClosed(t *testing.T) {
	inst := newFakeInstance()
	inst.failStep = "webhook"
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	out, err := Run(context.Background(), c, runSpec(t))
	if err == nil {
		t.Fatal("Run with a red webhook step returned nil, want an error")
	}
	if out != nil {
		t.Errorf("Run returned outputs %+v alongside an error, want nil", out)
	}
	if !strings.Contains(err.Error(), "webhook") {
		t.Errorf("error %q does not name the failing sub-step", err)
	}
}

// TestRunWebhookUpsertsByName proves the deterministic-name upsert: a re-run
// WITHOUT a prior secret (crash-recovery — the first run's secret was never
// stored) finds the still-disabled endpoint and RE-BINDS the fresh secret
// instead of creating a duplicate, so the endpoint and the reported secret
// agree.
func TestRunWebhookUpsertsByName(t *testing.T) {
	inst := newFakeInstance()
	srv := httptest.NewServer(inst.handler())
	defer srv.Close()

	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	spec := runSpec(t)

	first, err := Run(context.Background(), c, spec)
	if err != nil {
		t.Fatalf("Run #1: %v", err)
	}
	// Re-run WITHOUT PriorWebhookSecret (as if outputs were never stored).
	spec.PriorReadToken = first.ReadToken // read token still store-once; only the webhook secret is unknown
	second, err := Run(context.Background(), c, spec)
	if err != nil {
		t.Fatalf("Run #2: %v", err)
	}

	if inst.webhookCreates != 1 {
		t.Errorf("webhook creates = %d, want 1 (upsert by name — no duplicate)", inst.webhookCreates)
	}
	if inst.webhookUpdates != 1 {
		t.Errorf("webhook updates = %d, want 1 (fresh secret re-bound on the disabled placeholder)", inst.webhookUpdates)
	}
	wh := inst.webhookByName(WebhookName)
	if wh == nil {
		t.Fatal("webhook vanished after re-run")
	}
	// The endpoint's secret must equal the SECOND run's reported secret.
	if wh.secret != second.Env["BARKPARK_WEBHOOK_SECRET"] {
		t.Errorf("endpoint secret %q != reported %q — they must agree", wh.secret, second.Env["BARKPARK_WEBHOOK_SECRET"])
	}
}
