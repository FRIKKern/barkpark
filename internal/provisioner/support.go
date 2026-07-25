// support.go — the provision_support chain (Personal Dev Fleet MVP-0,
// PDF-D83/D84/D88/D89): the SERVER-SIDE re-host of `bp cloud support add`'s
// bring-up, executed by this worker from a control-plane claim instead of a
// developer laptop. The console journey needs no local Hetzner token — the
// worker's env carries HCLOUD_TOKEN exactly as it does for mains (PDF-D83).
//
// The chain REUSES the cloud-package support primitives the CLI surface uses
// (cloud.CreateSupportServer / cloud.ConfigureSupportHost / cloud.SupportRunner
// / cloud.NewSSHStepRunner) and REIMPLEMENTS the orchestration that lives in
// internal/cli/cloud_support_cmd.go — that file is laptop-shaped (resolveContext,
// bp-login CloudClient), while this one runs everything from CLAIM-PAYLOAD
// credentials. HARD LAW: package internal/cli is NEVER imported here.
//
// Steps are reported ONLY as create → configure → content → verify → ready
// (PDF-D84 — the control plane's validate_step 422s anything else; freshen/
// secure are never emitted for a support):
//
//	create     provider box (x86 warm image, identity label) + SSH wait-ready
//	configure  cloud.ConfigureSupportHost — the reduced go-live subset
//	content    roster row (provisioning) + ledger-token mint on the PARENT MAIN
//	           + scrubbed dataset export streamed over SSH + on-box merge-import
//	verify     listener runtime install (LEDGER token only — provider keys are
//	           NEVER written, PDF-D62/D88) + the server-side roster poll until
//	           the row truthfully reads idle|working|blocked WITH capacity
//	           (PDF-D89); an honest timeout FAILS the job, never fakes online
//	ready      the terminal transition; the worker's /succeed POST follows
//
// CREDENTIAL CUSTODY (the high-flip-risk surface): the parent main's admin
// token rides the internal claim payload over the WORKER_TOKEN channel — the
// same sanctioned crossing as agent tokens / Azure credentials. It is used
// ONLY as an Authorization header against the parent main. It is NEVER logged,
// NEVER written to the box, NEVER interpolated into any on-box script, and it
// is registered as a console-redaction secret before the first narration line,
// so no step/console/error output can carry it.
package provisioner

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// DefaultSupportProvisionTimeout bounds one whole provision_support chain. It is
// WIDER than DefaultProvisionTimeout because the chain serializes a configure
// (whose fail-open freshen can trigger a multi-minute rebuild) AND the ~10-min
// roster-verify budget. It MUST stay under the control plane's stale-claim
// threshold or the reaper double-claims a support that is legitimately verifying.
const DefaultSupportProvisionTimeout = 30 * time.Minute

// DefaultSupportRosterPollBudget is the verify step's server-side roster poll
// budget (PDF-D89: ~10 min; timeout → fail_job, terminal + honest — a
// stuck-provisioning support renders honestly and never bills, PDF-D10).
const DefaultSupportRosterPollBudget = 10 * time.Minute

// DefaultSupportRosterPollInterval is the gap between roster reads in verify.
const DefaultSupportRosterPollInterval = 5 * time.Second

// supportProvisioningTTL is the provisioning roster row's honest freshness
// budget (PDF-D56): the whole bring-up fits inside 30 min, after which an
// abandoned row truthfully ages to offline.
const supportProvisioningTTL = 1800

// supportRawBase is where the box fetches origin/main file CONTENT (fleet
// runtime + unit) — the freshened on-box checkout is the fallback (PDF-D62).
const supportRawBase = "https://raw.githubusercontent.com/FRIKKern/barkpark/main"

// ── validation fences (ported from the CLI surface; the claim payload is never
// trusted blindly — every value that reaches a shell script or URL is fenced) ──

// supportNameRe fences the worker name: it rides in provider labels, the
// listener doc id, systemd env, and single-quoted shell — a DNS-label shape.
var supportNameRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// supportSlugRe fences workspace/dataset slugs interpolated into shell + URLs.
var supportSlugRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// supportURLSafeRe is the safe shape the parent main's base URL must match
// before it is single-quoted into the on-box env-file script.
var supportURLSafeRe = regexp.MustCompile(`^[A-Za-z0-9:/._~%?=&+-]+$`)

// supportTokenSafeRe is the safe shape a minted ledger token must match before
// it is single-quoted into the env-file script (fail closed on a token that
// could break out of the quoting).
var supportTokenSafeRe = regexp.MustCompile(`^[A-Za-z0-9._~+/=-]+$`)

// supportClassVocab is the size-class vocabulary FLEET_MAX_CLASS may carry.
var supportClassVocab = map[string]bool{"light": true, "standard": true, "heavy": true, "xl": true}

// supportRosterLiveVocab is the self-declared vocabulary that counts as a LIVE
// listener in the verify poll (PDF-D23/D89 — offline is computed-only and
// provisioning means the first capacity beat has not landed yet).
var supportRosterLiveVocab = map[string]bool{"idle": true, "working": true, "blocked": true}

// ── the pinned claim contract (PDF-D83; the CP slice implements the server) ──

// SupportJobSpec is one claimed provision_support job — the EXACT JSON the
// control plane's POST /v1/internal/support-jobs/claim returns on 200 (a 204
// means no pending job). succeed/fail/step/console REUSE the generic
// provision-jobs paths with Job.ID.
type SupportJobSpec struct {
	Job      SupportJobRef      `json:"job"`
	Barkpark SupportBarkparkRef `json:"barkpark"`
	Support  SupportBindSpec    `json:"support"`
}

