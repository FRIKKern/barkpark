package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// ─── THE OUT-OF-ROW PIN (task-f7b781a0bcd7f70b) ─────────────────────────────
//
// THE DEFECT THESE DETECTORS CLOSE, stated once: on a row whose criteria are
// distinct, an off-by-one stamp scripted in the observed shape — `--criterion i`
// with `--criterion-text crit[i].criterion` READ FROM THE ROW — is wire-identical
// to a correct stamp of index i. TestTaskStampExecute_RotatedIndicesOnDistinct-
// CriteriaStillSilent (tasks_stamp_cmd_test.go) proves all four rotations of a
// four-criterion row exit 0 with one POST and no diagnostic, and it still does,
// because the pin is OPT-IN. The tests below prove that the SAME rotations, with
// an author-typed pin, are refused before anything is sent.
//
// Every detector here names the line it dies on:
//   - RotatedIndicesRefusedWhenPinned  → stampPinIndexProblem's comparison
//   - PinPrefixMismatchRefused         → stampPinTextProblem's pinMatchesCriterion
//   - PinMisalignmentCaughtByReadback  → the req.pin arm of stampMismatches
//   - AlignedPinPasses / PinNeverRidesTheWire → the CONTROLS: a guard that
//     refused everything, or one that leaked its flag to the server, would red
//     here and nowhere else.

// stampPinTestServer is a fake Barkpark whose GET serves a criteria list the
// test controls, counting POSTs and recording the query the stamp actually sent.
// When `rotateAfterPost` is set the criteria list ROTATES LEFT by one the moment
// the stamp lands — the row-moved-under-the-write race that the pre-check
// structurally cannot see and only the read-back can.
func stampPinTestServer(t *testing.T, criteria []string, rotateAfterPost bool) (*int32, *url.Values) {
	t.Helper()
	var hits int32
	var mu sync.Mutex
	live := append([]string(nil), criteria...)
	wrote := map[int]string{}
	lastPost := &url.Values{}
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp"):
			atomic.AddInt32(&hits, 1)
			q := stampMergedParams(r)
			mu.Lock()
			*lastPost = q
			if idx, err := strconv.Atoi(q.Get("criterion")); err == nil {
				wrote[idx] = q.Get("evidence")
			}
			if rotateAfterPost && len(live) > 1 {
				live = append(live[1:], live[0])
			}
			mu.Unlock()
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			mu.Lock()
			rows := make([]map[string]any, len(live))
			for i, c := range live {
				ev, ok := wrote[i]
				rows[i] = map[string]any{"criterion": c, "met": ok, "evidence": ev}
			}
			mu.Unlock()
			body, _ := json.Marshal(map[string]any{
				"ok":  true,
				"doc": map[string]any{"content": map[string]any{"acceptance_criteria": rows}},
			})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-stub")
	return &hits, lastPost
}

// pinFor renders the author's pin for a criterion: the first words they would
// have copied out of their plan, NOT the string the script reads off the row.
func pinFor(index int, criterion string) string {
	words := strings.Fields(criterion)
	if len(words) > 5 {
		words = words[:5]
	}
	return strconv.Itoa(index) + ":" + strings.Join(words, " ")
}

// THE NEGATIVE ARM the row names. This is TestTaskStampExecute_RotatedIndices-
// OnDistinctCriteriaStillSilent's exact loop — the observed shape, where both
// --criterion and --criterion-text come from the same (wrong) index and are
// therefore self-consistent — with ONE value added that the row cannot supply:
// the author's pin for the criterion they MEANT. Every rotation that exits 0
// silently today is refused, with nothing sent.
func TestTaskStampExecute_RotatedIndicesRefusedWhenPinned(t *testing.T) {
	for i := range fourDistinctCriteria {
		rotated := (i + 1) % len(fourDistinctCriteria)
		hits, _ := stampPinTestServer(t, fourDistinctCriteria, false)
		out, code := captureExecuteCode(t, []string{
			"task", "stamp", "bp-task-x", "w", "1",
			"--criterion", strconv.Itoa(rotated), "--met",
			"--evidence", "proof for criterion " + strconv.Itoa(i),
			// Read from the SAME wrong index — the pair the guard cannot tell
			// apart from a correct one.
			"--criterion-text", fourDistinctCriteria[rotated],
			// Authored BEFORE the row was read, for the criterion the author meant.
			"--expect", pinFor(i, fourDistinctCriteria[i]),
		})
		if code != exitValidation {
			t.Fatalf("rotation %d→%d: exit = %d, want exitValidation (%d); out:\n%s", i, rotated, code, exitValidation, out)
		}
		if n := atomic.LoadInt32(hits); n != 0 {
			t.Fatalf("rotation %d→%d: stamp POST fired %d times; a pin that disagrees with --criterion must be refused BEFORE sending", i, rotated, n)
		}
		// The refusal must name BOTH indices in BOTH bases, or the operator
		// cannot tell which half to fix.
		for _, want := range []string{
			"index " + strconv.Itoa(i), "index " + strconv.Itoa(rotated),
			"#" + strconv.Itoa(i+1), "#" + strconv.Itoa(rotated+1),
		} {
			if !strings.Contains(out, want) {
				t.Errorf("rotation %d→%d: refusal does not name %q; got:\n%s", i, rotated, want, out)
			}
		}
	}
}

