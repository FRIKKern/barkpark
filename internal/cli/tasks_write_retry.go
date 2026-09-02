package cli

// tasks_write_retry.go — the RETRY half of the ledger-write contract, and the
// one rule that makes retrying a POST safe at all: RE-READ BEFORE EVERY RETRY.
//
// THE FAILURE. Under an agent campaign guerrilla answers a share of every
// authenticated ledger route with a 500 or drops the connection outright
// (task-e2f5ecca0be9a6d1 measured 532 `Sent 500` in one hour, the raising
// frames being the auth plugs queued behind the ledger's own seq scans). The
// read paths already survive that: internal/apiclient/retry.go retries a
// transient `internal_error` — but ONLY a GET, and it says why in its own
// words: "A 500 tells you NOTHING about whether a write landed … a blind retry
// would have filed a duplicate."
//
// So every ledger WRITE — `bp task claim`, `bp task next`, `bp task close`,
// `bp task stamp`, `bp task pulse`, `bp task release` — failed on the first
// 500 and left the agent guessing. Each guess is a distinct, real harm:
//
//	claim   a claim that DID land, re-sent, comes back 409 already_claimed
//	        (the agent concludes it lost a race it actually won) or bumps the
//	        fencing epoch, which invalidates the epoch its own close will echo
//	next    the queue moved a task to in_progress under this worker and the
//	        worker never learned which one — an orphaned in_progress row
//	close   a close that landed, re-sent, fails its CAS (the epoch/rev fence)
//	        and reads as "the close did not land" on a row that IS sealed
//	pulse   a re-sent pulse bumps the claim epoch (memory: "pulse bumps the
//	        claim epoch"), so the close that follows CASes against a stale one
//	stamp   a re-sent stamp re-writes a criterion the store already holds
//
// THE POLICY, in one place. This file is the ONLY retry for ledger writes, and
// it is attached to the request at build time (buildManifestRequest), which is
// the seam BOTH the CLI dispatch (runCommand) and the headless MCP dispatch
// (execManifestCommand / execTaskNextWithPolicy) already share. The MCP tools
// task_claim / task_next / task_close / task_stamp / task_pulse therefore
// inherit it with zero per-tool code — verified by
// TestMCPTaskWritesInheritLedgerRetry.
//
//  1. RETRY only a 5xx, a dropped connection, or a timeout. NEVER a 4xx: a
//     409/422/404 is an ANSWER, and repeating it is noise (the same refusal
//     internal/apiclient/retry.go states for the read path).
//  2. Before EVERY retry, ASK THE STORE whether the write already landed. If
//     it did, return the read-back AS THE SUCCESS and send nothing more. This
//     is the whole point: the harm above is caused by the SECOND POST, not by
//     the first failure.
//  3. When every attempt fails, say how many were made AND what the last
//     read-back saw — landed / not landed / UNKNOWN. "Unknown" is the honest
//     word when the ledger is too sick to read: the box that 500s a write
//     500s the read that would have explained it, and reporting that as "not
//     landed" is exactly the false certainty this file exists to remove.
//
// WHY THE PREDICATES ARE PER-VERB. There is no generic "did it land" — each
// verb writes a different field, and each predicate is written to be
// CONSERVATIVE IN THE SAFE DIRECTION: a false "landed" would silently swallow
// a lost write, so every predicate demands positive evidence of THIS write and
// answers "not landed" on anything short of it. See ledgerLandedVerdict.

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ledgerWriteRetries is how many times a failed ledger write is re-sent AFTER
// the first attempt — so a fully unlucky call makes 4 requests in total. Three
// is what the measured fault rate justifies: at the ~15-30% per-request 500
// rate of the 2026-09-01 campaign hour, four independent attempts leave well
// under 1% residual, and the re-read before each one means the retries cost a
// duplicate write NEVER, only latency.
const ledgerWriteRetries = 3

// ledgerWriteDelays are the waits before retry 1, 2 and 3. Longer than the read
// path's 250ms/1s because the fault they wait out is different: a read retries
// a request that failed on its own, while this one waits for a box whose
// connection pool is queued behind minutes-long scans. Jitter is applied on top
// so a fleet of agents that all failed on the same bad second does not re-send
// in lockstep and reproduce it.
var ledgerWriteDelays = []time.Duration{
	500 * time.Millisecond,
	1500 * time.Millisecond,
	4 * time.Second,
}

