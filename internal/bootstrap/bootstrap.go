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
//     publish pass per seed.publish — createOrReplace lands DRAFTS
//     (templates/DEPLOYING.md gotcha #2), and publish needs BOTH {id,type}.
//     The type is PER DOCUMENT (the seed document's own "_type"), so a
//     connected multi-type graph — posts + authors + categories — seeds in one
//     batch; seed.publishType is the fallback for a document that omits one.
//     Every resolved type is checked against the types the manifest's schemas
//     DECLARE, BEFORE the seed is POSTed: publish is a second pass, so a batch
//     validated late would leave drafts behind that can never be published.
//  4. read token — POST /w/<ws>/p/default/v1/tokens {label,permissions:
//     ["public-read"]}. MANDATORY: non-Default workspaces 403 anonymous reads
//     (gotcha #3), so the deploy target cannot read without it. Idempotency is
//     STORE-ONCE: Spec.PriorReadToken carries a token a previous run already
//     minted + stored, and the mint is skipped — the instance has no token-list
//     endpoint, and a raw token is unrecoverable after mint (hash-at-rest), so
//     "check the label first" cannot return the raw value anyway.
//  5. webhook     — when the manifest wires a "webhook_secret" env source (a
//     template that wants ISR revalidation), UPSERT a webhook endpoint on the
//     instance for cache revalidation (dwb-5). The deploy target's URL is
//     unknown at bootstrap time (Vercel deploys after handoff), so the endpoint
//     is registered DISABLED with a placeholder URL + a crypto secret; dwb-6
//     PATCHes the real https://<site>/api/barkpark/webhook and flips active once
//     it learns the site URL. The secret is STORE-ONCE (like the read token):
//     Spec.PriorWebhookSecret carries a previously-generated one so a re-run
//     never rotates it, and the deterministic WebhookName upserts (never a
//     duplicate). No "webhook_secret" source → this step is skipped entirely.
//  6. env         — compute the deploy target's env values per the manifest's
//     env[].source wiring contract. source "webhook_secret" resolves to the
//     secret from step 5 (BARKPARK_WEBHOOK_SECRET).
//
// Everything is plain admin-token HTTPS against the instance's SCOPED URL
// (`/w/<ws>/p/default/v1/…`, never the flat `/v1` alias — gotcha #1: the flat
// alias resolves to the Default workspace and writes land in the wrong tenant).
package bootstrap

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apierr"
	"github.com/FRIKKern/barkpark/internal/template"
)

// Project is the Barkpark project slug a fresh workspace bootstraps with — the
// instance's workspace-create makes a "Default" project reachable at this slug.
const Project = "default"

// TokenLabel is the deterministic label the bootstrap read token is minted
// under. Fixed so a human (or a future label-aware mint) can recognise the
// bootstrap-owned token on the instance.
const TokenLabel = "bootstrap-public-read"

// WebhookName is the deterministic name the ISR-revalidation webhook is
// registered under. Fixed so a re-run UPSERTS by name (never a duplicate) and
// dwb-6 can find the bootstrap-owned endpoint to PATCH the real site URL.
const WebhookName = "bootstrap-revalidation"

// WebhookPath is the route @barkpark/nextjs mounts createWebhookHandler at — the
// path dwb-6 appends to the learned site origin when it PATCHes the real URL.
const WebhookPath = "/api/barkpark/webhook"

