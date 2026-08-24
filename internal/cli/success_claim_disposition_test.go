package cli

// success_claim_disposition_test.go is the STRUCTURAL half of the success-claim
// gate: the arm that stops a registry row passing on an IDENTITY ECHO.
//
// WHAT THE BEHAVIORAL GATE CANNOT SEE. TestSuccessClaimsChangeWhenTheResponseDoes
// (success_claim_registry_test.go) asks one question — do the two halves print
// different bytes? — and a row can answer YES by varying the two fields the verb
// cannot change. The pre-repair hzResDone row varied volume ID 9→10 and Name
// data-1→data-2 and went green: two DIFFERENT volumes print two different lines,
// which says nothing whatever about whether the attach took. Same shape on
// supportAddRun.success (host.Name + host.IP both moved, and deleting token_id /
// cp_row_id / max_class from the payload left the row PASSING).
//
// WHY THE OBVIOUS FIX WAS REFUTED FIRST (charter PDS-D363). The direction was to
// widen TestSiteClaimsAreProbedWithResponseTypes. That was proven UNSOUND by
// mutation — renaming an honest ledger probe to renderSiteStampVerdict made the
// arm fire and then REJECT taskboard.CriterionItem, a type the store genuinely
// returns — and it would have been a NO-OP anyway, because the vacuous hzResDone
// row already probed hcloud.Volume, a type hcloud-go really hands back. THE
// VIOLATED PROPERTY IS RELEVANCE, NOT PROVENANCE. So that test is left exactly as
// it is (byte-identical: its pinned[] list, its renderSite prefix scope and its
// PkgPath arm) and the relevance property is asserted here instead.
//
// THE THREE ARMS, plus completeness:
//
//	ARM 1  THE PROBE IS A DECODE TARGET. deref(TypeOf(Backed)) must be a named
//	       type declared OUTSIDE internal/cli, or an unnamed map/slice — the
//	       shapes a JSON decode or a foreign API hands back. A [2]string tuple,
//	       an unnamed struct, or a type this package declared for itself is a
//	       shape the ROW invented, and a row that invents its own probe is
//	       measuring itself.
//	ARM 2  IDENTITY HELD FIXED, THE AXIS DECLARED (PDS-D355). Declared identity
//	       paths must be DeepEqual across the pair; the row must declare at least
//	       one post-condition path (AN EMPTY POST SET IS A RED); every declared
//	       post path must actually differ; and — the tooth that kills the identity
//	       echo — EVERY differing path must be declared. A row that varies the id
//	       "on the side" fails whether or not its named axis moves.
//	ARM 3  PER-FIELD ATTRIBUTION ON EVERY SURFACE. For each declared post path, a
//	       pair differing ONLY in that field must change the printed bytes in
//	       table AND in json. This is the prospective catcher: it is what reds a
//	       field's deletion from the receipt (e.g. the fencing epoch) that the
//	       behavioral gate cannot see, because the behavioral gate is satisfied by
//	       the row's OTHER differences.
//	COMPLETENESS  every registry row carries a disposition, expressed as FIELD
//	       PATHS and never as prose. There is deliberately NO exemption list: a
//	       guard whose first act is an exception for itself is not shippable
//	       (PDS-D366), and grandfathering-by-enumeration is the exact shape the
//	       registry file's own header condemns.
//
// KNOWN HOLE, LEFT AS A NOTE RATHER THAN A SILENCE. Arm 1's unnamed-map carve-out
// is REQUIRED (instTransferDone and the roster row are honestly probed with the
// decoded body, which has no Go type), and it is a hole: a row could probe a map
// it built itself. Nothing here closes that; arms 2 and 3 constrain what such a
// row may vary and must print, which is a fence around the hole, not a lid on it.
//
// MADE ABLE TO FAIL, BOTH DIRECTIONS (reproduce before trusting it):
//   - rename hzDestroyIdentity's Name in BOTH halves → the failure set is
//     byte-identical (the guard keys on the RELATION, not on the strings);
//   - vary hzResDone/destroy-confirmed on identity instead of gone-ness (Backed
//     &Volume{ID:9}, Contradicted &Volume{ID:10}) → arm 2 reds twice (the declared
//     @presence axis no longer differs; ID differs undeclared) and arm 3 reds
//     (the @presence variant prints identical bytes), while every SHIPPED test in
//     success_claim_registry_test.go stays green.

