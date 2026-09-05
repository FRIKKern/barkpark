package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// cchi-w67-bl-bp-task-ls-has-no-status-filter — the foreign-claim scan.
//
// THE RED-WITHOUT for every test in this file is the same: before tasks_scan.go
// every one of --status/--assignee/--claimed/--claimed-by reached splitArgs as
// an unknown command-local flag and the run died with
// `unknown flag --status for task ls` (measured live against guerrilla,
// 2026-09-05). So each test below fails at the FIRST assertion — exit code —
// on the pre-change tree, and none of them can pass vacuously.

// scanRow is one row of the fake ledger, carrying the two claim-holder fields
// the live /v1/tasks render emits: the row's `assignee` and, separately, the
// worker currently HOLDING it under `claim.worker`. They are different facts,
// and conflating them is the bug this fixture exists to catch.
type scanRow struct {
	DocID     string `json:"doc_id"`
	Title     string `json:"title"`
	Lifecycle string `json:"lifecycle_status"`
	Assignee  string `json:"assignee,omitempty"`
	Claim     *struct {
		Worker string `json:"worker"`
	} `json:"claim,omitempty"`
}

func claimedBy(worker string) *struct {
	Worker string `json:"worker"`
} {
	return &struct {
		Worker string `json:"worker"`
	}{Worker: worker}
}

// scanLedger serves GET /v1/tasks honouring offset/limit AND the server's real
// `filter[lifecycle_status]` narrowing — because that is the whole point of the
// --status half: it must leave the client. It records every query string it was
// asked, so a test can prove the filter was SENT rather than applied locally.
type scanLedger struct {
	mu      sync.Mutex
	queries []string
}

func (l *scanLedger) seen() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.queries...)
}

func scanLedgerServer(t *testing.T, rows []scanRow) (*httptest.Server, *scanLedger) {
	t.Helper()
	l := &scanLedger{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/v1/tasks" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such route"}}`))
			return
		}
		l.mu.Lock()
		l.queries = append(l.queries, r.URL.RawQuery)
		l.mu.Unlock()

		// The server-side narrowing, applied exactly where the real one is:
		// BEFORE paging, so offsets index the filtered set.
		want := r.URL.Query().Get("filter[lifecycle_status]")
		kept := make([]scanRow, 0, len(rows))
		for _, row := range rows {
			if want == "" || row.Lifecycle == want {
				kept = append(kept, row)
			}
		}
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
		if err != nil || limit <= 0 {
			limit = len(kept)
		}
		page := []scanRow{}
		for i := offset; i < len(kept) && i < offset+limit; i++ {
			page = append(page, kept[i])
		}
		body, _ := json.Marshal(map[string]any{"ok": true, "docs": page})
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv, l
}

// scanFixture is the roster every filtering test reads: one epic's worth of
// rows spanning both lifecycle values and both claim-holder axes, with a row
// whose assignee and claim.worker DISAGREE (`split-row`) so a filter that reads
// the wrong field is caught rather than accidentally right.
func scanFixture() []scanRow {
	return []scanRow{
		{DocID: "epic-w1-alpha", Title: "alpha", Lifecycle: "in_progress", Assignee: "lead-cli-3", Claim: claimedBy("lead-cli-3")},
		{DocID: "epic-w1-beta", Title: "beta", Lifecycle: "in_progress", Assignee: "lead-api-1", Claim: claimedBy("lead-api-1")},
		{DocID: "epic-w1-unclaimed", Title: "gamma", Lifecycle: "in_progress", Assignee: "lead-cli-3"},
		{DocID: "epic-w1-split-row", Title: "delta", Lifecycle: "in_progress", Assignee: "lead-cli-3", Claim: claimedBy("lead-api-1")},
		{DocID: "epic-w1-open", Title: "epsilon", Lifecycle: "open", Assignee: "lead-cli-3", Claim: claimedBy("lead-cli-3")},
	}
}

func scanManifest() *manifest.Manifest {
	return &manifest.Manifest{Commands: []manifest.Command{{
		ID: taskLsCommandID, Noun: "task", Verb: "ls",
		HTTP:      manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks"},
		Paginated: true,
		Flags: []manifest.Flag{
			{Name: "limit", Type: "int"},
			{Name: "offset", Type: "int"},
		},
	}}}
}

func scannedDocIDs(t *testing.T, stdout string) []string {
	t.Helper()
	var env struct {
		Docs []scanRow `json:"docs"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a docs envelope: %v\n%s", err, stdout)
	}
	ids := make([]string, 0, len(env.Docs))
	for _, d := range env.Docs {
		ids = append(ids, d.DocID)
	}
	return ids
}