// ledgerRetryAfterCap bounds a server-supplied Retry-After. The header is
// HONOURED (a server that names its own recovery window knows better than our
// table), but not without limit — a proxy that says "3600" must not hang an
// interactive `bp task close` for an hour.
const ledgerRetryAfterCap = 30 * time.Second

// ledgerLandedState is the three-valued answer to "did the write we are about
// to re-send already land?". The third value is the one that matters: an
// unreadable ledger is UNKNOWN, never "no".
type ledgerLandedState int

const (
	// ledgerLandedNo — the store was read and does NOT hold the write.
	ledgerLandedNo ledgerLandedState = iota
	// ledgerLandedYes — the store was read and DOES hold the write. Re-sending
	// is the harm; return the read-back as the receipt instead.
	ledgerLandedYes
	// ledgerLandedUnknown — the store could not be asked (the same fault that
	// broke the write can break the read). Never report this as "not landed".
	ledgerLandedUnknown
)

func (s ledgerLandedState) String() string {
	switch s {
	case ledgerLandedYes:
		return "landed"
	case ledgerLandedNo:
		return "not landed"
	default:
		return "unknown"
	}
}

// ledgerLandedVerdict is one read-back's answer. Body is the raw envelope the
// store handed back and is used VERBATIM as the receipt on a landed write:
// GET /v1/tasks/:doc_id and the claim/close/stamp/pulse POSTs all render
// `%{ok: true, doc: Params.render_doc(...)}` (tasks_controller.ex), so the
// happy-path receipt and this one are the same shape — the caller cannot tell
// which request produced it, which is correct, because the STORE is what
// "landed" means.
type ledgerLandedVerdict struct {
	state  ledgerLandedState
	body   []byte
	detail string
}

// ledgerWrite is the retry+re-read policy for ONE ledger write, resolved at
// request-build time and carried on the manifestRequest. Every field that
// touches the clock or the network is injectable so the tests never sleep and
// never open a socket they did not stand up themselves.
type ledgerWrite struct {
	// verb is the bare verb name used in the stderr lines ("claim", "close", …).
	verb string
	// readback asks the STORE whether this write already landed. Never nil for
	// an attached policy — a policy with no read-back would be a blind retry,
	// which is the thing this file exists to forbid.
	readback func() ledgerLandedVerdict
	// send performs one attempt. Injectable so a test drives the schedule
	// without a server.
	send func() (int, []byte, string, http.Header, error)

	retries int
	delays  []time.Duration
	jitter  func(time.Duration) time.Duration
	sleep   func(time.Duration)
	notify  func(string)
}

// ledgerWriteVerbs is the closed set of manifest command ids this policy is
// attached to, keyed by id so a new verb is an explicit decision rather than
// something a prefix match sweeps in. Every one of them is a POST that MUTATES
// A CLAIM OR A SEAL — the writes whose re-send is destructive. `task.move`,
// `task.stage` and `task.labels` are deliberately absent: they are last-writer-
// wins field updates whose re-send is harmless, so they would gain latency and
// a read-back for nothing.
var ledgerWriteVerbs = map[string]string{
	"task.claim":   "claim",
	"task.next":    "next",
	"task.close":   "close",
	"task.stamp":   "stamp",
	"task.pulse":   "pulse",
	"task.release": "release",
}

