package cli

// success_claim_registry_test.go is the BEHAVIORAL gate for the PDS success-claim
// law: no bp verb may report success on an exit code alone — every success claim
// must be backed by a read of the state it claims to have produced, and any claim
// it cannot back must say so in the same breath.
//
// WHY THIS SHAPE AND NOT A LINT. The obvious guard — grep the tree for "✓" and
// demand each site carry a classification comment — IS the failure mode this epic
// exists to destroy: a checked-in string is a success claim about a success claim,
// and it passes CI whether or not the code is honest. Three measured facts kill
// the glyph lint outright:
//
//   - vercel_cmd.go carries 13 checkmarks and ZERO of them match a quoted-glyph
//     grep (they are interpolated inside out.progressf calls);
//   - `barkpark status` and `bp export` print success and carry no glyph at all;
//   - api/lib carries 47 glyphs and every one is LiveView chrome, not a claim.
//
// So the gate keys on BEHAVIOR, not on text. Each enrolled site is a receipt-RENDER
// function plus two server responses that DISAGREE about the post-condition — one
// that backs the claim, one that contradicts it. The property, asserted per site:
//
//	WOULD THE PRINTED SENTENCE CHANGE IF THE SERVER'S RESPONSE SAID THE OPPOSITE?
//
// A render function that ignores the response prints the same bytes for both and
// FAILS. A classification string cannot satisfy that; only reading the response
// can. And a decoupled emitter IS a render function, so enrolling one is the
// EASIEST thing in the file — that inversion is why this beats a function-scoped
// ratchet whose evasion is a two-line extract-a-helper refactor.
//
// THE RULING IT ENCODES (charter PDS-D313). "Response-backed" is three classes and
// the axis is the MEASUREMENT POINT, not response-vs-second-read:
//
//	A1  relayed post-condition — the server measured the field AFTER the change,
//	    FROM the state. Satisfies the law with no second read (bp cloud site
//	    rollback is A1).
//	A2  persisted-record echo — the server echoes the record it wrote. Satisfies
//	    the law for claims ABOUT THE RECORD.
//	A3  verb-derived / request echo — the sentence is keyed on the local verb or on
//	    what we asked for. VIOLATES the law even though a round trip happened.
//
// Enrollment is A1/A2 sites plus the A3 sites this wave converted. It is a FLOOR,
// not a census: requiredEnrollments below fails if an entry is deleted, so the
// registry can only grow.
//
// MUTATION-PROVEN: reverting the cloud_autoupdate_cmd.go fix (each verb's sentence
// keyed on the local verb again) turns TestSuccessClaimsChangeWhenTheResponseDoes
// RED on four entries. A gate not proven by mutation has not shipped.

