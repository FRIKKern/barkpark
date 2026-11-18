package cli

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// shrinkImportTimeout gives every batch a short deadline for the test.
func shrinkImportTimeout(t *testing.T, d time.Duration) {
	t.Helper()
	floor, rate := importTimeoutFloor, importUploadBytesPerSecond
	importTimeoutFloor, importUploadBytesPerSecond = d, 1<<30
	t.Cleanup(func() { importTimeoutFloor, importUploadBytesPerSecond = floor, rate })
}

// stallProxy forwards TCP to target. The first connection goes silent after
// the client has sent stallAfter bytes: it stops reading and never closes, as
// the connection to the Azure box did on 2026-11-18.
func stallProxy(t *testing.T, target string, stallAfter int64) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var conns []net.Conn
	var n atomic.Int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			u, err := net.Dial("tcp", target)
			if err != nil {
				c.Close()
				continue
			}
			mu.Lock()
			conns = append(conns, c, u)
			mu.Unlock()
			first := n.Add(1) == 1
			go io.Copy(c, u)
			go func() {
				if first {
					io.CopyN(u, c, stallAfter)
					return
				}
				io.Copy(u, c)
			}()
		}
	}()
	t.Cleanup(func() {
		ln.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, c := range conns {
			c.Close()
		}
	})
	return ln.Addr().String()
}

// task-1e302921c7545cb0: over HTTP/2 a request whose connection stalled
// leaves that connection in the pool, and every later request on the same
// transport waits on it and times out. That is why each halved batch on
// 2026-11-18 timed out without reaching the server. After reset() the sender
// dials a new connection and the request goes through.
func TestImportSenderResetLeavesAStalledConnection(t *testing.T) {
	shrinkImportTimeout(t, 1500*time.Millisecond)
	var got atomic.Int32
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		got.Add(1)
		_, _ = w.Write([]byte(`{}`))
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	t.Cleanup(srv.Close)
	su, _ := url.Parse(srv.URL)
	proxied := "https://" + stallProxy(t, su.Host, 1_000_000)
	base := srv.Client().Transport.(*http.Transport)
	prev := newImportTransport
	newImportTransport = func() *http.Transport { return base.Clone() }
	t.Cleanup(func() { newImportTransport = prev })

	s := newImportSender()
	defer s.close()
	isTimeout := func(err error) bool {
		var ne net.Error
		return errors.As(err, &ne) && ne.Timeout()
	}
	if _, _, err := s.send(http.MethodPost, proxied, nil, bytes.Repeat([]byte("x"), 30_000_000)); !isTimeout(err) {
		t.Fatalf("the 30 MB post on the stalling connection: err = %v, want a timeout", err)
	}
	// Without a reset the next small post rides the same stalled connection.
	if _, _, err := s.send(http.MethodPost, proxied, nil, []byte(`{}`)); !isTimeout(err) {
		t.Fatalf("a small post on the same transport: err = %v, want a timeout (the stalled connection is reused)", err)
	}
	if got.Load() != 0 {
		t.Fatalf("the server finished %d request(s) on the stalled connection, want 0", got.Load())
	}
	s.reset()
	status, _, err := s.send(http.MethodPost, proxied, nil, []byte(`{}`))
	if err != nil || status != http.StatusOK {
		t.Fatalf("after reset: status %d, err %v; want 200 on a new connection", status, err)
	}
	if got.Load() != 1 {
		t.Errorf("the server finished %d request(s), want 1", got.Load())
	}
}

