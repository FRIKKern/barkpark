package cli

// tasks_publish_wall.go — the CLIENT-SIDE publish wall for `bp task create
// --publish` (and its MCP twin `task_create` with publish:true).
//
// THE DEFECT THIS EXISTS TO KILL. `--publish` is not one operation: it is a
// `create` mutation followed by a `publish` mutation. The server's publish wall
// (api/lib/barkpark/content/label_spine.ex E1/E2 + content/tag_registry.ex E3)
// runs on the SECOND one. So a row that cannot clear the wall still lands the
// DRAFT, and the command then exits non-zero having created exactly the thing
// the ledger calls a phantom: an unclaimable `drafts.task-N` that `bp task
// claim` 404s. The caller reads "created task-N but publish failed", believes a
// row was filed, and moves on. A command that half-succeeds and leaves debris is
// worse than one that refuses.
//
// So `--publish` refuses BEFORE it writes anything, on the two walls that are
// knowable in advance:
//
//   E1/E2 label spine — PURE, no network. Mirrors label_spine.ex constant for
//     constant: a description of >= 20 trimmed characters, 1..12 weighted tags,
//     each {tag, strength, rationale} with `tag` matching ^[a-z0-9-]+$, an
//     INTEGER strength in 1..100, a rationale of >= 20 trimmed characters, all
//     strengths distinct (so the derived main tag is a unique argmax), and no
//     duplicate tag name.
//
//   E3 tag registry — ONE scoped read. The vocabulary is a REGISTRY, not free
//     text: a tag resolves only if a PUBLISHED `type:tag` document with that
//     `_id` exists in the dataset. Retrying with plausible-sounding names is
//     precisely what produces the second phantom, so the refusal NAMES the
//     vocabulary — nearest registered candidates per unknown name, plus the
//     registry's size and the command that lists it.
//
// FAIL-OPEN IS DELIBERATE ON E3 AND ONLY ON E3. The registry check refuses only
// on an AUTHORITATIVE read: HTTP 2xx, decodable, non-empty, and not truncated
// (the query controller clamps `limit` to 1000 and reports `hasMore`). A
// transport error, a 403, or a truncated page means WE are blind, not that the
// tag is unknown — blocking a legitimate publish on our own blindness would be a
// worse bug than the one being fixed. On a blind read the caller is TOLD so and
// the create proceeds exactly as it does today.
//
// WHY NOT DELETE THE ORPHANED DRAFT ON THE FAILURE PATH. Deleting server state
// on an error path destroys content the caller authored, and it turns one
// uncertain state into two (the delete can fail as well). With the pre-flight in
// front, the drafts that still survive a refused publish are the ones whose BODY
// was good and whose only fault was something the client could not know —
// exactly the drafts worth keeping. The residual fix is therefore naming, not
// deletion: the failure arm in tasks_create_cmd.go now reports the id in its
// resolvable `drafts.` form, says plainly that the row is not on the board and
// cannot be claimed, and hands over both exits (publish it, or delete it).

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The wall's numbers, mirroring api/lib/barkpark/content/label_spine.ex module
// attributes @min_description/@min_tags/@max_tags/@min_strength/@max_strength/
// @min_rationale. They are duplicated here on purpose — a client that refuses
// early has to know the server's floor — and any drift shows up as a client
// that refuses a row the server would have taken, which is the safe direction.
const (
	wallMinDescription = 20
	wallMinTags        = 1
	wallMaxTags        = 12
	wallMinStrength    = 1
	wallMaxStrength    = 100
	wallMinRationale   = 20
)

// tagRegistryPageLimit is the query controller's own clamp (query_controller.ex
// clamps limit to [1,1000]). One page at the clamp holds the whole registry
// today (207 published type:tag docs on guerrilla, 2026-09-01); if it ever does
// not, the response's `hasMore` says so and the check goes blind rather than
// wrong.
const tagRegistryPageLimit = 1000

