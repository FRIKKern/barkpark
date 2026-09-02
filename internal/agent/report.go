// Package agent is the barkpark-agent: a transparent on-box Go binary that runs
// on each managed server, reports health/status to the control plane, and runs
// APPROVED commands pulled from a poll-based queue. It is deliberately small —
// report + poll + a fixed 6-command allowlist — and entirely injectable so the
// whole cycle is exercised against an httptest fake control plane with no live
// server. The agent is a plain binary plus a systemd unit; `bp agent
// disable/uninstall` (cloud-11) act on it, and it keeps NO hidden persistence.
package agent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// Version is the agent's own build version, reported verbatim in every Report.
// Stamped here (overridable at build time via -ldflags) rather than read from
// the server so the report tells the truth about THIS binary.
const Version = "0.1.0"

// agentVersion is the build stamp of the agent binary ITSELF — what produced
// THIS beat, as opposed to the hand-maintained Version const above, which only
// says what the source tree called itself when a human last edited it and so
// cannot distinguish two boxes running binaries months apart.
//
// It is a var, not a const, so a blessed release can inject it:
//
//	go build -ldflags "-X github.com/FRIKKern/barkpark/internal/agent.agentVersion=v0.2.26" ./cmd/barkpark-agent
//
// It is EMPTY here on purpose. The fleet's agent is (re)built on-box by
// scripts/apply-update.sh and scripts/deploy-rebuild.sh with a plain
// `go build`, which injects no -X — but which DOES embed the checkout's
// vcs.revision in the module build info. AgentVersion falls back to that, so an
// un-stamped, self-updating box still dates its own beat.
var agentVersion = ""

// AgentVersionUnknown is the explicit marker AgentVersion returns when the
// binary carries no build stamp at all. It is the string-side twin of the -1
// sentinel the numeric vitals use (see ReqPerS/P95Ms below): a value that
// plainly reads "we could not determine this", never a value a consumer could
// mistake for a determination.
//
// The agent_version key is ALWAYS emitted and NEVER emitted as "": an absent
// key and an empty string each mean two incompatible things at once ("old
// binary that predates the field" vs "new binary that could not tell"), and
// that ambiguity is exactly the silence this field exists to break.
const AgentVersionUnknown = "unknown"

// AgentVersion is the running agent binary's own version stamp, resolved once
// per call from the binary itself: the -X-injected agentVersion if a release
// build set one, else the VCS revision Go embeds in the build info, else the
// explicit AgentVersionUnknown marker. It never returns an empty string.
func AgentVersion() string {
	return resolveAgentVersion(agentVersion, debug.ReadBuildInfo)
}

// resolveAgentVersion is AgentVersion's pure core, with both of its inputs
// injected so BOTH arms — stamped and unstamped — are provable in a test
// (a test binary's own build info is not a stable stand-in for either).
func resolveAgentVersion(injected string, readBuildInfo func() (*debug.BuildInfo, bool)) string {
	if v := strings.TrimSpace(injected); v != "" {
		return v
	}
	if readBuildInfo == nil {
		return AgentVersionUnknown
	}
	info, ok := readBuildInfo()
	if !ok || info == nil {
		return AgentVersionUnknown
	}
	var revision, modified string
	for _, s := range info.Settings {
		switch s.Key {
		case "vcs.revision":
			revision = s.Value
		case "vcs.modified":
			modified = s.Value
		}
	}
	if rev := strings.TrimSpace(revision); rev != "" {
		if len(rev) > 12 {
			rev = rev[:12]
		}
		// A dirty tree is carried, not hidden: a box beating a binary built
		// from uncommitted code is a deploy-hygiene fact, same as DirtyTree.
		if modified == "true" {
			rev += "-dirty"
		}
		return "git-" + rev
	}
	// A tagged module build (`go install …@v0.2.26`) carries no vcs settings but
	// does carry a main-module version. "(devel)" is Go's placeholder for
	// "nothing to say" and is not a stamp.
	if v := strings.TrimSpace(info.Main.Version); v != "" && v != "(devel)" {
		return v
	}
	return AgentVersionUnknown
}

// BackupState is the beat's three-valued-and-then-some backup verdict: the one
// field on the wire that can tell "nobody ever looked" from "we looked and the
// backup is not there". It exists because `backup_ok bool` cannot — a plain
// bool has one false and this measurement has four ways to not be "ok", and the
// only discriminator the beat ever carried was a free-text detail string no
// consumer is allowed to parse.
type BackupState string

// The WHOLE set of BackupState values. A consumer may switch on these
// exhaustively; anything else on the wire is a producer newer than the reader
// and must be treated as unknown, never as a backup fact.
const (
	// BackupStateUnmeasured — no BackupProbe was wired into this agent, so
	// nobody looked. This is the state every beat in the fleet carried as a
	// bare `false` before this field existed. It is NOT a statement about
	// backups; a surface that words it as "no backup" is inventing a
	// measurement.
	BackupStateUnmeasured BackupState = "unmeasured"
	// BackupStateUnconfigured — the probe RAN and this box has no backup
	// location at all. Distinct from failed on purpose: "you never set backups
	// up" and "your backups are broken" are different sentences with different
	// next actions, and only the probe can tell them apart.
	BackupStateUnconfigured BackupState = "unconfigured"
	// BackupStateOK — measured: a backup artifact is present and fresh.
	BackupStateOK BackupState = "ok"
	// BackupStateFailed — measured: the backup location exists and a fresh
	// backup does not. This, and only this, is the state a surface may render
	// as "the backup failed".
	BackupStateFailed BackupState = "failed"
	// BackupStateError — the probe itself failed (timeout, unreadable dir).
	// The box's backup state is UNKNOWN; this is a fact about the instrument.
	BackupStateError BackupState = "error"
)

// Valid reports whether s is one of the five states above. GatherReport uses it
// to refuse a probe's answer it cannot render, so an out-of-set string lands as
// BackupStateError with its value quoted rather than travelling to a console
// that will switch on it and fall through to a default nobody designed.
func (s BackupState) Valid() bool {
	switch s {
	case BackupStateUnmeasured, BackupStateUnconfigured, BackupStateOK, BackupStateFailed, BackupStateError:
		return true
	}
	return false
}

// Measured reports whether s is a statement about BACKUPS (ok / failed) rather
// than about the MEASUREMENT (unmeasured / unconfigured / error). It is the
// predicate a renderer wants: only when it is true has anything been observed
// about this box's backups at all.
func (s BackupState) Measured() bool {
	return s == BackupStateOK || s == BackupStateFailed
}

// Report is the payload the agent POSTs to /v1/agent/report. It is the honest
// superset of the cloud-9 registry's health columns
// (health_status/version/git_commit/agent_status/last_seen_at) plus the
// health-gate signals the registry stores as events (disk, PG size, backup,
// TLS/domain, websocket). Field-by-field JSON so the control plane can land it
// straight into upsert_health + record_event.
type Report struct {
	// AgentStatus is always "online" in a report — the agent only reports when
	// it is running. The registry flips a Barkpark to "offline" on staleness.
	AgentStatus string `json:"agent_status"`
	// Version is the agent binary version (Version const above).
	Version string `json:"version"`
	// AgentVersion dates the PRODUCER of this beat — which agent binary emitted
	// it — from the binary's own build stamp (see AgentVersion above), not from
	// a constant a human maintains.
	//
	// It exists because the fleet is split by binary age and nothing reported
	// it: a vital added to the agent (cpu_cores, load15, swap_used_percent)
	// lands only on boxes whose binary has been rebuilt since, and on every
	// other box the key is simply absent — which, from the payload alone, is
	// INDISTINGUISHABLE from a healthy box that measured fine. A fence that
	// divides by an absent cpu_cores is uncomputable, and uncomputable read as
	// silence is how a sick box passes. The only other route to the producer's
	// identity was the binary's mtime over SSH, and SSH host keys change.
	//
	// The control plane needs no change to read it: the beat payload is stored
	// as raw jsonb, so `select payload->>'agent_version'` works the moment a box
	// ships a binary carrying this field. Until every box does, an absent key is
	// itself the answer — that box predates the field.
	AgentVersion string `json:"agent_version"`
	// GitCommit is `git rev-parse HEAD` in the checkout (the deployed code's
	// commit). Empty + DirtyTree=false when the probe could not read it.
	GitCommit string `json:"git_commit"`
	// DirtyTree is true when `git status --porcelain --untracked-files=no` is
	// non-empty — the deployed checkout has uncommitted changes to TRACKED
	// files (a deploy-hygiene red flag).
	//
	// The `--untracked-files=no` flag is load-bearing, not a tidy-up: without
	// it, every working production box is dirty FOREVER. Boxes accrue untracked
	// operational junk (built binaries, worktrees, .env backups, spawned site
	// dirs) that no deploy can clear, so the gauge would be pinned true and
	// could never report the good state — a light that is always on says
	// nothing. Do not re-add untracked counting.
	DirtyTree bool `json:"dirty_tree"`

	// HealthStatus rolls the health-gate up to the registry's enum
	// (up/down/unknown): "up" iff the gate's OK is true, "down" when the gate
	// ran and a check FAILED, "unknown" when no gate probe was wired
	// (test/offline).
	//
	// A check the gate SKIPPED does not move this field in either direction —
	// it is not evidence. That is deliberate and load-bearing: when an unwired
	// optional stub counted as a failure, every online instance in the fleet
	// reported "down" and the dashboard stopped being read
	// (azh-agent-healthgate-down-finding). The skips still ride in Health, per
	// check, with status "skip", so the control plane can count what was NOT
	// checked apart from what passed instead of inferring it from this enum.
	HealthStatus string `json:"health_status"`

	// DiskUsedPercent is the root-filesystem usage from the injected disk probe
	// (statfs/df). -1 when the probe was not wired or failed.
	DiskUsedPercent int `json:"disk_used_percent"`
	// PGSizeBytes is the Postgres database size from the injected probe. -1 when
	// not wired/failed.
	PGSizeBytes int64 `json:"pg_size_bytes"`
	// PGTopRelations names the biggest consumers inside that total (top 10 by
	// pg_total_relation_size). nil — a JSON null, never an empty list — when the
	// probe was not wired or failed: "we did not measure" is a different fact
	// from "we measured and the database has no relations".
	PGTopRelations []RelationSize `json:"pg_top_relations"`

	// Vitals — the host's live resource pressure, gathered every beat behind the
	// same injectable-probe seam as disk (Linux /proc readers in production).
	// Each carries a -1 sentinel when its probe was not wired or failed, so a
	// partial box still phones home the rest and the control plane renders a null
	// point (nil-not-zero) rather than a fake reading.
	//
	// CPUUsedPercent is host CPU busy percent (0..100). -1 when not wired/failed.
	CPUUsedPercent int `json:"cpu_percent"`
	// MemUsedPercent is used-memory percent (0..100). -1 when not wired/failed.
	MemUsedPercent int `json:"mem_used_percent"`
	// Load1 is the 1-minute load average. -1 when the probe was not wired/failed.
	Load1 float64 `json:"load1"`
	// Load15 is the 15-minute load average — the SUSTAIN signal (charter D67),
	// carrying the same -1 unmeasured sentinel as Load1 and landing from the same
	// single read of /proc/loadavg (fields[2], which the probe already had in
	// memory and threw away).
	//
	// It exists because the sustain rule D52 asked for is not computable
	// downstream: /v1/barkparks serves ONE beat (a DISTINCT ON … ORDER BY
	// inserted_at DESC), so no consumer of the payload the console and
	// `bp cloud status` read can see a window at all. A 15-minute kernel EWMA is
	// a sustained measurement delivered as a scalar, which is why it needs no
	// window and no client state. Live: a box read load1 0.64/core — dark on any
	// single-beat fence — while its load15 read 1.89/core in the same sample.
	//
	// Load1 is kept, not replaced: it is the present-tense colour in the reason
	// string, while Load15 is what the fence is evaluated on.
	Load15 float64 `json:"load15"`

	// CPUCores is the box's usable core count (runtime.NumCPU()). It is the
	// DENOMINATOR the strained fence needs: sustained load-per-core, not a raw
	// load number. It carries no sentinel and needs none — NumCPU always answers
	// on every platform the agent builds for, so this field is always measured.
	//
	// There is deliberately NO hardcoded core-count fallback anywhere (charter
	// D52). A constant like `load1 >= 4.0` is numerically identical to
	// "2 cores × 2.0" only because every box in the fleet happens to be 2-core
	// today; it goes silently wrong on the first 4-core box, and silently wrong
	// is the failure this whole slice exists to remove.
	CPUCores int `json:"cpu_cores"`

	// SwapUsedPercent is swap consumption (0..100) and SwapTotalBytes is the
	// configured swap size. They travel as a PAIR because a bare percent cannot
	// carry three distinct states: (0, 0) is a swapless box — measured, and the
	// answer is none; (0, >0) is configured-but-idle; (-1, -1) is "could not
	// measure". The control-plane normalizer passes numbers through verbatim and
	// defers interpretation to the view, so the disambiguating total must travel
	// WITH the percent or the consumer cannot tell those apart.
	//
	// This is the vital the shipped mem_used_percent hides: MemAvailable clears
	// the floor precisely BECAUSE the BEAM has been paged out, so a box at 99.9%
	// swap can report a comfortable 58% memory.
	SwapUsedPercent int   `json:"swap_used_percent"`
	SwapTotalBytes  int64 `json:"swap_total_bytes"`

	// BeamPSSBytes and BeamSwapBytes are the BEAM's OWN footprint (Pss + Swap
	// from /proc/<beam pid>/smaps_rollup) — the single largest consumer on a
	// Barkpark box and the process the kernel OOM-kills. Both -1 when the probe
	// was not wired, no beam.smp was found, or the rollup was unreadable.
	BeamPSSBytes  int64 `json:"beam_pss_bytes"`
	BeamSwapBytes int64 `json:"beam_swap_bytes"`

	// BeamPID and BeamSlot ATTRIBUTE the two numbers above to the process they
	// were actually read from. The box runs blue/green, so during a cutover two
	// beam.smp processes coexist — 8m30s of overlap was observed on 2026-08-22 —
	// and without attribution a consumer cannot tell a real footprint change
	// from the probe silently switching subject. A beam_swap series stepping
	// 0 → ~190 MB across a flip is TWO PROCESSES, not a leak. Empty when the
	// probe was not wired or no beam.smp was found; BeamSlot is additionally
	// empty on a box whose cgroups carry no barkpark-slot@ unit, which is
	// "not attributable", never a guess.
	BeamPID  string `json:"beam_pid"`
	BeamSlot string `json:"beam_slot"`

	// ReqPerS is the instance's recent requests-per-second, read from the
	// instance RequestStats route over the SAME base+token seam as the health
	// gate. -1 when the probe was not wired, failed, or the instance is old and
	// lacks the route (a 404 degrades silently — version-skew honesty, D48/D51).
	ReqPerS float64 `json:"req_per_s"`
	// P95Ms is the instance's p95 request latency in milliseconds. -1 when the
	// probe was not wired/failed, OR when the instance reported p95 null (no
	// samples in the window yet) — the CP renders that unmetered, never a fake 0.
	P95Ms int `json:"p95_ms"`
	// Err5xxPerS is the instance's recent 5xx responses per second, read off the
	// SAME request-stats envelope as ReqPerS/P95Ms — the existing 60s ring, now
	// keeping the response status it was already handed and discarding (D75). -1
	// when the probe was not wired, failed, the instance predates the key, OR the
	// instance reported it null (an empty window). Zero 5xx and "no samples yet"
	// are different facts, and only one of them is good news.
	//
	// HONEST BOUND, and it must travel with the number: the ring is 60s and
	// PER-SLOT. It dies on every blue/green flip and reads an empty window for
	// the first minute after boot, so it answers "is this box answering 5xx RIGHT
	// NOW" and can never produce a cumulative count. It is also blind to 5xx the
	// BEAM never served — a Caddy 502/504 while the VM is unresponsive, which is
	// exactly the total-outage case — so a 0 here is not proof the box is
	// answering.
	Err5xxPerS float64 `json:"err_5xx_per_s"`

	// WindowS is the width, in seconds, of the ring the three numbers above
	// were measured over — the instance emits `window_s` on every request-stats
	// response (api request_stats.ex), and until dr-w14-bl the agent decoded
	// the three rates and DISCARDED their window at the door: three bare
	// numbers riding the beat with no denominator-of-time, this epic's
	// signature defect. -1 when the probe was not wired, failed, or the
	// instance predates the key (absent/null) — a rate whose window is unknown
	// says so, it never borrows the documented default.
	WindowS int `json:"window_s"`

	// Runaways names the box's LONG-RUNNING ORPHANED PROCESSES — the vital the
	// 2026-08-06 guerrilla incident proved nothing was watching. A `journalctl -u
	// bp-site-build-* --since -14d --no-pager` left behind by a dead SSH session
	// ran 2h46m at 66.3% of a core on a 2-core box; load sat at 6.3 and
	// /api/schemas flapped 200/500/500. It was found by a bp WRITE failing, not by
	// any alert, because every vital above is an AGGREGATE: cpu_percent and load15
	// say a box is busy and can never say WHO, and the operator's next action
	// depends entirely on the who.
	//
	// It rides the EXISTING 60s beat, not a second cadence: the whole complaint is
	// that a human learned about this three hours late, and a slower channel would
	// reproduce that. See RunawayProc for the predicate and its honest limits.
	//
	// nil — a JSON null, never an empty list — when the probe was not wired or
	// failed; a NON-NIL EMPTY list when the box was measured and is quiet. Those
	// are opposite facts and this is the one field where collapsing them would
	// re-enact the incident: "we did not look" rendered as "nothing to see" is
	// precisely the silence of 2026-08-06.
	Runaways []RunawayProc `json:"runaway_procs"`

	// SlotUnits is the state of the box's blue/green SYSTEMD UNITS (and the
	// spawned-site units systemd currently calls failed) — the fact that a
	// `barkpark-slot@blue` sitting in `failed` was known ONLY to ssh, while every
	// operator surface read `ok`. See the SlotUnit block below for the full case
	// and for why Result and ExecMainStatus must travel together.
	//
	// Same nil-vs-empty law as Runaways, and here it matters more, not less: nil
	// (a JSON null) is UNMEASURED — no systemd, no dbus, a timed-out probe — and
	// a NON-NIL EMPTY list is MEASURED and nothing to report. A consumer that
	// rendered "no failed units" off an unwired probe would re-create the exact
	// silence this field exists to break.
	SlotUnits []SlotUnit `json:"slot_units"`
	// SlotUnitsTruncated is how many FAILED SITE units slotUnitsLimit hid, so the
	// short list says it is short (the rule SitesCount already keeps for the
	// per-slug cap). 0 = the list is complete; -1 = the probe never ran, matching
	// the -1 sentinel every unmeasured number on this beat uses. The blue/green
	// pair is never truncated, so this can never hide a slot unit.
	SlotUnitsTruncated int `json:"slot_units_truncated"`

	// BackupState is the DISCRIMINATOR BackupOK cannot be. A plain bool has one
	// false and this field has four distinct realities to report, so for the
	// whole life of the beat `backup_ok:false` meant "no probe was ever wired"
	// (the Go zero value), "the probe ran and the backup is not there", and
	// "the probe itself blew up" — indistinguishable except by reading English
	// out of BackupDetail, which no consumer may parse. A console rendering
	// that false as "No backup" states a measurement that never happened.
	//
	// The five values, and they are the WHOLE set (BackupState*, below):
	//
	//	"unmeasured"   no BackupProbe wired — nobody looked. NOT a backup fact.
	//	"unconfigured" the probe ran; this box has no backup location at all.
	//	"ok"           measured: a fresh backup artifact is present.
	//	"failed"       measured: the location is there and the backup is not.
	//	"error"        the probe itself failed; the box's state is unknown.
	//
	// It is ADDITIVE beside BackupOK, never a replacement: a control plane that
	// predates it keeps reading the same bool it always read, and BackupOK
	// stays exactly `state == "ok"` so the two can never disagree. Only "ok"
	// and "failed" are BACKUP facts; the other three are facts about the
	// MEASUREMENT, and a surface must word them as such.
	BackupState BackupState `json:"backup_state"`
	// BackupOK / BackupDetail come from the injected backup-status probe — is a
	// recent backup present and scheduled? BackupOK is DERIVED from BackupState
	// (true iff "ok") and kept for consumers older than the state field; read
	// BackupState instead, because a false here is three different realities.
	BackupOK     bool   `json:"backup_ok"`
	BackupDetail string `json:"backup_detail"`

	// Health carries the per-check results of the health gate (websocket-not-403
	// / TLS / capabilities / studio / postgres-via-api …) so the control plane
	// can record the granular event stream, not just the roll-up.
	//
	// Each entry carries a three-valued `status` (pass/fail/skip) beside the
	// legacy `pass` bool. Read `status`: a skipped check ships `pass:true` only
	// so an old control plane's roll-up does not move on the day a new agent
	// deploys, and it is NOT a claim that anything was verified.
	Health []setup.CheckResult `json:"health_checks"`
}

