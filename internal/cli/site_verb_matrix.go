package cli

// site_verb_matrix.go — THE SITE COMMAND MATRIX. One table, two spellings.
//
// THE HAZARD IT RETIRES. Barkpark grew two site verb trees under two nouns:
//
//	bp sites …       the fleet surface (P6): ls · show · create · deployments ·
//	                 env · domain · github · logs
//	bp cloud site …  the spawner surface (site-spawner): ls · create · deploy ·
//	                 rollback · delete · status · doctor · open · preflight ·
//	                 settings
//
// Before this table only `ls` was aliased (the two-noun ruling,
// dr-w14-bl-owner-cannot-list-own-sites), so thirteen verbs answered under
// exactly ONE noun and refused under the other — an owner standing at the wrong
// noun read `unknown site command "logs"` for a site the other noun would have
// shown them. The nouns were never two RESOURCES: `CreateSite` and
// `CreateSpawnSite` both POST /v1/sites, `GetSite` and `GetSpawnSite` both GET
// /v1/sites/:id, and `Deploy` and `DeploySpawnSite` both POST
// /v1/sites/:id/deploy. One resource, one id space, two spellings.
//
// WHAT THIS FILE IS. The single dispatch table BOTH `runSites` and
// `runCloudSite` route through. A verb is declared once, here, with its scope:
//
//   - siteVerbShared     — ONE implementation, reachable under BOTH spellings.
//     `Impl` is the only handler, so the two spellings are the same func value,
//     not two copies that can drift. Most verbs are this.
//   - siteVerbSplit      — the kind difference is REAL and the spelling picks
//     it. `create` is the only one: `bp sites create` makes a CONTAINER site
//     (BYO repo, image, scale mode); `bp cloud site create` SPAWNS a
//     content-bound site on a named instance. Same route, different request
//     body — aliasing them would silently change which kind of site you get.
//   - siteVerbSpawnerOnly — offered under `bp cloud site` only, because the
//     other spelling's answer is a different command. `deploy` is the only one:
//     the container model deploys through top-level `bp deploy <site>`, so
//     `bp sites deploy` is a REFUSAL that names both doors rather than a third
//     ambiguous deploy instruction.
//   - siteVerbReserved   — NOT in this tree at all, listed so the matrix says
//     so out loud: `bp cloud deploy` and `bp cloud rollback` are INSTANCE-level
//     (the blue/green code-slot flip of a whole Barkpark box). They are never
//     aliased into a site noun and never will be.
//
// Output and exit codes are unchanged by the aliasing: a shared verb reaching
// the same func with the same args emits the same bytes and the same status at
// either spelling, which `site_verb_matrix_test.go` proves by running both
// spellings against one recording server and diffing the request sequence, the
// stdout and the exit code.

import (
	"fmt"
	"sort"
	"strings"
)

// siteHandler is the shape every site verb reduces to. The fleet handlers in
// sites_cmd.go take no globals, so they are adapted here; the spawner handlers
// take them verbatim.
type siteHandler func(out *writer, g globals, args []string) int

// siteVerbScope classifies how a verb relates to the two spellings. See the
// file header for what each one means.
type siteVerbScope string

const (
	siteVerbShared      siteVerbScope = "shared"
	siteVerbSplit       siteVerbScope = "split"
	siteVerbSpawnerOnly siteVerbScope = "spawner-only"
	siteVerbReserved    siteVerbScope = "reserved"
)

// siteSpellingFleet / siteSpellingSpawner name the two nouns a verb can be
// reached through. They are passed to binding.handler so a split verb knows
// which door it came in by.
const (
	siteSpellingFleet   = "bp sites"
	siteSpellingSpawner = "bp cloud site"
)

// siteVerbBinding is one row of the matrix.
type siteVerbBinding struct {
	// Verb is the canonical spelling; Aliases are accepted synonyms.
	Verb    string
	Aliases []string
	Scope   siteVerbScope

	// Impl is set for siteVerbShared ONLY: one func value, both spellings. A
	// shared row leaves Fleet and Spawner nil so the two doors cannot drift.
	Impl siteHandler
	// Fleet / Spawner are set for siteVerbSplit and siteVerbSpawnerOnly, where
	// the spelling genuinely selects a different implementation.
	Fleet   siteHandler
	Spawner siteHandler

	// Summary is one line for the matrix render; KindNote names the kind
	// difference when there is one (empty when the verb is kind-agnostic).
	Summary  string
	KindNote string
}

