package taskboard

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// livecorpus_test.go — THE GUARD (charter wave-9b, retuned for wave-11). It is
// DELIBERATELY real-corpus-shaped and now BuildBoard-DRIVEN (charter D55): the
// fixture is a Snapshot of authored task rows fed through the REAL BuildBoard, so
// the D49–D51 activity-focus policy is exercised end-to-end (a hand-built Board
// would bypass it). The corpus carries the pathologies wave-11 exists to fix:
//
//   - a MASS-CLOSE FLOOD: one active epic (auth) with 25 done children all <24h
//     old — the exact shape the user saw as a ✓ wall. It must fold to "+N done"
//     with only the ≤doneCueMax freshest as a dim cue (charter D50).
//   - TWO LIVE CLAIMS in NEIGHBORING subtrees of that one epic: the focus windows
//     MERGE into one neighborhood (both parents' context in one section block,
//     charter D51), and the epic ranks at the TOP (a live claim outranks recency,
//     D49).
//   - a DORMANT epic (all children long done, no events) that sinks near the
//     bottom and renders header+rollup ONLY.
//   - RECENCY SPREAD across the active/quiet epics so the top-down order is
//     unambiguous (Epics come back LastActivity desc, D49).
//   - the wave-10 invariants still hold: a NAMED-PHASE-BANDS epic (Spine/Studio/
//     Web CLI with a merged W3–4 range), a fully-CANCELLED tombstone epic, and
//     cluster/orphan cancelled folds — ZERO ✕ rows, cancelled only ever a fold
//     tail or the tombstone line.
//
// The golden captures the frame; the assertions pin what a golden alone would not
// (no READY TO CLAIM band, no done flood, recency order, the merged window, the
// server first-label + sacred "tasks" label). Rendered at the portrait widths
// where the defects lived (52/56/64/72).

var corpusFixedNow = time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)

// ctask is a compact fixture task builder (updated 2h ago by default).
func ctask(id, title, life, pri string) Task {
	return Task{DocID: id, Title: title, Lifecycle: life, Priority: pri, UpdatedAt: corpusFixedNow.Add(-2 * time.Hour)}
}

func withCrit(t Task, met, total int) Task  { t.Criteria = &Criteria{Met: met, Total: total}; return t }
func withParent(t Task, parent string) Task { t.ParentID = parent; return t }
func withLabels(t Task, ls ...string) Task  { t.Labels = ls; return t }

// withUpdated sets a task's last-movement time to `ago` before the fixed clock —
// the recency signal sectionActivity/LastActivity rank on (charter D49).
func withUpdated(t Task, ago time.Duration) Task { t.UpdatedAt = corpusFixedNow.Add(-ago); return t }

// withClaim turns a task into a LIVE in_progress claim `ago` before the fixed
// clock: BuildBoard lifts it into NOW and its owning subtree becomes the focus
// anchor (charter D51). The worker is non-empty so it passes the in_progress-only
// NOW guard (charter D53 — robust to expired claims).
func withClaim(t Task, worker string, ago time.Duration) Task {
	t.Lifecycle = lifeInProgress
	t.UpdatedAt = corpusFixedNow.Add(-ago)
	t.Claim = &Claim{Worker: worker, Epoch: 2, ClaimedAt: corpusFixedNow.Add(-ago)}
	return t
}