// THE COVERAGE-UNCHANGED CONTROL. An aligned pin changes nothing: the stamp
// goes through, one POST, exit 0. A guard that refused everything — the shape
// that makes the arm above pass for the wrong reason — reds here.
func TestTaskStampExecute_AlignedPinPasses(t *testing.T) {
	hits, _ := stampPinTestServer(t, fourDistinctCriteria, false)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "e",
		"--criterion-text", fourDistinctCriteria[2],
		"--expect", pinFor(2, fourDistinctCriteria[2]),
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1; out:\n%s", n, out)
	}
}

// THE FLAG NEVER REACHES THE SERVER. The pin is client-side and undeclarable;
// if it were forwarded, splitArgs would refuse it as an unknown flag against
// every real server. This asserts on the WIRE, not on the exit code, because an
// exit 0 against a fake that ignores unknown params would hide it.
func TestTaskStampExecute_PinNeverRidesTheWire(t *testing.T) {
	for _, spelling := range [][]string{
		{"--expect", pinFor(2, fourDistinctCriteria[2])},
		{"--expect=" + pinFor(2, fourDistinctCriteria[2])},
	} {
		t.Run(spelling[0], func(t *testing.T) {
			hits, last := stampPinTestServer(t, fourDistinctCriteria, false)
			args := append([]string{
				"task", "stamp", "bp-task-x", "w", "1",
				"--criterion", "2", "--met", "--evidence", "e",
				"--criterion-text", fourDistinctCriteria[2],
			}, spelling...)
			out, code := captureExecuteCode(t, args)
			if code != exitOK {
				t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
			}
			if n := atomic.LoadInt32(hits); n != 1 {
				t.Fatalf("stamp POST fired %d times, want 1", n)
			}
			for k := range *last {
				if strings.Contains(k, "expect") {
					t.Fatalf("the POST carried %q — the pin is client-side and must be stripped from the forwarded tail", k)
				}
			}
			// The value token must not have bound as a positional either.
			if got := last.Get("criterion"); got != "2" {
				t.Fatalf("criterion on the wire = %q, want \"2\" — the pin's value token was mis-parsed", got)
			}
		})
	}
}

// THE ROW MOVED SINCE THE PIN WAS WRITTEN. Index agrees; the wording at that
// index does not. Refused before the POST, with BOTH texts printed — the pin
// and the stored wording — because the operator cannot tell which one is stale
// without seeing them side by side.
func TestTaskStampExecute_PinPrefixMismatchRefused(t *testing.T) {
	hits, _ := stampPinTestServer(t, fourDistinctCriteria, false)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "1", "--met", "--evidence", "e",
		"--criterion-text", fourDistinctCriteria[1],
		"--expect", "1:THE CENSUS IS RE-RUN",
	})
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("stamp POST fired %d times; a pin whose wording does not match must be refused BEFORE sending", n)
	}
	for _, want := range []string{"THE CENSUS IS RE-RUN", fourDistinctCriteria[1]} {
		if !strings.Contains(out, want) {
			t.Errorf("refusal does not print %q; got:\n%s", want, out)
		}
	}
}

