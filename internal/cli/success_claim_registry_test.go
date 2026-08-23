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
// THE PROVENANCE CONVENTION, AND THE HOLE IT CLOSES (site-spawner W8). The
// property above constrains the RENDER, not the PROVENANCE of what the render is
// handed: a pure request-echo render PASSES if the row's Backed/Contradicted pair
// differs in the echoed REQUEST field, because the two calls do print different
// bytes. That is a green a dishonest receipt can manufacture. So the convention is
//
//	BACKED AND CONTRADICTED MUST BE VALUES THE SERVER RETURNED —
//	types internal/cloudclient hands BACK from a Client method, never a request body.
//
// A render may still take the request alongside (the site create receipt does, to
// tell "the server echoed it" apart from "the server said nothing"), but the axis
// the pair varies on must be the response. TestSiteClaimsAreProbedWithResponseTypes
// enforces this MECHANICALLY for the site rows: it parses internal/cloudclient for
// the types its methods return and fails any pinned site row probed with anything
// else — swap a row's Backed to cloudclient.SpawnSiteCreate (a request body) and it
// goes red, which is the mutation that proves the guard is not decorative.
// Pre-W8 rows predate the convention and are grandfathered by NAME — only the
// pinned site rows and anything named renderSite* are checked — never by prose on
// the row itself. The prefix half matters: an enumerated list would leave the NEXT
// site receipt unchecked until someone remembered it, which is the same
// nobody-looked shape the registry exists to kill.
//
// MUTATION-PROVEN: reverting the cloud_autoupdate_cmd.go fix (each verb's sentence
// keyed on the local verb again) turns TestSuccessClaimsChangeWhenTheResponseDoes
// RED on four entries. A gate not proven by mutation has not shipped.

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

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
			// PDS-D355 REPAIR. The pre-repair row varied its pair on ID/Name —
			// the two fields an action CANNOT change — and hand-injected an
			// extra map no action verb ever passed (`runHetznerServerAction`
			// passed nil). It was vacuously green: deleting hzDone's whole extra
			// handling left it PASSING. So: identity is held FIXED, the pair
			// varies on the POST-CONDITION, and Render calls hzDone exactly as
			// runHetznerServerAction calls it — the extra comes from the
			// production builder against the re-read server.
			Name: "hzDone/post-condition",
			Render: func(out *writer, resp any) {
				srv := resp.(*hcloud.Server)
				hzDone(out, "poweroff", srv, hzActionObserved("poweroff", srv))
			},
			Backed:       &hcloud.Server{ID: 42, Name: "web-1", Status: hcloud.ServerStatusOff},
			Contradicted: &hcloud.Server{ID: 42, Name: "web-1", Status: hcloud.ServerStatusRunning},
		},
		{
			// Shape C (reboot/reset) has no discriminator, so its receipt is
			// NARROWED rather than strengthened — and a narrowed sentence still
			// has to move when the observed state moves, or "✓ reboot" is back
			// to meaning nothing.
			Name: "hzDone/narrowed-restart",
			Render: func(out *writer, resp any) {
				srv := resp.(*hcloud.Server)
				hzDone(out, "reboot", srv, hzActionObserved("reboot", srv))
			},
			Backed:       &hcloud.Server{ID: 42, Name: "web-1", Status: hcloud.ServerStatusRunning},
			Contradicted: &hcloud.Server{ID: 42, Name: "web-1", Status: hcloud.ServerStatusOff},
		},
		{
			// The honest partial: an ACPI shutdown the guest has not reacted to.
			Name: "hzPartial",
			Render: func(out *writer, resp any) {
				srv := resp.(*hcloud.Server)
				hzPartial(out, "shutdown", srv, hzServerPostConditions["shutdown"].unmet(srv, time.Minute), hzActionObserved("shutdown", srv))
			},
			Backed:       &hcloud.Server{ID: 42, Name: "web-1", Status: hcloud.ServerStatusRunning},
			Contradicted: &hcloud.Server{ID: 42, Name: "web-1", Status: hcloud.ServerStatusOff},
		},
		{
			// PDS-D405/D423 REPAIR. The pre-repair row varied its pair on ID 9→10
			// and Name data-1→data-2 — the two fields an attach CANNOT change — so
			// it was an IDENTITY ECHO: two different volumes printed two different
			// lines, which proves nothing about whether the attach took. hzResDone
			// itself has no post-condition to read; the receipt that does is
			// hzResDestroyed (hetzner_respost.go:104), whose gone-arm IS hzResDone.
			// So the ROW is re-pointed at that receipt — the function keeps its name
			// (requiredEnrollments still names hzResDone) and the pair now varies on
			// GONE-ness with the resolved identity held fixed OUTSIDE the probe.
			//
			// THE STRUCTURAL WRINKLE, AND HOW IT IS RECONCILED: hzResDestroyed takes
			// a read closure over a ctx, while Render is func(out *writer, resp any).
			// The probe is therefore the CONFIRMING READ'S ANSWER — *hcloud.Volume,
			// exactly what hzResGoneRead[hcloud.Volume] hands back — and the closure
			// is a one-line adapter that returns it. That keeps the probe a decode
			// target (arm 1) instead of a tuple the row invented, and it puts the
			// post-condition where the SDK actually puts it: nil ⇒ the API says the
			// volume is gone, non-nil ⇒ it survived and the claim is refused.
			Name: "hzResDone/destroy-confirmed",
			Render: func(out *writer, resp any) {
				fresh, _ := resp.(*hcloud.Volume)
				hzResDestroyed(out, context.Background(), "delete", "volume",
					hzDestroyIdentity.ID, hzDestroyIdentity.Name, nil,
					func(context.Context) (*hcloud.Volume, *hcloud.Response, error) { return fresh, nil, nil })
			},
			Backed:       (*hcloud.Volume)(nil),
			Contradicted: &hcloud.Volume{ID: 9, Name: "data-1"},
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
			// PDS-D405 REPAIR. The pre-repair row probed with a hand-authored
			// [2]string: a tuple the ROW invented, whose arity and meaning no decode
			// produces. The behaviour was honest (mutating the emitter to ignore
			// teamID reds four other tests) but the PROBE was not, so it is
			// re-pointed — with no exemption — at cloudclient.LoginResp, the type
			// the token exchange decodes into (client.go:172, DevicePollResult.Login).
			// The session token is the identity and is held fixed; the pair varies
			// only on the team the control plane says the token belongs to.
			Name: "emitDeviceLoginSuccess",
			Render: func(out *writer, resp any) {
				// The account-identity widening (deviceAccount) is best-effort chrome
				// on TOP of the team-id contract this row probes: the probe holds it
				// at the zero value so the receipt still varies ONLY on TeamID, the
				// post-condition the disposition pins.
				emitDeviceLoginSuccess(out, deviceLoginBase, resp.(cloudclient.LoginResp).TeamID, deviceAccount{})
			},
			Backed:       cloudclient.LoginResp{Token: "tok-1", TeamID: "team-a"},
			Contradicted: cloudclient.LoginResp{Token: "tok-1", TeamID: "team-b"},
		},

		// ── tasks_next_cmd.go — the claim the LEDGER granted, epoch included ─────
		{
			// The WHICH-TASK half: the grant (worker + epoch) is held fixed in the
			// shared frontierGrant* fixtures and the pair varies on the picked task,
			// so id/title injectivity survives. Probed with taskboard.Pick — the
			// snapshot-decoded type the production call site passes — rather than
			// the old test-local frontierClaimResponse struct, which was a shape the
			// row invented for itself.
			Name: "emitFrontierClaim",
			Render: func(out *writer, resp any) {
				emitFrontierClaim(out, resp.(taskboard.Pick), frontierGrantWorker, frontierGrantEpoch, nil, nil, []apiclient.TaskNotice{})
			},
			Backed:       taskboard.Pick{Task: taskboard.Task{DocID: "task-aaa", Title: "Ship the gate"}},
			Contradicted: taskboard.Pick{Task: taskboard.Task{DocID: "task-bbb", Title: "Something else"}},
		},
		{
			// PDS-D405 REPAIR, as a VARIANT and not an edit in place: the row above
			// varies id AND title AND (before this) the epoch, so injectivity
			// survived losing the epoch entirely — the fencing token nobody's bytes
			// depended on. This row holds the pick fixed and varies ONLY the epoch,
			// probed with apiclient.TaskClaimOutcome (client.go:1163), the type
			// TaskClaimResources decodes the grant into. Delete the epoch from the
			// receipt and THIS row reds while the one above stays green.
			Name: "emitFrontierClaim/epoch",
			Render: func(out *writer, resp any) {
				o := resp.(apiclient.TaskClaimOutcome)
				emitFrontierClaim(out, frontierPick, frontierGrantWorker, o.Epoch, nil, nil, o.Notices)
			},
			Backed:       apiclient.TaskClaimOutcome{OK: true, Epoch: 7},
			Contradicted: apiclient.TaskClaimOutcome{OK: true, Epoch: 9},
		},

		// ── cloud_support_cmd.go — the step narration + the ONLINE receipt ───────
		{
			// PDS-D405 REPAIR (charter class A3). The pre-repair row handed done()
			// two hand-authored [2]string literals and asserted that the printed
			// line changed — i.e. that `progressf` prints its arguments. The lie
			// lives ONE FRAME UP, at the ~20 callers that compose the message, so
			// the row is re-enrolled at the caller that has a real post-condition:
			// stepOnline (cloud_support_cmd.go:799), whose narration is composed
			// from the MAIN'S ROSTER ROW — a decoded JSON body (supportRosterRow
			// returns map[string]any), never from the local verb.
			//
			// PDS-D431: the narration is now CALLED, not mirrored. The row hands
			// supportOnlineNarration the roster row WHOLE — it does its own
			// status/capacity extraction in cloud_support_cmd.go — so a production
			// edit that stops printing the capacity reds this row instead of
			// leaving it probing a sentence the CLI no longer composes. The three
			// mirror consts and their pinning arm are gone with it.
			Name: "supportAddRun.done/online-roster-row",
			Render: func(out *writer, resp any) {
				(&supportAddRun{out: out}).done("online",
					supportOnlineNarration(supportAddIdentity.name, resp.(map[string]any)))
			},
			Backed:       map[string]any{"status": "idle", "capacity": map[string]any{"max_class": "medium"}},
			Contradicted: map[string]any{"status": "offline", "capacity": map[string]any{"max_class": "small"}},
		},
		{
			// PDS-D405 REPAIR, same shape on the teardown side. Re-enrolled at
			// stepDNS (cloud_support_cmd.go:1229/:1236): the sweep names what the
			// ZONE returned — every A rrset resolving to the box IP, deleted BY
			// VALUE (PDF-D101) — so the pair varies on the zone's answer and the
			// receipt has to switch branches with it. The zone + IP are the identity
			// and are held fixed outside the probe.
			//
			// PDS-D431: the row CALLS supportDNSNarration, which owns BOTH the
			// len(deleted)==0 fork and the cloud.Fqdn mapping loop. The pre-repair
			// row reimplemented both, and nothing pinned either — a second mirror,
			// wholly unpinned, that could drift from production in silence.
			Name: "supportRemoveRun.done/dns-swept",
			Render: func(out *writer, resp any) {
				(&supportRemoveRun{out: out}).done("dns",
					supportDNSNarration(supportDNSZone, supportDNSIP, resp.([]string)))
			},
			Backed:       []string{"sup-1"},
			Contradicted: []string{},
		},
		{
			// PDS-D431, THE UNFILED HALF. The row above declares `@len`, so its
			// pair straddles the clean-vs-swept BRANCH and pins nothing INSIDE the
			// swept one: measured, dropping the fqdn NAMES from the swept sentence
			// left the entire claim family green (only the behavioural
			// cloud_support_cmd_test.go arm redded). This pair holds len at 1 and
			// moves only WHICH record the zone said it deleted, so the swept
			// branch's payload — the names, qualified against the zone — is
			// attributed on both surfaces in its own right.
			Name: "supportRemoveRun.done/dns-swept-names",
			Render: func(out *writer, resp any) {
				(&supportRemoveRun{out: out}).done("dns",
					supportDNSNarration(supportDNSZone, supportDNSIP, resp.([]string)))
			},
			Backed:       []string{"sup-1"},
			Contradicted: []string{"sup-2"},
		},
		// ── cloud_site_cmd.go — the spawner's five receipts (site-spawner W8) ────
		// Every Backed/Contradicted below is a type internal/cloudclient RETURNS;
		// the create rows hold the REQUEST fixed and vary only the row the control
		// plane sent back, so the printed difference can only come from the response.
		{
			Name: "renderSiteCreated/doc-type-binding",
			Render: func(out *writer, resp any) {
				renderSiteCreated(out.outf, resp.(cloudclient.SpawnSite), siteCreateReq, false)
			},
			// A doc type the control plane did NOT store is not a binding, however
			// loudly the request asked for one.
			Backed:       spawnSiteRowFixture(func(s *cloudclient.SpawnSite) { s.DocType = "paper" }),
			Contradicted: spawnSiteRowFixture(func(s *cloudclient.SpawnSite) { s.DocType = "" }),
		},
		{
			Name: "renderSiteCreated/dataset-binding",
			Render: func(out *writer, resp any) {
				renderSiteCreated(out.outf, resp.(cloudclient.SpawnSite), siteCreateReq, false)
			},
			Backed: spawnSiteRowFixture(nil),
			Contradicted: spawnSiteRowFixture(func(s *cloudclient.SpawnSite) {
				s.Workspace, s.Project, s.Dataset = "", "", ""
			}),
		},
		{
			// The deploy verdict: live is the control plane's RECORD of its switch,
			// so a record that says otherwise must not print the live receipt.
			Name: "renderSiteDeployVerdict/live-vs-failed",
			Render: func(out *writer, resp any) {
				renderSiteDeployVerdict(out, "blog", resp.(cloudclient.SiteDeployment))
			},
			// NARROWED by the disposition arms: the contradicting half used to
			// carry Stage + FailureReason as well, and neither is attributable on
			// its own — on a LIVE record the verdict prints neither, so they rode
			// along on Status and would have gone on passing after being deleted
			// from the render. The axis that IS load-bearing is status (and the
			// URL the live sentence prints); the failed branch's stage/reason
			// wording is pinned by cloud_site_cmd's own suite.
			Backed:       cloudclient.SiteDeployment{ID: "dep-1", Status: "live", URL: "https://acme.barkpark.cloud/sites/blog/"},
			Contradicted: cloudclient.SiteDeployment{ID: "dep-1", Status: "failed"},
		},
		{
			// A live record with no URL must not fabricate one.
			Name: "renderSiteDeployVerdict/live-no-url",
			Render: func(out *writer, resp any) {
				renderSiteDeployVerdict(out, "blog", resp.(cloudclient.SiteDeployment))
			},
			Backed:       cloudclient.SiteDeployment{ID: "dep-1", Status: "live", URL: "https://acme.barkpark.cloud/sites/blog/"},
			Contradicted: cloudclient.SiteDeployment{ID: "dep-1", Status: "live"},
		},
		{
			// A1: the control plane measured the serving slot after the flip.
			Name: "renderSiteRolledBack",
			Render: func(out *writer, resp any) {
				renderSiteRolledBack(out, "blog", resp.(cloudclient.SiteRollbackResult))
			},
			Backed:       cloudclient.SiteRollbackResult{OK: true, DeploymentID: "dep-prev", PreviousDeploymentID: "dep-bad"},
			Contradicted: cloudclient.SiteRollbackResult{OK: true, DeploymentID: "dep-other", PreviousDeploymentID: "dep-bad"},
		},
		{
			// A 200 is not the post-condition: an envelope that is not the deleted
			// receipt must not print a checkmark.
			Name: "renderSiteDeleted",
			Render: func(out *writer, resp any) {
				renderSiteDeleted(out, "blog", resp.(cloudclient.SiteDeleteResult))
			},
			Backed:       cloudclient.SiteDeleteResult{OK: true, Status: "deleted", Slug: "blog"},
			Contradicted: cloudclient.SiteDeleteResult{OK: false, Status: "pending", Slug: "blog"},
		},
		{
			// A2: the settings receipt claims the row the server stored, so a row
			// storing something else has to print something else.
			Name: "renderSiteSettingsUpdated",
			Render: func(out *writer, resp any) {
				renderSiteSettingsUpdated(out, "blog", resp.(cloudclient.SpawnSite))
			},
			Backed:       spawnSiteRowFixture(func(s *cloudclient.SpawnSite) { s.Theme = "ember" }),
			Contradicted: spawnSiteRowFixture(func(s *cloudclient.SpawnSite) { s.Theme = "fjord" }),
		},

		// ── tasks_stamp_cmd.go — the LEDGER ROW the store actually holds ────────
		{
			// PDS-D359/D361, wave 26. `bp task stamp` is the verb every acceptance
			// criterion in this epic is written with, and it was observed returning
			// exit 0 on a write the store never took. Its receipt is now rendered
			// from the SECOND READ: the request is held fixed (stampVerdictReq) and
			// the pair varies only on the row the store handed back, so a receipt
			// that echoed the request would print the same bytes for both halves.
			Name: "renderStampVerdict",
			Render: func(out *writer, resp any) {
				renderStampVerdict(out, stampVerdictReq, resp.(taskboard.CriterionItem), exitOK)
			},
			Backed:       stampStoredBacked(),
			Contradicted: stampStoredContradicted(),
		},

		// ── migrate_cmd.go / tasks_create_cmd.go — PDS wave 48's two A3 sites ───
		{
			// `bp migrate`'s per-type line used to count len(batch) — the REQUEST —
			// with the mutate response discarded on every 2xx. The pair here is the
			// same batch of 2 documents with the server confirming 2 results and 1:
			// the count is now read out of `results`, so a server that wrote fewer
			// than we sent has to print fewer (and loses the checkmark).
			Name:   "migrateTypeReceipt",
			Render: renderMigrateClaim,
			Backed: mutateBodyFixture(
				map[string]any{"id": "post-a", "operation": "createOrReplace"},
				map[string]any{"id": "post-b", "operation": "createOrReplace"},
			),
			Contradicted: mutateBodyFixture(
				map[string]any{"id": "post-a", "operation": "createOrReplace"},
			),
		},
		{
			// A2: `bp task create`'s birth receipt used to read the lifecycle out of
			// the request map the CLI itself had defaulted "open" into — tautological
			// by construction. It is now read off results[].document, the record the
			// server persisted (Envelope.render of the written row), so the pair
			// varies on the STORED lifecycle and a receipt echoing the request would
			// print the same bytes for both halves.
			Name:         "renderTaskCreated",
			Render:       renderTaskCreatedClaim,
			Backed:       taskCreatedBodyFixture("considering"),
			Contradicted: taskCreatedBodyFixture("open"),
		},

		{
			// PDS-D405 REPAIR. The pre-repair pair varied host.Name AND host.IP —
			// two different boxes — so "support sup-1 is ONLINE" was pinned by
			// NOTHING: mutation-proven, deleting token_id / cp_row_id / max_class
			// from the payload left the row PASSING. The run is now assembled from
			// ONE shared identity fixture and the pair varies only on the address
			// the PROVIDER assigned (cloud.Server.IP, which the provider returns —
			// unlike Name, which is what we asked for).
			//
			// The pair varies the address the PROVIDER assigned; the human sentence
			// prints it ("box: … at …") and so does the envelope, which is why this
			// row attributes on both surfaces. The measured max_class gets its own
			// row below — see supportAddRun.success/max-class.
			Name: "supportAddRun.success",
			Render: func(out *writer, resp any) {
				r := supportAddIdentity
				r.out = out
				r.host = resp.(cloud.Server)
				r.success()
			},
			Backed:       cloud.Server{ID: "srv-1", Name: "box-1", IP: "10.0.0.1"},
			Contradicted: cloud.Server{ID: "srv-1", Name: "box-1", IP: "203.0.113.9"},
		},
		{
			// PDS-D431 closes the limit the row above used to record: max_class rode
			// the machine envelope ALONE, so the operator's summary carried no
			// measured fact and arm 3 had nothing to attribute on both surfaces.
			// success() now prints it through supportCapacityNarration.
			//
			// The probe is the BOX'S RAW ANSWER — the stdout of the same measurer
			// the listener beats with (fleet-run.sh capacity, PDF-D36) — and
			// production's own parser turns it into the class. Nothing here restates
			// what production concluded; the pair moves what the box SAID.
			Name: "supportAddRun.success/max-class",
			Render: func(out *writer, resp any) {
				r := supportAddIdentity
				r.out = out
				r.host = supportSuccessHost
				stdout, _ := resp.(map[string]any)["capacity_stdout"].(string)
				r.maxClass = supportParseSizeClass(stdout)
				r.success()
			},
			Backed:       map[string]any{"capacity_stdout": `{"size_class":"standard"}`},
			Contradicted: map[string]any{"capacity_stdout": `{"size_class":"heavy"}`},
		},
		{
			// PDS wave 32. The row above only ever walks the MEASURED fork: both its
			// halves parse to a class, so supportCapacityNarration's degraded branch —
			// live, reachable from `bp cloud support add` whenever the box's capacity
			// probe answers off-vocabulary or not at all — was exercised by nothing,
			// and mutating it to print an empty sentence stayed green everywhere.
			//
			// Same entry point, same axis (the BOX'S RAW ANSWER), one fork over: the
			// backed half is a box that measured itself, the contradicting half is a
			// box whose answer carries no class at all. Production's own parser makes
			// the call and success() prints whatever the narration returns — the row
			// restates neither. The wording itself is pinned by
			// TestSupportCapacityNarrationStatesTheDegradedMeasure below, because the
			// change-when-the-response-does property alone is satisfied by ANY two
			// different strings and so cannot tell "degraded, and it says so" from
			// "degraded, silently".
			Name: "supportAddRun.success/max-class-degraded",
			Render: func(out *writer, resp any) {
				r := supportAddIdentity
				r.out = out
				r.host = supportSuccessHost
				stdout, _ := resp.(map[string]any)["capacity_stdout"].(string)
				r.maxClass = supportParseSizeClass(stdout)
				r.success()
			},
			Backed:       map[string]any{"capacity_stdout": `{"size_class":"standard"}`},
			Contradicted: map[string]any{"capacity_stdout": `{"error":"fleet-run.sh: capacity: no such file"}`},
		},
	}
}

