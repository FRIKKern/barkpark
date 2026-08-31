// Package provisioner is the Go warm-pool worker that bridges the Elixir control
// plane to the cloud-6 WarmPool.Provision chain. It closes the ONE integration
// gap: /v1/launch + /v1/go-live pay and create a `provisioning` Barkpark row but
// do NOT provision — this worker does, by draining a provision_jobs queue.
//
// The flow is poll-based (no Oban, no websocket — YAGNI):
//
//	loop {
//	  POST /v1/internal/provision-jobs/claim   (Bearer WORKER_TOKEN)
//	  204 → nothing pending; sleep --interval, continue
//	  200 → a job: run WarmPool.Provision for {name,slug,region,server_type}
//	         on success → POST /v1/internal/provision-jobs/:id/succeed {ip}
//	         on error   → POST /v1/internal/provision-jobs/:id/fail    {error}
//	}
//
// Worker auth is a single shared secret WORKER_TOKEN, presented as
// `Authorization: Bearer <WORKER_TOKEN>` — a SEPARATE principal from the user
// session token and the agent token. The internal endpoints are NEVER
// user/agent-reachable (the Elixir require_worker pipeline 401s anything else).
//
// Everything external is INJECTED — HTTPClient (so tests point it at an
// httptest.Server) and Provision (so tests use the cloud-package FAKES) — so the
// whole RunOnce cycle runs with no live control plane and no real cloud spend.
package provisioner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// DefaultInterval is the claim-poll cadence when Worker.Interval is zero.
const DefaultInterval = 5 * time.Second

// DefaultProvisionTimeout bounds a single job's Provision when Worker.ProvisionTimeout
// is zero. A real provision SSHes into a fresh box, installs Caddy, migrates, and
// waits on the health gate — minutes, not seconds — but it MUST be bounded so one
// hung step (a dead SSH connection the keepalive missed, a wedged apt) fails the
// job and releases it via fail() instead of pinning the single-threaded worker
// forever. Raised 8 → 20 min for dwb-17: the in-chain freshen step can trigger a
// deploy-rebuild.sh rebuild (build-aside, many minutes) under a ~12-min sub-budget
// before migrate runs. This MUST move with the control-plane stale-claim threshold
// (`provision_stale_after_seconds`, now 25 min) or the reaper double-claims a
// provision that legitimately outlives the old 12-min threshold.
const DefaultProvisionTimeout = 20 * time.Minute

// claimPath is the queue-drain endpoint; succeedPath/failPath are rendered
// per-job (they carry the job id). Poll-based by design — no streaming.
const (
	claimPath      = "/v1/internal/provision-jobs/claim"
	succeedPathFmt = "/v1/internal/provision-jobs/%s/succeed"
	failPathFmt    = "/v1/internal/provision-jobs/%s/fail"
	// releasePathFmt (dwb-15) flips a claimed job back to pending on graceful
	// shutdown WITHOUT consuming an attempt, so the next worker re-claims in seconds.
	releasePathFmt = "/v1/internal/provision-jobs/%s/release"
)

// DefaultShutdownDeadline bounds how long a graceful shutdown (SIGTERM/SIGINT)
// lets the in-flight provision keep running before it is interrupted and its
// claim RELEASED (claimed→pending) for the next worker. It is generous enough
// for the create step (the one boundary that must not be cut mid-flight — a box
// may exist) to finish on a healthy provider (~10-30s), after which releasing is
// safe: a dwb-11 predecessor-reap recovers any box a mid-create interrupt leaked.
// A completed provision inside the window reports succeed/fail normally (no
// release). Tests set a tiny value so the release path runs without a real wait.
const DefaultShutdownDeadline = 60 * time.Second

// releaseRetries / releaseRetryBackoff bound the shutdown release POST. Kept
// SHORT (unlike the ~60s succeed/fail budget) because shutdown is time-boxed —
// a couple of quick retries ride a momentary blip, and if the control plane is
// genuinely unreachable the stale-claim reaper (>12min) is the crash backstop.
const (
	releaseRetries      = 2
	releaseRetryBackoff = 1 * time.Second
	releaseTimeout      = 15 * time.Second
)

const (
	deprovisionClaimPath      = "/v1/internal/deprovision-jobs/claim"
	deprovisionSucceedPathFmt = "/v1/internal/deprovision-jobs/%s/succeed"
	deprovisionFailPathFmt    = "/v1/internal/deprovision-jobs/%s/fail"
)

const (
	attachDomainClaimPath      = "/v1/internal/attach-domain-jobs/claim"
	attachDomainSucceedPathFmt = "/v1/internal/attach-domain-jobs/%s/succeed"
	attachDomainFailPathFmt    = "/v1/internal/attach-domain-jobs/%s/fail"
)

// resurrectClaimPath is the portable-archive restore queue's claim endpoint
// (charter S14f). It is kind-filtered server-side so a resurrect job is never
// handed to a provision worker. The succeed/fail/step/console TRANSITIONS reuse
// the provision-jobs endpoints (a resurrect rides the same job machine, S14c), so
// RunOnceResurrect reports through the existing succeed/fail machinery.
const resurrectClaimPath = "/v1/internal/resurrect-jobs/claim"

// supportClaimPath is the provision_support queue's claim endpoint (Personal
// Dev Fleet MVP-0, PDF-D83). Like resurrect, it is its OWN claim route
// (kind-filtered server-side) while the succeed/fail/step/console TRANSITIONS
// reuse the generic provision-jobs endpoints, so RunOnceSupport reports through
// the existing succeed/fail machinery with the claimed Job.ID.
const supportClaimPath = "/v1/internal/support-jobs/claim"

const (
	enableApplyClaimPath      = "/v1/internal/enable-apply-jobs/claim"
	enableApplySucceedPathFmt = "/v1/internal/enable-apply-jobs/%s/succeed"
	enableApplyFailPathFmt    = "/v1/internal/enable-apply-jobs/%s/fail"
)

// EnableApplySpec is one claimed enable-apply job as the control plane hands
// it back — the EXACT JSON the Elixir enable-apply claim endpoint returns on
// 200 (a 204 means no pending job). ip is the box the instance lives on (the
// barkpark's host). The worker re-validates it defensively
// (validateEnableApplySpec) before any side effect — the claim payload is
// never trusted blindly.
type EnableApplySpec struct {
	JobID string `json:"job_id"`
	// ClaimToken (claim-fence bp-c55) is the per-claim token the control plane
	// stamped on this claim; the worker echoes it on succeed/fail so a
	// swept-and-re-claimed job's stale worker cannot flip the row it lost. Empty
	// when a pre-Stage-1 control plane omitted the key (the worker then sends none).
	ClaimToken string `json:"claim_token,omitempty"`
	IP         string `json:"ip"`
}

// AttachDomainSpec is one claimed attach-domain job as the control plane hands
// it back — the EXACT JSON the Elixir attach-domain claim endpoint returns on
// 200 (a 204 means no pending job). ip is the box the instance lives on (the
// barkpark's host), custom_host the full host to attach — a platform-zone host
// (gyldendal.barkpark.cloud) or, V2, an arbitrary external customer FQDN
// (barkpark.jarl.no) — and app_port the local Phoenix port the new Caddy vhost
// proxies to. dns_label/dns_zone are the platform A record's halves for a
// platform host and EMPTY (null) for an external host, whose DNS the customer
// owns. The worker re-validates ALL of it defensively
// (validateAttachDomainSpec) before any side effect — the claim payload is
// never trusted blindly.
type AttachDomainSpec struct {
	JobID string `json:"job_id"`
	// ClaimToken (claim-fence bp-c55) is the per-claim token the control plane
	// stamped on this claim; the worker echoes it on succeed/fail so a
	// swept-and-re-claimed job's stale worker cannot flip the row it lost. Empty
	// when a pre-Stage-1 control plane omitted the key (the worker then sends none).
	ClaimToken string `json:"claim_token,omitempty"`
	IP         string `json:"ip"`
	CustomHost string `json:"custom_host"`
	DNSLabel   string `json:"dns_label"`
	DNSZone    string `json:"dns_zone"`
	AppPort    int    `json:"app_port"`
}