import (
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// claimDisposition is one registry row's DECLARED axis. It carries no prose
// field by construction — only field paths — so it cannot degrade into a row of
// self-assessments the way a "justification" string would.
type claimDisposition struct {
	// Name is the registry Name EXACTLY, "/variant" suffix included: two
	// variants of one render can hold different things fixed.
	Name string
	// Identity is the set of probe paths held FIXED across the pair — the fields
	// the verb cannot change. Empty is legal and common: many receipts take their
	// identity as an argument (the box name, the resolved volume id), so it is
	// not in the probe at all. Those rows declare IdentityFixture instead.
	Identity []string
	// Post is the post-condition axis: the paths the pair varies on. Never empty.
	Post []string
	// IdentityFixture perturbs the package-level fixture the row holds its
	// identity in, and returns the restore. BOTH halves must visibly move under
	// it — the behavioral proof that the identity really is shared and fixed,
	// rather than baked into one half.
	IdentityFixture func() func()
}

// claimDispositions is the disposition for every registry row. Adding a row to
// successClaimRegistry without adding one here fails the completeness arm.
var claimDispositions = []claimDisposition{
	// ── cloud_autoupdate_cmd.go ─────────────────────────────────────────────
	// The policy's Enabled flag is the state the verb is NOT claiming to have
	// changed in the pin/unpin/pause/resume rows, so it is the identity there.
	{Name: "autoupdateReceipt/pin", Identity: []string{"Enabled"}, Post: []string{"PinnedRelease"}},
	{Name: "autoupdateReceipt/unpin", Identity: []string{"Enabled"}, Post: []string{"PinnedRelease"}},
	{Name: "autoupdateReceipt/pause", Identity: []string{"Enabled"}, Post: []string{"Paused"}},
	{Name: "autoupdateReceipt/resume", Identity: []string{"Enabled"}, Post: []string{"Paused"}},
	// The fallthrough claims nothing specific, so EVERY field of the policy is
	// its post-condition — and each one has to show on both surfaces.
	{Name: "autoupdateReceipt/default", Post: []string{"Enabled", "Paused", "PinnedRelease"}},
	{Name: "autoupdatePolicySummary", Post: []string{"Enabled", "Paused", "PinnedRelease"}},

	// ── cloud_rollback_cmd.go ───────────────────────────────────────────────
	{Name: "renderRollbackResult/target-sha", Identity: []string{"PinnedRelease"}, Post: []string{"TargetSHA"}},
	{Name: "renderRollbackResult/no-target-sha", Post: []string{"TargetSHA@presence"}},

	// ── cloud12_cmd.go ──────────────────────────────────────────────────────
	{
		Name:     "renderProvisioned",
		Identity: []string{"ID", "Name", "URL", "Mode"},
		Post:     []string{"HealthStatus"},
	},

	// ── hetzner_cmd.go — the server surface's post-read ─────────────────────
	{Name: "hzDone/post-condition", Identity: []string{"ID", "Name"}, Post: []string{"Status"}},
	{Name: "hzDone/narrowed-restart", Identity: []string{"ID", "Name"}, Post: []string{"Status"}},
	{Name: "hzPartial", Identity: []string{"ID", "Name"}, Post: []string{"Status"}},

	// ── hetzner_respost.go — the destroy receipt ────────────────────────────
	// The probe IS the confirming read's answer, so the post-condition is its
	// PRESENCE: nil ⇒ the API says the volume is gone (the claim is earned),
	// non-nil ⇒ it survived (the claim is refused). The identity cannot be in
	// the probe — PDS-D400 binds the gone-check to the ALREADY RESOLVED id — so
	// it is held in hzDestroyIdentity and proven fixed by mutating it.
	{
		Name: "hzResDone/destroy-confirmed",
		Post: []string{"@presence"},
		IdentityFixture: func() func() {
			prev := hzDestroyIdentity
			hzDestroyIdentity.ID, hzDestroyIdentity.Name = prev.ID+100, prev.Name+"-moved"
			return func() { hzDestroyIdentity = prev }
		},
	},

	// ── hetzner_instance_transfer_cmd.go ────────────────────────────────────
	{Name: "instTransferDone", Post: []string{"health"}},

	// ── login_device.go ─────────────────────────────────────────────────────
	{Name: "emitDeviceLoginSuccess", Identity: []string{"Token"}, Post: []string{"TeamID"}},

	// ── tasks_next_cmd.go ───────────────────────────────────────────────────
	{
		Name: "emitFrontierClaim",
		Post: []string{"Task.DocID", "Task.Title"},
		IdentityFixture: func() func() {
			prev := frontierGrantEpoch
			frontierGrantEpoch = prev + 11
			return func() { frontierGrantEpoch = prev }
		},
	},
	{
		Name:     "emitFrontierClaim/epoch",
		Identity: []string{"OK"},
		Post:     []string{"Epoch"},
		IdentityFixture: func() func() {
			prev := frontierPick
			frontierPick.Task.Title = prev.Task.Title + " (moved)"
			return func() { frontierPick = prev }
		},
	},

	// ── cloud_support_cmd.go ────────────────────────────────────────────────
	// `capacity.max_class` is LOAD-BEARING and must not be tidied away to
	// []string{"status"}: it is the tooth of the mutation proof for this row.
	// Arm 3 synthesises the single-axis pair through probeVaryingOnly — status
	// held at "idle" on BOTH halves, only the capacity moved — so dropping the
	// capacity from supportOnlineNarration reds here. Shorten the list and that
	// mutation goes green while the receipt quietly stops naming what it measured.
	{Name: "supportAddRun.done/online-roster-row", Post: []string{"status", "capacity.max_class"}},
	// @len straddles the clean-vs-swept branch: it proves the receipt switches
	// branches with the zone's answer, and NOTHING about the swept branch's
	// payload. The row below is the branch-internal half.
	{Name: "supportRemoveRun.done/dns-swept", Post: []string{"@len"}},
	{Name: "supportRemoveRun.done/dns-swept-names", Post: []string{"#0"}},
	{Name: "supportAddRun.success/max-class", Post: []string{"capacity_stdout"}},
	// Same axis, the DEGRADED fork: the contradicting half is a box whose answer
	// carries no class at all, so the post-condition the receipt must switch on is
	// still the box's raw stdout.
	{Name: "supportAddRun.success/max-class-degraded", Post: []string{"capacity_stdout"}},
	{
		Name:     "supportAddRun.success",
		Identity: []string{"ID", "Name"},
		Post:     []string{"IP"},
		IdentityFixture: func() func() {
			prev := supportAddIdentity
			supportAddIdentity.name = prev.name + "-moved"
			return func() { supportAddIdentity = prev }
		},
	},

	// ── cloud_site_cmd.go — the spawner's receipts ──────────────────────────
	{
		Name:     "renderSiteCreated/doc-type-binding",
		Identity: []string{"ID", "Name", "Slug", "Workspace", "Project", "Dataset"},
		Post:     []string{"DocType"},
	},
	{
		Name:     "renderSiteCreated/dataset-binding",
		Identity: []string{"ID", "Name", "Slug", "DocType"},
		Post:     []string{"Workspace", "Project", "Dataset"},
	},
	{
		Name:     "renderSiteDeployVerdict/live-vs-failed",
		Identity: []string{"ID"},
		Post:     []string{"Status", "URL"},
	},
	{Name: "renderSiteDeployVerdict/live-no-url", Identity: []string{"ID", "Status"}, Post: []string{"URL"}},
	{
		Name:     "renderSiteRolledBack",
		Identity: []string{"OK", "PreviousDeploymentID"},
		Post:     []string{"DeploymentID"},
	},
	{Name: "renderSiteDeleted", Identity: []string{"Slug"}, Post: []string{"OK", "Status"}},
	{
		Name:     "renderSiteSettingsUpdated",
		Identity: []string{"ID", "Name", "Slug", "Dataset"},
		Post:     []string{"Theme"},
	},

	// ── tasks_stamp_cmd.go — the ledger row the store actually holds ────────
	{Name: "renderStampVerdict", Identity: []string{"Criterion"}, Post: []string{"Met", "Evidence"}},

	// ── tasks_close_pulse_cmd.go — stamp's two siblings on the same ledger ──
	// close: the criteria tally is what the row carried going in, so it is the
	// identity; the SEAL is the post-condition — an "open" where a "done" was
	// asked for is precisely the close that did not land.
	{Name: "renderCloseVerdict", Identity: []string{"Met", "Total"}, Post: []string{"LifecycleStatus"}},
	// pulse: the lease it renewed is the identity (the same claim before and
	// after); the now-line the board renders is the post-condition, and its
	// absence is the pulse that never reached a reader.
	// The axis is the PRESENCE of the now-line, not its text: the failure this
	// read-back exists for is a pulse that renewed the lease and left the board
	// with nothing to render.
	{Name: "renderPulseVerdict", Identity: []string{"ClaimWorker", "ClaimEpoch"}, Post: []string{"Now@presence"}},

	// ── migrate_cmd.go — the count is the LENGTH of what the server returned ─
	// The transaction id is the thing the write cannot change about itself, so
	// it is the identity; the post-condition is how many results came back, and
	// @len is precisely the axis (one result for a two-document batch IS the
	// short write the old `written += len(batch)` could not see).
	{Name: "migrateTypeReceipt", Identity: []string{"transactionId"}, Post: []string{"results@len"}},

	// ── tasks_create_cmd.go — the birth receipt reads the PERSISTED record ───
	// The id and the draft flag are what the create asked for and got back; the
	// claim under test is the lifecycle the row was BORN with, which the CLI
	// itself defaults into the request — so it is the one path that must move.
	{
		Name:     "renderTaskCreated",
		Identity: []string{"results.#0.document._id", "results.#0.document._draft"},
		Post:     []string{"results.#0.document.lifecycle_status"},
	},
}

func dispositionsByName(t *testing.T) map[string]claimDisposition {
	t.Helper()
	out := map[string]claimDisposition{}
	for _, d := range claimDispositions {
		if _, dup := out[d.Name]; dup {
			t.Fatalf("two dispositions declare %q — one row, one declared axis", d.Name)
		}
		out[d.Name] = d
	}
	return out
}

// TestClaimProbesCoverEveryRegistryRow is the COMPLETENESS arm, in both
// directions: a row with no disposition fails here (so a new receipt cannot join
// the registry without declaring what it holds fixed), and a disposition naming
// no row fails too (so the arms below can never run on an empty set).
func TestClaimProbesCoverEveryRegistryRow(t *testing.T) {
	byName := dispositionsByName(t)
	seen := map[string]bool{}
	rows := successClaimRegistry()
	if len(rows) == 0 {
		t.Fatal("the success-claim registry is empty — every arm in this file would pass vacuously")
	}
	for _, site := range rows {
		if _, ok := byName[site.Name]; !ok {
			t.Errorf("registry row %q carries no disposition — declare its identity/post-condition FIELD PATHS in "+
				"claimDispositions. There is no exemption list: a row nobody can say what varies is a row nobody checked", site.Name)
			continue
		}
		seen[site.Name] = true
	}
	for _, d := range claimDispositions {
		if !seen[d.Name] {
			t.Errorf("disposition %q names no registry row — a stale disposition is an arm that runs on nothing", d.Name)
		}
	}
}

// TestClaimProbesAreDecodeTargets is ARM 1.
func TestClaimProbesAreDecodeTargets(t *testing.T) {
	cliPkg := reflect.TypeOf(claimSite{}).PkgPath()
	if cliPkg == "" {
		t.Fatal("cannot resolve internal/cli's package path — the arm would pass vacuously")
	}
	for _, site := range successClaimRegistry() {
		for _, half := range probeHalves(site) {
			typ := reflect.TypeOf(half.v)
			for typ != nil && typ.Kind() == reflect.Ptr {
				typ = typ.Elem()
			}
			if typ == nil {
				t.Errorf("%s.%s is an untyped nil — a probe must be a value some decode produces", site.Name, half.half)
				continue
			}
			switch {
			// The carve-out, and the hole it leaves (see the header): a decoded
			// JSON body has no Go type, and a list a foreign API returned has no
			// authored arity. An ARRAY does — [2]string is a tuple the row wrote —
			// and it lands in the default arm below.
			case typ.Name() == "" && (typ.Kind() == reflect.Map || typ.Kind() == reflect.Slice):
			case typ.PkgPath() != "" && typ.PkgPath() != cliPkg:
			default:
				t.Errorf("%s.%s is probed with %v, which is not a DECODE TARGET — the probe must be a named type "+
					"declared outside internal/cli (what a client/SDK hands back) or an unnamed map/slice (a decoded "+
					"body). A tuple or a type this package declared for itself is a shape the ROW invented, so the "+
					"row is measuring its own fixture rather than the server's answer",
					site.Name, half.half, typ)
			}
		}
	}
}

// TestClaimProbesHoldIdentityFixed is ARM 2.
func TestClaimProbesHoldIdentityFixed(t *testing.T) {
	byName := dispositionsByName(t)
	for _, site := range successClaimRegistry() {
		disp, ok := byName[site.Name]
		if !ok {
			continue // reported by the completeness arm
		}
		t.Run(site.Name, func(t *testing.T) {
			if len(disp.Post) == 0 {
				t.Fatalf("%s declares NO post-condition path — an empty post set is a RED. A receipt whose pair "+
					"varies on nothing it claims is an identity echo, however different the two lines look", site.Name)
			}
			backed, contradicted := reflect.ValueOf(site.Backed), reflect.ValueOf(site.Contradicted)

			for _, p := range disp.Identity {
				b, okB := valueAt(backed, p)
				c, okC := valueAt(contradicted, p)
				if !okB || !okC {
					t.Errorf("%s: identity path %q does not resolve in both halves — a path that is not there cannot be held fixed", site.Name, p)
					continue
				}
				if !reflect.DeepEqual(valueOrNil(b), valueOrNil(c)) {
					t.Errorf("%s: identity path %q is NOT held fixed (%v vs %v) — the pair varies on a field the verb "+
						"cannot change, so the printed difference proves nothing about the post-condition",
						site.Name, p, valueOrNil(b), valueOrNil(c))
				}
			}

			declared := map[string]bool{}
			for _, p := range disp.Post {
				declared[p] = true
				if _, okB := valueAt(backed, p); !okB {
					t.Errorf("%s: post-condition path %q does not resolve in the backed half", site.Name, p)
				}
			}
			for _, p := range disp.Identity {
				if declared[p] {
					t.Errorf("%s: %q is declared as BOTH identity and post-condition — it can only be one", site.Name, p)
				}
			}

			// The tooth: every path that differs must be declared. A row that
			// varies the id "on the side" fails here even when its named axis moves.
			diffs := diffPaths(backed, contradicted, "")
			sort.Strings(diffs)
			for _, p := range diffs {
				if !declared[p] {
					t.Errorf("%s varies on %q, which is declared NEITHER identity NOR post-condition — an undeclared "+
						"difference is how an identity echo passes: the receipt prints two different lines because it "+
						"was handed two different resources. Declare it, or hold it fixed", site.Name, p)
				}
			}
			seen := map[string]bool{}
			for _, p := range diffs {
				seen[p] = true
			}
			for _, p := range disp.Post {
				if !seen[p] {
					t.Errorf("%s declares post-condition %q but the two halves AGREE on it — the declared axis is not "+
						"the axis the pair varies on", site.Name, p)
				}
			}

			// The shared-identity-fixture proof, asserted behaviorally.
			if disp.IdentityFixture != nil {
				beforeB := renderClaimAt(t, site, site.Backed, "table")
				beforeC := renderClaimAt(t, site, site.Contradicted, "table")
				restore := disp.IdentityFixture()
				afterB := renderClaimAt(t, site, site.Backed, "table")
				afterC := renderClaimAt(t, site, site.Contradicted, "table")
				restore()
				for _, h := range []struct{ half, before, after string }{
					{"Backed", beforeB, afterB},
					{"Contradicted", beforeC, afterC},
				} {
					if h.before == h.after {
						t.Errorf("%s.%s prints the same bytes after the SHARED identity fixture moved — that half is "+
							"not rendering through the one fixture, so 'identity held fixed' is a claim about the "+
							"fixtures rather than a fact about the render.\nbefore: %q\nafter:  %q",
							site.Name, h.half, h.before, h.after)
					}
				}
			}
		})
	}
}

// TestClaimProbesAttributeEveryPostConditionPerSurface is ARM 3: per-field
// attribution, on the human table surface AND on the machine json one. A receipt
// that carries a field on only one surface fails here — which is the point: the
// machine envelope is what scripts branch on and the table line is what an
// operator reads, and a post-condition that moves only one of them leaves the
// other saying the same thing about two different worlds.
func TestClaimProbesAttributeEveryPostConditionPerSurface(t *testing.T) {
	byName := dispositionsByName(t)
	for _, site := range successClaimRegistry() {
		disp, ok := byName[site.Name]
		if !ok {
			continue
		}
		t.Run(site.Name, func(t *testing.T) {
			for _, p := range disp.Post {
				variant, err := probeVaryingOnly(site.Backed, site.Contradicted, p)
				if err != nil {
					t.Errorf("%s: cannot build a pair varying only on %q: %v", site.Name, p, err)
					continue
				}
				for _, surface := range []string{"table", "json"} {
					base := renderClaimAt(t, site, site.Backed, surface)
					got := renderClaimAt(t, site, variant, surface)
					if base == got {
						t.Errorf("%s: changing ONLY %q leaves the %s receipt byte-identical — that field is claimed by "+
							"the sentence but pinned by nothing, so deleting it from the render would not red this "+
							"gate.\nbytes: %q", site.Name, p, surface, base)
					}
				}
			}
		})
	}
}

// PDS-D431: TestClaimProbesMirrorTheProductionNarration stood here. It pinned
// three mirror consts against the production source because the two support rows
// REPRODUCED stepOnline's and stepDNS's sentences rather than calling them. The
// narrations are now pure composers in cloud_support_cmd.go and the rows call
// them, so the drift this arm guarded against can no longer exist — a mirror
// pinned against its original is strictly weaker than no mirror at all.

// ── surfaces ────────────────────────────────────────────────────────────────

// renderClaimAt is renderClaim with the output surface as a parameter: arm 3
// needs the machine envelope as well as the human line.
func renderClaimAt(t *testing.T, site claimSite, resp any, surface string) string {
	t.Helper()
	var stdout, stderr strings.Builder
	out := newWriter(&stdout, &stderr)
	out.output = surface
	out.color = false
	site.Render(out, resp)
	return stdout.String() + stderr.String()
}

type probeHalf struct {
	half string
	v    any
}

func probeHalves(site claimSite) []probeHalf {
	return []probeHalf{{"Backed", site.Backed}, {"Contradicted", site.Contradicted}}
}

// ── the path grammar ────────────────────────────────────────────────────────
//
// A path is dotted segments — exported struct field names and map keys — with
// "#i" for a slice index, and three TERMINAL markers for differences that are
// not about a leaf's value:
//
//	@presence  one side is nil and the other is not (a destroy's post-condition:
//	           the confirming read either handed a resource back or did not)
//	@len       two slices of different length
//	@type      an interface holding two different dynamic types
//
// A marker terminates the path: the node it names is replaced wholesale when
// arm 3 builds its one-field variant, because there is no field to reach into.

const (
	markPresence = "@presence"
	markLen      = "@len"
	markType     = "@type"
)

func joinPath(prefix, seg string) string {
	if prefix == "" {
		return seg
	}
	return prefix + "." + seg
}

func markPath(prefix, mark string) string {
	if prefix == "" {
		return mark
	}
	return prefix + mark
}

func valueOrNil(v reflect.Value) any {
	if !v.IsValid() {
		return nil
	}
	return v.Interface()
}

// diffPaths reports every path at which the two halves differ. Unexported struct
// fields are skipped: a foreign package's unexported field cannot be set from a
// composite literal, so a row cannot vary one — and reaching it would need
// unsafe, which this gate deliberately does not carry.
func diffPaths(a, b reflect.Value, prefix string) []string {
	a, b = deInterface(a), deInterface(b)
	switch {
	case !a.IsValid() && !b.IsValid():
		return nil
	case !a.IsValid() || !b.IsValid():
		return []string{markPath(prefix, markPresence)}
	case a.Type() != b.Type():
		return []string{markPath(prefix, markType)}
	}
	switch a.Kind() {
	case reflect.Ptr:
		if a.IsNil() != b.IsNil() {
			return []string{markPath(prefix, markPresence)}
		}
		if a.IsNil() {
			return nil
		}
		return diffPaths(a.Elem(), b.Elem(), prefix)
	case reflect.Struct:
		var out []string
		for i := 0; i < a.NumField(); i++ {
			f := a.Type().Field(i)
			if !f.IsExported() {
				continue
			}
			out = append(out, diffPaths(a.Field(i), b.Field(i), joinPath(prefix, f.Name))...)
		}
		return out
	case reflect.Map:
		var out []string
		for _, k := range unionKeys(a, b) {
			av, bv := a.MapIndex(k), b.MapIndex(k)
			out = append(out, diffPaths(av, bv, joinPath(prefix, fmt.Sprint(k.Interface())))...)
		}
		return out
	case reflect.Slice:
		if a.IsNil() != b.IsNil() && a.Len() == b.Len() {
			return nil // nil and empty say the same thing to every renderer here
		}
		if a.Len() != b.Len() {
			return []string{markPath(prefix, markLen)}
		}
		var out []string
		for i := 0; i < a.Len(); i++ {
			out = append(out, diffPaths(a.Index(i), b.Index(i), joinPath(prefix, fmt.Sprintf("#%d", i)))...)
		}
		return out
	default:
		if !reflect.DeepEqual(a.Interface(), b.Interface()) {
			return []string{prefix}
		}
		return nil
	}
}

func unionKeys(a, b reflect.Value) []reflect.Value {
	seen := map[string]reflect.Value{}
	for _, m := range []reflect.Value{a, b} {
		if m.IsValid() && !m.IsNil() {
			for _, k := range m.MapKeys() {
				seen[fmt.Sprint(k.Interface())] = k
			}
		}
	}
	names := make([]string, 0, len(seen))
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]reflect.Value, 0, len(names))
	for _, n := range names {
		out = append(out, seen[n])
	}
	return out
}