// WebhookPlaceholderURL is the disabled endpoint's stand-in target. The deploy
// target's real origin is unknown at bootstrap time (Vercel deploys AFTER
// handoff), so the endpoint is created DISABLED against an RFC-2606 `.invalid`
// host that is guaranteed never to resolve. A disabled endpoint is never
// dispatched (Webhooks.active_webhooks_for filters active == true), so nothing
// is ever POSTed here; dwb-6 replaces it with the real URL + flips active.
const WebhookPlaceholderURL = "https://webhook.invalid" + WebhookPath

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
	// Caption (dwb-19) receives one CURATED plain-language caption per content
	// sub-boundary (workspace → schemas → seed → webhook) — the live sub-line
	// under the active `content` step. Distinct from Logf (the raw journal): a
	// caption is a short human sentence, never raw output, and carries NO tokens.
	// nil → no captions.
	Caption func(caption string)
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
	// PriorWebhookSecret enables the STORE-ONCE webhook-secret idempotency (the
	// mirror of PriorReadToken): when a previous run already generated + stored
	// the webhook secret for this instance, pass it here and step 5 reuses it —
	// the endpoint is upserted by name and the secret is NEVER rotated on re-run.
	PriorWebhookSecret string
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
	c.caption("Creating your workspace…")
	if err := c.ensureWorkspace(ctx, spec.WorkspaceName, spec.WorkspaceSlug); err != nil {
		return nil, fmt.Errorf("bootstrap workspace: %w", err)
	}

	// ── 2. schemas (idempotent upsert per manifest schema) ──
	if len(spec.SchemaFiles) != len(tpl.Schemas) {
		return nil, fmt.Errorf("bootstrap: got %d schema bodies for %d manifest schemas", len(spec.SchemaFiles), len(tpl.Schemas))
	}
	if n := len(spec.SchemaFiles); n > 0 {
		c.caption("Installing %d %s…", n, plural(n, "schema", "schemas"))
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
		allowedTypes, terr := schemaTypes(spec.SchemaFiles)
		if terr != nil {
			return nil, fmt.Errorf("bootstrap seed: %w", terr)
		}
		if err := c.seedAndPublish(ctx, scopedBase, dataset, spec.SeedFile, tpl.Seed, allowedTypes); err != nil {
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

	// ── 5. webhook endpoint for ISR revalidation (store-once secret) ──
	// Gated on the manifest actually wiring a "webhook_secret" env source: a
	// template that wants ISR declares BARKPARK_WEBHOOK_SECRET. No source → no
	// endpoint and no secret (the pre-dwb-5 behaviour, byte-for-byte).
	webhookSecret := ""
	if wantsWebhookSecret(tpl) {
		c.caption("Wiring instant updates…")
		secret, werr := c.ensureWebhookEndpoint(ctx, scopedBase, dataset, spec.PriorWebhookSecret)
		if werr != nil {
			return nil, fmt.Errorf("bootstrap webhook: %w", werr)
		}
		webhookSecret = secret
	}

	// ── 6. env values per the manifest's env[].source wiring ──
	env, err := resolveEnv(tpl, scopedBase, readToken, dataset, spec.WorkspaceSlug, webhookSecret)
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
// "webhook_secret" resolves to the store-once secret bound to the ISR webhook
// endpoint (step 5); an unknown source errors (template.Validate should have
// caught it, but fail closed).
func resolveEnv(tpl *template.Template, scopedBase, readToken, dataset, workspace, webhookSecret string) (map[string]string, error) {
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
			// dwb-5: the shared HMAC secret bound to the webhook endpoint. Fail
			// closed rather than emit an empty secret — wantsWebhookSecret gates
			// step 5, so a non-empty secret must exist by here.
			if webhookSecret == "" {
				return nil, fmt.Errorf("env %s: webhook secret is empty (webhook registration did not run)", e.Key)
			}
			env[e.Key] = webhookSecret
		default:
			return nil, fmt.Errorf("env %s: unknown source %q", e.Key, e.Source)
		}
	}
	return env, nil
}

