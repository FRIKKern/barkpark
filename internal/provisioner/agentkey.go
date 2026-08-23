package provisioner

// The push_agent_key drain (PDF-D94, `pdf-bl-console-key-custody`) — the
// console replacement for the SSH one-liner. The developer pastes their
// provider key in the console; the control plane is TRANSPORT ONLY (D62
// amended: NEVER WRITES → NEVER KEEPS — the key rides an in-memory one-time
// stash CP-side and arrives here ONLY on the claim payload, never from a DB
// row); this worker delivers it: rewrite exactly one line of
// /etc/barkpark/fleet-listener.env on the ALREADY-LIVE support box over the
// SSH key this worker already holds, restart the listener, report.
//
// Custody on THIS side mirrors the provision_support ledger-token discipline:
// the key is fenced by shape before it touches a shell, delivered into the
// script via an exported env var (Argv-only — never a logged Cmd), and listed
// in CaddyStep.Redact so no captured output can carry it. The claim JSON is
// never logged.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

const (
	agentKeyClaimPath      = "/v1/internal/agent-key-jobs/claim"
	agentKeySucceedPathFmt = "/v1/internal/agent-key-jobs/%s/succeed"
	agentKeyFailPathFmt    = "/v1/internal/agent-key-jobs/%s/fail"
)

// DefaultAgentKeyPushTimeout bounds one delivery: a single SSH exec (env-line
// rewrite + systemctl restart) on a live box — seconds, not minutes — but it
// MUST be bounded so a dead SSH connection fails the job instead of pinning
// the drain.
const DefaultAgentKeyPushTimeout = 2 * time.Minute

// agentKeyVarVocab is the closed set of env var NAMES a delivery may write —
// exactly the supportAgentPackages keyVar column. Anything else is refused
// before any SSH runs (fail closed; the control plane enforces the same set).
var agentKeyVarVocab = map[string]bool{"ANTHROPIC_API_KEY": true, "OPENAI_API_KEY": true}

// agentKeySafeRe fences the key material itself before it is single-quoted
// into the delivery script — the same alphabet the support chain's
// supportTokenSafeRe pins for the ledger token, with explicit length bounds.
// A value that could break out of shell quoting is refused, not escaped.
var agentKeySafeRe = regexp.MustCompile(`^[A-Za-z0-9._~+/=-]{20,512}$`)

// AgentKeyJobSpec is one claimed push_agent_key job — the EXACT JSON the
// control plane's POST /v1/internal/agent-key-jobs/claim returns on 200 (a 204
// means no pending job). `key` is the one-time pop of the CP's in-memory
// stash: this payload is the only place it ever exists outside the browser and
// the box.
type AgentKeyJobSpec struct {
	Job    SupportJobRef `json:"job"`
	IP     string        `json:"ip"`
	KeyVar string        `json:"key_var"`
	Key    string        `json:"key"`
}

// AgentKeyPushFunc delivers one claimed key to its box. A non-nil error is the
// fail signal (reported to /fail; the box is untouched or partially updated —
// the delivery script is idempotent, so re-paste re-runs it cleanly).
type AgentKeyPushFunc func(ctx context.Context, spec AgentKeyJobSpec) error

// AgentKeySeams bundles the injectables one delivery needs. Production sets
// nothing (the real SSH runner via the key already on the worker box); tests
// inject RunnerFor recorders so no live SSH is ever touched.
type AgentKeySeams struct {
	// RunnerFor builds the per-host step runner. nil → cloud.NewSSHStepRunner.
	RunnerFor func(host string) cloud.StepRunner
}

// agentKeyInstallStep writes/replaces the ONE key line in the listener env
// (0600 preserved via umask + an atomic tmp-rewrite) and restarts the
// listener. The key rides in via $BP_AGENT_KEY inside Argv (never the logged
// Cmd), exactly the supportUnitInstallStep contract, and is Redact-listed so
// pattern capture can never echo it. keyVar is vocab-fenced by the caller, so
// interpolating it into grep/printf is safe.
func agentKeyInstallStep(keyVar, key string) cloud.CaddyStep {
	script := `set -e
export BP_AGENT_KEY='` + key + `'
mkdir -p /etc/barkpark
umask 077
touch /etc/barkpark/fleet-listener.env
tmp=$(mktemp /etc/barkpark/.fleet-listener.env.XXXXXX)
grep -v '^` + keyVar + `=' /etc/barkpark/fleet-listener.env > "$tmp" || true
printf '` + keyVar + `=%s\n' "$BP_AGENT_KEY" >> "$tmp"
chmod 600 "$tmp"
mv "$tmp" /etc/barkpark/fleet-listener.env
systemctl restart barkpark-fleet-listener`
	return cloud.CaddyStep{
		Title:  "deliver " + keyVar + " to /etc/barkpark/fleet-listener.env (0600) + restart the listener",
		Cmd:    "rewrite the " + keyVar + " line (key redacted) + systemctl restart barkpark-fleet-listener",
		Argv:   []string{"bash", "-lc", script},
		Redact: []string{key},
	}
}