func deInterface(v reflect.Value) reflect.Value {
	for v.IsValid() && v.Kind() == reflect.Interface {
		if v.IsNil() {
			return reflect.Value{}
		}
		v = v.Elem()
	}
	return v
}

func splitPath(path string) ([]string, string) {
	mark := ""
	for _, m := range []string{markPresence, markLen, markType} {
		if strings.HasSuffix(path, m) {
			mark, path = m, strings.TrimSuffix(path, m)
			break
		}
	}
	path = strings.TrimSuffix(path, ".")
	if path == "" {
		return nil, mark
	}
	return strings.Split(path, "."), mark
}

// valueAt resolves a path against a probe. A marked path resolves to the NODE
// the marker names (its presence/length/dynamic type is the value in question).
func valueAt(root reflect.Value, path string) (reflect.Value, bool) {
	segs, _ := splitPath(path)
	cur := deInterface(root)
	for _, seg := range segs {
		if !cur.IsValid() {
			return reflect.Value{}, false
		}
		for cur.Kind() == reflect.Ptr {
			if cur.IsNil() {
				return reflect.Value{}, false
			}
			cur = cur.Elem()
		}
		switch cur.Kind() {
		case reflect.Struct:
			f := cur.FieldByName(seg)
			if !f.IsValid() {
				return reflect.Value{}, false
			}
			cur = deInterface(f)
		case reflect.Map:
			v := cur.MapIndex(reflect.ValueOf(seg).Convert(cur.Type().Key()))
			if !v.IsValid() {
				return reflect.Value{}, false
			}
			cur = deInterface(v)
		case reflect.Slice, reflect.Array:
			var i int
			if _, err := fmt.Sscanf(seg, "#%d", &i); err != nil || i >= cur.Len() {
				return reflect.Value{}, false
			}
			cur = deInterface(cur.Index(i))
		default:
			return reflect.Value{}, false
		}
	}
	return cur, cur.IsValid()
}