// RelationSize is one named consumer of the database total: a relation and the
// bytes it occupies including indexes and TOAST (pg_total_relation_size). A
// named breakdown is what turns "3.2 GiB" into a diagnosis.
type RelationSize struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`
}

// RunawayProc is one long-running orphaned process: the pid, how long it has
// been alive, the CPU share it has averaged over that whole life, and the argv
// that identifies it. The command is what turns a number into an action — an
// operator kills `journalctl -u bp-site-build-*`, never "pid 3369344".
//
// ElapsedS is SECONDS, from `ps -o etimes=`, not the D-HH:MM:SS `etime` column:
// a number needs no format parser and cannot be misread across locales. The
// incident's 02:46:41 is 10001 here.
//
// CPUPercent is `ps -o pcpu=`, which is the process's LIFETIME AVERAGE CPU
// (cputime ÷ elapsed), not an instantaneous sample — and that is why this
// predicate works at all. An idle daemon that has been up for a week averages
// near zero however long it has lived, so elapsed alone cannot separate it from
// a runaway, while a lifetime average over half a core sustained for half an
// hour is a process that has actually spent the machine.
type RunawayProc struct {
	PID        int     `json:"pid"`
	ElapsedS   int     `json:"elapsed_s"`
	CPUPercent float64 `json:"cpu_percent"`
	Command    string  `json:"command"`
}

// The runaway predicate, and its honest bounds.
//
//   - runawayMinElapsedS (30 min): the incident ran 2h46m. Half an hour is far
//     past any legitimate per-beat probe (the longest bound in this file is the
//     60s du) and past a normal `next build`, so a burst cannot trip it.
//   - runawayMinCPUPercent (50): half a core, AVERAGED OVER THE WHOLE LIFE. The
//     incident read 66.3.
//   - runawayTopLimit (3) and runawayCommandLimit (120): this list rides the
//     health beat, which the metrics chart reads back up to 200 payloads at a
//     time, and an unbounded list of full argv strings crosses Postgres's
//     2032-byte TOAST_TUPLE_THRESHOLD the same way the per-slug space payload
//     did (D58). Three rows of a 120-rune command is ~500 B. An operator acts on
//     the worst offender, never on the tenth.
//
// WHAT THIS CANNOT DO, stated here because a detector whose blind spot is not
// written down is trusted past its evidence: PPID 1 is ALSO every systemd
// service's main process, so a genuinely CPU-hungry managed service clears this
// predicate. That is not a bug being tolerated — the payload carries the argv,
// so a human reads `beam.smp` and closes the tab — but it does mean a row here
// is a REPORT, never a verdict, and nothing downstream may treat it as one.
const (
	runawayMinElapsedS   = 1800
	runawayMinCPUPercent = 50.0
	runawayTopLimit      = 3
	runawayCommandLimit  = 120
)

// SpaceEventType is the agent-event type the space payload is posted under. It
// is deliberately NOT "health": the 60s health beat is the series the metrics
// chart reads (cloud/lib/barkpark_cloud/metrics.ex keeps only `type: "health"`
// events), and a per-slug space payload riding it crosses Postgres's 2032-byte
// TOAST_TUPLE_THRESHOLD on the compressed jsonb at 20-25 realistic slugs —
// after which a 14-day window per box goes 34MB→58MB and a 200-point metrics
// read goes 46 buffers/3.8ms → 637 buffers/9.6ms, because the metrics route
// pulls up to 200 payloads per chart. On its own type the row is never
// detoasted by a chart render at all (charter D58).
const SpaceEventType = "space"

// SiteSize is one named consumer of the sites directory: a site slug and the
// bytes its deploy tree occupies. Per-slug is strictly more useful than a
// total, because it names the site an operator would act on.
type SiteSize struct {
	Slug  string `json:"slug"`
	Bytes int64  `json:"bytes"`
}

// SpaceReport is the space payload: WHO is consuming the disk, by name. It
// answers the question "Disk 75%" never could — 75% of what, spent on what.
//
// It is posted on its own path at its own (slow) cadence, NOT folded into
// Report, and carries its intended agent-event type inline so the control-plane
// landing site records it verbatim rather than guessing (D58).
//
// HONEST ABSENCE: every unmeasured number is -1 and every unmeasured list is
// nil (a JSON null), never 0 and never []. "We did not measure" and "we
// measured and it is empty" are different facts, and under-reporting space is
// exactly the failure this payload exists to prevent.
type SpaceReport struct {
	// Type is SpaceEventType, carried in the body so the landing route records
	// the event under the right type without inferring it from the path.
	Type string `json:"type"`

	// RootUsedBytes / RootTotalBytes are the root filesystem's used and total
	// bytes from `df -P -k /`. They travel as a PAIR and never as a bare
	// percent: "75%" cannot tell a 40 GB box needing 10 GB freed from a 400 GB
	// box needing 100 GB, and the operator's next action depends on which it is.
	// Both -1 when the probe was not wired or failed.
	RootUsedBytes  int64 `json:"root_used_bytes"`
	RootTotalBytes int64 `json:"root_total_bytes"`

	// JournalBytes is what the systemd journal occupies, from
	// `journalctl --disk-usage` — a header read (~8ms warm), NOT a tree walk.
	// -1 when not wired/failed.
	JournalBytes int64 `json:"journal_bytes"`

	// PGSizeBytes / PGTopRelations reuse the EXISTING Postgres size probes
	// (pg_database_size + pg_total_relation_size), never a `du` over the data
	// directory: the database knows its own size, and walking PGDATA as root is
	// both slower and wrong (it counts WAL and temp files the operator cannot
	// act on). -1 / nil when not wired/failed.
	PGSizeBytes    int64          `json:"pg_size_bytes"`
	PGTopRelations []RelationSize `json:"pg_top_relations"`

	// SitesDir is the RESOLVED sites root the sites probe actually read — not
	// the configured one. BARKPARK_SITES_DIR is set on no box in the fleet, so
	// an env-read probe silently falls back to the default on every box; the
	// resolved path travels in the payload so a wrong root is visible instead of
	// silent (D59). It is always populated, even when the measurement failed.
	SitesDir string `json:"sites_dir"`
	// SitesBytes is the whole sites tree's size; SitesTop names the biggest
	// slugs inside it, capped at sitesTopLimit by bytes. -1 / nil when the probe
	// was not wired or failed — including a du killed at its deadline, whose
	// PARTIAL output parses as a plausible list that is silently missing half
	// the tree.
	SitesBytes int64      `json:"sites_bytes"`
	SitesTop   []SiteSize `json:"sites_top"`

	// SitesCount is how many slugs the walk actually FOUND, which is the only
	// thing that can tell a reader whether SitesTop is the whole answer or the
	// visible tip of one.
	//
	// A top-N list without its denominator is a cap that never says when it
	// binds: ten slugs and a total read as "these ten ARE the tree" whether the
	// walk found ten or forty, and the operator's next action differs (delete
	// search-ember vs. the tree has grown a shape nobody is watching). The cap
	// itself is not the hazard — reporting a truncated list as a complete one
	// is. With SitesCount a surface renders "top 10 of 37" and the truncation is
	// a stated fact instead of an invisible one.
	//
	// -1 when the probe was not wired or failed, matching every other unmeasured
	// field here — and NEVER 0, which is the measured claim "this tree is
	// empty".
	SitesCount int `json:"sites_count"`

	// ConsumerRoots is the BUILD PLANE's disk, and every other tree the sites
	// axis structurally cannot see.
	//
	// WHY IT EXISTS, measured: on the build-plane box at 91.98.139.58 the root
	// filesystem read 100% full with 285 MB free, and 25 GiB of it sat in
	// /var/lib/containerd (14 GiB) and /var/lib/barkpark-builder (11 GiB).
	// SitesDir there is /opt/barkpark/sites, which DOES NOT EXIST on that box —
	// it runs barkpark-builder.service and barkpark-runtime.service, not the
	// site tree this payload was first written against. So every field above
	// named ~1 GiB of a 34 GiB problem, and the box that most needed the
	// diagnosis was the box the diagnosis could not see.
	//
	// Each entry says WHICH root it is and WHETHER IT WAS READ, because the
	// failure being repaired is a probe pointed at a root that is not there
	// reporting "nothing to see" for "I did not look" — see ConsumerRoot.Status.
	//
	// nil (a JSON null) when no roots were configured at all: an agent that was
	// never told where to look has not measured an empty fleet of roots, it has
	// not measured.
	ConsumerRoots []ConsumerRoot `json:"consumer_roots"`

	// Residual is what this payload did NOT measure, in bytes, against the
	// denominator that produced it — or a stated refusal. See SpaceResidual.
	//
	// nil is an agent that does not compute one at all; a computed zero and a
	// refusal are both non-nil and say so themselves.
	Residual *SpaceResidual `json:"residual"`
}

// The four ConsumerRoot.Status values. They are a CLOSED set and they are
// deliberately four, not two: "we read it", "we read PART of it and can say
// which part we could not", "it is not on this box", and "we tried and failed"
// are four different operator actions (act on the bytes / chmod the named
// subtree or run the agent with the rights to see it / point the probe
// somewhere real / fix the probe), and collapsing any of them is how a wrong
// root became invisible in the first place.
const (
	// ConsumerRootRead — the walk completed. Bytes and Count are real.
	ConsumerRootRead = "read"
	// ConsumerRootDegraded — the walk finished and printed its total, but du
	// could not descend into one or more subtrees and said so. Bytes and Count
	// are REAL AND SHORT, and Degraded names by how much less we saw.
	//
	// It is its own word rather than `read` because the number is a floor, not
	// a size (measured on guerrilla: 212K reported against a true 712K, a 70%
	// shortfall), and rather than `unmeasured` because throwing away a floor we
	// CAN name — and can act on — is the same information loss one layer down.
	ConsumerRootDegraded = "degraded"
	// ConsumerRootAbsent — the path does not exist on this box. This is a
	// MEASUREMENT ("we looked; there is no such directory"), not a failure, and
	// it is the whole point of the field: it is the state that must never
	// render as 0 bytes.
	ConsumerRootAbsent = "absent"
	// ConsumerRootUnmeasured — no probe wired, or the walk errored/timed out.
	// Bytes and Count keep their -1 sentinel.
	ConsumerRootUnmeasured = "unmeasured"
)

// The three SpaceResidual.Status values, a CLOSED set, and the middle one is
// the whole point of the field.
const (
	// ResidualComputed — the subtraction was performed and Bytes is real.
	ResidualComputed = "computed"
	// ResidualUndefined — the measured roots summed to MORE than the root
	// filesystem's used bytes. That is arithmetically impossible for disjoint
	// trees on one device, so it is PROOF that the root set is not what it
	// claims to be, and the only honest output is a refusal.
	//
	// It is its own word rather than a clamp-to-zero because "0 B unaccounted"
	// is the strongest possible claim this axis can make — we saw everything —
	// and reaching it by clamping would let the worst-measured box render as
	// the best-measured one. A negative number is not printed either: a
	// negative gigabyte is a new dishonest number inside the fix for dishonest
	// numbers.
	ResidualUndefined = "undefined"
	// ResidualUnmeasured — the subtraction could not be attempted at all
	// (no root-filesystem denominator, or no way to verify the roots' device).
	// Reason names which.
	ResidualUnmeasured = "unmeasured"
)

// The SpaceResidual.PGSource values. Postgres is the one consumer this payload
// can measure TWICE, and the field says which measurement was used so the
// arithmetic is checkable rather than trusted.
const (
	// PGSourceDURoot — a configured consumer root covers PGDATA, so the du
	// walk already counted those bytes and PGSizeBytes was NOT added.
	PGSourceDURoot = "du-root"
	// PGSourceSizeBytes — no du root covers PGDATA, so PGSizeBytes was added.
	PGSourceSizeBytes = "pg-size-bytes"
	// PGSourceNone — neither: no pg on this box, or the size probe failed.
	PGSourceNone = "none"
)

// SpaceResidual is the answer to the question every part-of-a-whole reading
// begs and almost none of them state: WHAT ABOUT THE REST?
//
// The failure it repairs is not a wrong number, it is a confident subset. The
// shipped probe read one root, /opt/barkpark/sites, which exists on ONE of six
// boxes and covers 14.9% of that one — and it presented that 14.9% with the
// same voice it would have used for the whole disk. Coverage is ANTI-CORRELATED
// with trouble: the same two roots cover 81.66% of the box at 96% disk and
// 34.86% of another, a 47-point spread, so the reading is least complete
// exactly where it is most needed. A probe that sees 28% of a box must SAY 28%.
//
// THE DENOMINATOR IS RootUsedBytes AND NOTHING ELSE. Not disk_used_percent:
// `df`'s capacity column is ceil(used/(used+avail)) and excludes root-reserved
// blocks, so it is a percentage of a DIFFERENT WHOLE — the build-plane box read
// 96% capacity against 91.09% used-of-total, and a residual built from the
// percent INVENTS 1.83 GiB there and 1.35 GiB on another box. The two numbers
// are not the same quantity in different units.
//
// It is a POINTER on SpaceReport: nil is an agent that does not compute a
// residual at all, which is a different fact from an agent that tried and
// refused (ResidualUnmeasured) — the same nil-is-not-zero rule every other
// field here follows.
//
// The shape is DeployLedger.rate/2's refusal node: a value, the denominator
// that produced it, and a machine-readable reason — so no caller can render a
// percentage without the volume behind it, and no caller has to parse prose to
// learn that the number is missing.
type SpaceResidual struct {
	// Status is one of the three constants above. A reader branches on THIS,
	// never on Bytes >= 0.
	Status string `json:"status"`
	// Bytes is RootUsedBytes - MeasuredBytes: the bytes on this box's root
	// filesystem that no configured root accounts for. -1 unless Status is
	// ResidualComputed — and NEVER a negative figure, which is what the
	// ResidualUndefined arm exists to refuse.
	Bytes int64 `json:"bytes"`
	// OfBytes is the denominator, carried beside the value so a surface can
	// render the share without inventing the whole. It is RootUsedBytes
	// verbatim, -1 when that was unmeasured.
	OfBytes int64 `json:"of_bytes"`
	// MeasuredBytes is what was actually subtracted — the sum of the counted
	// extents. It travels even when Status is ResidualUndefined, because a sum
	// that EXCEEDS its denominator is the evidence for the refusal, and an
	// operator who can see both numbers can find the overlapping root in one
	// step instead of guessing.
	MeasuredBytes int64 `json:"measured_bytes"`
	// CountedRoots / ExcludedRoots are how many measured extents went into
	// MeasuredBytes and how many were held out. Their sum is the coverage
	// statement's denominator, and ExcludedRoots > 0 is the reader's cue to
	// look at the per-root excluded_reason for the names.
	CountedRoots  int `json:"counted_roots"`
	ExcludedRoots int `json:"excluded_roots"`
	// PGSource says which of the two Postgres measurements was used, so the
	// arithmetic can be checked rather than trusted. See the PGSource consts:
	// on one box `du -x -k -s /var/lib/postgresql` read 3,615,160 KiB against
	// sum(pg_database_size) 3,528,933 KiB — 97.6% the SAME bytes, 3.37 GiB and
	// 12.5% of that box's used total, countable twice by an axis that has both.
	PGSource string `json:"pg_source"`
	// Reason is machine-readable and empty exactly when Status is
	// ResidualComputed. It is a stable slug, never prose: a surface branches on
	// it and words it for its own reader.
	Reason string `json:"reason"`
}

// The SpaceResidual.Reason slugs and the ConsumerRoot.ExcludedReason slugs.
// Both are stable machine-readable tokens; every human sentence in every
// surface is derived FROM one of these, never parsed back into one.
const (
	// residual reasons
	residualReasonRootUnmeasured   = "root-used-unmeasured"
	residualReasonDeviceUnverified = "root-device-unverified"
	residualReasonOverlap          = "roots-overlap-or-cross-a-mount"
	// per-root exclusion reasons
	excludedCrossMount       = "cross-mount"
	excludedDeviceUnverified = "device-unverified"
	excludedUnderPrefix      = "under:"
)

// ConsumerRoot is one measured (or honestly unmeasured) disk-consumer root.
//
// Bytes and Count carry the SAME -1 sentinel every other number in this payload
// uses, and they carry it for `absent` too. An absent root reporting 0 bytes
// would be the claim "this directory is empty", which is a fact about a
// directory that is not there — the exact confusion Status exists to end.
type ConsumerRoot struct {
	// Path is the root as CONFIGURED, echoed back whether or not it was read,
	// for the same reason SitesDir is: a wrong root has to be visible.
	Path string `json:"path"`
	// Status is one of the three constants above. A reader branches on THIS,
	// never on Bytes >= 0.
	Status string `json:"status"`
	// Bytes is the whole tree's size; Top names its biggest direct children,
	// capped at consumerTopLimit; Count is how many children the walk FOUND, so
	// a capped list can say it is capped (the sites axis's own SitesCount
	// lesson: a cap that eats its denominator can never announce itself).
	// -1 / nil / -1 unless Status is ConsumerRootRead.
	Bytes int64     `json:"bytes"`
	Top   []DirSize `json:"top"`
	Count int       `json:"count"`

	// Degraded NAMES the subtrees du could not descend into, BY PATH — the
	// thing an operator can `ls`, `chmod` or `sudo du`. Never by the daemon or
	// unit that happens to own the tree: "containerd" is not a place, and the
	// path is the only string that is both what we asked for and what the
	// operator's next command takes.
	//
	// Capped at consumerDegradedLimit, with DegradedCount carrying how many the
	// walk actually hit, so a capped list can say it is capped — the same
	// lesson as SitesCount, where a cap that eats its own denominator can never
	// announce itself. nil / -1 unless Status is ConsumerRootDegraded.
	Degraded      []string `json:"degraded"`
	DegradedCount int      `json:"degraded_count"`

	// ExcludedReason names why this root's bytes were NOT summed into
	// SpaceReport.Residual, and it is empty exactly when they were.
	//
	// It lives on the ROW rather than in a list beside the residual because the
	// fact is about this root, and a second list of paths is a second thing to
	// keep in sync (and, at consumerRootsLimit, several hundred bytes of the
	// payload budget spent restating strings already on the wire).
	//
	// A root can be perfectly well MEASURED and still be excluded — the two
	// questions are independent. Status answers "did we read this tree?";
	// ExcludedReason answers "can this tree's bytes be subtracted from the root
	// filesystem's used total without double-counting or crossing a mount?".
	// The overlay case is exactly that: a complete, correct 1.44 GiB reading of
	// a tree that is not on the root filesystem at all.
	ExcludedReason string `json:"excluded_reason"`
}

// DirSize is one named child of a consumer root and the bytes it occupies.
//
// Its JSON keys are `name`/`bytes` — RelationSize's keys, NOT SiteSize's
// `slug` — deliberately: the control plane's row shaper
// (telemetry.ex relation_sizes/1) already accepts both and emits `name`, so
// this rides the landing path that exists instead of minting a second one. A
// containerd snapshotter directory is a name, never a slug.
type DirSize struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`
}

