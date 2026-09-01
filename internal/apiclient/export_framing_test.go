package apiclient

import (
	"bufio"
	"context"
	"net"
	"strconv"
	"strings"
	"testing"
)

// rawHTTPServer serves EXACTLY ONE request from a hand-written HTTP response and
// then closes the connection. httptest/net/http would frame the response for us
// (adding Content-Length or chunked encoding); these tests are ABOUT the framing,
// so every byte after the request line has to be ours.
//
// It returns the base URL to point a Client at.
func rawHTTPServer(t *testing.T, response string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		// Drain the request head so the client's write does not block.
		br := bufio.NewReader(conn)
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			if line == "\r\n" || line == "\n" {
				break
			}
		}
		_, _ = conn.Write([]byte(response))
		// Closing here is the only end-of-body signal a close-delimited response
		// ever gets — and the whole point of case 1.
	}()

	return "http://" + ln.Addr().String()
}

// exportAgainst runs Export against a raw server and reports the error plus the
// documents actually delivered to the callback.
func exportAgainst(t *testing.T, response string) (error, []string) {
	t.Helper()
	base := rawHTTPServer(t, response)
	c := New(Config{BaseURL: base, Workspace: "ws", Project: "proj", Dataset: "production"})
	var lines []string
	err := c.Export(context.Background(), ExportOpts{}, func(line string) error {
		lines = append(lines, line)
		return nil
	})
	return err, lines
}

const threeDocs = `{"_id":"a"}` + "\n" + `{"_id":"b"}` + "\n" + `{"_id":"c"}` + "\n"

// CASE 1 — CLOSE-DELIMITED, TRUNCATED. No Content-Length, no chunked framing:
// the body ends when the connection closes, so a server that died mid-dataset
// is byte-identical to one that finished. scanner.Err() is nil here, which is
// why Export must refuse to attest the stream instead of reporting success.
func TestExportRefusesCloseDelimitedFraming(t *testing.T) {
	err, lines := exportAgainst(t,
		"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n"+threeDocs)

	if err == nil {
		t.Fatalf("Export returned err=<nil> after %d documents on a CLOSE-DELIMITED body; "+
			"a truncated stream is indistinguishable from a complete one, so it must not be attested as complete", len(lines))
	}
	if !strings.Contains(err.Error(), "close-delimited") {
		t.Errorf("error = %q, want it to name the close-delimited framing", err)
	}
	if len(lines) != 3 {
		t.Errorf("delivered %d documents, want 3 (the refusal must not swallow what did arrive)", len(lines))
	}
	// The operator has to learn what they actually got.
	if !strings.Contains(err.Error(), "3") {
		t.Errorf("error = %q, want it to report the 3 documents received", err)
	}
}

// CASE 2 — SHORT CONTENT-LENGTH. Honest framing: the declared length outruns the
// bytes, so the transport itself reports an unexpected EOF. Unchanged behaviour.
func TestExportShortContentLengthStillErrors(t *testing.T) {
	err, lines := exportAgainst(t,
		"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: 9999\r\n\r\n"+threeDocs)

	if err == nil {
		t.Fatalf("Export returned nil on a SHORT Content-Length body (%d documents); want an unexpected-EOF error", len(lines))
	}
	if len(lines) != 3 {
		t.Errorf("delivered %d documents, want 3", len(lines))
	}
}

// CASE 3 — CHUNKED WITHOUT ITS TERMINATOR. Honest framing: the missing `0\r\n\r\n`
// is a real transport error. Unchanged behaviour.
func TestExportChunkedMissingTerminatorStillErrors(t *testing.T) {
	chunk := func(s string) string {
		return strconv.FormatInt(int64(len(s)), 16) + "\r\n" + s + "\r\n"
	}
	body := chunk(`{"_id":"a"}`+"\n") + chunk(`{"_id":"b"}`+"\n") + chunk(`{"_id":"c"}`+"\n")
	err, lines := exportAgainst(t,
		"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"+body)

	if err == nil {
		t.Fatalf("Export returned nil on a CHUNKED body missing its terminator (%d documents); want an unexpected-EOF error", len(lines))
	}
	if len(lines) != 3 {
		t.Errorf("delivered %d documents, want 3", len(lines))
	}
}

// CASE 4 — THE NEGATIVE ARM. A COMPLETE, properly terminated chunked response is
// attestable framing and must still succeed: this is what proves the refusal is
// framing-specific and not "always fail".
func TestExportCompleteChunkedSucceeds(t *testing.T) {
	chunk := func(s string) string {
		return strconv.FormatInt(int64(len(s)), 16) + "\r\n" + s + "\r\n"
	}
	body := chunk(`{"_id":"a"}`+"\n") + chunk(`{"_id":"b"}`+"\n") + chunk(`{"_id":"c"}`+"\n") + "0\r\n\r\n"
	err, lines := exportAgainst(t,
		"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"+body)

	if err != nil {
		t.Fatalf("Export returned %v on a COMPLETE chunked body, want nil", err)
	}
	if len(lines) != 3 {
		t.Fatalf("delivered %d documents, want 3", len(lines))
	}
}
