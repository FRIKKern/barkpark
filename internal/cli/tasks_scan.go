package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
)

// THE FOREIGN-CLAIM SCAN (cchi-w67-bl-bp-task-ls-has-no-status-filter…).
//
// Every epic wave is instructed to scan for foreign claims before it files or
// claims. Until this file that instruction was UNEXECUTABLE: `bp task ls`
// declared limit/offset/cursor and nothing else, so "list the in_progress rows
// held by someone else" had no spelling at all. Two wave-67 verifiers hit it
// and both had to report "no foreign claims" as UNMEASURED — and an unmeasured
// scan renders exactly like a clean one, which is this repo's own thesis defect
// pointed at its task tooling.
//
// FOUR FLAGS, TWO DIFFERENT KINDS, and the difference is the honest part:
//
//   - `--status <lifecycle_status>` is a SERVER filter. GET /v1/tasks honours
//     `filter[lifecycle_status]` (tasks_controller/params.ex @index_filter_keys:
//     kind, lifecycle_status, parent, parent_id, phase_id, label, type), and its
//     filter container is fail-CLOSED, so the narrowing either happens or 400s.
//     The manifest does not DECLARE the key — `task.ls` advertises only
//     limit/offset/cursor — so the CLI cannot pass it through the declared-flag
//     path and stamps it onto the resolved URL here instead. Same seam
//     `--match` uses, for the same reason: the manifest cannot declare what it
//     does not know, but the ROUTE knows it.
//
//   - `--assignee <worker>`, `--claimed`, `--claimed-by <worker>` are CLIENT
//     filters. There is no server filter on either axis — `assignee` and
//     `claim.worker` are not in @index_filter_keys — so they can only ever be
//     applied to rows the client has already read. A client filter over ONE
//     page is a lie shaped like an answer ("no foreign claims" about a ledger
//     it read 100 rows of), so each of them IMPLIES `--all` and says so on
//     stderr. The walk ends at the end of the corpus or with a named error;
//     it never ends quietly short.
//
// WHY --status VALIDATES ITS VALUE. The server's whitelist is on the KEY, not
// the value: `filter[lifecycle_status]=in-progress` (a hyphen) is a 200 with
// zero rows, and zero rows is precisely the reading this task exists to stop
// being ambiguous. So an unknown value is refused here, naming the vocabulary,
// rather than sent to become a clean-looking empty page.
const (
	taskStatusFlag    = "--status"
	taskAssigneeFlag  = "--assignee"
	taskClaimedFlag   = "--claimed"
	taskClaimedByFlag = "--claimed-by"
)

// taskLifecycleStatuses is the server's own lifecycle vocabulary, mirrored from
// api/lib/barkpark/tasks/validation.ex @lifecycle_statuses. Mirrored, not
// derived: the manifest does not carry it, and the alternative to a mirror is
// sending an unvalidated value that comes back as a confidently empty page.
var taskLifecycleStatuses = []string{
	"open",
	"in_progress",
	"blocked",
	"done",
	"cancelled",
	"considering",
	"researching",
}

// taskScanOpts is one `bp task ls` scan narrowing. The zero value is the
// listing every caller got before this file existed — a struct, not four loose
// parameters, so a new knob cannot change what an existing call site does.
type taskScanOpts struct {
	// status is a validated lifecycle_status, applied SERVER-side by
	// appendTaskStatusFilter. Empty means unfiltered.
	status string
	// assignee, when non-empty, keeps rows whose `assignee` equals it
	// (case-insensitive). CLIENT-side.
	assignee string
	// claimed, when true, keeps rows carrying a non-empty `claim.worker`.
	// CLIENT-side.
	claimed bool
	// claimedBy, when non-empty, keeps rows whose `claim.worker` equals it
	// (case-insensitive). CLIENT-side. Distinct from assignee on purpose: the
	// row's assignee and the worker currently HOLDING it are different facts,
	// and the foreign-claim scan is about the second one.
	claimedBy string
}