// corpusSnapshot authors the real-corpus-shaped guard as a Snapshot (charter
// D55): root goals + descendants with ParentID/Lifecycle/Priority/Labels/
// UpdatedAt/Claim, plus Events + Counts. Every test feeds it through BuildBoard,
// so the wave-11 policy is what the golden and assertions actually pin.
func corpusSnapshot() Snapshot {
	var tasks []Task
	add := func(ts ...Task) { tasks = append(tasks, ts...) }

	// ── Epic AUTH — ACTIVE, the MASS-CLOSE FLOOD + the MERGED WINDOW ────────────
	// Two live claims sit in neighboring subtrees (under auth-w1 and auth-w2, which
	// share the root auth), so their focus windows MERGE. 25 done children all <24h
	// old are the ✓-wall pathology: they must fold to "+N done", not render.
	add(withUpdated(ctask("auth", "Enterprise-ready auth - one layer, easy for everyone", lifeOpen, ""), 6*time.Hour))
	add(withUpdated(withParent(ctask("auth-w1", "W1 · Tenant-wide audit event bus", lifeOpen, "1"), "auth"), 3*time.Hour))
	add(withUpdated(withParent(ctask("auth-w2", "W2 · SSO / SAML enterprise connector", lifeOpen, "1"), "auth"), 3*time.Hour))
	add(withClaim(withParent(ctask("auth-w1-claim", "wire the append-only audit sink", "", "1"), "auth-w1"), "opus-3", 5*time.Minute))
	add(withClaim(withParent(ctask("auth-w2-claim", "map SAML group claims to roles", "", "1"), "auth-w2"), "fable-1", 8*time.Minute))
	add(withUpdated(withCrit(withParent(ctask("auth-w1-s1", "append-only event schema", lifeReady, "1"), "auth-w1"), 0, 3), 2*time.Hour))
	add(withUpdated(withCrit(withParent(ctask("auth-w1-s2", "retention window policy", lifeReady, "2"), "auth-w1"), 0, 2), 2*time.Hour))
	add(withUpdated(withParent(ctask("auth-w2-s1", "IdP metadata import", lifeReady, "2"), "auth-w2"), 2*time.Hour))
	for i := 0; i < 25; i++ {
		id := fmt.Sprintf("auth-done-%02d", i)
		title := fmt.Sprintf("closed connector slice %02d", i)
		add(withUpdated(withParent(ctask(id, title, lifeDone, ""), "auth"), time.Duration(60+i*20)*time.Minute)) // 1h..~9h — all <24h
	}

	// ── Epic UNIFIED — the wave-10 NAMED PHASE BANDS (explicitly expanded) ───────
	// Three ordered bands (Spine / Studio / Web CLI); the third spans W3.x/W4.x
	// titles so its derived code MERGES to "W3–4". One unphased child renders first;
	// a cancelled child yields the trailing "· 1 cancelled" tail (W10-B). Expanded
	// via CollapsedEpics so every band renders (the W10-A rollup guard).
	ph := func(id, title, life, pri, phase string, met, total int) Task {
		return withUpdated(withCrit(withLabels(withParent(ctask(id, title, life, pri), "unified"), labelPhasePrefix+phase), met, total), time.Hour)
	}
	add(withUpdated(ctask("unified", "Apply the cloud design profile to every surface", lifeOpen, "2"), time.Hour))
	add(withUpdated(withParent(ctask("u-scaffold", "living styleguide scaffold", lifeReady, "3"), "unified"), time.Hour)) // unphased → first
	add(ph("u-w12", "W1.2 · Build per-surface token emitters", lifeOpen, "1", "1-spine", 0, 4))
	add(ph("u-w13", "W1.3 · Unify status vocabulary", lifeOpen, "1", "1-spine", 0, 3))
	add(ph("u-w25", "W2.5 · Adopt generated tokens in Studio", lifeOpen, "2", "2-studio", 0, 0))
	add(ph("u-w26", "W2.6 · Sweep Studio literal colors", lifeOpen, "2", "2-studio", 0, 0))
	add(ph("u-w38", "W3.8 · Bridge web @theme to tokens", lifeOpen, "2", "3-web-cli", 0, 0))
	add(ph("u-w410", "W4.10 · Thread one canonical hex through Go", lifeOpen, "3", "3-web-cli", 0, 0))
	add(withParent(ctask("u-cancel", "abandoned adoption slice", lifeCancelled, ""), "unified"))

	// ── Epic PAPERS — INACTIVE but with a BLOCKED child (focus around the blocker) ─
	// Proves robustness: an epic with no live claim still shows a focus window when
	// it holds blocked work (a blocked kept child is a focus seed, charter D51).
	add(withUpdated(ctask("papers", "Paper components", lifeOpen, "1"), 3*time.Hour))
	add(withUpdated(withCrit(withParent(ctask("pc-resolver", "task-resolver -> live snapshot", lifeReady, "1"), "papers"), 2, 3), 3*time.Hour))
	add(withUpdated(withParent(ctask("pc-style", "styleguide gate - blocked on the resolver", lifeBlocked, "2"), "papers"), 4*time.Hour))
	add(withUpdated(withParent(ctask("pc-collect", "collect query targets", lifeDone, ""), "pc-resolver"), 3*time.Hour))

	// ── Epic DORMANT — all children long done, no events → header+rollup only, sinks ─
	add(withUpdated(ctask("dormant", "Legacy migration cleanup", lifeOpen, "4"), 20*24*time.Hour))
	add(withUpdated(withParent(ctask("dm1", "retire the old importer", lifeDone, ""), "dormant"), 20*24*time.Hour))
	add(withUpdated(withParent(ctask("dm2", "drop the v1 columns", lifeDone, ""), "dormant"), 21*24*time.Hour))

	// ── Dead epic (tombstone) — cancelled root → one dim line at the bottom (W10-B) ─
	add(withUpdated(ctask("dead", "Unified Aesthetic: one design language, every surface", lifeCancelled, ""), 5*24*time.Hour))
	add(withUpdated(withParent(ctask("dead-c1", "dead surface slice", lifeCancelled, ""), "dead"), 5*24*time.Hour))

	// ── Derived cluster (sheets-parity) with a folded cancelled member ──────────
	add(withUpdated(withCrit(withLabels(ctask("sp1", "SUM/AVG spill range", lifeReady, "2"), "proj:sheets-parity"), 1, 3), 2*time.Hour))
	add(withUpdated(withLabels(ctask("sp2", "cross-tab pivot header", lifeOpen, "3"), "proj:sheets-parity"), 2*time.Hour))
	add(withLabels(ctask("sp-cancel", "abandoned pivot engine", lifeCancelled, ""), "proj:sheets-parity"))
	add(withUpdated(withLabels(ctask("sp-done", "A:A whole-column ref", lifeDone, ""), "proj:sheets-parity"), 2*time.Hour))

	// ── Loose orphans — a blocked seed (focus window) + cancelled folds + a done ──
	add(withUpdated(ctask("orph-lint", "quality lint pass on the loose pile", lifeReady, "3"), 2*time.Hour))
	add(withUpdated(ctask("orph-blocked", "revisit the old migration path", lifeBlocked, "3"), 2*time.Hour))
	add(ctask("orph-cancel1", "abandoned loose task one", lifeCancelled, ""))
	add(ctask("orph-cancel2", "abandoned loose task two", lifeCancelled, ""))
	add(withUpdated(ctask("orph-done", "shipped loose task", lifeDone, ""), 2*time.Hour))

	// ── NEXT intent strip (charter wave-12) ─────────────────────────────────────
	// studio-user-login was claimed, the lease EXPIRED (worker cleared → open,
	// unclaimed), and NO later claim/close followed → a nextResume row, FIRST in
	// NEXT (the truest follow-up). orph-p0 is a P0 ready orphan → the ready head is
	// P0-first behind the resumable.
	add(withUpdated(ctask("studio-user-login", "wire the Studio user-login form", lifeOpen, "1"), 8*time.Minute))
	add(withUpdated(ctask("orph-p0", "urgent P0 ready fix", lifeReady, "0"), 30*time.Minute))

	events := []Event{
		{Mutation: "task.claimed", DocID: "auth-w1-claim", At: corpusFixedNow.Add(-5 * time.Minute)},
		{Mutation: "task.closed", DocID: "auth-done-00", At: corpusFixedNow.Add(-1 * time.Hour)},
		{Mutation: "task.lease_expired", DocID: "studio-user-login", At: corpusFixedNow.Add(-8 * time.Minute)},
	}
	counts := map[string]int{"in_progress": 2, "blocked": 2, "open": 21, "done": 30, "cancelled": 6}
	return Snapshot{Tasks: tasks, Events: events, Counts: counts, FetchedAt: corpusFixedNow.Add(-90 * time.Second)}
}

