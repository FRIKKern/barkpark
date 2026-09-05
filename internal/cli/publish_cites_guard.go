package cli

// publish_cites_guard.go — THE STALE-CITE ADVISORY on `bp doc publish`.
//
// THE DEFECT (task-f80f6eaebe2b4264, measured 2026-09-02 in the mobile lane).
// A never-published draft ages INVISIBLY: every staleness sweep this ledger
// runs reads the published corpus, so a draft accumulates rot with zero
// suspicion attached to it, and `bp doc publish` then converts that rot into a
// row every board reads as FRESH. drafts.mob-lm-s6-island-offline was authored
// 2026-07-28, asserted its own freshness in the PRESENT TENSE ("all six
// sub-claims still true on main"), and was published on 2026-09-02. All six
// sub-claims were false: the work had merged ten days earlier as PR #13309
// under the sibling row whose id is THE FIRST THING the draft's own description
// names. One lookup of that id before publishing would have cost a second and
// saved a full builder dispatch.
//
// THIS IS AN ADVISORY, NEVER A GATE — and that is the whole design constraint,
// not a softening of one. A legitimate follow-up row cites its predecessor by
// id too, and a predecessor that is DONE is the NORMAL case for a follow-up. A
// refusal here would be wrong more often than right. So, unlike its two
// neighbours in this package (discard_draft_guard.go refuses; destroy_confirm.go
// prompts), this file:
//
//   - never returns a refusal and never touches runCommand's exit code;
//   - runs its status lookups only AFTER the publish has already landed 2xx,
//     so it cannot delay, fail or influence the write in any way;
//   - writes to STDERR in every output mode, so `-o json` stdout stays one
//     byte-identical parseable document.
//
// THE SPLIT (why two halves, pre-write and post-write). The text it reads is
// the DRAFT's, and after a successful publish the drafts.<id> twin is gone. So
// the cheap half — one `doc get --perspective drafts` — runs BEFORE the send
// (the same read discard_draft_guard.go performs before its own verb), and the
// expensive half — the per-id status lookups — runs only on a 2xx. A publish
// that fails costs exactly one extra GET; a publish of a non-task, or of a
// draft citing nothing, costs nothing beyond it.
//
// THE EXTRACTION RULE, and its false-positive bound. Two token shapes are
// treated as CANDIDATES:
//
//  1. the canonical `task-<16 lowercase hex>` id;
//  2. the slug form the ledger also carries (pds-…, dr-w23-…, mob-zb-bl-…):
//     a lowercase token of THREE OR MORE hyphen-separated segments.
//
// Shape (2) alone would fire on ordinary prose — "read-before-write",
// "re-verify-before-acting" — so shape is NOT the test. RESOLUTION is: every
// candidate is looked up with `bp task get`, and only a candidate that RESOLVES
// to a real task row is ever named in the output. A prose token 404s and is
// dropped in silence. That is what bounds false positives at zero for shape (2)
// and makes the rule honest to state: the advisory names a cited id only when
// that id is a task this server knows.
//
// False NEGATIVES are accepted, deliberately: an id split across a line break,
// an id written with an unusual delimiter, and everything past the tenth
// candidate (publishCiteLookupCap) go unchecked. The row asked for a cheap
// check; a missed warning costs what today already costs, while a warning on
// prose would train the reader to skim the line — the exact failure mode
// tasks_ruling.go was written to undo.

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// publishCommandID keys the advisory on the manifest command id, never on the
// noun/verb spelling — discardDraftCommandID's rule, for the same reason: a
// server that renames the verb must not silently un-hook the check.
const publishCommandID = "doc.publish"

// publishCitesType scopes the advisory to task documents. A Paper or a media
// asset citing a task id is not the laundering this file is about, and the
// status vocabulary it reads (lifecycle_status) is the task plugin's.
const publishCitesType = "task"