// CommandRunner runs a single resolved argv and returns combined output. It is
// injected so tests use a fake that records calls and NEVER shells out to a real
// systemctl/make. The production runner (ExecRunner) shells out for real.
type CommandRunner interface {
	Run(name string, args ...string) (output string, err error)
}

// ExecRunner is the production CommandRunner: it runs the argv via os/exec.
type ExecRunner struct{}

// execRunnerTimeout bounds every ExecRunner.Run call. A stuck remote command
// (approved but hung — e.g. `make rebuild` wedged on a lock) must never freeze
// the agent forever; it is unexported so report_test.go can lower it to
// exercise the timeout path without a real 5-minute sleep.
var execRunnerTimeout = 5 * time.Minute

// Run executes name+args under a bounded internal deadline and returns
// combined stdout+stderr. The deadline is entirely internal to Run — the
// CommandRunner interface and its call sites (runCommand in commands.go,
// gitProbe.git above) are untouched, so a hung approved command surfaces as an
// honest "timed out after ..." error instead of wedging the agent.
func (ExecRunner) Run(name string, args ...string) (string, error) {
	return runBounded(execRunnerTimeout, nil, name, args...)
}

// runBounded is the one place a shell-out gets its lifetime. EVERY caller picks
// its own deadline: approved queue commands get the generous execRunnerTimeout,
// per-beat probes get a short one (pgProbeTimeout). A probe that can run for
// five minutes is the three-hour runaway again one layer down — the lesson of
// that incident was an unbounded LIFETIME, not an expensive command.
// errProbeTimedOut is the sentinel a caller matches with errors.Is to tell "we
// blew the deadline" from "the command exited non-zero on its own". They are
// different worlds: a killed walk printed a prefix of the tree and is not a
// measurement, while `du` exiting rc=1 because one subdirectory was unreadable
// printed the WHOLE tree and named what it missed. Inferring that difference
// from the output shape alone is how a timeout gets partially landed.
var errProbeTimedOut = errors.New("timed out")

// env is the SECOND thing a shell-out needs from this one place, and it exists
// for exactly one reason: a secret handed to a child in argv is world-readable
// for the child's whole lifetime (/proc/<pid>/cmdline, a plain `ps`), while the
// same secret handed to it in the environment is readable only by the process
// owner. nil means "inherit the agent's own environment" — every probe but the
// Postgres pair passes nil, because they carry no credential at all.
func runBounded(timeout time.Duration, env []string, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env // nil = inherit, which is exec's own default
	out, err := cmd.CombinedOutput()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return string(out), fmt.Errorf("%w after %s: %s %s", errProbeTimedOut, timeout, name, strings.Join(args, " "))
	}
	return string(out), err
}

// gitProbe reads the checkout's commit + dirty flag via an injected
// CommandRunner so report-gathering is testable without a real git tree.
type gitProbe struct {
	runner   CommandRunner
	checkout string // -C <checkout>; empty means "current working dir"
}

