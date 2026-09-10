package cli

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// CLAIMING AND PROTECTING ARE ONE ACT (task-f79e39f4992749a5, criterion 2).
//
// A claim is protected only if its doc id ALSO reaches the file the lane's
// pulse loop reads. Those were two separate manual acts, and the gap is silent:
// task-f0e49432f1653c2f was claimed by lead-cli-11, never added to
// held.lead-cli-s8.txt, therefore never pulsed. The lease lapsed, a worker
// built PR #16660 against an unclaimed row, and the handover still called it
// claimed. Nothing reported it — a successor found it by re-reading the live
// row. A convention in a brief does not fix this: the lead that lost that claim
// HAD the convention in front of it.
//
// So the append rides the claim itself, and — the half that makes it evidence
// rather than a hope — the file is READ BACK and the id looked for. A write
// that silently did not land (a full disk, a read-only mount, a path whose
// parent does not exist, an append into a file another process truncated
// underneath us) FAILS LOUD at claim time instead of being discovered by the
// next session.
//
// Opt-in by env var, so no existing invocation changes behaviour:
//
//	BARKPARK_HELD_FILE=/path/to/held.lead-cli-s8.txt bp task claim <id> <worker>
//
// The reconciliation in the OTHER direction — rows the server says this worker
// holds that are NOT in the file — is `scripts/ledger/claim-health.sh --held`,
// because it needs the server's view and this path only has the write it just
// made.

// heldFilePath is the file the claim must also reach, or "" when the caller
// opted out (the default).
func heldFilePath() string {
	return strings.TrimSpace(os.Getenv("BARKPARK_HELD_FILE"))
}

// recordHeldClaim appends docID to path and then reads the file back to prove
// the id is there. Returns an error naming what it could not prove — never a
// silent success. Idempotent: an id already present is left alone (a re-claim
// or a lease renewal must not duplicate the line), and the readback still runs,
// so the "already there" path is verified rather than assumed.
func recordHeldClaim(path, docID string) error {
	docID = strings.TrimSpace(docID)
	if docID == "" {
		return fmt.Errorf("no doc id to record")
	}
	present, err := heldFileHas(path, docID)
	if err != nil {
		return err
	}
	if !present {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return fmt.Errorf("could not open held file %s to record %s: %w — this claim is NOT protected", path, docID, err)
		}
		if _, err := f.WriteString(docID + "\n"); err != nil {
			f.Close()
			return fmt.Errorf("could not append %s to held file %s: %w", docID, path, err)
		}
		if err := f.Close(); err != nil {
			return fmt.Errorf("could not flush held file %s: %w", path, err)
		}
	}
	// THE READBACK. This is the whole point: the append above can report
	// success and still not be in the file a pulse loop will read.
	back, err := heldFileHas(path, docID)
	if err != nil {
		return err
	}
	if !back {
		return fmt.Errorf(
			"held-file readback FAILED: %s is not in %s after the append — this claim will NOT be pulsed",
			docID, path)
	}
	return nil
}

// heldFileHas reports whether path contains docID as a line (leading/trailing
// space and a trailing comment are tolerated; held files carry both). A missing
// file is not an error — it is simply "not present yet".
func heldFileHas(path, docID string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("could not read held file %s: %w", path, err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		if heldFileLineID(sc.Text()) == docID {
			return true, nil
		}
	}
	if err := sc.Err(); err != nil {
		return false, fmt.Errorf("could not scan held file %s: %w", path, err)
	}
	return false, nil
}

// heldFileLineID extracts the doc id from a held-file line, dropping a `#`
// comment and surrounding whitespace. A blank or comment-only line yields "".
func heldFileLineID(line string) string {
	if i := strings.Index(line, "#"); i >= 0 {
		line = line[:i]
	}
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}