// probeVaryingOnly returns a copy of backed with ONE path taken from
// contradicted — arm 3's "a pair differing only in that field". It rebuilds
// functionally (copy-on-write down the path) so nothing addresses, aliases or
// mutates the shared fixtures, and it never reaches an unexported field.
func probeVaryingOnly(backed, contradicted any, path string) (any, error) {
	segs, mark := splitPath(path)
	if mark != "" {
		// A marker must name a node whose presence/length is a real question.
		// Hung on anything else — e.g. @presence on a struct VALUE, which is
		// never absent — it would resolve to the whole probe and this arm would
		// silently degrade into the behavioral gate it exists to strengthen.
		node, ok := nodeAt(reflect.ValueOf(backed), segs)
		if !ok {
			return nil, fmt.Errorf("path %q does not resolve in the backed half", path)
		}
		switch k := deInterface(node).Kind(); {
		case mark == markPresence && (k == reflect.Ptr || k == reflect.Map || k == reflect.Slice || k == reflect.Interface):
		case mark == markLen && (k == reflect.Slice || k == reflect.Array || k == reflect.Map):
		case mark == markType:
		default:
			return nil, fmt.Errorf("%s names a %v, which can never be absent or vary in length — "+
				"the marker is a mis-declaration, not an axis", path, k)
		}
		segs = append(segs, mark)
	}
	want, ok := nodeAt(reflect.ValueOf(contradicted), segs)
	if !ok {
		return nil, fmt.Errorf("path %q does not resolve in the contradicted half", path)
	}
	out, err := withPath(reflect.ValueOf(backed), segs, want)
	if err != nil {
		return nil, err
	}
	if !out.IsValid() {
		return nil, nil
	}
	return out.Interface(), nil
}