// SupportJobRef identifies the claimed job + its claim-fence token.
type SupportJobRef struct {
	ID string `json:"id"`
	// ClaimToken (claim-fence bp-c55) is echoed on every fenced transition so a
	// swept-and-re-claimed job's stale worker cannot flip the row it lost.
	ClaimToken string `json:"claim_token,omitempty"`
}

// SupportBarkparkRef is the support's control-plane row identity, as claimed.
// region/server_type are ADVISORY here — the box create resolves its shape via
// cloud.FreshSpec exactly like the CLI surface (PDF-D58: size-class comes from
// the first measured beat, never a SKU).
type SupportBarkparkRef struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Slug       string `json:"slug"`
	Region     string `json:"region"`
	ServerType string `json:"server_type"`
}

// SupportBindSpec carries what the bring-up needs to bind the box to the
// developer's PARENT MAIN: where it lives, the admin bearer that authorizes
// the four main-side calls (mutate/mint/export/roster — PDF-D93), and the
// support's identity. ParentAdminToken is the custody-critical value: header
// use ONLY, never logged, never on the box.
type SupportBindSpec struct {
	ParentURL        string `json:"parent_url"`
	ParentAdminToken string `json:"parent_admin_token"`
	Dataset          string `json:"dataset"`
	Workspace        string `json:"workspace"`
	Name             string `json:"name"`
}

// SupportProvisionFunc runs the whole support chain for one claimed job and
// returns the live box IP, the OPAQUE id of the ledger token the chain minted
// on the parent main (task-5866ec745efcd7f7: the worker's succeed report
// carries it so the CP row's fleet_token_id is set and `bp cloud support
// remove` can later revoke the token — "" when the mint response carried no
// id), plus a Teardown that deletes that box. Non-nil error is the fail signal
// (the worker reports it to /fail). The Teardown is non-nil ONLY on success —
// the worker's lever for the money edge (succeed-report never lands → the box
// is deleted rather than orphaned, mirroring RunOnce). On a chain FAILURE the
// implementation has already torn its half-built box down.
type SupportProvisionFunc func(ctx context.Context, spec SupportJobSpec) (ip, tokenID string, teardown Teardown, err error)

// SupportSeams bundles the injectables one support chain needs. Production
// (main()) sets Provider + the two reporters and leaves the rest nil for the
// real defaults; tests inject fakes so no live cloud or SSH is ever touched.
type SupportSeams struct {
	// Provider is the cloud provider support boxes are created on (Hetzner —
	// the x86 warm images live there, PDF-D58). Used by the default CreateServer/
	// DeleteServer; ignored when both are injected.
	Provider cloud.CloudProvider
	// CreateServer creates + identity-labels one support box. nil → the real
	// cloud.CreateSupportServer over Provider.
	CreateServer func(ctx context.Context, name string) (cloud.Server, error)
	// DeleteServer deletes one support box by server name — the teardown half.
	// nil → Provider.Delete.
	DeleteServer func(ctx context.Context, serverName string) error
	// RunnerFor builds the per-host SSH runner once the box IP is known. nil →
	// cloud.NewSSHStepRunner (the key is already on the worker box).
	RunnerFor func(host string) cloud.SupportRunner
	// ConfigureHost runs the reduced configure chain. nil → cloud.ConfigureSupportHost.
	ConfigureHost func(ctx context.Context, runner cloud.SupportRunner, opts cloud.SupportConfigureOpts) (cloud.Secrets, error)
	// SecretsGen overrides the per-instance secret generator (tests). nil → real.
	SecretsGen cloud.SecretGen
	// MainHTTP is the client for every parent-main HTTP call (mutate / mint /
	// export / roster). nil → a generous default; per-call ctx still bounds it.
	MainHTTP *http.Client
	// StepReporter / ConsoleReporter — the SAME telemetry seams ProvisionWith
	// carries (dwb-14/dwb-16): pure telemetry, errors swallowed, redaction on
	// every console line. nil disables silently.
	StepReporter    func(ctx context.Context, jobID, step, status, detail string) error
	ConsoleReporter ConsoleReporter
	// Agent is the agent CLI installed fail-open on the box (claude|codex).
	// Empty → claude. The claim payload carries no agent today; the provider
	// KEY is the developer's own and is NEVER written (PDF-D62/D88).
	Agent string
	// SSHReadyTimeout bounds the create step's sshd poll. 0 → cloud.SupportSSHReadyTimeout.
	SSHReadyTimeout time.Duration
	// RosterPollInterval / RosterPollBudget tune the verify step's roster poll.
	// 0 → the defaults above. Tests set tiny values so no real sleeps run.
	RosterPollInterval time.Duration
	RosterPollBudget   time.Duration
}

// supportAgentPackages maps the agent choice to the npm package + binary the
// runtime step installs FAIL-OPEN and the env var the developer hands over
// themselves (PDF-D88 — the key hand-off is a visible named step in the UI;
// this chain only narrates the one-liner, it never carries a key).
var supportAgentPackages = map[string]struct{ pkg, bin, keyVar string }{
	"claude": {pkg: "@anthropic-ai/claude-code", bin: "claude", keyVar: "ANTHROPIC_API_KEY"},
	"codex":  {pkg: "@openai/codex", bin: "codex", keyVar: "OPENAI_API_KEY"},
}

