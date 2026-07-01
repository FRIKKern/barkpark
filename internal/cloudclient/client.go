// Package cloudclient is a framework-free HTTP client for the Barkpark Cloud
// CONTROL PLANE — a separate service from the content API that apiclient talks
// to. Where apiclient is scoped to ONE content server (workspace/project/dataset
// routing, the dev bearer token), cloudclient is scoped to the user's whole
// Barkpark FLEET: it logs a user in, lists every Barkpark they own, connects a
// cloud provider, launches a server, and "goes live".
//
// It deliberately mirrors apiclient's idiom — a small struct carrying BaseURL +
// Token + an injectable *http.Client, requests built by hand with net/http, a
// Bearer auth header on every authed call, and an honest error decode that
// surfaces the control plane's {"error":...} message instead of swallowing it —
// but it shares no code and no types: the two clients answer to different
// services and must be free to drift.
//
// YAGNI by design (cloud-12b): no retries, no pagination, no websocket, no warm-
// pool poll. The five methods below are exactly the surface the user-facing `bp`
// Cloud commands drive; the real provisioning happens server-side and is
// reflected back in the returned Barkpark row.
package cloudclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// DefaultTimeout is the per-request HTTP timeout when Client.HTTP is nil and we
// construct the fallback client. Login + a fleet list are quick control-plane
// calls; 30s is generous headroom without hanging a CLI invocation forever.
const DefaultTimeout = 30 * time.Second

// DefaultBaseURL is the production control-plane URL the CLI defaults to when no
// --url flag and no saved CloudURL override it.
const DefaultBaseURL = "https://api.barkpark.cloud"

// Client talks to the Barkpark Cloud control plane. BaseURL is the control-plane
// root (no trailing slash needed — it is trimmed); Token is the user session
// token attached as a Bearer header to every authed call (empty for Login).
// HTTP is injectable so tests point it at an httptest.Server; a nil HTTP uses a
// lazily-built client with DefaultTimeout.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// Barkpark is one registered server in the user's fleet, as returned by
// GET /v1/barkparks (and embedded in launch / go-live responses). The JSON tags
// match the control plane's serialization 1:1 — the two status axes
// (health_status / agent_status) are kept distinct on purpose.
type Barkpark struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Slug         string `json:"slug"`
	URL          string `json:"url"`
	Host         string `json:"host"`
	Mode         string `json:"mode"`
	HealthStatus string `json:"health_status"`
	AgentStatus  string `json:"agent_status"`
	Version      string `json:"version"`
	GitCommit    string `json:"git_commit"`
	LastSeenAt   string `json:"last_seen_at"`
	TeamID       string `json:"team_id"`
	InsertedAt   string `json:"inserted_at"`
}

// Provider is a connected cloud account (e.g. a Hetzner token) the control plane
// can provision Barkparks into, as returned by POST /v1/providers. The token is
// never echoed back — only the metadata the user can safely see.
type Provider struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	Label      string `json:"label"`
	TeamID     string `json:"team_id"`
	InsertedAt string `json:"inserted_at"`
}

// LoginResp is the body of a successful POST /v1/auth/login: the plaintext user
// session token to store, and the team the user belongs to (null → empty when
// the user has no team yet).
type LoginResp struct {
	Token  string `json:"token"`
	TeamID string `json:"team_id"`
}

// CheckoutResp is the body of a successful POST /v1/billing/checkout: the hosted
// checkout URL the customer opens in a browser to add a card and activate a
// subscription. The control plane resolves the price id for the requested plan
// and binds the session to the AUTHED user's team — the team is never client-
// supplied, so this envelope carries only the URL.
type CheckoutResp struct {
	CheckoutURL string `json:"checkout_url"`
}

// httpClient returns the configured *http.Client, or a lazily-built one with the
// default timeout. Tests always inject HTTP, so the fallback is the real-CLI
// path only.
func (c *Client) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: DefaultTimeout}
}

// url joins the (trimmed) BaseURL with a leading-slash path segment. It is the
// single place that knows the control-plane URL scheme — there is no workspace/
// project routing here, unlike apiclient.scopedURL.
func (c *Client) url(path string) string {
	return strings.TrimRight(c.BaseURL, "/") + path
}