// commit returns `git rev-parse HEAD` for the checkout, trimmed. Empty on error.
func (g gitProbe) commit() string {
	out, err := g.git("rev-parse", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// dirty returns true iff `git status --porcelain --untracked-files=no` is
// non-empty — uncommitted changes to TRACKED files. Untracked files are
// deliberately excluded: a live box always carries some (see DirtyTree above),
// so counting them pins the gauge true forever and it can never say clean.
// A probe error reports false — we do not invent dirtiness.
func (g gitProbe) dirty() bool {
	out, err := g.git("status", "--porcelain", "--untracked-files=no")
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) != ""
}

// git runs a git subcommand against the configured checkout (via -C) when set.
func (g gitProbe) git(args ...string) (string, error) {
	if g.checkout != "" {
		args = append([]string{"-C", g.checkout}, args...)
	}
	return g.runner.Run("git", args...)
}

// ReportConfig wires gatherReport's probes. EVERY field that is unknowable in a
// test (git tree, disk, PG size, backup, the live health gate) is behind an
// injected function so tests supply fakes and production supplies the real
// thing. A nil probe func means "skip this signal honestly" (the report field
// gets its zero/unknown value), never a panic.
type ReportConfig struct {
	// Runner backs the git probe (and is the same runner the command queue
	// uses). Required for the git signals; nil leaves GitCommit empty.
	Runner CommandRunner
	// Checkout is the deployed code directory git is read from (-C). Empty reads
	// the agent's current working directory.
	Checkout string

	// DiskProbe returns root-fs used-percent (0..100). nil → DiskUsedPercent=-1.
	DiskProbe func() (int, error)
	// CPUProbe returns host CPU busy-percent (0..100). nil → CPUUsedPercent=-1.
	CPUProbe func() (int, error)
	// MemProbe returns used-memory percent (0..100). nil → MemUsedPercent=-1.
	MemProbe func() (int, error)
	// LoadProbe returns the 1-minute AND 15-minute load averages. nil → BOTH
	// Load1 and Load15 = -1. Fail-soft as ONE unit like SwapProbe: the two come
	// from a single line of /proc/loadavg, so a failed read leaves both sentinels
	// rather than half a measurement.
	LoadProbe func() (load1 float64, load15 float64, err error)
	// ReqStatsProbe returns (req/s, p95 ms, 5xx/s, window s) from the instance
	// RequestStats route. nil → ReqPerS, P95Ms, Err5xxPerS and WindowS all -1.
	// Fail-soft like the other probes: a non-nil error leaves ALL sentinels; a
	// successful read with a null instance-side p95 or err_5xx_per_s lands
	// req/s but keeps that field at -1, and an instance predating `window_s`
	// keeps WindowS at -1 (see NewReqStatsProbe). Wire the production
	// implementation with NewReqStatsProbe(base, token, rootCAs).
	ReqStatsProbe func() (reqPerS float64, p95Ms int, err5xxPerS float64, windowS int, err error)
	// RunawayProbe returns the box's long-running orphaned processes, worst first.
	// nil → Runaways stays nil (UNMEASURED). A successful probe that found none
	// must return a NON-NIL EMPTY slice, and gatherReport normalizes a nil-with-no-
	// error to one, so "measured and quiet" can never arrive as "we did not look".
	// Wire the production implementation with NewRunawayProbe().
	RunawayProbe func() ([]RunawayProc, error)
	// SlotUnitsProbe returns the blue/green (and failed site) unit states plus
	// how many the cap hid. nil → SlotUnits stays nil (UNMEASURED) and
	// SlotUnitsTruncated stays -1; the two land as ONE unit like SwapProbe's
	// pair, because a truncation count without its list says nothing. Wire the
	// production implementation with NewSlotUnitsProbe().
	SlotUnitsProbe func() ([]SlotUnit, int, error)
	// SwapProbe returns (used percent 0..100, total swap bytes). nil → BOTH swap
	// fields keep the -1 sentinel. Gathered fail-soft as ONE unit like
	// ReqStatsProbe, not independently like CPU/Mem: a percent landed against an
	// unknown total is meaningless, so an error leaves both sentinels.
	SwapProbe func() (pct int, totalBytes int64, err error)
	// BeamProbe returns the winning BEAM's (PSS, swap) bytes plus the pid and
	// blue/green slot they were read from. nil or an error → BeamPSSBytes and
	// BeamSwapBytes keep -1 and BeamPID/BeamSlot stay empty; the four are ONE
	// measurement of ONE process and never half-land. On a blue/green box the
	// implementation must sample every comm-anchored beam.smp and report the
	// MAX across the set (pds-w11-paired-control-measure), never the first
	// match in directory order.
	BeamProbe func() (pssBytes int64, swapBytes int64, pid string, slot string, err error)
	// PGSizeProbe returns the Postgres DB size in bytes. nil → PGSizeBytes=-1.
	// Wire the production implementation with NewPGSizeProbe(checkout).
	PGSizeProbe func() (int64, error)
	// PGTopRelationsProbe returns the top relations by total size. nil or an
	// error → PGTopRelations stays nil (unmeasured). It is SEPARATE from
	// PGSizeProbe on purpose: its cost scales with relation count, so a box with
	// thousands of partitions may lose the breakdown while still reporting the
	// cheap total. Wire it with NewPGTopRelationsProbe(checkout).
	PGTopRelationsProbe func() ([]RelationSize, error)
	// BackupProbe returns (state, human-detail). The state is the probe's own
	// verdict, not a bool the caller has to interpret: only the probe can tell
	// "this box has no backup location configured" (BackupStateUnconfigured)
	// from "the location is there and the backup is not" (BackupStateFailed),
	// and collapsing those two into one false is the defect this seam exists to
	// close. nil probe → BackupStateUnmeasured, never a false; a non-nil error
	// → BackupStateError.
	BackupProbe func() (BackupState, string, error)

	// HealthGate is the injected health-gate runner (defaults to
	// setup.RunHealthGate). BaseURL/Token/probe-URLs/RootCAs configure it; when
	// BaseURL is empty the gate is skipped and HealthStatus is "unknown".
	HealthBaseURL    string
	HealthToken      string
	HealthGateOpts   setup.HealthGate
	HealthRootCAs    *x509.CertPool
	runHealthGateFor func(base, token string, opts setup.HealthGate) (setup.HealthReport, error)
}

// gatherReport assembles a Report from the wired probes. It is total: a missing
// or failing probe yields an honest unknown value, never a panic, so a partial
// box still phones home with whatever it can prove.
func gatherReport(cfg ReportConfig) Report {
	r := Report{
		AgentStatus: "online",
		Version:     Version,
		// Always emitted, never "" — AgentVersion falls back to the explicit
		// AgentVersionUnknown marker rather than to silence.
		AgentVersion:    AgentVersion(),
		HealthStatus:    "unknown",
		DiskUsedPercent: -1,
		PGSizeBytes:     -1,
		CPUUsedPercent:  -1,
		MemUsedPercent:  -1,
		Load1:           -1,
		Load15:          -1,
		ReqPerS:         -1,
		WindowS:         -1,
		P95Ms:           -1,
		Err5xxPerS:      -1,
		SwapUsedPercent: -1,
		SwapTotalBytes:  -1,
		BeamPSSBytes:    -1,
		BeamSwapBytes:   -1,
		// -1, not 0: 0 means "the cap hid nothing", which is a MEASUREMENT and
		// would be a lie on a box whose unit probe never ran.
		SlotUnitsTruncated: -1,
		// Always measured, never probed: the fence's denominator (D52).
		CPUCores: runtime.NumCPU(),
	}

	// Git signals (deployed commit + dirty tree).
	if cfg.Runner != nil {
		g := gitProbe{runner: cfg.Runner, checkout: cfg.Checkout}
		r.GitCommit = g.commit()
		r.DirtyTree = g.dirty()
	}

	// Disk.
	if cfg.DiskProbe != nil {
		if pct, err := cfg.DiskProbe(); err == nil {
			r.DiskUsedPercent = pct
		}
	}

	// CPU / memory / load — the per-beat vitals, each independently fail-soft.
	if cfg.CPUProbe != nil {
		if pct, err := cfg.CPUProbe(); err == nil {
			r.CPUUsedPercent = pct
		}
	}
	if cfg.MemProbe != nil {
		if pct, err := cfg.MemProbe(); err == nil {
			r.MemUsedPercent = pct
		}
	}
	// Load — one read of /proc/loadavg, two averages, landed together (D67).
	if cfg.LoadProbe != nil {
		if l1, l15, err := cfg.LoadProbe(); err == nil {
			r.Load1 = l1
			r.Load15 = l15
		}
	}

	// Request stats (req/s + p95 + 5xx/s). Fail-soft as one unit: a probe error
	// leaves all three at the -1 sentinel; a null instance-side p95 or
	// err_5xx_per_s arrives as that field's -1 with a real req/s
	// (NewReqStatsProbe applies that mapping).
	if cfg.ReqStatsProbe != nil {
		if rps, p95, err5xx, windowS, err := cfg.ReqStatsProbe(); err == nil {
			r.ReqPerS = rps
			r.P95Ms = p95
			r.Err5xxPerS = err5xx
			r.WindowS = windowS
		}
	}

	// Long-running orphans — WHO is spending the box, beside the aggregates that
	// can only say THAT it is being spent. The nil-vs-empty normalization is the
	// whole honesty of the field: a probe that ran and found nothing lands `[]`
	// (measured, quiet); an unwired or failing probe leaves nil (unmeasured), and
	// the control plane renders those two differently on purpose.
	if cfg.RunawayProbe != nil {
		if procs, err := cfg.RunawayProbe(); err == nil {
			if procs == nil {
				procs = []RunawayProc{}
			}
			r.Runaways = procs
		}
	}

	// Blue/green UNIT STATE — the half of "is this box healthy" that no vital can
	// answer. Same nil-vs-empty normalization as Runaways above, and the pair
	// lands together: an error leaves SlotUnits nil AND SlotUnitsTruncated -1,
	// because a truncation count beside no list is a number about nothing.
	if cfg.SlotUnitsProbe != nil {
		if units, truncated, err := cfg.SlotUnitsProbe(); err == nil {
			if units == nil {
				units = []SlotUnit{}
			}
			r.SlotUnits = units
			r.SlotUnitsTruncated = truncated
		}
	}

	// Swap. Fail-soft as ONE unit: an error leaves both sentinels, because a
	// percent without its companion total cannot be interpreted. A swapless box
	// is NOT an error — it lands (0, 0), which is a measurement.
	if cfg.SwapProbe != nil {
		if pct, total, err := cfg.SwapProbe(); err == nil {
			r.SwapUsedPercent = pct
			r.SwapTotalBytes = total
		}
	}

	// The BEAM's own footprint (PSS + swap) — the MAX across every blue/green
	// slot, carrying the pid and slot it was measured from so a consumer can
	// detect that the measured process changed.
	if cfg.BeamProbe != nil {
		if pss, sw, pid, slot, err := cfg.BeamProbe(); err == nil {
			r.BeamPSSBytes = pss
			r.BeamSwapBytes = sw
			r.BeamPID = pid
			r.BeamSlot = slot
		}
	}

	// Postgres size.
	if cfg.PGSizeProbe != nil {
		if sz, err := cfg.PGSizeProbe(); err == nil {
			r.PGSizeBytes = sz
		}
	}

	// Postgres top consumers by name — independently fail-soft from the total.
	if cfg.PGTopRelationsProbe != nil {
		if rows, err := cfg.PGTopRelationsProbe(); err == nil {
			r.PGTopRelations = rows
		}
	}

	// Backup status. The state is set on EVERY arm — including the nil-probe
	// arm, whose whole point is that "nobody looked" is now a value on the wire
	// instead of a zero value indistinguishable from a failure. BackupOK is
	// derived last, from the state, so the legacy bool can never drift.
	if cfg.BackupProbe != nil {
		state, detail, err := cfg.BackupProbe()
		switch {
		case err != nil:
			r.BackupState, r.BackupDetail = BackupStateError, "backup probe error: "+err.Error()
		case state.Valid():
			r.BackupState, r.BackupDetail = state, detail
		default:
			// A probe that answered with a state outside the set has told us
			// nothing we may render. That is a broken probe, not a backup
			// verdict, so it lands as an error and SAYS what it answered.
			r.BackupState = BackupStateError
			r.BackupDetail = fmt.Sprintf("backup probe returned unknown state %q", string(state))
		}
	} else {
		r.BackupState, r.BackupDetail = BackupStateUnmeasured, "no backup probe wired"
	}
	r.BackupOK = r.BackupState == BackupStateOK

	// Health gate (websocket-not-403 / TLS / capabilities / studio / pg-via-api).
	if cfg.HealthBaseURL != "" {
		run := cfg.runHealthGateFor
		if run == nil {
			run = setup.RunHealthGate
		}
		opts := cfg.HealthGateOpts
		if cfg.HealthRootCAs != nil {
			opts.RootCAs = cfg.HealthRootCAs
		}
		report, err := run(cfg.HealthBaseURL, cfg.HealthToken, opts)
		r.Health = report.Checks
		if err == nil && report.OK {
			r.HealthStatus = "up"
		} else {
			r.HealthStatus = "down"
		}
	}

	return r
}

// requestStatsPath is the instance route the ReqStatsProbe reads, served by the
// sibling wave-5 slice (cloud-console-w5-instance-req-stats — mounted in
// api/lib/barkpark_web/router.ex as GET /v1/instance/request-stats). It answers
// 200 {"req_per_s": float, "p95_ms": int|null, "window_s": int} for a valid
// bearer token; an instance built before that slice returns 404, which the probe
// degrades to sentinels (version-skew honesty, D48/D51). This string is the
// cross-slice contract — keep it in lockstep with the route the instance mounts.
const requestStatsPath = "/v1/instance/request-stats"

// reqStatsTimeout bounds the per-beat RequestStats GET. It is short by design:
// the stats read must never stall the whole report cycle, and a slow/hung box
// degrades to the -1 sentinel rather than blocking every other vital.
const reqStatsTimeout = 3 * time.Second

// reqStatsBody is the instance RequestStats response. P95Ms and Err5xxPerS are
// pointers so a JSON null (no samples in the window yet) — and an ABSENT key, an
// instance built before the field existed — are both distinguishable from a real
// 0 and map to the -1 sentinel. Never a fake zero latency, and never a fake zero
// error rate: "no samples" is not "no errors".
type reqStatsBody struct {
	ReqPerS    float64  `json:"req_per_s"`
	P95Ms      *int     `json:"p95_ms"`
	Err5xxPerS *float64 `json:"err_5xx_per_s"`
	// WindowS is a POINTER for the same reason its two siblings are: an
	// instance built before the key (or sending null) must arrive as the -1
	// sentinel, never as a confident 0-second window.
	WindowS *int `json:"window_s"`
}

// NewReqStatsProbe builds the production ReqStatsProbe: a short-timeout HTTP GET
// against the instance RequestStats route (base+requestStatsPath) carrying the
// health gate's bearer token — the SAME base+token seam the health gate uses.
//
// It is fail-soft to sentinels: any transport error, non-200 status (a 404 from
// an old instance without the route included), or undecodable body returns a
// non-nil error so gatherReport keeps ReqPerS=-1, P95Ms=-1 and Err5xxPerS=-1. On
// a 200 the decoded req/s always lands; a null (or absent) p95_ms/err_5xx_per_s
// maps to the -1 sentinel while req/s still reports — an instance built before
// the 5xx field simply omits the key and the beat says "unmeasured", which is
// the same version-skew honesty the 404 path already keeps. base=="" returns a
// nil probe (unwired), mirroring how the health gate is skipped when
// HealthBaseURL is empty.
func NewReqStatsProbe(base, token string, rootCAs *x509.CertPool) func() (float64, int, float64, int, error) {
	base = strings.TrimRight(base, "/")
	if base == "" {
		return nil
	}
	url := base + requestStatsPath
	return func() (float64, int, float64, int, error) {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			return -1, -1, -1, -1, err
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		client := &http.Client{Timeout: reqStatsTimeout}
		if rootCAs != nil {
			tr := http.DefaultTransport.(*http.Transport).Clone()
			tr.TLSClientConfig = &tls.Config{RootCAs: rootCAs}
			client.Transport = tr
		}
		resp, err := client.Do(req)
		if err != nil {
			return -1, -1, -1, -1, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return -1, -1, -1, -1, fmt.Errorf("request-stats: status %d", resp.StatusCode)
		}
		var body reqStatsBody
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return -1, -1, -1, -1, err
		}
		p95 := -1
		if body.P95Ms != nil {
			p95 = *body.P95Ms
		}
		err5xx := float64(-1)
		if body.Err5xxPerS != nil {
			err5xx = *body.Err5xxPerS
		}
		windowS := -1
		if body.WindowS != nil {
			windowS = *body.WindowS
		}
		return body.ReqPerS, p95, err5xx, windowS, nil
	}
}

// pgProbeTimeout bounds each psql shell-out. It is deliberately short and
// deliberately NOT execRunnerTimeout: the approved-command runner may take five
// minutes for a rebuild, but a per-beat space probe that takes five minutes IS
// the runaway-diagnostic incident again. Unexported so a test can lower it.
var pgProbeTimeout = 5 * time.Second

// pgStatementTimeout is the server-side twin of pgProbeTimeout: it stops the
// QUERY inside Postgres rather than only killing the client, so a psql we walk
// away from cannot leave a backend churning. The top-relations query's cost
// scales with RELATION count (a box with thousands of partitions), which is why
// it is bounded on both sides as well as by LIMIT.
const pgStatementTimeout = "3000ms"

// pgSizeSQL asks for the whole database's on-disk size — the number the usage
// meter has always rendered "unmetered" because this probe was never wired.
const pgSizeSQL = "SET statement_timeout = '" + pgStatementTimeout + "'; " +
	"SELECT pg_database_size(current_database());"

// pgTopRelationsSQL names the biggest consumers inside that total. LIMIT 10 and
// the statement_timeout are both load-bearing bounds, not decoration.
const pgTopRelationsSQL = "SET statement_timeout = '" + pgStatementTimeout + "'; " +
	"SELECT c.relname, pg_total_relation_size(c.oid) " +
	"FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " +
	"WHERE c.relkind IN ('r','m','p') " +
	"AND n.nspname NOT IN ('pg_catalog','information_schema') " +
	"ORDER BY 2 DESC LIMIT 10;"

// pgTopRelationsLimit mirrors the LIMIT in pgTopRelationsSQL and is enforced
// again client-side: a probe payload must stay bounded even if the query text
// is ever edited without the parser being told.
const pgTopRelationsLimit = 10

// probeRunner is the shell-out seam every on-box probe uses. Production passes
// a runBounded closure carrying that probe's timeout; tests pass a fake so the
// contract (env, argv, parsing, failure paths) is provable without a live box.
//
// env is the first parameter and not an option BECAUSE it is the credential
// channel: making every call site spell out `nil` is what makes the two that
// pass a real environment (the Postgres pair) visible at a glance, and it is
// why there is ONE runner rather than a second credential-carrying fork.
type probeRunner func(env []string, name string, args ...string) (string, error)

// boundedPGRunner is the production probeRunner: psql under pgProbeTimeout.
func boundedPGRunner(env []string, name string, args ...string) (string, error) {
	return runBounded(pgProbeTimeout, env, name, args...)
}

// pgDatabaseURL reads DATABASE_URL out of <checkout>/.env and returns it in a
// form psql accepts.
//
// Two facts make this necessary, both verified on a live box: the agent runs as
// root, and a bare `psql` as root fails with "role root does not exist", so the
// connection string must come from somewhere — and Barkpark stores it as an
// Ecto URL whose `ecto://` scheme libpq does not understand, so the scheme is
// rewritten to `postgres://`. An unreadable .env or a missing DATABASE_URL is
// an ERROR, never a fallback to a default connection: the field must stay at
// its -1 sentinel rather than report a number measured against some other
// database.
func pgDatabaseURL(checkout string) (string, error) {
	if checkout == "" {
		return "", errors.New("pg: no checkout configured")
	}
	path := filepath.Join(checkout, ".env")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("pg: read %s: %w", path, err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		line = strings.TrimPrefix(line, "export ")
		key, val, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(key) != "DATABASE_URL" {
			continue
		}
		val = strings.TrimSpace(val)
		val = strings.Trim(val, `"'`)
		if val == "" {
			continue
		}
		// Ecto's scheme is not libpq's; everything after it is identical.
		if rest, found := strings.CutPrefix(val, "ecto://"); found {
			val = "postgres://" + rest
		}
		return val, nil
	}
	return "", fmt.Errorf("pg: no DATABASE_URL in %s", path)
}

// psqlArgs builds the argv for a single-shot, machine-readable psql query:
// -A unaligned, -t tuples only, -q quiet, -F| explicit field separator, and
// ON_ERROR_STOP so a failed SET does not silently yield a partial answer.
//
// It carries NO connection string. argv is world-readable — every local process
// can read /proc/<pid>/cmdline or run a plain `ps` — so a DATABASE_URL placed
// here publishes the database password to every user on the box for the whole
// lifetime of the child, twice per beat. The connection travels in the child's
// ENVIRONMENT instead (pgConnEnv), which only the process owner can read.
func psqlArgs(sql string) []string {
	return []string{"-v", "ON_ERROR_STOP=1", "-A", "-t", "-q", "-F", "|", "-c", sql}
}

// psqlEnvKey maps a libpq URI query parameter to the environment variable libpq
// reads for the same connection keyword. The whitelist is closed on purpose: an
// unrecognised parameter is an ERROR, exactly as it is for libpq itself
// ("invalid URI query parameter"), because the alternative is silently DROPPING
// it — and a dropped `sslmode=require` is a plaintext connection nobody asked
// for. Failing keeps the field at its -1 sentinel, which is the honest answer.
var psqlEnvKey = map[string]string{
	"host":                 "PGHOST",
	"port":                 "PGPORT",
	"dbname":               "PGDATABASE",
	"user":                 "PGUSER",
	"password":             "PGPASSWORD",
	"sslmode":              "PGSSLMODE",
	"sslrootcert":          "PGSSLROOTCERT",
	"sslcert":              "PGSSLCERT",
	"sslkey":               "PGSSLKEY",
	"connect_timeout":      "PGCONNECT_TIMEOUT",
	"application_name":     "PGAPPNAME",
	"options":              "PGOPTIONS",
	"target_session_attrs": "PGTARGETSESSIONATTRS",
}

