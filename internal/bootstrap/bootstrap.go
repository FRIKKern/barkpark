// Package bootstrap stands up a FRESH Barkpark instance's CONTENT so the owner
// lands in a working site + Studio instead of an empty box (dwb-4). It is the
// server-side port of the `bp vercel quick-setup` orchestration
// (internal/cli/vercel_cmd.go), driven by a declarative template manifest
// (internal/template) from the provisioner's embedded catalog
// (internal/provisioner/catalog), and called by the provisioner chain AFTER the
// health gate + admin-token install succeeded.
//
// Steps (each logged for the SSE narration to come; tokens are NEVER logged):
//
//  1. workspace  — POST /api/workspaces {name,slug} → workspace + Default
//     project + production dataset in one call. 409/422 (already exists) is
//     tolerated, so a re-run converges.
//  2. schemas    — POST /w/<ws>/p/default/v1/schemas/<dataset> per manifest
//     schema (the instance upserts, so re-posting is idempotent).
//  3. seed       — POST /w/<ws>/p/default/v1/data/mutate/<dataset> with the
//     manifest's mutations (createOrReplace is idempotent), then an EXPLICIT
//     publish pass per seed.publish/publishType — createOrReplace lands DRAFTS
//     (templates/DEPLOYING.md gotcha #2), and publish needs BOTH {id,type}.
//  4. read token — POST /w/<ws>/p/default/v1/tokens {label,permissions:
//     ["public-read"]}. MANDATORY: non-Default workspaces 403 anonymous reads
//     (gotcha #3), so the deploy target cannot read without it. Idempotency is
//     STORE-ONCE: Spec.PriorReadToken carries a token a previous run already
//     minted + stored, and the mint is skipped — the instance has no token-list
//     endpoint, and a raw token is unrecoverable after mint (hash-at-rest), so
//     "check the label first" cannot return the raw value anyway.
//  5. env        — compute the deploy target's env values per the manifest's
//     env[].source wiring contract. source "webhook_secret" is SKIPPED here —
//     webhook wiring is dwb-5.
//
// Everything is plain admin-token HTTPS against the instance's SCOPED URL
// (`/w/<ws>/p/default/v1/…`, never the flat `/v1` alias — gotcha #1: the flat
// alias resolves to the Default workspace and writes land in the wrong tenant).
package bootstrap

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/template"
)

// Project is the Barkpark project slug a fresh workspace bootstraps with — the
// instance's workspace-create makes a "Default" project reachable at this slug.
const Project = "default"

// TokenLabel is the deterministic label the bootstrap read token is minted
// under. Fixed so a human (or a future label-aware mint) can recognise the
// bootstrap-owned token on the instance.
const TokenLabel = "bootstrap-public-read"

// Client is the instance-API connection the bootstrap drives: the fresh box's
// public origin plus the per-instance admin token the chain installed on it.
type Client struct {
	// BaseURL is the instance origin, e.g. https://acme.barkpark.cloud.
	BaseURL string
	// AdminToken is the per-instance admin bearer (bp_admin_…). NEVER logged.
	AdminToken string
	// HTTPClient is the injected client; nil → http.DefaultClient.
	HTTPClient *http.Client
	// Logf receives one line per sub-step (the provisioner journal / future SSE
	// narration). nil → silent. Implementations MUST NOT be handed tokens.
	Logf func(format string, args ...any)
}

// Spec is one bootstrap request: which template to apply and the workspace
// identity to stand it up under.
type Spec struct {
	// Template is the catalog slug (manifest `name`).
	Template *template.Template
	// SchemaFiles are the raw schema bodies, in manifest order (resolved by the
	// caller — e.g. from the embedded catalog).
	SchemaFiles [][]byte
	// SeedFile is the raw seed body (nil when the template ships no seed).
	SeedFile []byte
	// WorkspaceName / WorkspaceSlug identify the workspace to create (display
	// name + slug). The slug scopes every subsequent call.
	WorkspaceName string
	WorkspaceSlug string
	// PriorReadToken enables the STORE-ONCE mint idempotency: when a previous
	// run already minted + stored the read token for this instance, pass it here
	// and step 4 is skipped — a re-run never mints a duplicate.
	PriorReadToken string
}