// JobSpec is one claimed provision job as the control plane hands it back. It is
// the EXACT JSON the Elixir claim endpoint returns on 200 (a 204 means no
// pending job). region/server_type default to the warm-pool defaults (nbg1/
// cax11) on the Elixir side when the row didn't store them, so they arrive
// populated here — the worker does not re-default them.
type JobSpec struct {
	JobID string `json:"job_id"`
	// ClaimToken (claim-fence bp-c55) is the per-claim token the control plane
	// stamped on this claim and returns in the claim response. The worker echoes it
	// back on every fenced transition (succeed/fail/release) so a swept-and-re-claimed
	// job's stale worker cannot flip the row it lost. Empty when an OLD control plane
	// (pre-Stage-1) omitted the key — the worker then sends no claim_token and the
	// server falls back to status-only behavior.
	ClaimToken string `json:"claim_token,omitempty"`
	Name       string `json:"name"`
	Slug       string `json:"slug"`
	Region     string `json:"region"`
	ServerType string `json:"server_type"`
	// Kind is the provider slug the box is provisioned into (charter Decision 9).
	// Empty OR "hetzner" → the existing Hetzner warm-pool path, byte-for-byte
	// unchanged (an OLD control plane omits the key, so the zero value MUST route
	// Hetzner). "azure" → an honest pool-size-zero cold create resolved through
	// cloud.ProviderFor at provision time. omitempty keeps the Hetzner claim
	// payload identical to the pre-provider-neutral shape.
	Kind string `json:"kind,omitempty"`
	// Credentials is the provider's per-kind credential map (Azure's decrypted
	// {tenant_id,client_id,client_secret,subscription_id} 4-tuple), the single
	// sanctioned plaintext crossing on the worker-token internal channel. Present
	// ONLY for a provider that reads auth from credentials (azure); Hetzner reads
	// HCLOUD_TOKEN from the worker env, so its payload omits this key entirely.
	// NEVER logged — it is handed straight to the provider factory.
	Credentials map[string]string `json:"credentials,omitempty"`
	// Template is the OPTIONAL content-template slug (dwb-4) the owner picked at
	// launch, validated by the control plane against the known catalog. Empty →
	// no content bootstrap: the pre-template behavior exactly.
	Template string `json:"template,omitempty"`
	// AgentToken (charter Decision 33) is the per-instance monitoring token the
	// control plane mints at CLAIM time (scope "report") and threads in plaintext
	// here — the same sanctioned crossing as Credentials above, over the worker-token
	// internal channel. (It is NOT "the same crossing as env": JobSpec declares no
	// env field at all, and every claim decode below is a bare json.Unmarshal, so an
	// `env` key in the claim payload is silently DROPPED and never reaches the box.)
	// The configure step writes it to /etc/barkpark/agent.token
	// (0600) and enables barkpark-agent.service so the box reports its health +
	// vitals home. Present for BOTH providers; only its hash is stored server-side.
	// Empty when an OLD control plane omits the key → the worker skips the agent
	// install (the box serves, just without the beat). NEVER logged.
	AgentToken string `json:"agent_token,omitempty"`
	// BundleRef (charter S14, Decision 12) turns a normal provision into a RESTORE:
	// present ONLY on a resurrect claim, it points the job at the portable archive
	// bundle to rebuild the box FROM (manifest + pg_dump + media + sealed identity
	// secrets) and carries the KEK that unseals those secrets. When set, ProvisionWith
	// routes to the restore path — a cold create that NEVER warm-assigns (D40), whose
	// content phase is a database restore instead of a template bootstrap, and whose
	// configure phase installs the bundle's sealed identity (the KEK is CARRIED here,
	// never minted on this path). nil (every normal launch) → the byte-for-byte
	// unchanged provision. NEVER logged — it carries the KEK.
	BundleRef *BundleRef `json:"bundle_ref,omitempty"`
}

// BundleRef locates a portable archive bundle and carries what a cross-provider
// restore needs (charter S14, Decision 12). It mirrors the pinned-claim shape the
// control plane stamps: WHERE the bundle lives (Store + Key in object storage), the
// KEK that unseals its identity secrets (CARRIED from the archive time, never minted
// at restore time — a resurrected box keeps its prior identity so links/tokens
// survive), and the Manifest describing what to rebuild.
type BundleRef struct {
	// Store is the object-storage locator the bundle lives under (bucket/endpoint).
	Store string `json:"store"`
	// Key is the bundle's object key within Store (the specific archive, or the
	// control-plane-resolved newest one when the caller didn't pin a bundle).
	Key string `json:"key"`
	// KEK is the key-encryption-key that unseals secrets.enc. It is CARRIED from the
	// archive — NEVER minted on the restore path, or the box would come back with a
	// new identity (defaultSecretGen must not run for a resurrect). NEVER logged.
	KEK string `json:"kek"`
	// Manifest describes the box being rebuilt: its fqdn, the database to restore, the
	// media to unpack, and where it was archived FROM (a Hetzner bundle can land on
	// Azure and vice-versa — the bold cross-provider bet).
	Manifest BundleManifest `json:"manifest"`
}

// BundleManifest is the portable archive's self-description — the fidelity contract
// a restore round-trips (charter S14). Everything the restore needs to name the
// target and rebuild its data lives here, so the same bundle restores identically on
// either provider.
type BundleManifest struct {
	// SourceProvider is the provider the box was archived FROM (hetzner|azure). The
	// TARGET provider (job.Kind) may differ — that difference IS the migration story.
	SourceProvider string `json:"source_provider"`
	// Fqdn is the instance's public host — the A-record the restore repoints and the
	// origin the verify gate probes.
	Fqdn string `json:"fqdn"`
	// DBName is the database the restore DROPs + CREATEs + pg_restores into. Named by
	// the MANIFEST (not re-derived on the box) so the restore lands in the right place.
	DBName string `json:"db_name"`
	// Spec is the archive-time SHAPE hint — the region + server_type the source box
	// ran on (mirrored from cloud.BundleSpec). It lets a SAME-PROVIDER resurrect
	// rebuild the box to its prior size when the claim did not pin one, under the
	// precedence pin > archived hint > provider default (CloudRestoreDriver.CreateHost,
	// charter D49). The hint tier is same-provider ONLY (job.Kind == SourceProvider):
	// cross-provider size mapping is DEFERRED until real demand (D50 — no heuristic is
	// guessed). Both fields may be blank (an unpinned archive stamps ""), and it is a
	// SHAPE, never a content sha — no sha field exists in the bundle pipeline (D51).
	Spec BundleSpec `json:"spec"`
	// MediaPaths are the media roots the restore unpacks from the bundle.
	MediaPaths []string `json:"media_paths,omitempty"`
	// ArchivedAt is the RFC3339 instant the bundle was cut (audit + newest-selection).
	ArchivedAt string `json:"archived_at,omitempty"`
	// SchemaVersion pins the schema the dump was taken at, so the restore's best-effort
	// migrate knows whether it is catching up.
	SchemaVersion int `json:"schema_version,omitempty"`
}

// BundleSpec is the archive-time shape hint mirrored from cloud.BundleSpec: the
// region + server_type the source box ran on. It is carried on BundleManifest.Spec
// so a same-provider resurrect can rebuild the box to match (charter D49). Both
// fields are always present in the pinned manifest wire bytes — an unpinned archive
// stamps "" (a legitimate blank), never an omission — so a reader distinguishes "no
// hint" (blank) from a real one by value, not presence.
type BundleSpec struct {
	Region     string `json:"region"`
	ServerType string `json:"server_type"`
}

// ProvisionFunc runs the warm-pool provisioning for one claimed job and returns
// the live host IP, the per-instance admin token minted on the box, plus a
// Teardown that deletes that host. It is the injected seam: tests pass a fake
// that returns a deterministic IP (or an error) without touching a cloud; main()
// wires the real WarmPool chain over the real Hetzner provider/DNS. A non-nil
// error is the fail signal — the worker reports it to the control plane and moves on.
//
// adminToken (instance-admin-token) is the bp_admin_ bearer the chain minted +
// installed on the box. The worker forwards it in the succeed report so the
// control plane can store it encrypted and the OWNER can retrieve it without
// SSH. It is NEVER logged. Empty when the chain did not surface one.
//
// boot (dwb-4) carries the content-bootstrap outputs (workspace/project/dataset
// slugs, the minted public-read token, the resolved app env) when the job asked
// for a template and the bootstrap ran; nil otherwise. The worker forwards it in
// the succeed report so the control plane stores the secret halves encrypted
// (the same at-rest posture as adminToken). NEVER logged.
//
// The Teardown is non-nil ONLY on success and is the worker's lever for the money
// edge in RunOnce: when provisioning succeeds (a paid box is live) but the
// succeed-report to the control plane then fails, the box is orphaned — live,
// billed, and unknown to the control plane — so the worker calls Teardown to
// delete it. On a provision FAILURE — including a failed content bootstrap —
// the implementation has already torn its half-built box down, so it returns a
// nil Teardown.
type ProvisionFunc func(ctx context.Context, spec JobSpec) (ip string, adminToken string, boot *BootstrapOutputs, teardown Teardown, err error)