// publishCiteLookupCap bounds the network cost of one publish. A draft cites a
// handful of ids at most; ten is generous for the real case and hard-stops the
// pathological one (a draft that pastes a whole board). Canonical `task-<hex>`
// candidates are ordered FIRST so the cap can never be eaten by prose-shaped
// slug candidates ahead of a real id.
const publishCiteLookupCap = 10

// publishCiteAdvisoryPrefix heads every line this file prints. Lowercase and
// explicitly "advisory" — the opposite register from rulingBannerPrefix's
// shout, because this line is a PROMPT TO RE-VERIFY, not a decision already
// made, and it fires on the ordinary follow-up row too.
const publishCiteAdvisoryPrefix = "advisory: "

// canonicalTaskIDRe matches the ledger's canonical id: `task-` plus exactly 16
// lowercase hex digits. Anchored on both sides with a non-[a-z0-9-] boundary so
// a longer token that merely CONTAINS one never matches.
var canonicalTaskIDRe = regexp.MustCompile(`(^|[^a-z0-9-])(task-[0-9a-f]{16})($|[^a-z0-9-])`)

// slugTaskIDRe matches the slug id form (pds-…, dr-w23-…, mob-zb-bl-…): three
// or more lowercase alphanumeric segments joined by single hyphens. It is a
// CANDIDATE filter only — see the file header: nothing it matches is reported
// unless `bp task get` resolves it.
var slugTaskIDRe = regexp.MustCompile(`(^|[^a-z0-9-])([a-z][a-z0-9]*(?:-[a-z0-9]+){2,})($|[^a-z0-9-])`)

// publishCiteTerminal are the lifecycle_status values that mean the cited row's
// work is OVER — the ones that make a draft's present-tense claim about it
// suspect. Everything else is reported with its own status and the milder
// wording, so DONE and OPEN never read alike (criterion c1).
var publishCiteTerminal = map[string]bool{
	"done":      true,
	"cancelled": true,
	"canceled":  true,
}

// publishCite is one resolved citation: the id as written in the draft, the
// status the server reports for it now, and (for a closed row) the timestamp
// that dates the work.
type publishCite struct {
	ID       string
	Status   string
	ClosedAt string
	// Canonical marks a `task-<16 hex>` token. Only these earn a "could not
	// check" line on a failed lookup: a slug candidate that does not resolve is
	// overwhelmingly prose, and saying so out loud would be the false positive
	// this file refuses to emit.
	Canonical bool
}

// publishCitesArgs re-resolves cmd's positionals so the advisory reads the same
// document the publish will touch, re-running the PURE splitArgs/bindArgs
// exactly as discardDraftArgs and destroyRefArgs do rather than threading a map
// out of buildManifestRequest (which must still run once — it is the one that
// reads stdin).
func publishCitesArgs(cmd manifest.Command, tail []string) (typeName, bareID string, ok bool) {
	if cmd.ID != publishCommandID {
		return "", "", false
	}
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return "", "", false
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return "", "", false
	}
	typeName, id := args["type"], args["id"]
	if typeName != publishCitesType || id == "" {
		return "", "", false
	}
	return typeName, strings.TrimPrefix(id, "drafts."), true
}

// extractTaskCites pulls the candidate ids out of a draft's text, canonical
// form first, de-duplicated, with selfID (and its drafts. twin) removed — a row
// naming itself is not a citation. Order within each shape follows first
// appearance, so a truncated list is the head of the document, not an arbitrary
// slice of it.
func extractTaskCites(text, selfID string) []publishCite {
	self := map[string]bool{
		selfID:                                true,
		strings.TrimPrefix(selfID, "drafts."): true,
	}
	seen := map[string]bool{}
	var canonical, slugs []publishCite

	for _, mm := range canonicalTaskIDRe.FindAllStringSubmatch(text, -1) {
		id := mm[2]
		if self[id] || seen[id] {
			continue
		}
		seen[id] = true
		canonical = append(canonical, publishCite{ID: id, Canonical: true})
	}
	for _, mm := range slugTaskIDRe.FindAllStringSubmatch(text, -1) {
		id := mm[2]
		if self[id] || seen[id] {
			continue
		}
		seen[id] = true
		slugs = append(slugs, publishCite{ID: id})
	}
	return append(canonical, slugs...)
}

