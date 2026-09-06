package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE SEARCHABLE LEDGER (cchi-bl-task-get-not-found-hint-is-unsearchable).
//
// `bp task get <truncated-id>` answers not_found and — until this file — the
// remedy it named was `bp task ls`, a verb whose ONLY flags are limit/offset.
// So "run the list and look" meant dumping the whole ledger (8,120 rows,
// ~2.9 MB of JSON at the time of filing) and grepping it locally, on every
// truncated id an agent meets. And the epic's own rows produce truncated ids
// routinely: one P0 row named six of them in a single sentence.
//
// The server cannot help. GET /v1/tasks accepts filter[kind|label|
// lifecycle_status|parent|parent_id|phase_id|type] and nothing else — no `q`,
// no title/id substring — and its filter container is fail-CLOSED, so an
// invented `filter[q]` 400s rather than silently returning the unfiltered
// page. (Checked against the live manifest and
// tasks_controller/params.ex @index_filter_keys.) That leaves the client, and
// the client already owns a hardened offset walk, so this is a filter hook on
// that walk plus a hint that names it — not a new route.
//
// Two surfaces, one vocabulary:
//
//   - `bp task ls --match <substring>` walks every page and prints only rows
//     whose doc_id OR title contains the substring, case-insensitively.
//   - `bp task get <missing-id>` names that exact command with the id the
//     caller typed, and — when exactly ONE published doc_id has the typed id as
//     a strict prefix — names that id as a suggestion. A suggestion, never a
//     redirect: the CLI does not silently fetch a document the caller did not
//     ask for.
const taskMatchFlag = "--match"

// taskLsCommandID and taskGetCommandID are the manifest ids this file keys on.
// Keyed on the ID, never on the noun alone: `--match` must not be silently
// accepted by any other task verb, and the not_found enrichment must not fire
// on a refusal from a verb whose id was not a task doc_id.
const (
	taskLsCommandID  = "task.ls"
	taskGetCommandID = "task.get"
)

// taskIDPrefixParam is the server-side lookup this file prefers over the walk:
// `GET /v1/tasks?id_prefix=<id>` answers with doc_id + title only, from one
// indexed query (Barkpark.Tasks.Query.id_prefix_lookup/2). It is spelled here
// once so the probe and the doc comments cannot drift.
const taskIDPrefixParam = "id_prefix"

// extractTaskMatchFlag removes `--match <value>` / `--match=<value>` from tail
// and returns the LAST value given, tail without it, and a usage error when the
// flag was given without a value.
//
// It runs before splitArgs, which would otherwise refuse `--match` as an
// unknown command-local flag — the same seam
// `--fail-on-failed-delivery` (webhook.test-send) and `--delete-unpublished`
// (doc discard-draft) use, and for the same reason: the manifest cannot declare
// a flag the server knows nothing about.
//
// An empty value is a usage error, not a match-everything: `--match ""` that
// silently listed all 8,120 rows would be the exact dump this flag exists to
// avoid, wearing the costume of a filtered read.
func extractTaskMatchFlag(tail []string) (string, []string, error) {
	match := ""
	given := false
	kept := make([]string, 0, len(tail))
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		switch {
		case a == taskMatchFlag:
			if i+1 >= len(tail) {
				return "", nil, fmt.Errorf("%s needs a value: %s <substring>", taskMatchFlag, taskMatchFlag)
			}
			match = tail[i+1]
			given = true
			i++
		case strings.HasPrefix(a, taskMatchFlag+"="):
			match = strings.TrimPrefix(a, taskMatchFlag+"=")
			given = true
		default:
			kept = append(kept, a)
		}
	}
	if given && strings.TrimSpace(match) == "" {
		return "", nil, fmt.Errorf("%s needs a non-empty substring — an empty --match would print the whole ledger, which is what --match exists to avoid", taskMatchFlag)
	}
	return match, kept, nil
}