// ledgerWriteFor builds the policy for cmd, or returns nil when cmd is not a
// ledger write (the overwhelming majority of commands, which then take the
// untouched single-shot send).
//
// It is called from buildManifestRequest with the SAME argMap and flags the
// request body was built from, so the row the read-back targets can never drift
// from the row the POST carried — the discipline claimRequestOf/closeRequestOf/
// stampRequestOf each enforce for their own read-backs.
func ledgerWriteFor(ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, argMap map[string]string, flags map[string][]string, headers map[string]string) *ledgerWrite {
	verb, ok := ledgerWriteVerbs[cmd.ID]
	if !ok {
		return nil
	}
	worker := strings.TrimSpace(argMap["worker_id"])
	if worker == "" {
		// Every one of these verbs takes a worker id, and every predicate is
		// anchored on it ("is it MY write that landed?"). Without one there is
		// nothing to confirm, so decline the policy rather than retry blind.
		return nil
	}

	// The read-back rides the auth headers the WRITE resolved (same token, same
	// tier) minus the body content type — a GET carries no body.
	readHeaders := map[string]string{}
	for k, v := range headers {
		if strings.EqualFold(k, "Content-Type") {
			continue
		}
		readHeaders[k] = v
	}

	lw := &ledgerWrite{verb: verb}

	if cmd.ID == "task.next" {
		// THE QUEUE CLAIM NAMES NO ROW. POST /v1/tasks/claim picks the task, so
		// on a failure there is no doc id to re-read — the CLI does not know
		// what it might have claimed. The read-back is therefore the worker's
		// own live claims (GET /v1/tasks/prime?worker=…), and the predicate is
		// a CLOCK one: a claim taken at or after this command started can only
		// be this command's (a worker id names one agent; an agent racing its
		// own `bp task next` is racing itself).
		url, ok := ledgerPrimeURL(m, ctx, worker)
		if !ok {
			return nil
		}
		started := time.Now().UTC()
		lw.readback = func() ledgerLandedVerdict {
			return ledgerQueueClaimLanded(url, readHeaders, worker, started)
		}
		return lw
	}

	docID := strings.TrimSpace(argMap["doc_id"])
	if docID == "" {
		return nil
	}
	url, ok := ledgerTaskGetURL(m, ctx, docID)
	if !ok {
		return nil
	}

	last := func(name string) string {
		v := flags[name]
		if len(v) == 0 {
			return ""
		}
		return v[len(v)-1]
	}

	switch cmd.ID {
	case "task.claim":
		lw.readback = func() ledgerLandedVerdict {
			return ledgerReadAnd(url, readHeaders, func(row ledgerDocRow, raw []byte) ledgerLandedVerdict {
				return claimLanded(row, raw, worker)
			})
		}
	case "task.close":
		// The manifest documents lifecycle_status as "defaults to done when
		// omitted" — mirror that default, or an omitted status would make the
		// predicate unfalsifiable (closeRequestOf does the same).
		seal := strings.TrimSpace(argMap["lifecycle_status"])
		if seal == "" {
			seal = "done"
		}
		lw.readback = func() ledgerLandedVerdict {
			return ledgerReadAnd(url, readHeaders, func(row ledgerDocRow, raw []byte) ledgerLandedVerdict {
				return closeLanded(row, raw, worker, seal)
			})
		}
	case "task.release":
		lw.readback = func() ledgerLandedVerdict {
			return ledgerReadAnd(url, readHeaders, func(row ledgerDocRow, raw []byte) ledgerLandedVerdict {
				return releaseLanded(row, raw, worker)
			})
		}
	case "task.pulse":
		nowLine := last("now")
		if strings.TrimSpace(nowLine) == "" {
			return nil
		}
		lw.readback = func() ledgerLandedVerdict {
			return ledgerReadAnd(url, readHeaders, func(row ledgerDocRow, raw []byte) ledgerLandedVerdict {
				return pulseLanded(row, raw, worker, nowLine)
			})
		}
	case "task.stamp":
		idx, err := strconv.Atoi(strings.TrimSpace(last("criterion")))
		if err != nil || idx < 0 {
			return nil
		}
		req := stampRequest{
			docID:    docID,
			index:    idx,
			text:     last("criterion-text"),
			met:      last("met") == "true",
			evidence: last("evidence"),
			miss:     last("miss") == "true",
			note:     last("note"),
		}
		lw.readback = func() ledgerLandedVerdict {
			return ledgerReadAnd(url, readHeaders, func(row ledgerDocRow, raw []byte) ledgerLandedVerdict {
				return stampLanded(row, raw, req)
			})
		}
	default:
		return nil
	}
	return lw
}

// ── the loop ────────────────────────────────────────────────────────────────

