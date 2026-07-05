package cloud

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// narration records (status, detail) freshen transitions for assertions.
type narration struct {
	entries []struct{ status, detail string }
}

func (n *narration) narrate(status, detail string) {
	n.entries = append(n.entries, struct{ status, detail string }{status, detail})
}

func (n *narration) detailFor(status string) string {
	last := ""
	for _, e := range n.entries {
		if e.status == status {
			last = e.detail
		}
	}
	return last
}

func (n *narration) has(status, substr string) bool {
	for _, e := range n.entries {
		if e.status == status && strings.Contains(e.detail, substr) {
			return true
		}
	}
	return false
}

// bareRunner is a StepRunner WITHOUT the hostCommandRunner capture capability —
// used to prove EnsureFresh degrades to a safe no-op skip rather than panicking.
type bareRunner struct{}

func (bareRunner) Run(context.Context, CaddyStep) error { return nil }

// ── EnsureFresh unit tests ──

func TestEnsureFresh_CurrentNoRebuild(t *testing.T) {
	r := &recordingRunner{} // zero value → current (HEAD == origin/main)
	var n narration

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{Narrate: n.narrate})
	if err != nil {
		t.Fatalf("EnsureFresh (current): unexpected error: %v", err)
	}
	if !res.Checked || res.Behind || res.Rebuilt {
		t.Errorf("current box: got %+v, want Checked && !Behind && !Rebuilt", res)
	}
	if r.rebuildRan {
		t.Error("a current box must NOT rebuild")
	}
	// Freshen is a fallback: a current box narrates NOTHING, so the /new timeline
	// never advertises an "Updating…" phase that did no work.
	if len(n.entries) != 0 {
		t.Errorf("a current box must narrate nothing; got %+v", n.entries)
	}
}

func TestEnsureFresh_BehindRebuilds(t *testing.T) {
	r := &recordingRunner{behind: true}
	var n narration

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{Narrate: n.narrate})
	if err != nil {
		t.Fatalf("EnsureFresh (behind): unexpected error: %v", err)
	}
	if !res.Behind || !res.Rebuilt {
		t.Errorf("behind box: got %+v, want Behind && Rebuilt", res)
	}
	if !r.rebuildRan {
		t.Error("a behind box MUST run the rebuild")
	}
	// The version delta is narrated from git describe (v0.42 → v0.45).
	if !n.has("progress", "Updating Barkpark v0.42 → v0.45") {
		t.Errorf("no version-delta narration; got %+v", n.entries)
	}
}

func TestEnsureFresh_CheckFailureDegrades(t *testing.T) {
	r := &recordingRunner{checkErr: errors.New("could not resolve github.com")}
	var n narration

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{Narrate: n.narrate})
	if err == nil {
		t.Fatal("EnsureFresh must return an error on a failed cheap check (the caller decides policy)")
	}
	if !res.Degraded || res.Rebuilt {
		t.Errorf("check failure: got %+v, want Degraded && !Rebuilt", res)
	}
	if r.rebuildRan {
		t.Error("a failed cheap check must NOT attempt a rebuild")
	}
	// Degrade is narrated as `done` (never `failed` — the box works, just unchecked).
	if !n.has("done", freshenCheckFailedCaption) {
		t.Errorf("no degrade narration; got %+v", n.entries)
	}
	for _, e := range n.entries {
		if e.status == "failed" {
			t.Errorf("freshen must never narrate a `failed` status; got %+v", n.entries)
		}
	}
}

