package cli

// tasks_flight_recorder.go — THE WIRE HALF of the priming manifest and the
// close-time context compact (task-a42dccec2fe4a406, epic task-b55fafd148bb2578).
//
// PR #19114 gave `bp task claim` a LOCAL record of what the agent was holding
// when it took a row: `tasks_priming_manifest.go`, schema=1, opt-in via
// BARKPARK_PRIMING_DIR, readback-proven. That record is exactly as durable as
// the machine it ran on — a lapsed lease picked up from anywhere else still
// finds nothing. This file sends the SAME manifest to the ledger, and sends the
// compact of what the lease learned when it closes.
//
// ============================ NO SECOND SCHEMA ==============================
//
// The bytes on the wire are `json.Marshal` of the very PrimingManifest value
// that is later written to disk — ONE build, not two. Two calls to
// buildPrimingManifest differ in ClaimedAt and therefore in Digest, so a second
// build would put a different record on the ledger than in the directory, which
// is precisely the drift a flight recorder exists to rule out. The manifest is
// built once, before the POST, and the SAME value is persisted after it.
//
// ========================= WHY `--set`, NOT A NEW FLAG ======================
//
// Both verbs already declare `--set key=value` (key:=json for typed) as their
// body escape hatch, and the server reads `priming_start` / `context_compact`
// off the merged params exactly as it reads `criteria_unstated_override`. So the
// wire needs no new manifest flag, and — this is the load-bearing part — the
// wire half works against a server whose cached manifest predates it, instead of
// failing splitArgs with "unknown flag" on every claim the moment
// BARKPARK_PRIMING_DIR is set.
//
// `--context-compact <file>` IS a new flag, but a CLIENT-SIDE one in the shape
// tasks_stamp_cmd.go's `--expect` already established: consumed here, never
// forwarded, so no server declares it and no old server chokes on it. Its value
// is a PATH because a compact is prose — up to 16 KB of it — and prose does not
// belong on a command line.
//
// ============================== THREE STATES ================================
//
// Absent stays ABSENT. No priming dir → no `priming_start` on the wire, at all:
// not an empty object, not a null. No `--context-compact` → no `context_compact`
// key. The server's control for this feature is that such a claim is
// byte-identical to one issued before any of this existed, and a client that
// sent `{}` would break it from this side.

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// flightRecorderMaxBytes mirrors Barkpark.Tasks.FlightRecorder.max_bytes/0.
// Duplicated deliberately and named so the duplication is visible: the CLI
// cannot read the server's constant, and a compact refused after a round trip
// is a close the agent has to reissue. The SERVER's bound is the authority —
// this one only saves the trip, and the server's test is what proves the wall.
const flightRecorderMaxBytes = 16 * 1024

const (
	primingBodyKey        = "priming_start"
	contextCompactBodyKey = "context_compact"
	contextCompactFlag    = "--context-compact"
)

// primingWireArgs builds the manifest ONCE and returns it together with the
// `--set` argument pair that carries it to the server.
//
// Returns (nil, nil, nil) when there is nothing to record — no priming dir
// configured (the default: no existing invocation changes), or a doc id that
// could not be resolved from the command line. The unresolved-id case is NOT
// silent: recordPrimingManifest still refuses loudly after the POST, which is
// the one place that decision lives.
//
// An oversized manifest is a WARNING, not a refusal: the claim is the thing the
// agent came for, and losing it because its loadout record is fat would be the
// tail wagging the dog. The local write still happens; only the wire key is
// dropped, and stderr says so.
func primingWireArgs(out *writer, env primingEnv, docID, worker string) (*PrimingManifest, []string, error) {
	if primingDirPath(env.getenv) == "" || strings.TrimSpace(docID) == "" {
		return nil, nil, nil
	}
	m := buildPrimingManifest(env, docID, worker)
	b, err := json.Marshal(m)
	if err != nil {
		return &m, nil, fmt.Errorf("could not encode priming manifest for the wire: %w", err)
	}
	if len(b) > flightRecorderMaxBytes {
		if out != nil {
			out.errf("priming: manifest is %d bytes, over the %d-byte ledger bound — recorded LOCALLY only, not on the row\n",
				len(b), flightRecorderMaxBytes)
		}
		return &m, nil, nil
	}
	return &m, []string{"--set", primingBodyKey + ":=" + string(b)}, nil
}

// consumeContextCompact strips the client-side `--context-compact <file>` flag
// from a `bp task close` tail, reads the file, and returns the `--set` pair that
// carries its CONTENTS to the server.
//
// Three refusals, all BEFORE the POST, because each one is a close that would
// otherwise seal a row while silently dropping the record the agent asked to
// attach — the exact silence this epic exists to end:
//
//   - no path after the flag
//   - the file cannot be read
//   - the compact is over the ledger bound (named with the server's own code,
//     so the operator sees one vocabulary whichever side refuses)
//
// A blank or whitespace-only file is NOT a refusal and NOT a key: it records
// nothing, and the server treats it identically (FlightRecorder.validate_context_compact/1).
func consumeContextCompact(out *writer, tail []string) (forward []string, inject []string, code int, refused bool) {
	var path string
	var seen bool

	forward = make([]string, 0, len(tail))
	for i := 0; i < len(tail); i++ {
		tok := tail[i]
		switch {
		case tok == contextCompactFlag:
			seen = true
			if i+1 < len(tail) && !strings.HasPrefix(tail[i+1], "-") {
				path = tail[i+1]
				i++
			}
			continue
		case strings.HasPrefix(tok, contextCompactFlag+"="):
			seen = true
			path = strings.TrimPrefix(tok, contextCompactFlag+"=")
			continue
		}
		forward = append(forward, tok)
	}

	if !seen {
		return tail, nil, exitOK, false
	}
	if strings.TrimSpace(path) == "" {
		out.errf("%s needs a file path — nothing was closed\n", contextCompactFlag)
		return forward, nil, exitUsage, true
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		out.errf("%s: could not read %s: %v — nothing was closed, so the compact is not silently lost\n",
			contextCompactFlag, path, err)
		return forward, nil, exitGeneric, true
	}
	if len(raw) > flightRecorderMaxBytes {
		out.errf("context_compact_too_large: %s is %d bytes, over the %d-byte ledger bound — NOTHING was written and the task's rev is unchanged. Compact it further and close again.\n",
			path, len(raw), flightRecorderMaxBytes)
		return forward, nil, exitGeneric, true
	}
	if strings.TrimSpace(string(raw)) == "" {
		out.errf("%s: %s is empty — closing with no compact recorded\n", contextCompactFlag, path)
		return forward, nil, exitOK, false
	}
	return forward, []string{"--set", contextCompactBodyKey + "=" + string(raw)}, exitOK, false
}
