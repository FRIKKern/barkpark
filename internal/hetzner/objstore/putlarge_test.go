package objstore

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

// multipartTransport answers the four S3 multipart operations PutLarge drives,
// routed by method + query, recording the sequence in `ops`. With failPart set,
// UploadPart returns 500 so the abort path can be exercised. No socket is opened.
type multipartTransport struct {
	ops      []string
	failPart bool
}

func (t *multipartTransport) resp(code int, hdr http.Header, body string, req *http.Request) *http.Response {
	if hdr == nil {
		hdr = http.Header{}
	}
	return &http.Response{StatusCode: code, Header: hdr, Body: io.NopCloser(strings.NewReader(body)), Request: req}
}

func (t *multipartTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	q := req.URL.Query()
	switch {
	case req.Method == http.MethodPost && q.Has("uploads"):
		t.ops = append(t.ops, "create")
		return t.resp(200, nil,
			`<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>test-upload-id</UploadId></InitiateMultipartUploadResult>`,
			req), nil
	case req.Method == http.MethodPut && q.Get("partNumber") != "":
		t.ops = append(t.ops, "part:"+q.Get("partNumber"))
		if t.failPart {
			// 403/AccessDenied is non-retryable, so the SDK fails fast (no backoff
			// loop) — keeps the abort-path test quick and deterministic.
			return t.resp(403, nil, `<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>`, req), nil
		}
		return t.resp(200, http.Header{"Etag": {fmt.Sprintf("%q", "etag-"+q.Get("partNumber"))}}, "", req), nil
	case req.Method == http.MethodPost && q.Get("uploadId") != "":
		t.ops = append(t.ops, "complete")
		return t.resp(200, nil,
			`<?xml version="1.0"?><CompleteMultipartUploadResult><Location>x</Location><Bucket>b</Bucket><Key>k</Key><ETag>"final"</ETag></CompleteMultipartUploadResult>`,
			req), nil
	case req.Method == http.MethodDelete && q.Get("uploadId") != "":
		t.ops = append(t.ops, "abort")
		return t.resp(204, nil, "", req), nil
	}
	return t.resp(400, nil, `<?xml version="1.0"?><Error><Code>Unexpected</Code></Error>`, req), nil
}

func newMultipartClient(t *testing.T, rt http.RoundTripper) *Client {
	t.Helper()
	c, err := NewClient("fsn1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c
}

func TestPutLargeSinglePart(t *testing.T) {
	rt := &multipartTransport{}
	c := newMultipartClient(t, rt)
	if err := c.PutLarge(context.Background(), "backups", "db/x.sql.gz", strings.NewReader("hello world")); err != nil {
		t.Fatalf("PutLarge: %v", err)
	}
	want := []string{"create", "part:1", "complete"}
	if got := strings.Join(rt.ops, ","); got != strings.Join(want, ",") {
		t.Errorf("ops = %v, want %v", rt.ops, want)
	}
}

func TestPutLargeZeroByteUploadsOneEmptyPart(t *testing.T) {
	// A zero-byte body must still emit exactly one (empty) part — S3 rejects a
	// complete with no parts.
	rt := &multipartTransport{}
	c := newMultipartClient(t, rt)
	if err := c.PutLarge(context.Background(), "b", "k", strings.NewReader("")); err != nil {
		t.Fatalf("PutLarge empty: %v", err)
	}
	want := []string{"create", "part:1", "complete"}
	if got := strings.Join(rt.ops, ","); got != strings.Join(want, ",") {
		t.Errorf("ops = %v, want %v", rt.ops, want)
	}
}

func TestPutLargeAbortsOnPartFailure(t *testing.T) {
	rt := &multipartTransport{failPart: true}
	c := newMultipartClient(t, rt)
	err := c.PutLarge(context.Background(), "b", "k", strings.NewReader("data"))
	if err == nil {
		t.Fatal("expected an error when UploadPart fails")
	}
	// The half-finished multipart must be aborted so it doesn't accrue storage.
	var aborted bool
	for _, op := range rt.ops {
		if op == "abort" {
			aborted = true
		}
	}
	if !aborted {
		t.Errorf("upload was not aborted after a part failure; ops = %v", rt.ops)
	}
}

func TestPutLargeChunksIntoMultipleParts(t *testing.T) {
	// Shrink the chunk so a tiny body still spans several parts (exercises the
	// PartNumber increment + the ReadFull/ErrUnexpectedEOF tail without 64 MiB).
	orig := partSize
	partSize = 4
	defer func() { partSize = orig }()

	rt := &multipartTransport{}
	c := newMultipartClient(t, rt)
	if err := c.PutLarge(context.Background(), "b", "k", strings.NewReader("abcdefghij")); err != nil { // 10 bytes / 4 → 3 parts
		t.Fatalf("PutLarge: %v", err)
	}
	want := []string{"create", "part:1", "part:2", "part:3", "complete"}
	if got := strings.Join(rt.ops, ","); got != strings.Join(want, ",") {
		t.Errorf("ops = %v, want %v", rt.ops, want)
	}
}