// DefaultSupportProvision returns a SupportProvisionFunc bound to seams — the
// value the Worker's support drain calls per job. Tests bind it to fakes;
// main() binds it to the real provider + SSH runner factory.
func DefaultSupportProvision(seams SupportSeams) SupportProvisionFunc {
	return func(ctx context.Context, spec SupportJobSpec) (string, string, Teardown, error) {
		return SupportProvisionWith(ctx, seams, spec)
	}
}

// SupportProvisionWith runs the five-step support chain for ONE claimed job.
// On ANY failure after the box exists, the box is torn down before returning
// (nil Teardown — no billed box the control plane cannot render, the same
// no-orphan ethos as ProvisionWith); a create/placement failure writes NOTHING
// (PDF-D58). On success the returned Teardown deletes the box — held by the
// worker for the succeed-report money edge.
func SupportProvisionWith(ctx context.Context, seams SupportSeams, spec SupportJobSpec) (string, string, Teardown, error) {
	seams = seams.withSupportDefaults()

	// Fence the claim payload BEFORE any side effect — a malformed claim is an
	// honest job failure that writes nothing.
	if err := validateSupportSpec(spec); err != nil {
		return "", "", nil, err
	}
	name := spec.Support.Name
	parentURL := strings.TrimRight(strings.TrimSpace(spec.Support.ParentURL), "/")

	// Custody: the parent admin token is a console-redaction secret from line
	// zero — no narration path can carry it even if a format string ever did.
	console := newConsoleEmitter(ctx, spec.Job.ID, seams.ConsoleReporter)
	console.addSecret(spec.Support.ParentAdminToken)
	console.logf("provisioning support %s for main %s (dataset %s)…", name, parentURL, spec.Support.Dataset)

	report := func(step, status, detail string) {
		// The CP /step sink is NOT redacted server-side — scrub the detail before
		// it leaves the worker, against the secret set as it stands at CALL time
		// (the ledger token and the box admin token register mid-chain).
		detail = console.redact(detail)
		if detail != "" {
			// A failed on-box step's detail can be MULTI-LINE (the sshrunner embeds
			// the remote command's full captured output — bp's error body, the
			// barkpark journal tail). The CP caps a single console line at 2000
			// chars, so shipping the blob as one line would truncate exactly the
			// evidence it exists to carry (task-63a199c0a0ce2a06 fired blind this
			// way). Split: first line inline with the step header, each subsequent
			// non-blank line as its own console entry. The step-detail sink below
			// still receives the FULL multi-line text (it is uncapped server-side).
			lines := reportDetailLines(detail)
			console.logf("%s: %s — %s", step, status, lines[0])
			for _, l := range lines[1:] {
				console.logf("  · %s", l)
			}
		} else {
			console.logf("%s: %s", step, status)
		}
		if seams.StepReporter == nil {
			return
		}
		if err := seams.StepReporter(ctx, spec.Job.ID, step, status, detail); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: support step report %s/%s for job %s failed (non-fatal): %v\n", step, status, spec.Job.ID, err)
		}
	}

	r := &supportRun{seams: seams, spec: spec, name: name, parentURL: parentURL, console: console, report: report}

	// ── create ──────────────────────────────────────────────────────────────
	report("create", "started", "")
	host, err := seams.CreateServer(ctx, name)
	if err != nil {
		// PDF-D58: a placement failure writes NOTHING — no box, no roster row,
		// no token. Honest terminal report, job released for retry.
		report("create", "failed", err.Error())
		return "", "", nil, fmt.Errorf("create support box for %q: %w", name, err)
	}
	r.host = host
	r.runner = seams.RunnerFor(host.IP)
	report("create", "progress", fmt.Sprintf("box %s up at %s — waiting for sshd", host.Name, host.IP))
	if err := r.runner.WaitReady(ctx, seams.SSHReadyTimeout); err != nil {
		return r.failStep(ctx, "create", fmt.Errorf("box %s never answered SSH: %w", host.Name, err))
	}
	report("create", "done", host.IP)

	// ── configure ───────────────────────────────────────────────────────────
	report("configure", "started", "")
	secrets, err := seams.ConfigureHost(ctx, r.runner, cloud.SupportConfigureOpts{
		SecretsGen: seams.SecretsGen,
		Narrate:    func(state, detail string) { console.logf("configure: %s — %s", state, detail) },
	})
	if err != nil {
		return r.failStep(ctx, "configure", err)
	}
	r.boxSecrets = secrets
	// The box's own minted admin token is a redaction secret too (it drives the
	// on-box import; the import step also carries it in Redact).
	console.addSecret(secrets.AdminToken)
	report("configure", "done", "")

	// ── content ─────────────────────────────────────────────────────────────
	report("content", "started", "")
	report("content", "progress", "publishing the provisioning roster row on the main")
	if err := r.contentRosterRow(ctx); err != nil {
		return r.failStep(ctx, "content", err)
	}
	report("content", "progress", "minting the support's ledger token on the main")
	if err := r.contentMintToken(ctx); err != nil {
		return r.failStep(ctx, "content", err)
	}
	report("content", "progress", fmt.Sprintf("pulling the scrubbed %s/%s dataset onto the box", spec.Support.Workspace, spec.Support.Dataset))
	if err := r.contentDataset(ctx); err != nil {
		return r.failStep(ctx, "content", err)
	}
	report("content", "done", "")

	// ── verify ──────────────────────────────────────────────────────────────
	report("verify", "started", "")
	report("verify", "progress", "installing the fleet listener runtime (provider keys are never written)")
	if err := r.verifyRuntime(ctx); err != nil {
		return r.failStep(ctx, "verify", err)
	}
	report("verify", "progress", fmt.Sprintf("polling the main's roster until %s reads online with capacity (budget %s)", name, seams.RosterPollBudget))
	rowStatus, capJSON, err := r.verifyRosterOnline(ctx)
	if err != nil {
		// PDF-D89/D10: the timeout is TERMINAL and honest — never succeed without
		// the roster read; the box is torn down so a dead support never bills.
		return r.failStep(ctx, "verify", err)
	}
	report("verify", "done", fmt.Sprintf("%s reads %s with capacity %s", name, rowStatus, capJSON))

	// ── ready ───────────────────────────────────────────────────────────────
	report("ready", "started", "")
	report("ready", "done", "")

	teardown := func(tctx context.Context) error {
		return seams.DeleteServer(tctx, host.Name)
	}
	return host.IP, r.tokenID, teardown, nil
}

