package manifest

import "sort"

// ── Dataset honesty ──────────────────────────────────────────────────────────
//
// THE BUG THIS FILE CLOSES. `bp -d staging task ready` returned the PRODUCTION
// ledger's rows, byte-identically, with exit 0. The -d value was parsed into
// ctx.Dataset and then never reached the URL, the query string or a header,
// because /v1/tasks/ready has no :dataset placeholder and declares no `dataset`
// flag, so neither fillTemplate nor applyQuery's globalQueryForwards had
// anywhere to put it. The operator was answered about a dataset they did not
// name and nothing said so. This is the last surviving arm of the silent
// scope-drop class scope.go opened for -w/-p.
//
// THE RULE, deliberately the same four-way total classification scope.go uses,
// so there is one mental model for both axes and no fifth outcome:
//
//	DatasetCarried          the URL the command builds reads :dataset, or the
//	                        command declares a `dataset` FLAG that applyQuery
//	                        forwards the typed -d into. The value reaches the wire.
//	DatasetUnscopedByDesign declared, with a reason: -d is meaningless for this
//	                        command by construction (it runs before any dataset
//	                        exists, or it operates on the container that HOLDS
//	                        datasets). Staying flat is the honest answer.
//	DatasetRefused          nothing can carry it. The CLI must refuse before I/O.
//
// WHY THERE IS NO DatasetMirrored, AND WHY THAT IS DERIVED. scope.go's
// ScopeMirrored exists because 66 of the live surface's 207 commands advertise a
// per-command `scoped_prefix`, and BuildURL composes it. Every one of those
// prefixes is the same string, "/w/:workspace_slug/p/:project_slug" — there is
// no dataset segment in any of them, so there is no mirror for a dataset to be
// re-routed to. That is not an assumption: TestNoAdvertisedPrefixCarriesADataset
// re-derives it from the checked-in capabilities capture on every run, and reds
// the day a server starts advertising one. A fourth fate would then be a filing,
// not a surprise.
//
// WHY DIVERGENCE, AND WHY A NARROWER PROVENANCE THAN -w/-p. The divergence half
// is copied verbatim in spirit from StatedScope: provenance alone is true for
// everyone with a saved context, so arming on it refuses for everyone. The
// provenance half is DELIBERATELY narrower than WorkspaceExplicit — it is
// "supplied at flag precedence", not "supplied by any layer above Defaults" —
// because the dataset floor is `production` and an ambient non-production
// dataset (BARKPARK_DATASET, a repo .barkpark.json, the saved active config) is
// the normal state of every development machine. Refusing on that would brick
// `bp task ready` for those operators with no command line that fixes it. The
// full argument, and why the field is called DatasetTyped rather than
// DatasetExplicit, is in context.go beside the field.

// DatasetFate is what happens to an operator-typed, non-floor -d on one command.
type DatasetFate int

const (
	// DatasetCarried — the command's URL or a declared `dataset` flag carries it.
	DatasetCarried DatasetFate = iota
	// DatasetUnscopedByDesign — declared dataset-agnostic with a reason; stays flat.
	DatasetUnscopedByDesign
	// DatasetRefused — nothing can carry it; the CLI must refuse before I/O.
	DatasetRefused
)

func (f DatasetFate) String() string {
	switch f {
	case DatasetCarried:
		return "carried"
	case DatasetUnscopedByDesign:
		return "unscoped-by-design"
	case DatasetRefused:
		return "refused"
	}
	return "unknown"
}

// datasetNames are the placeholder and flag spellings that mean "the dataset
// scope". Today the manifest defines exactly one — resolvePlaceholder's switch
// in url.go folds ctx.Dataset into `:dataset` and nothing else — and this slice
// exists so a future alias is added in one place rather than in three.
var datasetNames = []string{"dataset"}