// draftCiteText flattens every string a draft document carries under the fields
// that hold PROSE — description, brief, title — into one blob for the
// extractor. It walks the brief's block tree rather than naming its keys: the
// PortableDoc shape nests text under blocks/content/items, and a key-named walk
// would go silently blind the first time a block type is added.
//
// Deliberately NOT the whole document: acceptance_criteria, labels, tags and
// the claim map are machine fields, and a `dr-w23-bl`-shaped LABEL is not the
// author citing a measurement.
func draftCiteText(body []byte) string {
	var env struct {
		Result map[string]any `json:"result"`
		Doc    map[string]any `json:"doc"`
	}
	if json.Unmarshal(body, &env) != nil {
		return ""
	}
	doc := env.Result
	if doc == nil {
		doc = env.Doc
	}
	if doc == nil {
		// A bare document with no envelope wrapper.
		if json.Unmarshal(body, &doc) != nil {
			return ""
		}
	}
	var b strings.Builder
	for _, field := range []string{"title", "description", "brief"} {
		collectStrings(doc[field], &b)
	}
	return b.String()
}

// collectStrings appends every string reachable from v, newline-separated, so
// two adjacent values can never fuse into a token that appears in neither.
// Map keys are walked in sorted order purely for determinism.
func collectStrings(v any, b *strings.Builder) {
	switch t := v.(type) {
	case string:
		b.WriteString(t)
		b.WriteString("\n")
	case []any:
		for _, e := range t {
			collectStrings(e, b)
		}
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			collectStrings(t[k], b)
		}
	}
}

// readDraftCites is the PRE-WRITE half: one `doc get --perspective drafts` for
// the row about to be published, returning the candidate ids its prose names.
// Every failure — no doc.get on this server, a transport error, a non-2xx, an
// unreadable body — returns nil, in silence. This half must never speak: it
// runs before the write, and a message here would read as a publish problem.
func readDraftCites(g globals, ctx manifest.Context, m *manifest.Manifest, typeName, bareID string) []publishCite {
	get, ok := m.Tree().Lookup("doc", "get")
	if !ok {
		return nil
	}
	tail := []string{typeName, bareID}
	if commandDeclaresFlag(*get, "perspective") {
		tail = append(tail, "--perspective", "drafts")
	}

	// Headless dispatch, exactly as probeDiscardDraftTwin uses it: no
	// rendering, no guards, no stdout. --dry-run is cleared so a dry run reads
	// nothing at all rather than half-reading, and --all is cleared so a
	// caller's global cannot turn one probe into a page walk.
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	status, body, err := execManifestCommand(lg, ctx, m, *get, tail)
	if err != nil || status/100 != 2 {
		return nil
	}
	return extractTaskCites(draftCiteText(body), bareID)
}

// lookupTaskStatus asks `bp task get <id>` for one cited row's CURRENT
// lifecycle_status. found=false means the id did not resolve to a task on this
// server — for a slug candidate that is the ordinary "it was prose" answer, and
// for a canonical id it is what the "could not check" line reports.
func lookupTaskStatus(g globals, ctx manifest.Context, m *manifest.Manifest, id string) (status, closedAt string, found bool) {
	get, ok := m.Tree().Lookup("task", "get")
	if !ok {
		return "", "", false
	}
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false

	// THE TASK LEDGER IS UNSCOPED, and the scope fence enforces that: task.get
	// advertises no scoped_prefix, so manifest.BuildURL REFUSES a stated
	// `-w/-p` on it rather than answering about the default scope while the
	// caller asked about another (internal/manifest/scope.go). The publish that
	// triggered this advisory is a scoped document write, so the caller's ctx
	// carries exactly that stated scope — and without dropping it here the
	// lookup never leaves the client and every cite reads as unresolvable.
	// Dropping it is what the fence's own remedy sentence says to do, and it is
	// honest: there is one task ledger, and this id addresses it.
	lctx := ctx
	lctx.Workspace = ""
	lctx.Project = ""
	lctx.WorkspaceExplicit = false
	lctx.ProjectExplicit = false

	code, body, err := execManifestCommand(lg, lctx, m, *get, []string{id})
	if err != nil || code/100 != 2 {
		return "", "", false
	}
	return taskStatusFromEnvelope(body)
}

