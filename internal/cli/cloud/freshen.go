// dwb-17 warm-image freshness. A provisioned box boots the code baked into the
// warm/base snapshot, which DRIFTS behind origin/main between re-bakes — so a
// fresh instance can silently serve stale code (the #957-adjacent class). The
// freshen step closes that gap at go-live time: it re-checks the box's checkout
// against origin/main and, only when behind, rebuilds it to current BEFORE the
// migrate step runs (migrations must match the code that will serve).
//
// THE MECHANISM (decided — see the dwb-reliability charter D6) is the self-update
// sequence INLINED over SSH, NOT `bash scripts/self-update.sh` (the baked script
// may predate isu-6) and NOT a raw `git pull` (the post-merge hook path wedges
// after a failed build). Two phases:
//
//  1. cheap check (ALWAYS, seconds):
//     cd /opt/barkpark && git fetch origin --tags --prune
//     git rev-parse HEAD ; git rev-parse origin/main ; git describe --tags
//     — compare HEAD vs origin/main. Behind ⟺ they differ.
//  2. rebuild (ONLY when behind):
//     git -c core.hooksPath=/dev/null merge --ff-only origin/main
//     bash scripts/deploy-rebuild.sh
//     deploy-rebuild.sh comes from the NEW tree (post-merge), builds ASIDE and
//     swaps, holds a repo-local flock, and restarts LAST — so a failure,
//     interruption, or timeout leaves the box serving the BAKED code, never a
//     half-broken one. That build-aside guarantee is what lets the in-chain call
//     site degrade to a working box on a freshen failure instead of a dead go-live.
//
// The step runs over the SAME per-host runner the Caddy/migrate steps use (an
// SSHStepRunner in production, a recording fake in tests), but unlike a
// fire-and-forget CaddyStep it must READ the check output to decide whether to
// rebuild and to narrate the version delta — so it rides a capture capability
// (hostCommandRunner) the runner advertises, mirroring the sshReadyWaiter idiom.
package cloud

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// hostCommandRunner is the optional capability a per-host StepRunner advertises
// when it can run an arbitrary shell command on the box and RETURN its combined
// output — what the freshen step needs and the error-only StepRunner.Run cannot
// give. The production SSHStepRunner implements it (RunOutput shells the script
// over the same SSH plumbing Run uses); the recording test fakes script it. A
// runner that does NOT implement it makes EnsureFresh a safe no-op skip (in
// production the runner is always an SSHStepRunner, so this only affects a
// degenerate/legacy fake).
type hostCommandRunner interface {
	RunOutput(ctx context.Context, script string) (string, error)
}

// freshenRepoDir is the on-box git checkout the warm/base snapshot bakes, with
// `origin` pointed at the public GitHub repo — the same path self-update.sh and
// deploy-rebuild.sh operate on.
const freshenRepoDir = "/opt/barkpark"

// freshenCheckScript is the CHEAP freshness probe (phase 1): fetch, then emit the
// local HEAD, the origin/main tip, and both `git describe` versions as
// parseable KEY=VALUE lines on stdout (fetch chatter is routed to stderr so it
// never pollutes the parse). `set -e` makes an unreachable fetch a non-zero exit
// so the caller sees a check failure rather than a stale comparison. Seconds, not
// minutes — it is run on EVERY go-live, so the fetch is ALSO bounded on the box
// (`timeout 90`, generous for weeks of drift): a wedged-but-alive fetch degrades
// to a loud check-failure instead of silently burning the whole provision budget
// (ssh keepalives only catch a DEAD connection).
const freshenCheckScript = `set -e
cd ` + freshenRepoDir + `
timeout 90 git fetch origin --tags --prune 1>&2
printf 'FRESHEN_HEAD=%s\n' "$(git rev-parse HEAD)"
printf 'FRESHEN_REMOTE=%s\n' "$(git rev-parse origin/main)"
printf 'FRESHEN_FROM=%s\n' "$(git describe --tags --always 2>/dev/null || echo unknown)"
printf 'FRESHEN_TO=%s\n' "$(git describe --tags --always origin/main 2>/dev/null || echo unknown)"`