// registryRow returns the enrolled row with this exact Name, failing if it is
// gone — so a test that pins one row's behavior can never pass vacuously after
// a rename.
func registryRow(t *testing.T, name string) claimSite {
	t.Helper()
	for _, site := range successClaimRegistry() {
		if site.Name == name {
			return site
		}
	}
	t.Fatalf("no success-claim registry row named %q — the row it pins is gone", name)
	return claimSite{}
}

// TestSupportCapacityNarrationStatesTheDegradedMeasure pins the fork the pair
// property cannot reach on its own. supportCapacityNarration's degraded branch is
// production's answer when the box could not measure itself, and an operator
// reading `size: max class ` with nothing after it reads it as fine. So:
//
//   - the degraded sentence must exist and must NAME the degradation;
//   - it must not read like a measured class (it cannot equal the measured
//     sentence, and must not carry the class the measured half prints);
//   - and success() must actually print THAT sentence — asserted by CALLING
//     supportCapacityNarration and requiring the receipt to contain what it
//     returned, never by restating its text here (#8688: a registry that
//     restates a string proves the string exists, not that the code emits it).
//
// MUTATION-PROVEN: making the degraded branch return "" fails the non-empty arm;
// making it return the measured wording fails the names-the-degradation arm.
func TestSupportCapacityNarrationStatesTheDegradedMeasure(t *testing.T) {
	degraded := supportCapacityNarration("")
	if strings.TrimSpace(degraded) == "" {
		t.Fatalf("supportCapacityNarration(\"\") = %q — an unmeasured capacity must be STATED, never printed as an "+
			"empty tail the operator reads as a measured fact", degraded)
	}
	low := strings.ToLower(degraded)
	for _, want := range []string{"not measured", "degraded"} {
		if !strings.Contains(low, want) {
			t.Errorf("supportCapacityNarration(\"\") = %q, want it to name the degradation (%q)", degraded, want)
		}
	}
	const measuredClass = "standard"
	if measured := supportCapacityNarration(measuredClass); degraded == measured {
		t.Errorf("supportCapacityNarration(\"\") prints the same sentence as a MEASURED class — "+
			"the receipt cannot tell the operator which one happened.\nboth: %q", degraded)
	}
	if strings.Contains(degraded, measuredClass) {
		t.Errorf("supportCapacityNarration(\"\") = %q names a size class — a measure that did not happen "+
			"must not read like one that did", degraded)
	}

	// And production must PRINT it: render the degraded half of the enrolled row
	// and require the receipt to carry exactly what the narration returned.
	site := registryRow(t, "supportAddRun.success/max-class-degraded")
	receipt := renderClaim(t, site, site.Contradicted)
	if !strings.Contains(receipt, degraded) {
		t.Errorf("supportAddRun.success does not print supportCapacityNarration's degraded sentence (%q) when the "+
			"box's answer carries no class — the branch is live in production but unreachable from the receipt.\nreceipt: %q",
			degraded, receipt)
	}
}