// clientSide reports whether any narrowing must be applied over walked rows —
// i.e. whether this scan is only honest with `--all`.
func (o taskScanOpts) clientSide() bool {
	return o.assignee != "" || o.claimed || o.claimedBy != ""
}

// any reports whether any narrowing at all was asked for.
func (o taskScanOpts) any() bool { return o.status != "" || o.clientSide() }

// extractTaskScanFlags removes the four scan flags from tail and returns the
// scan, tail without them, and a usage error for a missing or invalid value.
//
// It runs before splitArgs, which would refuse every one of them as an unknown
// command-local flag — the same seam extractTaskMatchFlag uses. The LAST
// spelling of a repeated flag wins, matching --match.
func extractTaskScanFlags(tail []string) (taskScanOpts, []string, error) {
	var opts taskScanOpts
	kept := make([]string, 0, len(tail))

	// valueFlags maps a value-taking flag to the field it fills.
	targets := map[string]*string{
		taskStatusFlag:    &opts.status,
		taskAssigneeFlag:  &opts.assignee,
		taskClaimedByFlag: &opts.claimedBy,
	}
	// given records which value flags were SPELLED, so `--assignee ""` is a
	// usage error rather than a silent match-everything.
	given := map[string]bool{}

	for i := 0; i < len(tail); i++ {
		a := tail[i]
		if a == taskClaimedFlag {
			opts.claimed = true
			continue
		}
		matched := false
		for flag, dst := range targets {
			switch {
			case a == flag:
				if i+1 >= len(tail) {
					return taskScanOpts{}, nil, fmt.Errorf("%s needs a value: %s <value>", flag, flag)
				}
				*dst = tail[i+1]
				given[flag] = true
				i++
				matched = true
			case strings.HasPrefix(a, flag+"="):
				*dst = strings.TrimPrefix(a, flag+"=")
				given[flag] = true
				matched = true
			}
			if matched {
				break
			}
		}
		if !matched {
			kept = append(kept, a)
		}
	}

	// Empty values, checked in a stable order so a caller who spelled two of
	// them wrong is named the same one on every run.
	for _, flag := range []string{taskAssigneeFlag, taskClaimedByFlag, taskStatusFlag} {
		if given[flag] && strings.TrimSpace(*targets[flag]) == "" {
			return taskScanOpts{}, nil, fmt.Errorf(
				"%s needs a non-empty value — an empty %s would print the whole ledger, which is what %s exists to avoid",
				flag, flag, flag)
		}
	}

	if opts.status != "" {
		if err := validateTaskStatus(opts.status); err != nil {
			return taskScanOpts{}, nil, err
		}
	}

	// `--claimed-by X --claimed` is redundant, not contradictory: claimed-by is
	// strictly narrower, so collapse it rather than refusing a caller who was
	// being explicit.
	if opts.claimedBy != "" {
		opts.claimed = false
	}
	return opts, kept, nil
}

// validateTaskStatus refuses a lifecycle_status the server's vocabulary does
// not contain, naming the whole vocabulary. See the file header for why an
// invalid value cannot simply be forwarded.
func validateTaskStatus(status string) error {
	for _, s := range taskLifecycleStatuses {
		if status == s {
			return nil
		}
	}
	vocab := append([]string(nil), taskLifecycleStatuses...)
	sort.Strings(vocab)
	// A near-miss is the common case (`in-progress`, `IN_PROGRESS`), so name it
	// rather than leaving the caller to diff two lists by eye.
	normalized := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(status), "-", "_"))
	suggestion := ""
	for _, s := range taskLifecycleStatuses {
		if normalized == s {
			suggestion = fmt.Sprintf(" — did you mean %s %s?", taskStatusFlag, s)
			break
		}
	}
	return fmt.Errorf(
		"%s %q is not a lifecycle_status; the server would answer 200 with zero rows, which reads exactly like a clean scan. Known: %s%s",
		taskStatusFlag, status, strings.Join(vocab, ", "), suggestion)
}