// supportRun carries one chain invocation's accumulated truth so each step
// reads like the sequence it narrates (the supportAddRun idiom, re-hosted).
type supportRun struct {
	seams     SupportSeams
	spec      SupportJobSpec
	name      string
	parentURL string
	console   *consoleEmitter
	report    func(step, status, detail string)

	host       cloud.Server
	runner     cloud.SupportRunner
	boxSecrets cloud.Secrets

	ledgerToken string // minted for the box, delivered 0600 — never narrated
	tokenID     string
}

// reportDetailLines splits a step detail into the console lines that carry it:
// CR-stripped, blank interior lines dropped, always at least one element (the
// first line, even when blank) so the caller's header line renders. Pure so the
// multi-line console contract is testable without a harness.
func reportDetailLines(detail string) []string {
	raw := strings.Split(strings.ReplaceAll(detail, "\r\n", "\n"), "\n")
	lines := []string{strings.TrimRight(strings.ReplaceAll(raw[0], "\r", ""), " ")}
	for _, l := range raw[1:] {
		l = strings.TrimRight(strings.ReplaceAll(l, "\r", ""), " ")
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	return lines
}

// failStep reports the honest terminal state for a failed step and tears the
// half-built box down (best-effort) so no billed box is orphaned from the
// control plane. The teardown runs on a FRESH bounded context — the chain ctx
// may already be cancelled/expired. Returns the (nil-teardown) fail triple.
func (r *supportRun) failStep(_ context.Context, step string, cause error) (string, string, Teardown, error) {
	// The returned error IS the /fail POST body (and the drain's stderr) — build
	// it from scrubbed text so both inherit console redaction. %s, never %w:
	// nothing unwraps these, and a wrapped cause would resurface unscrubbed text.
	// The report closure scrubs its own detail — the raw cause stays here.
	causeText := r.console.redact(cause.Error())
	r.report(step, "failed", cause.Error())
	tctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if derr := r.seams.DeleteServer(tctx, r.host.Name); derr != nil {
		return "", "", nil, fmt.Errorf("support %s: %s: %s (AND box %s teardown failed: %s — reclaim it manually)", r.name, step, causeText, r.host.Name, r.console.redact(derr.Error()))
	}
	return "", "", nil, fmt.Errorf("support %s: %s: %s (box torn down; the roster row ages to offline honestly)", r.name, step, causeText)
}

// ── content sub-steps ────────────────────────────────────────────────────────

// contentRosterRow publishes listener-<name> {status:provisioning} on the
// parent main via the dataset-in-path mutate route (PDF-D56: the row is written
// ONLY after a box exists; content.status, never top-level). The admin token
// satisfies the write gate (PDF-D93).
func (r *supportRun) contentRosterRow(ctx context.Context) error {
	doc := map[string]any{
		"_id":    "listener-" + r.name,
		"_type":  "listener",
		"_draft": false,
		"content": map[string]any{
			"worker":    r.name,
			"status":    "provisioning",
			"last_seen": time.Now().UTC().Format(time.RFC3339),
			"ttl_s":     supportProvisioningTTL,
		},
	}
	body := map[string]any{"mutations": []any{
		map[string]any{"createOrReplace": doc},
		map[string]any{"publish": map[string]any{"id": "listener-" + r.name, "type": "listener"}},
	}}
	status, resp, err := r.mainJSON(ctx, http.MethodPost, r.parentURL+"/v1/data/mutate/"+url.PathEscape(r.spec.Support.Dataset), body)
	if err != nil {
		return fmt.Errorf("roster row: cannot reach the main: %w", err)
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("roster row: main answered %d: %s", status, supportTrimBody(resp))
	}
	return nil
}

// contentMintToken mints the support's LEDGER token on the parent main
// (POST /v1/fleet/support-tokens, admin-gated — PDF-D57/D93). The token is the
// ONLY credential ever written to the box (0600, in verifyRuntime). Custody:
// registered as a console-redaction secret immediately; mint-response bodies
// are NEVER embedded in errors (they carry the token).
func (r *supportRun) contentMintToken(ctx context.Context) error {
	status, resp, err := r.mainJSON(ctx, http.MethodPost, r.parentURL+"/v1/fleet/support-tokens",
		map[string]any{"name": r.name, "worker": r.name})
	if err != nil {
		return fmt.Errorf("support-token mint: cannot reach the main: %w", err)
	}
	if status < 200 || status >= 300 {
		// Body withheld: a non-2xx mint body can still carry the token (e.g. a
		// header-echoing error page) — supportTrimBody is NEVER used on a mint.
		return fmt.Errorf("support-token mint: main answered %d (body withheld — mint responses can carry the token)", status)
	}
	tok, tokID := supportParseMint(resp)
	if tok == "" {
		// Deliberately NOT echoing the body: an unrecognized envelope may still
		// carry the secret under an unknown key.
		return fmt.Errorf("support-token mint: the response carried no token (looked for token/secret/value; status %d)", status)
	}
	if !supportTokenSafeRe.MatchString(tok) {
		return fmt.Errorf("support-token mint: the minted token has an unexpected shape; refusing to interpolate it into an on-box script")
	}
	r.ledgerToken, r.tokenID = tok, tokID
	r.console.addSecret(tok)
	return nil
}

// contentDataset runs the scrubbed pull (PDS twin doctrine): dev-profile
// dataset export FROM the parent main, streamed over SSH to the box, then
// merge-imported into the box's OWN localhost API with the box's minted admin
// token (never the parent's).
func (r *supportRun) contentDataset(ctx context.Context) error {
	tar, err := r.exportDatasetTar(ctx)
	if err != nil {
		return fmt.Errorf("dataset export: %w", err)
	}
	defer func() {
		tar.Close()
		os.Remove(tar.Name())
	}()

	if _, err := r.runner.RunFeed(ctx, "stream dataset bundle",
		`mkdir -p /opt/barkpark-fleet && cat > /opt/barkpark-fleet/dataset.tar`, tar); err != nil {
		return fmt.Errorf("dataset stream to box: %w", err)
	}
	if err := r.runner.Run(ctx, supportEnableImportStep()); err != nil {
		return fmt.Errorf("enable bundle import on box: %w", err)
	}
	if err := r.runner.Run(ctx, supportEnsureBpStep()); err != nil {
		return fmt.Errorf("bp install on box: %w", err)
	}
	if err := r.runner.Run(ctx, supportEnsureWorkspaceStep(r.spec.Support.Workspace, r.boxSecrets.AdminToken)); err != nil {
		return fmt.Errorf("ensure workspace on box: %w", err)
	}
	if err := r.runner.Run(ctx, supportImportStep(r.spec.Support.Workspace, r.boxSecrets.AdminToken)); err != nil {
		return fmt.Errorf("on-box merge-import: %w", err)
	}
	return nil
}

// exportDatasetTar GETs the dev-profile (scrubbed) dataset bundle from the
// parent main into a temp file and returns it opened for reading. The admin
// token rides the Authorization header only.
func (r *supportRun) exportDatasetTar(ctx context.Context) (*os.File, error) {
	q := url.Values{}
	q.Set("profile", "dev")
	q.Set("dataset", r.spec.Support.Dataset)
	q.Set("source_server", r.parentURL)
	target := r.parentURL + "/api/workspaces/" + url.PathEscape(r.spec.Support.Workspace) + "/export?" + q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, fmt.Errorf("build export request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+r.spec.Support.ParentAdminToken)
	req.Header.Set("Accept", "application/x-tar, application/json")
	resp, err := r.seams.MainHTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("export request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		return nil, fmt.Errorf("export answered %d: %s", resp.StatusCode, supportTrimBody(body))
	}
	f, err := os.CreateTemp("", "bp-provisioner-support-dataset-*.tar")
	if err != nil {
		return nil, fmt.Errorf("create temp bundle: %w", err)
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(f.Name())
		return nil, fmt.Errorf("stream export: %w", err)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		f.Close()
		os.Remove(f.Name())
		return nil, fmt.Errorf("rewind bundle: %w", err)
	}
	return f, nil
}

// ── verify sub-steps ─────────────────────────────────────────────────────────

// verifyRuntime installs the listener runtime: fleet-run.sh + protocol
// (origin/main content), the agent CLI FAIL-OPEN, the measured capacity
// ceiling, the systemd unit + 0600 env carrying the LEDGER token — and enables
// it. PROVIDER KEYS ARE NEVER WRITTEN (PDF-D62/D88): the developer hands the
// box its model key themselves; the exact one-liner is narrated (no secrets).
func (r *supportRun) verifyRuntime(ctx context.Context) error {
	if err := r.runner.Run(ctx, supportFleetFilesStep()); err != nil {
		return fmt.Errorf("fleet runtime files: %w", err)
	}

	agent := r.seams.Agent
	spec := supportAgentPackages[agent]
	if err := r.runner.Run(ctx, supportAgentInstallStep(spec.pkg, spec.bin)); err != nil {
		// FAIL-OPEN: presence never depends on the vendor CLI — orders degrade
		// loudly, the bring-up continues.
		r.console.logf("verify: %s CLI install degraded (%v) — the listener comes online but orders fail until %s is installed on the box", agent, err, spec.pkg)
	}

	maxClass := ""
	if out, err := r.runner.RunOutput(ctx, supportCapacityMeasureScript); err == nil {
		maxClass = supportParseSizeClass(out)
	}
	if maxClass == "" {
		r.console.logf("verify: capacity measure degraded — FLEET_MAX_CLASS omitted; the listener measures itself at each beat")
	}

	if err := r.runner.Run(ctx, supportUnitInstallStep(r.parentURL, r.ledgerToken, r.name, agent, maxClass)); err != nil {
		return fmt.Errorf("listener unit/env install: %w", err)
	}

	if err := r.runner.Run(ctx, cloud.CaddyStep{
		Title: "enable + start the fleet listener",
		Argv:  []string{"bash", "-lc", "set -e; systemctl daemon-reload; systemctl enable --now barkpark-fleet-listener"},
	}); err != nil {
		return fmt.Errorf("enable barkpark-fleet-listener: %w", err)
	}

	// PDF-D88: the key hand-off is the developer's own visible step. Narrate the
	// exact one-liner (no secret material) so the console journey can render it.
	r.console.logf("agent provider keys are NEVER copied — hand the box its %s key yourself: ssh root@%s \"printf '%s=<your-key>\\n' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener\"", agent, r.host.IP, spec.keyVar)
	return nil
}

// verifyRosterOnline is the server-side port of the CLI's stepOnline loop
// (PDF-D89): poll GET {parent}/v1/fleet/roster (Bearer = the parent admin
// token; roster is token_root) until the row for <name> truthfully reads
// idle|working|blocked WITH a non-empty capacity map. A timeout is a TERMINAL
// error — the chain NEVER succeeds without the roster read.
func (r *supportRun) verifyRosterOnline(ctx context.Context) (status, capJSON string, err error) {
	deadline := time.Now().Add(r.seams.RosterPollBudget)
	lastStatus := ""
	for {
		row, rerr := r.fetchRosterRow(ctx)
		if rerr == nil && row != nil {
			st, _ := row["status"].(string)
			lastStatus = st
			capMap, hasCap := row["capacity"].(map[string]any)
			if supportRosterLiveVocab[st] && hasCap && len(capMap) > 0 {
				b, _ := json.Marshal(capMap)
				return st, string(b), nil
			}
		}
		if !time.Now().Before(deadline) {
			last := lastStatus
			if last == "" {
				last = "no row"
			}
			return "", "", fmt.Errorf("the roster did not reach online-with-capacity within %s (last read: %s) — never faking online", r.seams.RosterPollBudget, last)
		}
		select {
		case <-ctx.Done():
			return "", "", ctx.Err()
		case <-time.After(r.seams.RosterPollInterval):
		}
	}
}

// fetchRosterRow GETs the parent main's roster (the documents envelope,
// PDF-D21) and returns the row whose worker matches, nil when absent.
func (r *supportRun) fetchRosterRow(ctx context.Context) (map[string]any, error) {
	status, body, err := r.mainJSON(ctx, http.MethodGet,
		r.parentURL+"/v1/fleet/roster?dataset="+url.QueryEscape(r.spec.Support.Dataset), nil)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("roster answered %d: %s", status, supportTrimBody(body))
	}
	var env struct {
		Documents []map[string]any `json:"documents"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return nil, fmt.Errorf("roster payload not parseable: %w", jerr)
	}
	for _, d := range env.Documents {
		if w, _ := d["worker"].(string); w == r.name {
			return d, nil
		}
	}
	return nil, nil
}

// mainJSON runs one JSON request against the parent main with the claim's
// admin bearer and returns (status, body, transport error). Non-2xx is NOT an
// error here — callers own the honest message per step. The token rides the
// Authorization header ONLY.
func (r *supportRun) mainJSON(ctx context.Context, method, target string, payload any) (int, []byte, error) {
	var rdr io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, fmt.Errorf("encode request: %w", err)
		}
		rdr = strings.NewReader(string(b))
	}
	req, err := http.NewRequestWithContext(ctx, method, target, rdr)
	if err != nil {
		return 0, nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+r.spec.Support.ParentAdminToken)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := r.seams.MainHTTP.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, body, nil
}

// ── defaults + validation ────────────────────────────────────────────────────

// withSupportDefaults fills the nil seams with the production defaults.
func (s SupportSeams) withSupportDefaults() SupportSeams {
	if s.CreateServer == nil {
		provider := s.Provider
		s.CreateServer = func(ctx context.Context, name string) (cloud.Server, error) {
			if provider == nil {
				return cloud.Server{}, fmt.Errorf("provisioner: a CloudProvider must be set for support jobs")
			}
			return cloud.CreateSupportServer(ctx, provider, cloud.ProviderHetzner, name)
		}
	}
	if s.DeleteServer == nil {
		provider := s.Provider
		s.DeleteServer = func(ctx context.Context, serverName string) error {
			if provider == nil {
				return fmt.Errorf("provisioner: a CloudProvider must be set for support teardown")
			}
			return provider.Delete(ctx, serverName)
		}
	}
	if s.RunnerFor == nil {
		s.RunnerFor = func(host string) cloud.SupportRunner { return cloud.NewSSHStepRunner(host) }
	}
	if s.ConfigureHost == nil {
		s.ConfigureHost = cloud.ConfigureSupportHost
	}
	if s.MainHTTP == nil {
		// No client-level timeout: the export streams a whole dataset bundle and
		// the job ctx (DefaultSupportProvisionTimeout) bounds every call anyway.
		s.MainHTTP = &http.Client{}
	}
	if _, ok := supportAgentPackages[s.Agent]; !ok {
		s.Agent = "claude"
	}
	if s.SSHReadyTimeout <= 0 {
		s.SSHReadyTimeout = cloud.SupportSSHReadyTimeout
	}
	if s.RosterPollInterval <= 0 {
		s.RosterPollInterval = DefaultSupportRosterPollInterval
	}
	if s.RosterPollBudget <= 0 {
		s.RosterPollBudget = DefaultSupportRosterPollBudget
	}
	return s
}

// validateSupportSpec fences every claim-payload value that reaches a shell
// script, URL, or provider label — the claim is never trusted blindly. A
// violation is an honest pre-create job failure (nothing written). The parent
// admin token itself is NEVER echoed into any error.
func validateSupportSpec(spec SupportJobSpec) error {
	if strings.TrimSpace(spec.Job.ID) == "" {
		return fmt.Errorf("support claim missing job.id")
	}
	if !supportNameRe.MatchString(spec.Support.Name) {
		return fmt.Errorf("invalid support name %q — want a DNS-label shape (it becomes the worker id, the listener-<name> roster row, and a provider label)", spec.Support.Name)
	}
	parent := strings.TrimRight(strings.TrimSpace(spec.Support.ParentURL), "/")
	if parent == "" {
		return fmt.Errorf("support claim missing support.parent_url")
	}
	if !supportURLSafeRe.MatchString(parent) {
		return fmt.Errorf("parent main URL %q has an unexpected shape; refusing to interpolate it into on-box scripts", parent)
	}
	if strings.TrimSpace(spec.Support.ParentAdminToken) == "" {
		return fmt.Errorf("support claim missing support.parent_admin_token")
	}
	if !supportSlugRe.MatchString(spec.Support.Dataset) {
		return fmt.Errorf("invalid dataset slug %q", spec.Support.Dataset)
	}
	if !supportSlugRe.MatchString(spec.Support.Workspace) {
		return fmt.Errorf("invalid workspace slug %q", spec.Support.Workspace)
	}
	return nil
}

// ── on-box step builders (pure — ported from the CLI surface; tests assert
// their scripts carry no parent-token material) ──────────────────────────────

// supportEnableImportStep flips the box's fail-closed bundle-import switch and
// restarts Barkpark, then waits for the loopback API to answer again.
func supportEnableImportStep() cloud.CaddyStep {
	script := `set -e
touch /opt/barkpark/.env
grep -v '^BARKPARK_ALLOW_BUNDLE_IMPORT=' /opt/barkpark/.env > /opt/barkpark/.env.bpnew || true
printf 'BARKPARK_ALLOW_BUNDLE_IMPORT=1\n' >> /opt/barkpark/.env.bpnew
mv /opt/barkpark/.env.bpnew /opt/barkpark/.env
systemctl restart barkpark
for i in $(seq 1 60); do curl -fsS http://localhost:4000/api/schemas >/dev/null 2>&1 && exit 0; sleep 2; done
echo 'barkpark did not come back after restart' >&2; exit 1`
	return cloud.CaddyStep{
		Title: "enable workspace bundle import (BARKPARK_ALLOW_BUNDLE_IMPORT=1) + restart",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportEnsureBpStep installs bp via the committed installer when absent.
func supportEnsureBpStep() cloud.CaddyStep {
	script := `set -e
command -v bp >/dev/null 2>&1 && exit 0
sh /opt/barkpark/scripts/install-cli.sh`
	return cloud.CaddyStep{
		Title: "install the bp CLI on the box (scripts/install-cli.sh)",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportEnsureWorkspaceStep creates the import's target workspace on the box
// when it does not exist yet (task-2ba0270056e7da6e). A TEMPLATE-launched
// parent's bootstrap workspace slug (= the instance slug) exists on NO fresh
// box — the box only ships the migrate-seeded "default" — and importing that
// bundle live-failed twice with a box-side 5xx (exit 8). The r3-era CLI chain
// only ever imported guerrilla's "default" workspace, so its imports ALWAYS
// took the live-proven PDS-D9 branch of the merge engine (same-slug empty
// shell → adopt-delete → import); this step routes every import — any slug —
// through that same proven branch: POST /api/workspaces {name,slug} with the
// BOX's own admin token, tolerating 409/422 (already exists) exactly like the
// template bootstrap's ensureWorkspace, so a re-run converges and ws="default"
// is byte-neutral. The created shell is empty, so the engine's empty-shell
// adopt replaces it with the bundle's own workspace row in-transaction.
func supportEnsureWorkspaceStep(ws, boxAdminToken string) cloud.CaddyStep {
	// ws is fenced by supportSlugRe ([A-Za-z0-9_-]+) before any step builds, so
	// it is safe inside both the single-quoted shell string and the JSON body.
	script := `set -e; export BP_TOK='` + boxAdminToken + `'
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://localhost:4000/api/workspaces \
  -H "Authorization: Bearer $BP_TOK" -H 'Content-Type: application/json' \
  --data '{"name":"` + ws + `","slug":"` + ws + `"}')
case "$code" in
  2*|409|422) exit 0 ;;
  *) echo "workspace ensure: POST /api/workspaces answered HTTP $code" >&2; exit 1 ;;