// THE READ-BACK CHECKS ALIGNMENT, NOT SUCCESS. The pre-check passes — at the
// moment it looked, index 2 was the criterion the author pinned — and then the
// list ROTATES as the stamp lands, so the evidence sits on a criterion nobody
// named. The write succeeded; the POST answered 2xx; the row holds met and the
// evidence exactly as sent. Only an alignment-keyed read-back can see it, and a
// read-back that asked "did the write land" would print a ✓ here.
func TestTaskStampExecute_PinMisalignmentCaughtByReadback(t *testing.T) {
	hits, _ := stampPinTestServer(t, fourDistinctCriteria, true)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "e",
		"--expect", pinFor(2, fourDistinctCriteria[2]),
	})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — the read-back must refuse a stamp that landed on an unpinned criterion; out:\n%s", code, exitConflict, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1 — the write DID happen; it is the alignment that failed", n)
	}
	// Both texts: what was pinned, and what the store actually holds there.
	for _, want := range []string{"the read-back renders", "the census is re-run"} {
		if !strings.Contains(out, want) {
			t.Errorf("the read-back verdict does not print %q; got:\n%s", want, out)
		}
	}
}

// AN UNCHECKED PIN IS NOT A MET ONE. The caller asked for the expectation to be
// checked and the store could not be read, so nothing is sent. This is the one
// place the pin differs from the discrimination pre-check, which is advisory on
// a failed read — that one is layered on a server guard that still runs; this
// one is the only thing that can catch its defect.
func TestTaskStampExecute_PinUnreadableStoreRefused(t *testing.T) {
	var hits int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			atomic.AddInt32(&hits, 1)
			_, _ = w.Write([]byte(`{"ok":true}`))
			return
		}
		http.Error(w, `{"ok":false,"error":{"code":"boom"}}`, http.StatusInternalServerError)
	}))
	t.Cleanup(backend.Close)
	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-stub")

	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "e",
		"--criterion-text", fourDistinctCriteria[2],
		"--expect", pinFor(2, fourDistinctCriteria[2]),
	})
	if code == exitOK {
		t.Fatalf("exit = 0 on a pin that could not be checked; out:\n%s", out)
	}
	if n := atomic.LoadInt32(&hits); n != 0 {
		t.Fatalf("stamp POST fired %d times; an unchecked pin must send nothing", n)
	}
	if !strings.Contains(out, "unchecked expectation") {
		t.Errorf("the refusal does not say the expectation went unchecked; got:\n%s", out)
	}
}

// THE UNPINNED MET GETS THE ADVISORY, and only the unpinned met. A flag nobody
// can discover is a flag nobody types.
func TestStampExpectAdvisory(t *testing.T) {
	two := 2
	for _, c := range []struct {
		name string
		sa   stampArgs
		want bool
	}{
		{"met, no pin", stampArgs{met: true, criterion: &two}, true},
		{"met, pinned", stampArgs{met: true, criterion: &two, expect: "2:something long"}, false},
		{"miss", stampArgs{miss: true, criterion: &two}, false},
		{"withdraw", stampArgs{withdraw: true, criterion: &two}, false},
		{"no index", stampArgs{met: true}, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := stampExpectAdvisory(c.sa) != ""
			if got != c.want {
				t.Fatalf("stampExpectAdvisory(%+v) non-empty = %v, want %v", c.sa, got, c.want)
			}
		})
	}
}