// The import loop drops its connections after a timed-out batch, so the
// halved batch goes out on a new transport, and every document lands.
func TestRunImportOpensANewConnectionAfterATimeout(t *testing.T) {
	shrinkImportTimeout(t, 300*time.Millisecond)
	var transports atomic.Int32
	prev := newImportTransport
	newImportTransport = func() *http.Transport {
		transports.Add(1)
		return prev()
	}
	t.Cleanup(func() { newImportTransport = prev })

	path := filepath.Join(t.TempDir(), "backup.ndjson")
	var b strings.Builder
	for n := 0; n < 40; n++ {
		fmt.Fprintf(&b, `{"_id":"p-%04d","_type":"post","title":"t"}`+"\n", n)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := newImportFakeServer(t)
	dst.hang = 1
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, path)
	if code != exitOK {
		t.Fatalf("import exit = %d; stderr=%s", code, stderr)
	}
	if len(dst.docs) != 40 {
		t.Fatalf("target holds %d documents, want 40", len(dst.docs))
	}
	if !strings.Contains(stderr, "did not finish: the request timed out. Sending 20 documents per batch") {
		t.Errorf("stderr does not show the halving after the timeout:\n%s", stderr)
	}
	if transports.Load() != 2 {
		t.Errorf("the import built %d transports, want 2: one at the start and one after the timeout", transports.Load())
	}
}

// A single document that times out is sent once more on a new connection
// before the run stops.
func TestRunImportRetriesOneTimedOutDocumentOnANewConnection(t *testing.T) {
	shrinkImportTimeout(t, 300*time.Millisecond)
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	if err := os.WriteFile(path, []byte(`{"_id":"a","_type":"post"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := newImportFakeServer(t)
	dst.hang = 1
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, path)
	if code != exitOK {
		t.Fatalf("import exit = %d; stderr=%s", code, stderr)
	}
	if !strings.Contains(stderr, "Sending it again on a new connection") {
		t.Errorf("stderr does not name the retry:\n%s", stderr)
	}

	// Two timeouts in a row stop the run with the resume line.
	dst2 := newImportFakeServer(t)
	dst2.hang = 2
	code, _, stderr = runImportForTest(t, dst2.ctx(), globals{}, path)
	if code == exitOK {
		t.Fatalf("import exited 0 after two timeouts; stderr=%s", stderr)
	}
	if !strings.Contains(stderr, "--from-line 1") {
		t.Errorf("stderr does not name the resume line:\n%s", stderr)
	}
}

// The default packs batches to importDefaultBatchBytes. A document bigger than
// that goes alone, and only a document over the server's request cap is
// refused.
func TestImportBatchesDefaultSizeAndOversizedDocument(t *testing.T) {
	row := func(line, size int) *importRow {
		body := fmt.Sprintf(`{"createOrReplace":{"_id":"d-%d","_type":"post","x":"%s"}}`, line, strings.Repeat("x", size))
		return &importRow{Line: line, ID: fmt.Sprintf("d-%d", line), Type: "post", Action: "create", mutations: [][]byte{[]byte(body)}}
	}
	var rows []*importRow
	for n := 1; n <= 30; n++ {
		rows = append(rows, row(n, 1_000_000))
	}
	rows = append(rows, row(31, 8_000_000))
	batches, err := importBatches(rows, importDefaultBatchBytes, importMaxRequestBytes, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(batches) < 7 {
		t.Errorf("31 MB in %d batches, want at least 7 at the 5 MB default", len(batches))
	}
	last := batches[len(batches)-1]
	if len(last.rows) != 1 || last.rows[0].Line != 31 {
		t.Errorf("the 8 MB document shares a batch: %d rows", len(last.rows))
	}
	for k, b := range batches[:len(batches)-1] {
		if len(b.body) > importDefaultBatchBytes {
			t.Errorf("batch %d is %d bytes, over the default %d", k+1, len(b.body), importDefaultBatchBytes)
		}
	}
	if _, err := importBatches([]*importRow{row(1, importMaxRequestBytes)}, importDefaultBatchBytes, importMaxRequestBytes, 0); err == nil {
		t.Error("a document over the request cap was accepted")
	}
	// An explicit --batch-bytes is the cap for every request, as before.
	if _, err := importBatches([]*importRow{row(1, 8_000_000)}, 5_000_000, 5_000_000, 0); err == nil {
		t.Error("an 8 MB document passed an explicit 5 MB cap")
	}
}