// freshenRebuildScript renders the REBUILD (phase 2), run ONLY when the check
// found the box behind: fast-forward to origin/main with the post-merge hook
// SUPPRESSED (the hook path wedges after a failed build — self-update.sh's header
// documents why), then invoke deploy-rebuild.sh EXPLICITLY. deploy-rebuild.sh
// builds aside and swaps under a repo-local flock, restarting last, so an
// interrupted/failed rebuild leaves the baked code serving. `--ff-only` REFUSES a
// diverged checkout (exit non-zero) rather than rewriting history — a snapshot
// should never diverge, and if it somehow has, failing is safer than a merge commit.
//
// When budget > 0 the rebuild is ALSO bounded ON THE BOX with coreutils `timeout`
// (exit 124), not just by the caller's local context. This is load-bearing for the
// in-chain fail-open path: a local-only timeout kills the ssh CLIENT but the
// remote deploy-rebuild.sh would run on to COMPLETION — swapping _build/prod and
// `systemctl restart barkpark` at an unpredictable moment while the go-live chain
// is already proceeding through secrets-install/migrate/health, which can fail the
// very go-live the degrade was meant to save. The remote timeout TERMs the script
// BEFORE its swap/restart lines can run (an orphaned inner `mix compile` may
// linger, but only writes the aside _build_next — it can never swap or restart).
// The caller's local context gets a small grace on top (see EnsureFresh) so the
// remote timeout fires first and its output/exit 124 are captured.
func freshenRebuildScript(budget time.Duration) string {
	rebuild := "bash scripts/deploy-rebuild.sh"
	if budget > 0 {
		rebuild = fmt.Sprintf("timeout %d %s", int(budget.Seconds()), rebuild)
	}
	return `set -e
cd ` + freshenRepoDir + `
git -c core.hooksPath=/dev/null merge --ff-only origin/main
` + rebuild
}

// freshenRebuildBudget bounds the in-chain rebuild (call site (b), configureHost)
// — remotely via `timeout` and locally via a grace-padded sub-context. A clean
// Elixir rebuild is many minutes; 12 is generous while still bounding the wait so
// a wedged build degrades to the baked box rather than pinning the go-live. The
// warm-create call site (a) does NOT set a sub-budget — it runs under
// warmRefillTimeout (freshenWarmBox bounds it for BOTH warm callers), where nobody
// waits and a timed-out box is torn down anyway.
const freshenRebuildBudget = 12 * time.Minute

// freshenLocalGrace is how much longer than the remote `timeout` bound the LOCAL
// rebuild sub-context waits, so the remote timeout fires first and EnsureFresh
// captures the box's own output + exit 124 instead of a bare context deadline.
const freshenLocalGrace = 30 * time.Second

// Degrade captions — the honest, calm copy the freshen step narrates when it
// proceeds on the baked release rather than failing the go-live. slice 1's
// register-time refresh_update_status then renders the box "behind" with a
// one-click self-update, so a degrade is a VISIBLE, fixable state, never a lie.
const (
	freshenCurrentCaption       = "Already up to date"
	freshenCheckFailedCaption   = "Couldn't check for updates — continuing on the baked release."
	freshenRebuildFailedCaption = "Couldn't update — continuing on the baked release; you can update from the dashboard."
)

