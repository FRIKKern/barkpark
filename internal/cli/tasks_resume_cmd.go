package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// REHYDRATION IS THE READ SIDE OF THE FLIGHT RECORDER (task-b55fafd148bb2578,
// P2 — task-7ac1b27605ef6060).
//
// tasks_priming_manifest.go writes the loadout an agent held when it claimed a
// row. This file reads it back for the SUCCESSOR: `bp task resume <id>
// <worker>` rebuilds what the crashed agent was holding and prints a CRASH
// BRIEF — predecessor identity and epoch, the lease's now-line as the store
// currently holds it, the worktree and HEAD the work was done from, the primer
// documents and their content hashes, and an explicit instruction to REVIEW
// before continuing.
//
// TWO SOURCES, ONE LAW (the server arm, task-7ac1b27605ef6060 c3). The manifest
// lives in two places: `claim.priming_start` on the row (sent by `bp task
// claim`, stored by api/lib/barkpark/tasks/flight_recorder.ex) and the local
// BARKPARK_PRIMING_DIR file. The LEDGER copy is preferred, because it is the
// only one that survives the machine that wrote it — which is the entire case
// this verb exists for: a lease that lapsed on a host the successor has never
// seen. The local file is the fallback. Both are judged by believeManifest,
// the same schema/doc-id/digest arms, so neither wire buys a weaker proof.
//
// `resume` reads the row but is otherwise a READ-ONLY builtin, not a manifest verb: it writes nothing,
// claims nothing, and takes no lease. Taking the row is still `bp task claim`.
//
// ========================= A RESUME PATH IS ALL ABSENCES =====================
//
// The three-state law (internal/agent/site_plane.go, and the writer's own
// header) is not a nicety here — it is the entire contract. A successor asking
// "what was my predecessor holding?" can get three DIFFERENT nothings, and
// collapsing them is how a successor is told it may guess:
//
//	NO RECORD        No manifest file names this row. UNMEASURED. Nothing is
//	                 claimed about the predecessor in either direction — this
//	                 is NOT "the predecessor held nothing".
//
//	UNREADABLE       A manifest file EXISTS and could not be turned into a
//	                 loadout: unreadable, unparseable, an unknown schema, a doc
//	                 id for a different row, or a digest that does not describe
//	                 its own bytes. This is a MEASURED FAILURE — the filesystem
//	                 was asked and answered — and it is the LOUDEST of the
//	                 three, because a record that exists and lies is worse than
//	                 one that was never written. It exits non-zero.
//
//	SILENT           A manifest loaded, re-digested clean, and says nothing:
//	                 every measured field is nil and no primers are listed. The
//	                 record ANSWERED, and its answer is "I did not measure".
//	                 Distinct from NO RECORD, which never answered at all.
//
// The same law governs the live half. If the store could not be read, the
// predecessor's claim is UNMEASURED — the brief says so, and never renders an
// absent claim as "nobody holds this row".
//
// THE FAILURE DIRECTION, stated once: a resume that prints a confident brief
// over a manifest it did not actually read is worse than one that refuses.
// Every arm below is written to fail toward the refusal.

// resumeState is which of the three nothings (or a real loadout) the reader got.
type resumeState int

const (
	// resumeNoRecord — no manifest file names this row. UNMEASURED.
	resumeNoRecord resumeState = iota
	// resumeUnreadable — a file exists and could not be believed. MEASURED failure.
	resumeUnreadable
	// resumeSilent — a manifest loaded and carries no measurement.
	resumeSilent
	// resumeLoaded — a manifest loaded and carries a loadout.
	resumeLoaded
)

func (s resumeState) String() string {
	switch s {
	case resumeNoRecord:
		return "NO RECORD"
	case resumeUnreadable:
		return "UNREADABLE RECORD"
	case resumeSilent:
		return "SILENT RECORD"
	default:
		return "LOADED"
	}
}

// resumeRecord is the outcome of rehydrating one row's loadout.
//
// Source names WHERE the bytes came from, because a successor reading a brief
// on a machine that never ran the claim needs to know whether the loadout was
// rebuilt from the LEDGER (durable, reachable from anywhere) or from a local
// file (exactly as durable as this host). It is prose in the brief, never a
// predicate: no arm below branches on it.
type resumeRecord struct {
	Path     string
	Source   string // "the ledger (claim.priming_start)" / "<path>"
	State    resumeState
	Fault    string // why the record could not be believed (UNREADABLE only)
	Manifest *PrimingManifest
}