func TestEnsureFresh_RebuildFailureDegrades(t *testing.T) {
	r := &recordingRunner{behind: true, rebuildErr: errors.New("mix compile failed")}
	var n narration

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{
		Narrate:        n.narrate,
		RebuildTimeout: time.Minute,
	})
	if err == nil {
		t.Fatal("EnsureFresh must return an error on a failed rebuild")
	}
	if !res.Behind || res.Rebuilt || !res.Degraded {
		t.Errorf("rebuild failure: got %+v, want Behind && !Rebuilt && Degraded", res)
	}
	if !r.rebuildRan {
		t.Error("the rebuild was attempted (and failed) — rebuildRan should be true")
	}
	if !n.has("done", freshenRebuildFailedCaption) {
		t.Errorf("no rebuild-degrade narration; got %+v", n.entries)
	}
	for _, e := range n.entries {
		if e.status == "failed" {
			t.Errorf("freshen must never narrate a `failed` status; got %+v", n.entries)
		}
	}
}

// ── Path-aware skip: box-irrelevant drift fast-forwards instead of rebuilding ──

func TestBoxIrrelevantPaths(t *testing.T) {
	cases := []struct {
		name  string
		paths []string
		want  bool
	}{
		{"docs+cloud+web+js+ci+md", []string{"docs/api-v1.md", "cloud/priv/static/app.js", "web/app/page.tsx", "js/sdk/src/index.ts", ".github/workflows/ci.yml", "README.md", "api/CLAUDE.md"}, true},
		{"api elixir", []string{"docs/x.md", "api/lib/barkpark/content.ex"}, false},
		{"go module", []string{"internal/cli/cloud/freshen.go"}, false},
		{"scripts", []string{"scripts/deploy-rebuild.sh"}, false},
		{"root config", []string{"Makefile"}, false},
		{"empty diff", []string{}, false},
		{"blank lines only", []string{"", "  "}, false},
	}
	for _, c := range cases {
		if got := boxIrrelevantPaths(c.paths); got != c.want {
			t.Errorf("%s: boxIrrelevantPaths(%v) = %v, want %v", c.name, c.paths, got, c.want)
		}
	}
}

func TestEnsureFresh_IrrelevantDriftFastForwards(t *testing.T) {
	r := &recordingRunner{behind: true, diffOut: "docs/ops/PROD_OPS.md\ncloud/priv/static/app.js\nREADME.md\n"}
	var n narration

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{Narrate: n.narrate})
	if err != nil {
		t.Fatalf("EnsureFresh (irrelevant drift): unexpected error: %v", err)
	}
	if !res.Behind || !res.FastForwarded || res.Rebuilt || res.Degraded {
		t.Errorf("want Behind && FastForwarded && !Rebuilt && !Degraded, got %+v", res)
	}
	if !r.ffRan {
		t.Error("the bare fast-forward must run")
	}
	if r.rebuildRan {
		t.Error("a box-irrelevant drift must NOT rebuild")
	}
	// Silent: the box's served behavior was already current — nothing to narrate,
	// so the /new timeline never shows an "Updating…" step for a docs commit.
	if len(n.entries) != 0 {
		t.Errorf("irrelevant drift must narrate nothing; got %+v", n.entries)
	}
}

func TestEnsureFresh_RelevantDriftStillRebuilds(t *testing.T) {
	r := &recordingRunner{behind: true, diffOut: "docs/x.md\napi/lib/barkpark/content.ex\n"}
	var n narration

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{Narrate: n.narrate})
	if err != nil {
		t.Fatalf("EnsureFresh (relevant drift): unexpected error: %v", err)
	}
	if !res.Behind || !res.Rebuilt || res.FastForwarded {
		t.Errorf("want Behind && Rebuilt && !FastForwarded, got %+v", res)
	}
	if r.ffRan {
		t.Error("a relevant drift must not take the bare fast-forward path")
	}
	if !n.has("progress", "Updating Barkpark") {
		t.Errorf("a real update must narrate; got %+v", n.entries)
	}
}