// taskRowMatcher builds the row predicate for `--match`: case-insensitive
// containment over doc_id AND title.
//
// Both fields, because the two ways an id reaches an agent fail differently. A
// truncated doc_id (`cch-w57-s5`) is a prefix of the real id, so doc_id
// matching finds it; a row remembered by what it SAID ("the dns sweep") has no
// id at all, so title matching finds that. A row missing either field simply
// does not match on it — never a panic, never a wildcard.
func taskRowMatcher(needle string) func(json.RawMessage) bool {
	lowered := strings.ToLower(needle)
	return func(row json.RawMessage) bool {
		var obj struct {
			DocID string `json:"doc_id"`
			Title string `json:"title"`
		}
		if json.Unmarshal(row, &obj) != nil {
			return false
		}
		return strings.Contains(strings.ToLower(obj.DocID), lowered) ||
			strings.Contains(strings.ToLower(obj.Title), lowered)
	}
}

// Bounds on the prefix-suggestion walk. The suggestion rides the not_found
// path, so it must NEVER turn a fast 404 into a hang: a caller who typed a
// genuinely bogus id is entitled to their refusal now, not after a full ledger
// crawl.
//
// The page size is 1000 because that is the server's own clamp
// (Params.parse_limit(params["limit"], 1000, 1000)) — asking for more returns
// 1000 anyway, so 1000 is the fewest round-trips the route can be walked in
// (~9 for the 8,120-row ledger, versus ~82 at the --all walk's page size of
// 100). The ceiling and the deadline are BOTH hard: whichever trips first
// abandons the suggestion. Abandoning is safe in exactly one direction —
// "exactly one candidate" is an ABSENCE claim about every row not read, so a
// truncated walk cannot make it. It falls back to the plain hint, which still
// names `--match` and is still one command from the answer.
const (
	// taskRouteMaxLimit is the server's own clamp on GET /v1/tasks
	// (Params.parse_limit(params["limit"], 1000, 1000)). Asking for more
	// returns 1000 anyway — and, worse, returns it SILENTLY.
	taskRouteMaxLimit = 1000

	// taskWalkPageSize is the window `bp task ls --match` walks in. It is the
	// clamp MINUS ONE, and the minus one is load-bearing.
	//
	// paginatedAllWalk requests pageSize+1 and keeps the extra row as the
	// lookahead anchor that proves the next page opens where this one left off.
	// A pageSize of 1000 asks for 1001, the server clamps it to 1000, and the
	// walk gets no anchor row — so EVERY boundary goes unverified and says so,
	// eight times, on stderr. Measured live: the run printed
	// "pagination boundary at offset N is unverified" for all eight boundaries.
	// That trades away the exact shift-detection the walk exists for. 999 asks
	// for 1000, lands ON the clamp, and keeps every boundary anchored — at the
	// same nine round-trips.
	taskWalkPageSize = taskRouteMaxLimit - 1

	// The suggestion walk asks for the clamp exactly: it keeps no lookahead row
	// (a best-effort suggestion needs no shift proof — it abandons instead), so
	// it has no +1 to leave room for.
	taskSuggestPageSize = taskRouteMaxLimit
	taskSuggestMaxPages = 25

	// taskSuggestConcurrency is how many pages are IN FLIGHT at once, and it is
	// the reason this suggestion fires on the real ledger at all.
	//
	// The block below is right that the cost is server-side latency per
	// request and that no projection can shrink it. It draws the wrong
	// conclusion from that, because it only ever considered paying the latency
	// SERIALLY. Re-measured 2026-09-05 against guerrilla: the ledger is 8,565
	// rows — nine pages at the clamp — and a single `limit=1000&view=brief`
	// page costs 1.01s / 1.54s / 0.86s (~350-420 KB each). Nine of those in a
	// row is ~9-13s against a 6s deadline, so the walk did not merely risk
	// abandoning on this ledger: it abandoned EVERY time, and `bp task get
	// <prefix>` and `bp task get <bogus-id>` printed the identical
	// "no close-id scan was made" line. The one message the caller needed to
	// tell apart was the one message it could not.
	//
	// Four in flight turns nine pages into three waves — ~3-4s measured, inside
	// the SAME 6s bound. Nothing about the spend the caller consented to
	// changes: same nine requests, same bytes, same ceiling, same deadline.
	// Only the waiting is no longer done one page at a time.
	//
	// FOUR, NOT MORE — and this is measured, not taste. Widening the wave does
	// NOT keep paying: the route contends with itself. Same ledger, same
	// binary, only the width changed, three runs each on a busy box:
	//
	//   width 6:  7.89s / 15.89s / 13.30s   (every run blew the 6s bound)
	//   width 4:  3.34s /  9.22s /  7.29s
	//   width 3:  7.07s /  3.05s /  1.87s
	//
	// Six is not "twice as fast as three", it is reliably the WORST of the
	// three. Beyond a handful in flight the server starts queueing the walk
	// behind itself, so the extra requests buy latency for everyone including
	// the caller who issued them — and firing all 25 pages of the ceiling at a
	// shared production route to enrich a 404 would be a thundering herd
	// charged to every other caller. Four sits at the knee.
	//
	// WHAT THIS DOES AND DOES NOT BUY, stated plainly because the spread above
	// is wide: those runs were taken while the box itself was under a task
	// campaign (load average ~30-50), and at that load NO width hits the
	// deadline every time. Serial hits it NEVER — its floor is nine sequential
	// pages, ~9s, which is past 6s before the first slow page. So the claim
	// here is the honest one: this makes the suggestion POSSIBLE on a
	// nine-page ledger, where it was arithmetically impossible before. It is
	// not a guarantee, and it does not need to be — the walk still abandons
	// inside its bound and taskGetNotFoundHint still SAYS it abandoned, which
	// is the pre-existing and correct behaviour for a scan that did not finish.
	//
	// CONCURRENCY DOES NOT WEAKEN THE UNIQUENESS CLAIM, and it is worth being
	// exact about why, because "exactly one" is an absence claim over every row
	// not read. Offset pagination over a shifting collection can miss a row
	// between two reads — but that hazard is a function of the WALL-CLOCK GAP
	// between the first page and the last, and this change shrinks that gap
	// from ~11s to ~3s. Pages are still consumed in ascending order, so an
	// unreadable page still abandons before any later page is inspected, and a
	// short page still finalizes before the pages beyond it are looked at.
	// Parallel here is strictly safer than serial, not merely no worse.
	taskSuggestConcurrency = 4

	// THE DEADLINE, CHOSEN AGAINST MEASURED PAGES, NOT TASTE — and it is the
	// reason this suggestion is deliberately allowed to give up.
	//
	// Measured against the live ledger (8,120 tasks, 9 pages), three runs over
	// ONE keep-alive connection: 30.1s, 27.4s, 40.6s for 2.91 MB. The bytes are
	// not the cost — `view=brief` already cut a page from 10.2 MB to ~340 KB and
	// the walk still takes ~3-5s PER PAGE, because the time is server-side per
	// request. So a COMPLETE scan of a ledger this size cannot be bought at any
	// latency a refusal may honestly charge, no matter how the client asks.
	//
	// That is a fact about the route, not a tuning failure, and the honest
	// response is to bound the spend and SAY when the bound was hit rather than
	// to raise it until a 404 takes half a minute. 6s buys a small ledger's
	// whole scan (a fresh instance, a local dev server, any corpus of a page or
	// two — where the suggestion fires exactly as specified) and about two pages
	// of a large one, after which the walk stops and the hint reports that it
	// stopped. The real fix is server-side (a prefix lookup, or an id-only
	// projection on /v1/tasks) and is out of this change's fence.
)