// The pure parser, over the cells that decide whether a pin is usable at all.
func TestParseStampPin(t *testing.T) {
	for _, c := range []struct {
		name    string
		raw     string
		wantIdx int
		wantPfx string
		wantErr bool
	}{
		{"plain", "2:THE READ-BACK CHECKS", 2, "THE READ-BACK CHECKS", false},
		{"zero", "0:the gate refuses a bare", 0, "the gate refuses a bare", false},
		{"spaces round the index", " 3 : the census is re-run ", 3, "the census is re-run", false},
		// A criterion's own wording is full of colons; only the FIRST one splits.
		{"colon in the prefix", "1:WHY: the reason rides", 1, "WHY: the reason rides", false},
		{"no colon", "2 THE READ-BACK", 0, "", true},
		{"index not a number", "two:THE READ-BACK", 0, "", true},
		{"negative index", "-1:THE READ-BACK CHECKS", 0, "", true},
		{"empty", "", 0, "", true},
		// Too short to discriminate: a pin must be a phrase the author knew.
		{"too short", "2:THE", 0, "", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseStampPin(c.raw)
			if c.wantErr {
				if err == nil {
					t.Fatalf("parseStampPin(%q) = %+v, want an error", c.raw, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseStampPin(%q): %v", c.raw, err)
			}
			if got.index != c.wantIdx || got.prefix != c.wantPfx {
				t.Fatalf("parseStampPin(%q) = {%d,%q}, want {%d,%q}", c.raw, got.index, got.prefix, c.wantIdx, c.wantPfx)
			}
		})
	}
}

// The comparison itself. Whitespace and case fold — a pin is copied out of a
// plan and may be re-wrapped — and NOTHING else does, or the pin would start
// matching criteria it does not name.
func TestPinMatchesCriterion(t *testing.T) {
	for _, c := range []struct {
		name      string
		prefix    string
		criterion string
		want      bool
	}{
		{"exact prefix", "THE READ-BACK", "THE READ-BACK CHECKS ALIGNMENT", true},
		{"case folded", "the read-back", "THE READ-BACK CHECKS ALIGNMENT", true},
		{"whitespace collapsed", "THE   READ-BACK\n CHECKS", "THE READ-BACK CHECKS ALIGNMENT", true},
		{"whole criterion", "THE READ-BACK CHECKS", "THE READ-BACK CHECKS", true},
		{"different criterion", "THE CENSUS IS", "THE READ-BACK CHECKS", false},
		{"mid-string, not a prefix", "CHECKS ALIGNMENT", "THE READ-BACK CHECKS ALIGNMENT", false},
		{"pin longer than criterion", "THE READ-BACK CHECKS ALIGNMENT", "THE READ-BACK", false},
		{"empty pin never matches", "", "anything at all", false},
		{"empty criterion", "THE READ-BACK", "", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := pinMatchesCriterion(c.prefix, c.criterion); got != c.want {
				t.Fatalf("pinMatchesCriterion(%q, %q) = %v, want %v", c.prefix, c.criterion, got, c.want)
			}
		})
	}
}

// The two pure verdicts behind the refusals, each over the cell that decides it.
func TestStampPinProblems(t *testing.T) {
	pin := stampPin{index: 2, prefix: "the read-back renders", raw: "2:the read-back renders"}
	if p := stampPinIndexProblem(pin, 2); p != "" {
		t.Fatalf("aligned index reported a problem: %q", p)
	}
	if p := stampPinIndexProblem(pin, 3); p == "" {
		t.Fatal("a pin for index 2 beside a stamp of index 3 reported NO problem")
	}
	if p := stampPinTextProblem(pin, fourDistinctCriteria); p != "" {
		t.Fatalf("aligned wording reported a problem: %q", p)
	}
	if p := stampPinTextProblem(pin, fourDistinctCriteria[:2]); p == "" {
		t.Fatal("a pin for index 2 against a 2-criterion row reported NO problem")
	}
	if p := stampPinTextProblem(stampPin{index: 0, prefix: "the read-back renders"}, fourDistinctCriteria); p == "" {
		t.Fatal("a pin whose wording is not at index 0 reported NO problem")
	}
	if p := stampPinReadbackProblem(pin, 2, fourDistinctCriteria[2]); p != "" {
		t.Fatalf("aligned read-back reported a problem: %q", p)
	}
	if p := stampPinReadbackProblem(pin, 2, fourDistinctCriteria[3]); p == "" {
		t.Fatal("a read-back on an unpinned criterion reported NO problem")
	}
}

// The help block is the only place the flag can be discovered (the manifest
// cannot declare it), so its presence is a test, not a convention.
func TestStampExpectPinHelpNamesTheFlag(t *testing.T) {
	lines := strings.Join(stampExpectPinHelpLines(), "\n")
	for _, want := range []string{stampExpectFlag, "<index>:<first words>", "read-back", "--criterion-text"} {
		if !strings.Contains(lines, want) {
			t.Errorf("stampExpectPinHelpLines() does not mention %q:\n%s", want, lines)
		}
	}
	if !reflect.DeepEqual(stampExpectPinHelpLines(), stampExpectPinHelpLines()) {
		t.Fatal("help lines are not stable")
	}
}
