package cli

import (
	"bytes"
	"context"
	"net/http"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// importSender posts the import's mutate batches on a client of its own, so
// the import can drop its connections without touching the shared dispatch
// client (task-1e302921c7545cb0).
//
// On 2026-11-18 the first 30 MB batch to a new Azure box stalled mid-upload.
// The shared client reused the stalled HTTP/2 connection for every smaller
// retry, so each one timed out without reaching the server. reset() replaces
// the transport, and the next request dials a new connection.
type importSender struct {
	transport *http.Transport
	client    *http.Client
}

// newImportTransport builds the transport for one sender. Tests replace it to
// trust a TLS test server or to count the connections the import opens.
var newImportTransport = func() *http.Transport {
	return http.DefaultTransport.(*http.Transport).Clone()
}

// importTimeoutFloor and importUploadBytesPerSecond set the wall-clock budget
// for one batch: the floor plus the time to upload the body at
// importUploadBytesPerSecond. A 5 MB batch gets 85 s and a 30 MB document gets
// 210 s, where the shared client gave every request 30 s. Vars so a test can
// shrink them.
var (
	importTimeoutFloor         = 60 * time.Second
	importUploadBytesPerSecond = 200_000
)

func importBatchTimeout(bodyBytes int) time.Duration {
	return importTimeoutFloor + time.Duration(bodyBytes/importUploadBytesPerSecond)*time.Second
}

func newImportSender() *importSender {
	s := &importSender{}
	s.reset()
	return s
}

// reset closes the sender's idle connections and gives it a new transport. A
// connection still held by a stalled request is left to its own timeout; the
// new transport never hands it out again.
func (s *importSender) reset() {
	s.close()
	s.transport = newImportTransport()
	s.client = &http.Client{
		// The same 429 and transient 500 policy as every other bp request.
		Transport:     apiclient.NewRetryTransport(s.transport),
		CheckRedirect: checkRedirect,
	}
}

func (s *importSender) close() {
	if s.transport != nil {
		s.transport.CloseIdleConnections()
	}
}

// send sends one batch with a deadline scaled to its size and returns the
// status and body, read under the same cap as every bp response. The caller
// names the method, so the write census finds the write in importWriteBatch.
func (s *importSender) send(method, rawURL string, headers map[string]string, body []byte) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), importBatchTimeout(len(body)))
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, rawURL, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	noteResponseHeader(resp.Header)
	respBody, err := readCapped(resp.Body, responseByteCap)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, respBody, nil
}