// taskSuggestDeadline is a var, not a const, for ONE reason: the arm that
// enforces it is a distinct exit from the page ceiling, and a test that cannot
// reach it cannot prove it reports an ABANDONED scan rather than a completed
// one. Shrinking it is the only way to exercise that arm without spending six
// real seconds per run. Never reassigned outside tests.
var taskSuggestDeadline = 6 * time.Second

// taskSuggestView is the projection the suggestion walk asks for. It reads
// nothing but doc_id, and the brief view carries doc_id and title while
// dropping the brief/description/criteria bulk that makes a full task row fat:
// measured against the live route, 337 KB per 1000-row page instead of
// 10.2 MB, and ~1.2s instead of ~4s. Nothing is rendered from these rows, so
// the narrower projection has no effect a caller can observe — only a 30x
// cheaper one they do not wait for.
//
// It is sent as a raw query param rather than through resolveView because
// task.ls declares no `views` contract in the manifest, so the CLI's own view
// resolution would send nothing. Asking for a view a route does not implement
// is harmless — an unknown param is ignored and the walk reads full rows, just
// more slowly.
const taskSuggestView = "brief"

// taskPrefixSuggestion returns the ONE published task doc_id that has typed as
// a strict prefix, or "" when there is no such id, more than one, or the walk
// could not finish inside its bounds.
//
// "Exactly one" is the whole contract. Two candidates mean the CLI does not
// know which one the caller meant, and naming either would be a guess dressed
// as an answer — so two candidates say nothing, exactly as zero do.
//
// Candidates are deduplicated by doc_id: a page that repeats a row (a
// collection shifting mid-walk, the same hazard paginatedAllWalk refuses over)
// would otherwise turn one real candidate into a phantom pair and suppress a
// correct suggestion.
// It returns (suggestion, complete). complete is false when the walk gave up —
// on a bound, an error, or an unreadable page — and the caller must then say
// that no scan was made rather than implying no candidate exists. "" with
// complete=true is a real absence claim; "" with complete=false is silence.
func taskPrefixSuggestion(out *writer, m *manifest.Manifest, ctx manifest.Context, typed string) (string, bool) {
	if m == nil || typed == "" {
		return "", false
	}
	var lsCmd manifest.Command
	found := false
	for _, c := range m.Commands {
		if c.ID == taskLsCommandID {
			lsCmd, found = c, true
			break
		}
	}
	if !found {
		return "", false
	}
	baseURL, err := m.BuildURL(lsCmd, ctx, map[string]string{})
	if err != nil {
		return "", false
	}
	headers := authHeaders(lsCmd, ctx)

	// SERVER FIRST. `?id_prefix=` asks the route the question directly and
	// answers it in ONE request from an indexed lookup, so on a server that
	// implements it the walk below never runs and the 404 stays a 404-shaped
	// wait. `served` is false ONLY when this server cannot answer — see
	// taskPrefixLookupServer for how that is decided — and the walk is then the
	// fallback, unchanged, still honest about giving up.
	if suggestion, served := taskPrefixLookupServer(lsCmd, ctx, baseURL, headers, typed); served {
		return suggestion, true
	}
	return taskPrefixScanWalk(out, lsCmd, baseURL, headers, typed)
}

