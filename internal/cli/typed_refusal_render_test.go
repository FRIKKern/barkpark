package cli

// typed_refusal_render_test.go is the CLI end of the typed-refusal chain
// (site-spawner W11).
//
// A prebuilt deploy is refused by the serving box with a TYPED code from the
// extractor (`Barkpark.Sites.PrebuiltArtifact` — 20 distinct `E_*` codes across
// 43 message sites), the control plane folds it into
// `failure_reason` as "the instance refused the deploy (HTTP 400): <CODE> —
// <message>", and `bp cloud site deploy` is where a human finally reads it. That
// last hop was functionally correct and WHOLLY UNPINNED: `grep -rn '"E_'
// internal/` returned zero hits repo-wide, so nothing in the Go tree asserted
// that a typed code survives the render at all.
//
// What can silently take it away:
//
//   - `sanitizeCell` (table.go) collapses \n\t\r and drops C0/DEL but does NOT
//     truncate, and `truncateCell`/`cellMaxRunes` only ever apply to map/slice
//     values in `formatCell` — never to a plain string. A future "tidy the table"
//     change that made either apply to `renderSiteDeployVerdict`'s reason would
//     shear the code or the message off the end and hand the user back the bare
//     "the instance refused the deploy (HTTP 400)" bug W10 fixed.
//   - `-o json` drops `failure_reason` from `siteDeploymentMap` when it is empty;
//     a refactor that dropped it unconditionally would make the machine-readable
//     surface the LEAST informative one.
//
// So these tests pin BOTH shapes, with the accented-slug headline as the fixture:
// Go's archive/tar emits a PAX ('x') header for any non-ASCII entry name, and the
// extractor refuses it with E_UNKNOWN_TYPE — the defect that made this wave.

import (
	"encoding/json"
	"strings"
	"testing"
)

// The refusal the real guerrilla box produced for a real accented-slug dist,
// composed exactly as `BarkparkCloud.Sites.Deploy.box_refusal/2` writes it
// (em-dash between code and message) and JSON-escaped as the control plane sends
// it. Kept as one const so the table and the json test pin the SAME bytes.
const typedRefusalReason = `the instance refused the deploy (HTTP 400): E_UNKNOWN_TYPE — unsupported tar entry type \"x\"`

// typedRefusalWant is typedRefusalReason as it exists in memory once decoded —
// what the render must reproduce.
const typedRefusalWant = `the instance refused the deploy (HTTP 400): E_UNKNOWN_TYPE — unsupported tar entry type "x"`

func typedRefusalPoll(reason string) fakeResp {
	return fakeResp{200, `{"deployment":{"id":"dep-1","status":"failed","stage":"STAGE","failure_reason":"` + reason +
		`","stages":[{"name":"PLAN","status":"done"},{"name":"BUILD","status":"skipped"},{"name":"STAGE","status":"failed"}]}}`}
}

// TestTypedRefusalReachesStderrInTableMode: the code AND the message land on
// stderr, in the "site deploy failed at <stage> — <reason>" line, un-truncated.
func TestTypedRefusalReachesStderrInTableMode(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
	cp.pollResp = typedRefusalPoll(typedRefusalReason)
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d (a refused deploy never exits 0)\nstderr:%s", code, exitGeneric, stderr)
	}
	if strings.Contains(stdout, "site live") {
		t.Fatalf("a refused deploy must not claim live:\n%s", stdout)
	}

	// The CODE is what a user greps, files a bug about, and what maps to the
	// extractor's refusal table.
	if !strings.Contains(stderr, "E_UNKNOWN_TYPE") {
		t.Fatalf("the typed code never reached stderr:\n%s", stderr)
	}
	// The MESSAGE is what tells them what to fix.
	if !strings.Contains(stderr, `unsupported tar entry type "x"`) {
		t.Fatalf("the refusal message never reached stderr:\n%s", stderr)
	}
	// NOT TRUNCATED: sanitizeCell does not truncate and truncateCell/cellMaxRunes
	// (60 cells) never apply to a string, so the WHOLE reason must be present —
	// this reason is longer than cellMaxRunes, so a cap creeping in would cut the
	// message and this assertion is what catches it.
	if len(typedRefusalWant) <= cellMaxRunes {
		t.Fatalf("fixture too short to prove no truncation: %d runes vs cellMaxRunes %d", len(typedRefusalWant), cellMaxRunes)
	}
	if !strings.Contains(stderr, typedRefusalWant) {
		t.Fatalf("the reason was altered or truncated.\nwant substring: %s\ngot stderr:      %s", typedRefusalWant, stderr)
	}
	if strings.Contains(stderr, "...") {
		t.Fatalf("an ellipsis in the failure line means something truncated the reason:\n%s", stderr)
	}
	// The failing STAGE travels with it — "failed at STAGE" is what tells the user
	// the bytes were rejected on ingest, not that their site is broken.
	if !strings.Contains(stderr, "site deploy failed at STAGE") {
		t.Fatalf("failure line must name the failing stage:\n%s", stderr)
	}
}

