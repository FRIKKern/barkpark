package cli

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// ── Why this file exists: the gate covered ONE of the six lanes' areas ───────
//
// manifest_declared_fact_guard_test.go turned the defect class of
// task-ce8f04315a6d1f10 into a running rule — but it binds identifiers by ONE
// qualified package, `manifest`, so the only re-derivations it can see are the
// ones a manifest CONSUMER writes. That is where the SEED defect lived
// (#14115, mediaUploadFileArg deciding multipart from "/media" in the path
// text when the arg declares `type: "file"`).
//
// It is not where the other five lanes found theirs. Measured against the
// merged lane fixes, the manifest-bound gate covers 1 of 6 known instances:
//
//	#14115 manifest.Arg declared type      ← gated
//	#14297 a typed HTTP status vs body prose
//	#14300 a chat-host boolean read out of a negated sentence
//	#14304 a scaffy op's declared MARK vs the bare token
//	#14305 --perspective keyed on three hardcoded command ids
//	#14306 cloudFail's status vs its prose
//
// So "the class is gated instead of enumerated" was true of the manifest
// sub-shape and of nothing else: for internal/taskboard, internal/chat,
// internal/chathost, internal/apiclient, internal/agent and cmd/**, the tree's
// silence was still uninterpretable — absence of a finding was not
// distinguishable from absence of a sweep, which is exactly what the parent
// row's coverage criterion forbids assuming.
//
// This file closes that by running the SAME predicate at every package whose
// types carry declarations. Nothing about the predicate is manifest-specific:
// a string match whose haystack is a field reached off a value bound to a
// declaring type is asking a rendered string a question the struct already
// answers, whichever struct it is.
//
// ── What the sweep measured (2026-09-17, on 8c5d94750) ──────────────────────
//
// Hits over internal/ + cmd/, non-test, 437 files, per qualifier:
//
//	manifest 0 · apiclient 0 · taskboard 0 · scaffy 0 · pdrender 0 · chat 0
//	cloudclient 1 — internal/cli/cloud_status_cmd.go slotUnitMarker,
//	                strings.HasPrefix(u.Unit, slotUnitPrefix)
//
// That single hit was read AT THE SOURCE and is legitimate, which is why it is
// pinned below as a control rather than waived by line number: a systemd unit
// name genuinely IS text (`barkpark-slot@blue.service`), cloudclient.SlotUnit
// declares no kind field for the call to read instead, and the site already
// carries its own regression test for the Contains-vs-HasPrefix distinction
// (TestASiteUnitEmbeddingTheSlotTokenIsStillASiteUnit). It is the same verdict
// the prior audit reached in task-a0b1d0fd5ad0cb1b.
//
// The remaining 75 non-test strings.Contains/HasPrefix/HasSuffix sites outside
// internal/cli and outside the six hand-swept packages were also read by hand
// on 2026-09-17 (internal/taskboard 31, internal/apiclient 7, cmd/** 10,
// internal/chat 6, internal/caddyfile 5, internal/chathost 4, internal/agent 4,
// internal/manifest 3 comments, and one each in template, wasmimages, backup,
// hostguard, cloudclient). Every one parses text that IS text — SSE line
// prefixes, `drafts.` doc-id prefixes, systemd unit suffixes, markdown fences,
// label prefixes, Caddyfile syntax — or reads a typed field FIRST and falls
// back to prose only for errors this tree did not construct
// (snapshotErrorLabel in internal/taskboard/live.go tries *httpStatusError via
// errors.As before any "status 401" match: that is the #14297 fix, landed).
// No instance of the class. The zero above is a reading, not a silence.
//
// ── The one thing this does NOT claim ───────────────────────────────────────
//
// Same syntactic blind spot as the manifest gate: copying the field into a
// local first defeats it, because go/types is not vendored. Widening the
// qualifier set widens the tripwire, not the proof.