// corpusUIState pins the cursor on the first NOW card and EXPANDS the banded
// UNIFIED epic (explicit CollapsedEpics=false) so the W10-A named bands render in
// full for the golden — an explicit override always wins over the focus default
// (charter D54).
func corpusUIState() UIState {
	return UIState{
		Cursor:         0,
		Conn:           ConnLive,
		LastSync:       corpusFixedNow.Add(-90 * time.Second),
		Frame:          0,
		CollapsedEpics: map[string]bool{"unified": false},
	}
}

// TestLiveCorpusGolden is the eyeball golden: the whole real-corpus-shaped frame
// at each portrait width, built through the REAL BuildBoard against a full-URL
// server so D-A is exercised.
func TestLiveCorpusGolden(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "main", Server: "https://guerrilla.barkpark.cloud"}
	t.Cleanup(func() { Chrome = old })

	b := BuildBoard(corpusSnapshot(), RepoContext{}, corpusFixedNow)
	st := corpusUIState()
	for _, width := range []int{52, 56, 64, 72} {
		width := width
		t.Run(fmt.Sprintf("w%d", width), func(t *testing.T) {
			got := ansi.Strip(Render(b, st, width, 80, corpusFixedNow))
			path := filepath.Join("testdata", fmt.Sprintf("livecorpus_%d.txt", width))
			if *update {
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatalf("write golden: %v", err)
				}
				return
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read golden (run with -update): %v", err)
			}
			if got != string(want) {
				t.Errorf("live-corpus frame at %d cols diverged from %s\n--- got ---\n%s\n--- want ---\n%s",
					width, path, got, want)
			}
		})
	}
}