// handler returns the implementation for one spelling, or nil when the verb is
// not offered there. For a shared verb both spellings return the SAME func
// value — that identity is the unification, and the parity test asserts it.
func (b siteVerbBinding) handler(spelling string) siteHandler {
	if b.Impl != nil {
		return b.Impl
	}
	if spelling == siteSpellingFleet {
		return b.Fleet
	}
	return b.Spawner
}

// names is the canonical verb plus every alias, in declaration order.
func (b siteVerbBinding) names() []string {
	return append([]string{b.Verb}, b.Aliases...)
}

// fleetAdapter lifts a sites_cmd.go handler (no globals) into a siteHandler.
func fleetAdapter(fn func(out *writer, args []string) int) siteHandler {
	return func(out *writer, _ globals, args []string) int { return fn(out, args) }
}

// siteVerbMatrix is THE table. Declaration order is the render order.
//
// Adding a verb to either tree means adding a row here — there is no second
// switch to forget. Do not reintroduce a `case` arm in runSites or
// runCloudSite: TestSiteVerbMatrixIsTheOnlyDispatcher reads both functions'
// source and reds on one.
// It is populated in init() rather than as a composite literal because the
// `matrix` row's handler reads the table it lives in — Go rejects that as an
// initialization cycle even though it is only ever read at call time.
var siteVerbMatrix []siteVerbBinding

func init() {
	siteVerbMatrix = []siteVerbBinding{
		{
			Verb: "ls", Aliases: []string{"list"}, Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesList),
			Summary: "list every site under your team (both kinds, one table)",
		},
		{
			Verb: "show", Aliases: []string{"get"}, Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesShow),
			Summary: "show one site by name, slug or id",
		},
		{
			Verb: "create", Scope: siteVerbSplit,
			Fleet:    fleetAdapter(runSitesCreate),
			Spawner:  runCloudSiteCreate,
			Summary:  "create a site",
			KindNote: "SPELLING PICKS THE KIND: `bp sites create` makes a CONTAINER site (BYO repo); `bp cloud site create` SPAWNS a content-bound site on an instance. Same route, different body.",
		},
		{
			Verb: "deploy", Aliases: []string{"build"}, Scope: siteVerbSpawnerOnly,
			Fleet:    siteDeployAtWrongNoun,
			Spawner:  runCloudSiteDeploy,
			Summary:  "enqueue a build for a spawned site and stream the six stages",
			KindNote: "container sites deploy with top-level `bp deploy <site>`; `bp sites deploy` refuses and names both doors rather than guessing.",
		},
		{
			Verb: "deployments", Aliases: []string{"deploys"}, Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesDeployments),
			Summary: "list a window of a site's deployments, newest first",
		},
		{
			Verb: "status", Scope: siteVerbShared,
			Impl:    runCloudSiteStatus,
			Summary: "the site's newest and live build, with attempts-per-live cost",
		},
		{
			Verb: "doctor", Scope: siteVerbShared,
			Impl:    runCloudSiteDoctor,
			Summary: "read every substrate the site occupies and name the repair",
		},
		{
			Verb: "rollback", Scope: siteVerbShared,
			Impl:     runCloudSiteRollback,
			Summary:  "flip back to the previous good build",
			KindNote: "static flips a symlink, node flips the Caddy upstream — the kind difference is the SERVER's, not the CLI's.",
		},
		{
			Verb: "delete", Aliases: []string{"rm"}, Scope: siteVerbShared,
			Impl:    runCloudSiteDelete,
			Summary: "tear the site down",
		},
		{
			Verb: "open", Scope: siteVerbShared,
			Impl:    runCloudSiteOpen,
			Summary: "open the site's live URL in a browser",
		},
		{
			Verb: "settings", Scope: siteVerbShared,
			Impl:    runCloudSiteSettings,
			Summary: "read or patch the site's theme, doc type and prebuilt opt-in",
		},
		{
			Verb: "preflight", Scope: siteVerbShared,
			Impl:    runCloudSitePreflight,
			Summary: "build your LOCAL tree and check that build (offline, no login)",
		},
		{
			Verb: "env", Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesEnv),
			Summary: "replace the encrypted env blob (`env set <site> KEY=VAL ...`)",
		},
		{
			Verb: "domain", Aliases: []string{"domains"}, Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesDomain),
			Summary: "add a domain (`domain add <site> <domain>`)",
		},
		{
			Verb: "github", Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesGithub),
			Summary: "link a GitHub repo + branch (`github connect <site> --repo o/r`)",
		},
		{
			Verb: "logs", Aliases: []string{"log"}, Scope: siteVerbShared,
			Impl:    fleetAdapter(runSitesLogs),
			Summary: "the build-log URL, or the recorder's record for one deployment",
		},
		{
			Verb: "matrix", Scope: siteVerbShared,
			Impl:    runSiteMatrix,
			Summary: "print THIS table — which verbs both spellings share, and why the rest do not",
		},
	}
}

