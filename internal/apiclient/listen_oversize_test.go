package apiclient

import (
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

// These tests pin the shared SSE reader's behaviour on an OVERSIZE line — the
// case whose old signature was silence. scanListenFrames used to discard
// scanner.Err(), so bufio.ErrTooLong ended the read with a bare nil: identical
// to a clean EOF, so all three callers (Listen, ChatEvents, FleetEvents) simply
// backed off and reconnected while the frame — and every later frame in the same
// response — was gone for good.

// scanFrames drives scanListenFrames over r the way a caller does, returning the
// dispatched "event|data" frames, the cursor the id: lines left behind, and the
// error the reader surfaced.
func scanFrames(t *testing.T, r io.Reader) (frames []string, cursor string, err error) {
	t.Helper()
	backoff := 4 * time.Second
	err = scanListenFrames(r, &cursor, &backoff, time.Second, func(event, data string) error {
		frames = append(frames, event+"|"+data)
		return nil
	}, nil)
	return frames, cursor, err
}

// dataLine builds a `data: ` line whose TOTAL length (excluding the newline) is
// exactly total bytes — the unit the scanner's cap is measured in.
func dataLine(total int) string {
	const prefix = "data: "
	return prefix + strings.Repeat("x", total-len(prefix))
}

// The cap itself is part of the contract: a silent change here would move the
// boundary the tests below pin, and would move it for the SERVER too (the
// server's per-frame bound must stay inside the smallest cap any shipped binary
// carries, and shipped binaries can never be fixed in the field).
func TestMaxSSELineBytesIsPinned(t *testing.T) {
	if maxSSELineBytes != 8*1024*1024 {
		t.Fatalf("maxSSELineBytes = %d, want 8 MiB (8388608) — the change.go/export.go precedent", maxSSELineBytes)
	}
}

// An oversize line yields a NON-NIL, size-naming, errors.Is-distinguishable
// error — and the frames that preceded it were still delivered.
func TestScanListenFramesOversizeLineReturnsTypedError(t *testing.T) {
	stream := "event: mutation\ndata: {\"seq\":7}\n\n" +
		"event: mutation\n" + dataLine(maxSSELineBytes) + "\n\n" +
		"event: mutation\ndata: {\"seq\":9}\n\n"

	frames, _, err := scanFrames(t, strings.NewReader(stream))

	if err == nil {
		t.Fatal("oversize line returned nil — indistinguishable from a clean EOF, which is the bug")
	}
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("error %v is not errors.Is(ErrFrameTooLarge) — a caller cannot tell an over-cap frame from a dropped connection", err)
	}
	if !strings.Contains(err.Error(), "8388608") || !strings.Contains(strings.ToLower(err.Error()), "too large") {
		t.Fatalf("error message does not name the size problem: %q", err)
	}
	// Frames before the oversize line still arrive; frames after it do not —
	// the reader stops at the bad line, it does not resynchronise.
	if len(frames) != 1 || frames[0] != `mutation|{"seq":7}` {
		t.Fatalf("frames = %q, want only the frame preceding the oversize one", frames)
	}
}

// The exact byte boundary: maxSSELineBytes-1 is the largest line bufio.Scanner
// can deliver (the trailing newline must still fit in the buffer), and
// maxSSELineBytes is the first line it rejects.
func TestScanListenFramesByteBoundary(t *testing.T) {
	t.Run("largest deliverable line", func(t *testing.T) {
		line := dataLine(maxSSELineBytes - 1)
		frames, _, err := scanFrames(t, strings.NewReader("event: mutation\n"+line+"\n\n"))
		if err != nil {
			t.Fatalf("line of %d bytes must be delivered, got error: %v", maxSSELineBytes-1, err)
		}
		if len(frames) != 1 || len(frames[0]) != len("mutation|")+maxSSELineBytes-1-len("data: ") {
			t.Fatalf("frame not delivered intact: got %d frames", len(frames))
		}
	})

	t.Run("first rejected line", func(t *testing.T) {
		line := dataLine(maxSSELineBytes)
		_, _, err := scanFrames(t, strings.NewReader("event: mutation\n"+line+"\n\n"))
		if !errors.Is(err, ErrFrameTooLarge) {
			t.Fatalf("line of %d bytes must be rejected with ErrFrameTooLarge, got %v", maxSSELineBytes, err)
		}
	})
}

// The permanent-loss shape: the server writes `id: SEQ` on its own short line
// BEFORE the giant data line and resumes strictly exclusive (seq > since), so an
// id-carrying oversize frame advances the cursor past a row that never arrived —
// that row is skipped FOREVER on reconnect. The reader cannot undo that; what it
// must no longer do is hide it behind a nil that reads as a plain drop.
func TestScanListenFramesIDCarryingOversizeIsPermanentLoss(t *testing.T) {
	stream := "id: 7\nevent: message\ndata: {\"seq\":7}\n\n" +
		"id: 8\nevent: message\n" + dataLine(maxSSELineBytes) + "\n\n" +
		"id: 9\nevent: message\ndata: {\"seq\":9}\n\n"

	frames, cursor, err := scanFrames(t, strings.NewReader(stream))

	if len(frames) != 1 || frames[0] != `message|{"seq":7}` {
		t.Fatalf("frames = %q, want only seq 7", frames)
	}
	if cursor != "8" {
		t.Fatalf("cursor = %q, want %q — the id: line lands before the oversize data line, so the cursor advances past a frame that never arrived", cursor, "8")
	}
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("permanent loss must surface as ErrFrameTooLarge, got %v", err)
	}
}

// A large-but-under-cap frame — bigger than the OLD 1 MiB cap — passes clean.
func TestScanListenFramesLargeUnderCapFramePassesClean(t *testing.T) {
	payload := strings.Repeat("y", 2*1024*1024) // 2 MiB: over the old cap, under the new one
	frames, _, err := scanFrames(t, strings.NewReader("event: message\ndata: "+payload+"\n\n"))
	if err != nil {
		t.Fatalf("2 MiB frame must pass clean, got %v", err)
	}
	if len(frames) != 1 || frames[0] != "message|"+payload {
		t.Fatalf("2 MiB frame not delivered intact (got %d frames)", len(frames))
	}
}

// Guard the resilience the callers depend on: a NON-size read error (a mid-
// stream connection reset) is still an ordinary drop — it returns nil so the
// reconnect ladders behave exactly as before. Only the size case is loud.
func TestScanListenFramesReadErrorStillReadsAsDrop(t *testing.T) {
	r := io.MultiReader(
		strings.NewReader("event: mutation\ndata: {\"seq\":1}\n\n"),
		&errReader{err: errors.New("connection reset by peer")},
	)
	frames, _, err := scanFrames(t, r)
	if err != nil {
		t.Fatalf("a mid-stream read error must stay a drop (nil), got %v", err)
	}
	if len(frames) != 1 {
		t.Fatalf("frames = %q, want the frame read before the error", frames)
	}
}

type errReader struct{ err error }

func (e *errReader) Read([]byte) (int, error) { return 0, e.err }