// bareBandRe matches an ORPHAN phase-band line: an indented, bare "W6" / "W2"
// with no leader and no rollup — the D-B defect. A legitimate row always carries
// a glyph before its text, so this can only match the retired bare band label.
var bareBandRe = regexp.MustCompile(`^\s+W\d+(?:[.\-–]\d+)?\s*$`)

// blankRowRe matches a row that is a glyph + selection marker but no title — the
// D-C blank-row defect ("○ ", "↳ ✓").
var blankRowRe = regexp.MustCompile(`^\s*(?:↳\s*)?[▎ ]?[○✓!✕⠋⠿]\s*$`)

// countDoneRowsPerSection counts the teal ✓ done ROWS between each section header
// and the next, so the ≤doneCueMax invariant can be checked per section.
func maxDoneRowsInAnySection(lines []string) int {
	most, cur := 0, 0
	inSection := false
	isHeader := func(ln string) bool {
		// A section header is a dotted-leader line (never a task row — task rows
		// carry a lifecycle glyph). The momentum bar and ticker have no " ·· ".
		return strings.Contains(ln, "··") && !strings.ContainsAny(ln, "○✓!⠋⠿↳")
	}
	flush := func() {
		if cur > most {
			most = cur
		}
		cur = 0
	}
	for _, ln := range lines {
		if isHeader(ln) {
			flush()
			inSection = true
			continue
		}
		if inSection && strings.ContainsRune(ln, '✓') {
			cur++
		}
	}
	flush()
	return most
}