// supportSuccessHost is the box the max-class row holds fixed: that row's axis is
// what the box MEASURED, so the address the provider assigned must not move with
// it (the row above is where the address is the axis).
var supportSuccessHost = cloud.Server{ID: "srv-1", Name: "box-1", IP: "10.0.0.1"}

// siteCreateReq is the REQUEST the site create rows hold fixed. It is deliberately
// never a Backed/Contradicted value: the pair must vary on the response, or the
// gate would be probing an echo of ourselves.
var siteCreateReq = cloudclient.SpawnSiteCreate{
	Name: "blog", Framework: "astro", Kind: "static",
	Workspace: "acme", Project: "rocket", Dataset: "production", DocType: "paper",
}

// spawnSiteRowFixture is the control plane's echo of that create — the fully-bound row —
// with an optional mutation for the contradicting half.
func spawnSiteRowFixture(mut func(*cloudclient.SpawnSite)) cloudclient.SpawnSite {
	s := cloudclient.SpawnSite{
		ID: "site-1", Name: "blog", Slug: "blog", Kind: "static", Framework: "astro",
		Workspace: "acme", Project: "rocket", Dataset: "production",
		Instance: "acme", DocType: "paper", Theme: "ember",
	}
	if mut != nil {
		mut(&s)
	}
	return s
}