esac`
	return cloud.CaddyStep{
		Title:  "ensure the target workspace '" + ws + "' exists on the box (POST /api/workspaces — already-exists is fine)",
		Cmd:    "curl -X POST http://localhost:4000/api/workspaces {name/slug: " + ws + "} (token redacted)",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{boxAdminToken},
	}
}

// supportImportStep merge-imports the staged bundle into the box's OWN
// localhost API with the BOX's minted admin token (BP_TOK env — Argv only,
// redacted; never the parent's token). Delegates to the ONE shared builder
// (cloud.SupportMergeImportStep) so this chain and the CLI chain cannot drift,
// and so the on-box failure carries its evidence (bp's error body + the box's
// barkpark journal tail — task-63a199c0a0ce2a06 fired blind without them).
func supportImportStep(ws, boxAdminToken string) cloud.CaddyStep {
	return cloud.SupportMergeImportStep(ws, boxAdminToken)
}

// supportFleetFilesStep writes the fleet runtime from origin/main CONTENT
// (raw.githubusercontent first, the freshened on-box checkout as fallback).
func supportFleetFilesStep() cloud.CaddyStep {
	script := `set -e
mkdir -p /opt/barkpark-fleet
fetch(){ curl -fsSL "` + supportRawBase + `/$1" -o "$2" 2>/dev/null || cp "/opt/barkpark/$1" "$2"; }
fetch tooling/fleet/fleet-run.sh /opt/barkpark-fleet/fleet-run.sh
fetch tooling/fleet/fleet-protocol.md /opt/barkpark-fleet/fleet-protocol.md
chmod 0755 /opt/barkpark-fleet/fleet-run.sh`
	return cloud.CaddyStep{
		Title: "write fleet-run.sh + fleet-protocol.md from origin/main content",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportAgentInstallStep installs node + the agent CLI. The CALLER treats a
// failure as a WARNING (fail-open): presence never depends on the vendor CLI.
func supportAgentInstallStep(pkg, bin string) cloud.CaddyStep {
	script := `set -e