// sendLedgerWrite is the retrying send. It is called from sendManifestRequest
// for exactly the requests that carry a policy; everything else keeps the
// single-shot path byte-for-byte.
func sendLedgerWrite(req *manifestRequest) (int, []byte, string, error) {
	lw := req.ledger
	send := lw.send
	if send == nil {
		send = func() (int, []byte, string, http.Header, error) {
			return doRequestFull(req.method, req.url, req.headers, req.body)
		}
	}

	retries := lw.retries
	if retries <= 0 {
		retries = ledgerWriteRetries
	}

	// Starts UNKNOWN and stays UNKNOWN unless a read-back actually answers:
	// "we never got to ask" and "we asked and could not read" are the same
	// honest word to the caller.
	last := ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the store was not read"}

	var (
		status int
		body   []byte
		ct     string
		err    error
	)
	for attempt := 1; ; attempt++ {
		var hdr http.Header
		status, body, ct, hdr, err = send()
		if !ledgerFaultIsTransient(status, err) {
			// A 2xx, or a 4xx refusal — an ANSWER either way. Hand it back
			// untouched; this policy never inspects a response it did not
			// retry (the read path's rule, for the same reason).
			return status, body, ct, err
		}
		if attempt > retries {
			break
		}

		// THE RE-READ, BEFORE the retry and not after it. Everything this file
		// is for happens on this line.
		last = lw.readback()
		if last.state == ledgerLandedYes {
			lw.emit(fmt.Sprintf("ledger %s on %s — but the store ALREADY HOLDS the write (%s); not re-sending, the read-back is the receipt",
				ledgerFaultLabel(status, err), lw.verb, last.detail))
			return http.StatusOK, last.body, "application/json", nil
		}

		delay := lw.delayFor(attempt, hdr)
		lw.emit(fmt.Sprintf("ledger %s on %s, retrying %d/%d in %s (read-back: %s)",
			ledgerFaultLabel(status, err), lw.verb, attempt, retries, ledgerRoundDelay(delay), last.describe()))
		lw.nap(delay)
	}

	attempts := retries + 1
	lw.emit(fmt.Sprintf("ledger %s on %s after %d attempts — the last read-back says the write is %s; %s",
		ledgerFaultLabel(status, err), lw.verb, attempts, last.state, ledgerAdviceFor(last.state, lw.verb)))
	if err != nil {
		return status, body, ct, fmt.Errorf("ledger %s failed after %d attempts (last read-back: %s): %w",
			lw.verb, attempts, last.state, err)
	}
	return status, body, ct, nil
}

// ledgerAdviceFor is the one line that tells the caller what to DO, and it
// never says "it did not land" when the store could not be read.
func ledgerAdviceFor(state ledgerLandedState, verb string) string {
	switch state {
	case ledgerLandedNo:
		return "the store was readable and does not hold it, so re-running the " + verb + " is safe"
	default:
		return "the ledger could not be read either, so whether the " + verb +
			" landed is UNKNOWN — re-read with `bp task get <id>` before re-sending, never assume it was lost"
	}
}

func (v ledgerLandedVerdict) describe() string {
	if v.detail == "" {
		return v.state.String()
	}
	return v.state.String() + ", " + v.detail
}

// delayFor picks the wait before the next attempt: the server's Retry-After
// when it named one (capped), else the table entry with jitter.
func (lw *ledgerWrite) delayFor(attempt int, hdr http.Header) time.Duration {
	if d, ok := ledgerRetryAfter(hdr); ok {
		return d
	}
	delays := lw.delays
	if delays == nil {
		delays = ledgerWriteDelays
	}
	if len(delays) == 0 {
		return 0
	}
	base := delays[len(delays)-1]
	if attempt-1 < len(delays) {
		base = delays[attempt-1]
	}
	if lw.jitter != nil {
		return lw.jitter(base)
	}
	return ledgerJitter(base)
}

// ledgerJitter spreads a delay by ±15%. A fleet of agents that all failed on
// the same bad second must not re-send on the same next second.
func ledgerJitter(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	spread := float64(d) * 0.15
	return time.Duration(float64(d) + (rand.Float64()*2-1)*spread)
}

func ledgerRoundDelay(d time.Duration) time.Duration {
	if d >= time.Second {
		return d.Round(100 * time.Millisecond)
	}
	return d.Round(10 * time.Millisecond)
}

// ledgerSleep is the process-wide wait between ledger-write retries. A var so a
// suite driving the whole dispatch (the Execute-level tests) does not spend the
// real schedule; a unit test that wants to ASSERT the schedule injects
// ledgerWrite.sleep instead and records what it was asked to wait.
var ledgerSleep = time.Sleep

func (lw *ledgerWrite) nap(d time.Duration) {
	if d <= 0 {
		return
	}
	if lw.sleep != nil {
		lw.sleep(d)
		return
	}
	ledgerSleep(d)
}

// emit prints ONE line to stderr. stderr, never stdout, so `-o json` keeps a
// single parseable document — the same channel discipline emitHelpHints and the
// read path's stderrRetryNotifier use. BARKPARK_QUIET_RETRIES silences the
// line for a caller that has opted out of the noise; it never silences the
// re-read, which is behaviour and not a message.
func (lw *ledgerWrite) emit(line string) {
	if lw.notify != nil {
		lw.notify(line)
		return
	}
	if os.Getenv("BARKPARK_QUIET_RETRIES") != "" {
		return
	}
	fmt.Fprintln(os.Stderr, line)
}