// TestLiveCorpusInvariants pins the wave-9/10 invariants a golden alone would not
// catch, across the portrait widths, on the BuildBoard-driven corpus.
func TestLiveCorpusInvariants(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "main", Server: "https://guerrilla.barkpark.cloud"}
	t.Cleanup(func() { Chrome = old })

	b := BuildBoard(corpusSnapshot(), RepoContext{}, corpusFixedNow)
	st := corpusUIState()

	for _, width := range []int{40, 52, 56, 64, 72, 80} {
		frame := ansi.Strip(Render(b, st, width, 80, corpusFixedNow))
		lines := strings.Split(frame, "\n")
		header := lines[0]

		// D-A: the server is its first DNS label, never the FQDN/URL; the sacred
		// label "tasks" is always present in full.
		if strings.Contains(header, "guerrilla.barkpark.cloud") || strings.Contains(header, "://") {
			t.Errorf("w%d: header shows the full server, not its first DNS label: %q", width, header)
		}
		if !strings.Contains(header, "guerrilla") {
			t.Errorf("w%d: header lost the server label: %q", width, header)
		}
		if !strings.Contains(header, "tasks") {
			t.Errorf("w%d: the sacred label \"tasks\" was truncated out of the header: %q", width, header)
		}

		for i, ln := range lines {
			if w := ansi.StringWidth(ln); w > width {
				t.Errorf("w%d: line %d is %d cols (over budget): %q", width, i, w, ln)
			}
			if bareBandRe.MatchString(ln) {
				t.Errorf("w%d: bare phase-band orphan line %q (D-B regression)", width, ln)
			}
			if blankRowRe.MatchString(ln) {
				t.Errorf("w%d: blank glyph-only row %q (D-C regression)", width, ln)
			}
			// W10-B: cancelled work NEVER renders as a row (no ✕ glyph anywhere).
			if strings.ContainsRune(ln, '✕') {
				t.Errorf("w%d: a ✕ cancelled glyph rendered as a row %q (W10-B regression)", width, ln)
			}
		}

		// W10-A: the NAMED phase bands (in the explicitly-expanded UNIFIED epic)
		// carry an intact `Wcode · done/total` rollup, incl the merged "W3–4".
		for _, roll := range []string{"W1 · 0/2", "W2 · 0/2", "W3–4 · 0/2"} {
			if width >= 52 && !strings.Contains(frame, roll) {
				t.Errorf("w%d: phase-band rollup %q missing or truncated (W10-A regression)\n%s", width, roll, frame)
			}
		}
		for _, name := range []string{"Spine ", "Studio ", "Web CLI "} {
			if width >= 52 && !strings.Contains(frame, name) {
				t.Errorf("w%d: phase-band name %q missing (W10-A regression)\n%s", width, name, frame)
			}
		}

		// W10-B: the cancelled folds surface as a dim "cancelled" tail (never rows),
		// and the fully-cancelled epic is a single dim tombstone line.
		if !strings.Contains(frame, "cancelled") {
			t.Errorf("w%d: the cancelled fold tail / tombstone vanished (W10-B regression)\n%s", width, frame)
		}

		// The momentum % (line index 1) must be intact — meta reserved before the
		// title ellipsizes (D-D).
		if pct := regexp.MustCompile(`\d+%`).FindString(lines[1]); pct == "" {
			t.Errorf("w%d: momentum %% truncated off the line: %q (D-D regression)", width, lines[1])
		}
	}
}