// pgConnEnv turns the checkout's DATABASE_URL into the ENVIRONMENT the psql
// child connects with, so the password never appears in argv.
//
// Two properties are load-bearing:
//
//   - It is COMPLETE or it is an error. Host, user and database must all be
//     present; a URL missing any of them would leave libpq to fall back on its
//     own defaults (the OS user, a unix socket, a database named after the
//     user) and the probe would then report a real, plausible number measured
//     against the WRONG database. That is worse than -1, so it returns an error
//     and the field keeps its sentinel — the same contract pgDatabaseURL holds.
//   - It is EXCLUSIVE. Every inherited PG* variable is dropped from the child's
//     environment first, so an ambient PGHOST/PGDATABASE in the agent's own
//     environment cannot redirect the probe at another server. PG* is entirely
//     libpq's connection namespace; psql needs nothing else out of it.
func pgConnEnv(rawURL string) ([]string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		// The error is NOT wrapped: url.Error prints the url it failed on, and
		// that url is the credential this whole function exists to contain.
		return nil, errors.New("pg: unparseable DATABASE_URL")
	}
	if u.Scheme != "postgres" && u.Scheme != "postgresql" {
		return nil, fmt.Errorf("pg: DATABASE_URL scheme %q is not postgres://", u.Scheme)
	}
	conn := map[string]string{}
	if h := u.Hostname(); h != "" {
		conn["PGHOST"] = h
	}
	if port := u.Port(); port != "" {
		conn["PGPORT"] = port
	}
	if db := strings.TrimPrefix(u.Path, "/"); db != "" {
		conn["PGDATABASE"] = db
	}
	if u.User != nil {
		if name := u.User.Username(); name != "" {
			conn["PGUSER"] = name
		}
		if pw, ok := u.User.Password(); ok {
			conn["PGPASSWORD"] = pw
		}
	}
	params, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		// Unwrapped for the same reason: the parse error quotes the input.
		return nil, errors.New("pg: unparseable DATABASE_URL parameters")
	}
	for name, vals := range params {
		key, ok := psqlEnvKey[name]
		if !ok {
			return nil, fmt.Errorf("pg: DATABASE_URL carries unsupported parameter %q", name)
		}
		conn[key] = vals[len(vals)-1]
	}
	for _, required := range []string{"PGHOST", "PGUSER", "PGDATABASE"} {
		if conn[required] == "" {
			return nil, fmt.Errorf("pg: DATABASE_URL has no %s — a default connection would measure the WRONG database", required)
		}
	}

	env := make([]string, 0, len(conn)+16)
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "PG") {
			continue
		}
		env = append(env, kv)
	}
	keys := make([]string, 0, len(conn))
	for k := range conn {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		env = append(env, k+"="+conn[k])
	}
	return env, nil
}

// NewPGSizeProbe builds the production PGSizeProbe: psql against the checkout's
// own DATABASE_URL, bounded by pgProbeTimeout. checkout=="" returns nil
// (unwired), mirroring NewReqStatsProbe. Every failure path — no .env, no
// DATABASE_URL, no psql binary, a timeout, an unparseable answer — returns an
// error so PGSizeBytes stays -1. A box without psql reports exactly what it
// reports today; it never reports a faked zero.
func NewPGSizeProbe(checkout string) func() (int64, error) {
	return newPGSizeProbeWith(boundedPGRunner, checkout)
}

func newPGSizeProbeWith(run probeRunner, checkout string) func() (int64, error) {
	if checkout == "" {
		return nil
	}
	return func() (int64, error) {
		dbURL, err := pgDatabaseURL(checkout)
		if err != nil {
			return -1, err
		}
		env, err := pgConnEnv(dbURL)
		if err != nil {
			return -1, err
		}
		out, err := run(env, "psql", psqlArgs(pgSizeSQL)...)
		if err != nil {
			return -1, fmt.Errorf("pg size: %w: %s", err, strings.TrimSpace(out))
		}
		return parsePGSize(out)
	}
}

// parsePGSize reads the single integer psql prints for pg_database_size.
func parsePGSize(out string) (int64, error) {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		n, err := strconv.ParseInt(line, 10, 64)
		if err != nil {
			return -1, fmt.Errorf("pg size: unparseable %q", line)
		}
		return n, nil
	}
	return -1, errors.New("pg size: empty result")
}

// NewPGTopRelationsProbe builds the production PGTopRelationsProbe: the top 10
// relations by pg_total_relation_size, same seam and same bound as the total.
// checkout=="" returns nil (unwired); every failure returns an error so
// PGTopRelations stays nil rather than an invented empty list.
func NewPGTopRelationsProbe(checkout string) func() ([]RelationSize, error) {
	return newPGTopRelationsProbeWith(boundedPGRunner, checkout)
}

func newPGTopRelationsProbeWith(run probeRunner, checkout string) func() ([]RelationSize, error) {
	if checkout == "" {
		return nil
	}
	return func() ([]RelationSize, error) {
		dbURL, err := pgDatabaseURL(checkout)
		if err != nil {
			return nil, err
		}
		env, err := pgConnEnv(dbURL)
		if err != nil {
			return nil, err
		}
		out, err := run(env, "psql", psqlArgs(pgTopRelationsSQL)...)
		if err != nil {
			return nil, fmt.Errorf("pg top relations: %w: %s", err, strings.TrimSpace(out))
		}
		return parsePGTopRelations(out)
	}
}

// parsePGTopRelations turns psql's "name|bytes" lines into RelationSize rows,
// re-applying pgTopRelationsLimit client-side so the beat payload stays bounded
// no matter what the query returned.
func parsePGTopRelations(out string) ([]RelationSize, error) {
	var rows []RelationSize
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		name, sizeStr, ok := strings.Cut(line, "|")
		if !ok {
			return nil, fmt.Errorf("pg top relations: unparseable %q", line)
		}
		n, err := strconv.ParseInt(strings.TrimSpace(sizeStr), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("pg top relations: unparseable size in %q", line)
		}
		rows = append(rows, RelationSize{Name: strings.TrimSpace(name), Bytes: n})
		if len(rows) == pgTopRelationsLimit {
			break
		}
	}
	if len(rows) == 0 {
		return nil, errors.New("pg top relations: empty result")
	}
	return rows, nil
}

// SpaceConfig wires gatherSpace's probes, exactly like ReportConfig wires the
// beat's. Every probe is injected so the whole space payload is provable
// without a real df/journalctl/du/psql, and a nil probe means "skip this
// consumer honestly" — its field keeps the unmeasured sentinel.
type SpaceConfig struct {
	// RootProbe returns the root filesystem's (used, total) bytes. nil → both -1.
	RootProbe func() (usedBytes int64, totalBytes int64, err error)
	// JournalProbe returns the systemd journal's bytes. nil → -1.
	JournalProbe func() (int64, error)
	// PGSizeProbe / PGTopRelationsProbe are the SAME constructors the beat uses
	// (NewPGSizeProbe / NewPGTopRelationsProbe) — the database is measured one
	// way, in one place, never by a `du` over PGDATA. nil → -1 / nil.
	PGSizeProbe         func() (int64, error)
	PGTopRelationsProbe func() ([]RelationSize, error)
	// SitesDir is the RESOLVED sites root, echoed into the payload whether or
	// not the measurement succeeds.
	SitesDir string
	// SitesProbe returns (total bytes, EVERY slug it found, sorted biggest
	// first) for SitesDir. nil or an error → SitesBytes=-1, SitesTop=nil and
	// SitesCount=-1, as ONE unit: a total without its breakdown is the
	// uninformative number this payload replaces, and a breakdown without its
	// total cannot be sanity-checked.
	//
	// The probe deliberately does NOT cap. gatherSpace applies sitesTopLimit at
	// the payload boundary — the one place the bound is actually needed — so the
	// count it reports is the count the walk FOUND, not the count that survived
	// the cap. A cap that eats its own denominator can never say when it binds.
	SitesProbe func() (totalBytes int64, all []SiteSize, err error)

	// ConsumerRoots is the ORDERED list of extra disk-consumer roots to measure
	// — the build plane's trees and anything else the sites axis cannot see.
	// Empty → SpaceReport.ConsumerRoots stays nil (not measured), never [].
	//
	// It is a LIST and it is configurable because the fleet is not one shape:
	// the box that motivated this runs the build plane and has no sites tree at
	// all, while a content box has a sites tree and no containerd. A single
	// hardcoded root is how one of those two became unmeasurable.
	ConsumerRoots []string

	// ConsumerRootExists reports whether a root is present on this box. It is a
	// SEPARATE seam from the probe on purpose: "not there" is a measurement
	// this agent can make with a stat, in microseconds, without shelling out —
	// and it is the one answer a du error can never give reliably, because a
	// du that fails on a missing directory and a du killed at its deadline both
	// come back as "non-zero exit, some text". nil → every configured root that
	// the probe cannot read reports `unmeasured` (we genuinely do not know).
	ConsumerRootExists func(path string) bool

	// ConsumerRootProbe measures ONE root: (total bytes, EVERY direct child,
	// sorted biggest first). Like SitesProbe it does NOT cap — gatherSpace caps
	// at the payload boundary so Count survives the cap. An error → that root
	// reports `unmeasured`; the other roots are unaffected, because one
	// unreadable tree must not erase the ones that were read.
	// degraded names the subtrees the walk could not descend into, by PATH. A
	// non-empty degraded with a nil err is a REAL, SHORT total: du finished and
	// printed its root but could not read everything under it, and that is a
	// floor worth landing precisely because we can say what is missing from it.
	ConsumerRootProbe func(path string) (totalBytes int64, all []DirSize, degraded []string, err error)

	// DeviceProbe returns the st_dev of a path and whether it could be read.
	// It is the residual's mount-boundary guard: only extents on the SAME
	// device as `/` may be subtracted from a root-filesystem denominator.
	//
	// It is a separate seam from ConsumerRootExists for the reason that seam is
	// separate from the probe: presence, device and size are three different
	// questions, and inferring any of them from another's failure mode is how a
	// wrong root became invisible in the first place. nil → the residual
	// REFUSES (residualReasonDeviceUnverified) rather than summing roots it
	// cannot place.
	DeviceProbe func(path string) (dev uint64, ok bool)

	// PGDataDir is where Postgres keeps its files, used ONLY to decide whether
	// a configured du root already covers PGSizeBytes. Empty → DefaultPGDataDir.
	//
	// It is not a probe and nothing walks it: the database's own size is the
	// better measurement (it excludes the WAL and temp files an operator cannot
	// act on), so this path exists purely to stop the two from being added
	// together.
	PGDataDir string
}

// gatherSpace assembles a SpaceReport from the wired probes. Like gatherReport
// it is total: a missing or failing probe yields the unmeasured sentinel, never
// a panic and never a partial number.
func gatherSpace(cfg SpaceConfig) SpaceReport {
	s := SpaceReport{
		Type:           SpaceEventType,
		RootUsedBytes:  -1,
		RootTotalBytes: -1,
		JournalBytes:   -1,
		PGSizeBytes:    -1,
		SitesDir:       cfg.SitesDir,
		SitesBytes:     -1,
		SitesCount:     -1,
	}

	// Root filesystem: used AND total, one measurement, never half-landed.
	if cfg.RootProbe != nil {
		if used, total, err := cfg.RootProbe(); err == nil {
			s.RootUsedBytes, s.RootTotalBytes = used, total
		}
	}

	if cfg.JournalProbe != nil {
		if n, err := cfg.JournalProbe(); err == nil {
			s.JournalBytes = n
		}
	}

	if cfg.PGSizeProbe != nil {
		if n, err := cfg.PGSizeProbe(); err == nil {
			s.PGSizeBytes = n
		}
	}
	if cfg.PGTopRelationsProbe != nil {
		if rows, err := cfg.PGTopRelationsProbe(); err == nil {
			s.PGTopRelations = rows
		}
	}

	// Sites: total + per-slug + the COUNT, one unit. The cap lands here, at the
	// payload boundary, and only after the count has been taken off the full
	// list — so SitesTop can be short of SitesCount and a reader can SEE that it
	// is. Capping upstream would leave len(SitesTop) as the only available
	// denominator, which is the same number under both "ten slugs exist" and
	// "forty do", i.e. a bound that never announces itself.
	if cfg.SitesProbe != nil {
		if total, all, err := cfg.SitesProbe(); err == nil {
			s.SitesBytes, s.SitesCount = total, len(all)
			if len(all) > sitesTopLimit {
				all = all[:sitesTopLimit]
			}
			s.SitesTop = all
		}
	}

	s.ConsumerRoots = gatherConsumerRoots(cfg)

	// LAST, and from the assembled payload rather than from the probes: the
	// residual is a statement ABOUT this payload, so it must be computed from
	// exactly the numbers the payload carries. Computing it alongside the
	// probes would let a field be adjusted afterwards (a cap applied, a sentinel
	// substituted) while the residual still described the pre-adjustment values.
	s.Residual = computeResidual(&s, cfg)

	return s
}

// spaceExtent is one measured region of disk that the residual may subtract:
// a path with a byte count, plus the payload row it came from so an exclusion
// can be written back onto that row.
type spaceExtent struct {
	path  string
	bytes int64
	// root points at the ConsumerRoot this extent came from, so an exclusion
	// lands on the row itself. nil for the sites extent, which has no row.
	root *ConsumerRoot
}

// pathCovers reports whether parent contains child (or IS child). Both are
// already cleaned. The separator test is what stops "/var/lib" from swallowing
// "/var/libvirt": a prefix match on strings alone is a bug that only shows up
// when two roots happen to share one.
func pathCovers(parent, child string) bool {
	if parent == child {
		return true
	}
	if parent == "/" {
		return true
	}
	return strings.HasPrefix(child, parent+"/")
}

// computeResidual performs the one subtraction this axis exists for, and
// refuses in every case where the subtraction would produce a number it cannot
// stand behind.
//
// THE FOUR GUARDS, in the order they are applied:
//
//  1. EXACT BYTES. Nothing here rounds; duTreeArgs asks du for -k and
//     parseDuSize multiplies by 1024. This function only ever adds and
//     subtracts int64 byte counts. (The guard lives at duTreeArgs; it is named
//     here because it is the guard whose absence this arithmetic would amplify.)
//  2. SAME DEVICE AS `/`. An extent on another device is bytes that are not in
//     the denominator, so subtracting it is a phantom deficit. Excluded and
//     named. An extent whose device cannot be READ is excluded too — "unknown"
//     is not "same".
//  3. DISJOINT. An extent covered by an earlier extent is already inside that
//     extent's du total. Excluded and named, with the covering path in the
//     reason so the operator does not have to work out which pair collided.
//  4. PG ONCE. If a counted extent covers PGDATA, PGSizeBytes is NOT added;
//     otherwise it is. The choice is stated in PGSource either way.
//
// AND THE CLAMP. If the counted extents still sum to more than the denominator,
// the root set is not what it claims and the result is ResidualUndefined — never
// a negative gigabyte.
func computeResidual(s *SpaceReport, cfg SpaceConfig) *SpaceResidual {
	r := &SpaceResidual{
		Status:        ResidualUnmeasured,
		Bytes:         -1,
		OfBytes:       s.RootUsedBytes,
		MeasuredBytes: -1,
		PGSource:      PGSourceNone,
	}

	// GUARD 4 (the denominator). No RootUsedBytes, no residual — and in
	// particular no substituting disk_used_percent, which is a share of a
	// different whole.
	if s.RootUsedBytes < 0 {
		r.Reason = residualReasonRootUnmeasured
		return r
	}

	// GUARD 2, first half: we need `/`'s own device to compare anything to. No
	// device probe, or a `/` we cannot stat, means every extent is unplaceable
	// — and a residual over unplaceable extents is exactly the confident subset
	// this field exists to refuse.
	if cfg.DeviceProbe == nil {
		r.Reason = residualReasonDeviceUnverified
		return r
	}
	rootDev, ok := cfg.DeviceProbe("/")
	if !ok {
		r.Reason = residualReasonDeviceUnverified
		return r
	}

	// Candidate extents, in payload order: the consumer roots, then sites.
	// Order is load-bearing for guard 3 — the FIRST extent covering a region
	// keeps it, so the exclusion lands deterministically on the same root every
	// run rather than on whichever one sorted first today.
	var candidates []spaceExtent
	for i := range s.ConsumerRoots {
		row := &s.ConsumerRoots[i]
		if row.Status != ConsumerRootRead && row.Status != ConsumerRootDegraded {
			continue
		}
		if row.Bytes < 0 {
			continue
		}
		candidates = append(candidates, spaceExtent{path: filepath.Clean(row.Path), bytes: row.Bytes, root: row})
	}
	if s.SitesDir != "" && s.SitesBytes >= 0 {
		candidates = append(candidates, spaceExtent{path: filepath.Clean(s.SitesDir), bytes: s.SitesBytes})
	}

	counted := make([]spaceExtent, 0, len(candidates))
	excluded := 0
	exclude := func(e spaceExtent, reason string) {
		excluded++
		if e.root != nil {
			e.root.ExcludedReason = reason
		}
	}

	for _, e := range candidates {
		// GUARD 2. A root on another device — the overlay case — is measured
		// correctly and still must not be subtracted.
		dev, devOK := cfg.DeviceProbe(e.path)
		if !devOK {
			exclude(e, excludedDeviceUnverified)
			continue
		}
		if dev != rootDev {
			exclude(e, excludedCrossMount)
			continue
		}
		// GUARD 3. Covered by something already counted → its bytes are in
		// that total. Name the covering path: "excluded" without "by what" is a
		// fact the operator cannot act on.
		if covering, dup := coveredBy(counted, e.path); dup {
			exclude(e, excludedUnderPrefix+covering)
			continue
		}
		counted = append(counted, e)
	}

	var measured int64
	for _, e := range counted {
		measured += e.bytes
	}

	// GUARD 3 (continued) and GUARD 4 (pg once). PGSizeBytes measures the same
	// bytes a du root over PGDATA measures, so exactly one of them may be
	// added — and the payload says which, because an unstated choice between
	// two overlapping measurements is a 3.37 GiB error nobody can audit.
	pgDir := filepath.Clean(cfg.PGDataDir)
	if cfg.PGDataDir == "" {
		pgDir = DefaultPGDataDir
	}
	switch {
	case coveredByAny(counted, pgDir):
		r.PGSource = PGSourceDURoot
	case s.PGSizeBytes >= 0:
		r.PGSource = PGSourceSizeBytes
		measured += s.PGSizeBytes
	default:
		r.PGSource = PGSourceNone
	}

	r.MeasuredBytes = measured
	r.CountedRoots = len(counted)
	r.ExcludedRoots = excluded

	// THE CLAMP. Disjoint trees on one device cannot sum past that device's
	// used total, so this branch is proof the set is wrong — and a wrong set is
	// reported as a refusal, never as a negative gigabyte.
	if measured > s.RootUsedBytes {
		r.Status = ResidualUndefined
		r.Reason = residualReasonOverlap
		return r
	}

	r.Status = ResidualComputed
	r.Bytes = s.RootUsedBytes - measured
	return r
}