command -v node >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 && apt-get install -y nodejs npm >/dev/null 2>&1; }
npm install -g '` + pkg + `' >/dev/null 2>&1
command -v '` + bin + `' >/dev/null 2>&1`
	return cloud.CaddyStep{
		Title: "install node + the agent CLI (" + pkg + ") — fail-open",
		Argv:  []string{"bash", "-lc", script},
	}
}

// supportCapacityMeasureScript measures the box's size class through the SAME
// measurer the listener beats with (fleet-run.sh capacity, PDF-D36).
const supportCapacityMeasureScript = `bash /opt/barkpark-fleet/fleet-run.sh capacity`

// supportUnitInstallStep writes the 0600 listener env (the minted LEDGER token
// rides in via $BP_FLEET_TOK — Argv only, redacted) and installs the committed
// unit. The ONLY credential written is the ledger token — never a provider key,
// never the parent admin token (PDF-D62/D88).
func supportUnitInstallStep(mainBase, ledgerToken, worker, agent, maxClass string) cloud.CaddyStep {
	classLine := ""
	if supportClassVocab[maxClass] {
		classLine = `printf 'FLEET_MAX_CLASS=%s\n' '` + maxClass + `' >> /etc/barkpark/fleet-listener.env` + "\n"
	}
	script := `set -e