// TestActivityFocus is the wave-11 guard (charter D49–D52): ONE list, recency
// order, done never floods, focus windows merge. It is teeth-checked: reverting
// any one policy breaks an assertion here (recorded in the slice completion note).
func TestActivityFocus(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "main", Server: "https://guerrilla.barkpark.cloud"}
	t.Cleanup(func() { Chrome = old })

	b := BuildBoard(corpusSnapshot(), RepoContext{}, corpusFixedNow)
	st := corpusUIState()

	// D49: sections rank by recency within a tier — board.Epics LastActivity is
	// non-increasing (the active auth epic, owning two claims, leads; dormant sinks
	// last). Reverting to epicFreshest(kept-only) drops the mass-close auth epic.
	for i := 1; i < len(b.Epics); i++ {
		if b.Epics[i-1].LastActivity.Before(b.Epics[i].LastActivity) {
			t.Errorf("epic order not recency-desc at %d: %q(%v) before %q(%v)",
				i, b.Epics[i-1].Root.Title, b.Epics[i-1].LastActivity, b.Epics[i].Root.Title, b.Epics[i].LastActivity)
		}
	}
	// The active auth epic ranks FIRST (a live claim always outranks recency, D49).
	if len(b.Epics) == 0 || b.Epics[0].Root.DocID != "auth" {
		t.Fatalf("the active mass-close epic must rank first, got %v", epicRootIDs(b.Epics))
	}

	// D50: the mass close folds — auth keeps only ≤doneCueMax done as a cue and
	// folds the rest (>=18), regardless of age. Reverting the age gate keeps them.
	auth := b.Epics[0]
	if auth.DoneFolded < 18 {
		t.Errorf("auth DoneFolded = %d, want >=18 (the mass-close flood must fold)", auth.DoneFolded)
	}
	doneKept := 0
	for _, c := range auth.Children {
		if isTerminal(c.Lifecycle) {
			doneKept++
		}
	}
	if doneKept > doneCueMax {
		t.Errorf("auth keeps %d done rows, want <=%d (the cue)", doneKept, doneCueMax)
	}

	// D49/D50 in the FRAME: no active section renders more than doneCueMax ✓ rows —
	// the auth ✓ wall is gone.
	for _, width := range []int{52, 72} {
		lines := strings.Split(ansi.Strip(Render(b, st, width, 80, corpusFixedNow)), "\n")
		if n := maxDoneRowsInAnySection(lines); n > doneCueMax {
			t.Errorf("w%d: a section rendered %d done rows, want <=%d (the ✓ wall must not return)", width, n, doneCueMax)
		}
	}

	// D52: NO READY TO CLAIM band anywhere — ONE list. Checked on BOTH the claimed
	// corpus AND an empty-NOW variant (all claims dropped to ready): the retired
	// band only ever surfaced on an empty NOW, so the empty-NOW render is where a
	// D52 regression bites. The empty-NOW board reads the calm all-clear instead.
	noClaims := corpusSnapshot()
	for i := range noClaims.Tasks {
		if noClaims.Tasks[i].Claim != nil {
			noClaims.Tasks[i].Claim = nil
			noClaims.Tasks[i].Lifecycle = lifeReady
		}
	}
	emptyNow := BuildBoard(noClaims, RepoContext{}, corpusFixedNow)
	if len(emptyNow.Now) != 0 {
		t.Fatalf("empty-NOW variant still has %d claims", len(emptyNow.Now))
	}
	for _, tc := range []struct {
		name  string
		board Board
	}{{"claimed", b}, {"empty-now", emptyNow}} {
		for _, width := range []int{52, 56, 64, 72} {
			frame := ansi.Strip(Render(tc.board, st, width, 80, corpusFixedNow))
			if strings.Contains(frame, "READY TO CLAIM") {
				t.Errorf("%s w%d: the retired READY TO CLAIM band reappeared:\n%s", tc.name, width, frame)
			}
		}
	}
	// With NOW empty the WHO band collapses, but the INTENT strip still surfaces
	// what to pick up next (charter wave-12): the resumable + the ready head. The
	// board is never a dead-end all-clear when there IS follow-up work.
	if f := ansi.Strip(Render(emptyNow, st, 72, 80, corpusFixedNow)); !strings.Contains(f, "NEXT") {
		t.Errorf("empty-NOW board did not surface the NEXT intent strip:\n%s", f)
	}

	// D51: the merged window — BOTH claims' parents (auth-w1, auth-w2) are in the
	// auth epic's focus set (one neighborhood, not two lists). Reverting to
	// head-of-5 would not guarantee both parents' context.
	if !auth.FocusSet["auth-w1"] || !auth.FocusSet["auth-w2"] {
		t.Errorf("auth focus window did not MERGE both claims' parent context: %v", auth.FocusSet)
	}
	// Both parent rows appear in the SAME contiguous section block in the frame.
	frame := ansi.Strip(Render(b, st, 72, 80, corpusFixedNow))
	if !strings.Contains(frame, "Tenant-wide audit event bus") || !strings.Contains(frame, "SSO / SAML enterprise connector") {
		t.Errorf("the merged auth window did not render both parents' context:\n%s", frame)
	}

	// D51: the dormant epic renders header+rollup ONLY (no child rows) and sinks to
	// the bottom of the epic tier.
	dormant := findEpic(t, b.Epics, "dormant")
	if len(dormant.FocusSet) != 0 {
		t.Errorf("dormant epic should have an empty focus set (header-only), got %v", dormant.FocusSet)
	}
	if b.Epics[len(b.Epics)-1].Root.DocID != "dormant" {
		t.Errorf("dormant epic should sink last in the epic tier, got %v", epicRootIDs(b.Epics))
	}
}