// do issues one control-plane request: it marshals body (when non-nil) to JSON,
// attaches the Bearer token when auth is true, and returns the decoded status +
// response body. It is the shared core all five methods route through, mirroring
// apiclient's hand-built net/http requests.
func (c *Client) do(ctx context.Context, method, path string, auth bool, body any) (int, []byte, error) {
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, fmt.Errorf("marshal request: %w", err)
		}
		rdr = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.url(path), rdr)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if auth && c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, raw, nil
}

// cloudError turns a non-2xx control-plane response into a one-line error,
// surfacing the {"error":"<message>"} field the API returns (e.g. "name_required"
// from a 422 go-live, or an auth message from a 401). When the body carries no
// recognisable error field it falls back to "status <code>: <clamped body>" so
// nothing is ever swallowed. A 401 is prefixed with "unauthorized:" so callers
// (and users) read the auth failure plainly.
func cloudError(status int, body []byte) error {
	var env struct {
		Error string `json:"error"`
	}
	msg := ""
	if json.Unmarshal(body, &env) == nil && env.Error != "" {
		msg = env.Error
	}
	if msg == "" {
		raw := strings.TrimSpace(string(body))
		if r := []rune(raw); len(r) > 200 {
			raw = string(r[:200]) + "…"
		}
		if raw == "" {
			msg = http.StatusText(status)
		} else {
			msg = raw
		}
	}
	if status == http.StatusUnauthorized {
		return fmt.Errorf("unauthorized: %s", msg)
	}
	return fmt.Errorf("%s", msg)
}

// ok reports whether status is a 2xx.
func ok(status int) bool { return status >= 200 && status < 300 }

// Login exchanges email + password for a user session token via
// POST /v1/auth/login. It is the only UNauthed method — there is no token yet.
// A 401 (or any non-2xx) surfaces an honest auth error; a 200 decodes the token
// + team the caller stores in config.
func (c *Client) Login(ctx context.Context, email, password string) (LoginResp, error) {
	status, body, err := c.do(ctx, "POST", "/v1/auth/login", false, map[string]string{
		"email":    email,
		"password": password,
	})
	if err != nil {
		return LoginResp{}, err
	}
	if !ok(status) {
		return LoginResp{}, cloudError(status, body)
	}
	var out LoginResp
	if err := json.Unmarshal(body, &out); err != nil {
		return LoginResp{}, fmt.Errorf("decode login response: %w", err)
	}
	return out, nil
}

// Register creates a new account via POST /v1/auth/register and logs the user in
// in one shot: the control plane creates the user, a team (team defaults from the
// email local-part when team is ""), an owner membership, and a session token,
// then returns the same {token, team_id} envelope as Login. It is the second
// UNauthed method — like Login there is no token yet, so no Bearer is sent.
//
// team is sent as team_name only when non-empty (an empty value lets the server
// derive the default slug). A 201 decodes the token + team the caller stores in
// config; a non-2xx surfaces the control plane's honest error verbatim — 409
// "email_taken" (the address is registered), 422 "<field>_invalid" /
// "validation_failed" (weak password / bad email). cloudError carries each
// message through, so the CLI can match on it.
func (c *Client) Register(ctx context.Context, email, password, team string) (LoginResp, error) {
	req := map[string]string{"email": email, "password": password}
	if team != "" {
		req["team_name"] = team
	}
	status, body, err := c.do(ctx, "POST", "/v1/auth/register", false, req)
	if err != nil {
		return LoginResp{}, err
	}
	if !ok(status) {
		return LoginResp{}, cloudError(status, body)
	}
	var out LoginResp
	if err := json.Unmarshal(body, &out); err != nil {
		return LoginResp{}, fmt.Errorf("decode register response: %w", err)
	}
	return out, nil
}