// siteReservedVerbs are the INSTANCE-level verbs the matrix names so nobody
// aliases them into a site noun. They carry no handler on purpose.
var siteReservedVerbs = []siteVerbBinding{
	{
		Verb: "bp cloud deploy", Scope: siteVerbReserved,
		Summary:  "blue/green CODE-slot flip of a whole Barkpark INSTANCE",
		KindNote: "never a site verb: its subject is a box, not a site.",
	},
	{
		Verb: "bp cloud rollback", Scope: siteVerbReserved,
		Summary:  "flip an INSTANCE back to its previous code slot",
		KindNote: "never a site verb: `bp cloud site rollback` / `bp sites rollback` roll back a SITE.",
	},
}

// lookupSiteVerb resolves a typed verb (canonical or alias) to its row.
func lookupSiteVerb(verb string) (siteVerbBinding, bool) {
	for _, b := range siteVerbMatrix {
		for _, n := range b.names() {
			if n == verb {
				return b, true
			}
		}
	}
	return siteVerbBinding{}, false
}

// dispatchSiteVerb is the shared body of both trees: resolve, check the verb is
// offered at this spelling, run it. An unknown verb, or a verb the spelling does
// not offer, is a usage error naming the door that does answer.
func dispatchSiteVerb(out *writer, g globals, spelling, verb string, rest []string) int {
	b, ok := lookupSiteVerb(verb)
	if !ok {
		return useError(out, "usage", fmt.Sprintf("unknown site command %q (run `%s -h` for usage; to list your team's sites: `bp sites` or `bp cloud site ls`)", verb, spelling), exitUsage)
	}
	fn := b.handler(spelling)
	if fn == nil {
		other := siteSpellingSpawner
		if spelling == siteSpellingSpawner {
			other = siteSpellingFleet
		}
		return useError(out, "usage", fmt.Sprintf("`%s %s` is not offered here — use `%s %s`", spelling, verb, other, verb), exitUsage)
	}
	return fn(out, g, rest)
}

// siteDeployAtWrongNoun is `bp sites deploy` — the ONE verb whose two kinds have
// two different doors. It refuses and names both rather than picking one: the
// container model's deploy is the top-level `bp deploy <site>`, the spawner's is
// `bp cloud site deploy <site>`. Guessing here is how a CD script deploys the
// wrong way and reads a green.
func siteDeployAtWrongNoun(out *writer, _ globals, _ []string) int {
	return useError(out, "usage",
		"`bp sites deploy` is ambiguous — a CONTAINER site deploys with `bp deploy <site>`, a SPAWNED site with `bp cloud site deploy <site>`. Run `bp sites matrix` for the whole table.",
		exitUsage)
}