// ledgerFaultIsTransient is the ONE classification: retry a 5xx, a dropped
// connection or a timeout, and NOTHING else. A 4xx is a refusal — an answer —
// and a 2xx is the result. status 0 with an error is the transport failing
// before any response existed (the connection drop / timeout class); a non-zero
// status WITH an error is a body that failed to read after the server answered,
// which is a client-side cap and not a server fault, so it is handed back.
func ledgerFaultIsTransient(status int, err error) bool {
	if status == 0 && err != nil {
		return true
	}
	return status >= 500 && status <= 599
}

func ledgerFaultLabel(status int, err error) string {
	if status == 0 && err != nil {
		return "connection error"
	}
	return strconv.Itoa(status)
}

// ledgerRetryAfter reads a Retry-After header in either legal spelling —
// delay-seconds or an HTTP-date — and caps it. A header we cannot parse is no
// header at all.
func ledgerRetryAfter(hdr http.Header) (time.Duration, bool) {
	if hdr == nil {
		return 0, false
	}
	raw := strings.TrimSpace(hdr.Get("Retry-After"))
	if raw == "" {
		return 0, false
	}
	if secs, err := strconv.Atoi(raw); err == nil {
		if secs < 0 {
			return 0, false
		}
		return ledgerCapDelay(time.Duration(secs) * time.Second), true
	}
	if t, err := http.ParseTime(raw); err == nil {
		d := time.Until(t)
		if d <= 0 {
			return 0, true
		}
		return ledgerCapDelay(d), true
	}
	return 0, false
}

func ledgerCapDelay(d time.Duration) time.Duration {
	if d > ledgerRetryAfterCap {
		return ledgerRetryAfterCap
	}
	return d
}

// ── the read-back ───────────────────────────────────────────────────────────

// ledgerDocRow is the SHAPE OF A READ-BACK, decoded only as far as the landed
// predicates need. It is deliberately narrower than what internal/taskboard
// decodes for the receipts (SealRow / PulseRow / CriterionItem) and does not
// replace it: taskboard still owns the shapes the RECEIPTS speak from, with
// their full server-matching tolerance contract. This decode answers exactly
// one question — "may I re-send?" — and it answers "no, do not re-send" (i.e.
// landed) only on unambiguous positive evidence.
type ledgerDocRow struct {
	OK  bool `json:"ok"`
	Doc struct {
		DocID           string          `json:"doc_id"`
		Status          string          `json:"status"`
		LifecycleStatus string          `json:"lifecycle_status"`
		Claim           *ledgerClaim    `json:"claim"`
		Content         json.RawMessage `json:"content"`
	} `json:"doc"`
}

type ledgerClaim struct {
	Worker     string          `json:"worker"`
	Epoch      int             `json:"epoch"`
	TSISO      string          `json:"ts_iso"`
	ClosedAt   string          `json:"closed_at"`
	ClosedBy   string          `json:"closed_by"`
	ReleasedAt string          `json:"released_at"`
	ExpiredAt  string          `json:"expired_at"`
	Now        *ledgerPulseNow `json:"now"`
}

type ledgerPulseNow struct {
	Text string `json:"text"`
}

// live reports whether this claim is a HELD lease — not closed out, not
// released, not expired.
func (c *ledgerClaim) live() bool {
	if c == nil || strings.TrimSpace(c.Worker) == "" {
		return false
	}
	return strings.TrimSpace(c.ClosedAt) == "" &&
		strings.TrimSpace(c.ReleasedAt) == "" &&
		strings.TrimSpace(c.ExpiredAt) == ""
}

// ledgerReadAnd performs the GET and hands the decoded row to a predicate. Every
// failure on the way — transport, non-200, unparseable body, ok:false — is
// UNKNOWN, never "not landed": the box that 500s the write is the same box
// answering this read.
func ledgerReadAnd(url string, headers map[string]string, decide func(ledgerDocRow, []byte) ledgerLandedVerdict) ledgerLandedVerdict {
	status, raw, _, _, err := doRequestFull(http.MethodGet, url, headers, nil)
	if err != nil {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the read-back failed: " + err.Error()}
	}
	if status != http.StatusOK {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: fmt.Sprintf("the read-back answered HTTP %d", status)}
	}
	var row ledgerDocRow
	if json.Unmarshal(raw, &row) != nil {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the read-back body did not parse as a task envelope"}
	}
	if !row.OK {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the read-back envelope said ok:false"}
	}
	return decide(row, raw)
}