// StatedDataset reports whether the operator TYPED a dataset, on this command
// line, to a value that diverges from the baked floor. False means the ambient
// dataset is in play and nothing about the request changes.
//
// Three conjuncts, and dropping any one of them reopens a door that was already
// walked through on the -w/-p axis:
//
//	DatasetTyped              a value that won at flag precedence. Without it,
//	                          every BARKPARK_DATASET / .barkpark.json / saved
//	                          config dataset arms the refusal — the
//	                          provenance-alone shape domain review rejected.
//	!DatasetFromServerEntry   `bp -s <saved-name>` copies that entry's dataset
//	                          into the flags map (cli.go's FindServer branch), so
//	                          it wins at flag precedence WITHOUT being typed.
//	                          Without this subtraction, `bp -s gyldendal task
//	                          ready` refuses and the only cure is deleting the
//	                          saved entry.
//	Dataset != floor.Dataset  a config or a flag pinned to `production` keeps
//	                          byte-identical behaviour. This is the conjunct
//	                          scope.go's "WHY DIVERGENCE, NOT PROVENANCE ALONE"
//	                          paragraph is about.
func StatedDataset(ctx Context) bool {
	floor := DefaultDefaults()
	return ctx.DatasetTyped &&
		!ctx.DatasetFromServerEntry &&
		ctx.Dataset != "" &&
		ctx.Dataset != floor.Dataset
}

// DatasetFateFor classifies one command. It is TOTAL — every command gets a
// fate, and "silently ignore the flag" is reachable only through an explicit
// declaration in datasetDispositions.
func DatasetFateFor(cmd Command) DatasetFate {
	if commandCarriesDataset(cmd) {
		return DatasetCarried
	}
	if d, ok := DatasetDispositionFor(cmd); ok && d.Unscoped {
		return DatasetUnscopedByDesign
	}
	return DatasetRefused
}

// commandCarriesDataset reports whether a TYPED -d actually reaches the wire for
// this command. Two ways, and they are the two real mechanisms, not a guess:
//
//   - the path template holds a :dataset placeholder, which fillTemplate fills
//     from ctx.Dataset (url.go's resolvePlaceholder);
//   - the command declares a `dataset` FLAG, which applyQuery forwards g.dataset
//     into via globalQueryForwards (run.go / globals.go).
//
// A declared positional ARG named `dataset` is NOT carriage: a positional is the
// operator's own value for that slot, filled from the args map, and the global
// -d never reaches it. On the live surface the single command with such an arg
// (onixedit.export) also has the placeholder, so the distinction costs nothing
// today and is written down so it does not have to be rediscovered.
//
// The placeholder test goes through PlaceholderNames — the whole-token parse —
// never strings.Contains(tmpl, ":dataset"), for the same reason
// commandCarriesScope does: a substring test is unsound the moment a longer
// placeholder starts with the same letters.
func commandCarriesDataset(cmd Command) bool {
	tmpl := cmd.HTTP.PathTemplate
	if cmd.ScopedPrefix != nil {
		// The prefix is part of the URL wherever BuildURL composes it, so it is
		// part of the carriage question too. Composing it here unconditionally is
		// the fail-OPEN-safe direction only because no advertised prefix carries a
		// dataset — TestNoAdvertisedPrefixCarriesADataset holds that true.
		tmpl = *cmd.ScopedPrefix + tmpl
	}
	present := PlaceholderNames(tmpl)
	declaredFlag := map[string]bool{}
	for _, f := range cmd.Flags {
		declaredFlag[f.Name] = true
	}
	for _, n := range datasetNames {
		if present[n] || declaredFlag[n] {
			return true
		}
	}
	return false
}