// Worker claims provision jobs from the control plane and runs each through the
// injected Provision. Everything it talks to is injected — HTTPClient (so tests
// use httptest), Provision (so tests use the cloud fakes) — so RunOnce runs with
// no live anything.
type Worker struct {
	// ControlURL is the control-plane origin (e.g. https://cloud.barkpark.dev).
	// Trailing slash is trimmed.
	ControlURL string
	// Token is the shared WORKER_TOKEN. Sent as `Authorization: Bearer <token>`
	// on every internal request — the separate worker principal.
	Token string
	// Interval is the claim-poll cadence for Run. Zero means DefaultInterval.
	Interval time.Duration
	// HTTPClient is the injected client. Zero value uses http.DefaultClient.
	HTTPClient *http.Client
	// Provision runs one job's warm-pool chain. MUST be set (RunOnce errors if
	// nil — there is no safe default that doesn't touch a real cloud).
	Provision ProvisionFunc
	// Deprovision tears down one box (server + DNS) for a claimed deprovision job.
	// nil → the worker only provisions. Injected like Provision.
	Deprovision DeprovisionFunc
	// AttachDomain points a custom host at one live box (DNS A record + on-box
	// env/Caddy config) for a claimed attach-domain job. nil → the worker skips
	// the attach-domain queue. Injected like Provision/Deprovision.
	AttachDomain AttachDomainFunc
	// Resurrect resolves the object store + KEK a portable-restore job needs, from
	// WORKER ENV (never the claim JSON — charter S14f/D43). The resurrect drain
	// calls it to TRANSLATE a claim's string bundle_ref into a full *BundleRef
	// (manifest read from the store, KEK injected here) before handing the job to
	// Provision. nil → the worker skips the resurrect queue (like Deprovision/
	// AttachDomain). A missing-env error fails the JOB honestly; the drain survives.
	Resurrect ResurrectDepsFunc
	// SupportProvision runs one claimed provision_support job — the server-side
	// support bring-up chain (MVP-0, PDF-D83: create/configure/content/verify/
	// ready from claim-payload credentials). nil → the worker skips the support
	// queue (like Deprovision/AttachDomain/Resurrect). Injected like Provision;
	// tests bind it to fakes via DefaultSupportProvision(SupportSeams{…}).
	SupportProvision SupportProvisionFunc
	// AgentKeyPush delivers one claimed push_agent_key job (PDF-D94 — the
	// console paste-a-key custody path: rewrite one listener-env line on a live
	// support box + restart). nil → the worker skips the agent-key queue.
	// Injected like the others; tests bind it via DefaultAgentKeyPush(AgentKeySeams{…}).
	AgentKeyPush AgentKeyPushFunc
	// EnableApply flips BARKPARK_SELF_UPDATE_APPLY=1 on one live box (+ app
	// restart) for a claimed enable-apply job. nil → the worker skips the
	// enable-apply queue. Injected like Provision/Deprovision/AttachDomain.
	EnableApply EnableApplyFunc
	// ProvisionTimeout bounds a single Provision call. Zero means
	// DefaultProvisionTimeout. When it fires, the job's ctx is cancelled — a
	// well-behaved Provision returns a (deadline-exceeded) error, which RunOnce
	// reports to /fail so the job is released for a later retry rather than
	// hanging the worker.
	ProvisionTimeout time.Duration
	// ReportRetryBackoff overrides the pause between succeed/fail report retries.
	// Zero means the production reportRetryBackoff (~10s, sized to ride out a
	// control-plane deploy restart). Tests set a tiny value so the retry loop runs
	// fast without a real ~60s wall-clock budget. Production leaves it zero.
	ReportRetryBackoff time.Duration
	// Sweep deletes every box labeled barkpark-orphaned=true (plus its stranded DNS
	// record) — the auto-recovery for the double-failure edge (a box torn down whose
	// provider.Delete persistently failed got marked orphaned). It is SAFE: only
	// boxes that label, set exclusively in the teardown path, are touched. Run once
	// on startup (SweepOnce) and, when SweepEvery > 0, every SweepEvery cycles. nil
	// → no sweep (the worker still provisions; orphans just aren't auto-recovered).
	Sweep SweepFunc
	// SweepEvery, when > 0, runs Sweep every Nth completed cycle in Run (in addition
	// to the startup sweep), so a long-lived worker keeps recovering orphans without
	// a separate timer. Zero → startup-only.
	SweepEvery int
	// Reconcile holds the warm pool at its target size (dwb-10) — creates boxes when
	// the pool is short, retires excess boxes when it is over. SAFE: it only ever
	// deletes boxes it pops via the control-plane claim-for-retire (SKIP LOCKED, so
	// never an in-flight assign's box). Run once on startup (ReconcileOnce) and, when
	// ReconcileEvery > 0, every ReconcileEvery cycles. nil → no reconcile (the pool
	// is disabled, or reconciled out-of-band).
	Reconcile ReconcileFunc
	// ReconcileEvery, when > 0, runs Reconcile every Nth completed cycle in Run (in
	// addition to the startup reconcile), so a long-lived worker keeps the pool at
	// size without a separate timer. Zero → startup-only.
	ReconcileEvery int
	// Refresh keeps idle pool boxes at origin/main (snapshot-management): each call
	// launches an ASYNC background refresh of the STALEST due box (out of the
	// assignable set while it refreshes, fail-open) so a go-live almost never
	// rebuilds at claim time. Non-blocking + one-in-flight (DefaultRefresh gates
	// it), so the claim loop is never held up by a multi-minute rebuild. nil → the
	// pool is only kept current at refill/reconcile (the pre-self-refresh behavior).
	Refresh func(context.Context)
	// RefreshEvery, when > 0, calls Refresh every Nth completed cycle in Run. Sized
	// small (a check is cheap — a 204 when nothing is due) so the pool tracks main
	// tightly. Zero → no periodic refresh.
	RefreshEvery int
	// ShutdownDeadline bounds a graceful shutdown's grace window (dwb-15). Zero →
	// DefaultShutdownDeadline. See Shutdown.
	ShutdownDeadline time.Duration

	// ── graceful-shutdown coordination (dwb-15) ──
	// drainMu guards the in-flight-job handoff between the claim loop (RunOnce) and
	// the shutdown goroutine (Shutdown). The worker runs ONE job at a time, so this
	// tracks exactly one in-flight provision.
	drainMu sync.Mutex
	// curJobID is the id of the job currently being provisioned (empty when idle).
	curJobID string
	// curClaimToken is the claim-fence token (bp-c55) of the in-flight job, so a
	// graceful-shutdown release can echo it back and be fenced against a re-claim.
	// Empty when the control plane didn't stamp one (pre-Stage-1 compat).
	curClaimToken string
	// curCancel cancels the current provision's bounded context — Shutdown calls it
	// to interrupt a provision that overran the grace window before releasing it.
	curCancel context.CancelFunc
	// curDone is closed when the current provision returns (success or error), so
	// Shutdown can wait for a natural finish instead of forcing a release.
	curDone chan struct{}
	// releasedJobs records ids the shutdown path RELEASED (claimed→pending). RunOnce
	// checks this after its provision returns and, if present, skips its
	// succeed/fail report — the release already re-queued the job for the next worker.
	releasedJobs map[string]bool
}

// httpClient returns the injected client or http.DefaultClient.
func (w *Worker) httpClient() *http.Client {
	if w.HTTPClient != nil {
		return w.HTTPClient
	}
	return http.DefaultClient
}

// reportBackoff returns the per-retry pause: the injected override when set,
// else the production reportRetryBackoff. Lets tests run the retry loop fast.
func (w *Worker) reportBackoff() time.Duration {
	if w.ReportRetryBackoff > 0 {
		return w.ReportRetryBackoff
	}
	return reportRetryBackoff
}

// shutdownDeadline returns the graceful-shutdown grace window: the injected
// override when set, else DefaultShutdownDeadline.
func (w *Worker) shutdownDeadline() time.Duration {
	if w.ShutdownDeadline > 0 {
		return w.ShutdownDeadline
	}
	return DefaultShutdownDeadline
}

// setInflight records the job now being provisioned + its cancel (and its
// claim-fence token, so a shutdown release can echo it), and opens a fresh done
// channel Shutdown can wait on. Called by RunOnce right after a claim.
func (w *Worker) setInflight(jobID, claimToken string, cancel context.CancelFunc) {
	w.drainMu.Lock()
	w.curJobID = jobID
	w.curClaimToken = claimToken
	w.curCancel = cancel
	w.curDone = make(chan struct{})
	w.drainMu.Unlock()
}

// clearInflight closes the done channel + clears the in-flight state, and reports
// whether Shutdown RELEASED this job (so RunOnce can skip its succeed/fail
// report). One atomic section so it can't race Shutdown's release decision: if
// Shutdown already marked the job released, RunOnce sees released=true here and
// stands down; otherwise Shutdown, locking after this, sees curJobID cleared and
// does NOT release a job RunOnce is about to report normally.
func (w *Worker) clearInflight(jobID string) (released bool) {
	w.drainMu.Lock()
	defer w.drainMu.Unlock()
	released = w.releasedJobs[jobID]
	if w.curDone != nil {
		close(w.curDone)
	}
	w.curJobID = ""
	w.curClaimToken = ""
	w.curCancel = nil
	w.curDone = nil
	return released
}

