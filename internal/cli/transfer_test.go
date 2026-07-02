package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// shrinkTransferHeaderTimeout temporarily lowers the transfer client's
// response-header timeout so these tests run in milliseconds, restoring it after.
func shrinkTransferHeaderTimeout(t *testing.T, d time.Duration) {
	t.Helper()
	prev := transferResponseHeaderTimeout
	transferResponseHeaderTimeout = d
	t.Cleanup(func() { transferResponseHeaderTimeout = prev })
}

// trickleReader wraps r so each Read yields at most chunk bytes after a delay —
// modeling a slow upload connection: the request body's transmission takes real
// wall-clock time. ResponseHeaderTimeout arms only after the body is FULLY
// written, so this must not trip it.
type trickleReader struct {
	r     io.Reader
	delay time.Duration
	chunk int
}

func (tr *trickleReader) Read(p []byte) (int, error) {
	time.Sleep(tr.delay)
	if len(p) > tr.chunk {
		p = p[:tr.chunk]
	}
	return tr.r.Read(p)
}

// TestDoRequestStreamTrickleUpload proves the streaming upload path survives a
// body whose transmission takes far longer than transferResponseHeaderTimeout:
// ResponseHeaderTimeout only bounds the wait AFTER the body is fully written, so
// a slow-but-alive upload completes (the old 30s absolute-Timeout client would
// have killed anything >30s wall-clock). The body is a real multipart stream
// from buildMultipartFile, wrapped in trickleReader to model a slow connection.
func TestDoRequestStreamTrickleUpload(t *testing.T) {
	shrinkTransferHeaderTimeout(t, 200*time.Millisecond)

	var received int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		received = n
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"result":{"ok":true}}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	fpath := filepath.Join(dir, "upload.bin")
	payload := bytes.Repeat([]byte("x"), 1024)
	if err := os.WriteFile(fpath, payload, 0o644); err != nil {
		t.Fatal(err)
	}

	stream, ct, err := buildMultipartFile(fpath)
	if err != nil {
		t.Fatalf("buildMultipartFile: %v", err)
	}
	// ~1KB multipart body in 32-byte sips at 15ms each ≈ 600ms of transmission,
	// comfortably past the 200ms header timeout.
	slow := &trickleReader{r: stream, delay: 15 * time.Millisecond, chunk: 32}
	status, resp, err := doRequestStream("POST", srv.URL, map[string]string{"Content-Type": ct}, slow, -1)
	if err != nil {
		t.Fatalf("doRequestStream errored on a slow-but-alive upload: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", status, resp)
	}
	if received == 0 {
		t.Fatal("server received no body bytes")
	}
}

// TestDoRequestStreamHeaderTimeout proves ResponseHeaderTimeout still fires: a
// server that drains the body then stalls before writing headers must make the
// request error out rather than hang forever.
func TestDoRequestStreamHeaderTimeout(t *testing.T) {
	shrinkTransferHeaderTimeout(t, 150*time.Millisecond)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		time.Sleep(600 * time.Millisecond) // stall past the header timeout
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	body := "ping"
	_, _, err := doRequestStream("POST", srv.URL, nil, strings.NewReader(body), int64(len(body)))
	if err == nil {
		t.Fatal("doRequestStream did not error when the server stalled past ResponseHeaderTimeout")
	}
}

// TestFetchToFileTrickleDownload proves the upgrade download path survives a
// slow body: headers arrive immediately (beating the header timeout), then the
// server flushes bytes slowly past it, and fetchToFile still writes the intact
// file (the old 120s absolute-Timeout client would have capped the transfer).
func TestFetchToFileTrickleDownload(t *testing.T) {
	shrinkTransferHeaderTimeout(t, 200*time.Millisecond)

	want := bytes.Repeat([]byte("barkpark"), 128) // 1024 bytes
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK) // headers first — no header-timeout risk
		fl, _ := w.(http.Flusher)
		for i := 0; i < len(want); i += 32 {
			end := i + 32
			if end > len(want) {
				end = len(want)
			}
			w.Write(want[i:end])
			if fl != nil {
				fl.Flush()
			}
			time.Sleep(10 * time.Millisecond)
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	dst := filepath.Join(dir, "bp.new")
	if err := fetchToFile(newTransferClient(), srv.URL, dst); err != nil {
		t.Fatalf("fetchToFile errored on a slow-but-alive download: %v", err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("downloaded content mismatch: got %d bytes, want %d", len(got), len(want))
	}
}