// runSiteMatrix renders the matrix. Table for humans, -o json for scripts; both
// are DERIVED from siteVerbMatrix, so a row added without a spelling note shows
// up here rather than in a doc nobody regenerated.
func runSiteMatrix(out *writer, _ globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			out.outf("bp sites matrix — which site verbs both spellings share.\n\nUSAGE\n  bp sites matrix\n  bp cloud site matrix\n\nFLAGS\n  -o json   emit the matrix as one machine-readable object")
			return exitOK
		}
		return useError(out, "usage", fmt.Sprintf("unknown argument %q (usage: bp sites matrix)", a), exitUsage)
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(siteVerbMatrix)+len(siteReservedVerbs))
		for _, b := range siteVerbMatrix {
			rows = append(rows, map[string]any{
				"verb":      b.Verb,
				"aliases":   b.Aliases,
				"scope":     string(b.Scope),
				"spellings": siteVerbSpellings(b),
				"summary":   b.Summary,
				"kind_note": siteMatrixNullable(b.KindNote),
			})
		}
		for _, b := range siteReservedVerbs {
			rows = append(rows, map[string]any{
				"verb":      b.Verb,
				"aliases":   []string{},
				"scope":     string(b.Scope),
				"spellings": []string{},
				"summary":   b.Summary,
				"kind_note": siteMatrixNullable(b.KindNote),
			})
		}
		out.emitStructured(map[string]any{"verbs": rows})
		return exitOK
	}

	out.outf("SITE COMMAND MATRIX — `bp sites <verb>` and `bp cloud site <verb>` are ONE tree.")
	out.outf("")
	rows := [][]string{{"VERB", "ALIASES", "SPELLINGS", "WHAT IT DOES"}}
	for _, b := range siteVerbMatrix {
		rows = append(rows, []string{
			b.Verb,
			siteMatrixDash(strings.Join(b.Aliases, ", ")),
			strings.Join(siteVerbSpellings(b), " + "),
			b.Summary,
		})
	}
	writeSiteMatrixTable(out, rows)

	out.outf("")
	out.outf("WHERE THE SPELLINGS DIFFER")
	any := false
	for _, b := range siteVerbMatrix {
		if b.KindNote == "" {
			continue
		}
		any = true
		out.outf("  %s — %s", b.Verb, b.KindNote)
	}
	if !any {
		out.outf("  nowhere: every verb is shared.")
	}

	out.outf("")
	out.outf("RESERVED — INSTANCE-LEVEL, NEVER A SITE VERB")
	for _, b := range siteReservedVerbs {
		out.outf("  %s — %s", b.Verb, b.Summary)
		if b.KindNote != "" {
			out.outf("      %s", b.KindNote)
		}
	}

	out.outf("")
	out.outf("OUTPUT + EXIT are spelling-independent: a shared verb reaches the same")
	out.outf("implementation at either noun, so the bytes and the exit code match.")
	return exitOK
}

// siteVerbSpellings names the nouns a verb actually answers at.
func siteVerbSpellings(b siteVerbBinding) []string {
	var got []string
	if b.handler(siteSpellingFleet) != nil && b.Scope != siteVerbSpawnerOnly {
		got = append(got, "bp sites")
	}
	if b.handler(siteSpellingSpawner) != nil {
		got = append(got, "bp cloud site")
	}
	sort.SliceStable(got, func(i, j int) bool { return got[i] < got[j] })
	return got
}

func siteMatrixDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func siteMatrixNullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// writeSiteMatrixTable pads columns 1..n-1 and lets the last column run, the
// same shape the other site tables use.
func writeSiteMatrixTable(out *writer, rows [][]string) {
	if len(rows) == 0 {
		return
	}
	widths := make([]int, len(rows[0]))
	for _, r := range rows {
		for i, c := range r {
			if i < len(widths) && len([]rune(c)) > widths[i] {
				widths[i] = len([]rune(c))
			}
		}
	}
	for _, r := range rows {
		var b strings.Builder
		for i, c := range r {
			if i == len(r)-1 {
				b.WriteString(c)
				break
			}
			b.WriteString(c)
			b.WriteString(strings.Repeat(" ", widths[i]-len([]rune(c))+2))
		}
		out.outf("%s", strings.TrimRight(b.String(), " "))
	}
}
