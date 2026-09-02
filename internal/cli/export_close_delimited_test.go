package cli

import (
	"bufio"
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// exportServeCloseDelimited answers EVERY connection with the same hand-framed
// response: a 200 with NO Content-Length and NO chunked framing, three
// documents, then the connection closes. That close is the body's only
// terminator, so a server that died after three of three thousand documents
// would produce these exact bytes. httptest cannot produce this framing (it
// adds Content-Length or chunks the body), which is why the listener is raw.
func exportServeCloseDelimited(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	const response = "HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/x-ndjson\r\n" +
		"Connection: close\r\n" +
		"\r\n" +
		`{"_id":"a"}` + "\n" + `{"_id":"b"}` + "\n" + `{"_id":"c"}` + "\n"

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				// Drain the request head so the client's write never blocks.
				br := bufio.NewReader(c)
				for {
					line, err := br.ReadString('\n')
					if err != nil {
						return
					}
					if line == "\r\n" || line == "\n" {
						break
					}
				}
				_, _ = c.Write([]byte(response))
			}(conn)
		}
	}()

	return "http://" + ln.Addr().String()
}

// END TO END, the case the sidecar doctrine could not see. Before #14597 a
// close-delimited stream that stopped early returned a nil error, `--out`
// wrote a sidecar whose sha256, byte total and line count all described the
// SHORT file, and `bp export --verify` PASSED on a falsified backup. This test
// pins the whole chain: the verb exits non-zero and says PARTIAL, NO sidecar
// exists for either the requested name or the partial, and `--verify` on what
// the operator actually has REFUSES. Delete the close-delimited refusal in
// apiclient.Export and the first assertion reds; delete the sidecar's
// "only after a clean completion" rule and the second one does.
func TestRunExportOutCloseDelimitedWritesNoSidecarAndVerifyRefuses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	partial := path + exportPartialSuffix

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	ctx := manifest.Context{
		Server:    exportServeCloseDelimited(t),
		Workspace: "ws",
		Project:   "proj",
		Dataset:   "production",
	}

	if code := runExport(out, globals{}, ctx, []string{"--out", path}); code != exitGeneric {
		t.Fatalf("export exit = %d, want %d — a close-delimited stream cannot be attested as complete; stderr=%s",
			code, exitGeneric, se.String())
	}
	if !strings.Contains(se.String(), "close-delimited") || !strings.Contains(se.String(), "PARTIAL") {
		t.Errorf("stderr = %q, want it to name the close-delimited framing and call the artifact PARTIAL", se.String())
	}

	for _, sidecar := range []string{path + exportMetaSuffix, partial + exportMetaSuffix} {
		if _, err := os.Stat(sidecar); !os.IsNotExist(err) {
			t.Errorf("sidecar %s is present (stat err=%v) — a stream whose completeness is unknowable must leave NO attestation",
				sidecar, err)
		}
	}

	// What the operator is left with is the partial file. It must not verify.
	if _, err := os.Stat(partial); err != nil {
		t.Fatalf("the partial artifact %s should remain for inspection: %v", partial, err)
	}
	var so2, se2 bytes.Buffer
	out2 := newWriter(&so2, &se2)
	if code := runExport(out2, globals{}, manifest.Context{}, []string{"--verify", partial}); code != exitGeneric {
		t.Fatalf("verify exit = %d, want %d — a silently truncated export must never verify; stderr=%s",
			code, exitGeneric, se2.String())
	}
	if !strings.Contains(se2.String(), "no sidecar") {
		t.Errorf("verify stderr = %q, want it to say the artifact has no sidecar", se2.String())
	}
}