// Outputs is what the bootstrap produced — the values the worker reports to the
// control plane (stored encrypted) and the dashboard/deploy target consume.
type Outputs struct {
	Template  string            `json:"template"`
	Workspace string            `json:"workspace"`
	Project   string            `json:"project"`
	Dataset   string            `json:"dataset"`
	ReadToken string            `json:"read_token"`
	Env       map[string]string `json:"env"`
}

// Run executes the bootstrap chain against the instance. It returns the outputs
// on success; ANY sub-step failure returns an error — the caller (the
// provisioner chain) fails the provision job through the existing machinery so
// the box is never silently half-alive.
//
// Run is IDEMPOTENT: re-running against a half-bootstrapped instance converges
// (workspace create tolerates already-exists, schema posts upsert, seed
// createOrReplace re-applies, publish re-publishes, and the token mint is
// skipped when PriorReadToken carries the stored one).
//
// @canonical capability:instance-content-bootstrap aka:quick-setup,post-provision-bootstrap,template-bootstrap doc:templates/MANIFEST.md
func Run(ctx context.Context, c Client, spec Spec) (*Outputs, error) {
	tpl := spec.Template
	if tpl == nil {
		return nil, fmt.Errorf("bootstrap: no template manifest given")
	}
	if strings.TrimSpace(spec.WorkspaceSlug) == "" {
		return nil, fmt.Errorf("bootstrap: a workspace slug is required")
	}
	dataset := tpl.Dataset()
	scopedBase := strings.TrimRight(c.BaseURL, "/") + scopedPrefix(spec.WorkspaceSlug, Project)

	c.logf("bootstrap %s: template=%s workspace=%s dataset=%s", c.BaseURL, tpl.Name, spec.WorkspaceSlug, dataset)

	// ── 1. workspace (+ Default project + production dataset in one call) ──
	if err := c.ensureWorkspace(ctx, spec.WorkspaceName, spec.WorkspaceSlug); err != nil {
		return nil, fmt.Errorf("bootstrap workspace: %w", err)
	}

	// ── 2. schemas (idempotent upsert per manifest schema) ──
	if len(spec.SchemaFiles) != len(tpl.Schemas) {
		return nil, fmt.Errorf("bootstrap: got %d schema bodies for %d manifest schemas", len(spec.SchemaFiles), len(tpl.Schemas))
	}
	for i, body := range spec.SchemaFiles {
		if err := c.applySchema(ctx, scopedBase, dataset, body); err != nil {
			return nil, fmt.Errorf("bootstrap schema %q: %w", tpl.Schemas[i], err)
		}
		c.logf("bootstrap: schema applied (%s)", tpl.Schemas[i])
	}

	// ── 3. seed + explicit publish ──
	// A manifest that DECLARES a seed must arrive with its bytes — silently
	// skipping would ship an empty site while reporting success (fail closed).
	if tpl.Seed != nil && len(spec.SeedFile) == 0 {
		return nil, fmt.Errorf("bootstrap seed: manifest declares %q but no seed bytes were provided", tpl.Seed.Path)
	}
	if tpl.Seed != nil {
		if got := tpl.Seed.Format(); got != template.SeedFormatMutations {
			// v1 bootstrap applies the mutations shape only; ndjson/script templates
			// fail loudly rather than half-applying.
			return nil, fmt.Errorf("bootstrap seed: format %q is not supported (only %q)", got, template.SeedFormatMutations)
		}
		if err := c.seedAndPublish(ctx, scopedBase, dataset, spec.SeedFile, tpl.Seed); err != nil {
			return nil, fmt.Errorf("bootstrap seed: %w", err)
		}
	}

	// ── 4. workspace-bound public-read token (store-once idempotency) ──
	readToken := spec.PriorReadToken
	if readToken == "" {
		tok, err := c.mintReadToken(ctx, scopedBase, dataset)
		if err != nil {
			return nil, fmt.Errorf("bootstrap read token: %w", err)
		}
		readToken = tok
		c.logf("bootstrap: minted %s (workspace-bound public-read)", TokenLabel)
	} else {
		c.logf("bootstrap: reusing stored read token (store-once — no duplicate mint)")
	}

	// ── 5. env values per the manifest's env[].source wiring ──
	env, err := resolveEnv(tpl, scopedBase, readToken, dataset, spec.WorkspaceSlug)
	if err != nil {
		return nil, fmt.Errorf("bootstrap env: %w", err)
	}
	c.logf("bootstrap: resolved %d env value(s)", len(env))

	return &Outputs{
		Template:  tpl.Name,
		Workspace: spec.WorkspaceSlug,
		Project:   Project,
		Dataset:   dataset,
		ReadToken: readToken,
		Env:       env,
	}, nil
}