// Shutdown is the graceful-shutdown orchestration (dwb-15). Call it on
// SIGTERM/SIGINT BEFORE cancelling the worker's loop context (cancelling the loop
// ctx would cancel the in-flight provision immediately and defeat the grace
// window). It:
//
//  1. captures the in-flight job (if any) under the lock;
//  2. if idle, returns at once — nothing to release;
//  3. otherwise waits up to ShutdownDeadline for the provision to finish on its
//     own (the best outcome: it reports succeed/fail normally, no release);
//  4. if the window expires with the job STILL in flight, interrupts the
//     provision (curCancel) and RELEASES its claim (claimed→pending, no attempt
//     consumed) so the next worker re-claims in seconds. Any box a mid-create
//     interrupt leaked is recovered by the dwb-11 predecessor-reap on the next
//     attempt — the hard constraint is honoured by the grace window, which lets
//     the fast create step finish before any interrupt.
//
// After Shutdown returns, the caller cancels the loop context to stop the worker.
func (w *Worker) Shutdown(ctx context.Context) {
	w.drainMu.Lock()
	jobID := w.curJobID
	claimToken := w.curClaimToken
	cancel := w.curCancel
	done := w.curDone
	w.drainMu.Unlock()

	if jobID == "" {
		return // idle — no in-flight claim to release.
	}

	select {
	case <-done:
		// The provision finished within the grace window — RunOnce reports its
		// outcome normally. No release, no interrupt.
		return
	case <-time.After(w.shutdownDeadline()):
	}

	// The window expired with the job still in flight. Claim the right to finalize:
	// mark released so RunOnce stands down, THEN interrupt + release. If RunOnce
	// happens to be finishing right now, clearInflight (also under the lock) already
	// cleared curJobID — re-check so we never release a job that just completed.
	w.drainMu.Lock()
	stillInflight := w.curJobID == jobID
	if stillInflight {
		if w.releasedJobs == nil {
			w.releasedJobs = map[string]bool{}
		}
		w.releasedJobs[jobID] = true
	}
	w.drainMu.Unlock()

	if !stillInflight {
		return // it finished in the race window — let RunOnce report it.
	}

	if cancel != nil {
		cancel() // interrupt the overrunning provision.
	}

	// Release on a FRESH bounded context — the loop ctx is about to be cancelled,
	// and a release POST on a cancelled ctx would fail instantly.
	rctx, rcancel := context.WithTimeout(context.Background(), releaseTimeout)
	defer rcancel()
	if err := w.releaseWithRetry(rctx, jobID, claimToken); err != nil {
		// Release didn't land (control plane unreachable). The stale-claim reaper
		// (>12min) is the crash backstop — surface it in the worker journal.
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: graceful release of job %s failed (reaper is the backstop): %v\n", jobID, err)
	}
}

// release POSTs the release endpoint for jobID (claimed→pending, no attempt
// consumed). A 2xx (fresh or the idempotent already-pending 200) is success.
// claim-fence (bp-c55): echo the claim_token when the control plane stamped one
// so a stale release (a swept-and-re-claimed job) is fenced to 409; sent ONLY
// when non-empty, so an old control plane's token-less release path is unchanged.
func (w *Worker) release(ctx context.Context, jobID, claimToken string) error {
	return w.postJSON(ctx, fmt.Sprintf(releasePathFmt, jobID), claimBody(nil, claimToken))
}

// releaseWithRetry runs release with a SHORT bounded retry (unlike the long
// succeed/fail budget): a 5xx/transport blip during a control-plane deploy is
// retried a couple times; a 4xx (e.g. 409 — the job already succeeded/failed) is
// terminal and stops immediately (nothing to release). ctx bounds the total wait.
func (w *Worker) releaseWithRetry(ctx context.Context, jobID, claimToken string) error {
	var lastErr error
	for attempt := 0; attempt <= releaseRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(releaseRetryBackoff):
			}
		}
		if err := w.release(ctx, jobID, claimToken); err != nil {
			lastErr = err
			if is4xx(err) {
				break
			}
			continue
		}
		return nil
	}
	return lastErr
}

// reportRetries is how many EXTRA times the succeed/fail report is retried (after
// the first attempt) on a TRANSIENT failure before the worker concludes the report
// is not getting through and (for a succeed) tears the orphan box down. Sized to
// ride out a control-plane DEPLOY: barkpark.service behind Caddy returns 502/503
// for ~10-30s during a `systemctl restart`, longer than the old ~6s budget — so a
// deploy landing in this window used to burn a full create+provision+teardown
// cycle (and the reaper re-provisioned next pass) over a transient restart. With
// reportRetries=5 (6 attempts total) × reportRetryBackoff the budget is ~60s,
// comfortably longer than a restart, so the common case rides through with NO
// teardown. The cap still keeps the single-threaded worker from spinning forever
// on a sustained outage — a rare hard outage still falls through to teardown + the
// reaper's bounded retries.
const reportRetries = 5

// reportRetryBackoff is the fixed pause between report retries. ~10s × the 5
// retries ≈ a ~60s budget — long enough to outlast a deploy `systemctl restart`,
// still bounded so a hard outage does not pin the worker.
const reportRetryBackoff = 10 * time.Second

// RunOnce performs exactly one claim→provision→report cycle:
//
//  1. POST /v1/internal/provision-jobs/claim (Bearer WORKER_TOKEN).
//  2. 204 No Content → nothing pending; return (claimed=false), no provision.
//  3. 200 → a job: run Provision for {name,slug,region,server_type}.
//  4. on success → POST .../:id/succeed {ip}; the barkpark flips to up.
//  5. on error   → POST .../:id/fail   {error}; the barkpark stays provisioning.
//
// It returns claimed=true ONLY when a job was drained AND its outcome was cleanly
// recorded with the control plane (a succeed or fail that the control plane
// acknowledged). It returns an error for a transport/encoding fault or a
// misconfiguration (nil Provision, non-2xx claim). A provision FAILURE is NOT a
// RunOnce error — it is reported to the control plane and, once the fail report
// lands, the cycle is a clean handled-claim. This mirrors the agent's "command
// failure rides back in the result, doesn't abort the cycle" contract.
//
// THE MONEY EDGE (claimed=false on a report that never lands). The in-chain
// registry is a no-op, so the worker's report POST is the ONLY thing that tells
// the control plane what happened to a job. If a report does not get through, the
// job's true state is NOT recorded, so RunOnce must NOT consume the job — it
// returns claimed=false so the cycle is not counted as cleanly done, leaving the
// job "claimed" for the Elixir reaper to re-claim (a claim older than ~12m becomes
// re-claimable, bounded by an attempts cap) for a fresh attempt. Two cases:
//
//   - SUCCEED-report failure: a paid box is LIVE but the control plane has not yet
//     learned it exists (it would stay stuck "provisioning" while the box bills).
//     The worker classifies the failure by status CLASS (see succeedWithRetry):
//     a 5xx (Caddy 502/503 from a deploy `systemctl restart`, or a 500 blip) and a
//     transport/timeout error are TRANSIENT — the report is retried 3×2s to ride
//     the restart out, and any 2xx that lands (fresh OR the idempotent 200 the CP
//     returns for an already-succeeded job) is success: the box is KEPT, no
//     teardown. A 4xx (e.g. 409 — the job was already reaped at the attempts cap)
//     is a TERMINAL rejection: the worker stops immediately. When the report still
//     never lands (persistent 5xx/timeout, or a terminal 4xx), the worker TEARS THE
//     BOX DOWN (the returned Teardown: provider.Delete + DNS DeleteRecord) so there
//     is no live box the control plane is blind to, then returns claimed=false so
//     the reaper re-claims the job once the control plane is back. The invariant:
//     never a live box the control plane is blind to, and never a silently-dropped
//     job.
//   - FAIL-report transport failure: the box was already torn down by the provision
//     failure path, so there is nothing to clean up — RunOnce just returns
//     claimed=false so the failure is not silently consumed and the reaper retries
//     until the failure is eventually recorded (and the attempts cap eventually
//     marks a permanently-failing job failed).
func (w *Worker) RunOnce(ctx context.Context) (claimed bool, err error) {
	if w.Provision == nil {
		return false, fmt.Errorf("provisioner: a Provision func must be injected")
	}

	job, ok, err := w.claim(ctx)
	if err != nil {
		return false, fmt.Errorf("claim: %w", err)
	}
	if !ok {
		return false, nil // 204 — nothing pending.
	}

	// Bound the provision so one hung step fails the job instead of pinning the
	// single-threaded worker forever. On timeout the job ctx is cancelled and the
	// provision returns an error that flows to the fail() path below, releasing
	// the job for retry. (The one-shot provision cleans up its half-built box on
	// the cancelled ctx via a fresh teardown context.)
	pto := w.ProvisionTimeout
	if pto <= 0 {
		pto = DefaultProvisionTimeout
	}
	provCtx, cancel := context.WithTimeout(ctx, pto)
	// dwb-15: register the in-flight job so a graceful shutdown can wait for it and,
	// past the deadline, interrupt (cancel) + release its claim. clearInflight below
	// reports whether shutdown RELEASED it — if so, we skip the succeed/fail report
	// (the release already re-queued the job for the next worker).
	w.setInflight(job.JobID, job.ClaimToken, cancel)
	ip, adminToken, boot, teardown, provErr := w.Provision(provCtx, job)
	cancel()
	if w.clearInflight(job.JobID) {
		// A graceful shutdown released this claim (claimed→pending). Do NOT report:
		// the provision was interrupted, its claim is already back to pending, and the
		// next worker picks it up in seconds. Not a cleanly-consumed cycle → false.
		return false, nil
	}
	if provErr != nil {
		// The provision already tore down any half-built box (teardown is nil on a
		// failure). Report the failure so the control plane records it and the
		// barkpark stays in provisioning for a later retry. The fail report rides the
		// SAME widened transient-retry budget as succeed (5xx/timeout retry, 4xx stop)
		// so a deploy `systemctl restart` window does not drop the failure record over
		// a transient 502/503. If the fail report STILL does NOT get through, do NOT
		// consume the job: return claimed=false so the reaper re-claims it and the
		// failure is eventually recorded (bounded by the attempts cap). There is no
		// orphan box to clean up here.
		if rerr := w.failWithRetry(ctx, job.JobID, job.ClaimToken, provErr.Error()); rerr != nil {
			return false, fmt.Errorf("report fail for job %s (provision error %v): %w", job.JobID, provErr, rerr)
		}
		return true, nil
	}

	// Provision SUCCEEDED: a paid box is live. The control plane does NOT yet know
	// — the worker's succeed POST is the only signal. Retry transient failures (5xx
	// deploy restarts / blips / transport drops) a few times to ride them out; a 2xx
	// (fresh or idempotent) keeps the box. Only a terminal 4xx or a report that never
	// lands falls through to teardown.
	if rerr := w.succeedWithRetry(ctx, job.JobID, job.ClaimToken, ip, adminToken, boot); rerr != nil {
		// The report is not getting through (persistent 5xx/timeout) or was terminally
		// rejected (4xx). The live box is orphaned from the control plane (which would
		// leave it stuck "provisioning" while the box bills indefinitely). Tear it down
		// so there is NO live box the control plane is blind to, and do NOT consume the
		// job (claimed=false) — leave it for the reaper to re-claim for a fresh attempt.
		if teardown != nil {
			if cerr := teardown(ctx); cerr != nil {
				// A failed teardown leaves a billed orphan AND an unrecorded job — the
				// worst case. Surface both so it is visible in the worker journal.
				return false, fmt.Errorf("report succeed for job %s failed (%v) AND orphan teardown failed: %w", job.JobID, rerr, cerr)
			}
		}
		return false, fmt.Errorf("report succeed for job %s (box torn down to avoid an orphan, job left for retry): %w", job.JobID, rerr)
	}
	return true, nil
}