// wantsWebhookSecret reports whether the manifest wires any env value from the
// "webhook_secret" source — the trigger for the ISR webhook-registration step.
func wantsWebhookSecret(tpl *template.Template) bool {
	for _, e := range tpl.Env {
		if e.Source == template.SourceWebhookSecret {
			return true
		}
	}
	return false
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
func (c Client) seedAndPublish(ctx context.Context, scopedBase, dataset string, seed []byte, s *template.Seed, allowedTypes map[string]bool) error {
	// Type validation runs BEFORE the mutate POST, not between the two passes:
	// a seed whose types are wrong would otherwise land as drafts and then fail
	// to publish, leaving content the owner never asked for behind.
	var docs []seedDoc
	if s.Publish {
		parsed, perr := seedDocs(seed)
		if perr != nil {
			return perr
		}
		if len(parsed) == 0 {
			return fmt.Errorf("publish: the seed carries no document ids to publish")
		}
		if verr := validateSeedTypes(parsed, allowedTypes, s.PublishType); verr != nil {
			return fmt.Errorf("publish: %w", verr)
		}
		docs = parsed
	}

	c.caption("Adding your sample content…")
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
	c.caption("Publishing %d sample %s…", len(docs), plural(len(docs), "document", "documents"))
	pubBody, _ := json.Marshal(publishPayload(docs, s.PublishType))
	status, respBody, err = c.doJSON(ctx, http.MethodPost, u, pubBody)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("publish: status %d: %s", status, snippet(respBody))
	}
	c.logf("bootstrap: published %d document(s) of type(s) %q", len(docs), publishTypeSummary(docs, s.PublishType))
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
		return "", fmt.Errorf("status %d: %s", status, mintRefusal(respBody))
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

// ensureWebhookEndpoint UPSERTS the ISR-revalidation webhook on the instance and
// returns the secret bound to it. It is IDEMPOTENT by the deterministic
// WebhookName: a re-run finds the existing endpoint and converges instead of
// duplicating.
//
// STORE-ONCE secret: when priorSecret is non-empty a previous run already
// generated + stored it, so it is reused and NEVER rotated (mirrors the read
// token). Otherwise a fresh cryptographically-random secret is minted; if an
// endpoint already exists from an earlier run whose secret was never stored (a
// crash between create and outputs-report), the fresh secret is re-bound so the
// endpoint and the reported BARKPARK_WEBHOOK_SECRET agree — safe because the
// endpoint is still a DISABLED placeholder (no site is wired to the old secret).
// An already-ACTIVE endpoint (dwb-6 wired the real URL) is left untouched.
//
// The endpoint is registered DISABLED with WebhookPlaceholderURL: the deploy
// target's real URL is unknown until Vercel deploys after handoff, so dwb-6
// PATCHes the URL + flips active later. The raw secret rides back ONLY in the
// return value.
func (c Client) ensureWebhookEndpoint(ctx context.Context, scopedBase, dataset, priorSecret string) (string, error) {
	secret := priorSecret
	if secret == "" {
		s, err := generateWebhookSecret()
		if err != nil {
			return "", err
		}
		secret = s
	}

	id, active, err := c.findWebhook(ctx, scopedBase, dataset, WebhookName)
	if err != nil {
		return "", err
	}
	switch {
	case id == "":
		if err := c.createWebhook(ctx, scopedBase, dataset, secret); err != nil {
			return "", err
		}
		c.logf("bootstrap: registered %q webhook (disabled, placeholder URL — dwb-6 wires the real site URL)", WebhookName)
	case priorSecret == "" && !active:
		// Crash-recovery convergence: the endpoint exists but its secret was
		// never stored, and it is still a disabled placeholder — re-bind our
		// fresh secret so outputs match the endpoint.
		if err := c.updateWebhookSecret(ctx, scopedBase, dataset, id, secret); err != nil {
			return "", err
		}
		c.logf("bootstrap: re-bound secret on existing %q webhook (converge)", WebhookName)
	default:
		c.logf("bootstrap: %q webhook already present (store-once — no duplicate, no secret rotation)", WebhookName)
	}
	return secret, nil
}

// generateWebhookSecret mints the shared HMAC secret the instance's dispatcher
// signs with and the @barkpark/nextjs handler verifies with: 32 crypto/rand
// bytes, hex-encoded (64 lowercase chars — env-safe, no escaping). NEVER logged.
func generateWebhookSecret() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate webhook secret: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// findWebhook lists the dataset's webhooks over the scoped admin endpoint and
// returns the (id, active) of the one named `name`, or ("", false, nil) when
// none match. The list render never carries the secret, so this cannot (and
// must not) recover it — hence the store-once priorSecret path.
func (c Client) findWebhook(ctx context.Context, scopedBase, dataset, name string) (string, bool, error) {
	u := scopedBase + "/v1/webhooks/" + url.PathEscape(dataset)
	status, body, err := c.doJSON(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", false, err
	}
	if status < 200 || status >= 300 {
		return "", false, fmt.Errorf("list: status %d: %s", status, snippet(body))
	}
	var resp struct {
		Webhooks []struct {
			ID     string `json:"id"`
			Name   string `json:"name"`
			Active bool   `json:"active"`
		} `json:"webhooks"`
	}
	if jerr := json.Unmarshal(body, &resp); jerr != nil {
		return "", false, fmt.Errorf("parse list: %w", jerr)
	}
	for _, w := range resp.Webhooks {
		if w.Name == name {
			return w.ID, w.Active, nil
		}
	}
	return "", false, nil
}

// createWebhook POSTs a DISABLED endpoint bound to the shared secret over the
// scoped admin webhook endpoint. events:[] = every mutation event (full ISR
// coverage); the placeholder URL + active:false keep it inert until dwb-6.
func (c Client) createWebhook(ctx context.Context, scopedBase, dataset, secret string) error {
	body, _ := json.Marshal(map[string]any{
		"name":   WebhookName,
		"url":    WebhookPlaceholderURL,
		"secret": secret,
		"events": []string{}, // empty = fire on every event (full revalidation)
		"active": false,      // inert until dwb-6 PATCHes the real site URL
	})
	status, respBody, err := c.doJSON(ctx, http.MethodPost, scopedBase+"/v1/webhooks/"+url.PathEscape(dataset), body)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("create: status %d: %s", status, snippet(respBody))
	}
	return nil
}