// maxTagSuggestionsPerName bounds the per-name "did you mean" list, and
// minTagSuggestionScore is the floor below which a candidate is misleading
// rather than helpful — an unrelated vocabulary must produce an EMPTY suggestion
// list, never a confident wrong one (the same contract tag_registry.ex's trgm
// @suggestion_floor keeps server-side).
const (
	maxTagSuggestionsPerName = 3
	minTagSuggestionScore    = 0.2
)

// tagNamePattern is the schema's own tag shape (paper.json / tasks/schema.ex,
// re-checked by label_spine.ex check_entries).
var tagNamePattern = regexp.MustCompile(`^[a-z0-9-]+$`)

// tagRegistryCommand is the ONE command that lists the live vocabulary. `--all`
// is not decoration: `bp doc ls tag` stops at the query controller's default
// limit of 100 and prints a truncation warning, so a reader who runs it without
// `--all` sees roughly half the registry and can still conclude a real tag is
// absent.
const tagRegistryCommand = "bp doc ls tag --all"

// publishWallRefusal is one refusal, in the shape the SERVER uses for the same
// refusal ({field, rule, fix} for label_spine; {unknown, suggestions} for
// unknown_tag) so the client-side and server-side messages read alike.
type publishWallRefusal struct {
	// Code is the server error code this pre-empts: "label_spine" or
	// "unknown_tag".
	Code string
	// Field, Rule, Fix carry a label_spine violation. Index is the offending
	// entry's position, or -1 when the violation is not entry-specific.
	Field string
	Rule  string
	Fix   string
	Index int
	// Unknown and Suggestions carry an unknown_tag violation; RegistrySize is how
	// many tags the authoritative registry read returned.
	Unknown      []string
	Suggestions  map[string][]string
	RegistrySize int
}

// headline is the one-line summary the refusal leads with.
func (r *publishWallRefusal) headline() string {
	if r.Code == "unknown_tag" {
		return fmt.Sprintf("refused before writing anything — %d tag(s) are not in the registry", len(r.Unknown))
	}
	return "refused before writing anything — this row cannot clear the publish wall"
}

// lines renders the refusal's body: the broken rule and its fix, then the
// vocabulary door. Every line is indented by the caller.
func (r *publishWallRefusal) lines() []string {
	var out []string
	if r.Code == "unknown_tag" {
		for _, name := range r.Unknown {
			sugg := r.Suggestions[name]
			if len(sugg) == 0 {
				out = append(out, fmt.Sprintf("unknown tag %q — no registered tag is close to it", name))
				continue
			}
			out = append(out, fmt.Sprintf("unknown tag %q — did you mean: %s", name, strings.Join(sugg, ", ")))
		}
		out = append(out,
			"a tag is registered ONLY if a PUBLISHED type:tag document carries that id — you cannot invent one at create time",
			fmt.Sprintf("%s   # the live registry (%d registered)", tagRegistryCommand, r.RegistrySize),
		)
		return out
	}
	out = append(out, "field: "+r.Field)
	if r.Index >= 0 {
		out = append(out, fmt.Sprintf("entry: tags[%d]", r.Index))
	}
	out = append(out, "rule:  "+r.Rule, "fix:   "+r.Fix)
	if r.Field == "tags" {
		out = append(out, tagRegistryCommand+"   # every tag must ALREADY be a published type:tag doc — never invent one")
	}
	return out
}

// renderPublishWallRefusal writes the refusal to stderr and returns the process
// exit code. exitUsage, not exitGeneric: the inputs were bad and no request was
// sent, which is the same class as the empty-title refusal in runTaskCreate.
//
// The last line is the load-bearing one. The whole point of moving the wall in
// front of the create is that the caller can act on the refusal without first
// having to work out what got left on the server — so the refusal SAYS that
// nothing did.
func renderPublishWallRefusal(out *writer, ref *publishWallRefusal) int {
	out.userErr("task create --publish: %s", ref.headline())
	for _, line := range ref.lines() {
		out.errf("  %s", line)
	}
	out.errf("  nothing was created — no draft was left behind.")
	return exitUsage
}