// appendTaskStatusFilter stamps `filter[lifecycle_status]=<status>` onto the
// resolved URL. Called only when --status was given, so no existing caller's
// URL changes shape.
func appendTaskStatusFilter(rawURL, status string) (string, error) {
	if status == "" {
		return rawURL, nil
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("cannot apply %s to %q: %v", taskStatusFlag, rawURL, err)
	}
	q := u.Query()
	q.Set("filter[lifecycle_status]", status)
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// taskScanRowMatcher builds the CLIENT-side row predicate, or nil when the scan
// asks for no client narrowing (so the walk keeps its unfiltered fast path).
//
// A row missing a field simply does not match on it — never a panic, never a
// wildcard. An unparseable row does not match either: the foreign-claim scan is
// an ABSENCE claim, and a row we could not read is not a row we can vouch for
// being absent from the answer, so it is excluded from the FILTERED output
// while remaining fully visible to the walk's own stall/anchor machinery.
func taskScanRowMatcher(o taskScanOpts) func(json.RawMessage) bool {
	if !o.clientSide() {
		return nil
	}
	assignee := strings.ToLower(o.assignee)
	claimedBy := strings.ToLower(o.claimedBy)
	return func(row json.RawMessage) bool {
		var obj struct {
			Assignee string `json:"assignee"`
			Claim    *struct {
				Worker string `json:"worker"`
			} `json:"claim"`
		}
		if json.Unmarshal(row, &obj) != nil {
			return false
		}
		holder := ""
		if obj.Claim != nil {
			holder = strings.TrimSpace(obj.Claim.Worker)
		}
		if assignee != "" && strings.ToLower(strings.TrimSpace(obj.Assignee)) != assignee {
			return false
		}
		if o.claimed && holder == "" {
			return false
		}
		if claimedBy != "" && strings.ToLower(holder) != claimedBy {
			return false
		}
		return true
	}
}

// andRowFilters composes row predicates with AND, dropping nils. Returns nil
// when nothing survives, so the walk's unfiltered path is preserved exactly.
//
// AND, because `--match dns --claimed` asks one question ("claimed rows about
// dns"), not two. OR would widen a scan whose whole job is to narrow.
func andRowFilters(filters ...func(json.RawMessage) bool) func(json.RawMessage) bool {
	live := make([]func(json.RawMessage) bool, 0, len(filters))
	for _, f := range filters {
		if f != nil {
			live = append(live, f)
		}
	}
	switch len(live) {
	case 0:
		return nil
	case 1:
		return live[0]
	}
	return func(row json.RawMessage) bool {
		for _, f := range live {
			if !f(row) {
				return false
			}
		}
		return true
	}
}

// taskScanClientSideNotice is the stderr line a client-side scan prints, or ""
// when every narrowing asked for was pushed to the server.
//
// It exists because "this filter ran on the client over every page" is the
// difference between a roster and a guess, and the caller cannot tell from the
// output which one they are holding. stderr in every output mode, so `-o json`
// stays one parseable document.
func taskScanClientSideNotice(o taskScanOpts) string {
	if !o.clientSide() {
		return ""
	}
	var named []string
	if o.assignee != "" {
		named = append(named, taskAssigneeFlag)
	}
	if o.claimed {
		named = append(named, taskClaimedFlag)
	}
	if o.claimedBy != "" {
		named = append(named, taskClaimedByFlag)
	}
	server := "no server-side narrowing"
	if o.status != "" {
		server = fmt.Sprintf("%s %s is applied server-side (filter[lifecycle_status])", taskStatusFlag, o.status)
	}
	return fmt.Sprintf(
		"%s has no server-side filter, so it is applied client-side over EVERY page — --all implied, walking to the end of the ledger (%s)",
		strings.Join(named, "/"), server)
}