// TestEnsureFresh_FFFailureFallsThroughToRebuild pins the pure-fast-path
// contract: a refused fast-forward (diverged snapshot) is NOT a new failure
// mode — the chain falls through to the full rebuild exactly as if the skip
// didn't exist.
func TestEnsureFresh_FFFailureFallsThroughToRebuild(t *testing.T) {
	r := &recordingRunner{behind: true, diffOut: "docs/only.md\n", ffErr: errors.New("fatal: not possible to fast-forward")}

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{})
	if err != nil {
		t.Fatalf("EnsureFresh (ff refused): unexpected error: %v", err)
	}
	if !res.Rebuilt || res.FastForwarded {
		t.Errorf("a refused ff must fall through to the rebuild, got %+v", res)
	}
	if !r.rebuildRan {
		t.Error("the rebuild must run after a refused fast-forward")
	}
}

// TestEnsureFresh_DiffFailureFallsThroughToRebuild: same for a failed diff —
// when irrelevance can't be proven, rebuild.
func TestEnsureFresh_DiffFailureFallsThroughToRebuild(t *testing.T) {
	r := &recordingRunner{behind: true, diffErr: errors.New("git died")}

	res, err := EnsureFresh(context.Background(), r, FreshenOpts{})
	if err != nil {
		t.Fatalf("EnsureFresh (diff failed): unexpected error: %v", err)
	}
	if !res.Rebuilt || res.FastForwarded {
		t.Errorf("a failed diff must fall through to the rebuild, got %+v", res)
	}
}

// TestEnsureFresh_RebuildBoundedOnBox proves the rebuild budget is enforced ON THE
// BOX (remote coreutils `timeout`), not just by the local sub-context — otherwise a
// local timeout kills the ssh client while the remote deploy-rebuild.sh runs on to
// swap+restart underneath the already-proceeding go-live chain.
func TestEnsureFresh_RebuildBoundedOnBox(t *testing.T) {
	r := &recordingRunner{behind: true}
	if _, err := EnsureFresh(context.Background(), r, FreshenOpts{RebuildTimeout: 12 * time.Minute}); err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if len(r.outScripts) != 3 {
		t.Fatalf("want check + diff + rebuild scripts, got %d: %v", len(r.outScripts), r.outScripts)
	}
	if want := "timeout 720 bash scripts/deploy-rebuild.sh"; !strings.Contains(r.outScripts[2], want) {
		t.Errorf("rebuild script must bound deploy-rebuild.sh remotely with %q; got:\n%s", want, r.outScripts[2])
	}
}

// TestEnsureFresh_NoRemoteTimeoutWithoutBudget proves the warm-create shape (no
// RebuildTimeout — the whole call is bounded by the caller, and a timed-out box is
// torn down anyway) does NOT wrap the rebuild in a remote `timeout`.
func TestEnsureFresh_NoRemoteTimeoutWithoutBudget(t *testing.T) {
	r := &recordingRunner{behind: true}
	if _, err := EnsureFresh(context.Background(), r, FreshenOpts{}); err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if len(r.outScripts) != 3 {
		t.Fatalf("want check + diff + rebuild scripts, got %d: %v", len(r.outScripts), r.outScripts)
	}
	if strings.Contains(r.outScripts[2], "timeout ") {
		t.Errorf("no remote timeout expected without a budget; got:\n%s", r.outScripts[2])
	}
	if !strings.Contains(r.outScripts[2], "bash scripts/deploy-rebuild.sh") {
		t.Errorf("rebuild script must still invoke deploy-rebuild.sh; got:\n%s", r.outScripts[2])
	}
}

// TestTailOf pins the error-output bound: the TAIL survives (that is where a build
// failure lives), an elision marker is prepended, and short output passes through.
func TestTailOf(t *testing.T) {
	if got := tailOf("  short  ", 100); got != "short" {
		t.Errorf("short output must pass through trimmed, got %q", got)
	}
	long := strings.Repeat("x", 5000) + "THE-REAL-ERROR"
	got := tailOf(long, 100)
	if !strings.HasPrefix(got, "… ") || !strings.HasSuffix(got, "THE-REAL-ERROR") || len(got) > 110 {
		t.Errorf("tail must be bounded, marked, and keep the end; got %q (len %d)", got, len(got))
	}
}