// checkLabelSpineLocal is the PURE half of the wall: it answers, with no server
// call, whether body clears label_spine.ex's E1/E2 rules. nil means clear.
//
// Rule order matches validate/1's `with` chain so the client and the server name
// the SAME first broken rule — a client that reported a different one would send
// the caller to fix a field the server was not going to complain about.
//
// @canonical capability:task-publish-wall-preflight aka:label_spine,unknown_tag,publish wall,phantom draft,registered tag,--publish
func checkLabelSpineLocal(body map[string]any) *publishWallRefusal {
	if ref := checkWallDescription(body); ref != nil {
		return ref
	}
	tags, ref := wallTagEntries(body)
	if ref != nil {
		return ref
	}
	if ref := checkWallTagCount(tags); ref != nil {
		return ref
	}
	if ref := checkWallEntries(tags); ref != nil {
		return ref
	}
	if ref := checkWallDistinctStrengths(tags); ref != nil {
		return ref
	}
	return checkWallDuplicateTags(tags)
}

func spineRefusal(field, rule, fix string, index int) *publishWallRefusal {
	return &publishWallRefusal{Code: "label_spine", Field: field, Rule: rule, Fix: fix, Index: index}
}

func checkWallDescription(body map[string]any) *publishWallRefusal {
	value, ok := body["description"].(string)
	if !ok {
		return spineRefusal("description",
			"A published document requires a description.",
			fmt.Sprintf("--description '…' with at least %d characters.", wallMinDescription), -1)
	}
	if len([]rune(strings.TrimSpace(value))) < wallMinDescription {
		return spineRefusal("description",
			fmt.Sprintf("A description must be non-trivial (at least %d characters).", wallMinDescription),
			"Write a description that summarizes the task in a sentence or two.", -1)
	}
	return nil
}