// succeedWithRetry POSTs the succeed report through the shared transient-retry
// loop. A nil return means a 2xx was acknowledged — fresh OR idempotent (the CP's
// succeed_job is idempotent: re-POSTing an already-"succeeded" job returns 200 with
// no double side-effects), which is what self-heals a lost succeed response
// (committed server-side, HTTP reply dropped): the retry re-POSTs, gets 200, no
// teardown. A non-nil return is the signal to tear the orphan box down.
func (w *Worker) succeedWithRetry(ctx context.Context, jobID, claimToken, ip, adminToken string, boot *BootstrapOutputs) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.succeed(ctx, jobID, claimToken, ip, adminToken, boot) })
}

// failWithRetry POSTs the fail report through the SAME shared transient-retry loop
// as succeed, so a control-plane deploy restart (502/503) does not drop the failure
// record. There is no box to tear down on this path (the provision failure already
// cleaned up its half-built box); a non-nil return just means the job is left
// un-consumed for the reaper to re-claim.
func (w *Worker) failWithRetry(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.fail(ctx, jobID, claimToken, errMsg) })
}

// reportWithRetry runs post (one succeed/fail POST) and retries TRANSIENT failures
// up to reportRetries extra times with a fixed backoff. It returns nil on the
// first 2xx-acknowledged report and the LAST error if every attempt failed. The
// backoff honours ctx cancellation so a shutdown does not stall here.
//
// Retryability is classified by status CLASS, not by "is it a status error":
//
//   - 5xx (500-599) AND transport/timeout errors are TRANSIENT → RETRY. The
//     production control plane sits behind Caddy and does `systemctl restart
//     barkpark.service` on deploy, so a deploy landing in this window returns
//     502/503 for ~10-30s. Those are not rejections — the report just hasn't
//     landed yet, so re-POSTing across the widened ~60s budget rides the restart
//     out with no teardown / no cycle burn.
//   - 4xx (400-499) is a TERMINAL control-plane rejection → STOP immediately. A
//     4xx means the CP refused THIS report (e.g. 409 for a job already reaped at
//     the attempts cap); an immediate re-POST cannot change that, so fall straight
//     through to the caller's decision.
func (w *Worker) reportWithRetry(ctx context.Context, post func(context.Context) error) error {
	var lastErr error
	for attempt := 0; attempt <= reportRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(w.reportBackoff()):
			}
		}
		if err := post(ctx); err != nil {
			lastErr = err
			// A 4xx is a terminal control-plane rejection — re-POSTing won't change
			// it, so stop retrying and fall through to the caller's decision now.
			// A 5xx (deploy restart / blip) and a transport failure are transient —
			// keep retrying within the loop.
			if is4xx(err) {
				break
			}
			continue
		}
		return nil
	}
	return lastErr
}

// Run loops RunOnce until ctx is done, returning ctx.Err(). It sleeps Interval
// between cycles ONLY when a cycle drained nothing (204) — when a job was
// claimed it loops straight to the next claim so a backlog drains fast. A cycle
// error is non-fatal: the loop reports it via onCycle (nil-safe) and keeps
// going, so a transient control-plane blip doesn't kill the worker.
func (w *Worker) Run(ctx context.Context) error {
	return w.RunWith(ctx, nil)
}

// SweepOnce runs one orphan sweep via the injected Sweep, if set. It is a no-op
// (0, nil) when Sweep is nil, so a worker without the seam still runs. main()
// calls it on STARTUP — before the claim loop — so a leaked orphan box from a
// prior run's double-failure is recovered (deleted, with its DNS) on the next
// process start, reclaiming the spend with zero risk to live boxes.
func (w *Worker) SweepOnce(ctx context.Context) (int, error) {
	if w.Sweep == nil {
		return 0, nil
	}
	return w.Sweep(ctx)
}

// ReconcileOnce runs one warm-pool reconcile via the injected Reconcile, if set.
// It is a no-op (nil) when Reconcile is nil. main() calls it on STARTUP — before
// the claim loop — so the pool is topped up to size as soon as the worker boots
// (and shrunk to size if a prior run over-provisioned), keeping the ≤15s path warm
// from the first go-live.
func (w *Worker) ReconcileOnce(ctx context.Context) error {
	if w.Reconcile == nil {
		return nil
	}
	return w.Reconcile(ctx)
}

// RunWith is Run with an onCycle hook fired after each cycle (nil-safe),
// carrying that cycle's (claimed, error) so a caller can log/observe without the
// provisioner package importing a logger. Used by main() for stderr logging and
// by tests to count cycles.
//
// When SweepEvery > 0 and Sweep is set, an orphan sweep runs every SweepEvery
// completed cycles (in addition to main()'s startup sweep) so a long-lived worker
// keeps recovering orphans. A sweep error is reported via onCycle (claimed=false)
// and is non-fatal — the loop keeps draining jobs.
func (w *Worker) RunWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	cycles := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnce(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}
		cycles++

		// Periodic orphan sweep: every SweepEvery cycles, recover any box a prior
		// double-failure marked orphaned. Non-fatal; surfaced through onCycle.
		if w.SweepEvery > 0 && w.Sweep != nil && cycles%w.SweepEvery == 0 {
			if _, serr := w.SweepOnce(ctx); serr != nil && onCycle != nil {
				onCycle(false, fmt.Errorf("orphan sweep: %w", serr))
			}
		}

		// Periodic warm-pool reconcile: every ReconcileEvery cycles, hold the pool at
		// its target size (top up shortfalls, retire excess). Non-fatal; surfaced
		// through onCycle. Never touches an in-flight assign's box.
		if w.ReconcileEvery > 0 && w.Reconcile != nil && cycles%w.ReconcileEvery == 0 {
			if rerr := w.ReconcileOnce(ctx); rerr != nil && onCycle != nil {
				onCycle(false, fmt.Errorf("warm-pool reconcile: %w", rerr))
			}
		}

		// Periodic self-refresh: every RefreshEvery cycles, kick a background
		// refresh of the stalest due pool box to origin/main so a claim almost
		// never rebuilds (snapshot-management). Non-blocking + one-in-flight, so a
		// multi-minute rebuild never holds up the claim loop.
		if w.RefreshEvery > 0 && w.Refresh != nil && cycles%w.RefreshEvery == 0 {
			w.Refresh(ctx)
		}

		// Only idle-sleep when there was nothing to do; a drained job loops
		// straight back to claim the next one.
		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// claim POSTs the claim endpoint. A 200 decodes into a JobSpec (ok=true); a 204
// is the empty-queue signal (ok=false, no error). Any other status is an error.
func (w *Worker) claim(ctx context.Context) (JobSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(claimPath), nil)
	if err != nil {
		return JobSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return JobSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return JobSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return JobSpec{}, false, fmt.Errorf("POST %s: status %d: %s", claimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var job JobSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &job); err != nil {
			return JobSpec{}, false, fmt.Errorf("decode claim response: %w", err)
		}
	}
	if strings.TrimSpace(job.JobID) == "" {
		return JobSpec{}, false, fmt.Errorf("claim response missing job_id: %s", truncate(string(data), 200))
	}
	return job, true, nil
}