func assertIDs(t *testing.T, got []string, want ...string) {
	t.Helper()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("rows = %v, want %v", got, want)
	}
}

// ---------------------------------------------------------------------------
// --status: the SERVER half
// ---------------------------------------------------------------------------

// The narrowing must LEAVE THE CLIENT. A --status honoured client-side over the
// default 100-row page would answer "these are the in_progress rows" about a
// window it did not choose — the same silence the whole row is about, one layer
// down. So this asserts on the wire, not on the output.
func TestTaskLsStatus_IsSentAsAServerFilter(t *testing.T) {
	srv, ledger := scanLedgerServer(t, scanFixture())

	stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--status", "in_progress")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	seen := ledger.seen()
	if len(seen) != 1 {
		t.Fatalf("requests = %d (%v), want exactly 1 — --status alone must NOT imply a full walk", len(seen), seen)
	}
	// The literal wire spelling GET /v1/tasks whitelists
	// (tasks_controller/params.ex @index_filter_keys). url.Values.Encode
	// percent-encodes the brackets, so assert on the decoded query.
	if !strings.Contains(seen[0], "filter%5Blifecycle_status%5D=in_progress") {
		t.Fatalf("query %q does not carry filter[lifecycle_status]=in_progress", seen[0])
	}
	assertIDs(t, scannedDocIDs(t, stdout),
		"epic-w1-alpha", "epic-w1-beta", "epic-w1-unclaimed", "epic-w1-split-row")
}

// The pre-existing URL must not change by a byte when --status is absent: the
// stamp is opt-in, and a caller who never typed it sends what they always sent.
func TestTaskLsWithoutStatus_SendsNoFilterParam(t *testing.T) {
	srv, ledger := scanLedgerServer(t, scanFixture())

	_, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID)
	if code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, stderr)
	}
	for _, q := range ledger.seen() {
		if strings.Contains(q, "filter") {
			t.Fatalf("an unfiltered `task ls` sent %q — the stamp must be opt-in", q)
		}
	}
}

// An invalid lifecycle value is REFUSED, not forwarded. The server's whitelist
// is on the KEY, so `filter[lifecycle_status]=in-progress` is a 200 with zero
// rows — and zero rows is exactly the reading this task exists to disambiguate.
// A near-miss is named.
func TestTaskLsStatus_RefusesAValueTheServerWouldSilentlyEmpty(t *testing.T) {
	srv, ledger := scanLedgerServer(t, scanFixture())

	stdout, _, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--status", "in-progress")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage) for an invalid lifecycle_status", code, exitUsage)
	}
	if n := len(ledger.seen()); n != 0 {
		t.Fatalf("a refused --status still sent %d request(s) — the refusal must precede the send", n)
	}
	if !strings.Contains(stdout, "in_progress") {
		t.Fatalf("the refusal does not name the near-miss spelling: %s", stdout)
	}
	if !strings.Contains(stdout, "zero rows") {
		t.Fatalf("the refusal does not say WHY forwarding it would be dangerous: %s", stdout)
	}
}