import (
	"bytes"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/FRIKKern/barkpark/internal/taskboard"
	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// claimSite is ONE enrolled receipt-render function. It deliberately carries no
// classification/justification string field — TestSuccessClaimRegistryCarriesNoProse
// enforces that structurally, so the registry can never degrade into a list of
// self-assessments.
type claimSite struct {
	// Name is the render function as DECLARED in internal/cli, optionally with a
	// "/variant" suffix naming which branch this row exercises. The declaration is
	// verified against the sources, so a rename or deletion fails the gate.
	Name string
	// Render writes the receipt for one server response. It is the real production
	// function, never a copy.
	Render func(out *writer, resp any)
	// Backed is a response that BACKS the claim; Contradicted is the same call with
	// a response that says the opposite about the post-condition being claimed.
	Backed       any
	Contradicted any
}

func strp(s string) *string { return &s }

// successClaimRegistry is the enrolled set. Add a row when you add a receipt.
func successClaimRegistry() []claimSite {
	autoupdate := func(verb string) func(*writer, any) {
		return func(out *writer, resp any) {
			out.outf("%s", autoupdateReceipt(verb, "box-1", resp.(cloudclient.AutoupdatePolicy)))
		}
	}
	pinned := cloudclient.AutoupdatePolicy{Enabled: true, PinnedRelease: "v1.4.2"}
	unpinned := cloudclient.AutoupdatePolicy{Enabled: true}
	paused := cloudclient.AutoupdatePolicy{Enabled: true, Paused: true}
	running := cloudclient.AutoupdatePolicy{Enabled: true}

	return []claimSite{
		// ── cloud_autoupdate_cmd.go — the A3 sites this wave converted ──────────
		{
			Name:   "autoupdateReceipt/pin",
			Render: autoupdate("pin"),
			// A pin the control plane did not write is not a pin.
			Backed: pinned, Contradicted: unpinned,
		},
		{
			Name:   "autoupdateReceipt/unpin",
			Render: autoupdate("unpin"),
			Backed: unpinned, Contradicted: pinned,
		},
		{
			Name:   "autoupdateReceipt/pause",
			Render: autoupdate("pause"),
			Backed: paused, Contradicted: running,
		},
		{
			Name:   "autoupdateReceipt/resume",
			Render: autoupdate("resume"),
			Backed: running, Contradicted: paused,
		},
		{
			// The fallthrough claims nothing specific, so it must REPORT the policy
			// rather than assert one — an enabled/disabled flip has to show.
			Name:   "autoupdateReceipt/default",
			Render: autoupdate("enable"),
			Backed: cloudclient.AutoupdatePolicy{Enabled: true},
			Contradicted: cloudclient.AutoupdatePolicy{
				Enabled: false, Paused: true, PinnedRelease: "v0.9.0",
			},
		},
		{
			Name: "autoupdatePolicySummary",
			Render: func(out *writer, resp any) {
				out.outf("  policy: %s", autoupdatePolicySummary(resp.(cloudclient.AutoupdatePolicy)))
			},
			Backed:       running,
			Contradicted: cloudclient.AutoupdatePolicy{Enabled: false, Paused: true, PinnedRelease: "v0.9.0"},
		},

		// ── cloud_rollback_cmd.go — A1, the control plane reports the target slot ─
		{
			Name: "renderRollbackResult/target-sha",
			Render: func(out *writer, resp any) {
				renderRollbackResult(out, "box-1", resp.(cloudclient.RollbackResult))
			},
			Backed:       cloudclient.RollbackResult{TargetSHA: strp("abc123def456"), PinnedRelease: strp("v1.4.2")},
			Contradicted: cloudclient.RollbackResult{TargetSHA: strp("999888777666"), PinnedRelease: strp("v1.4.2")},
		},
		{
			// The defensive branch: a 202 with no target sha must NOT invent one.
			Name: "renderRollbackResult/no-target-sha",
			Render: func(out *writer, resp any) {
				renderRollbackResult(out, "box-1", resp.(cloudclient.RollbackResult))
			},
			Backed:       cloudclient.RollbackResult{TargetSHA: strp("abc123def456")},
			Contradicted: cloudclient.RollbackResult{},
		},

		// ── cloud12_cmd.go — the provisioning row the control plane returned ─────
		{
			Name: "renderProvisioned",
			Render: func(out *writer, resp any) {
				renderProvisioned(out, "launched", resp.(cloudclient.Barkpark))
			},
			Backed:       cloudclient.Barkpark{ID: "bp-1", Name: "main", URL: "https://main.example", Mode: "managed", HealthStatus: "healthy"},
			Contradicted: cloudclient.Barkpark{ID: "bp-1", Name: "main", URL: "https://main.example", Mode: "managed"},
		},

		// ── hetzner_cmd.go / hetzner_net_cmd.go — the SDK's returned resource ────
		{
			Name: "hzDone",
			Render: func(out *writer, resp any) {
				hzDone(out, "reboot", resp.(*hcloud.Server), map[string]any{"status": "running"})
			},
			Backed:       &hcloud.Server{ID: 42, Name: "web-1"},
			Contradicted: &hcloud.Server{ID: 43, Name: "web-2"},
		},
		{
			Name: "hzResDone",
			Render: func(out *writer, resp any) {
				v := resp.(hcloud.Volume)
				hzResDone(out, "attach", "volume", v.ID, v.Name, nil)
			},
			Backed:       hcloud.Volume{ID: 9, Name: "data-1"},
			Contradicted: hcloud.Volume{ID: 10, Name: "data-2"},
		},

		// ── hetzner_instance_transfer_cmd.go — the health sentinel it measured ───
		{
			Name: "instTransferDone",
			Render: func(out *writer, resp any) {
				instTransferDone(out, "import", "box.example", resp.(map[string]any))
			},
			Backed:       map[string]any{"health": "ok"},
			Contradicted: map[string]any{"health": "degraded"},
		},

		// ── login_device.go — the team the token exchange actually returned ──────
		{
			Name: "emitDeviceLoginSuccess",
			Render: func(out *writer, resp any) {
				v := resp.([2]string)
				emitDeviceLoginSuccess(out, v[0], v[1])
			},
			Backed:       [2]string{"https://cp.example", "team-a"},
			Contradicted: [2]string{"https://cp.example", "team-b"},
		},

		// ── tasks_next_cmd.go — the claim the LEDGER granted, epoch included ─────
		{
			Name: "emitFrontierClaim",
			Render: func(out *writer, resp any) {
				v := resp.(frontierClaimResponse)
				emitFrontierClaim(out, v.pick, "worker-1", v.epoch, nil, nil, []apiclient.TaskNotice{})
			},
			Backed: frontierClaimResponse{
				pick:  taskboard.Pick{Task: taskboard.Task{DocID: "task-aaa", Title: "Ship the gate"}},
				epoch: 7,
			},
			Contradicted: frontierClaimResponse{
				pick:  taskboard.Pick{Task: taskboard.Task{DocID: "task-bbb", Title: "Something else"}},
				epoch: 9,
			},
		},

		// ── cloud_support_cmd.go — the step narration + the ONLINE receipt ───────
		{
			Name: "supportAddRun.done",
			Render: func(out *writer, resp any) {
				v := resp.([2]string)
				(&supportAddRun{out: out}).done(v[0], v[1])
			},
			Backed:       [2]string{"roster", "listener ONLINE with measured capacity"},
			Contradicted: [2]string{"roster", "listener never phoned home"},
		},
		{
			Name: "supportRemoveRun.done",
			Render: func(out *writer, resp any) {
				v := resp.([2]string)
				(&supportRemoveRun{out: out}).done(v[0], v[1])
			},
			Backed:       [2]string{"token", "revoked"},
			Contradicted: [2]string{"token", "still valid"},
		},
		{
			Name: "supportAddRun.success",
			Render: func(out *writer, resp any) {
				r := resp.(supportAddRun)
				r.out = out
				r.success()
			},
			Backed: supportAddRun{
				name: "sup-1", agent: "claude", ws: "main", dataset: "production",
				base: "https://main.example", host: cloud.Server{Name: "box-1", IP: "10.0.0.1"},
			},
			Contradicted: supportAddRun{
				name: "sup-1", agent: "claude", ws: "main", dataset: "production",
				base: "https://main.example", host: cloud.Server{Name: "box-2", IP: "10.0.0.9"},
			},
		},
	}
}

// frontierClaimResponse bundles the two halves of a granted claim the ledger
// returns — the picked task and the epoch it was granted at.
type frontierClaimResponse struct {
	pick  taskboard.Pick
	epoch int
}

// requiredEnrollments is the FLOOR: deleting a row to make the gate green fails
// here instead. Names are the registry Name minus any "/variant" suffix.
var requiredEnrollments = []string{
	"autoupdateReceipt",
	"autoupdatePolicySummary",
	"renderRollbackResult",
	"renderProvisioned",
	"hzDone",
	"hzResDone",
	"instTransferDone",
	"emitDeviceLoginSuccess",
	"emitFrontierClaim",
	"supportAddRun.done",
	"supportRemoveRun.done",
	"supportAddRun.success",
}

// renderClaim runs one enrolled render against one response and returns
// everything it printed (stdout AND stderr — some receipts narrate on stderr).
// Output is pinned to "table" because that is the human receipt surface; the
// machine envelopes are contract-tested by their own suites.
func renderClaim(t *testing.T, site claimSite, resp any) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "table"
	out.color = false
	site.Render(out, resp)
	return stdout.String() + stderr.String()
}