// ledgerTaskGetURL resolves GET /v1/tasks/:doc_id through the MANIFEST — never
// by string surgery on the write's own URL — so the read-back follows the same
// route table (and the same scoped prefix) the server declared.
func ledgerTaskGetURL(m *manifest.Manifest, ctx manifest.Context, docID string) (string, bool) {
	if m == nil {
		return "", false
	}
	get, ok := m.Tree().Lookup("task", "get")
	if !ok {
		return "", false
	}
	url, err := m.BuildURL(*get, ctx, map[string]string{"doc_id": docID})
	if err != nil {
		return "", false
	}
	return url, true
}

// ledgerPrimeURL resolves GET /v1/tasks/prime?worker=…&limit=1 — the queue
// claim's only possible read-back. limit=1 is not decoration: prime also runs
// the ready-queue CTE, which is the very scan that produces the 500s this file
// retries (task-e2f5ecca0be9a6d1), so the read-back asks for the smallest
// ready head the endpoint will serve.
func ledgerPrimeURL(m *manifest.Manifest, ctx manifest.Context, worker string) (string, bool) {
	if m == nil {
		return "", false
	}
	prime, ok := m.Tree().Lookup("task", "prime")
	if !ok {
		return "", false
	}
	url, err := m.BuildURL(*prime, ctx, map[string]string{})
	if err != nil {
		return "", false
	}
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}
	return url + sep + "worker=" + neturl.QueryEscape(worker) + "&limit=1", true
}

// ── the per-verb landed predicates ──────────────────────────────────────────

// claimLanded — the claim landed iff the store shows a LIVE claim held by US
// with a positive fencing epoch.
//
// The epoch is required, not decoration: TaskClaimN already treats a won claim
// with no positive epoch as a hard failure ("proceeding with epoch 0 defeats
// the CAS fencing"), so a row that names us without one is not a claim we can
// close against and must not be reported as success.
//
// A claim this worker ALREADY held before the command (a live lease from an
// earlier session) also reads as landed, and that is correct rather than
// convenient: `bp task claim` on a row you already hold is the sanctioned
// renew, the server would have accepted it, and RE-SENDING is the harm — it
// bumps the epoch that the caller's own close will echo.
func claimLanded(row ledgerDocRow, raw []byte, worker string) ledgerLandedVerdict {
	c := row.Doc.Claim
	if !c.live() {
		return ledgerLandedVerdict{state: ledgerLandedNo, detail: "the store holds no live claim on that row"}
	}
	if !strings.EqualFold(strings.TrimSpace(c.Worker), worker) {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: fmt.Sprintf("the live claim is held by %s, not %s", c.Worker, worker)}
	}
	if c.Epoch <= 0 {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: "the row names us but carries no fencing epoch, which is not a claim that can be closed against"}
	}
	return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
		detail: fmt.Sprintf("claim held by %s at epoch %d", c.Worker, c.Epoch)}
}

// closeLanded — the close landed iff the store holds the REQUESTED seal AND the
// claim carries a close-out stamp.
//
// THE STILL-HELD TEST KEYS ON closed_at, NOT ON claim.worker
// (task-735080f28a2bfecd, fixed by #14819). The server KEEPS the claim map on a
// successful close and stamps closed_by + closed_at onto it in the same atomic
// write, deliberately, so a sealed row still says who did the work. Reading a
// named worker as "still held" is what made every successful close print
// "half-landed" — and here it would be worse than a wrong message: it would
// report a landed close as unlanded and re-send it into a CAS failure.
func closeLanded(row ledgerDocRow, raw []byte, worker, wantSeal string) ledgerLandedVerdict {
	seal := strings.TrimSpace(row.Doc.LifecycleStatus)
	if seal == "" {
		return ledgerLandedVerdict{state: ledgerLandedUnknown,
			detail: "the read-back carried no lifecycle_status, so the seal could not be confirmed either way"}
	}
	if seal != wantSeal {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: fmt.Sprintf("lifecycle_status is %q, not the %q that was asked for", seal, wantSeal)}
	}
	c := row.Doc.Claim
	if c == nil || strings.TrimSpace(c.Worker) == "" {
		// Sealed with no claim at all: nothing left to settle, and nothing a
		// re-send could add.
		return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
			detail: fmt.Sprintf("lifecycle_status=%s with no claim standing", seal)}
	}
	if closedBy := strings.TrimSpace(c.ClosedBy); closedBy != "" && worker != "" && !strings.EqualFold(closedBy, worker) {
		// A close-out stamp naming somebody ELSE settles nothing about ours.
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: fmt.Sprintf("the row is sealed but closed_by names %s, not %s", closedBy, worker)}
	}
	if strings.TrimSpace(c.ClosedAt) == "" && strings.TrimSpace(c.ClosedBy) == "" {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: "the row is sealed but the claim carries no close-out stamp — the close half-landed"}
	}
	return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
		detail: fmt.Sprintf("lifecycle_status=%s, claim closed out at %s", seal, orNoneStr(c.ClosedAt))}
}