// nodeAt is valueAt's sibling for the REPLACEMENT value: it stops at the node a
// terminal marker names rather than descending past it.
func nodeAt(root reflect.Value, segs []string) (reflect.Value, bool) {
	cur := root
	for _, seg := range segs {
		if isMark(seg) {
			return cur, true
		}
		cur = deInterface(cur)
		for cur.IsValid() && cur.Kind() == reflect.Ptr && !cur.IsNil() {
			cur = cur.Elem()
		}
		if !cur.IsValid() {
			return reflect.Value{}, false
		}
		switch cur.Kind() {
		case reflect.Struct:
			f := cur.FieldByName(seg)
			if !f.IsValid() {
				return reflect.Value{}, false
			}
			cur = f
		case reflect.Map:
			v := cur.MapIndex(reflect.ValueOf(seg).Convert(cur.Type().Key()))
			if !v.IsValid() {
				return reflect.Value{}, false
			}
			cur = v
		case reflect.Slice, reflect.Array:
			var i int
			if _, err := fmt.Sscanf(seg, "#%d", &i); err != nil || i >= cur.Len() {
				return reflect.Value{}, false
			}
			cur = cur.Index(i)
		default:
			return reflect.Value{}, false
		}
	}
	return cur, cur.IsValid()
}

func isMark(seg string) bool {
	return seg == markPresence || seg == markLen || seg == markType
}