// resumeIO is the filesystem the reader is allowed to touch, injected for the
// SAME reason the writer injects its own (see primingIO): the failures this
// reader exists to catch are a read that SUCCEEDS and hands back the wrong
// bytes — truncated, tampered, a different row's manifest, a schema from a
// future build. os cannot be made to do any of that on demand, so without
// injection the rehydration has no arm that reds when it is deleted. That is
// not a hypothetical: it is exactly what PR #19114's first reversion pass
// measured on the WRITE side, where removing the readback left the whole suite
// green. See TestResumeRehydrationRedsWhenRemoved.
type resumeIO struct {
	readFile func(string) ([]byte, error)
}

func osResumeIO() resumeIO { return resumeIO{readFile: os.ReadFile} }

// loadResumeRecord rehydrates the loadout for docID out of dir.
//
// THIS FUNCTION IS THE REHYDRATION. Deleting its verification arms (schema,
// doc-id and digest checks) must red a test, or the brief becomes a confident
// render of bytes nobody checked.
func loadResumeRecord(io resumeIO, dir, docID string) resumeRecord {
	path := primingManifestPath(dir, docID)
	rec := resumeRecord{Path: path, Source: path}

	b, err := io.readFile(path)
	if err != nil {
		// THE ONE SPLIT THAT MAKES THE WHOLE VERB HONEST. "Not there" is
		// UNMEASURED; every other read error is a filesystem that was asked and
		// answered badly, which the successor must be told about.
		if errors.Is(err, fs.ErrNotExist) {
			rec.State = resumeNoRecord
			return rec
		}
		rec.State = resumeUnreadable
		rec.Fault = fmt.Sprintf("the file exists and could not be read: %v", err)
		return rec
	}

	state, fault, m := believeManifest(b, docID)
	rec.State, rec.Fault, rec.Manifest = state, fault, m
	return rec
}

// believeManifest is the ONE set of verification arms that decides whether a
// manifest's bytes may be turned into a loadout. Both readers — the local file
// and the ledger copy — go through it, DELIBERATELY: a server arm with its own
// weaker checks would be a second law for the same record, and the successor
// would have no way to know which one had judged the bytes it is being shown.
// The bytes arrive over a different wire; they do not arrive with a different
// standard of proof.
//
// Returns the state, the fault (UNREADABLE only), and a manifest ONLY when the
// record was believed — never alongside a fault, because handing a caller a
// manifest it may render is exactly how a corrupt record gets believed.
func believeManifest(b []byte, docID string) (resumeState, string, *PrimingManifest) {
	var m PrimingManifest
	if err := json.Unmarshal(b, &m); err != nil {
		return resumeUnreadable, fmt.Sprintf("it does not parse as a priming manifest: %v", err), nil
	}
	// A successor that does not know the schema number must REFUSE to interpret
	// the record, not guess at it — the writer's own instruction.
	if m.Schema != primingSchema {
		return resumeUnreadable, fmt.Sprintf("schema %d, but this build only understands schema %d — refusing to interpret it rather than guess", m.Schema, primingSchema), nil
	}
	// A manifest for a DIFFERENT row is not this row's loadout. Rendering it
	// would hand the successor another agent's primers as its own.
	if m.DocID != docID {
		return resumeUnreadable, fmt.Sprintf("it records doc_id %q, but this resume asked for %q — this is another row's loadout", m.DocID, docID), nil
	}
	// The digest must still describe the bytes that came back. A manifest that
	// says one thing and hashes as another has been truncated or edited since
	// the claim, and nothing in it can be relied on.
	if re := primingDigest(m); re != m.Digest {
		return resumeUnreadable, fmt.Sprintf("it carries digest %q but its own content hashes to %q — truncated or edited since the claim", m.Digest, re), nil
	}
	if manifestIsSilent(m) {
		return resumeSilent, "", &m
	}
	return resumeLoaded, "", &m
}

// manifestIsSilent reports the third nothing: a record that loaded and answers
// UNMEASURED to every question it was built to answer. It is deliberately
// conjunctive — ONE measured field is a partial loadout, which is a real
// (if thin) answer and must render as LOADED, not as silence.
func manifestIsSilent(m PrimingManifest) bool {
	return m.Model == nil && m.Effort == nil && m.Worktree == nil &&
		m.Head == nil && m.DirtyTree == nil && len(m.Primers) == 0
}