// succeed reports a provisioned host's IP (flipping the barkpark to up) and, when
// the chain minted one, the per-instance admin token (instance-admin-token) so
// the control plane can store it encrypted for the owner. The token is sent ONLY
// when non-empty so the ip-only contract is unchanged; it is part of the request
// body and is NEVER written to a log.
//
// dwb-4: when a content bootstrap ran, its outputs ride along as `bootstrap`
// (workspace/project/dataset slugs, the minted read token, the resolved app
// env) so the control plane stores the secret halves encrypted on the barkpark
// row. Absent (nil) → the pre-template body exactly; an OLD control plane
// simply ignores the extra key.
func (w *Worker) succeed(ctx context.Context, jobID, claimToken, ip, adminToken string, boot *BootstrapOutputs) error {
	body := map[string]any{"ip": ip}
	if adminToken != "" {
		body["admin_token"] = adminToken
	}
	if boot != nil {
		body["bootstrap"] = map[string]any{
			"template":   boot.Template,
			"workspace":  boot.Workspace,
			"project":    boot.Project,
			"dataset":    boot.Dataset,
			"read_token": boot.ReadToken,
			"env":        boot.Env,
		}
	}
	return w.postJSON(ctx, fmt.Sprintf(succeedPathFmt, jobID), claimBody(body, claimToken))
}

// succeedSupport reports a provisioned SUPPORT box's IP and, when the chain
// minted one, the OPAQUE id of the support's ledger token as `token_id`
// (task-5866ec745efcd7f7). The CP persists it as the row's fleet_token_id —
// the SOLE durable token-id holder (PDF-D68), which `bp cloud support remove`
// later revokes. ADDITIVE contract, tolerant both ways: the key is sent ONLY
// when non-empty (the ip-only body is byte-identical to before for a mint
// response that carried no id), and an OLD control plane simply ignores it.
// The ledger-token VALUE never rides here — only its opaque, non-secret id.
//
// `admin_token` is the box's own minted per-instance admin bearer — the SAME
// key mains' succeed sends (the CP's role-agnostic succeed_job encrypts it at
// rest), so mint_studio_link works against the support's reserved url. Sent
// ONLY when non-empty; part of the request body and NEVER written to a log.
func (w *Worker) succeedSupport(ctx context.Context, jobID, claimToken, ip, tokenID, adminToken string) error {
	body := map[string]any{"ip": ip}
	if tokenID != "" {
		body["token_id"] = tokenID
	}
	if adminToken != "" {
		body["admin_token"] = adminToken
	}
	return w.postJSON(ctx, fmt.Sprintf(succeedPathFmt, jobID), claimBody(body, claimToken))
}

// succeedSupportWithRetry is succeedSupport through the shared transient-retry
// loop (mirrors succeedWithRetry: 5xx/transport retries, 4xx stops).
func (w *Worker) succeedSupportWithRetry(ctx context.Context, jobID, claimToken, ip, tokenID, adminToken string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error {
		return w.succeedSupport(ctx, jobID, claimToken, ip, tokenID, adminToken)
	})
}

// fail reports a provision failure; the barkpark stays provisioning for retry.
func (w *Worker) fail(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.postJSON(ctx, fmt.Sprintf(failPathFmt, jobID), claimBody(map[string]any{"error": errMsg}, claimToken))
}

// claimBody merges the claim-fence token (bp-c55) into a transition request body:
// base (may be nil) plus "claim_token" ONLY when non-empty. Sending the key only
// when present keeps the token-less request byte-for-byte compatible with an old
// control plane whose claim response lacked a claim_token (Stage 1 compat).
func claimBody(base map[string]any, claimToken string) map[string]any {
	if base == nil {
		base = map[string]any{}
	}
	if claimToken != "" {
		base["claim_token"] = claimToken
	}
	return base
}

// postJSON marshals body and POSTs it to ControlURL+path with the Bearer token,
// enforcing a 2xx response. The body is discarded (the contract returns
// {ok:true}); a non-2xx carries the truncated body for diagnosis.
func (w *Worker) postJSON(ctx context.Context, path string, body any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(path), bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &httpStatusError{status: resp.StatusCode, msg: fmt.Sprintf("POST %s: status %d: %s", path, resp.StatusCode, truncate(string(data), 200))}
	}
	return nil
}

// httpStatusError is the error postJSON returns when the control plane answered
// with a non-2xx status — distinct from a transport failure (connection
// refused/reset/timeout, which surface as the raw net error). It carries the
// status so succeedWithRetry can classify by CLASS, not just presence: a 5xx is a
// transient deploy-restart/blip (retry), a 4xx is a terminal rejection (stop).
type httpStatusError struct {
	status int
	msg    string
}

func (e *httpStatusError) Error() string { return e.msg }

// statusError extracts the *httpStatusError from err (if any), so callers can read
// the status code without re-implementing the errors.As dance.
func statusError(err error) (*httpStatusError, bool) {
	var se *httpStatusError
	if errors.As(err, &se) {
		return se, true
	}
	return nil, false
}

// is4xx reports whether err is a 4xx control-plane rejection — a TERMINAL refusal
// of this report (e.g. 409 for a job already reaped at the attempts cap). An
// immediate re-POST cannot change a 4xx, so succeedWithRetry stops on it. Anything
// that is NOT a 4xx — a 5xx (Caddy 502/503 during a `systemctl restart
// barkpark.service` deploy, or a 500 blip) and a transport/timeout failure — is
// transient and stays in the retry loop.
func is4xx(err error) bool {
	se, ok := statusError(err)
	return ok && se.status >= 400 && se.status <= 499
}

// authorize attaches the shared WORKER_TOKEN bearer (when set).
func (w *Worker) authorize(req *http.Request) {
	if w.Token != "" {
		req.Header.Set("Authorization", "Bearer "+w.Token)
	}
}

// url joins the trimmed ControlURL with path.
func (w *Worker) url(path string) string {
	return strings.TrimRight(w.ControlURL, "/") + path
}

func (w *Worker) RunDeprovision(ctx context.Context) error {
	return w.RunDeprovisionWith(ctx, nil)
}

func (w *Worker) RunDeprovisionWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnceDeprovision(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}

		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// RunOnceDeprovision claims one deprovision job, deletes the box+DNS, reports
// succeed/fail. NO orphan edge: deprovision is idempotent (delete-if-exists), so a
// dropped succeed-report just re-runs as a no-op on a later reaper re-claim.
func (w *Worker) RunOnceDeprovision(ctx context.Context) (claimed bool, err error) {
	if w.Deprovision == nil {
		return false, nil
	}

	spec, ok, err := w.claimDeprovision(ctx)
	if err != nil {
		return false, fmt.Errorf("deprovision claim: %w", err)
	}
	if !ok {
		return false, nil
	}

	if derr := w.Deprovision(ctx, spec); derr != nil {
		if rerr := w.failDeprovisionWithRetry(ctx, spec.JobID, spec.ClaimToken, derr.Error()); rerr != nil {
			return false, fmt.Errorf("report deprovision fail for job %s (delete error %v): %w", spec.JobID, derr, rerr)
		}
		return true, nil
	}

	if rerr := w.succeedDeprovisionWithRetry(ctx, spec.JobID, spec.ClaimToken); rerr != nil {
		return false, fmt.Errorf("report deprovision succeed for job %s (box already gone; job left for retry): %w", spec.JobID, rerr)
	}
	return true, nil
}

func (w *Worker) claimDeprovision(ctx context.Context) (DeprovisionSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(deprovisionClaimPath), nil)
	if err != nil {
		return DeprovisionSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return DeprovisionSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return DeprovisionSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return DeprovisionSpec{}, false, fmt.Errorf("POST %s: status %d: %s", deprovisionClaimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var spec DeprovisionSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &spec); err != nil {
			return DeprovisionSpec{}, false, fmt.Errorf("decode deprovision claim response: %w", err)
		}
	}
	if strings.TrimSpace(spec.JobID) == "" {
		return DeprovisionSpec{}, false, fmt.Errorf("deprovision claim response missing job_id: %s", truncate(string(data), 200))
	}
	return spec, true, nil
}

// succeedDeprovision reports a completed teardown. claim-fence (bp-c55): echo the
// claim_token when present so a stale worker's succeed is fenced; sent only when
// non-empty (Stage 1 compat with a token-less control plane).
func (w *Worker) succeedDeprovision(ctx context.Context, jobID, claimToken string) error {
	return w.postJSON(ctx, fmt.Sprintf(deprovisionSucceedPathFmt, jobID), claimBody(nil, claimToken))
}

func (w *Worker) failDeprovision(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.postJSON(ctx, fmt.Sprintf(deprovisionFailPathFmt, jobID), claimBody(map[string]any{"error": errMsg}, claimToken))
}

func (w *Worker) succeedDeprovisionWithRetry(ctx context.Context, jobID, claimToken string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.succeedDeprovision(ctx, jobID, claimToken) })
}

func (w *Worker) failDeprovisionWithRetry(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.failDeprovision(ctx, jobID, claimToken, errMsg) })
}

func (w *Worker) RunAttachDomain(ctx context.Context) error {
	return w.RunAttachDomainWith(ctx, nil)
}

func (w *Worker) RunAttachDomainWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnceAttachDomain(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}

		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// RunOnceAttachDomain claims one attach-domain job, points the DNS A record at