func withPath(cur reflect.Value, segs []string, want reflect.Value) (reflect.Value, error) {
	if len(segs) == 0 || isMark(segs[0]) {
		return want, nil
	}
	if !cur.IsValid() {
		return reflect.Value{}, fmt.Errorf("path runs past a nil at %q", segs[0])
	}
	switch cur.Kind() {
	case reflect.Interface:
		return withPath(cur.Elem(), segs, want)
	case reflect.Ptr:
		if cur.IsNil() {
			return reflect.Value{}, fmt.Errorf("path runs into a nil pointer at %q", segs[0])
		}
		inner, err := withPath(cur.Elem(), segs, want)
		if err != nil {
			return reflect.Value{}, err
		}
		p := reflect.New(cur.Type().Elem())
		p.Elem().Set(inner)
		return p, nil
	case reflect.Struct:
		c := reflect.New(cur.Type()).Elem()
		c.Set(cur)
		f := c.FieldByName(segs[0])
		if !f.IsValid() || !f.CanSet() {
			return reflect.Value{}, fmt.Errorf("no settable exported field %q on %v", segs[0], cur.Type())
		}
		inner, err := withPath(f, segs[1:], want)
		if err != nil {
			return reflect.Value{}, err
		}
		f.Set(inner)
		return c, nil
	case reflect.Map:
		m := reflect.MakeMap(cur.Type())
		for _, k := range cur.MapKeys() {
			m.SetMapIndex(k, cur.MapIndex(k))
		}
		key := reflect.ValueOf(segs[0]).Convert(cur.Type().Key())
		inner, err := withPath(cur.MapIndex(key), segs[1:], want)
		if err != nil {
			return reflect.Value{}, err
		}
		m.SetMapIndex(key, inner)
		return m, nil
	case reflect.Slice:
		var i int
		if _, err := fmt.Sscanf(segs[0], "#%d", &i); err != nil || i >= cur.Len() {
			return reflect.Value{}, fmt.Errorf("bad slice index %q", segs[0])
		}
		s := reflect.MakeSlice(cur.Type(), cur.Len(), cur.Len())
		reflect.Copy(s, cur)
		inner, err := withPath(s.Index(i), segs[1:], want)
		if err != nil {
			return reflect.Value{}, err
		}
		s.Index(i).Set(inner)
		return s, nil
	default:
		return reflect.Value{}, fmt.Errorf("cannot descend into %v at %q", cur.Kind(), segs[0])
	}
}