// updateWebhookSecret PUTs only the secret onto an existing endpoint (the
// changeset leaves url/events/active intact). Used only for crash-recovery
// convergence on a still-disabled placeholder.
func (c Client) updateWebhookSecret(ctx context.Context, scopedBase, dataset, id, secret string) error {
	body, _ := json.Marshal(map[string]any{"secret": secret})
	u := scopedBase + "/v1/webhooks/" + url.PathEscape(dataset) + "/" + url.PathEscape(id)
	status, respBody, err := c.doJSON(ctx, http.MethodPut, u, body)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("update: status %d: %s", status, snippet(respBody))
	}
	return nil
}

// seedDoc is one seeded document's publish identity: the id the mutation
// created and the _type the document declares for ITSELF. A seed may mix types
// (a posts/authors/categories graph), so the type travels PER DOCUMENT rather
// than once for the whole batch.
type seedDoc struct {
	ID string
	// Type is the document's own "_type". Empty when the seed document omits
	// it — the manifest's seed.publishType is then the fallback.
	Type string
}

// seedDocs extracts (id, _type) pairs from a {"mutations":[…]} seed payload —
// createOrReplace first, then create (the same extraction the CLI quick-setup
// performs).
func seedDocs(seed []byte) ([]seedDoc, error) {
	var env struct {
		Mutations []struct {
			CreateOrReplace map[string]json.RawMessage `json:"createOrReplace"`
			Create          map[string]json.RawMessage `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(seed, &env); err != nil {
		return nil, fmt.Errorf("parse seed mutations: %w", err)
	}
	var docs []seedDoc
	for _, m := range env.Mutations {
		for _, doc := range []map[string]json.RawMessage{m.CreateOrReplace, m.Create} {
			if id := rawString(doc, "_id"); id != "" {
				docs = append(docs, seedDoc{ID: id, Type: rawString(doc, "_type")})
				break
			}
		}
	}
	return docs, nil
}

// rawString pulls a string field out of a mutation document map. A missing key
// and a non-string value are both reported as "" — the caller decides whether
// that is fatal (validateSeedTypes does, for "_type").
func rawString(doc map[string]json.RawMessage, key string) string {
	if doc == nil {
		return ""
	}
	raw, ok := doc[key]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return s
}

// schemaTypes is the set of document types the manifest's schema bodies
// DECLARE (each schema file's top-level "name"). It is the allowlist a seed
// document's _type is checked against; a schema body the bootstrap cannot parse
// is an error rather than a silently empty allowlist, because an empty
// allowlist would wave every type through.
func schemaTypes(files [][]byte) (map[string]bool, error) {
	types := make(map[string]bool, len(files))
	for i, body := range files {
		var s struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(body, &s); err != nil {
			return nil, fmt.Errorf("parse schema body %d: %w", i, err)
		}
		if name := strings.TrimSpace(s.Name); name != "" {
			types[name] = true
		}
	}
	return types, nil
}

// validateSeedTypes checks EVERY seeded document resolves to a legal publish
// type BEFORE any mutation is POSTed. Publishing is a second pass, so a batch
// that fails halfway leaves drafts the owner never asked for: the whole seed is
// refused up front instead.
//
// Resolution order per document: the document's own "_type", else the
// manifest's seed.publishType. The result must be non-empty AND, when the
// manifest declared schemas, one of the types those schemas declare.
func validateSeedTypes(docs []seedDoc, allowed map[string]bool, fallbackType string) error {
	fallbackType = strings.TrimSpace(fallbackType)
	for _, d := range docs {
		t := strings.TrimSpace(d.Type)
		if t == "" {
			t = fallbackType
		}
		if t == "" {
			return fmt.Errorf("document %q declares no _type and the manifest sets no seed.publishType", d.ID)
		}
		if len(allowed) > 0 && !allowed[t] {
			return fmt.Errorf("document %q has type %q, which no manifest schema declares (declared: %s)", d.ID, t, strings.Join(sortedKeys(allowed), ", "))
		}
	}
	return nil
}

// sortedKeys renders an allowlist deterministically so the refusal message is
// stable across runs (map iteration order is not).
func sortedKeys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// publishPayload builds {"mutations":[{"publish":{"id","type"}}]} — publish
// needs BOTH id and type, else the instance 400s. Each document publishes under
// its OWN _type; fallbackType (the manifest's seed.publishType) covers a
// document that omits one. validateSeedTypes has already proven every resolved
// type is non-empty and legal.
func publishPayload(docs []seedDoc, fallbackType string) map[string]any {
	fallbackType = strings.TrimSpace(fallbackType)
	muts := make([]map[string]any, 0, len(docs))
	for _, d := range docs {
		t := strings.TrimSpace(d.Type)
		if t == "" {
			t = fallbackType
		}
		muts = append(muts, map[string]any{
			"publish": map[string]string{"id": d.ID, "type": t},
		})
	}
	return map[string]any{"mutations": muts}
}

// publishTypeSummary renders the DISTINCT types a publish pass covered, for the
// journal line — a single-type seed still reads as one type, a mixed seed names
// them all instead of quoting one and hiding the rest.
func publishTypeSummary(docs []seedDoc, fallbackType string) string {
	seen := map[string]bool{}
	for _, d := range docs {
		t := strings.TrimSpace(d.Type)
		if t == "" {
			t = strings.TrimSpace(fallbackType)
		}
		if t != "" {
			seen[t] = true
		}
	}
	return strings.Join(sortedKeys(seen), ", ")
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

// mintRefusal renders a token-mint refusal. The instance's 403 (the
// :scoped_admin gate, RequireWorkspaceRole) is the canonical envelope
// {"error":{"code":"forbidden","message":…,"hint":…}}, and its hint is the
// sentence naming the role the gate wanted — so a forbidden refusal renders as
// "forbidden: <message> — <hint>", read through internal/apierr (the one shared
// envelope parser). Every other body keeps the raw snippet it always rendered.
func mintRefusal(body []byte) string {
	env, ok := apierr.Parse(body)
	if !ok || env.Code != "forbidden" {
		return snippet(body)
	}
	msg := "forbidden: " + env.Summary()
	if h := env.HintLine(); h != "" {
		msg += " — " + h
	}
	return msg
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

// caption is nil-safe live sub-caption narration (dwb-19). It formats a curated
// plain-language line for the live `content` step sub-caption. Callers MUST pass
// only human copy (counts, names) — never a token.
func (c Client) caption(format string, args ...any) {
	if c.Caption != nil {
		c.Caption(fmt.Sprintf(format, args...))
	}
}

// plural picks the singular or plural noun for n (dwb-19 caption copy).
func plural(n int, singular, pluralForm string) string {
	if n == 1 {
		return singular
	}
	return pluralForm
}