func TestTaskLsStatus_UsageErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		tail []string
	}{
		{"no value", []string{"--status"}},
		{"empty value", []string{"--status", ""}},
		{"empty via equals", []string{"--status="}},
		{"empty assignee", []string{"--assignee", "  "}},
		{"no claimed-by value", []string{"--claimed-by"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, ledger := scanLedgerServer(t, scanFixture())
			_, _, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, tc.tail...)
			if code != exitUsage {
				t.Fatalf("exit = %d, want %d", code, exitUsage)
			}
			if n := len(ledger.seen()); n != 0 {
				t.Fatalf("a usage error still sent %d request(s)", n)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// --claimed / --claimed-by / --assignee: the CLIENT half
// ---------------------------------------------------------------------------

// The foreign-claim scan in one command, exactly as the acceptance criterion
// spells it: in_progress rows currently held by someone. `epic-w1-unclaimed` is
// in_progress with no claim and must NOT appear; `epic-w1-open` is claimed but
// not in_progress and must not appear either — so a filter that dropped either
// half of the AND is caught.
func TestTaskLsStatusClaimed_IsTheForeignClaimScan(t *testing.T) {
	srv, ledger := scanLedgerServer(t, scanFixture())

	stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--status", "in_progress", "--claimed")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	assertIDs(t, scannedDocIDs(t, stdout), "epic-w1-alpha", "epic-w1-beta", "epic-w1-split-row")

	// The server filter still left the client even though the walk is on.
	for _, q := range ledger.seen() {
		if !strings.Contains(q, "filter%5Blifecycle_status%5D=in_progress") {
			t.Fatalf("a walked page dropped the server filter: %q", q)
		}
	}
}

// `--claimed-by` reads claim.worker, `--assignee` reads assignee, and the
// `split-row` fixture (assignee lead-cli-3, held by lead-api-1) proves they are
// not the same read. A filter wired to the wrong field flips exactly one of
// these two subtests.
func TestTaskLsClaimHolderAxesAreDistinctFields(t *testing.T) {
	t.Run("--claimed-by reads claim.worker", func(t *testing.T) {
		srv, _ := scanLedgerServer(t, scanFixture())
		stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--claimed-by", "lead-api-1")
		if code != exitOK {
			t.Fatalf("exit = %d; stderr=%q", code, stderr)
		}
		assertIDs(t, scannedDocIDs(t, stdout), "epic-w1-beta", "epic-w1-split-row")
	})
	t.Run("--assignee reads assignee", func(t *testing.T) {
		srv, _ := scanLedgerServer(t, scanFixture())
		stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--assignee", "lead-api-1")
		if code != exitOK {
			t.Fatalf("exit = %d; stderr=%q", code, stderr)
		}
		assertIDs(t, scannedDocIDs(t, stdout), "epic-w1-beta")
	})
	// Case-insensitive, because a worker name reaches an agent from prose as
	// often as from JSON.
	t.Run("case-insensitive", func(t *testing.T) {
		srv, _ := scanLedgerServer(t, scanFixture())
		stdout, _, _ := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--claimed-by", "LEAD-API-1")
		assertIDs(t, scannedDocIDs(t, stdout), "epic-w1-beta", "epic-w1-split-row")
	})
}

// A CLIENT-side filter is only honest if it saw every page, so it implies --all
// WITHOUT the caller typing it — the needle lives past page one here, where a
// single-page read finds nothing and reports a clean "no foreign claims".
//
// This is the test that fails if the --all implication is ever dropped: it
// would return zero rows and exit 0, which is the defect wearing a green.
func TestTaskLsClaimedWalksEveryPageWithoutAll(t *testing.T) {
	rows := make([]scanRow, 0, taskWalkPageSize+5)
	for i := 0; i < taskWalkPageSize+4; i++ {
		rows = append(rows, scanRow{
			DocID:     fmt.Sprintf("filler-%03d", i),
			Lifecycle: "in_progress",
			Assignee:  "nobody",
		})
	}
	// The one claimed row, seated past the first page boundary.
	rows = append(rows, scanRow{
		DocID:     "the-foreign-claim",
		Lifecycle: "in_progress",
		Assignee:  "lead-api-1",
		Claim:     claimedBy("lead-api-1"),
	})

	srv, ledger := scanLedgerServer(t, rows)
	stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--claimed")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
	}
	assertIDs(t, scannedDocIDs(t, stdout), "the-foreign-claim")
	if n := len(ledger.seen()); n < 2 {
		t.Fatalf("requests = %d — a row past page one was found without walking, so the fixture is vacuous", n)
	}
}

// The client/server split is STATED, in every output mode, on stderr. A caller
// cannot otherwise tell a roster from a guess.
func TestTaskLsClientSideScanAnnouncesItselfOnStderrOnly(t *testing.T) {
	srv, _ := scanLedgerServer(t, scanFixture())
	stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--status", "in_progress", "--claimed")
	if code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "--claimed") || !strings.Contains(stderr, "client-side") {
		t.Fatalf("stderr does not name the client-side filter: %q", stderr)
	}
	if !strings.Contains(stderr, "--all implied") {
		t.Fatalf("stderr does not say the walk went to the end: %q", stderr)
	}
	if !strings.Contains(stderr, "server-side") {
		t.Fatalf("stderr does not distinguish the server-side half: %q", stderr)
	}
	// -o json stays ONE parseable document.
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("the notice broke -o json: %v\nstdout=%q", err, stdout)
	}
}