// TestSuccessClaimsChangeWhenTheResponseDoes is THE gate. For every enrolled
// receipt, a response that contradicts the claim must change what is printed.
func TestSuccessClaimsChangeWhenTheResponseDoes(t *testing.T) {
	for _, site := range successClaimRegistry() {
		t.Run(site.Name, func(t *testing.T) {
			backed := renderClaim(t, site, site.Backed)
			if strings.TrimSpace(backed) == "" {
				t.Fatalf("%s printed nothing for the backed response — a receipt that prints nothing cannot be audited", site.Name)
			}
			contradicted := renderClaim(t, site, site.Contradicted)
			if backed == contradicted {
				t.Fatalf("%s prints the SAME line whether the server backs the claim or contradicts it — "+
					"the success claim is verb-derived (class A3), not response-backed.\n"+
					"backed:       %q\ncontradicted: %q",
					site.Name, backed, contradicted)
			}
		})
	}
}

// TestSuccessClaimRegistryEnrollsRealFunctions proves every Name is a function
// that actually exists in internal/cli — a rename, a deletion, or a typo'd
// enrollment fails here rather than silently shrinking the gate's reach.
func TestSuccessClaimRegistryEnrollsRealFunctions(t *testing.T) {
	src := readPackageSources(t)
	for _, site := range successClaimRegistry() {
		name := strings.SplitN(site.Name, "/", 2)[0]
		if !declaresFunc(src, name) {
			t.Errorf("registry enrolls %q but internal/cli declares no such function", site.Name)
		}
	}
}