// resumeLive is what the STORE currently says about the row, as a three-state
// value in its own right: Read false means the store was not asked or did not
// answer, and NOTHING about the predecessor's claim may be inferred from it.
type resumeLive struct {
	Read      bool
	Fault     string
	Lifecycle string
	Claim     apiclient.ClaimInfo
	// Priming is content.claim.priming_start EXACTLY as the ledger holds it —
	// raw, undecoded, unjudged. Nil means the key was absent from the claim
	// object (or there was no claim object), which is NO RECORD on the server
	// arm; a present-but-corrupt value is UNREADABLE and must reach
	// believeManifest to be told so. Decoding here would collapse the two.
	Priming json.RawMessage
}

// serverPrimingSource names the ledger in the brief. A successor must be able
// to see at a glance that the loadout it is reading survived the machine that
// wrote it.
const serverPrimingSource = "the ledger (claim.priming_start)"

// serverResumeRecord rehydrates the loadout from the LEDGER copy of the
// manifest — the one `bp task claim` sends under `claim.priming_start`
// (api/lib/barkpark/tasks/flight_recorder.ex). This is the arm that makes
// resume work at all for the case the verb exists for: a lease that lapsed on
// a machine the successor has never touched, whose BARKPARK_PRIMING_DIR it
// cannot read and must not pretend to.
//
// THE THREE-ABSENCE LAW HOLDS HERE VERBATIM, and asked=false is a FOURTH thing
// that is not one of the three:
//
//	asked=false   the store was not read at all. NOT "no record on the
//	              server" — an unreachable ledger says NOTHING about whether a
//	              manifest is stored, and reporting it as NO RECORD would be a
//	              statement about the predecessor drawn from a network error.
//	NO RECORD     the row was read and carries no priming_start. UNMEASURED.
//	UNREADABLE    a priming_start EXISTS and cannot be believed. The loudest.
//	SILENT/LOADED believeManifest's own verdicts, unchanged.
func serverResumeRecord(live resumeLive, docID string) (rec resumeRecord, asked bool) {
	rec = resumeRecord{Source: serverPrimingSource}
	if !live.Read {
		return rec, false
	}
	if len(live.Priming) == 0 {
		return rec, true
	}
	state, fault, m := believeManifest(live.Priming, docID)
	rec.State, rec.Fault, rec.Manifest = state, fault, m
	return rec, true
}

// claimPrimingStart pulls content.claim.priming_start out of a read row
// WITHOUT judging it. An absent claim, a null claim, a claim that does not
// decode, and an absent key all yield nil — every one of them is "the ledger
// holds no manifest for this row", which is NO RECORD. A present value is
// handed back raw, including `null` and `{}`, so believeManifest is the only
// thing that ever decides a stored value is unbelievable.
func claimPrimingStart(doc apiclient.Doc) json.RawMessage {
	raw, ok := doc.Extra["claim"]
	if !ok {
		return nil
	}
	var c struct {
		PrimingStart json.RawMessage `json:"priming_start"`
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil
	}
	if len(c.PrimingStart) == 0 || string(c.PrimingStart) == "null" {
		return nil
	}
	return c.PrimingStart
}

// runTaskResume is the builtin entry point: `bp task resume <doc-id> <worker>`.
func runTaskResume(out *writer, g globals, ctx manifest.Context, tail []string) int {
	var pos []string
	for _, a := range tail {
		if strings.HasPrefix(a, "-") {
			continue
		}
		pos = append(pos, strings.TrimSpace(a))
	}
	if len(pos) < 2 || pos[0] == "" || pos[1] == "" {
		out.userErr("usage: barkpark task resume <doc-id> <worker-id>\n  rebuilds the loadout a crashed agent held at claim time and prints a crash brief.\n  prefers the manifest the ledger holds at claim.priming_start, and falls back to the\n  local file `bp task claim` wrote under BARKPARK_PRIMING_DIR; writes nothing and takes no lease.")
		return exitUsage
	}
	docID, worker := pos[0], pos[1]

	live := fetchResumeLive(ctx, docID)
	dir := primingDirPath(defaultPrimingEnv().getenv)

	rec, ok := pickResumeRecord(osResumeIO(), live, dir, docID)
	if !ok {
		// REFUSE RATHER THAN RENDER AN EMPTY BRIEF. Neither place a manifest
		// could be was readable — the ledger did not answer AND this shell has
		// no priming dir — so "no record" would be a statement about the
		// predecessor drawn from a network error and a missing env var.
		out.userErr("Neither source of a loadout could be LOOKED AT for %s:\n  the ledger was not read (%s), and BARKPARK_PRIMING_DIR is unset so there is nowhere local to look.\n  This is NOT evidence that %s has no loadout — it is evidence that this shell cannot look.\n  Fix the server connection, or set BARKPARK_PRIMING_DIR to the directory `bp task claim` wrote to, then re-run.", docID, orNoneStr(live.Fault), docID)
		return exitUsage
	}
	renderCrashBrief(out, docID, worker, rec, live)

	if rec.State == resumeUnreadable {
		// The loudest of the three nothings is the only one that fails the
		// command: a record that exists and cannot be believed must not be
		// walked past with a zero exit.
		return exitGeneric
	}
	return exitOK
}