// taskStatusFromEnvelope decodes lifecycle_status (and the claim's closed_at,
// when the row carries one) out of a task envelope, trying the flat body first
// and then a {"result": …} wrapper — the two-shape walk rulingFromEnvelope and
// leaseFromEnvelope both do.
func taskStatusFromEnvelope(body []byte) (status, closedAt string, found bool) {
	if s, c, ok := taskStatusOf(body); ok {
		return s, c, true
	}
	return taskStatusOf(unwrapResult(body))
}

func taskStatusOf(body []byte) (string, string, bool) {
	type claim struct {
		ClosedAt string `json:"closed_at"`
	}
	var env struct {
		LifecycleStatus string `json:"lifecycle_status"`
		Claim           claim  `json:"claim"`
		Doc             struct {
			LifecycleStatus string `json:"lifecycle_status"`
			Claim           claim  `json:"claim"`
			Content         struct {
				LifecycleStatus string `json:"lifecycle_status"`
				Claim           claim  `json:"claim"`
			} `json:"content"`
		} `json:"doc"`
	}
	if json.Unmarshal(body, &env) != nil {
		return "", "", false
	}
	status := firstNonEmpty(env.Doc.LifecycleStatus, env.Doc.Content.LifecycleStatus, env.LifecycleStatus)
	if status == "" {
		return "", "", false
	}
	closed := firstNonEmpty(env.Doc.Claim.ClosedAt, env.Doc.Content.Claim.ClosedAt, env.Claim.ClosedAt)
	return strings.TrimSpace(status), strings.TrimSpace(closed), true
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// emitPublishCiteAdvisory is the POST-2xx half: the publish has already landed,
// so nothing here can affect it. It resolves each candidate's current status
// and prints at most one line per cited id, on stderr, in every output mode.
//
// Silent — byte-for-byte the receipt this command printed before this file
// existed — when the draft named nothing, when nothing it named resolves, and
// for every command that is not doc.publish.
func emitPublishCiteAdvisory(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cites []publishCite) {
	if len(cites) == 0 {
		return
	}
	if len(cites) > publishCiteLookupCap {
		cites = cites[:publishCiteLookupCap]
	}
	for _, c := range cites {
		status, closedAt, found := lookupTaskStatus(g, ctx, m, c.ID)
		if !found {
			// A slug candidate that does not resolve was prose. Only a
			// canonical `task-<16 hex>` token — which cannot be prose — earns
			// the one-line "could not check", and even that never blocks and
			// never changes the exit code (criterion c2).
			if c.Canonical {
				out.errf("%scould not check %s — the status lookup did not land; the publish stands", publishCiteAdvisoryPrefix, c.ID)
			}
			continue
		}
		out.errf("%s%s", publishCiteAdvisoryPrefix, publishCiteLine(c.ID, status, closedAt))
	}
}

// publishCiteLine is the sentence itself, split out so the DONE and OPEN
// wordings can be asserted directly (criterion c1: the two must not read
// alike).
func publishCiteLine(id, status, closedAt string) string {
	up := strings.ToUpper(status)
	if publishCiteTerminal[strings.ToLower(status)] {
		when := ""
		if closedAt != "" {
			when = fmt.Sprintf(" (closed %s)", closedAt)
		}
		return fmt.Sprintf(
			"this draft cites %s which is %s%s — a stale measurement may be about to publish as fresh; re-verify before acting on it",
			id, up, when)
	}
	return fmt.Sprintf(
		"this draft cites %s which is %s — check it is still the row you mean",
		id, up)
}