// resolveEnv materialises the manifest env[] into concrete values. Source
// "webhook_secret" is skipped (dwb-5 wires webhooks); an unknown source errors
// (template.Validate should have caught it, but fail closed).
func resolveEnv(tpl *template.Template, scopedBase, readToken, dataset, workspace string) (map[string]string, error) {
	env := make(map[string]string, len(tpl.Env))
	for _, e := range tpl.Env {
		switch e.Source {
		case template.SourceAPIURL:
			env[e.Key] = scopedBase
		case template.SourceReadToken:
			env[e.Key] = readToken
		case template.SourceDataset:
			env[e.Key] = dataset
		case template.SourceWorkspace:
			env[e.Key] = workspace
		case template.SourceProject:
			env[e.Key] = Project
		case template.SourceLiteral:
			env[e.Key] = e.Value
		case template.SourceWebhookSecret:
			// dwb-5: webhook wiring is a later step — skip, never fabricate.
			continue
		default:
			return nil, fmt.Errorf("env %s: unknown source %q", e.Key, e.Source)
		}
	}
	return env, nil
}

// scopedPrefix is the workspace/project SCOPED path prefix — deliberately never
// the flat /v1 alias (which resolves to the Default workspace: gotcha #1).
func scopedPrefix(workspace, project string) string {
	return fmt.Sprintf("/w/%s/p/%s", url.PathEscape(workspace), url.PathEscape(project))
}

// ensureWorkspace creates the workspace; 409/422 (duplicate slug) is treated as
// already-present so a re-run converges.
func (c Client) ensureWorkspace(ctx context.Context, name, slug string) error {
	body, _ := json.Marshal(map[string]string{"name": name, "slug": slug})
	status, respBody, err := c.doJSON(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+"/api/workspaces", body)
	if err != nil {
		return err
	}
	switch {
	case status >= 200 && status < 300:
		c.logf("bootstrap: workspace %q created", slug)
		return nil
	case status == http.StatusConflict || status == http.StatusUnprocessableEntity:
		c.logf("bootstrap: workspace %q already exists", slug)
		return nil
	default:
		return fmt.Errorf("status %d: %s", status, snippet(respBody))
	}
}

// applySchema POSTs one flat schema object to the SCOPED schema URL (upsert).
func (c Client) applySchema(ctx context.Context, scopedBase, dataset string, schema []byte) error {
	u := scopedBase + "/v1/schemas/" + url.PathEscape(dataset)
	status, respBody, err := c.doJSON(ctx, http.MethodPost, u, schema)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("status %d: %s", status, snippet(respBody))
	}
	return nil
}