// FreshenResult reports what EnsureFresh did, for the caller's logging + policy.
// It is returned alongside a possibly-non-nil error: the in-chain caller IGNORES
// the error (fail-open — build-aside guarantees a working box) and the warm-create
// caller ACTS on it (fail-closed — tear the box down; a stale box never enters the
// pool). The narration is emitted by EnsureFresh itself via the injected Narrate.
type FreshenResult struct {
	// Skipped is set when the runner has no capture capability — freshness could
	// not be verified, so nothing was done (a no-op).
	Skipped bool
	// Checked is set when the cheap check ran and parsed.
	Checked bool
	// Behind is set when HEAD differed from origin/main (a rebuild was attempted).
	Behind bool
	// Rebuilt is set when the rebuild ran AND succeeded — the box now serves current.
	Rebuilt bool
	// Degraded is set when the box proceeds on the BAKED code after a non-fatal
	// failure (unreachable fetch / unparseable check / failed rebuild). The box
	// works; it is just behind.
	Degraded bool
	// FromVersion / ToVersion are `git describe` of HEAD and origin/main (best-effort,
	// "unknown" when the box has no tags) — the version delta for narration.
	FromVersion string
	ToVersion   string
}

// FreshenOpts configures one EnsureFresh call.
type FreshenOpts struct {
	// RebuildTimeout, when > 0, bounds JUST the rebuild phase in its own
	// context.WithTimeout (the in-chain sub-budget). Zero → the rebuild runs under
	// the caller's ctx unchanged (the warm-create path, bounded by warmRefillTimeout).
	RebuildTimeout time.Duration
	// Narrate, when set, reports the freshen step's transitions (nil-safe). status ∈
	// started | progress | done; detail is the human caption. EnsureFresh NEVER
	// narrates a `failed` status: a freshen failure DEGRADES to a working box, so a
	// red timeline row would misread as breakage — it narrates `done` with a
	// truthful caption instead. The warm-create call site passes nil (no user is
	// watching a background pool refill).
	Narrate func(status, detail string)
}

// EnsureFresh runs the freshen sequence over runner: the cheap check ALWAYS, then
// the rebuild ONLY when the box is behind origin/main. It returns a FreshenResult
// describing what happened plus an error that is non-nil on ANY freshen failure
// (unreachable fetch, unparseable check, or a failed/timed-out rebuild). The
// CALLER owns the failure POLICY:
//
//   - in-chain (configureHost): IGNORE the error — proceed on the baked code
//     (build-aside guarantees the box works; slice 1 renders it "behind").
//   - warm-create (defaultWarmRefill / reconcile grow): ACT on the error — tear
//     the box down so a stale box never enters the pool.
//
// Narration (when opts.Narrate is set) is emitted here so the "started → caption →
// done" lifecycle interleaves correctly around the multi-minute rebuild.
func EnsureFresh(ctx context.Context, runner StepRunner, opts FreshenOpts) (FreshenResult, error) {
	narrate := opts.Narrate
	if narrate == nil {
		narrate = func(string, string) {}
	}

	cmd, ok := runner.(hostCommandRunner)
	if !ok {
		// No capture capability — freshness can't be verified. Safe no-op skip; in
		// production the runner is always an SSHStepRunner, so this is a test/legacy
		// path only. No narration (nothing happened).
		return FreshenResult{Skipped: true}, nil
	}

	narrate("started", "")

	// Phase 1 — the cheap check, ALWAYS.
	out, err := cmd.RunOutput(ctx, freshenCheckScript)
	if err != nil {
		// Unreachable fetch / git error. NEVER brick a go-live on GitHub flake:
		// proceed loudly on the baked code.
		narrate("done", freshenCheckFailedCaption)
		return FreshenResult{Degraded: true}, fmt.Errorf("freshen: freshness check failed: %w: %s", err, tailOf(out, freshenErrOutputMax))
	}
	head, remote, from, to := parseFreshenCheck(out)
	if head == "" || remote == "" {
		narrate("done", freshenCheckFailedCaption)
		return FreshenResult{Degraded: true}, fmt.Errorf("freshen: could not parse freshness check output: %q", strings.TrimSpace(out))
	}

	res := FreshenResult{Checked: true, FromVersion: from, ToVersion: to}
	if head == remote {
		// Current — the common case once re-bakes are frequent. No rebuild.
		narrate("progress", freshenCurrentCaption)
		narrate("done", freshenCurrentCaption)
		return res, nil
	}

	// Phase 2 — behind → rebuild.
	res.Behind = true
	narrate("progress", updatingCaption(from, to))

	// The budget is enforced on the BOX (remote `timeout`, so a timed-out rebuild
	// can never swap/restart underneath the proceeding chain — see
	// freshenRebuildScript) with the local sub-context as a grace-padded backstop
	// for a dead connection.
	rctx := ctx
	if opts.RebuildTimeout > 0 {
		var cancel context.CancelFunc
		rctx, cancel = context.WithTimeout(ctx, opts.RebuildTimeout+freshenLocalGrace)
		defer cancel()
	}
	if rout, rerr := cmd.RunOutput(rctx, freshenRebuildScript(opts.RebuildTimeout)); rerr != nil {
		// The rebuild failed or timed out. deploy-rebuild.sh builds ASIDE and swaps
		// last, so the box is STILL serving the baked code — degrade, don't die.
		narrate("done", freshenRebuildFailedCaption)
		res.Degraded = true
		return res, fmt.Errorf("freshen: rebuild failed: %w: %s", rerr, tailOf(rout, freshenErrOutputMax))
	}

	res.Rebuilt = true
	narrate("done", updatedCaption(from, to))
	return res, nil
}