// ── THE HELD-FIXED HALVES (PDS-D355) ────────────────────────────────────────
//
// Every fixture below is the IDENTITY a repaired row holds constant while its
// probe varies on the post-condition. They are package-level vars, not literals
// inside a Render closure, for one reason: a shared fixture can be MUTATED, and
// TestClaimProbesHoldIdentityFixed mutates each one and requires BOTH halves of
// the row to move. A half that baked its own identity in place fails there —
// which is what stops "identity held fixed" from being a claim about the
// fixtures rather than a fact about the render.

// hzDestroyIdentity is the RESOLVED identity a destroy receipt closes over.
// PDS-D400: the gone-check binds to the id the verb ALREADY resolved, never to
// the user's token, so the identity is not in the confirming read's answer at
// all — it is here, and both halves render through it.
var hzDestroyIdentity = struct {
	ID   int64
	Name string
}{ID: 9, Name: "data-1"}

// deviceLoginBase is the control plane the device login reports against. The
// team the token belongs to is the probe; the host is not.
var deviceLoginBase = "https://cp.example"

// frontierGrant* is the grant the ledger returned — the worker it was granted
// to and the fencing epoch. The WHICH-TASK row holds these fixed; the /epoch
// row holds frontierPick fixed and varies the epoch instead.
var (
	frontierGrantWorker = "worker-1"
	frontierGrantEpoch  = 7
	frontierPick        = taskboard.Pick{Task: taskboard.Task{DocID: "task-aaa", Title: "Ship the gate"}}
)