// declaredFactQualifier is one package whose types carry declarations, with the
// floors that keep its zero meaningful. A qualifier that binds nothing can
// never report a hit, so its green would say "no subjects", not "no instances"
// — the same hole TestManifestFactDetectorReachesTheRealTree closed for
// manifest. Floors are set well under the live measurement (printed by the
// test) so refactoring does not trip them; they catch a COLLAPSE, not drift.
type declaredFactQualifier struct {
	Pkg             string
	MinBindingFiles int
	MinBindings     int
	// KnownHits are the call sites this sweep read at the source and found
	// legitimate, keyed by SHAPE (`strings.<Fn>(<expr>)` on `<pkg>.<Type>`),
	// never by line number. A hit that is not here reds; a known hit that
	// stops appearing reds too, because then this record no longer describes
	// the tree.
	KnownHits []string
}

// declaredFactQualifiers are the declaring packages, with live numbers from
// 2026-09-17 in the comment beside each floor.
var declaredFactQualifiers = []declaredFactQualifier{
	// manifest reuses the live gate's OWN clearance list rather than a second
	// copy: both sweeps read the same tree with the same predicate, so a shape
	// cleared for one is cleared for the other, and one list cannot rot while
	// its twin stays current.
	{Pkg: "manifest", MinBindingFiles: 30, MinBindings: 60, // live: 65 files / 146 bindings
		KnownHits: manifestKnownHits},
	{Pkg: "apiclient", MinBindingFiles: 15, MinBindings: 25}, // live: 36 / 57
	{Pkg: "cloudclient", MinBindingFiles: 10, MinBindings: 40, // live: 24 / 111
		// The EqualFold entries below all arrived with the same widening
		// (task-0ab3dfa73662ee68): once the callee set became the whole
		// matching family, a case-insensitive comparison against a literal
		// became visible to this sweep. Read at the source 2026-09-20, every
		// one of them compares the WHOLE declared value against a literal —
		// which is reading the declaration, exactly like the
		// `cmd.ID == "media.upload"` shape the negative control in
		// manifest_declared_fact_guard_test.go clears, with a case fold on
		// top because the control plane's casing is not part of its contract.
		// None asks about a SUBSTRING, which is the defect class.
		//
		// The one Contains entry is different and was read separately:
		// FailureClass is the control plane's NAMED cause ("BUILD_FAILED",
		// "BOX_AT_CAPACITY_DEFERRED"), a compound name whose parts ARE its
		// grammar, and cloudclient declares no deferred flag to read instead.
		KnownHits: []string{
			"strings.HasPrefix(u.Unit) on cloudclient.SlotUnit",
			"strings.EqualFold(d.Overall) on cloudclient.DomainCheck",
			"strings.EqualFold(strings.TrimSpace(res.Beat.Status)) on cloudclient.MetricsResult",
			"strings.EqualFold(strings.TrimSpace(d.Status)) on cloudclient.SiteDeployment",
			"strings.EqualFold(strings.TrimSpace(d.Environment)) on cloudclient.SiteDeployment",
			"strings.EqualFold(d.Status) on cloudclient.SiteDeployment",
			"strings.EqualFold(dep.Status) on cloudclient.SiteDeployment",
			"strings.EqualFold(newest.ID) on cloudclient.SiteDeployment",
			"strings.Contains(strings.ToUpper(depStr(d.FailureClass))) on cloudclient.SiteDeploymentEmbed",
			"strings.EqualFold(team.Slug) on cloudclient.Team",
		}},
	{Pkg: "taskboard", MinBindingFiles: 5, MinBindings: 10}, // live: 11 / 21
	{Pkg: "pdrender", MinBindingFiles: 5, MinBindings: 10},  // live: 12 / 24
	{Pkg: "scaffy", MinBindingFiles: 2, MinBindings: 6},     // live: 4 / 17
}

// hitShape renders a hit the way KnownHits spells it: by what was asked of
// what, not by where.
func hitShape(pkg string, h manifestFactHit) string {
	return fmt.Sprintf("strings.%s(%s) on %s.%s", h.Fn, h.Expr, pkg, h.Type)
}