// the box and configures it (env origin merge + Caddy vhost + reload/restart),
// reports succeed/fail. NO orphan edge: every attach step is idempotent (DNS
// upsert, guarded env merge, guarded vhost append), so a dropped succeed-report
// just re-runs as a no-op on a later reaper re-claim.
func (w *Worker) RunOnceAttachDomain(ctx context.Context) (claimed bool, err error) {
	if w.AttachDomain == nil {
		return false, nil
	}

	spec, ok, err := w.claimAttachDomain(ctx)
	if err != nil {
		return false, fmt.Errorf("attach-domain claim: %w", err)
	}
	if !ok {
		return false, nil
	}

	if aerr := w.AttachDomain(ctx, spec); aerr != nil {
		if rerr := w.failAttachDomainWithRetry(ctx, spec.JobID, spec.ClaimToken, aerr.Error()); rerr != nil {
			return false, fmt.Errorf("report attach-domain fail for job %s (attach error %v): %w", spec.JobID, aerr, rerr)
		}
		return true, nil
	}

	if rerr := w.succeedAttachDomainWithRetry(ctx, spec.JobID, spec.ClaimToken); rerr != nil {
		return false, fmt.Errorf("report attach-domain succeed for job %s (box already configured; job left for retry): %w", spec.JobID, rerr)
	}
	return true, nil
}

func (w *Worker) claimAttachDomain(ctx context.Context) (AttachDomainSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(attachDomainClaimPath), nil)
	if err != nil {
		return AttachDomainSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return AttachDomainSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return AttachDomainSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return AttachDomainSpec{}, false, fmt.Errorf("POST %s: status %d: %s", attachDomainClaimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var spec AttachDomainSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &spec); err != nil {
			return AttachDomainSpec{}, false, fmt.Errorf("decode attach-domain claim response: %w", err)
		}
	}
	if strings.TrimSpace(spec.JobID) == "" {
		return AttachDomainSpec{}, false, fmt.Errorf("attach-domain claim response missing job_id: %s", truncate(string(data), 200))
	}
	return spec, true, nil
}

// succeedAttachDomain reports a completed attach. claim-fence (bp-c55): echo the
// claim_token when present so a stale worker's succeed is fenced; sent only when
// non-empty (Stage 1 compat with a token-less control plane).
func (w *Worker) succeedAttachDomain(ctx context.Context, jobID, claimToken string) error {
	return w.postJSON(ctx, fmt.Sprintf(attachDomainSucceedPathFmt, jobID), claimBody(nil, claimToken))
}

func (w *Worker) failAttachDomain(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.postJSON(ctx, fmt.Sprintf(attachDomainFailPathFmt, jobID), claimBody(map[string]any{"error": errMsg}, claimToken))
}

func (w *Worker) succeedAttachDomainWithRetry(ctx context.Context, jobID, claimToken string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.succeedAttachDomain(ctx, jobID, claimToken) })
}

func (w *Worker) failAttachDomainWithRetry(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.failAttachDomain(ctx, jobID, claimToken, errMsg) })
}

func (w *Worker) RunResurrect(ctx context.Context) error {
	return w.RunResurrectWith(ctx, nil)
}

// RunResurrectWith is the 4th drain loop (charter S14f) — the portable-archive
// RESTORE queue, run in its own goroutine like Deprovision/AttachDomain. It claims
// resurrect jobs from resurrectClaimPath, TRANSLATES each claim's string bundle_ref
// into a full *BundleRef (store + KEK from worker env), and runs it through the
// SAME Provision seam (which routes a BundleRef-carrying job to the restore chain).
func (w *Worker) RunResurrectWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnceResurrect(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}

		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// RunOnceResurrect claims one resurrect job, translates its bundle_ref, restores
// the box, and reports succeed/fail. It mirrors RunOnce's ORPHAN-TEARDOWN branch,
// NOT deprovision's simpler one (D45): a resurrected box is a live, BILLED box, so
// a dropped succeed-report must tear it down rather than orphan a paying instance.
// It does NOT participate in the graceful-shutdown claim-release coordination
// (setInflight) — that is the primary provision loop's exclusive mechanism; this
// concurrent loop follows the deprovision/attach pattern (a resurrect that outruns
// shutdown is recovered by the control-plane stale-claim reaper).
//
// TRANSLATE is where a resurrect can honestly fail before any box exists: a missing
// bundle env (D43) or a torn/foreign bundle fails the JOB (reported to /fail, the
// drain survives), never the worker.
func (w *Worker) RunOnceResurrect(ctx context.Context) (claimed bool, err error) {
	if w.Resurrect == nil {
		return false, nil // the resurrect queue is not wired.
	}
	if w.Provision == nil {
		return false, fmt.Errorf("provisioner: a Provision func must be injected for resurrect")
	}

	spec, ok, err := w.claimResurrect(ctx)
	if err != nil {
		return false, fmt.Errorf("resurrect claim: %w", err)
	}
	if !ok {
		return false, nil // 204 — nothing pending.
	}

	// TRANSLATE (D43): resolve the store + KEK from WORKER ENV and read the bundle
	// manifest, building the full *BundleRef the restore chain needs. A missing var
	// (or a torn/foreign bundle) is an honest JOB failure — report /fail so the
	// control plane records it, then move on (the drain survives).
	deps, derr := w.Resurrect()
	if derr != nil {
		return w.finishResurrect(ctx, spec.JobID, spec.ClaimToken, fmt.Errorf("resurrect bundle store not configured: %w", derr))
	}
	job, terr := translateResurrect(ctx, spec, deps)
	if terr != nil {
		return w.finishResurrect(ctx, spec.JobID, spec.ClaimToken, terr)
	}

	// Bound the restore like a provision so one hung step fails the job instead of
	// pinning this loop forever.
	pto := w.ProvisionTimeout
	if pto <= 0 {
		pto = DefaultProvisionTimeout
	}
	provCtx, cancel := context.WithTimeout(ctx, pto)
	ip, _, _, teardown, provErr := w.Provision(provCtx, job)
	cancel()

	if provErr != nil {
		// The restore chain already tore down any half-built box (teardown nil on
		// failure). Report so the control plane records it and the row stays
		// provisioning for a later retry.
		return w.finishResurrect(ctx, spec.JobID, spec.ClaimToken, provErr)
	}

	// Restore SUCCEEDED: a paid box is live but the control plane does not yet know
	// (its succeed POST is the only signal). Retry transient report failures; on a
	// report that never lands, tear the box down so no BILLED box is orphaned — the
	// RunOnce money-edge, applied to a resurrect (D45). adminToken/boot are empty on
	// a restore (identity is RESTORED, never minted; no template bootstrap).
	if rerr := w.succeedWithRetry(ctx, spec.JobID, spec.ClaimToken, ip, "", nil); rerr != nil {
		if teardown != nil {
			if cerr := teardown(ctx); cerr != nil {
				return false, fmt.Errorf("report resurrect succeed for job %s failed (%v) AND orphan teardown failed: %w", spec.JobID, rerr, cerr)
			}
		}
		return false, fmt.Errorf("report resurrect succeed for job %s (box torn down to avoid an orphan, job left for retry): %w", spec.JobID, rerr)
	}
	return true, nil
}

// finishResurrect reports a resurrect FAILURE (translate error or a failed restore)
// through the shared transient-retry fail path — reusing the provision-jobs /fail
// endpoint (a resurrect rides the same job machine, S14c). A report that never
// lands leaves the job un-consumed (claimed=false) for the reaper; a landed report
// is a cleanly-handled cycle (claimed=true).
func (w *Worker) finishResurrect(ctx context.Context, jobID, claimToken string, jobErr error) (bool, error) {
	if rerr := w.failWithRetry(ctx, jobID, claimToken, jobErr.Error()); rerr != nil {
		return false, fmt.Errorf("report resurrect fail for job %s (job error %v): %w", jobID, jobErr, rerr)
	}
	return true, nil
}

// claimResurrect POSTs the resurrect claim endpoint. A 200 decodes into a
// resurrectClaimSpec (the provision claim fields PLUS bundle_ref as a STRING — D43);
// a 204 is the empty-queue signal. Any other status is an error.
func (w *Worker) claimResurrect(ctx context.Context) (resurrectClaimSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(resurrectClaimPath), nil)
	if err != nil {
		return resurrectClaimSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return resurrectClaimSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return resurrectClaimSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return resurrectClaimSpec{}, false, fmt.Errorf("POST %s: status %d: %s", resurrectClaimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var spec resurrectClaimSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &spec); err != nil {
			return resurrectClaimSpec{}, false, fmt.Errorf("decode resurrect claim response: %w", err)
		}
	}
	if strings.TrimSpace(spec.JobID) == "" {
		return resurrectClaimSpec{}, false, fmt.Errorf("resurrect claim response missing job_id: %s", truncate(string(data), 200))
	}
	if strings.TrimSpace(spec.BundleRef) == "" {
		return resurrectClaimSpec{}, false, fmt.Errorf("resurrect claim response missing bundle_ref: %s", truncate(string(data), 200))
	}
	return spec, true, nil
}

func (w *Worker) RunSupport(ctx context.Context) error {
	return w.RunSupportWith(ctx, nil)
}

// RunSupportWith is the 5th drain loop (Personal Dev Fleet MVP-0, PDF-D83) —
// the provision_support queue, run in its own goroutine like Deprovision/
// AttachDomain/Resurrect (mirroring RunResurrectWith). It claims support jobs
// from supportClaimPath and runs each through the injected SupportProvision
// (the server-side create/configure/content/verify/ready chain).
func (w *Worker) RunSupportWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnceSupport(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}

		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// RunOnceSupport claims one provision_support job, runs the support chain, and