// supportAddIdentity is the one `support add` run every support row renders
// through: the name/agent/workspace/dataset the operator asked for. Everything
// in it is a REQUEST echo by construction, which is exactly why it is the
// identity and never the probe.
var supportAddIdentity = supportAddRun{
	name: "sup-1", agent: "claude", ws: "main", dataset: "production",
	base: "https://main.example",
}

// supportDNS* is the teardown's identity: the zone swept and the box IP the
// sweep matches A-record VALUES against. The probe is what the zone returned.
var (
	supportDNSZone = "fleet.example"
	supportDNSIP   = "10.0.0.1"
)

// PDS-D431: the three mirror consts that used to live here — and
// TestClaimProbesMirrorTheProductionNarration, which pinned them against the
// production source — are GONE. The support rows call
// supportOnlineNarration / supportDNSNarration in cloud_support_cmd.go
// directly, so there is no second copy of the sentence left to drift.

// ── PDS wave 48 — the two receipts that used to assert from the REQUEST ─────
//
// Both probes are DECODED /v1/data/mutate bodies (an unnamed map[string]any —
// what a JSON decode of that endpoint produces, and the arm-1 carve-out for a
// body with no Go type). Each render marshals the probe back and hands the
// BYTES to the production parser (migrateBatchWritten / firstMutationRecord),
// so the row exercises the real decode instead of a copy of it, and both
// surfaces are rendered by the production functions.