// coveredBy returns the counted path that contains p, if any. It is the guard-3
// test, kept as its own function so the "which one" answer is produced by the
// same code that decides "whether" — a reason that names a path the check did
// not actually use is worse than no reason.
func coveredBy(counted []spaceExtent, p string) (string, bool) {
	for _, c := range counted {
		if pathCovers(c.path, p) {
			return c.path, true
		}
	}
	return "", false
}

func coveredByAny(counted []spaceExtent, p string) bool {
	_, ok := coveredBy(counted, p)
	return ok
}

// gatherConsumerRoots measures every configured consumer root, in order, and
// returns one entry per root — INCLUDING the roots that are not on this box.
//
// The absent entry is the whole reason this function exists. Dropping a missing
// root from the list would restore exactly the bug being fixed: a payload with
// no /var/lib/containerd row is indistinguishable from a payload from a box
// where containerd holds nothing, and a reader that sees no row for a root it
// asked about learns nothing about which of those two is true.
//
// It returns nil (never an empty slice) when no roots are configured: an agent
// that was never told where to look has not measured "no roots".
func gatherConsumerRoots(cfg SpaceConfig) []ConsumerRoot {
	roots := cfg.ConsumerRoots
	if len(roots) == 0 {
		return nil
	}
	if len(roots) > consumerRootsLimit {
		roots = roots[:consumerRootsLimit]
	}

	out := make([]ConsumerRoot, 0, len(roots))
	for _, path := range roots {
		// Every root starts UNMEASURED with both sentinels set, so any arm that
		// falls through — nil probe, error, timeout — lands honestly by default
		// rather than by remembering to.
		r := ConsumerRoot{
			Path:          path,
			Status:        ConsumerRootUnmeasured,
			Bytes:         -1,
			Count:         -1,
			DegradedCount: -1,
		}
		switch {
		case cfg.ConsumerRootExists != nil && !cfg.ConsumerRootExists(path):
			// Measured, and the measurement is "there is no such directory".
			// Bytes and Count stay -1: a tree that does not exist is not empty.
			r.Status = ConsumerRootAbsent
		case cfg.ConsumerRootProbe != nil:
			if total, all, degraded, err := cfg.ConsumerRootProbe(path); err == nil {
				r.Status = ConsumerRootRead
				r.Bytes, r.Count = total, len(all)
				if len(all) > consumerTopLimit {
					all = all[:consumerTopLimit]
				}
				r.Top = all
				if len(degraded) > 0 {
					// The total is real and SHORT. Say both, and cap the names
					// after taking the count — never before, or the payload can
					// no longer say how much it hid.
					r.Status = ConsumerRootDegraded
					r.DegradedCount = len(degraded)
					if len(degraded) > consumerDegradedLimit {
						degraded = degraded[:consumerDegradedLimit]
					}
					r.Degraded = degraded
				}
			}
		}
		out = append(out, r)
	}
	return out
}

// The space probes' deadlines. Each is probe-SPECIFIC, and each is a LIFETIME
// bound on the shell-out (runBounded), not a hint: df and journalctl are header
// reads that finish in milliseconds, while du walks a tree and was measured at
// 2.03s cold / 0.36s warm on a loaded 2-core box. Unexported so tests can lower
// them.
var (
	dfProbeTimeout      = 5 * time.Second
	journalProbeTimeout = 10 * time.Second
	duProbeTimeout      = 60 * time.Second
)

// sitesTopLimit caps the per-slug list, enforced in gatherSpace (NOT in the
// probe) so SpaceReport.SitesCount still carries how many slugs the cap hid. Ten slugs compress to ~1685 B, safely
// inside Postgres's 2032-byte TOAST_TUPLE_THRESHOLD; an uncapped list crosses
// it between 20 and 25 realistic high-entropy slugs (D58). The cap is also the
// useful shape: an operator acts on the biggest site, not on the 40th.
const sitesTopLimit = 10

// consumerRootsLimit and consumerTopLimit are the consumer axis's two bounds,
// and they are bounds on a CONFIGURED list, which is the point: the roots are
// operator-supplied, so a fat-fingered unit file must not be able to turn the
// space beat into a rootfs walk or the payload into a kilobyte of directory
// names.
//
// consumerRootsLimit also bounds WALL TIME, not just bytes: every root is one
// bounded `du` under duProbeTimeout, so six roots is a 6-minute worst case on a
// box that is already struggling. That is the number to lower if the beat is
// ever seen crowding a cutover — never the honesty.
//
// consumerTopLimit is 2 rather than the sites axis's 10 because it multiplies:
// six roots at ten children each is sixty rows on a payload the sites axis
// already budgets ten for. TestSpacePayloadStaysBounded marshals a real
// jarl-shaped report and pins the resulting size, so this arithmetic is a
// measurement rather than a hope.
//
// It came DOWN from 5 when the degraded names were added, and DOWN AGAIN from 3
// when the residual was added — that direction is the rule, and it has now been
// applied twice. At full caps the payload measured 5125 bytes when the degraded
// names landed and 4128 when the residual did, both against a 4096-byte
// ceiling, and the ceiling is the thing that must not move.
//
// The bytes are bought from the LAST CHILD, never from a root slot, and the
// asymmetry is deliberate: a root nobody measures is invisible — it contributes
// nothing to the residual and cannot be missed — while a third-biggest child is
// a detail on a tree whose total and biggest two consumers are already named.
// Count still reports how many children the walk found, so the shorter list
// says it is short. Measured against the build-plane box's real shape, the top
// two children of /var/lib/containerd carry 13.15 of its 13.17 GiB.
// consumerDegradedLimit caps the NAMES a degraded root carries. Two is enough
// to act on — an operator fixes a permission class, not 40 individual
// directories — and DegradedCount still reports how many the walk hit, so the
// cap announces itself instead of quietly deciding the shortfall was small.
const (
	consumerRootsLimit    = 6
	consumerTopLimit      = 2
	consumerDegradedLimit = 2
)

// DefaultConsumerRoots is what the agent measures when nothing overrides it.
//
// It is three paths and each earned its place on a real box:
//
//   - /var/lib/containerd — 14 GiB on the build-plane box, its single biggest
//     consumer, 12 GiB of that in one overlayfs snapshotter directory.
//   - /var/lib/barkpark-builder — 11 GiB, effectively all of it in `images`.
//   - /var/log/journal — 889 MiB, and measured HERE as a tree as well as via
//     `journalctl --disk-usage` above, because the header read needs journald
//     on the box and the tree walk does not.
//
// Two of the three do not exist on a content box, and one does not exist on the
// build box. That asymmetry is why they report `absent` instead of vanishing.
// DefaultPGDataDir is where Postgres lives on the fleet's boxes. It is used
// ONLY to decide whether a configured du root already covers the database, so
// pg is never counted twice — nothing walks it.
const DefaultPGDataDir = "/var/lib/postgresql"

var DefaultConsumerRoots = []string{
	"/var/lib/containerd",
	"/var/lib/barkpark-builder",
	"/var/log/journal",
}

// boundedSpaceRunner returns a probeRunner bound to timeout. Every space probe
// goes through one — a probe that can run forever is the runaway-diagnostic
// incident again, one layer down.
func boundedSpaceRunner(timeout time.Duration) probeRunner {
	return func(env []string, name string, args ...string) (string, error) {
		return runBounded(timeout, env, name, args...)
	}
}

// dfRootArgs is the root-filesystem argv. `-P` pins the POSIX one-line-per-fs
// format (no wrapped device names) and `-k` pins 1024-byte blocks, so the
// parser never has to guess the unit from the header. DIRECT argv — no shell.
func dfRootArgs() []string { return []string{"-P", "-k", "/"} }

// NewRootSpaceProbe builds the production root-filesystem probe: `df -P -k /`
// under dfProbeTimeout. A non-zero exit or an unparseable table is an error, so
// both bytes keep their -1 sentinel.
func NewRootSpaceProbe() func() (int64, int64, error) {
	return newRootSpaceProbeWith(boundedSpaceRunner(dfProbeTimeout))
}

func newRootSpaceProbeWith(run probeRunner) func() (int64, int64, error) {
	return func() (int64, int64, error) {
		out, err := run(nil, "df", dfRootArgs()...)
		if err != nil {
			return -1, -1, fmt.Errorf("df: %w: %s", err, strings.TrimSpace(out))
		}
		return parseDFRoot(out)
	}
}

// parseDFRoot reads (used, total) bytes from `df -P -k` output. Columns are
// indexed from the END (…blocks used avail capacity mount) so a device name
// containing spaces cannot shift the numbers — and the capacity percent is
// deliberately ignored: a bare percent is the number that tells an operator
// nothing.
func parseDFRoot(out string) (int64, int64, error) {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		fields := strings.Fields(lines[i])
		if len(fields) < 6 {
			continue
		}
		total, errT := strconv.ParseInt(fields[len(fields)-5], 10, 64)
		used, errU := strconv.ParseInt(fields[len(fields)-4], 10, 64)
		if errT != nil || errU != nil {
			continue // the header row
		}
		// df -k reports 1024-byte blocks.
		return used * 1024, total * 1024, nil
	}
	return -1, -1, errors.New("df: no data row")
}

// journalArgs is the journal argv: `journalctl --disk-usage` reads the journal
// files' own headers (~8ms warm) rather than walking /var/log/journal.
func journalArgs() []string { return []string{"--disk-usage"} }

// NewJournalSpaceProbe builds the production journal probe under
// journalProbeTimeout. A box without journald errors, so JournalBytes keeps its
// -1 sentinel rather than reporting a fictional zero.
func NewJournalSpaceProbe() func() (int64, error) {
	return newJournalSpaceProbeWith(boundedSpaceRunner(journalProbeTimeout))
}

func newJournalSpaceProbeWith(run probeRunner) func() (int64, error) {
	return func() (int64, error) {
		out, err := run(nil, "journalctl", journalArgs()...)
		if err != nil {
			return -1, fmt.Errorf("journalctl: %w: %s", err, strings.TrimSpace(out))
		}
		return parseJournalDiskUsage(out)
	}
}

// parseJournalDiskUsage pulls the size out of journalctl's one prose line
// ("Archived and active journals take up 3.7G in the file system."). The first
// field that parses as a human size wins; the surrounding words never do.
func parseJournalDiskUsage(out string) (int64, error) {
	for _, f := range strings.Fields(out) {
		if n, err := parseHumanBytes(strings.Trim(f, ".,")); err == nil {
			return n, nil
		}
	}
	return -1, fmt.Errorf("journalctl: no size in %q", truncate(strings.TrimSpace(out), 120))
}

// duSitesArgs is the sites argv, and it is a contract, not a preference:
//
//   - `nice -n 19 ionice -c3` — the walk yields to everything else on a box
//     that is already struggling; measuring pressure must not add it.
//   - `-x` never crosses a filesystem boundary (a mounted volume under the
//     tree would otherwise be counted against the sites).
//   - `-d1` bounds the depth to the direct children — one row per slug.
//     (`-s` CONFLICTS with `-d1` in coreutils 9.4; the root total comes from
//     `-d1`'s own last row.)
//   - DIRECT argv, never `sh -c`, no pipes, no `2>&1`, no `; echo rc=$?`.
//     Measured: under an identical 200ms bound, direct argv returned at 200ms
//     while an `sh -c` wrapper returned at 8.77s — 44x over budget — because
//     exec.CommandContext kills only cmd.Process (no process-group kill) and
//     CombinedOutput then blocks in Wait until the orphaned grandchild closes
//     the inherited stdout pipe. BOTH return the identical `signal: killed`, so
//     the caller cannot tell the bound was blown (charter D59).
//
// TestSitesProbeArgvIsDirect pins this shape so no future edit can quietly
// reintroduce a shell.
func duSitesArgs(dir string) []string {
	args, _ := duTreeArgs(dir)
	return args
}

// duUnit names the unit `du` was ASKED for, and it travels with the output to
// the parser. It exists because the flag and the parse are ONE decision that
// lives in TWO places, and separating them is a 1024x under-report one
// character wide:
//
//	du -h  ->  "25G\t/var/lib/containerd"        (suffixed, humanized at 1024)
//	du -k  ->  "26214400\t/var/lib/containerd"   (a bare count of 1024-blocks)
//
// A parser that reads an UNSUFFIXED number as BYTES turns that same 25 GiB into
// 26 MB, and the whole point of this axis is that a box which is full says so.
// Measured on this repo before the parameter existed: flipping the flag AND the
// two argv literals that pin it — the realistic "generalize the argv" edit —
// left the ENTIRE package suite green, because no test encoded the unit.
type duUnit string

const (
	// duUnitHuman is `du -h`: every size carries a K/M/G/T/P/E suffix, and a
	// bare number is only legal BELOW 1024 (du humanizes at 1024, so a bare
	// number >= 1024 could not have come from -h at all).
	duUnitHuman duUnit = "h"
	// duUnitKiB is `du -k`: every size is a bare count of 1024-byte blocks and
	// a suffix is impossible.
	duUnitKiB duUnit = "k"
)

// duTreeArgs returns the du argv AND the unit its output will be in, from ONE
// place, so the two cannot drift: the unit constant below is interpolated into
// the flag, so flipping it to duUnitKiB flips the argv and the parser together
// in a single edit. That mechanical coupling is the fix — TestDuArgvAndParseUnitCannotDrift
// pins it, so a future edit that changes only one side does not compile past a test.
func duTreeArgs(dir string) ([]string, duUnit) {
	// duUnitKiB, NOT duUnitHuman, and the residual is why. `du -h` ROUNDS UP,
	// per root and SYSTEMATICALLY POSITIVE, and a residual is a SUBTRACTION of
	// those roots — so the rounding does not average out, it accumulates into a
	// phantom deficit that drives the residual negative.
	//
	// MEASURED ON THE BUILD-PLANE BOX, from its own live payload on
	// 2026-09-01T20:33:42Z against `du -x -k -s` on the same trees minutes later:
	//
	//	root                        du -h landed   du -k exact    over by
	//	/var/lib/containerd         15032385536    14136475648    +895 MB
	//	/var/lib/barkpark-builder   11811160064    11575521280    +236 MB
	//	/var/log/journal             2040109466     1971761152     +68 MB
	//
	// Every landed figure is an exact multiple of 0.1 GiB, which is the
	// signature of a rounded string re-inflated by parseHumanBytes: the payload
	// was reporting a PRECISION it never had. Three roots already cost 1.2 GiB
	// of phantom; at consumerRootsLimit the error reaches several GiB on a
	// 39 GiB box, which is larger than every other hazard on this axis combined.
	const unit = duUnitKiB
	return []string{"-n", "19", "ionice", "-c3", "du", "-" + string(unit) + "x", "-d1", dir}, unit
}

// NewSitesSpaceProbe builds the production per-slug sites probe for dir, under
// duProbeTimeout. dir=="" returns nil (unwired), mirroring the PG probes.
func NewSitesSpaceProbe(dir string) func() (int64, []SiteSize, error) {
	return newSitesSpaceProbeWith(boundedSpaceRunner(duProbeTimeout), dir)
}