func TestEnsureFresh_SkipWhenNoCapture(t *testing.T) {
	res, err := EnsureFresh(context.Background(), bareRunner{}, FreshenOpts{})
	if err != nil {
		t.Fatalf("a runner without capture must be a safe no-op, got error: %v", err)
	}
	if !res.Skipped {
		t.Errorf("want Skipped=true for a non-capturing runner, got %+v", res)
	}
}

// ── configureHost integration (via Provision) ──

// TestProvision_FreshenRunsBeforeMigrate proves the freshen step (dwb-17) runs at
// the TOP of the shared go-live chain — BEFORE migrate — so migrations always run
// against the code that will serve.
func TestProvision_FreshenRunsBeforeMigrate(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, _ := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	var n narration
	wp.Progress = func(step, status, detail string) {
		if step == "freshen" {
			n.narrate(status, detail)
		}
	}
	ctx := context.Background()

	if _, err := wp.Provision(ctx, spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	checkAt := runner.eventIndex("out:freshen-check")
	migrateAt := runner.eventIndex("ecto.migrate")
	if checkAt < 0 {
		t.Fatalf("freshen cheap-check never ran; events=%v", runner.events)
	}
	if migrateAt < 0 {
		t.Fatalf("migrate step never ran; events=%v", runner.events)
	}
	if checkAt >= migrateAt {
		t.Errorf("freshen (idx %d) must run BEFORE migrate (idx %d); events=%v", checkAt, migrateAt, runner.events)
	}
	// A current box never rebuilds — and narrates nothing (freshen is a fallback
	// step; the timeline only shows it when it actually intervenes).
	if runner.rebuildRan {
		t.Error("a current box rebuilt during the in-chain freshen")
	}
	if len(n.entries) != 0 {
		t.Errorf("a current box must narrate no freshen step; got %+v", n.entries)
	}
}

// TestProvision_FreshenBehindRebuildsAndNarrates proves a behind box rebuilds
// in-chain and narrates the version delta.
func TestProvision_FreshenBehindRebuildsAndNarrates(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	runner.behind = true
	var n narration
	wp.Progress = func(step, status, detail string) {
		if step == "freshen" {
			n.narrate(status, detail)
		}
	}

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if !runner.rebuildRan {
		t.Error("a behind box must rebuild in-chain")
	}
	if !n.has("progress", "Updating Barkpark") {
		t.Errorf("no update narration; got %+v", n.entries)
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Error("box was not registered after a successful in-chain freshen+rebuild")
	}
}

// TestProvision_FreshenRebuildFailureStillRegisters proves the in-chain freshen is
// FAIL-OPEN: a failed rebuild degrades to the baked box (build-aside guarantee) and
// the go-live still completes + registers — never a dead go-live.
func TestProvision_FreshenRebuildFailureStillRegisters(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	runner.behind = true
	runner.rebuildErr = errors.New("deploy-rebuild.sh: build failed")

	live, err := wp.Provision(context.Background(), spec)
	if err != nil {
		t.Fatalf("in-chain freshen must FAIL-OPEN on a rebuild failure, but Provision errored: %v", err)
	}
	if !runner.rebuildRan {
		t.Error("the rebuild was supposed to be attempted (and fail)")
	}
	if live.FQDN != "acme.barkpark.cloud" || !reg.Has("acme.barkpark.cloud") {
		t.Errorf("a degraded (baked-code) box must still go live + register; got live=%+v", live)
	}
}

// TestProvision_FreshenCheckFailureStillRegisters proves an unreachable fetch never
// bricks a go-live — it proceeds on the baked release.
func TestProvision_FreshenCheckFailureStillRegisters(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	runner.checkErr = errors.New("git fetch: network unreachable")

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("a failed freshen check must not fail the go-live: %v", err)
	}
	if runner.rebuildRan {
		t.Error("a failed cheap check must not trigger a rebuild")
	}
	if !reg.Has("acme.barkpark.cloud") {
		t.Error("box was not registered after a degraded (unreachable-fetch) freshen")
	}
}