// pickResumeRecord chooses WHICH manifest the brief is built from.
//
// THE LEDGER WINS WHEN IT HAS ONE. The server copy is the only one that
// survives the machine that wrote it, and it is the copy the successor can
// actually be expected to reach; the local file is the FALLBACK, for the case
// where the claim predates the wire half or the ledger did not answer.
//
// The precedence is on PRESENCE, never on content: a ledger manifest that is
// UNREADABLE still wins over a local file that loads. Falling through to a
// believable local copy on a corrupt server copy would silently swallow the
// loudest of the three nothings — the successor would see a clean brief and
// never learn that the ledger holds a record that lies.
//
// ok=false means NEITHER source could be looked at (store unread AND no
// priming dir). That is not a fourth state of the record; it is the caller's
// signal to refuse instead of printing a brief about a row nobody asked.
func pickResumeRecord(io resumeIO, live resumeLive, dir, docID string) (resumeRecord, bool) {
	srv, asked := serverResumeRecord(live, docID)
	if asked && srv.State != resumeNoRecord {
		return srv, true
	}
	if dir != "" {
		local := loadResumeRecord(io, dir, docID)
		// A local record that says something answers where the ledger had
		// nothing. If it too is NO RECORD, prefer the SERVER's no-record when
		// the store was actually asked — same state, and the source line then
		// names the durable place that was checked.
		if local.State != resumeNoRecord || !asked {
			return local, true
		}
		// BOTH places were looked at and BOTH are empty. Say both, or the
		// brief's "no manifest names this row at the ledger" quietly drops the
		// fact that the local directory was checked too — and a successor
		// deciding whether to go looking on the dead host needs that.
		srv.Source = serverPrimingSource + " — and " + local.Path
		return srv, true
	}
	if asked {
		return srv, true
	}
	return resumeRecord{}, false
}

// fetchResumeLive reads the row back for the live half of the brief. Every
// failure class collapses to Read:false with a fault string — the brief then
// says the claim is UNMEASURED, which is the truth, instead of rendering a
// zero ClaimInfo as "nobody holds it".
func fetchResumeLive(ctx manifest.Context, docID string) resumeLive {
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
		// "drafts" for the same reason diagnoseClaimConflict picks it: a
		// just-moved claim lives in the draft overlay.
		Perspective: "drafts",
	})
	doc, outcome := client.GetPerspectiveResult("task", docID, "drafts")
	if outcome.Failed() {
		return resumeLive{Fault: outcome.Describe()}
	}
	return resumeLive{
		Read:      true,
		Lifecycle: doc.ContentString("lifecycle_status"),
		Claim:     doc.ClaimInfo(),
		Priming:   claimPrimingStart(doc),
	}
}