// CreateCheckout starts a subscription checkout for plan via
// POST /v1/billing/checkout (Bearer). The control plane resolves the plan's
// price id and opens a hosted checkout session bound to the AUTHED user's team —
// the client NEVER supplies a team id; it is read server-side from the session
// token. A 200 decodes the {checkout_url} the customer opens in a browser to add
// a card and activate the subscription; a non-2xx surfaces the control plane's
// honest error verbatim — notably 422 "plan_invalid" for an unknown plan or the
// "free" tier (which needs no checkout). It mirrors Login's hand-built request.
func (c *Client) CreateCheckout(ctx context.Context, plan string) (CheckoutResp, error) {
	status, body, err := c.do(ctx, "POST", "/v1/billing/checkout", true, map[string]string{
		"plan": plan,
	})
	if err != nil {
		return CheckoutResp{}, err
	}
	if !ok(status) {
		return CheckoutResp{}, cloudError(status, body)
	}
	var out CheckoutResp
	if err := json.Unmarshal(body, &out); err != nil {
		return CheckoutResp{}, fmt.Errorf("decode checkout response: %w", err)
	}
	return out, nil
}

// ListBarkparks returns the user's whole fleet via GET /v1/barkparks (Bearer).
// This is the AUTHORITATIVE registry view `bp barkparks` renders when a cloud
// token is present (vs. the local KnownServers fallback in cloud-11).
func (c *Client) ListBarkparks(ctx context.Context) ([]Barkpark, error) {
	status, body, err := c.do(ctx, "GET", "/v1/barkparks", true, nil)
	if err != nil {
		return nil, err
	}
	if !ok(status) {
		return nil, cloudError(status, body)
	}
	var out struct {
		Barkparks []Barkpark `json:"barkparks"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode barkparks response: %w", err)
	}
	return out.Barkparks, nil
}

// Credentials is the body of GET /v1/barkparks/:id/credentials — the
// per-instance admin bearer the warm-pool minted on the box (instance-admin-token),
// decrypted server-side for the OWNER, plus the instance URL/host for convenience.
// The token is a secret: it is printed once for the user to store safely and is
// never persisted by the CLI.
type Credentials struct {
	AdminToken string `json:"admin_token"`
	URL        string `json:"url"`
	Host       string `json:"host"`
}

// GetCredentials fetches a Barkpark's stored admin token via
// GET /v1/barkparks/:id/credentials (Bearer). The route is team-admin-gated and
// team-scoped: a non-admin gets 403 and an instance in another team (or no such
// id) is the SAME 404 (no existence leak) — both surface verbatim via cloudError.
// A 404 "no_admin_token" means the instance never had one captured (e.g. an
// ip-only/legacy provision).
func (c *Client) GetCredentials(ctx context.Context, id string) (Credentials, error) {
	status, body, err := c.do(ctx, "GET", "/v1/barkparks/"+id+"/credentials", true, nil)
	if err != nil {
		return Credentials{}, err
	}
	if !ok(status) {
		return Credentials{}, cloudError(status, body)
	}
	var out Credentials
	if err := json.Unmarshal(body, &out); err != nil {
		return Credentials{}, fmt.Errorf("decode credentials response: %w", err)
	}
	return out, nil
}

// ConnectProvider links a cloud account (kind + plaintext token, optional label)
// via POST /v1/providers (Bearer). The control plane encrypts the token at rest
// and returns only the safe metadata. label is sent only when non-empty.
func (c *Client) ConnectProvider(ctx context.Context, kind, token, label string) (Provider, error) {
	req := map[string]string{"kind": kind, "token": token}
	if label != "" {
		req["label"] = label
	}
	status, body, err := c.do(ctx, "POST", "/v1/providers", true, req)
	if err != nil {
		return Provider{}, err
	}
	if !ok(status) {
		return Provider{}, cloudError(status, body)
	}
	var out struct {
		Provider Provider `json:"provider"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Provider{}, fmt.Errorf("decode provider response: %w", err)
	}
	return out.Provider, nil
}

// Launch provisions a Barkpark into a connected provider via POST /v1/launch
// (Bearer). provider is the provider id/kind to launch into (sent only when
// non-empty so the control plane can pick the Team's default); name is the new
// Barkpark's name. The returned row reflects the provisioning state — actual
// provisioning runs server-side (the Go warm-pool, cloud-6), not here.
func (c *Client) Launch(ctx context.Context, provider, name string) (Barkpark, error) {
	req := map[string]string{"name": name}
	if provider != "" {
		req["provider"] = provider
	}
	return c.launchLike(ctx, "/v1/launch", req)
}