export BP_FLEET_TOK='` + ledgerToken + `'
mkdir -p /etc/barkpark
umask 077
: > /etc/barkpark/fleet-listener.env
printf 'BARKPARK_API_URL=%s\n' '` + mainBase + `' >> /etc/barkpark/fleet-listener.env
printf 'BARKPARK_API_TOKEN=%s\n' "$BP_FLEET_TOK" >> /etc/barkpark/fleet-listener.env
printf 'FLEET_WORKER=%s\n' '` + worker + `' >> /etc/barkpark/fleet-listener.env
printf 'FLEET_AGENT=%s\n' '` + agent + `' >> /etc/barkpark/fleet-listener.env
` + classLine + `chmod 600 /etc/barkpark/fleet-listener.env
curl -fsSL "` + supportRawBase + `/deploy/systemd/barkpark-fleet-listener.service" -o /etc/systemd/system/barkpark-fleet-listener.service 2>/dev/null || install -m 0644 /opt/barkpark/deploy/systemd/barkpark-fleet-listener.service /etc/systemd/system/barkpark-fleet-listener.service
chmod 0644 /etc/systemd/system/barkpark-fleet-listener.service`
	return cloud.CaddyStep{
		Title:  "write /etc/barkpark/fleet-listener.env (0600) + install barkpark-fleet-listener.service",
		Cmd:    "write fleet-listener.env with BARKPARK_API_URL/BARKPARK_API_TOKEN (token redacted) + install the unit",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{ledgerToken},
	}
}

// ── small parse helpers (ported) ─────────────────────────────────────────────

// supportParseMint reads the minted token + token id out of the mint response,
// leniently: top-level first, then one known wrapper level.
func supportParseMint(body []byte) (token, tokenID string) {
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return "", ""
	}
	layers := []map[string]any{m}
	for _, wrapper := range []string{"support_token", "token", "doc", "data"} {
		if sub, ok := m[wrapper].(map[string]any); ok {
			layers = append(layers, sub)
		}
	}
	for _, layer := range layers {
		if token == "" {
			for _, k := range []string{"token", "secret", "value", "bearer"} {
				if s, ok := layer[k].(string); ok && strings.TrimSpace(s) != "" {
					token = s
					break
				}
			}
		}
		if tokenID == "" {
			for _, k := range []string{"token_id", "id"} {
				if s, ok := layer[k].(string); ok && strings.TrimSpace(s) != "" {
					tokenID = s
					break
				}
			}
		}
	}
	if token == "" {
		if s, ok := m["token"].(string); ok {
			token = s
		}
	}
	return token, tokenID
}

// supportParseSizeClass reads size_class out of fleet-run.sh capacity's JSON,
// "" when unparseable or off-vocabulary (the caller degrades loudly).
func supportParseSizeClass(out string) string {
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var m struct {
			SizeClass string `json:"size_class"`
		}
		if err := json.Unmarshal([]byte(line), &m); err == nil && supportClassVocab[m.SizeClass] {
			return m.SizeClass
		}
	}
	return ""
}

// supportTrimBody renders a response body into an error message: single line,
// bounded, never empty. NEVER used on a mint response (it carries the token).
func supportTrimBody(b []byte) string {
	s := strings.Join(strings.Fields(string(b)), " ")
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	if s == "" {
		return "(empty body)"
	}
	return s
}
