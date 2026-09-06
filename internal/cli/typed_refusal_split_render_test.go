package cli

// typed_refusal_split_render_test.go is the RENDER half of the unfused box
// refusal (task-f156b5e43bfbfe91; producer PR #16511).
//
// Its sibling typed_refusal_render_test.go pins the LEGACY path: a refusal that
// reaches the CLI as one fused prose line in `failure_reason`. That path is not
// going away — every deployment row written before the split carries only the
// composite — so this file's "neither" arm is the assertion that the old
// behaviour is BYTE-UNCHANGED, and the other three arms are what the split buys.
//
// The four arms are the four wire shapes the control plane can actually produce,
// because each half is nulled independently:
//
//	code + message  a box refusal the server split cleanly
//	code only       the box named an error and wrote no sentence
//	message only    the box explained itself without a typed code
//	neither         every legacy row, and every failure that is not a refusal

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// The composite as a pre-split control plane sends it — one line, code and
// sentence fused, which is exactly what the split exists to stop readers from
// taking apart by substring.
const splitLegacyComposite = `the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry "/quota/index.html" is an absolute path — refused`

func TestTypedRefusalSplitRender(t *testing.T) {
	cases := []struct {
		name string
		dep  cloudclient.SiteDeployment
		// want is the exact reason text the verdict line must carry.
		want string
	}{
		{
			// BOTH HALVES: the code is a token and the message stands beside it.
			// The server's wrapper prose ("the instance refused the deploy (HTTP
			// 400):") is what fusing required and is not re-printed.
			name: "code and message",
			dep: cloudclient.SiteDeployment{
				ID: "dep-1", Status: "failed", Stage: "STAGE",
				FailureReason:  splitLegacyComposite,
				FailureCode:    strPtr("E_ABSOLUTE_PATH"),
				FailureMessage: strPtr(`entry "/quota/index.html" is an absolute path — refused`),
			},
			want: `E_ABSOLUTE_PATH — entry "/quota/index.html" is an absolute path — refused`,
		},
		{
			// CODE ONLY: the bare token, with no em-dash dangling off it. The code
			// is the thing a bug is filed against, so it is still worth printing
			// alone.
			name: "code only",
			dep: cloudclient.SiteDeployment{
				ID: "dep-2", Status: "failed", Stage: "STAGE",
				FailureReason: "the instance refused the deploy (HTTP 400): already_running",
				FailureCode:   strPtr("already_running"),
			},
			want: "already_running",
		},
		{
			// MESSAGE ONLY: the sentence, unprefixed. A box that explained itself
			// without a typed code is not owed an invented one.
			name: "message only",
			dep: cloudclient.SiteDeployment{
				ID: "dep-3", Status: "failed", Stage: "STAGE",
				FailureReason:  "the instance refused the deploy (HTTP 400): the box is already running a deploy for this site",
				FailureMessage: strPtr("the box is already running a deploy for this site"),
			},
			want: "the box is already running a deploy for this site",
		},
		{
			// NEITHER — the legacy row, and the arm that must not move. The
			// composite is printed EXACTLY as the control plane wrote it.
			name: "neither half — composite unchanged",
			dep: cloudclient.SiteDeployment{
				ID: "dep-4", Status: "failed", Stage: "STAGE",
				FailureReason: splitLegacyComposite,
			},
			want: splitLegacyComposite,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stage, reason := siteFailure(tc.dep)
			if stage != "STAGE" {
				t.Fatalf("stage=%q want STAGE — the split must not disturb the stage", stage)
			}
			if reason != tc.want {
				t.Fatalf("reason mismatch.\nwant: %s\ngot:  %s", tc.want, reason)
			}

			// And it survives the verdict render, on stderr, un-truncated.
			out, _, errBuf := newTestWriter()
			if code := renderSiteDeployVerdict(out, testSiteID, tc.dep); code != exitGeneric {
				t.Fatalf("exit=%d want %d (a failed deploy never exits 0)", code, exitGeneric)
			}
			stderr := errBuf.String()
			if !strings.Contains(stderr, "site deploy failed at STAGE") {
				t.Fatalf("failure line missing:\n%s", stderr)
			}
			if !strings.Contains(stderr, tc.want) {
				t.Fatalf("the reason was altered or truncated.\nwant substring: %s\ngot stderr:      %s", tc.want, stderr)
			}
			if strings.Contains(stderr, "...") {
				t.Fatalf("an ellipsis means something truncated the reason:\n%s", stderr)
			}
		})
	}
}

// TestTypedRefusalSplitEmptyHalvesFallBackToTheComposite: a half the box sent as
// an EMPTY string carries no text to print, so the render falls through to the
// composite rather than emitting a blank token. The struct still knows the
// difference (the pointer is non-nil) — this is a DISPLAY rule, not a decode one,
// and the cloudclient decode test is where the nil-vs-"" distinction is pinned.
func TestTypedRefusalSplitEmptyHalvesFallBackToTheComposite(t *testing.T) {
	_, reason := siteFailure(cloudclient.SiteDeployment{
		ID: "dep-5", Status: "failed", Stage: "STAGE",
		FailureReason:  splitLegacyComposite,
		FailureCode:    strPtr(""),
		FailureMessage: strPtr("   "),
	})
	if reason != splitLegacyComposite {
		t.Fatalf("empty halves must not shadow the composite.\nwant: %s\ngot:  %s", splitLegacyComposite, reason)
	}
}

// TestTypedRefusalSplitReachesJSONMode: `-o json` gains both halves, and ONLY
// when the control plane sent them. A nil half must produce no key at all — an
// empty string there would read to a script as a code the box sent.
func TestTypedRefusalSplitReachesJSONMode(t *testing.T) {
	m := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-1", Status: "failed", Stage: "STAGE",
		FailureReason:  splitLegacyComposite,
		FailureCode:    strPtr("E_ABSOLUTE_PATH"),
		FailureMessage: strPtr(`entry "/quota/index.html" is an absolute path — refused`),
	})
	if got, _ := m["failure_code"].(string); got != "E_ABSOLUTE_PATH" {
		t.Fatalf("failure_code = %q", got)
	}
	if got, _ := m["failure_message"].(string); got != `entry "/quota/index.html" is an absolute path — refused` {
		t.Fatalf("failure_message = %q", got)
	}
	// The composite stays beside them, byte-unchanged, for every consumer that
	// has not moved.
	if got, _ := m["failure_reason"].(string); got != splitLegacyComposite {
		t.Fatalf("failure_reason must be untouched, got %q", got)
	}

	legacy := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-2", Status: "failed", Stage: "STAGE",
		FailureReason: splitLegacyComposite,
	})
	if _, ok := legacy["failure_code"]; ok {
		t.Fatalf("a nil half must emit NO key, got %#v", legacy["failure_code"])
	}
	if _, ok := legacy["failure_message"]; ok {
		t.Fatalf("a nil half must emit NO key, got %#v", legacy["failure_message"])
	}
}