// GoLive provisions a fully-managed Barkpark via POST /v1/go-live (Bearer) — the
// zero-config path where the control plane owns the infra (no BYO provider). name
// is required (a missing name surfaces the control plane's 422 "name_required");
// plan is the optional billing plan (sent only when non-empty).
func (c *Client) GoLive(ctx context.Context, name, plan string) (Barkpark, error) {
	req := map[string]string{"name": name}
	if plan != "" {
		req["plan"] = plan
	}
	return c.launchLike(ctx, "/v1/go-live", req)
}

// launchLike is the shared POST-then-unwrap-{"barkpark":…} core behind Launch and
// GoLive — both return a single provisioned Barkpark row in the same envelope.
func (c *Client) launchLike(ctx context.Context, path string, req map[string]string) (Barkpark, error) {
	status, body, err := c.do(ctx, "POST", path, true, req)
	if err != nil {
		return Barkpark{}, err
	}
	if !ok(status) {
		return Barkpark{}, cloudError(status, body)
	}
	var out struct {
		Barkpark Barkpark `json:"barkpark"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Barkpark{}, fmt.Errorf("decode launch response: %w", err)
	}
	return out.Barkpark, nil
}

// Site is one hosted website running co-located with a Barkpark, as returned by
// the /v1/sites endpoints (control plane, cloud-12c). Mirrors the site_json
// shape in cloud/lib/barkpark_cloud/web/router.ex — the env blob is NEVER
// echoed back, only metadata. `CurrentDeploymentID` is the live deployment
// pointer the on-box runtime is serving from.
type Site struct {
	ID                  string   `json:"id"`
	BarkparkID          string   `json:"barkpark_id"`
	TeamID              string   `json:"team_id"`
	Name                string   `json:"name"`
	Slug                string   `json:"slug"`
	Framework           string   `json:"framework"`
	Domains             []string `json:"domains"`
	ScaleMode           string   `json:"scale_mode"`
	Port                int      `json:"port"`
	CurrentDeploymentID string   `json:"current_deployment_id"`
	// P7 github-webhook: GitHub link metadata (the encrypted secret never
	// appears in JSON; `GithubWebhookConfigured` is a server-computed bool).
	GithubRepo              string `json:"github_repo,omitempty"`
	GithubBranch            string `json:"github_branch,omitempty"`
	GithubWebhookConfigured bool   `json:"github_webhook_configured,omitempty"`
	InsertedAt              string `json:"inserted_at"`
	UpdatedAt               string `json:"updated_at"`
}

// Deployment is one build-and-release of a Site, as returned by the
// /v1/sites/:id/deploy + /v1/sites/:id/deployments endpoints. `Status` walks
// queued → building → pushing → live (or failed). `BuildLogURL` is opaque to
// the control plane — `bp sites logs <site>` prints it as a best-effort
// pointer at the builder's log surface.
type Deployment struct {
	ID            string `json:"id"`
	SiteID        string `json:"site_id"`
	Status        string `json:"status"`
	GitRef        string `json:"git_ref"`
	ArtifactURL   string `json:"artifact_url"`
	ImageTag      string `json:"image_tag"`
	BuildLogURL   string `json:"build_log_url"`
	FailureReason string `json:"failure_reason"`
	BecameLiveAt  string `json:"became_live_at"`
	InsertedAt    string `json:"inserted_at"`
	UpdatedAt     string `json:"updated_at"`
}

// SiteCreate is the body the CLI POSTs to /v1/sites. Pointer-ish optionality
// is encoded by omitempty so a zero-value field is left unset on the wire —
// the server fills in defaults (framework "nextjs", scale_mode "always_on").
type SiteCreate struct {
	BarkparkID string   `json:"barkpark_id"`
	Name       string   `json:"name"`
	Framework  string   `json:"framework,omitempty"`
	Domains    []string `json:"domains,omitempty"`
	ScaleMode  string   `json:"scale_mode,omitempty"`
}

// ListSites returns every site under the user's team via GET /v1/sites
// (Bearer). The control plane scopes results to the caller's team — a wrong
// team gets an empty list, not a 403.
func (c *Client) ListSites(ctx context.Context) ([]Site, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites", true, nil)
	if err != nil {
		return nil, err
	}
	if !ok(status) {
		return nil, cloudError(status, body)
	}
	var out struct {
		Sites []Site `json:"sites"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode sites response: %w", err)
	}
	return out.Sites, nil
}

