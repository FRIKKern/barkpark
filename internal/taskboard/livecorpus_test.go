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

// livecorpus_test.go — THE GUARD (charter wave-9b). Wave 9 shipped broken on the
// live guerrilla corpus because its goldens used CURATED fixtures that already
// resembled the mockup: the real corpus (many epics, a full-FQDN server, W-code-
// only "phases", empty titles, narrow portrait) rendered wrong while the tests
// stayed green. This fixture is DELIBERATELY real-corpus-shaped — 8 epics (one a
// clean W1/W2/W6 multi-phase decomposition, one with 30+ children, one the
// wave-10 NAMED-PHASE-BANDS epic (Spine/Studio/Web-CLI with a merged W3–4 range +
// an unphased-first child + a done·cancelled tail), one a fully-CANCELLED
// tombstone, several with names long enough to force ellipsis), a derived cluster
// (with a folded cancelled member), loose orphans (with folded cancelled), a
// pinned NOW claim, empty-title tasks, and a full-URL server — rendered at the
// portrait widths where the defects lived (52/56/64/72). It is the regression
// guard for D-A..D-E AND wave-10 W10-A/B: the golden captures the calm mockup
// look, and the assertions pin the invariants a golden alone would not (server =
// first DNS label, "tasks" never truncates, no bare phase-band line, no blank
// row, ZERO ✕ cancelled rows, and the section rollup / momentum % NEVER truncate
// — meta is reserved before the title ellipsizes).

var corpusFixedNow = time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)

// ctask is a compact fixture task builder.
func ctask(id, title, life, pri string) Task {
	return Task{DocID: id, Title: title, Lifecycle: life, Priority: pri, UpdatedAt: corpusFixedNow.Add(-2 * time.Hour)}
}

func withCrit(t Task, met, total int) Task  { t.Criteria = &Criteria{Met: met, Total: total}; return t }
func withParent(t Task, parent string) Task { t.ParentID = parent; return t }
func withLabels(t Task, ls ...string) Task  { t.Labels = ls; return t }