// datasetDispositions is the per-noun disposition table for the DATASET axis,
// keyed by manifest noun because the reason is a property of the resource family
// rather than of one verb. datasetDispositionOverrides handles per-command
// exceptions.
//
// It reuses scope.go's ScopeDisposition type — same two fields, same meaning of
// each (Unscoped true = staying flat is CORRECT and the flag is ignored on
// purpose; false = refuse before I/O) — so there is one shape to learn, and
// Unscoped=false stays the verdict to reach for when in doubt.
//
// Every entry below was derived from the checked-in capture of GET
// /v1/capabilities (testdata/capabilities-guerrilla-2026-09-04.json, 207
// commands): these are EXACTLY the nouns with at least one command that has no
// :dataset placeholder and declares no `dataset` flag. The derivation is not a
// one-time act — TestEveryDatasetUnscopableCommandIsDeclared re-runs it against
// the whole fixture on every test run and reds on any family that is not here,
// and TestDeclaredDatasetNounsAllExistInTheShippedManifest reds on any entry
// here that no longer describes a real family.
var datasetDispositions = map[string]ScopeDisposition{
	// ── Unscoped by design: -d is meaningless for these by construction. ──
	"auth":      {Unscoped: true, Reason: "account identity on the SERVER — register/login/reset/mfa run before the caller has a workspace, let alone a dataset, so there is no dataset for -d to name"},
	"workspace": {Unscoped: true, Reason: "workspace/project/member administration operates on the CONTAINER that holds datasets, not inside one; workspace dataset-ls exists precisely to enumerate them, and narrowing it to one would answer a different question than the one asked"},
	"plugin":    {Unscoped: true, Reason: "plugins are installed and configured on the INSTANCE; a plugin's listing and settings are not partitioned by dataset"},
	"incident":  {Unscoped: true, Reason: "status-page incidents are instance-wide announcements and exist outside any dataset"},

	// ── Refuse: the flag cannot reach the wire and the drop would be silent. ──
	"access":              {Reason: "the flat /v1/access grants are looked up by grant id and carry no dataset segment; the dataset-filtered form is access.grant, which declares its own `dataset` flag"},
	"app_token":           {Reason: "the app-token listing and revocation routes are keyed on the calling identity and carry no dataset segment; app_token.create declares its own `dataset` flag"},
	"bulldocs":            {Reason: "the bulldocs ingest routes address a paper by slug with no dataset segment and declare no dataset flag"},
	"chat":                {Reason: "chat sessions are addressed by session id with no dataset segment and declare no dataset flag"},
	"cycle":               {Reason: "the epic-cycle wave routes address a wave by :epic_id/:wave_id under the workspace/project prefix and carry no dataset segment"},
	"fleet_support_token": {Reason: "fleet support tokens are minted against the instance and carry no dataset segment"},
	"graph":               {Reason: "graph.show addresses one corpus node by id with no dataset segment; the corpus-wide graph verbs declare their own `dataset` flag"},
	"secret":              {Reason: "secrets are stored per instance or per workspace/project, never per dataset, and neither the flat nor the scoped secrets routes carry a dataset segment"},
	"session":             {Reason: "session records are addressed by slug with no dataset segment and declare no dataset flag"},
	"share":               {Reason: "share grants, links and tokens are addressed by id with no dataset segment and declare no dataset flag"},
	"task":                {Reason: "the task ledger routes address a task by doc_id with no dataset segment and declare no dataset flag; task.events is the one ledger verb that declares its own `dataset` flag"},
	"ticket":              {Reason: "the ticket inbox routes carry no dataset segment and declare no dataset flag"},
	"ticket-key":          {Reason: "ticket signing keys are minted against the instance and carry no dataset segment"},
	"token":               {Reason: "the flat /v1/tokens listing and revocation routes carry no dataset segment; token.create declares its own `dataset` flag"},
}

// datasetDispositionOverrides declares a single command whose dataset verdict
// differs from its noun's. Empty today; it exists so a per-command exception
// never has to be bought by loosening a whole family.
var datasetDispositionOverrides = map[string]ScopeDisposition{}

// DatasetDispositionFor returns the declared dataset verdict for cmd — the
// per-command override first, then the noun. ok is false when the family is
// UNDECLARED, which DatasetFateFor treats as "refuse" (fail closed) and the
// manifest-wide enumeration test treats as a red.
func DatasetDispositionFor(cmd Command) (ScopeDisposition, bool) {
	if d, ok := datasetDispositionOverrides[cmd.ID]; ok {
		return d, true
	}
	d, ok := datasetDispositions[cmd.Noun]
	return d, ok
}

// DeclaredDatasetNouns returns the declared nouns, sorted. Diagnostics and tests
// read the table through this rather than reaching into the map.
func DeclaredDatasetNouns() []string {
	out := make([]string, 0, len(datasetDispositions))
	for n := range datasetDispositions {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// DatasetFateTally counts, over a whole command roster, how many commands fall
// to each fate for an operator-typed, non-floor -d. Like ScopeFateTally it is
// DERIVED from the live manifest every time: a hard-coded count would go stale
// the moment the server declares one more `dataset` flag, and a stale number in
// a line whose whole job is honesty is worse than no line.
func DatasetFateTally(cmds []Command) map[DatasetFate]int {
	tally := map[DatasetFate]int{}
	for _, c := range cmds {
		tally[DatasetFateFor(c)]++
	}
	return tally
}