// A --status-only scan pushes everything to the server, so it must NOT claim a
// client-side walk it did not make.
func TestTaskLsServerOnlyScanIsSilent(t *testing.T) {
	srv, _ := scanLedgerServer(t, scanFixture())
	_, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID, "--status", "in_progress")
	if code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, stderr)
	}
	if strings.Contains(stderr, "client-side") {
		t.Fatalf("a server-only scan announced a client-side walk: %q", stderr)
	}
}

// --match and the scan compose with AND — one question, not two. Dropping
// either predicate widens the answer, and both directions are asserted.
func TestTaskLsMatchAndScanComposeWithAnd(t *testing.T) {
	srv, _ := scanLedgerServer(t, scanFixture())
	stdout, stderr, code := runTaskCmd(t, srv, scanManifest(), taskLsCommandID,
		"--match", "split", "--claimed-by", "lead-api-1")
	if code != exitOK {
		t.Fatalf("exit = %d; stderr=%q", code, stderr)
	}
	assertIDs(t, scannedDocIDs(t, stdout), "epic-w1-split-row")

	// Same --match, a claim holder that excludes it: an OR would still print it.
	stdout2, _, _ := runTaskCmd(t, srv, scanManifest(), taskLsCommandID,
		"--match", "split", "--claimed-by", "lead-cli-3")
	if ids := scannedDocIDs(t, stdout2); len(ids) != 0 {
		t.Fatalf("rows = %v, want none — the predicates are ORed, not ANDed", ids)
	}
}

// ---------------------------------------------------------------------------
// Unit-level guards on the parsing surface
// ---------------------------------------------------------------------------