// sweepDeclaredFactQualifier runs the predicate over internal/ + cmd/ at one
// qualifier, returning the hits plus the reachability figures.
func sweepDeclaredFactQualifier(t *testing.T, repo, qualifier string) (hits []manifestFactHit, scanned, bindingFiles, bindings int) {
	t.Helper()
	fset := token.NewFileSet()
	for _, r := range guardScanRoots {
		root := filepath.Join(repo, r)
		if _, err := os.Stat(root); err != nil {
			t.Fatalf("scan root %s missing: %v (the sweep would pass vacuously)", root, err)
		}
		if err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			f, perr := parser.ParseFile(fset, p, nil, 0)
			if perr != nil {
				return nil
			}
			scanned++
			bound := bindDeclaredFactIdents(f, qualifier)
			if n := len(bound); n > 0 {
				bindingFiles++
				bindings += n
			}
			for _, h := range scanWithManifestBindings(fset, f, bound) {
				h.Pos = strings.TrimPrefix(h.Pos, repo+string(filepath.Separator))
				hits = append(hits, h)
			}
			return nil
		}); err != nil {
			t.Fatalf("walk %s: %v", root, err)
		}
	}
	return hits, scanned, bindingFiles, bindings
}

// TestNoStringMatchStandsInForADeclaredFactInAnyDeclaringPackage is the live
// gate for the five lane areas the manifest-bound gate cannot see.
func TestNoStringMatchStandsInForADeclaredFactInAnyDeclaringPackage(t *testing.T) {
	repo := repoRootForGuard(t)
	for _, q := range declaredFactQualifiers {
		t.Run(q.Pkg, func(t *testing.T) {
			hits, scanned, bindingFiles, bindings := sweepDeclaredFactQualifier(t, repo, q.Pkg)
			if scanned < 200 {
				t.Fatalf("scanned only %d non-test .go files under %v — the sweep did not reach the tree", scanned, guardScanRoots)
			}
			// Reachability: a qualifier nothing binds cannot report a hit, so
			// its zero would be a green with no subject.
			if bindingFiles < q.MinBindingFiles || bindings < q.MinBindings {
				t.Fatalf("the detector binds %d %s.* value(s) across %d of %d non-test files (floors: %d files, %d bindings).\n"+
					"Nothing in the tree is bound to a %s.* type any more, so this sweep's zero says \"no subjects\", not "+
					"\"no instances\". Either the import was aliased/renamed (teach bindDeclaredFactIdents the spelling) or "+
					"the consumers moved — do not lower these floors to restore the green.",
					bindings, q.Pkg, bindingFiles, scanned, q.MinBindingFiles, q.MinBindings, q.Pkg)
			}
			seen := map[string]bool{}
			known := map[string]bool{}
			for _, k := range q.KnownHits {
				known[k] = true
			}
			for _, h := range hits {
				shape := hitShape(q.Pkg, h)
				seen[shape] = true
				if known[shape] {
					continue
				}
				t.Errorf("%s: strings.%s(%s, …) asks a rendered string a question %s.%s already answers with a typed field "+
					"— read the declaration, not the spelling (task-ce8f04315a6d1f10). If the spelling genuinely IS the "+
					"fact, say so in a comment at the call site and add its SHAPE to declaredFactQualifiers[%q].KnownHits.",
					h.Pos, h.Fn, h.Expr, q.Pkg, h.Type, q.Pkg)
			}
			missing := []string{}
			for _, k := range q.KnownHits {
				if !seen[k] {
					missing = append(missing, k)
				}
			}
			sort.Strings(missing)
			if len(missing) > 0 {
				t.Errorf("recorded known-legitimate hit(s) %v no longer appear in %s consumers. This record was read at the "+
					"source on 2026-09-17; it no longer describes the tree, so re-read the site and drop or re-word the entry "+
					"rather than leaving a stale clearance standing.", missing, q.Pkg)
			}
			t.Logf("%s: %d hit(s), %d bindings across %d/%d non-test files", q.Pkg, len(hits), bindings, bindingFiles, scanned)
		})
	}
}

