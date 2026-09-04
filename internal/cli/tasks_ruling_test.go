package cli

import (
	"net/http"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ── fixtures ────────────────────────────────────────────────────────────────

// rulingReason is the shape that produced the defect: a decision recorded a day
// before the claim, in prose that reads like an instruction to make it.
const rulingReason = "RULED by team-lead, 2026-09-02: declare it unsupported, with the refusal SURFACED"

// taskEnvelope builds a tasks-endpoint 2xx envelope. An empty reason omits the
// key entirely — the ABSENT arm must exercise a row that never had the field,
// not one carrying an empty string.
func taskEnvelope(title, disposition, reason string) string {
	content := `"lifecycle_status":"open"`
	if disposition != "" {
		content += `,"disposition":"` + disposition + `"`
	}
	if reason != "" {
		content += `,"disposition_reason":"` + reason + `"`
	}
	return `{"ok":true,"doc":{"doc_id":"task-a","title":"` + title +
		`","claim":{"epoch":3,"worker":"w1"},"content":{` + content + `}},` +
		`"help":["bp task pulse task-a w1 --now \"...\""]}`
}

func taskWriteCommand(id, verb string) manifest.Command {
	return manifest.Command{
		ID:            id,
		Noun:          "task",
		Verb:          verb,
		HTTP:          manifest.HTTP{Method: http.MethodPost, PathTemplate: "/tasks/claim"},
		Writes:        true,
		DefaultOutput: "table",
	}
}

func taskGetCommand() manifest.Command {
	return manifest.Command{
		ID:            "task.get",
		Noun:          "task",
		Verb:          "get",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/tasks/x"},
		DefaultOutput: "table",
	}
}

// ── c0 / c1: the claim-time shout, both arms ────────────────────────────────

// TestTaskClaimShoutsRecordedRuling is the PRESENT arm for `bp task claim`: a
// row whose content.disposition_reason is non-empty prints the reason VERBATIM
// on its own stderr line, under a prefix that cannot be mistaken for the
// server's "help: " templates.
func TestTaskClaimShoutsRecordedRuling(t *testing.T) {
	body := taskEnvelope("do the thing", "parked", rulingReason)
	for _, output := range []string{"json", "yaml", "table", "minimal"} {
		t.Run(output, func(t *testing.T) {
			stdout, stderr, code := runPageResponse(t, output, globals{yes: true}, taskWriteCommand("task.claim", "claim"), body)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
			}
			want := rulingBannerPrefix + rulingReason
			if !strings.Contains(stderr, want) {
				t.Fatalf("%s stderr missing the ruling line %q:\n%s", output, want, stderr)
			}
			// One line, and NOT confusable with the help templates beside it.
			for _, line := range strings.Split(stderr, "\n") {
				if strings.Contains(line, rulingReason) && strings.HasPrefix(line, "help: ") {
					t.Fatalf("the ruling rendered as a help template: %q", line)
				}
			}
			if strings.Contains(stdout, rulingReason) && output == "table" {
				t.Fatalf("the ruling leaked onto table stdout (must be stderr):\n%s", stdout)
			}
		})
	}
}