// mutateBodyFixture is one /v1/data/mutate 2xx body, results in order.
func mutateBodyFixture(results ...map[string]any) map[string]any {
	rows := make([]any, 0, len(results))
	for _, r := range results {
		rows = append(rows, r)
	}
	return map[string]any{"transactionId": "tx-1", "results": rows}
}

// taskCreatedBodyFixture is the create response for ONE task, varying only on
// the lifecycle_status the server PERSISTED into the echoed document.
func taskCreatedBodyFixture(lifecycle string) map[string]any {
	return mutateBodyFixture(map[string]any{
		"id": "task-9",
		"document": map[string]any{
			"_id":              "task-9",
			"_draft":           false,
			"lifecycle_status": lifecycle,
		},
	})
}

func claimBodyBytes(resp any) []byte {
	b, err := json.Marshal(resp)
	if err != nil {
		return []byte(`{}`)
	}
	return b
}

// migrateClaimPlan is the plan the migrate row's machine surface is projected
// through: it is held FIXED across the pair, so the only thing that can move
// the -o json envelope is the count the server returned.
var migrateClaimPlan = migratePlan{
	from:    migrateEndpoint{name: "src", url: "http://src", kind: "local"},
	to:      migrateEndpoint{name: "dst", url: "http://dst", kind: "local"},
	dataset: "production",
	types:   []migrateTypeCount{{Type: "post", Count: migrateClaimSent}},
	total:   migrateClaimSent,
}

// migrateClaimSent is how many documents the batch SENT — the number the old
// receipt printed unconditionally.
const migrateClaimSent = 2

// renderMigrateClaim drives `bp migrate`'s per-type receipt on both surfaces:
// the human line and the -o json envelope's total_migrated, which now carry the
// same server-derived count.
func renderMigrateClaim(out *writer, resp any) {
	written, err := migrateBatchWritten(claimBodyBytes(resp))
	if err != nil {
		out.errf("  ✗ post: %v", err)
		return
	}
	if out.machineOut() {
		out.emitStructured(migratePlanJSON(migrateClaimPlan, false,
			[]migrateTypeCount{{Type: "post", Count: written}}, written, nil))
		return
	}
	out.outf("%s", migrateTypeReceipt("post", written, migrateClaimSent))
}