// taskPrefixLookupServer asks `GET /v1/tasks?id_prefix=<typed>` — the
// server-side lookup (cchi-bl-task-get-needs-a-server-side-prefix-lookup) —
// and returns (suggestion, served).
//
// served=true means THIS SERVER ANSWERED THE QUESTION, and the answer is
// complete: "" then means zero-or-many, a real absence claim, never silence.
// served=false means the server could not be asked, and the caller must fall
// back rather than infer anything.
//
// HOW "COULD NOT BE ASKED" IS DECIDED, and why it is not a manifest lookup.
// `task.ls` declares no per-param contract in the manifest (the same reason
// `view=brief` is sent as a raw param above), so there is nothing to read a
// capability off. The route itself is the capability probe: `GET /v1/tasks`
// fail-CLOSES on an unknown top-level param, so a server without this filter
// answers 400 naming `id_prefix` — a definitive "I do not have it" — while a
// server with it answers 200. A 400 therefore means fall back, and so does any
// other non-2xx, a transport error, or a 200 whose body is not this lookup's
// envelope (an HTTP 200 is no proof the body came from Barkpark).
//
// The `id_prefix` ECHO is what makes the 200 arm safe. A hypothetical server
// that accepted the param and IGNORED it would return the ordinary task page:
// its rows would be arbitrary tasks, and one of them could carry the typed id
// as a prefix by luck. Requiring the echo — a field the ordinary page does not
// have — means an ignored param reads as "not served" rather than as a
// suggestion computed over the wrong set.
func taskPrefixLookupServer(cmd manifest.Command, ctx manifest.Context, baseURL string, headers map[string]string, typed string) (string, bool) {
	sep := "?"
	if strings.Contains(baseURL, "?") {
		sep = "&"
	}
	lookupURL := baseURL + sep + taskIDPrefixParam + "=" + url.QueryEscape(typed)

	status, body, err := doRequest(cmd.HTTP.Method, lookupURL, headers, nil)
	if err != nil || status < 200 || status >= 300 {
		return "", false
	}

	var payload struct {
		IDPrefix *string `json:"id_prefix"`
		Matches  []struct {
			DocID string `json:"doc_id"`
		} `json:"matches"`
	}
	if json.Unmarshal(unwrapResult(body), &payload) != nil || payload.IDPrefix == nil {
		return "", false
	}

	// EXACTLY ONE is the same contract the walk holds: two candidates mean the
	// CLI does not know which one the caller meant, and a STRICT extension is
	// required because an id equal to what was typed is the id that just 404'd.
	if len(payload.Matches) == 1 && len(payload.Matches[0].DocID) > len(typed) {
		return payload.Matches[0].DocID, true
	}
	return "", true
}

