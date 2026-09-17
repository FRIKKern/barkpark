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
// `resume` is a purely LOCAL builtin, not a manifest verb: it writes nothing,
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
type resumeRecord struct {
	Path     string
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
	rec := resumeRecord{Path: path}

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

	var m PrimingManifest
	if err := json.Unmarshal(b, &m); err != nil {
		rec.State = resumeUnreadable
		rec.Fault = fmt.Sprintf("the file does not parse as a priming manifest: %v", err)
		return rec
	}
	// A successor that does not know the schema number must REFUSE to interpret
	// the file, not guess at it — the writer's own instruction.
	if m.Schema != primingSchema {
		rec.State = resumeUnreadable
		rec.Fault = fmt.Sprintf("schema %d, but this build only understands schema %d — refusing to interpret it rather than guess", m.Schema, primingSchema)
		return rec
	}
	// A manifest for a DIFFERENT row is not this row's loadout. Rendering it
	// would hand the successor another agent's primers as its own.
	if m.DocID != docID {
		rec.State = resumeUnreadable
		rec.Fault = fmt.Sprintf("it records doc_id %q, but this resume asked for %q — this is another row's loadout", m.DocID, docID)
		return rec
	}
	// The digest must still describe the bytes that came back. A manifest that
	// says one thing and hashes as another has been truncated or edited since
	// the claim, and nothing in it can be relied on.
	if re := primingDigest(m); re != m.Digest {
		rec.State = resumeUnreadable
		rec.Fault = fmt.Sprintf("it carries digest %q but its own content hashes to %q — truncated or edited since the claim", m.Digest, re)
		return rec
	}

	rec.Manifest = &m
	if manifestIsSilent(m) {
		rec.State = resumeSilent
		return rec
	}
	rec.State = resumeLoaded
	return rec
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
		out.userErr("usage: barkpark task resume <doc-id> <worker-id>\n  rebuilds the loadout a crashed agent held at claim time and prints a crash brief.\n  reads the manifest `bp task claim` wrote under BARKPARK_PRIMING_DIR; writes nothing and takes no lease.")
		return exitUsage
	}
	docID, worker := pos[0], pos[1]

	dir := primingDirPath(defaultPrimingEnv().getenv)
	if dir == "" {
		// REFUSE RATHER THAN RENDER AN EMPTY BRIEF. With no priming dir there is
		// no place a manifest could ever have been, so "no record" here would be
		// a statement about the predecessor drawn from a missing configuration.
		out.userErr("BARKPARK_PRIMING_DIR is unset, so there is nowhere a loadout could have been recorded.\n  This is NOT evidence that %s has no loadout — it is evidence that this shell cannot look.\n  Set BARKPARK_PRIMING_DIR to the directory `bp task claim` wrote to, then re-run.", docID)
		return exitUsage
	}

	rec := loadResumeRecord(osResumeIO(), dir, docID)
	live := fetchResumeLive(ctx, docID)
	renderCrashBrief(out, docID, worker, rec, live)

	if rec.State == resumeUnreadable {
		// The loudest of the three nothings is the only one that fails the
		// command: a record that exists and cannot be believed must not be
		// walked past with a zero exit.
		return exitGeneric
	}
	return exitOK
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
	switch rec.State {
	case resumeNoRecord:
		out.outf("  No manifest names this row at %s.", rec.Path)
		out.outf("  UNMEASURED: this says NOTHING about what your predecessor held. It is not")
		out.outf("  a finding that they held nothing — only that nothing was written down.")
	case resumeUnreadable:
		out.outf("  A manifest EXISTS at %s and cannot be believed:", rec.Path)
		out.outf("  %s", rec.Fault)
		out.outf("  This is a MEASURED failure, not an absence: something was recorded and it")
		out.outf("  is wrong. Do NOT reconstruct a loadout from it, and do not treat this row")
		out.outf("  as unprimed — find out what corrupted the record first.")
	case resumeSilent:
		out.outf("  A manifest at %s loaded and re-digested clean, and measures NOTHING:", rec.Path)
		out.outf("  no model, no effort, no worktree, no HEAD, no tree state, no primers.")
		out.outf("  The record answered; its answer is UNMEASURED. That is different from no")
		out.outf("  record at all — the claim DID run this path, and had nothing to report.")
	default:
		renderLoadout(out, *rec.Manifest, rec.Path)
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
	out.outf("  from %s (digest %s)", path, shortDigest(m.Digest))
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