// GetSite returns one site by id via GET /v1/sites/:id (Bearer). A 404 from
// either "no such site" or "site in another team" surfaces verbatim — the
// control plane does NOT leak existence across team boundaries.
func (c *Client) GetSite(ctx context.Context, id string) (Site, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites/"+id, true, nil)
	if err != nil {
		return Site{}, err
	}
	if !ok(status) {
		return Site{}, cloudError(status, body)
	}
	var out struct {
		Site Site `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Site{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// CreateSite POSTs /v1/sites (Bearer) and returns the new row. `BarkparkID`
// is the underlying Barkpark UUID the site lives on — the CLI resolves
// `--barkpark <slug>` to this id via ListBarkparks before calling.
func (c *Client) CreateSite(ctx context.Context, req SiteCreate) (Site, error) {
	status, body, err := c.do(ctx, "POST", "/v1/sites", true, req)
	if err != nil {
		return Site{}, err
	}
	if !ok(status) {
		return Site{}, cloudError(status, body)
	}
	var out struct {
		Site Site `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Site{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// Deploy enqueues a Deployment row via POST /v1/sites/:id/deploy (Bearer).
// `gitRef` and `artifactURL` are optional — at least one is needed in
// practice for the builder to do anything; the CLI requires `--artifact-url`
// until the tarball-upload route lands (P7). The returned Deployment is
// status:"queued" — the builder polls and walks it through.
func (c *Client) Deploy(ctx context.Context, siteID, gitRef, artifactURL string) (Deployment, error) {
	req := map[string]string{}
	if gitRef != "" {
		req["git_ref"] = gitRef
	}
	if artifactURL != "" {
		req["artifact_url"] = artifactURL
	}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+siteID+"/deploy", true, req)
	if err != nil {
		return Deployment{}, err
	}
	if !ok(status) {
		return Deployment{}, cloudError(status, body)
	}
	var out struct {
		Deployment Deployment `json:"deployment"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Deployment{}, fmt.Errorf("decode deployment response: %w", err)
	}
	return out.Deployment, nil
}

// ListDeployments returns a site's deployments newest-first via
// GET /v1/sites/:id/deployments (Bearer).
func (c *Client) ListDeployments(ctx context.Context, siteID string) ([]Deployment, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites/"+siteID+"/deployments", true, nil)
	if err != nil {
		return nil, err
	}
	if !ok(status) {
		return nil, cloudError(status, body)
	}
	var out struct {
		Deployments []Deployment `json:"deployments"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode deployments response: %w", err)
	}
	return out.Deployments, nil
}

// SetEnv REPLACES the encrypted env blob via POST /v1/sites/:id/env (Bearer).
// The control plane re-encrypts the whole map at rest — there is no
// merge-on-server. The CLI's `bp sites env set` is responsible for any
// upstream merge (read current env from the user, overlay the K=V pairs).
// On 200 the server returns {"ok": true} with no body shape to decode.
func (c *Client) SetEnv(ctx context.Context, siteID string, env map[string]string) error {
	req := map[string]any{"env": env}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+siteID+"/env", true, req)
	if err != nil {
		return err
	}
	if !ok(status) {
		return cloudError(status, body)
	}
	return nil
}

// ArtifactUpload is the response shape from POST /v1/sites/:id/artifact: the
// `file://` URL the control plane wrote the tarball to (passed verbatim into
// /deploy as `artifact_url`), the byte count for the user-facing summary, and
// the on-disk filename so logs can echo it.
type ArtifactUpload struct {
	ArtifactURL string `json:"artifact_url"`
	Bytes       int64  `json:"bytes"`
	Filename    string `json:"filename"`
}

// UploadArtifact streams a tarball to POST /v1/sites/:id/artifact as
// application/octet-stream (Bearer). The reader is read in full and shipped
// without buffering — a 100 MB project tar.gz never goes through json.Marshal
// or sits in a byte slice. The returned `artifact_url` is the `file://` URL
// the builder reads next; the caller hands it to Deploy.
//
// A 413 surfaces as "artifact_too_large" via cloudError; a 404 (site in
// another team, or no such id) propagates the control plane's no-leak error.
func (c *Client) UploadArtifact(ctx context.Context, siteID string, body io.Reader) (ArtifactUpload, error) {
	if body == nil {
		return ArtifactUpload{}, fmt.Errorf("upload artifact: nil body")
	}
	req, err := http.NewRequestWithContext(ctx, "POST", c.url("/v1/sites/"+siteID+"/artifact"), body)
	if err != nil {
		return ArtifactUpload{}, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	// A large tarball over a slow link easily exceeds the shared 30s
	// DefaultTimeout — and http.Client.Timeout is an absolute deadline over the
	// whole body stream that ctx cannot extend. So the upload path deliberately
	// uses a client with no wall-clock cap: cancellation is bounded only by the
	// caller's ctx. The injected client (tests) is honored when present.
	client := c.HTTP
	if client == nil {
		client = &http.Client{}
	}
	resp, err := client.Do(req)
	if err != nil {
		return ArtifactUpload{}, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return ArtifactUpload{}, fmt.Errorf("read upload response: %w", err)
	}
	if !ok(resp.StatusCode) {
		return ArtifactUpload{}, cloudError(resp.StatusCode, raw)
	}
	var out ArtifactUpload
	if err := json.Unmarshal(raw, &out); err != nil {
		return ArtifactUpload{}, fmt.Errorf("decode upload response: %w", err)
	}
	return out, nil
}

// AddDomain appends a hostname to the site's domains array via
// POST /v1/sites/:id/domains (Bearer). The returned Site reflects the new
// array; the domain becomes acceptable to the on-demand-TLS ask gate
// immediately.
func (c *Client) AddDomain(ctx context.Context, siteID, domain string) (Site, error) {
	req := map[string]string{"domain": domain}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+siteID+"/domains", true, req)
	if err != nil {
		return Site{}, err
	}
	if !ok(status) {
		return Site{}, cloudError(status, body)
	}
	var out struct {
		Site Site `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Site{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// GithubConnectResp is the body the control plane returns from
// POST /v1/sites/:id/github — the updated Site row, the webhook URL the user
// pastes into GitHub, and the plaintext webhook secret (shown ONCE; the
// server stores only the Vault-encrypted blob).
type GithubConnectResp struct {
	Site          Site   `json:"site"`
	WebhookURL    string `json:"webhook_url"`
	WebhookSecret string `json:"webhook_secret"`
}

// GithubConnect links a Site to a GitHub repo + branch via
// POST /v1/sites/:id/github (Bearer). `repo` is the conventional "owner/repo"
// form; `branch` is optional (the server defaults to "main"); `secret` is
// optional (when empty, the server generates a fresh random one and returns
// it ONCE in the response).
//
// The response carries the plaintext `webhook_secret` and the `webhook_url`
// the user pastes into GitHub's "Add webhook" form. The plaintext is shown
// here and nowhere else — the only persistent copy is the encrypted-at-rest
// blob on the Site row.
func (c *Client) GithubConnect(ctx context.Context, siteID, repo, branch, secret string) (GithubConnectResp, error) {
	req := map[string]string{"repo": repo}
	if branch != "" {
		req["branch"] = branch
	}
	if secret != "" {
		req["webhook_secret"] = secret
	}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+siteID+"/github", true, req)
	if err != nil {
		return GithubConnectResp{}, err
	}
	if !ok(status) {
		return GithubConnectResp{}, cloudError(status, body)
	}
	var out GithubConnectResp
	if err := json.Unmarshal(body, &out); err != nil {
		return GithubConnectResp{}, fmt.Errorf("decode github connect response: %w", err)
	}
	return out, nil
}