// DefaultAgentKeyPush returns an AgentKeyPushFunc bound to seams — validate
// the claim defensively (fail the JOB, never the drain), then run the one
// idempotent delivery step on the box.
func DefaultAgentKeyPush(seams AgentKeySeams) AgentKeyPushFunc {
	runnerFor := seams.RunnerFor
	if runnerFor == nil {
		runnerFor = func(host string) cloud.StepRunner { return cloud.NewSSHStepRunner(host) }
	}

	return func(ctx context.Context, spec AgentKeyJobSpec) error {
		if strings.TrimSpace(spec.IP) == "" {
			return fmt.Errorf("agent-key claim carries no box ip")
		}
		if !agentKeyVarVocab[spec.KeyVar] {
			return fmt.Errorf("agent-key claim names an unsupported env var %q", spec.KeyVar)
		}
		if !agentKeySafeRe.MatchString(spec.Key) {
			// NEVER echo the value — a malformed secret is still a secret.
			return fmt.Errorf("agent-key claim carries a key outside the safe shape (not echoed)")
		}

		runner := runnerFor(spec.IP)
		if err := runner.Run(ctx, agentKeyInstallStep(spec.KeyVar, spec.Key)); err != nil {
			return fmt.Errorf("deliver %s: %w", spec.KeyVar, err)
		}
		return nil
	}
}

func (w *Worker) RunAgentKey(ctx context.Context) error {
	return w.RunAgentKeyWith(ctx, nil)
}

// RunAgentKeyWith is the push_agent_key drain loop, run in its own goroutine
// like Deprovision/AttachDomain/Resurrect/Support.
func (w *Worker) RunAgentKeyWith(ctx context.Context, onCycle func(claimed bool, err error)) error {
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

		claimed, err := w.RunOnceAgentKey(ctx)
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

// RunOnceAgentKey claims one push_agent_key job, delivers the key, reports
// succeed/fail. NO orphan edge and NO teardown: the delivery step is
// idempotent on a box that already exists, so a dropped succeed-report just
// re-runs on a reaper re-claim — where the CP's delete-on-read stash then
// fails the job honestly ("paste it again") rather than double-delivering.
func (w *Worker) RunOnceAgentKey(ctx context.Context) (claimed bool, err error) {
	if w.AgentKeyPush == nil {
		return false, nil // the agent-key queue is not wired.
	}

	spec, ok, err := w.claimAgentKey(ctx)
	if err != nil {
		return false, fmt.Errorf("agent-key claim: %w", err)
	}
	if !ok {
		return false, nil
	}

	pushCtx, cancel := context.WithTimeout(ctx, DefaultAgentKeyPushTimeout)
	perr := w.AgentKeyPush(pushCtx, spec)
	cancel()

	if perr != nil {
		if rerr := w.failAgentKeyWithRetry(ctx, spec.Job.ID, spec.Job.ClaimToken, perr.Error()); rerr != nil {
			return false, fmt.Errorf("report agent-key fail for job %s (push error %v): %w", spec.Job.ID, perr, rerr)
		}
		return true, nil
	}

	if rerr := w.succeedAgentKeyWithRetry(ctx, spec.Job.ID, spec.Job.ClaimToken, spec.IP); rerr != nil {
		return false, fmt.Errorf("report agent-key succeed for job %s (key already delivered; job left for retry): %w", spec.Job.ID, rerr)
	}
	return true, nil
}

func (w *Worker) claimAgentKey(ctx context.Context) (AgentKeyJobSpec, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url(agentKeyClaimPath), nil)
	if err != nil {
		return AgentKeyJobSpec{}, false, err
	}
	w.authorize(req)

	resp, err := w.httpClient().Do(req)
	if err != nil {
		return AgentKeyJobSpec{}, false, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return AgentKeyJobSpec{}, false, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		// The error body is CP copy, never the key (the key exists only on a 200).
		return AgentKeyJobSpec{}, false, fmt.Errorf("POST %s: status %d: %s", agentKeyClaimPath, resp.StatusCode, truncate(string(data), 200))
	}

	var spec AgentKeyJobSpec
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &spec); err != nil {
			// Decode errors must not quote the payload — it may carry the key.
			return AgentKeyJobSpec{}, false, fmt.Errorf("decode agent-key claim response (body withheld — it can carry key material): %w", err)
		}
	}
	if strings.TrimSpace(spec.Job.ID) == "" {
		return AgentKeyJobSpec{}, false, fmt.Errorf("agent-key claim response missing job id (body withheld — it can carry key material)")
	}
	return spec, true, nil
}

// succeedAgentKey/failAgentKey mirror the attach-domain reporters: claim-fence
// token echoed when present, body carries only routing facts.
func (w *Worker) succeedAgentKey(ctx context.Context, jobID, claimToken, ip string) error {
	body := map[string]any{}
	if strings.TrimSpace(ip) != "" {
		body["ip"] = ip
	}
	return w.postJSON(ctx, fmt.Sprintf(agentKeySucceedPathFmt, jobID), claimBody(body, claimToken))
}

func (w *Worker) failAgentKey(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.postJSON(ctx, fmt.Sprintf(agentKeyFailPathFmt, jobID), claimBody(map[string]any{"error": errMsg}, claimToken))
}

func (w *Worker) succeedAgentKeyWithRetry(ctx context.Context, jobID, claimToken, ip string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.succeedAgentKey(ctx, jobID, claimToken, ip) })
}

func (w *Worker) failAgentKeyWithRetry(ctx context.Context, jobID, claimToken, errMsg string) error {
	return w.reportWithRetry(ctx, func(ctx context.Context) error { return w.failAgentKey(ctx, jobID, claimToken, errMsg) })
}