func newSitesSpaceProbeWith(run probeRunner, dir string) func() (int64, []SiteSize, error) {
	if dir == "" {
		return nil
	}
	return func() (int64, []SiteSize, error) {
		args, unit := duTreeArgs(dir)
		out, err := run(nil, "nice", args...)
		if err != nil {
			// DISCARD, never partially land. A du killed at its deadline prints
			// the rows it had already finished — 5 site rows, then rc=137 — and
			// those rows parse as a perfectly plausible list silently missing
			// the rest of the tree. Under-reporting space is precisely the
			// failure this payload exists to remove, so a non-zero exit reports
			// unmeasured.
			return -1, nil, fmt.Errorf("du %s: %w: %s", dir, err, truncate(strings.TrimSpace(out), 120))
		}
		total, rows, degraded, perr := parseDuTree(out, dir, unit)
		if perr != nil {
			return -1, nil, perr
		}
		if len(degraded) > 0 {
			// The sites axis has NOWHERE to put the names: SpaceReport carries
			// sites_bytes / sites_top / sites_count and no field that can say
			// "this total is short by these subtrees". A silently-short number
			// is the exact failure this payload exists to remove, so the sites
			// axis DISCARDS where the consumer axis — which has
			// ConsumerRoot.Degraded to name them in — lands. Widening the sites
			// payload to carry names is its own row, not a side effect of this one.
			return -1, nil, fmt.Errorf("du %s: unreadable subtrees %v", dir, degraded)
		}
		return total, rows, nil
	}
}

// NewConsumerRootExists builds the production presence check: a plain
// os.Stat.
//
// It is a stat and NOT a du-error inspection on purpose. `du` on a missing
// directory exits non-zero with "cannot access", and `du` killed at its
// deadline also exits non-zero — string-matching the first out of the second is
// locale-dependent, coreutils-version-dependent, and wrong the first time a
// timeout message happens to contain the word "No". A stat answers the
// question the payload is actually asking, in microseconds, with no shell.
//
// Anything that is NOT a "does not exist" error — a permission denial, an I/O
// error on a failing disk — reports PRESENT, so the du probe runs and its
// failure lands as `unmeasured`. Claiming a root is absent because we were not
// allowed to look at it would be the original bug wearing a different hat.
func NewConsumerRootExists() func(string) bool {
	return func(path string) bool {
		_, err := os.Stat(path)
		return !errors.Is(err, fs.ErrNotExist)
	}
}

// NewConsumerRootProbe builds the production per-root probe: the SAME bounded,
// shell-free `nice -n 19 ionice -c3 du -hx -d1 <dir>` argv the sites probe
// uses, under the same duProbeTimeout, with the same discard-on-error rule (a
// partially-printed walk is not a measurement).
func NewConsumerRootProbe() func(string) (int64, []DirSize, []string, error) {
	return newConsumerRootProbeWith(boundedSpaceRunner(duProbeTimeout))
}

func newConsumerRootProbeWith(run probeRunner) func(string) (int64, []DirSize, []string, error) {
	return func(dir string) (int64, []DirSize, []string, error) {
		if dir == "" {
			return -1, nil, nil, errors.New("du: empty root")
		}
		args, unit := duTreeArgs(dir)
		out, runErr := run(nil, "nice", args...)
		total, rows, degraded, parseErr := parseDuTree(out, dir, unit)

		if runErr != nil {
			// A non-zero exit is TWO different worlds and only ONE of them is a
			// measurement. Measured on guerrilla (GNU coreutils 9.4,
			// unprivileged, one 0700 subdir): `du -hx -d1` printed EVERY row
			// INCLUDING the total, named the unreadable path on stderr, and
			// exited rc=1 — a real 712K tree landing as 212K, a 70% shortfall
			// that we can NAME. A killed du printed a prefix and no total row.
			//
			// So the landing rule is three ANDs, and each one can veto:
			//   - not a deadline kill (errProbeTimedOut), which is never a
			//     measurement however parseable its prefix happens to be;
			//   - the parse SUCCEEDED, which means the total row is present —
			//     du prints its root last, so output without it was cut short;
			//   - at least one `du:` diagnostic named a path, which is the
			//     positive evidence that this rc!=0 is a permission shortfall
			//     and not an unexplained failure.
			// Anything else DISCARDS to the unmeasured sentinel (D59).
			if errors.Is(runErr, errProbeTimedOut) || parseErr != nil || len(degraded) == 0 {
				return -1, nil, nil, fmt.Errorf("du %s: %w: %s", dir, runErr, truncate(strings.TrimSpace(out), 120))
			}
		} else if parseErr != nil {
			return -1, nil, nil, parseErr
		}

		// One parser, two payload shapes. parseDuTree already returns the rows
		// biggest-first and already refuses output with no total row; all that
		// differs is the JSON key the wire wants (see DirSize).
		children := make([]DirSize, 0, len(rows))
		for _, r := range rows {
			children = append(children, DirSize{Name: r.Slug, Bytes: r.Bytes})
		}
		return total, children, degraded, nil
	}
}

// parseDuTree turns `du -hx -d1 <dir>` output into (total bytes, EVERY per-slug
// size, sorted biggest first). The row whose path IS dir is the total; every
// other row is one slug, named by its base name.
//
// It does NOT truncate. gatherSpace owns sitesTopLimit, because the count of
// slugs the walk found has to survive to the payload — see SpaceReport.SitesCount.
//
// The total row is REQUIRED: du prints its root last, so output without it is
// output that was cut short, and a truncated walk must not land as a
// measurement.
//
// On an ERROR the total and the rows are discarded (-1, nil) but the degraded
// list is still returned: what du complained about is a fact whether or not the
// rest of the output parsed, and handing it back keeps the caller's "was this a
// permission shortfall?" veto separate from its "did the parse succeed?" veto.
// Callers must still branch on err — a returned degraded list is never on its
// own a licence to land a number.
func parseDuTree(out string, dir string, unit duUnit) (int64, []SiteSize, []string, error) {
	want := filepath.Clean(dir)
	var total int64 = -1
	var rows []SiteSize
	var degraded []string
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// A du DIAGNOSTIC, not a row. runBounded uses CombinedOutput, so du's
		// complaints about subtrees it could not read arrive interleaved with
		// its sizes; hard-failing the parse on them threw away a measurement we
		// had, along with the only bytes that could name the shortfall.
		if path, ok := duDiagnosticPath(line); ok {
			if !seen[path] {
				seen[path] = true
				degraded = append(degraded, path)
			}
			continue
		}
		sizeStr, path, ok := strings.Cut(line, "\t")
		if !ok {
			// du separates with a tab; fall back to whitespace for robustness.
			fields := strings.Fields(line)
			if len(fields) < 2 {
				return -1, nil, degraded, fmt.Errorf("du: unparseable %q", line)
			}
			sizeStr, path = fields[0], strings.Join(fields[1:], " ")
		}
		n, err := parseDuSize(strings.TrimSpace(sizeStr), unit)
		if err != nil {
			return -1, nil, degraded, fmt.Errorf("du: unparseable size in %q: %w", line, err)
		}
		path = filepath.Clean(strings.TrimSpace(path))
		if path == want {
			total = n
			continue
		}
		rows = append(rows, SiteSize{Slug: filepath.Base(path), Bytes: n})
	}
	if total < 0 {
		return -1, nil, degraded, fmt.Errorf("du: no total row for %s", want)
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Bytes > rows[j].Bytes })
	return total, rows, degraded, nil
}

// duDiagnosticPath recognises one of du's stderr lines and names the PATH it is
// about — by path, never by the daemon or unit that happens to own the tree,
// because the operator's next action is `ls`/`chmod`/`du` on a directory.
//
// Two shapes, both measured:
//
//	GNU  du: cannot read directory '/opt/barkpark/sites/locked': Permission denied
//	BSD  du: /opt/barkpark/sites/locked: Permission denied
//
// GNU emits its diagnostics LAST (after the total row) and BSD emits them
// FIRST, so POSITION is never the test — the shape is. A du OUTPUT row is
// `size<TAB>path`, so the discriminator is exact: a diagnostic starts with
// "du: " and carries no tab, and a directory literally named "du: x" still
// arrives as "4.0K\tdu: x" and is read as the row it is.
func duDiagnosticPath(line string) (string, bool) {
	if !strings.HasPrefix(line, "du: ") || strings.Contains(line, "\t") {
		return "", false
	}
	rest := strings.TrimSpace(strings.TrimPrefix(line, "du: "))
	// GNU quotes the path. Outside the C locale it uses U+2018/U+2019, which is
	// why this looks for three opener/closer pairs rather than one.
	for _, q := range [][2]string{{"'", "'"}, {"\u2018", "\u2019"}, {"\"", "\""}} {
		if i := strings.Index(rest, q[0]); i >= 0 {
			if j := strings.Index(rest[i+len(q[0]):], q[1]); j > 0 {
				return rest[i+len(q[0]) : i+len(q[0])+j], true
			}
		}
	}
	// Unquoted (BSD): the reason is the tail after the LAST ": ", so what
	// precedes it is the path — including paths that themselves contain ": ".
	if i := strings.LastIndex(rest, ": "); i > 0 {
		return strings.TrimSpace(rest[:i]), true
	}
	// A diagnostic we cannot pick a path out of is still a diagnostic: report
	// the whole message rather than silently dropping the fact that the walk
	// was short. Naming something is the requirement; naming nothing is the bug.
	return rest, true
}

// parseDuSize reads one du size IN THE UNIT DU WAS ASKED FOR. The unit is a
// parameter and not an inference because inferring it is exactly the bug: `du
// -k`'s "26214400" is a perfectly valid bare integer, and reading it as bytes
// silently reports 26 MB for 25 GiB — the direction that makes a full box look
// healthy.
//
// In duUnitHuman a bare number is legal ONLY below 1024. `du -h` humanizes at
// 1024, so it can print "512" but can never print "26214400"; a bare value at
// or above 1024 is therefore PROOF that -k output reached the -h path, and it
// is REFUSED rather than returned 1024x short.
//
// THE TRIPWIRE HAS A FLOOR, AND IT IS NOT THE DEFENCE. Below 1024 the two units
// are genuinely indistinguishable from the output alone: measured on a real
// tree, `du -kx -d1` prints "300/100/400" where `du -hx -d1` prints
// "300K/100K/400K", and nothing in those bytes says which flag produced them.
// A parser cannot close that gap; only knowing the flag can. So the UNIT
// PARAMETER is the defence — duTreeArgs hands the flag and the unit out
// together precisely so the parser is never guessing — and this check is a
// secondary tripwire for output that arrived from somewhere else. It catches
// every case where the error exceeds ~1 MB, which is the magnitude the axis
// exists to see (25 GiB rendering as 26 MB); it does not, and cannot, make the
// coupling optional.
func parseDuSize(s string, unit duUnit) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, errors.New("empty size")
	}
	switch unit {
	case duUnitKiB:
		// -k: a bare count of 1024-byte blocks. A suffix here means du was NOT
		// run with -k, and multiplying a humanized number by 1024 over-reports
		// by as much as the other direction under-reports.
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil || v < 0 {
			return 0, fmt.Errorf("du -k: want a bare 1024-block count, got %q", s)
		}
		return v * 1024, nil
	case duUnitHuman:
		if v, err := strconv.ParseInt(s, 10, 64); err == nil {
			if v < 0 {
				return 0, fmt.Errorf("negative size %q", s)
			}
			if v >= 1024 {
				return 0, fmt.Errorf("du -h: %q is an unsuffixed value >= 1024, which `du -h` "+
					"never prints — this is `du -k` output on the -h parse path, and reading it "+
					"as bytes under-reports by 1024x", s)
			}
			return v, nil
		}
		return parseHumanBytes(s)
	}
	return 0, fmt.Errorf("du: unknown unit %q", unit)
}

// humanUnits maps du/journalctl's single-letter suffixes to powers of 1024.
// Both tools report binary multiples (`du -h` 1K = 1024 bytes).
var humanUnits = map[byte]float64{
	'K': 1 << 10,
	'M': 1 << 20,
	'G': 1 << 30,
	'T': 1 << 40,
	'P': 1 << 50,
	'E': 1 << 60,
}

// parseHumanBytes reads "3.7G", "628M", "4.0K", "12B" or a bare byte count into
// bytes. An unsuffixed value is bytes; an unknown suffix is an error, never a
// silently-dropped magnitude — misreading "3.7G" as 3.7 would under-report the
// journal by a billion.
func parseHumanBytes(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, errors.New("empty size")
	}
	// Tolerate an "iB"/"B" suffix (some builds print 3.7GiB / 3.7GB).
	upper := strings.ToUpper(s)
	upper = strings.TrimSuffix(upper, "B")
	upper = strings.TrimSuffix(upper, "I")
	if upper == "" {
		return 0, fmt.Errorf("unparseable size %q", s)
	}
	last := upper[len(upper)-1]
	if mult, ok := humanUnits[last]; ok {
		v, err := strconv.ParseFloat(upper[:len(upper)-1], 64)
		if err != nil {
			return 0, fmt.Errorf("unparseable size %q", s)
		}
		if v < 0 {
			return 0, fmt.Errorf("negative size %q", s)
		}
		return int64(v*mult + 0.5), nil
	}
	v, err := strconv.ParseInt(upper, 10, 64)
	if err != nil || v < 0 {
		return 0, fmt.Errorf("unparseable size %q", s)
	}
	return v, nil
}

// --- the runaway-orphan probe ------------------------------------------------
//
// The 2026-08-06 guerrilla incident, in one line: an SSH session died and left
// `journalctl -u bp-site-build-* --since -14d --no-pager` reparented to PID 1,
// scanning fourteen days of journal for a unit glob that matched nothing, at
// 66.3% of a core, for 2h46m, on a box with two cores. The API flapped and the
// only thing that noticed was a human's `bp` write failing.
//
// The LIFETIME half of that lesson is already paid (runBounded above). This is
// the DETECTION half, and it is deliberately the cheapest possible instrument:
// one `ps` per beat, no state, no second cadence.

// runawayProbeTimeout bounds the `ps` shell-out. `ps -e` is a /proc walk of a
// few hundred entries — milliseconds — and a probe that hangs must degrade to
// the unmeasured sentinel rather than stall the beat behind it.
var runawayProbeTimeout = 5 * time.Second

// psRunawayArgs is the process-list argv, and it is a contract, not a taste:
//
//   - `-e` every process, so an orphan nobody owns is in scope.
//   - `-o ppid=,pid=,etimes=,pcpu=,args=` — the four fields the predicate needs
//     and nothing else. The trailing `=` on each suppresses the header, so the
//     parser never has to recognise and skip one.
//   - `args=` is LAST because it is the only field that can contain spaces; the
//     parser splits four times and keeps the remainder verbatim. Any other
//     order would make an argv with a space corrupt the numbers beside it.
//   - `etimes` (seconds) not `etime` (D-HH:MM:SS): a number, not a format.
//   - DIRECT argv, never `sh -c` and never a pipe to `grep`/`sort`. Under an
//     identical deadline a shell wrapper returns 44x late, because
//     exec.CommandContext kills only the direct child and CombinedOutput then
//     blocks in Wait on the orphaned grandchild's inherited stdout — and BOTH
//     paths report the same `signal: killed`, so the caller cannot tell the
//     bound was blown (D59, measured for duSitesArgs above). A probe for
//     runaway orphans that leaks a runaway orphan is not a joke worth risking.
func psRunawayArgs() []string {
	return []string{"-e", "-o", "ppid=,pid=,etimes=,pcpu=,args="}
}

// BackupMaxAge is how stale the newest backup artifact may be before the probe
// calls the backup FAILED. 26 hours = a daily backup plus a two-hour grace, so
// a cron that ran late is not reported as a broken backup and a cron that has
// not run since yesterday is.
const BackupMaxAge = 26 * time.Hour