// seedDefectOnANonManifestDeclaration is the class at a package the manifest
// gate cannot see: a taskboard task's lifecycle read out of a rendered status
// line when the row declares it. This is the POSITIVE CONTROL for the
// widening itself — and the mutation proof that the widening MEASURES
// something, since TestManifestFactDetectorIsBlindOutsideItsOwnPackage below
// shows the manifest-bound binder reports nothing here.
const seedDefectOnANonManifestDeclaration = `package cli

import (
	"strings"

	"barkpark/internal/taskboard"
)

func isDone(row taskboard.Task) bool {
	return strings.Contains(row.StatusLine, "done")
}
`

func TestDeclaredFactDetectorFiresAtANonManifestQualifier(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "tb.go", seedDefectOnANonManifestDeclaration, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	hits := scanWithManifestBindings(fset, f, bindDeclaredFactIdents(f, "taskboard"))
	if len(hits) != 1 || hits[0].Expr != "row.StatusLine" || hits[0].Type != "Task" {
		t.Fatalf("hits = %+v, want exactly one Contains on row.StatusLine bound to taskboard.Task", hits)
	}
}

// TestManifestFactDetectorIsBlindOutsideItsOwnPackage is the RED control for
// this whole file: it pins the hole the widening fills. If the manifest-bound
// binder ever starts seeing a taskboard.Task — say because someone widened
// manifestQualifier itself — this test reds and the widening here is
// redundant, which is worth being told rather than discovering by duplication.
func TestManifestFactDetectorIsBlindOutsideItsOwnPackage(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "tb.go", seedDefectOnANonManifestDeclaration, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if hits := scanManifestFactStringMatches(fset, f); len(hits) != 0 {
		t.Fatalf("the manifest-bound detector reported %+v on a taskboard declaration — it is no longer blind outside "+
			"internal/manifest's consumers, so TestNoStringMatchStandsInForADeclaredFactInAnyDeclaringPackage may be "+
			"duplicating it", hits)
	}
}

// TestDeclaredFactDetectorStaysQuietOnLegitimateStringWorkAtAnyQualifier is the
// QUIET arm, carrying the shapes this sweep read at the source and cleared —
// so re-litigating them costs a test run, not a reading:
//
//   - a systemd unit name matched against the template PREFIX it is built from
//     (cloud_status_cmd.go slotUnitMarker: the unit name IS text, and SlotUnit
//     declares no kind field);
//   - an SSE frame's `data:` line prefix (apiclient/listen.go), which is the
//     wire grammar — a BARE string, not a field off a declaration;
//   - a typed status read through errors.As BEFORE any prose match
//     (taskboard/live.go snapshotErrorLabel) — the #14297 fix's own shape,
//     which must never be mistaken for the defect it replaced.
const legitimateStringWorkAtOtherQualifiers = `package cli

import (
	"errors"
	"strings"

	"barkpark/internal/cloudclient"
)

func legit(u cloudclient.SlotUnit, line string, err error) string {
	if strings.HasPrefix(line, "data:") {
		return "sse"
	}
	var status *httpStatusError
	if errors.As(err, &status) {
		return "typed"
	}
	if u.ActiveState == "failed" {
		return "failed"
	}
	return ""
}
`

func TestDeclaredFactDetectorStaysQuietOnLegitimateStringWorkAtAnyQualifier(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "legit2.go", legitimateStringWorkAtOtherQualifiers, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	for _, q := range declaredFactQualifiers {
		if hits := scanWithManifestBindings(fset, f, bindDeclaredFactIdents(f, q.Pkg)); len(hits) != 0 {
			t.Errorf("detector fired at qualifier %s on legitimate string work: %+v", q.Pkg, hits)
		}
	}
}