// taskCreatedClaimDraftID is the draft id the create mutation returned — held
// fixed across the pair, so only the persisted record can move the receipt.
const taskCreatedClaimDraftID = "drafts.task-9"

func renderTaskCreatedClaim(out *writer, resp any) {
	rec, ok := firstMutationRecord(claimBodyBytes(resp))
	if !ok {
		out.errf("task create: server returned no id")
		return
	}
	renderTaskCreated(out, taskCreatedClaimDraftID, rec)
}

// requiredEnrollments is the FLOOR: deleting a row to make the gate green fails
// here instead. Names are the registry Name minus any "/variant" suffix.
var requiredEnrollments = []string{
	"autoupdateReceipt",
	"autoupdatePolicySummary",
	"renderRollbackResult",
	"renderProvisioned",
	"hzDone",
	"hzPartial",
	"hzResDone",
	"instTransferDone",
	"emitDeviceLoginSuccess",
	"emitFrontierClaim",
	"supportAddRun.done",
	"supportRemoveRun.done",
	"supportAddRun.success",
	// site-spawner W8 — every `bp cloud site` success receipt.
	"renderSiteCreated",
	"renderSiteDeployVerdict",
	"renderSiteRolledBack",
	"renderSiteDeleted",
	"renderSiteSettingsUpdated",
	// PDS wave 26 — the ledger writer this epic's own evidence is made of.
	"renderStampVerdict",
	// PDS wave 48 — the two receipts that asserted from the REQUEST.
	"migrateTypeReceipt",
	"renderTaskCreated",
}

// ── LEDGER ROWS (charter PDS-D363) ──────────────────────────────────────────
//
// The site rows are held to their provenance convention by
// TestSiteClaimsAreProbedWithResponseTypes, which parses internal/cloudclient
// for the types its methods RETURN. That arm was PROVEN unable to cover a
// ledger row: it gates on `pinned[base] || HasPrefix(base,"renderSite")` and on
// a PkgPath ending internal/cloudclient, and renaming an honest stamp probe to
// renderSiteStampVerdict made it fire and then REJECT taskboard.CriterionItem,
// because cloudclient never returns one. Copying the regex arm is no fix
// either: it is UNSOUND on internal/apiclient (Doc is both a returned field and
// a request parameter, so "returned type" stops telling request from response)
// and VACUOUS on internal/taskboard (neither CriterionItem producer returns an
// error, so the `) (T, error)` scan finds nothing and the check passes on an
// empty set).
//
// So a ledger row is constrained STRUCTURALLY instead, on the three facts that
// make a second read a second read:
//
//  1. Backed and Contradicted are the SAME Go type — two halves of one row,
//     not a request compared against a response.
//  2. That type is the READ-BACK type: what the store's decode produces.
//  3. The request is a SHARED package-level fixture both halves render through
//     — proven behaviorally by mutating it and requiring BOTH halves to move.
//     A half that baked its own request in place, or one that never reads the
//     request at all, fails here.
//
// The decisive measurement behind this: a render that ignores the store entirely
// goes FULLY GREEN across every other registry test once its pair is varied on
// the request. This is the arm that refuses that green.
type ledgerRow struct {
	// Name is the registry Name (minus any "/variant" suffix) this constrains.
	Name string
	// ReadBack is a zero value of the type the verb's SECOND READ decodes into.
	ReadBack any
	// MutateRequest perturbs the shared package-level request fixture and
	// returns the restore. Both halves must visibly move under it.
	MutateRequest func() func()
}

var ledgerRows = []ledgerRow{
	{
		Name:     "renderStampVerdict",
		ReadBack: taskboard.CriterionItem{},
		MutateRequest: func() func() {
			prev := stampVerdictReq
			stampVerdictReq.index = prev.index + 7
			return func() { stampVerdictReq = prev }
		},
	},
}

// TestLedgerRowsAreProbedWithTheStoredRow enforces the three facts above for
// every enrolled ledger row, and fails if an enrolled row is not in the
// registry at all (so the check can never pass vacuously).
func TestLedgerRowsAreProbedWithTheStoredRow(t *testing.T) {
	byName := map[string]ledgerRow{}
	for _, r := range ledgerRows {
		byName[r.Name] = r
	}
	seen := map[string]bool{}
	for _, site := range successClaimRegistry() {
		base := strings.SplitN(site.Name, "/", 2)[0]
		row, ok := byName[base]
		if !ok {
			continue
		}
		seen[base] = true

		bt, ct := reflect.TypeOf(site.Backed), reflect.TypeOf(site.Contradicted)
		if bt != ct {
			t.Errorf("%s: Backed is %v but Contradicted is %v — a ledger row's two halves are the SAME "+
				"stored row differing in state, never a request weighed against a response", site.Name, bt, ct)
			continue
		}
		if want := reflect.TypeOf(row.ReadBack); bt != want {
			t.Errorf("%s is probed with %v, but the verb's second read decodes into %v — "+
				"a ledger receipt must be probed with what the STORE handed back", site.Name, bt, want)
			continue
		}

		// The shared-request-fixture proof, asserted behaviorally: perturb the ONE
		// package-level request var and both halves must print something different.
		beforeBacked := renderClaim(t, site, site.Backed)
		beforeContradicted := renderClaim(t, site, site.Contradicted)
		restore := row.MutateRequest()
		afterBacked := renderClaim(t, site, site.Backed)
		afterContradicted := renderClaim(t, site, site.Contradicted)
		restore()
		for _, h := range []struct {
			half          string
			before, after string
		}{
			{"Backed", beforeBacked, afterBacked},
			{"Contradicted", beforeContradicted, afterContradicted},
		} {
			if h.before == h.after {
				t.Errorf("%s.%s prints the same bytes after the SHARED request fixture changed — "+
					"that half is not rendering through the one package-level request, so the pair is not "+
					"a request-fixed / store-varied ledger row.\nbefore: %q\nafter:  %q",
					site.Name, h.half, h.before, h.after)
			}
		}
	}
	for _, r := range ledgerRows {
		if !seen[r.Name] {
			t.Errorf("%s is enrolled as a ledger row but is not in the success-claim registry — "+
				"the ledger-row property would pass vacuously", r.Name)
		}
	}
}