// wallTagEntries pulls `tags` out of the body as a list of maps. A body built by
// parseTaskCreateArgs carries whatever --set 'tags:=<json>' decoded, so the
// entries are map[string]any with float64 strengths; an MCP or native caller may
// hand over []map[string]any, which is the same shape by another static type.
// Anything else is the shape violation the server would report on `tags`.
func wallTagEntries(body map[string]any) ([]map[string]any, *publishWallRefusal) {
	raw, present := body["tags"]
	if !present || raw == nil {
		return nil, spineRefusal("tags",
			"A published document requires a `tags` array.",
			`--set 'tags:=[{"tag":"<registered>","strength":80,"rationale":"why this tag, 20+ chars"}]'`, -1)
	}
	list, ok := raw.([]any)
	if !ok {
		if typed, isTyped := raw.([]map[string]any); isTyped {
			return typed, nil
		}
		return nil, spineRefusal("tags",
			"`tags` must be an array of weighted entries.",
			`--set 'tags:=[{"tag":"<registered>","strength":80,"rationale":"why this tag, 20+ chars"}]'`, -1)
	}
	entries := make([]map[string]any, 0, len(list))
	for i, item := range list {
		entry, entryOK := item.(map[string]any)
		if !entryOK {
			return nil, spineRefusal("tags",
				"Every tag entry must be an object with `tag`, `strength` and `rationale`.",
				"A bare string is the LEGACY flat shape and cannot be published — use the weighted object form.", i)
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func checkWallTagCount(tags []map[string]any) *publishWallRefusal {
	if len(tags) < wallMinTags {
		return spineRefusal("tags",
			fmt.Sprintf("A published document requires at least %d tag.", wallMinTags),
			`--set 'tags:=[{"tag":"<registered>","strength":80,"rationale":"why this tag, 20+ chars"}]'`, -1)
	}
	if len(tags) > wallMaxTags {
		return spineRefusal("tags",
			fmt.Sprintf("A published document carries at most %d tags.", wallMaxTags),
			fmt.Sprintf("Drop %d entr(ies) — keep the ones that actually classify the row.", len(tags)-wallMaxTags), -1)
	}
	return nil
}

func checkWallEntries(tags []map[string]any) *publishWallRefusal {
	for i, entry := range tags {
		name, _ := entry["tag"].(string)
		if strings.TrimSpace(name) == "" {
			return spineRefusal("tags", "Every tag entry requires a `tag` name.",
				"Give the entry a tag name the registry already carries.", i)
		}
		if !tagNamePattern.MatchString(name) {
			return spineRefusal("tags",
				"A tag name is lowercase letters, digits and hyphens only (^[a-z0-9-]+$).",
				fmt.Sprintf("Rewrite %q in that shape — and only as a name the registry already carries.", name), i)
		}
		strength, numeric := wallInt(entry["strength"])
		if !numeric {
			return spineRefusal("tags",
				"Every tag entry requires an integer `strength`.",
				fmt.Sprintf("The key is `strength` (not `weight`), an integer %d..%d.", wallMinStrength, wallMaxStrength), i)
		}
		if strength < wallMinStrength || strength > wallMaxStrength {
			return spineRefusal("tags",
				fmt.Sprintf("`strength` is an integer %d..%d.", wallMinStrength, wallMaxStrength),
				fmt.Sprintf("Entry %q carries strength %d.", name, strength), i)
		}
		rationale, _ := entry["rationale"].(string)
		if len([]rune(strings.TrimSpace(rationale))) < wallMinRationale {
			return spineRefusal("tags",
				fmt.Sprintf("Every tag entry requires a `rationale` of at least %d characters.", wallMinRationale),
				fmt.Sprintf("Say in one clause why %q classifies this row.", name), i)
		}
	}
	return nil
}

func checkWallDistinctStrengths(tags []map[string]any) *publishWallRefusal {
	seen := make(map[int]string, len(tags))
	for i, entry := range tags {
		strength, numeric := wallInt(entry["strength"])
		if !numeric {
			continue
		}
		name, _ := entry["tag"].(string)
		if prior, dup := seen[strength]; dup {
			return spineRefusal("tags",
				"All tag strengths must be DISTINCT — the main tag is derived as the unique maximum, never stored.",
				fmt.Sprintf("%q and %q both carry strength %d; give one of them a different value.", prior, name, strength), i)
		}
		seen[strength] = name
	}
	return nil
}

func checkWallDuplicateTags(tags []map[string]any) *publishWallRefusal {
	seen := make(map[string]bool, len(tags))
	for i, entry := range tags {
		name, _ := entry["tag"].(string)
		if seen[name] {
			return spineRefusal("tags", "A tag may appear only once.",
				fmt.Sprintf("Drop the duplicate %q entry.", name), i)
		}
		seen[name] = true
	}
	return nil
}

// wallInt reads a JSON number as an integer. --set 'tags:=…' decodes through
// encoding/json into float64, an MCP body may already carry int, and a
// hand-built map may carry json.Number — all three are the same value and none
// of them may be reported as "not an integer". A float with a fractional part is
// NOT an integer and is reported as such.
func wallInt(value any) (int, bool) {
	switch n := value.(type) {
	case int:
		return n, true
	case int64:
		return int(n), true
	case float64:
		if n != float64(int(n)) {
			return 0, false
		}
		return int(n), true
	case json.Number:
		i, err := n.Int64()
		if err != nil {
			return 0, false
		}
		return int(i), true
	default:
		return 0, false
	}
}

// registeredTagReader is the injection seam for the E3 registry read. Tests
// override it; the real reader is one scoped GET.
var registeredTagReader = fetchRegisteredTags

// checkTagRegistry is the NETWORK half of the wall: every weighted tag name on
// the body must resolve to a published type:tag document. A nil refusal means
// clear — including every case in which the read was not authoritative, because
// a blind client must not refuse a publish the server would have accepted.
//
// blind reports that the check could not run, so the caller can SAY so instead
// of implying the row was cleared.
func checkTagRegistry(ctx manifest.Context, body map[string]any) (ref *publishWallRefusal, blind bool) {
	tags, spineRef := wallTagEntries(body)
	if spineRef != nil || len(tags) == 0 {
		// The spine check runs first and already refused; nothing to resolve.
		return nil, false
	}
	names := make([]string, 0, len(tags))
	for _, entry := range tags {
		if name, ok := entry["tag"].(string); ok && name != "" {
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return nil, false
	}

	registry, authoritative := registeredTagReader(ctx)
	if !authoritative {
		return nil, true
	}
	known := make(map[string]bool, len(registry))
	for _, name := range registry {
		known[name] = true
	}
	var unknown []string
	for _, name := range names {
		if !known[name] {
			unknown = append(unknown, name)
		}
	}
	if len(unknown) == 0 {
		return nil, false
	}
	suggestions := make(map[string][]string, len(unknown))
	for _, name := range unknown {
		if nearest := nearestRegisteredTags(name, registry); len(nearest) > 0 {
			suggestions[name] = nearest
		}
	}
	return &publishWallRefusal{
		Code:         "unknown_tag",
		Unknown:      unknown,
		Suggestions:  suggestions,
		RegistrySize: len(registry),
	}, false
}

// fetchRegisteredTags reads the dataset's published type:tag documents and
// returns their ids. The second return is AUTHORITATIVE: false whenever the
// answer cannot be trusted as the complete registry — a transport error, a
// non-2xx, an undecodable body, an empty page, or a TRUNCATED page (`hasMore`).
// The truncated page is the subtle one: it decodes fine and looks like a
// registry, and using it would refuse real tags that live past the boundary.
func fetchRegisteredTags(ctx manifest.Context) ([]string, bool) {
	endpoint := fmt.Sprintf("%s?limit=%d",
		ctxScopedURL(ctx, "/v1/data/query/"+url.PathEscape(ctx.Dataset)+"/tag"),
		tagRegistryPageLimit)
	status, respBody, err := doRequest("GET", endpoint, ctxAuthHeaders(ctx), nil)
	if err != nil || status < 200 || status >= 300 {
		return nil, false
	}
	var parsed struct {
		Result struct {
			Documents []struct {
				ID string `json:"_id"`
			} `json:"documents"`
			HasMore bool `json:"hasMore"`
		} `json:"result"`
		Documents []struct {
			ID string `json:"_id"`
		} `json:"documents"`
	}
	if jsonErr := json.Unmarshal(respBody, &parsed); jsonErr != nil {
		return nil, false
	}
	if parsed.Result.HasMore {
		return nil, false
	}
	docs := parsed.Result.Documents
	if len(docs) == 0 {
		docs = parsed.Documents
	}
	names := make([]string, 0, len(docs))
	for _, doc := range docs {
		if doc.ID != "" {
			names = append(names, doc.ID)
		}
	}
	// A registry that reads as EMPTY is indistinguishable from a dataset whose
	// tag schema was never seeded, and refusing every tag on that basis would
	// break --publish outright. Treat it as blind.
	if len(names) == 0 {
		return nil, false
	}
	return names, true
}

// nearestRegisteredTags ranks the registry against one unknown name by Dice
// coefficient over character bigrams — cheap, order-insensitive, and close
// enough to the server's trgm similarity that the client's "did you mean" and
// the server's suggestions agree on the obvious cases. Candidates below
// minTagSuggestionScore are dropped: an empty list is honest, a confident wrong
// list is how a caller invents a SECOND unregistered tag.
func nearestRegisteredTags(name string, registry []string) []string {
	type scored struct {
		name  string
		score float64
	}
	var candidates []scored
	want := tagBigrams(name)
	for _, candidate := range registry {
		score := tagDice(want, tagBigrams(candidate))
		if score >= minTagSuggestionScore {
			candidates = append(candidates, scored{candidate, score})
		}
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].score != candidates[j].score {
			return candidates[i].score > candidates[j].score
		}
		return candidates[i].name < candidates[j].name
	})
	if len(candidates) > maxTagSuggestionsPerName {
		candidates = candidates[:maxTagSuggestionsPerName]
	}
	out := make([]string, 0, len(candidates))
	for _, c := range candidates {
		out = append(out, c.name)
	}
	return out
}

func tagBigrams(s string) map[string]int {
	r := []rune(strings.ToLower(s))
	out := make(map[string]int, len(r))
	if len(r) < 2 {
		if len(r) == 1 {
			out[string(r)]++
		}
		return out
	}
	for i := 0; i+1 < len(r); i++ {
		out[string(r[i:i+2])]++
	}
	return out
}

func tagDice(a, b map[string]int) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	shared, total := 0, 0
	for gram, n := range a {
		total += n
		if m, ok := b[gram]; ok {
			if m < n {
				shared += m
			} else {
				shared += n
			}
		}
	}
	for _, n := range b {
		total += n
	}
	if total == 0 {
		return 0
	}
	return 2 * float64(shared) / float64(total)
}

// orphanedDraftRemedyLines is what the create path says when the publish was
// refused AFTER the draft landed — the residue the pre-flight cannot pre-empt (a
// duplicate_of refusal, a registry the client could not read, a wall rule added
// server-side since this binary was built).
//
// It exists because the old message was itself a phantom generator: it printed
// the BARE id ("created task-4211"), which is the id of a row that does not
// exist yet, and said nothing about the state. A reader took that for a filed
// task, and `bp task claim task-4211` answered 404. So this prints the DRAFT id
// verbatim, the consequence in the words a person uses for it, and BOTH exits —
// a caller who cannot dispose of debris leaves it lying there.
//
// `bp doc delete task <bare-id>` removes BOTH variants: Content.delete_document
// normalizes the id through DraftId.published_id/draft_id and deletes every row
// it finds, so the bare id disposes of the draft.
func orphanedDraftRemedyLines(draftID, bareID string) []string {
	return []string{
		fmt.Sprintf("the row exists as a DRAFT ONLY — %s is NOT ON THE BOARD: `bp task ready` will not list it and `bp task claim %s` will 404.", draftID, bareID),
		"fix the refusal above, then EITHER publish the draft you already have:",
		"  " + taskPublishCommand(bareID),
		"OR delete it so it does not sit in the queue as debris:",
		"  bp doc delete task " + bareID + " --yes",
	}
}

// renderOrphanedDraftRemedy writes those lines to stderr, indented under the
// refusal they belong to.
func renderOrphanedDraftRemedy(out *writer, draftID, bareID string) {
	for _, line := range orphanedDraftRemedyLines(draftID, bareID) {
		out.errf("  %s", line)
	}
}

// orphanedDraftRemedyText is the same remedy folded into one string, for the MCP
// tool's single-message error channel.
func orphanedDraftRemedyText(draftID, bareID string) string {
	return "\n" + strings.Join(orphanedDraftRemedyLines(draftID, bareID), "\n")
}

// mcpPublishWallMessage renders a pre-flight refusal as the MCP tool's error
// text — same headline, same rule/fix, same "nothing was created" guarantee the
// CLI prints, because an agent needs the guarantee more than a human does.
func mcpPublishWallMessage(ref *publishWallRefusal) string {
	parts := append([]string{"task_create: " + ref.headline()}, ref.lines()...)
	parts = append(parts, "nothing was created — no draft was left behind.")
	return strings.Join(parts, "\n")
}