// taskPrefixScanWalk is the pre-server-filter client-side walk, kept verbatim
// as the fallback for a server that does not implement `?id_prefix=`. The CLI
// is manifest-driven and talks to instances it did not ship with, so deleting
// this would turn a working (if slow) suggestion into no suggestion at all on
// every older box. Against a server that HAS the filter it is unreachable.
func taskPrefixScanWalk(out *writer, lsCmd manifest.Command, baseURL string, headers map[string]string, typed string) (string, bool) {

	// ANNOUNCE THE WAIT. This walk can take seconds, and it hangs off a
	// refusal — the one place a caller expects an instant answer. A silent
	// multi-second pause on a 404 reads as a hung CLI, which is worse than no
	// suggestion at all; one line naming what is happening and what it is
	// bounded by turns it into a wait the reader can sit through or Ctrl-C.
	if out != nil {
		out.userErr("no such task id — scanning the ledger for a close match (up to %s)…", taskSuggestDeadline)
	}

	// fetchPage reads ONE page. ok=false covers every reason the page cannot be
	// counted — transport error, non-2xx, or a 200 whose body is not a readable
	// Barkpark list (the same law the --all walk applies: an HTTP 200 is no
	// proof the body came from Barkpark). It returns a value rather than
	// mutating shared state so it is safe to run in the wave below.
	fetchPage := func(page int) suggestPageResult {
		pageURL := withOffsetLimit(baseURL, page*taskSuggestPageSize, taskSuggestPageSize) + "&view=" + taskSuggestView
		status, body, err := doRequest(lsCmd.HTTP.Method, pageURL, headers, nil)
		if err != nil || status < 200 || status >= 300 {
			return suggestPageResult{}
		}
		rows, key := extractListRows(unwrapResult(body))
		if key == "" {
			return suggestPageResult{}
		}
		return suggestPageResult{rows: rows, ok: true}
	}

	seen := map[string]bool{}
	deadline := time.Now().Add(taskSuggestDeadline)
	for base := 0; base < taskSuggestMaxPages; base += taskSuggestConcurrency {
		if time.Now().After(deadline) {
			return "", false
		}
		width := taskSuggestConcurrency
		if base+width > taskSuggestMaxPages {
			width = taskSuggestMaxPages - base
		}
		// Each goroutine writes its own slot and reads none, so the slice needs
		// no lock; the WaitGroup is the happens-before edge for every read below.
		wave := make([]suggestPageResult, width)
		var wg sync.WaitGroup
		for i := 0; i < width; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				wave[i] = fetchPage(base + i)
			}(i)
		}
		wg.Wait()

		// ASCENDING ORDER IS THE CONTRACT. The pages arrived in whatever order
		// the network gave them, but they are CONSUMED lowest-offset first, so
		// every exit below fires exactly where the serial walk fired it: an
		// unreadable page abandons before any later page is inspected, and a
		// short page finalizes before the empty pages beyond it are looked at.
		for i := 0; i < width; i++ {
			p := wave[i]
			if !p.ok {
				// An unreadable page cannot support an "exactly one" claim, so
				// the suggestion is abandoned rather than computed over a
				// partial read.
				return "", false
			}
			for _, row := range p.rows {
				var obj struct {
					DocID string `json:"doc_id"`
				}
				if json.Unmarshal(row, &obj) != nil {
					continue
				}
				if len(obj.DocID) > len(typed) && strings.HasPrefix(obj.DocID, typed) {
					seen[obj.DocID] = true
					if len(seen) > 1 {
						// Two candidates already: no further page can restore
						// uniqueness. This IS a complete answer: "not exactly
						// one" is settled.
						return "", true
					}
				}
			}
			if len(p.rows) < taskSuggestPageSize {
				// Short page: the walk reached the end of the collection, so the
				// count below is over EVERY row, which is what "exactly one" needs.
				if len(seen) == 1 {
					for id := range seen {
						return id, true
					}
				}
				return "", true
			}
		}
	}
	// Page ceiling reached without a short page — the walk never saw the end of
	// the ledger, so it cannot claim uniqueness.
	return "", false
}