// siteResponseTypedRows are the enrollments whose Backed/Contradicted MUST be
// types internal/cloudclient returns (the provenance convention in this file's
// header). Pinned by name, and the names are also in requiredEnrollments, so a
// rename that would dodge this check fails the floor first.
//
// This list is a FLOOR, not the scope. On its own it grandfathers by enumeration:
// the SIXTH site receipt someone adds next wave would be uncovered until a human
// remembered to append it here, which is the same "a claim nobody checked" shape
// the registry exists to kill. So the check ALSO covers every registry row whose
// name carries siteRenderPrefix — the list makes deletion fail, the prefix makes
// omission fail. A future site render that legitimately cannot be probed with a
// response type is a real finding, not an exemption to add here.
const siteRenderPrefix = "renderSite"

var siteResponseTypedRows = []string{
	"renderSiteCreated",
	"renderSiteDeployVerdict",
	"renderSiteRolledBack",
	"renderSiteDeleted",
	"renderSiteSettingsUpdated",
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

// TestSiteClaimsAreProbedWithResponseTypes closes the gate's own hole for the
// site rows. TestSuccessClaimsChangeWhenTheResponseDoes constrains the RENDER and
// says nothing about where the probe values came from, so a request-echo receipt
// can go green by varying the request. Here the pinned site rows must be probed
// with types internal/cloudclient RETURNS — a request body (SpawnSiteCreate is
// only ever a parameter) is not one, and fails.
func TestSiteClaimsAreProbedWithResponseTypes(t *testing.T) {
	returned := cloudclientReturnedTypes(t)
	if !returned["SpawnSite"] || !returned["SiteDeployment"] {
		t.Fatalf("scan of internal/cloudclient found no SpawnSite/SiteDeployment return — the check would pass vacuously (found %d types)", len(returned))
	}
	if returned["SpawnSiteCreate"] {
		t.Fatalf("SpawnSiteCreate is a REQUEST body but the scan calls it returned — the provenance check cannot tell request from response")
	}
	pinned := map[string]bool{}
	for _, n := range siteResponseTypedRows {
		pinned[n] = true
	}
	seen := map[string]bool{}
	for _, site := range successClaimRegistry() {
		base := strings.SplitN(site.Name, "/", 2)[0]
		// Pinned by name (the floor) OR by the site-render prefix (the scope), so a
		// receipt added later is covered without anyone remembering to enrol it here.
		if !pinned[base] && !strings.HasPrefix(base, siteRenderPrefix) {
			continue
		}
		seen[base] = true
		for _, probe := range []struct {
			half string
			v    any
		}{{"Backed", site.Backed}, {"Contradicted", site.Contradicted}} {
			typ := reflect.TypeOf(probe.v)
			for typ != nil && typ.Kind() == reflect.Ptr {
				typ = typ.Elem()
			}
			if typ == nil || !strings.HasSuffix(typ.PkgPath(), "internal/cloudclient") || !returned[typ.Name()] {
				t.Errorf("%s.%s is probed with %v, which internal/cloudclient never RETURNS — "+
					"a success claim must be probed with what the server sent back, never with the request "+
					"(a request-echo render passes the change-when-the-response-does property on its own)",
					site.Name, probe.half, typ)
			}
		}
	}
	for _, n := range siteResponseTypedRows {
		if !seen[n] {
			t.Errorf("%s is pinned as response-typed but is not enrolled in the registry", n)
		}
	}
}

// cloudclientReturnedTypes is the set of type names internal/cloudclient hands
// BACK — parsed from its `) (T, error)` result lists, so it needs no build tags
// and no reflection over unexported API.
func cloudclientReturnedTypes(t *testing.T) map[string]bool {
	t.Helper()
	entries, err := os.ReadDir("../cloudclient")
	if err != nil {
		t.Fatalf("read internal/cloudclient sources: %v", err)
	}
	// `) (T, error)`, `) (*T, error)` and `) ([]T, error)` — a method that hands back
	// a slice returns that element type just as surely as one that hands back a value,
	// and missing it would fail a legitimate row with a confusing message.
	re := regexp.MustCompile(`\)\s*\((?:\[\])?\*?(?:\w+\.)?(\w+), error\)`)
	out := map[string]bool{}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		body, rerr := os.ReadFile("../cloudclient/" + name)
		if rerr != nil {
			t.Fatalf("read ../cloudclient/%s: %v", name, rerr)
		}
		for _, m := range re.FindAllStringSubmatch(string(body), -1) {
			out[m[1]] = true
		}
	}
	return out
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