// parseFreshenCheck pulls the FRESHEN_* KEY=VALUE lines out of the cheap check's
// stdout. Missing keys come back empty; the caller treats an empty head/remote as
// an unparseable check (a degrade) rather than guessing.
func parseFreshenCheck(out string) (head, remote, from, to string) {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "FRESHEN_HEAD="):
			head = strings.TrimPrefix(line, "FRESHEN_HEAD=")
		case strings.HasPrefix(line, "FRESHEN_REMOTE="):
			remote = strings.TrimPrefix(line, "FRESHEN_REMOTE=")
		case strings.HasPrefix(line, "FRESHEN_FROM="):
			from = strings.TrimPrefix(line, "FRESHEN_FROM=")
		case strings.HasPrefix(line, "FRESHEN_TO="):
			to = strings.TrimPrefix(line, "FRESHEN_TO=")
		}
	}
	return head, remote, from, to
}

// updatingCaption renders the in-flight rebuild caption. With both versions known
// it is the honest delta ("Updating Barkpark v0.42 → v0.45…"); when a box has no
// tags (`git describe` → "unknown") it falls back to a version-less line rather
// than narrate "unknown".
func updatingCaption(from, to string) string {
	if knownVer(from) && knownVer(to) {
		return fmt.Sprintf("Updating Barkpark %s → %s…", from, to)
	}
	return "Updating Barkpark to the latest release…"
}

// updatedCaption is the terminal caption after a successful rebuild.
func updatedCaption(from, to string) string {
	if knownVer(to) {
		return fmt.Sprintf("Updated Barkpark to %s", to)
	}
	return "Updated Barkpark to the latest release"
}

// knownVer reports whether a `git describe` value is a usable version string (not
// empty and not the "unknown" sentinel a tag-less checkout yields).
func knownVer(v string) bool {
	v = strings.TrimSpace(v)
	return v != "" && v != "unknown"
}

// freshenErrOutputMax bounds how much captured box output a wrapped freshen error
// carries. A failed deploy-rebuild is a full `mix deps.compile`'s worth of output
// (potentially hundreds of KB) — the TAIL is where the actual failure lives, and
// an unbounded error string bloats the worker journal / reconcile error joins.
const freshenErrOutputMax = 2048

// tailOf returns the last max bytes of s (whitespace-trimmed), prefixing "… " when
// truncated so a reader knows output was elided.
func tailOf(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) <= max {
		return s
	}
	return "… " + s[len(s)-max:]
}