// releaseLanded — the release landed iff the lease is no longer held: the claim
// is gone, or it carries released_at (or a close-out, which also ends it).
func releaseLanded(row ledgerDocRow, raw []byte, worker string) ledgerLandedVerdict {
	c := row.Doc.Claim
	if c == nil || strings.TrimSpace(c.Worker) == "" {
		return ledgerLandedVerdict{state: ledgerLandedYes, body: raw, detail: "the store holds no claim on that row"}
	}
	if !strings.EqualFold(strings.TrimSpace(c.Worker), worker) {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: fmt.Sprintf("the claim is held by %s, not %s — this release has nothing of ours to end", c.Worker, worker)}
	}
	if !c.live() {
		return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
			detail: "the lease is no longer live (released/expired/closed)"}
	}
	return ledgerLandedVerdict{state: ledgerLandedNo, detail: "the lease is still live"}
}

// pulseLanded — the pulse landed iff the store's now-line IS the line we sent,
// on a claim held by us. Compared trimmed, exactly as pulseMismatches compares
// it for the receipt, so the retry and the receipt can never disagree about the
// same two strings.
//
// Note what this deliberately does NOT check: the epoch. A pulse BUMPS the
// claim epoch (that is the lease renewal), so there is no before-value to
// compare — the now-line is the only field that identifies THIS pulse, and it
// is also the field a re-send would cost an epoch to rewrite identically.
func pulseLanded(row ledgerDocRow, raw []byte, worker, wantNow string) ledgerLandedVerdict {
	c := row.Doc.Claim
	if c == nil || c.Now == nil {
		return ledgerLandedVerdict{state: ledgerLandedNo, detail: "the store holds no now-line on that claim"}
	}
	if w := strings.TrimSpace(c.Worker); w != "" && !strings.EqualFold(w, worker) {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: fmt.Sprintf("the claim is held by %s, not %s", w, worker)}
	}
	if strings.TrimSpace(c.Now.Text) != strings.TrimSpace(wantNow) {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: fmt.Sprintf("the stored now-line is a different line (%d bytes stored vs %d sent)",
				len(c.Now.Text), len(wantNow))}
	}
	return ledgerLandedVerdict{state: ledgerLandedYes, body: raw, detail: "the store holds this exact now-line"}
}

// stampLanded — the stamp landed iff the criterion at the requested index shows
// what was asked for.
//
// THE EVIDENCE TEST IS PRESENCE, NOT BYTE-EQUALITY, and that is a deliberate
// divergence from stampMismatches (which the RECEIPT still uses, unchanged).
// task-22bc2e2578ef1222 is open on exactly this: evidence containing the
// literal `%{` came back from the store differing from what was sent, twice,
// with the hypothesis (mangled text vs a rev race) not yet settled. For a
// receipt, flagging that difference is right — it is the finding. For a RETRY
// predicate it is the wrong test in the dangerous direction: it would call a
// landed stamp "not landed" and RE-SEND it, turning an open read-back question
// into a duplicate write. The off-by-one guard is kept instead, and it is the
// stronger one anyway: --criterion-text must match the row at that index, which
// is the same identity check the server's own 409 criteria_mismatch enforces.
func stampLanded(row ledgerDocRow, raw []byte, req stampRequest) ledgerLandedVerdict {
	items := ledgerCriteriaOf(row.Doc.Content)
	if req.index >= len(items) {
		return ledgerLandedVerdict{state: ledgerLandedUnknown,
			detail: fmt.Sprintf("the store holds %d criteria — index %d does not exist", len(items), req.index)}
	}
	it := items[req.index]
	if want := strings.TrimSpace(req.text); want != "" && want != strings.TrimSpace(it.Criterion) {
		return ledgerLandedVerdict{state: ledgerLandedNo,
			detail: "the row at that index is a DIFFERENT criterion than --criterion-text named"}
	}
	if req.met {
		if !it.Met {
			return ledgerLandedVerdict{state: ledgerLandedNo, detail: "met is still false in the store"}
		}
		if strings.TrimSpace(it.Evidence) == "" {
			return ledgerLandedVerdict{state: ledgerLandedNo, detail: "the store holds met with no evidence"}
		}
		return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
			detail: fmt.Sprintf("criterion %d is met with %d bytes of evidence", req.index, len(it.Evidence))}
	}
	if req.miss {
		note := strings.TrimSpace(req.note)
		if note == "" {
			return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the miss carried no note to look for"}
		}
		for _, a := range it.Attempts {
			if strings.TrimSpace(a.Note) == note {
				return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
					detail: fmt.Sprintf("criterion %d carries this attempt note", req.index)}
			}
		}
		return ledgerLandedVerdict{state: ledgerLandedNo, detail: "the store carries no attempt with that note"}
	}
	return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the stamp asked for neither --met nor --miss"}
}