// TestTypedRefusalReachesStdoutInJSONMode: -o json keeps stdout a single envelope
// and carries failure_reason verbatim, so a script can switch on the code.
func TestTypedRefusalReachesStdoutInJSONMode(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = typedRefusalPoll(typedRefusalReason)
	cp.serve()

	stdout, _, code := runSite(t, "json", "deploy", testSiteID)
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d\n%s", code, exitGeneric, stdout)
	}

	var env struct {
		Deployment struct {
			Status        string `json:"status"`
			FailureReason string `json:"failure_reason"`
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, stdout)
	}
	if env.Deployment.Status != "failed" {
		t.Fatalf("status=%q want failed", env.Deployment.Status)
	}
	if env.Deployment.FailureReason != typedRefusalWant {
		t.Fatalf("failure_reason not verbatim.\nwant: %s\ngot:  %s", typedRefusalWant, env.Deployment.FailureReason)
	}
}

// TestTypedRefusalCodesSurviveTheRender walks the codes a static-site deploy can
// realistically hit, INCLUDING the ones whose message interpolates a
// producer-controlled entry name — the class that the control plane's humanize
// hop used to swallow (an E_ABSOLUTE_PATH on "/quota/index.html" rendered as
// "Hetzner ran out of server capacity"). The CLI must be a pass-through: whatever
// the control plane sends, the user reads.
func TestTypedRefusalCodesSurviveTheRender(t *testing.T) {
	cases := []struct{ code, message string }{
		{"E_UNKNOWN_TYPE", `unsupported tar entry type \"x\"`},
		{"E_ABSOLUTE_PATH", `entry \"/quota/index.html\" is an absolute path — refused`},
		{"E_PATH_TRAVERSAL", `entry \"../timeout/index.html\" escapes the artifact root`},
		{"E_NO_INDEX", `the archive has no index.html at its root`},
		{"E_DIGEST_MISMATCH", `the uploaded bytes do not match the declared sha256`},
	}

	for _, tc := range cases {
		t.Run(tc.code, func(t *testing.T) {
			cp := newSiteCP(t)
			cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
			cp.pollResp = typedRefusalPoll(`the instance refused the deploy (HTTP 400): ` + tc.code + ` — ` + tc.message)
			cp.serve()

			_, stderr, code := runSite(t, "table", "deploy", testSiteID)
			if code != exitGeneric {
				t.Fatalf("exit=%d want %d\n%s", code, exitGeneric, stderr)
			}
			if !strings.Contains(stderr, tc.code) {
				t.Fatalf("%s lost in the render:\n%s", tc.code, stderr)
			}
			// The message, with its JSON escapes resolved.
			want := strings.ReplaceAll(tc.message, `\"`, `"`)
			if !strings.Contains(stderr, want) {
				t.Fatalf("message lost or altered.\nwant: %s\ngot:  %s", want, stderr)
			}
		})
	}
}

// TestTypedRefusalSanitizeCellDoesNotTruncate is the direct unit tripwire under
// the two tests above: sanitizeCell is the ONLY transform the failure line puts
// the reason through, and it must be length-preserving. cellMaxRunes/truncateCell
// exist for table CELLS and are proven here to be a separate concern — if someone
// ever wires truncateCell into the failure path, the first assertion here fails
// before the render tests do, naming the cause.
func TestTypedRefusalSanitizeCellDoesNotTruncate(t *testing.T) {
	if got := sanitizeCell(typedRefusalWant); got != typedRefusalWant {
		t.Fatalf("sanitizeCell altered a typed refusal.\nwant: %s\ngot:  %s", typedRefusalWant, got)
	}
	// Well past cellMaxRunes (60) and still untouched — sanitizeCell has no cap.
	long := typedRefusalWant + strings.Repeat("x", 200)
	if got := sanitizeCell(long); got != long {
		t.Fatalf("sanitizeCell truncated a %d-rune reason", len([]rune(long)))
	}
	// What it DOES do, and why the reason is safe to print on one line: newlines
	// and tabs collapse to spaces, and an ESC sequence a producer smuggled into an
	// entry name is dropped rather than handed to the terminal.
	if got := sanitizeCell("E_BAD_NAME\n\tentry\r\x1b[31mred"); got != "E_BAD_NAME  entry [31mred" {
		t.Fatalf("sanitizeCell contract changed: %q", got)
	}
	// truncateCell is the cell-width cap. It DOES cut — which is exactly why it
	// must never be reached by a failure reason.
	if got := truncateCell(typedRefusalWant, cellMaxRunes); got == typedRefusalWant {
		t.Fatalf("truncateCell(%d) left a longer string intact — the cap the failure path must avoid is gone", cellMaxRunes)
	}
}