// NewBackupProbe is the production BackupProbe: it reads ONE directory — the
// box's backup location — and answers what it actually found. It is the first
// backup probe this agent has ever had; before it, ReportConfig.BackupProbe was
// declared and wired NOWHERE, so every beat in the fleet carried the Go zero
// value `backup_ok:false` and a console had no way to know that "false" was the
// absence of a probe rather than the absence of a backup.
//
// It never returns a bare bool, and that is the point. The five answers:
//
//   - dir == "" or the dir does not exist → BackupStateUnconfigured. Nobody set
//     backups up on this box. That is a true statement and it is NOT "the
//     backup failed" — different sentence, different next action.
//   - the dir is unreadable → BackupStateError, with the error. The instrument
//     broke; the box's backup state is unknown and must be worded that way.
//   - the dir holds no regular file, or the newest one is 0 bytes →
//     BackupStateFailed. The location exists and the backup does not: a real,
//     measured failure.
//   - the newest artifact is older than BackupMaxAge → BackupStateFailed, and
//     the detail SAYS the age, because "stale" is the failure operators
//     actually hit and a bare "failed" would send them looking for a crash.
//   - otherwise → BackupStateOK with the artifact's name, age and size.
//
// The walk is one non-recursive ReadDir: no du, no shell-out, bounded by the
// entry count of a directory that holds dumps. Subdirectories are skipped
// rather than descended — a backup artifact is a file.
//
// @canonical capability:agent-backup-state aka:backup_ok,backup-tristate,BackupProbe,no backup probe wired,BackupState
func NewBackupProbe(dir string) func() (BackupState, string, error) {
	return func() (BackupState, string, error) {
		d := strings.TrimSpace(dir)
		if d == "" {
			return BackupStateUnconfigured, "no backup location configured on this box", nil
		}
		entries, err := os.ReadDir(d)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return BackupStateUnconfigured, fmt.Sprintf("no backup location on this box: %s does not exist", d), nil
			}
			return BackupStateError, "", fmt.Errorf("read backup dir %s: %w", d, err)
		}

		var (
			newestName string
			newestMod  time.Time
			newestSize int64
		)
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			info, err := e.Info()
			if err != nil {
				// A file that vanished mid-walk (a dump being rotated) is not
				// an instrument failure; skip it and judge the rest.
				continue
			}
			if !info.Mode().IsRegular() {
				continue
			}
			if newestName == "" || info.ModTime().After(newestMod) {
				newestName, newestMod, newestSize = e.Name(), info.ModTime(), info.Size()
			}
		}

		if newestName == "" {
			return BackupStateFailed, fmt.Sprintf("backup dir %s exists but holds no backup artifact", d), nil
		}
		if newestSize == 0 {
			return BackupStateFailed, fmt.Sprintf("newest backup %s in %s is 0 bytes", newestName, d), nil
		}
		age := time.Since(newestMod)
		if age > BackupMaxAge {
			return BackupStateFailed, fmt.Sprintf("newest backup %s in %s is %s old (limit %s)", newestName, d, age.Truncate(time.Minute), BackupMaxAge), nil
		}
		return BackupStateOK, fmt.Sprintf("newest backup %s in %s is %s old, %d bytes", newestName, d, age.Truncate(time.Minute), newestSize), nil
	}
}

// NewRunawayProbe builds the production RunawayProbe: one bounded `ps` per beat.
// Every failure path — no `ps`, a `ps` without `etimes`, a timeout, an
// unparseable table — returns an error, so Runaways stays nil (UNMEASURED)
// rather than landing an empty list that would read "this box is quiet".
func NewRunawayProbe() func() ([]RunawayProc, error) {
	return newRunawayProbeWith(boundedSpaceRunner(runawayProbeTimeout))
}

func newRunawayProbeWith(run probeRunner) func() ([]RunawayProc, error) {
	return func() ([]RunawayProc, error) {
		out, err := run(nil, "ps", psRunawayArgs()...)
		if err != nil {
			return nil, fmt.Errorf("ps: %w: %s", err, truncate(strings.TrimSpace(out), 120))
		}
		return parseRunaways(out)
	}
}

// parseRunaways turns `ps -e -o ppid=,pid=,etimes=,pcpu=,args=` output into the
// orphans that clear the predicate, worst first, capped at runawayTopLimit.
//
// It returns a NON-NIL EMPTY slice for a quiet box and an ERROR for output it
// could not read. Those must not be confused: a `ps` build that does not know
// `etimes` prints usage to stderr, and silently reading that as "no runaways"
// would make this instrument permanently, invisibly blind — the exact failure
// mode the field exists to remove. Empty output is an error too: `ps -e` always
// lists at least itself, so nothing at all means the command did not run.
//
// "Worst first" is by CPU-SECONDS ACTUALLY SPENT (elapsed x pcpu), not by
// either factor alone: a 90%-of-a-core process 31 minutes old has cost the box
// less than the incident's 66.3% over 2h46m, and the cap must keep the one an
// operator would kill first.
func parseRunaways(out string) ([]RunawayProc, error) {
	rows := []RunawayProc{}
	seen := 0
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		seen++
		// Four splits: ppid, pid, etimes, pcpu, then args VERBATIM (it may
		// contain any number of spaces, and it is the field we most need intact).
		fields := strings.Fields(line)
		if len(fields) < 5 {
			return nil, fmt.Errorf("ps: unparseable %q", truncate(line, 120))
		}
		ppid, errPP := strconv.Atoi(fields[0])
		pid, errP := strconv.Atoi(fields[1])
		elapsed, errE := strconv.Atoi(fields[2])
		cpu, errC := strconv.ParseFloat(fields[3], 64)
		if errPP != nil || errP != nil || errE != nil || errC != nil {
			return nil, fmt.Errorf("ps: unparseable %q", truncate(line, 120))
		}
		args := restAfterFields(line, 4)
		if args == "" {
			return nil, fmt.Errorf("ps: no command in %q", truncate(line, 120))
		}
		// THE PREDICATE, all three arms required. PPID 1 alone is every daemon
		// on the box; elapsed alone is every daemon that has been up a while;
		// a high lifetime average alone is a legitimate short burst.
		if ppid != 1 || elapsed < runawayMinElapsedS || cpu < runawayMinCPUPercent {
			continue
		}
		rows = append(rows, RunawayProc{
			PID:        pid,
			ElapsedS:   elapsed,
			CPUPercent: cpu,
			Command:    truncate(args, runawayCommandLimit),
		})
	}
	if seen == 0 {
		return nil, errors.New("ps: empty process list")
	}
	sort.SliceStable(rows, func(i, j int) bool {
		return float64(rows[i].ElapsedS)*rows[i].CPUPercent >
			float64(rows[j].ElapsedS)*rows[j].CPUPercent
	})
	if len(rows) > runawayTopLimit {
		rows = rows[:runawayTopLimit]
	}
	return rows, nil
}

// restAfterFields returns everything in line after the first n whitespace-
// separated fields, with the separating whitespace stripped and the remainder
// otherwise VERBATIM.
//
// It exists because the command is the only field that may contain spaces, so
// it cannot be recovered by rejoining strings.Fields output — `sh -c 'a  b'`
// would come back with its double space collapsed, and an operator comparing
// this string to what they see in `ps` would be looking at a different command.
// Splitting on the pcpu TOKEN instead (its first occurrence in the line) is the
// obvious shortcut and is wrong for the same reason a grep is: it assumes no
// earlier field can contain that byte sequence, which is a property of today's
// `ps` output, not of the format.
func restAfterFields(line string, n int) string {
	rest := line
	for i := 0; i < n; i++ {
		rest = strings.TrimLeft(rest, " \t")
		j := strings.IndexAny(rest, " \t")
		if j < 0 {
			return ""
		}
		rest = rest[j:]
	}
	return strings.TrimLeft(rest, " \t")
}

// --- slot / site UNIT STATE (dr-bl-w5-failed-slot-unit-is-invisible) ---------
//
// WHAT WAS MISSING, measured on guerrilla 2026-08-06 and again 2026-09-01: the
// box runs blue/green as two systemd template units and the beat carried NOT ONE
// BIT of their state. `systemctl is-active barkpark-slot@blue barkpark-slot@green`
// read `failed / active` — blue had died on an 8m30s stop-sigterm timeout and
// been SIGKILLed — and every operator surface said `ok`, because the verdict was
// computed from vitals alone and had no unit-state input at all. It was ACCIDENTALLY
// right (green was serving, so the box genuinely was serving) and would have said
// exactly the same thing with BOTH halves dead: a light that cannot go out.
//
// The beat now carries the unit facts themselves — never a verdict. Whether a
// failed half matters is the consumer's call, and it CANNOT be made from
// ActiveState alone:
//
//   - Result= separates a crash from a deliberate stop that systemd mislabels.
//     Measured 2026-09-01: barkpark-site@search__b is `failed` with
//     Result=exit-code, ExecMainStatus=143 — 128+15, i.e. Next.js exiting on the
//     SIGTERM of its own retire. PR #14863 adds SuccessExitStatus=143 to the unit
//     file for exactly this. Until it lands, a reader that treats `failed` as a
//     crash is reading a clean shutdown as an outage, so the exit status rides
//     WITH the result and neither is dropped.
//   - MainPID separates "the unit says active" from "a process is actually
//     there". An `active`/`exited` oneshot has MainPID 0.
//   - StateSince is systemd's own timestamp string, carried VERBATIM. An
//     operator's next question after "blue is failed" is "since when", and a
//     re-formatted timestamp is a second source of truth for a fact systemd
//     already states.
//
// A verdict built on this can finally distinguish the two cases the row names:
// half the pair failed while the OTHER half serves (still ok, say so in the
// detail), versus NEITHER half active while health claims up (a real
// contradiction, and previously unsayable).

// SlotUnit is ONE systemd unit's state as `systemctl show` reports it — the raw
// properties, never a derived verdict.
//
// Every string is systemd's own vocabulary verbatim (ActiveState
// active|inactive|failed|activating|deactivating; SubState running|dead|failed|…;
// Result success|exit-code|signal|timeout|oom-kill|…). Reproducing that
// vocabulary here as an enum would be a second, drifting copy of a contract the
// kernel of this design does not own.
type SlotUnit struct {
	// Unit is systemd's `Id=` — the full unit name including `.service`. It is
	// read back from the property block rather than echoed from the argv, so a
	// block that came back for a different unit than we asked about cannot be
	// mislabelled.
	Unit string `json:"unit"`
	// ActiveState / SubState / Result are systemd's three state axes. Result is
	// the one that separates a crash from a signal from a timeout, and it is
	// meaningless without ExecMainStatus (see the 143 case above).
	ActiveState string `json:"active_state"`
	SubState    string `json:"sub_state"`
	Result      string `json:"result"`
	// MainPID is systemd's `MainPID=`: 0 when no main process is running. It is
	// the difference between a unit that CLAIMS active and one that has a
	// process. -1 when the property was absent or unparseable — an unread pid is
	// not pid 0, which is a real, different fact.
	MainPID int64 `json:"main_pid"`
	// ExecMainStatus is the main process's last exit status (or signal number).
	// -1 when absent/unparseable, for the same reason MainPID is: a status we
	// could not read must never render as a clean 0.
	ExecMainStatus int `json:"exec_main_status"`
	// StateSince is systemd's own timestamp for the unit's last state change,
	// VERBATIM (e.g. "Tue 2026-09-01 11:07:52 UTC"). Empty when systemd has none
	// — a never-started unit reports empty timestamps, and an invented one would
	// be the fabrication the whole beat's honesty law forbids.
	StateSince string `json:"state_since"`
}

// slotUnitNames is the blue/green pair, asked for BY NAME on every beat. They
// are named rather than discovered so the pair is reported even when a half is
// `inactive`/`dead` — a discovery listing that only returns loaded-and-running
// units would report the healthy half and silently omit the dead one, which is
// the precise blindness this field exists to end.
var slotUnitNames = []string{"barkpark-slot@blue.service", "barkpark-slot@green.service"}

// slotUnitProps is the `systemctl show -p` property list. Id FIRST because it is
// what labels the block; the timestamps are three because systemd populates a
// different one depending on how the unit came to rest (see stateSince below).
const slotUnitProps = "Id,ActiveState,SubState,Result,MainPID,ExecMainStatus," +
	"StateChangeTimestamp,InactiveEnterTimestamp,ActiveEnterTimestamp"

// slotUnitsLimit caps the whole list. The blue/green pair is 2 of it and is
// NEVER dropped; the remainder is the failed `barkpark-site@*` units, and
// SlotUnitsTruncated reports how many the cap hid, so the short list says it is
// short (the same rule sitesTopLimit/SitesCount keep above). Six failed sites is
// already a story; the seventh does not change the operator's next action.
const slotUnitsLimit = 8

// siteUnitPattern is the spawned-site template. `--state=failed` does the
// filtering server-side, so a box with fifty healthy sites costs one line of
// output, not fifty.
const siteUnitPattern = "barkpark-site@*"

// slotUnitsProbeTimeout bounds each systemctl shell-out. Two short `systemctl`
// calls on a local dbus are milliseconds; a hung dbus must degrade to the
// unmeasured nil, never stall the beat behind it.
var slotUnitsProbeTimeout = 5 * time.Second

// NewSlotUnitsProbe builds the production probe: two bounded, DIRECT-argv
// `systemctl` calls per beat (no shell, no pipe — see psRunawayArgs for why
// that is a contract and not a taste).
//
// The FIRST call is the blue/green pair and its failure is the probe's failure:
// SlotUnits stays nil (UNMEASURED) rather than landing an empty list that would
// read "we looked at the pair and there is nothing to say". The SECOND call is
// the failed site units and it degrades independently — a `systemctl list-units`
// that errors costs the site rows, never the pair.
func NewSlotUnitsProbe() func() ([]SlotUnit, int, error) {
	return newSlotUnitsProbeWith(boundedSpaceRunner(slotUnitsProbeTimeout))
}

func newSlotUnitsProbeWith(run probeRunner) func() ([]SlotUnit, int, error) {
	return func() ([]SlotUnit, int, error) {
		args := append([]string{"show", "-p", slotUnitProps}, slotUnitNames...)
		out, err := run(nil, "systemctl", args...)
		if err != nil {
			return nil, -1, fmt.Errorf("systemctl show: %w: %s", err, truncate(strings.TrimSpace(out), 120))
		}
		units := parseSystemctlShow(out)
		if len(units) == 0 {
			// `systemctl show` prints a block even for a unit that does not
			// exist, so NOTHING parseable means the command did not really run
			// (no systemd, no dbus, a busybox `systemctl`). That is unmeasured.
			return nil, -1, fmt.Errorf("systemctl show: no unit block in %q", truncate(strings.TrimSpace(out), 120))
		}

		truncated := 0
		names, lerr := failedSiteUnitNames(run)
		if lerr == nil && len(names) > 0 {
			room := slotUnitsLimit - len(units)
			if room < 0 {
				room = 0
			}
			if len(names) > room {
				truncated = len(names) - room
				names = names[:room]
			}
			if len(names) > 0 {
				sargs := append([]string{"show", "-p", slotUnitProps}, names...)
				if sout, serr := run(nil, "systemctl", sargs...); serr == nil {
					units = append(units, parseSystemctlShow(sout)...)
				}
			}
		}
		return units, truncated, nil
	}
}

// failedSiteUnitNames lists the spawned-site units systemd currently calls
// FAILED, in systemd's own order. `--plain --no-legend --no-pager` strips the
// decorations so the first field of every line is a unit name and nothing else.
func failedSiteUnitNames(run probeRunner) ([]string, error) {
	out, err := run(nil, "systemctl", "list-units", siteUnitPattern,
		"--all", "--state=failed", "--plain", "--no-legend", "--no-pager")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if strings.HasSuffix(fields[0], ".service") {
			names = append(names, fields[0])
		}
	}
	return names, nil
}

// parseSystemctlShow turns `systemctl show -p A,B,C unit…` output into one
// SlotUnit per property BLOCK. Blocks are blank-line separated and properties
// arrive as `Key=Value` in an order systemd does not promise, so every block is
// read into a map and looked up by name — never by position.
//
// A block with no `Id=` is DROPPED: an unlabelled block cannot be attributed to
// a unit, and attributing it to the argv position would be a guess in exactly
// the place beam_slot already taught this tree not to guess.
func parseSystemctlShow(out string) []SlotUnit {
	var units []SlotUnit
	block := map[string]string{}
	flush := func() {
		if len(block) == 0 {
			return
		}
		if u, ok := slotUnitFrom(block); ok {
			units = append(units, u)
		}
		block = map[string]string{}
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		block[strings.TrimSpace(k)] = v
	}
	flush()
	return units
}

func slotUnitFrom(block map[string]string) (SlotUnit, bool) {
	id := strings.TrimSpace(block["Id"])
	if id == "" {
		return SlotUnit{}, false
	}
	return SlotUnit{
		Unit:           id,
		ActiveState:    strings.TrimSpace(block["ActiveState"]),
		SubState:       strings.TrimSpace(block["SubState"]),
		Result:         strings.TrimSpace(block["Result"]),
		MainPID:        parseUnitInt64(block["MainPID"]),
		ExecMainStatus: int(parseUnitInt64(block["ExecMainStatus"])),
		StateSince:     stateSince(block),
	}, true
}

// parseUnitInt64 reads a systemd numeric property, returning -1 for absent or
// unparseable. Never 0: an unread pid and pid 0 are different facts.
func parseUnitInt64(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// stateSince picks the timestamp that describes how the unit came to rest, in
// the order systemd actually populates them: StateChangeTimestamp is set for a
// unit that has changed state at all; a unit that fell out of active carries
// InactiveEnterTimestamp; a running one carries ActiveEnterTimestamp. All three
// are EMPTY on a unit that has never run since boot — measured on guerrilla for
// barkpark-slot@blue — and empty is carried through as empty.
func stateSince(block map[string]string) string {
	for _, k := range []string{"StateChangeTimestamp", "InactiveEnterTimestamp", "ActiveEnterTimestamp"} {
		if v := strings.TrimSpace(block[k]); v != "" {
			return v
		}
	}
	return ""
}