// reports succeed/fail through the generic provision-jobs endpoints (PDF-D83).
// It mirrors RunOnceResurrect's ORPHAN-TEARDOWN branch, not deprovision's
// simpler one: a provisioned support is a live, BILLED box, so a dropped
// succeed-report must tear it down rather than orphan it. Like the other
// concurrent drains it does NOT participate in the graceful-shutdown
// claim-release coordination (setInflight is the primary provision loop's
// exclusive mechanism); a support job that outruns shutdown is recovered by
// the control-plane stale-claim reaper.
func (w *Worker) RunOnceSupport(ctx context.Context) (claimed bool, err error) {
	if w.SupportProvision == nil {
		return false, nil // the support queue is not wired.
	}

	spec, ok, err := w.claimSupport(ctx)
	if err != nil {
		return false, fmt.Errorf("support claim: %w", err)
	}
	if !ok {
		return false, nil // 204 — nothing pending.
	}

	// Bound the chain so one hung step (a wedged SSH, a never-answering roster)
	// fails the job instead of pinning this loop forever. The support default is
	// WIDER than a provision's (configure + the ~10-min verify budget serialize).
	pto := w.ProvisionTimeout
	if pto <= 0 {
		pto = DefaultSupportProvisionTimeout
	}
	provCtx, cancel := context.WithTimeout(ctx, pto)
	ip, tokenID, adminToken, teardown, provErr := w.SupportProvision(provCtx, spec)
	cancel()

	if provErr != nil {
		// The chain already tore down any half-built box (teardown nil on
		// failure — see SupportProvisionWith.failStep). Report so the control
		// plane records the honest terminal state (PDF-D10/D89: stuck-provisioning
		// renders honestly, never fakes online, never bills).
		if rerr := w.failWithRetry(ctx, spec.Job.ID, spec.Job.ClaimToken, provErr.Error()); rerr != nil {
			return false, fmt.Errorf("report support fail for job %s (job error %v): %w", spec.Job.ID, provErr, rerr)
		}
		return true, nil
	}

	// Chain SUCCEEDED: a paid box is live but the control plane does not yet
	// know (its succeed POST is the only signal). Retry transient report
	// failures; on a report that never lands, tear the box down so no BILLED
	// box is orphaned — the RunOnce money-edge, applied to a support. The
	// minted ledger token's opaque id rides along (task-5866ec745efcd7f7) so
	// the CP row's fleet_token_id is set and remove can revoke the token, and
	// the box's minted admin token rides as `admin_token` (same key as mains)
	// so the CP stores it encrypted and Open Studio works on the support.
	if rerr := w.succeedSupportWithRetry(ctx, spec.Job.ID, spec.Job.ClaimToken, ip, tokenID, adminToken); rerr != nil {
		if teardown != nil {
			if cerr := teardown(ctx); cerr != nil {
				return false, fmt.Errorf("report support succeed for job %s failed (%v) AND orphan teardown failed: %w", spec.Job.ID, rerr, cerr)
			}
		}
		return false, fmt.Errorf("report support succeed for job %s (box torn down to avoid an orphan, job left for retry): %w", spec.Job.ID, rerr)
	}
	return true, nil
}

// claimSupport POSTs the support claim endpoint. A 200 decodes into the pinned
// SupportJobSpec envelope ({job:{id,claim_token},barkpark:{…},support:{…}} —
// PDF-D83); a 204 is the empty-queue signal. Any other status is an error.
// Only job.id is asserted here — every other field is fenced by
// validateSupportSpec INSIDE the chain, so a malformed claim fails the JOB
// honestly (reported to /fail) rather than erroring the drain.
func (w *Worker) claimSupport(ctx context.Context) (SupportJobSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(supportClaimPath), nil)
	if err != nil {
		return SupportJobSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return SupportJobSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return SupportJobSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return SupportJobSpec{}, false, fmt.Errorf("POST %s: status %d: %s", supportClaimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var spec SupportJobSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &spec); err != nil {
			return SupportJobSpec{}, false, fmt.Errorf("decode support claim response: %w", err)
		}
	}
	if strings.TrimSpace(spec.Job.ID) == "" {
		// TOLERATED DIALECT: the CP's support_provision_claim_json reuses the FLAT
		// claim_json envelope (job_id/claim_token/name/slug/region/server_type at
		// the top level, `support` nested) — the resurrect precedent's shape —
		// while the PDF-D83 pin nests them under job/barkpark. Accept both so the
		// two halves meet regardless of which dialect the merged CP speaks; the
		// `support` map decodes identically either way.
		var flat struct {
			JobID      string `json:"job_id"`
			ClaimToken string `json:"claim_token"`
			Name       string `json:"name"`
			Slug       string `json:"slug"`
			Region     string `json:"region"`
			ServerType string `json:"server_type"`
		}
		if err := json.Unmarshal(data, &flat); err == nil && strings.TrimSpace(flat.JobID) != "" {
			spec.Job.ID = flat.JobID
			spec.Job.ClaimToken = flat.ClaimToken
			if spec.Barkpark.Name == "" {
				spec.Barkpark.Name = flat.Name
				spec.Barkpark.Slug = flat.Slug
				spec.Barkpark.Region = flat.Region
				spec.Barkpark.ServerType = flat.ServerType
			}
		}
	}
	if strings.TrimSpace(spec.Job.ID) == "" {
		// CUSTODY: never echo the claim body here — a 200 payload carries
		// support.parent_admin_token, and this error lands in the worker journal.
		return SupportJobSpec{}, false, fmt.Errorf("support claim response missing job.id (body withheld — it carries credentials)")
	}
	return spec, true, nil
}

// truncate caps s at n runes for error messages.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
func (w *Worker) RunEnableApply(ctx context.Context) error {
	return w.RunEnableApplyWith(ctx, nil)
}

func (w *Worker) RunEnableApplyWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
	interval := w.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		claimed, err := w.RunOnceEnableApply(ctx)
		if onCycle != nil {
			onCycle(claimed, err)
		}

		if !claimed {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
			}
		}
	}
}

// RunOnceEnableApply claims one enable-apply job, flips
// BARKPARK_SELF_UPDATE_APPLY=1 on the box and restarts the app, reports
// succeed/fail. NO orphan edge: both steps are idempotent (guarded env append,
// restart), so a dropped succeed-report just re-runs as a no-op on a later
// reaper re-claim.
func (w *Worker) RunOnceEnableApply(ctx context.Context) (claimed bool, err error) {
	if w.EnableApply == nil {
		return false, nil
	}

	spec, ok, err := w.claimEnableApply(ctx)
	if err != nil {
		return false, fmt.Errorf("enable-apply claim: %w", err)
	}
	if !ok {
		return false, nil
	}

	if eerr := w.EnableApply(ctx, spec); eerr != nil {
		if rerr := w.failEnableApplyWithRetry(ctx, spec.JobID, spec.ClaimToken, eerr.Error()); rerr != nil {
			return false, fmt.Errorf("report enable-apply fail for job %s (enable error %v): %w", spec.JobID, eerr, rerr)
		}
		return true, nil
	}

	if rerr := w.succeedEnableApplyWithRetry(ctx, spec.JobID, spec.ClaimToken); rerr != nil {
		return false, fmt.Errorf("report enable-apply succeed for job %s (box already flagged; job left for retry): %w", spec.JobID, rerr)
	}
	return true, nil
}

func (w *Worker) claimEnableApply(ctx context.Context) (EnableApplySpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(enableApplyClaimPath), nil)
	if err != nil {
		return EnableApplySpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return EnableApplySpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return EnableApplySpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return EnableApplySpec{}, false, fmt.Errorf("POST %s: status %d: %s", enableApplyClaimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var spec EnableApplySpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &spec); err != nil {
			return EnableApplySpec{}, false, fmt.Errorf("decode enable-apply claim response: %w", err)
		}
	}
	if strings.TrimSpace(spec.JobID) == "" {
		return EnableApplySpec{}, false, fmt.Errorf("enable-apply claim response missing job_id: %s", truncate(string(data), 200))
	}
	return spec, true, nil
}

// succeedEnableApply reports a completed enable. claim-fence (bp-c55): echo the
// claim_token when present so a stale worker's succeed is fenced; sent only when
// non-empty (Stage 1 compat with a token-less control plane).
func (w *Worker) succeedEnableApply(ctx context.Context, jobID, claimToken string) error {
	return w.postJSON(ctx, fmt.Sprintf(enableApplySucceedPathFmt, jobID), claimBody(nil, claimToken))
}

func (w *Worker) failEnableApply(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.postJSON(ctx, fmt.Sprintf(enableApplyFailPathFmt, jobID), claimBody(map[string]any{"error": errMsg}, claimToken))
}

func (w *Worker) succeedEnableApplyWithRetry(ctx context.Context, jobID, claimToken string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.succeedEnableApply(ctx, jobID, claimToken) })
}

func (w *Worker) failEnableApplyWithRetry(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.failEnableApply(ctx, jobID, claimToken, errMsg) })
}