// corpusBoard builds the real-corpus-shaped guard board (see file header).
func corpusBoard() Board {
	// Epic 1 — long name; a CLEAN multi-phase decomposition (W1/W2/W6, ≥2 each);
	// Active so it shows every child. Rows keep their natural "W# ·" titles — with
	// wave-9b there is NO within-epic sub-band, so no bare "W6" line and no doubled
	// phase indicator.
	auth := Epic{
		Root:   ctask("auth", "Enterprise-ready auth - one layer, easy for everyone", lifeReady, "1"),
		Active: true,
		Children: []Task{
			withCrit(ctask("w1a", "W1 · Append-only tenant-wide audit event bus", lifeReady, "1"), 0, 4),
			withCrit(ctask("w1b", "W1 · Org-admin shell + thin Organization tier", lifeReady, "2"), 0, 3),
			withCrit(ctask("w2a", "W2 · First-class passwordless magic-link", lifeReady, "3"), 0, 3),
			withCrit(ctask("w2b", "W2 · SSO / SAML enterprise connector", lifeOpen, "3"), 0, 2),
			withCrit(ctask("w6a", "W6 · DPA template + support tiers", lifeReady, "4"), 0, 2),
			withCrit(ctask("w6b", "W6 · Backup/DR with a proven restore drill", lifeOpen, "3"), 0, 3),
		},
		DoneFolded: 2,
	}

	// Epic 2 — 30+ children, NOT active → head-capped to a glanceable few + a
	// "+N more" fold. Long name forces the header title to ellipsize before its
	// rollup, which must survive whole.
	big := Epic{
		Root: ctask("aesthetic", "Aesthetic Unification - apply the new cloud profile to EVERY surface", lifeReady, "3"),
	}
	for i := 0; i < 32; i++ {
		life := lifeReady
		if i%3 == 0 {
			life = lifeOpen
		}
		big.Children = append(big.Children, ctask(fmt.Sprintf("au%02d", i), fmt.Sprintf("W5.%d Component surface adoption slice %d", i%9, i), life, "3"))
	}
	big.DoneFolded = 6

	// Epic 3 — root carries an explicit phase code (phase:W0), so the header rollup
	// reads "W0 · 2/2" (the mockup's Token-spine line). All done.
	tokens := Epic{
		Root: withLabels(ctask("tokens", "Token spine", lifeDone, ""), labelPhasePrefix+"W0"),
		Children: []Task{
			withCrit(ctask("tok1", "tokens.json - single source of truth", lifeDone, ""), 2, 2),
			withCrit(ctask("tok2", "design/check drift gate", lifeDone, ""), 3, 3),
		},
	}

	// Epic 4 — a blocked child (amber "! blocked" badge), an arbitrary-depth ↳
	// nested subtask, and an EMPTY-TITLE child (D-C: renders a dim placeholder, not
	// a blank row). Root phase:W5.
	papers := Epic{
		Root: withLabels(ctask("papers", "Paper Components", lifeReady, "1"), labelPhasePrefix+"W5"),
		Children: []Task{
			withCrit(ctask("pc-resolver", "task-resolver -> live snapshot", lifeReady, "1"), 2, 3),
			withCrit(withParent(ctask("pc-collect", "collect query targets", lifeDone, ""), "pc-resolver"), 1, 1),
			ctask("pc-style", "styleguide + gate", lifeBlocked, "2"),
			ctask("pc-empty-9f2a3b", "", lifeReady, "3"), // empty title → dim short-id placeholder
		},
	}

	// Epic 5 — short name, all children long-since done → one folded "+9 done" line;
	// rollup "9/9".
	fleet := Epic{
		Root:       ctask("fleet", "Cloud fleet lifecycle admin", lifeDone, ""),
		DoneFolded: 9,
	}

	// Epic 6 — a small, calm epic to keep the count at 6 and exercise a plain
	// no-code rollup.
	doey := Epic{
		Root:     ctask("doey", "Doey-grade reading polish", lifeReady, "2"),
		Children: []Task{withCrit(ctask("doey1", "hybrid timestamps everywhere", lifeReady, "3"), 0, 2)},
	}

	// Epic 7 — the wave-10 NAMED PHASE BANDS (W10-A). Children carry
	// phase:<n>-<slug> labels forming three ordered bands (Spine / Studio /
	// Web CLI); the third band's members span W3.x and W4.x titles, so its derived
	// code MERGES to the "W3–4" range. One unphased ready child exercises the
	// "unphased first" rule (renders directly under the epic header, before any
	// band); DoneFolded + CancelledFolded exercise the trailing
	// "+N done · M cancelled" tail (W10-B). Active → every band shown in full
	// (stable golden; the per-band head cap is unit-tested separately).
	ph := func(id, title, life, pri, phase string, met, total int) Task {
		return withCrit(withLabels(ctask(id, title, life, pri), labelPhasePrefix+phase), met, total)
	}
	unified := Epic{
		Root:   ctask("unified", "Apply the cloud design profile to every surface", lifeOpen, "2"),
		Active: true,
		Children: []Task{
			ctask("u-scaffold", "living styleguide scaffold", lifeReady, "3"), // unphased → first
			ph("u-w12", "W1.2 · Build per-surface token emitters", lifeOpen, "1", "1-spine", 0, 4),
			ph("u-w13", "W1.3 · Unify status vocabulary", lifeOpen, "1", "1-spine", 0, 3),
			ph("u-w25", "W2.5 · Adopt generated tokens in Studio", lifeOpen, "2", "2-studio", 0, 0),
			ph("u-w26", "W2.6 · Sweep Studio literal colors", lifeOpen, "2", "2-studio", 0, 0),
			ph("u-w38", "W3.8 · Bridge web @theme to tokens", lifeOpen, "2", "3-web-cli", 0, 0),
			ph("u-w410", "W4.10 · Thread one canonical hex through Go", lifeOpen, "3", "3-web-cli", 0, 0),
		},
		DoneFolded:      2, // the unphased component fleet, long done → folded
		CancelledFolded: 1, // one abandoned slice → "· 1 cancelled"
	}

	// A fully-CANCELLED epic (W10-B): the root itself is cancelled, so the whole
	// section collapses to ONE dim tombstone line at the BOTTOM of the board — its
	// seven dead children never render as rows.
	dead := Epic{
		Root:            ctask("dead-ua", "Unified Aesthetic: one design language, every surface", lifeCancelled, ""),
		CancelledFolded: 7,
	}

	// A derived cluster (dim title + "~") and loose orphans, including an empty-
	// title orphan and a 9-day-stale open row (amber stale badge). The cluster
	// carries one cancelled member (folded → "· 1 cancelled" tail, W10-B).
	sheets := Cluster{
		Key: "proj:sheets-parity",
		Tasks: []Task{
			withCrit(ctask("sp1", "SUM/AVG spill range", lifeReady, "2"), 1, 3),
			ctask("sp2", "cross-tab pivot header", lifeOpen, "3"),
			withCrit(ctask("sp3", "A:A whole-column ref", lifeDone, ""), 4, 4),
		},
		CancelledFolded: 1,
	}

	stale := ctask("orph-stale", "revisit the old migration path", lifeOpen, "4")
	stale.UpdatedAt = corpusFixedNow.Add(-9 * 24 * time.Hour)
	orphans := []Task{
		ctask("orph-lint", "quality lint pass on the loose pile", lifeReady, "3"),
		ctask("orph-empty-4c1d", "", lifeOpen, ""), // empty-title orphan → placeholder
		stale,
	}

	// One pinned NOW claim so the momentum "in flight" count and the two-line
	// claim card render (the spinner rides Frame, held at 0 = ⠋ steady).
	claim := ctask("now-inject", "inject snapshot into render opts", lifeInProgress, "2")
	claim.Claim = &Claim{Worker: "opus-3", Epoch: 2, ClaimedAt: corpusFixedNow.Add(-4 * time.Minute)}
	claim.Criteria = &Criteria{Met: 1, Total: 2}

	return Board{
		Now:                    []Task{claim},
		Epics:                  []Epic{auth, big, tokens, papers, unified, fleet, doey, dead},
		Clusters:               []Cluster{sheets},
		Orphans:                orphans,
		OrphansFolded:          5,
		OrphansCancelledFolded: 2, // two abandoned loose tasks → "· 2 cancelled"
		Stale:                  3,
		// "cancelled": 10 rides the summed Counts so the momentum % must EXCLUDE it
		// (W10-B): 100 done / (150 non-cancelled) = 67%, never 100/160 = 63%.
		Counts: map[string]int{"in_progress": 1, "blocked": 2, "open": 47, "done": 100, "cancelled": 10},
	}
}