// TestTaskClaimSilentWithoutRuling is the ABSENT arm: a row with no
// disposition_reason prints NO ruling line at all.
func TestTaskClaimSilentWithoutRuling(t *testing.T) {
	body := taskEnvelope("do the thing", "", "")
	_, stderr, code := runPageResponse(t, "table", globals{yes: true}, taskWriteCommand("task.claim", "claim"), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if strings.Contains(stderr, rulingBannerPrefix) {
		t.Fatalf("a row with NO recorded ruling shouted one:\n%s", stderr)
	}
	// The pre-existing receipt is untouched — the absent arm must prove the
	// hook is silent, not that the whole receipt vanished.
	if !strings.Contains(stderr, "help: bp task pulse task-a w1") {
		t.Fatalf("the claim receipt lost its help templates:\n%s", stderr)
	}
}

// TestTaskNextShoutsRecordedRuling — c1, PRESENT arm, same shape on the verb
// that hands a worker a row it never chose.
func TestTaskNextShoutsRecordedRuling(t *testing.T) {
	body := taskEnvelope("do the thing", "parked", rulingReason)
	_, stderr, code := runPageResponse(t, "table", globals{yes: true}, taskWriteCommand("task.next", "next"), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if !strings.Contains(stderr, rulingBannerPrefix+rulingReason) {
		t.Fatalf("`task next` did not shout the ruling:\n%s", stderr)
	}
}

// TestTaskNextSilentWithoutRuling — c1, ABSENT arm.
func TestTaskNextSilentWithoutRuling(t *testing.T) {
	body := taskEnvelope("do the thing", "", "")
	_, stderr, code := runPageResponse(t, "table", globals{yes: true}, taskWriteCommand("task.next", "next"), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if strings.Contains(stderr, rulingBannerPrefix) {
		t.Fatalf("`task next` shouted a ruling the row does not carry:\n%s", stderr)
	}
}

// TestRulingShoutIsVerbKeyed proves the hook is NOT shape-keyed: every task
// envelope carries doc.content, so an unkeyed hook would repeat the banner on
// pulse/stamp/close and on `task get` (which renders the ruling in place).
func TestRulingShoutIsVerbKeyed(t *testing.T) {
	body := taskEnvelope("do the thing", "parked", rulingReason)
	_, stderr, code := runPageResponse(t, "table", globals{yes: true}, taskWriteCommand("task.pulse", "pulse"), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	if strings.Contains(stderr, rulingBannerPrefix) {
		t.Fatalf("`task pulse` grew a claim-time ruling banner:\n%s", stderr)
	}
}

// ── c2: `bp task get` human rendering ───────────────────────────────────────

// TestTaskGetHumanRenderPlacesRulingUnderTitle — PRESENT arm: the human (table)
// rendering leads with the title and places disposition + disposition_reason
// DIRECTLY under it, before the key/value dump.
func TestTaskGetHumanRenderPlacesRulingUnderTitle(t *testing.T) {
	body := taskEnvelope("do the thing", "parked", rulingReason)
	stdout, _, code := runPageResponse(t, "table", globals{}, taskGetCommand(), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	lines := strings.Split(strings.TrimRight(stdout, "\n"), "\n")
	if len(lines) < 3 {
		t.Fatalf("human render is too short to carry the ruling header:\n%s", stdout)
	}
	// PLACEMENT, not mere presence: the three lines are the first three, in
	// order, title first.
	if !strings.HasPrefix(lines[0], "title") || !strings.Contains(lines[0], "do the thing") {
		t.Fatalf("line 1 is not the title: %q\n%s", lines[0], stdout)
	}
	if !strings.HasPrefix(lines[1], "disposition ") || !strings.Contains(lines[1], "parked") {
		t.Fatalf("line 2 is not the disposition directly under the title: %q\n%s", lines[1], stdout)
	}
	if !strings.HasPrefix(lines[2], "disposition_reason") || !strings.Contains(lines[2], rulingReason) {
		t.Fatalf("line 3 is not the disposition_reason directly under the title: %q\n%s", lines[2], stdout)
	}
}

// TestTaskGetHumanRenderSilentWithoutRuling — ABSENT arm: a row with no ruling
// renders exactly as it did before this slice (no title/disposition header).
func TestTaskGetHumanRenderSilentWithoutRuling(t *testing.T) {
	body := taskEnvelope("do the thing", "", "")
	stdout, _, code := runPageResponse(t, "table", globals{}, taskGetCommand(), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	first := strings.SplitN(stdout, "\n", 2)[0]
	if strings.HasPrefix(first, "title") {
		t.Fatalf("a row with no ruling grew a header block:\n%s", stdout)
	}
	if strings.Contains(stdout, "disposition") {
		t.Fatalf("a row with no ruling rendered a disposition:\n%s", stdout)
	}
}

// TestTaskGetJSONBytesUnchangedByRulingHeader — the machine contract: for the
// SAME fixture, -o json stdout is byte-identical to what a build without the
// header emits, i.e. the header lives ONLY in the table arm. Asserted as full
// stdout bytes against the raw server body (which is what renderRaw echoes),
// so a single stray byte on stdout reds this.
func TestTaskGetJSONBytesUnchangedByRulingHeader(t *testing.T) {
	body := taskEnvelope("do the thing", "parked", rulingReason)
	for _, output := range []string{"json", "yaml", "minimal"} {
		t.Run(output, func(t *testing.T) {
			stdout, _, code := runPageResponse(t, output, globals{}, taskGetCommand(), body)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d", code, exitOK)
			}
			if strings.Contains(stdout, "disposition_reason  ") {
				t.Fatalf("the table-only ruling header leaked into -o %s stdout:\n%s", output, stdout)
			}
		})
	}
	// The byte assertion proper, and it must not be circular: the REFERENCE is
	// the same fixture rendered through a command id the hook provably skips
	// (emitTaskGetRulingHeader returns on cmd.ID != "task.get"), so the compare
	// is task.get's FULL stdout bytes against a render that cannot contain the
	// header. Any leak — one byte — reds this.
	reference := taskGetCommand()
	reference.ID = "widget.get"
	for _, output := range []string{"json", "yaml", "minimal"} {
		t.Run("bytes/"+output, func(t *testing.T) {
			got, _, _ := runPageResponse(t, output, globals{}, taskGetCommand(), body)
			want, _, _ := runPageResponse(t, output, globals{}, reference, body)
			if got != want {
				t.Fatalf("-o %s stdout is not byte-unchanged by the ruling header:\n got %q\nwant %q", output, got, want)
			}
			if got == "" {
				t.Fatalf("-o %s produced NO stdout — the compare would pass vacuously", output)
			}
		})
	}
}