// renderCrashBrief prints the successor's brief. It is pure rendering over the
// two three-state inputs, so both arms of every state are drivable by a test
// without a filesystem or a network.
func renderCrashBrief(out *writer, docID, worker string, rec resumeRecord, live resumeLive) {
	out.outf("CRASH BRIEF — %s", docID)
	out.outf("successor: %s", worker)
	out.outf("")

	out.outf("LOADOUT: %s", rec.State)
	out.outf("  source: %s", orNoneStr(rec.Source))
	switch rec.State {
	case resumeNoRecord:
		out.outf("  No manifest names this row at %s.", orNoneStr(rec.Source))
		out.outf("  UNMEASURED: this says NOTHING about what your predecessor held. It is not")
		out.outf("  a finding that they held nothing — only that nothing was written down.")
	case resumeUnreadable:
		out.outf("  A manifest EXISTS at %s and cannot be believed:", orNoneStr(rec.Source))
		out.outf("  %s", rec.Fault)
		out.outf("  This is a MEASURED failure, not an absence: something was recorded and it")
		out.outf("  is wrong. Do NOT reconstruct a loadout from it, and do not treat this row")
		out.outf("  as unprimed — find out what corrupted the record first.")
	case resumeSilent:
		out.outf("  A manifest at %s loaded and re-digested clean, and measures NOTHING:", orNoneStr(rec.Source))
		out.outf("  no model, no effort, no worktree, no HEAD, no tree state, no primers.")
		out.outf("  The record answered; its answer is UNMEASURED. That is different from no")
		out.outf("  record at all — the claim DID run this path, and had nothing to report.")
	default:
		renderLoadout(out, *rec.Manifest, rec.Source)
	}
	out.outf("")

	out.outf("PREDECESSOR (live store):")
	if !live.Read {
		out.outf("  UNMEASURED — the store could not be read: %s", orNoneStr(live.Fault))
		out.outf("  No conclusion about who holds this row may be drawn from this line.")
	} else if !live.Claim.Present {
		out.outf("  the row carries NO claim object — nobody has ever claimed it through this store")
		out.outf("  lifecycle_status=%s", orNoneStr(live.Lifecycle))
	} else {
		out.outf("  worker=%s epoch=%d released_at=%s expired_at=%s lifecycle_status=%s",
			orNoneStr(live.Claim.Worker), live.Claim.Epoch,
			orNoneStr(live.Claim.ReleasedAt), orNoneStr(live.Claim.ExpiredAt),
			orNoneStr(live.Lifecycle))
		if live.Claim.Worker != "" && live.Claim.Worker != worker {
			out.outf("  You are NOT the holder. `bp task claim` is what takes the row; this verb took nothing.")
		}
	}
	out.outf("")

	out.outf("BEFORE YOU CONTINUE — REVIEW, DO NOT RESUME BLIND:")
	out.outf("  1. Re-read every primer listed above and confirm its hash still matches;")
	out.outf("     a primer that CHANGED since the claim invalidates the predecessor's plan.")
	out.outf("  2. Inspect the worktree and HEAD above before writing anything — a dirty")
	out.outf("     tree is half-finished work whose intent is not recorded anywhere.")
	out.outf("  3. Read what the predecessor already pushed (branch, PR) before re-doing it.")
	out.outf("  4. Claim the row under YOUR worker id: bp task claim %s %s", docID, worker)
}

// renderLoadout prints a manifest that loaded with content. Tristate fields are
// rendered through tristate()/orUnmeasured() so an UNMEASURED field is visibly
// distinct on the terminal from a measured empty one — the same distinction the
// writer keeps on the wire.
func renderLoadout(out *writer, m PrimingManifest, path string) {
	out.outf("  digest %s (from %s)", shortDigest(m.Digest), path)
	out.outf("  claimed by %s at %s", orNoneStr(m.Worker), orNoneStr(m.ClaimedAt))
	out.outf("  model=%s effort=%s", orUnmeasured(m.Model), orUnmeasured(m.Effort))
	out.outf("  worktree=%s head=%s dirty_tree=%s",
		orUnmeasured(m.Worktree), orUnmeasured(m.Head), tristate(m.DirtyTree))
	out.outf("  primed=%s", tristate(m.Primed))
	if len(m.Primers) == 0 {
		out.outf("  primers: none listed")
		return
	}
	out.outf("  primers (%d):", len(m.Primers))
	for _, p := range m.Primers {
		if p.SHA256 == nil {
			out.outf("    %s — NOT READABLE at claim time: %s", p.Path, orNoneStr(p.Error))
			continue
		}
		out.outf("    %s sha256=%s bytes=%s", p.Path, shortDigest(*p.SHA256), orUnmeasuredInt(p.Bytes))
	}
}

// orUnmeasured renders a *string as UNMEASURED when nil, never as "".
func orUnmeasured(s *string) string {
	if s == nil {
		return "UNMEASURED"
	}
	return *s
}

func orUnmeasuredInt(n *int64) string {
	if n == nil {
		return "UNMEASURED"
	}
	return fmt.Sprintf("%d", *n)
}

func shortDigest(d string) string {
	if len(d) > 12 {
		return d[:12]
	}
	if d == "" {
		return "(none)"
	}
	return d
}