// seedAndPublish POSTs the seed mutations, then publishes every seeded doc id
// when the manifest asks for it (createOrReplace lands drafts; publish needs
// BOTH id and type).
func (c Client) seedAndPublish(ctx context.Context, scopedBase, dataset string, seed []byte, s *template.Seed) error {
	u := scopedBase + "/v1/data/mutate/" + url.PathEscape(dataset)
	status, respBody, err := c.doJSON(ctx, http.MethodPost, u, seed)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("mutate: status %d: %s", status, snippet(respBody))
	}
	c.logf("bootstrap: seeded (drafts)")

	if !s.Publish {
		return nil
	}
	ids, err := seedIDs(seed)
	if err != nil {
		return err
	}
	if len(ids) == 0 {
		return fmt.Errorf("publish: the seed carries no document ids to publish")
	}
	pubBody, _ := json.Marshal(publishPayload(ids, s.PublishType))
	status, respBody, err = c.doJSON(ctx, http.MethodPost, u, pubBody)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("publish: status %d: %s", status, snippet(respBody))
	}
	c.logf("bootstrap: published %d document(s) of type %q", len(ids), s.PublishType)
	return nil
}

// mintReadToken mints the workspace-bound public-read token over the admin-gated
// scoped endpoint. The raw token rides back ONLY in the return value.
func (c Client) mintReadToken(ctx context.Context, scopedBase, dataset string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"label":       TokenLabel,
		"permissions": []string{"public-read"},
		"dataset":     dataset,
	})
	status, respBody, err := c.doJSON(ctx, http.MethodPost, scopedBase+"/v1/tokens", body)
	if err != nil {
		return "", err
	}
	if status < 200 || status >= 300 {
		return "", fmt.Errorf("status %d: %s", status, snippet(respBody))
	}
	var resp struct {
		Token string `json:"token"`
	}
	if jerr := json.Unmarshal(respBody, &resp); jerr != nil {
		return "", fmt.Errorf("parse mint response: %w", jerr)
	}
	if resp.Token == "" {
		return "", fmt.Errorf("server returned no token")
	}
	return resp.Token, nil
}

// seedIDs extracts document ids from a {"mutations":[…]} seed payload —
// createOrReplace._id first, then create._id (the same extraction the CLI
// quick-setup performs).
func seedIDs(seed []byte) ([]string, error) {
	var env struct {
		Mutations []struct {
			CreateOrReplace map[string]json.RawMessage `json:"createOrReplace"`
			Create          map[string]json.RawMessage `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(seed, &env); err != nil {
		return nil, fmt.Errorf("parse seed mutations: %w", err)
	}
	var ids []string
	for _, m := range env.Mutations {
		if id := rawID(m.CreateOrReplace); id != "" {
			ids = append(ids, id)
			continue
		}
		if id := rawID(m.Create); id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

// rawID pulls a string "_id" out of a mutation document map.
func rawID(doc map[string]json.RawMessage) string {
	if doc == nil {
		return ""
	}
	raw, ok := doc["_id"]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return s
}

// publishPayload builds {"mutations":[{"publish":{"id","type"}}]} — publish
// needs BOTH id and type, else the instance 400s.
func publishPayload(ids []string, publishType string) map[string]any {
	muts := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		muts = append(muts, map[string]any{
			"publish": map[string]string{"id": id, "type": publishType},
		})
	}
	return map[string]any{"mutations": muts}
}

// doJSON POSTs/sends body with the admin bearer + JSON content type and returns
// (status, body, err). The response body is capped at 1 MiB.
func (c Client) doJSON(ctx context.Context, method, u string, body []byte) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.AdminToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.AdminToken)
	}
	client := c.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, data, nil
}

// snippet truncates a response body for error messages (and never carries a
// request token — only server responses land here).
func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	r := []rune(s)
	if len(r) > 200 {
		return string(r[:200]) + "…"
	}
	return s
}

// logf is nil-safe step narration.
func (c Client) logf(format string, args ...any) {
	if c.Logf != nil {
		c.Logf(format, args...)
	}
}