func TestExtractTaskScanFlags(t *testing.T) {
	t.Run("strips every spelling and keeps the rest of the tail", func(t *testing.T) {
		opts, kept, err := extractTaskScanFlags([]string{
			"--limit", "10", "--status=in_progress", "--assignee", "w1", "--claimed-by=w2", "--offset", "5",
		})
		if err != nil {
			t.Fatalf("err = %v", err)
		}
		if opts.status != "in_progress" || opts.assignee != "w1" || opts.claimedBy != "w2" {
			t.Fatalf("opts = %+v", opts)
		}
		if strings.Join(kept, " ") != "--limit 10 --offset 5" {
			t.Fatalf("kept = %v — declared flags must survive for splitArgs", kept)
		}
	})
	t.Run("--claimed-by subsumes the broader --claimed", func(t *testing.T) {
		opts, _, err := extractTaskScanFlags([]string{"--claimed", "--claimed-by", "w"})
		if err != nil {
			t.Fatalf("err = %v", err)
		}
		if opts.claimed {
			t.Fatalf("--claimed survived beside the strictly narrower --claimed-by: %+v", opts)
		}
		if !opts.clientSide() {
			t.Fatalf("collapsing the pair lost the client-side flag: %+v", opts)
		}
	})
	t.Run("the zero scan asks for nothing", func(t *testing.T) {
		opts, kept, err := extractTaskScanFlags([]string{"--limit", "3"})
		if err != nil {
			t.Fatalf("err = %v", err)
		}
		if opts.any() || opts.clientSide() || taskScanRowMatcher(opts) != nil {
			t.Fatalf("an untouched tail produced a narrowing: %+v", opts)
		}
		if taskScanClientSideNotice(opts) != "" {
			t.Fatalf("an untouched tail produced a notice")
		}
		if strings.Join(kept, " ") != "--limit 3" {
			t.Fatalf("kept = %v", kept)
		}
	})
	t.Run("every documented lifecycle value is accepted", func(t *testing.T) {
		for _, s := range taskLifecycleStatuses {
			if err := validateTaskStatus(s); err != nil {
				t.Errorf("validateTaskStatus(%q) = %v", s, err)
			}
		}
	})
}

func TestAppendTaskStatusFilterPreservesExistingQuery(t *testing.T) {
	got, err := appendTaskStatusFilter("http://x/v1/tasks?limit=10&offset=20", "done")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	for _, want := range []string{"limit=10", "offset=20", "filter%5Blifecycle_status%5D=done"} {
		if !strings.Contains(got, want) {
			t.Fatalf("url %q lost %q", got, want)
		}
	}
	// The no-op path returns the URL untouched, byte for byte.
	same, err := appendTaskStatusFilter("http://x/v1/tasks?limit=10", "")
	if err != nil || same != "http://x/v1/tasks?limit=10" {
		t.Fatalf("empty status rewrote the url: %q (%v)", same, err)
	}
}

// A row the walk could not parse is excluded from a FILTERED answer rather than
// waved through: the scan makes an absence claim, and a row we cannot read is
// not one we can vouch for.
func TestTaskScanRowMatcherRejectsUnreadableRows(t *testing.T) {
	m := taskScanRowMatcher(taskScanOpts{claimed: true})
	if m == nil {
		t.Fatal("claimed scan produced no matcher")
	}
	if m(json.RawMessage(`not json`)) {
		t.Error("an unparseable row matched")
	}
	if m(json.RawMessage(`{"doc_id":"x"}`)) {
		t.Error("a row with no claim matched --claimed")
	}
	if m(json.RawMessage(`{"doc_id":"x","claim":{"worker":"  "}}`)) {
		t.Error("a blank claim.worker counted as a live claim")
	}
	if !m(json.RawMessage(`{"doc_id":"x","claim":{"worker":"w"}}`)) {
		t.Error("a claimed row did not match")
	}
}

// The flags are DISCOVERABLE. A flag the manifest cannot declare is a flag
// `--help` cannot list unless usage.go names it, and this whole row was filed
// because two verifiers read `bp task ls --help`, saw limit/offset, and
// concluded the scan was impossible.
func TestTaskLsHelpNamesTheScanFlags(t *testing.T) {
	var cmd manifest.Command
	for _, c := range scanManifest().Commands {
		if c.ID == taskLsCommandID {
			cmd = c
		}
	}
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	usageCommand(out, cmd)
	help := stderr.String()
	for _, want := range []string{"--status", "--claimed", "--claimed-by", "--assignee", "in_progress", "implies --all"} {
		if !strings.Contains(help, want) {
			t.Errorf("`task ls --help` never names %q:\n%s", want, help)
		}
	}
}