func corpusUIState() UIState {
	return UIState{
		Cursor:   0, // the pinned NOW card
		Conn:     ConnLive,
		LastSync: corpusFixedNow.Add(-90 * time.Second),
		Frame:    0,
	}
}

// TestLiveCorpusGolden is the eyeball golden: the whole real-corpus-shaped frame
// at each portrait width, rendered against a full-URL server so D-A is exercised.
func TestLiveCorpusGolden(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "main", Server: "https://guerrilla.barkpark.cloud"}
	t.Cleanup(func() { Chrome = old })

	b := corpusBoard()
	st := corpusUIState()
	for _, width := range []int{52, 56, 64, 72} {
		width := width
		t.Run(fmt.Sprintf("w%d", width), func(t *testing.T) {
			got := ansi.Strip(Render(b, st, width, 72, corpusFixedNow))
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
// a glyph (○ / ✓ / ! / ⠋ / ✕) before its text, so this can only match the retired
// bare band label.
var bareBandRe = regexp.MustCompile(`^\s+W\d+(?:[.\-–]\d+)?\s*$`)

// blankRowRe matches a row that is a glyph + selection marker but no title — the
// D-C blank-row defect ("○ ", "↳ ✓").
var blankRowRe = regexp.MustCompile(`^\s*(?:↳\s*)?[▎ ]?[○✓!✕⠋⠿]\s*$`)

// TestLiveCorpusInvariants pins the D-A..D-E invariants a golden alone would not
// catch, across the portrait widths.
func TestLiveCorpusInvariants(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "main", Server: "https://guerrilla.barkpark.cloud"}
	t.Cleanup(func() { Chrome = old })

	b := corpusBoard()
	st := corpusUIState()

	for _, width := range []int{40, 52, 56, 64, 72, 80} {
		frame := ansi.Strip(Render(b, st, width, 72, corpusFixedNow))
		lines := strings.Split(frame, "\n")
		header := lines[0]

		// D-A: the server is its first DNS label, never the FQDN/URL, and never a
		// scheme; the primary label "tasks" is always present in full.
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
			// runewidth-safety: no line exceeds the pane.
			if w := ansi.StringWidth(ln); w > width {
				t.Errorf("w%d: line %d is %d cols (over budget): %q", width, i, w, ln)
			}
			// D-B: no bare orphan phase-band line survives.
			if bareBandRe.MatchString(ln) {
				t.Errorf("w%d: bare phase-band orphan line %q (D-B regression)", width, ln)
			}
			// D-C: no glyph-only blank row.
			if blankRowRe.MatchString(ln) {
				t.Errorf("w%d: blank glyph-only row %q (D-C regression)", width, ln)
			}
			// W10-B: cancelled work NEVER renders as a row anywhere — not a ✕ glyph,
			// not a dead epic's children. The only place "cancelled" may appear is a
			// dim fold tail or the tombstone line (neither carries the ✕ glyph).
			if strings.ContainsRune(ln, '✕') {
				t.Errorf("w%d: a ✕ cancelled glyph rendered as a row %q (W10-B regression)", width, ln)
			}
		}

		// W10-A: the NAMED phase bands carry an intact `Wcode · done/total` rollup,
		// including the merged "W3–4" range — and, like the section rollups, it is
		// reserved before the band NAME ellipsizes (never truncated at these widths).
		for _, roll := range []string{"W1 · 0/2", "W2 · 0/2", "W3–4 · 0/2"} {
			if width >= 52 && !strings.Contains(frame, roll) {
				t.Errorf("w%d: phase-band rollup %q missing or truncated (W10-A regression)\n%s", width, roll, frame)
			}
		}
		// W10-A: the derived band NAMES are present (title-cased slug, acronym
		// allowlist upper-cases CLI).
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

		// D-D: the section rollup done/total and the momentum % must NEVER be
		// truncated — meta is reserved before the title/name ellipsizes. At these
		// widths the fixture's rollups and % are all present and intact.
		for _, roll := range []string{"9/9", "W0 · 2/2", "6/38", "W5 · 1/4"} {
			if width >= 52 && !strings.Contains(frame, roll) {
				t.Errorf("w%d: rollup %q missing or truncated (D-D regression)\n%s", width, roll, frame)
			}
		}
		// The momentum % is on line 1 (0-based index 1) and must be intact.
		if pct := regexp.MustCompile(`\d+%`).FindString(lines[1]); pct == "" {
			t.Errorf("w%d: momentum %% truncated off the line: %q (D-D regression)", width, lines[1])
		}
	}
}