// TestSuccessClaimRegistryHoldsItsFloor fails when an enrollment is dropped.
func TestSuccessClaimRegistryHoldsItsFloor(t *testing.T) {
	enrolled := map[string]bool{}
	for _, site := range successClaimRegistry() {
		enrolled[strings.SplitN(site.Name, "/", 2)[0]] = true
	}
	for _, want := range requiredEnrollments {
		if !enrolled[want] {
			t.Errorf("%s was un-enrolled from the success-claim registry — the gate only grows; "+
				"if the function is gone, delete its requiredEnrollments row in the SAME commit and say why", want)
		}
	}
}

// TestSuccessClaimRegistryCarriesNoProse is the anti-self-assessment guard: the
// registry entry carries exactly ONE string field (the function's name, which is
// verified against the sources). Adding a "classification" or "justification"
// string — the shape this whole epic exists to destroy — fails here.
func TestSuccessClaimRegistryCarriesNoProse(t *testing.T) {
	typ := reflect.TypeOf(claimSite{})
	var strFields []string
	for i := 0; i < typ.NumField(); i++ {
		if typ.Field(i).Type.Kind() == reflect.String {
			strFields = append(strFields, typ.Field(i).Name)
		}
	}
	if len(strFields) != 1 || strFields[0] != "Name" {
		t.Fatalf("claimSite string fields = %v, want exactly [Name]; a registry entry must not be able "+
			"to pass by carrying prose about itself — the only admissible evidence is a printed line that changes", strFields)
	}
}

// TestAutoupdateReceiptNamesTheContradiction pins the wording of the four
// converted A3 sites: a contradicted claim must SAY it is contradicted, not just
// print something different.
func TestAutoupdateReceiptNamesTheContradiction(t *testing.T) {
	for _, tc := range []struct {
		verb   string
		policy cloudclient.AutoupdatePolicy
		want   string
	}{
		{"pin", cloudclient.AutoupdatePolicy{}, "is NOT pinned"},
		{"unpin", cloudclient.AutoupdatePolicy{PinnedRelease: "v1.4.2"}, "is STILL pinned"},
		{"pause", cloudclient.AutoupdatePolicy{}, "is NOT paused"},
		{"resume", cloudclient.AutoupdatePolicy{Paused: true}, "is STILL paused"},
	} {
		got := autoupdateReceipt(tc.verb, "box-1", tc.policy)
		if !strings.Contains(got, tc.want) {
			t.Errorf("autoupdateReceipt(%q, contradicting policy) = %q, want it to name the contradiction (%q)", tc.verb, got, tc.want)
		}
		if strings.Contains(got, "✓") {
			t.Errorf("autoupdateReceipt(%q, contradicting policy) = %q — a contradicted claim must not carry a checkmark", tc.verb, got)
		}
		if autoupdateApplied(tc.verb, tc.policy) {
			t.Errorf("autoupdateApplied(%q, contradicting policy) = true, want false so the verb exits non-zero", tc.verb)
		}
	}
}

// ── source helpers ──────────────────────────────────────────────────────────

func readPackageSources(t *testing.T) string {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read internal/cli sources: %v", err)
	}
	var b strings.Builder
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		body, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		b.Write(body)
		b.WriteString("\n")
	}
	if b.Len() == 0 {
		t.Fatal("read internal/cli sources: no non-test .go files found — the enrollment check would pass vacuously")
	}
	return b.String()
}

// declaresFunc reports whether src declares `name` as a plain function or as a
// method on the named receiver type (registry names use "Type.method" for those).
func declaresFunc(src, name string) bool {
	if recv, method, ok := strings.Cut(name, "."); ok {
		re := regexp.MustCompile(`func \(\w+ \*?` + regexp.QuoteMeta(recv) + `\) ` + regexp.QuoteMeta(method) + `\(`)
		return re.MatchString(src)
	}
	return regexp.MustCompile(`func ` + regexp.QuoteMeta(name) + `\(`).MatchString(src)
}