// suggestPageResult is one page of the suggestion walk. ok=false is the single
// "do not count this page" signal: it collapses transport failure, a non-2xx,
// and an unreadable 200 body, because the walk's response to all three is
// identical — abandon, and let the hint say no scan was made.
type suggestPageResult struct {
	rows []json.RawMessage
	ok   bool
}

// taskGetNotFoundHint is the remedy for a `bp task get <id>` not_found: it
// names `bp task ls --match <the id the caller typed>` and, when exactly one
// published doc_id extends that id, names it.
//
// It replaces the generic notFoundHint for this one command because that hint
// named `bp task ls` with no flag — a remedy whose cost is the whole ledger.
// The dataset clause is carried over verbatim: /v1/tasks has no :dataset
// placeholder, and a reader who reaches for --dataset next has been sent down a
// second dead end.
//
// TWO NEIGHBOURS IT IS NOT, because both answer a grep a reader would type
// here: errors.go's notFoundHint is the manifest-derived hint for EVERY noun
// (the one this overrides), and usage.go's usageSuggestNouns is a different
// "did you mean" entirely — it suggests NOUNS on a usage error, never a
// document id.
func taskGetNotFoundHint(out *writer, m *manifest.Manifest, ctx manifest.Context, typed string) string {
	if typed == "" {
		return ""
	}
	search := fmt.Sprintf("run `bp task ls --match %s` — a case-insensitive substring of doc_id or title, matched over every page", typed)
	scope := "(this route is not dataset-scoped, so --dataset cannot affect it)"

	suggestion, complete := taskPrefixSuggestion(out, m, ctx, typed)
	switch {
	case suggestion != "":
		return fmt.Sprintf("did you mean `%s`? it is the only published task id starting with `%s`. %s %s", suggestion, typed, search, scope)
	case !complete:
		// SILENCE IS NOT ABSENCE. The scan gave up, so "no close id" was never
		// established — and a hint that quietly omitted the suggestion here
		// would let the reader infer an absence the CLI never checked.
		return fmt.Sprintf("no close-id scan was made (this ledger is larger than a %s scan can read); %s %s", taskSuggestDeadline, search, scope)
	}
	return search + " " + scope
}

// taskGetTypedID recovers the doc_id positional the caller typed, or "" when
// the command is not `task get` or bound no id. It reads the ALREADY-BOUND arg
// map shape via bindArgs rather than re-scanning tail, so a flag value can
// never be mistaken for the id.
func taskGetTypedID(cmd manifest.Command, tail []string) string {
	if cmd.ID != taskGetCommandID {
		return ""
	}
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return ""
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return ""
	}
	return args["doc_id"]
}