// ledgerCriterionRow is the narrow criterion shape the stamp predicate reads.
type ledgerCriterionRow struct {
	Criterion string `json:"criterion"`
	Met       bool   `json:"met"`
	Evidence  string `json:"evidence"`
	Attempts  []struct {
		Note string `json:"note"`
	} `json:"attempts"`
}

// ledgerCriteriaOf reads content.acceptance_criteria. The criteria live under
// `content`, NOT at the top level of the doc — a reader that walks the top
// level finds nothing and reports every stamp as lost.
func ledgerCriteriaOf(content json.RawMessage) []ledgerCriterionRow {
	if len(content) == 0 {
		return nil
	}
	var c struct {
		AcceptanceCriteria []ledgerCriterionRow `json:"acceptance_criteria"`
	}
	if json.Unmarshal(content, &c) != nil {
		return nil
	}
	return c.AcceptanceCriteria
}

// ── the queue claim's read-back ─────────────────────────────────────────────

// ledgerPrimeRow is GET /v1/tasks/prime narrowed to what the queue-claim
// predicate needs: the worker's live claims.
type ledgerPrimeRow struct {
	OK         bool `json:"ok"`
	InProgress []struct {
		DocID string       `json:"doc_id"`
		Claim *ledgerClaim `json:"claim"`
	} `json:"in_progress"`
}

// ledgerQueueClaimSkew is how far BEFORE the command's start a claim timestamp
// may sit and still count as this command's. It absorbs clock skew between this
// machine and the box — nothing more; it is deliberately far smaller than the
// gap between two `bp task next` invocations by the same worker.
const ledgerQueueClaimSkew = 5 * time.Second

// ledgerQueueClaimLanded is the queue claim's predicate. POST /v1/tasks/claim
// names no row, so "did it land?" becomes "does this worker now hold a claim
// this command could have taken?" — answered by the claim's OWN timestamp, the
// server's record of when the lease began, against the moment this command
// started.
//
// It is conservative in the safe direction twice over: a claim older than our
// start is somebody else's business (a lease this agent was already holding),
// and an unreadable prime is UNKNOWN, so a queue claim is re-sent only when the
// store positively shows no fresh claim.
func ledgerQueueClaimLanded(url string, headers map[string]string, worker string, started time.Time) ledgerLandedVerdict {
	status, raw, _, _, err := doRequestFull(http.MethodGet, url, headers, nil)
	if err != nil {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the prime read-back failed: " + err.Error()}
	}
	if status != http.StatusOK {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: fmt.Sprintf("the prime read-back answered HTTP %d", status)}
	}
	var prime ledgerPrimeRow
	if json.Unmarshal(raw, &prime) != nil || !prime.OK {
		return ledgerLandedVerdict{state: ledgerLandedUnknown, detail: "the prime read-back did not parse as a prime envelope"}
	}
	floor := started.Add(-ledgerQueueClaimSkew)
	for _, row := range prime.InProgress {
		c := row.Claim
		if !c.live() || !strings.EqualFold(strings.TrimSpace(c.Worker), worker) {
			continue
		}
		ts, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(c.TSISO))
		if err != nil || ts.Before(floor) {
			continue
		}
		return ledgerLandedVerdict{state: ledgerLandedYes, body: raw,
			detail: fmt.Sprintf("the queue already claimed %s for %s at %s", row.DocID, worker, c.TSISO)}
	}
	return ledgerLandedVerdict{state: ledgerLandedNo,
		detail: fmt.Sprintf("%s holds no claim taken since this command started", worker)}
}
