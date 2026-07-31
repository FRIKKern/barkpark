package objstore

import (
	"context"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// recordingTransport captures every request the SDK builds and answers with a
// canned response — no dial, no DNS, no creds ever leave the process. This is
// how the tests observe the REAL wire shape (host, path, auth header) without
// a live bucket.
type recordingTransport struct {
	reqs []*http.Request
	body string
}

func (rt *recordingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	rt.reqs = append(rt.reqs, req)
	return &http.Response{
		StatusCode: 200,
		Header:     http.Header{"Content-Type": []string{"application/xml"}},
		Body:       io.NopCloser(strings.NewReader(rt.body)),
		Request:    req,
	}, nil
}

// TestNewClientEndpoint asserts the derived endpoint string for each Hetzner
// location and that construction needs no network.
func TestNewClientEndpoint(t *testing.T) {
	for _, loc := range []string{"fsn1", "nbg1", "hel1"} {
		c, err := NewClient(loc, "AK", "SK")
		if err != nil {
			t.Fatalf("NewClient(%s): %v", loc, err)
		}
		want := "https://" + loc + ".your-objectstorage.com"
		if c.BaseEndpoint() != want {
			t.Errorf("BaseEndpoint(%s) = %q, want %q", loc, c.BaseEndpoint(), want)
		}
	}
	if _, err := NewClient("", "AK", "SK"); err == nil {
		t.Error("NewClient with an empty location did not error")
	}
}

// TestVirtualHostedAddressing asserts UsePathStyle=false end-to-end: a request
// against bucket "backups" must address backups.<location-host> (Hetzner's
// default), NOT <host>/backups.
func TestVirtualHostedAddressing(t *testing.T) {
	rt := &recordingTransport{body: `<?xml version="1.0"?><ListBucketResult><Name>backups</Name><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>`}
	c, err := NewClient("fsn1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	if _, err := c.ListObjects(context.Background(), "backups", "db/"); err != nil {
		t.Fatalf("ListObjects: %v", err)
	}
	if len(rt.reqs) == 0 {
		t.Fatal("no request was built")
	}
	req := rt.reqs[0]
	if got, want := req.URL.Host, "backups.fsn1.your-objectstorage.com"; got != want {
		t.Errorf("request host = %q, want virtual-hosted %q", got, want)
	}
	if req.URL.Path == "/backups" || strings.HasPrefix(req.URL.Path, "/backups/") {
		t.Errorf("request path %q is path-style; want the bucket on the host", req.URL.Path)
	}
	if got := req.URL.Query().Get("prefix"); got != "db/" {
		t.Errorf("prefix = %q, want db/", got)
	}
	// SigV4 actually signed with the static creds.
	if auth := req.Header.Get("Authorization"); !strings.Contains(auth, "AWS4-HMAC-SHA256") || !strings.Contains(auth, "AK/") {
		t.Errorf("Authorization %q is not a SigV4 signature with the static key", auth)
	}
}

// TestPresignGetObject asserts a presigned URL points at the virtual-hosted
// object and carries the SigV4 query auth — all offline.
func TestPresignGetObject(t *testing.T) {
	c, err := NewClient("nbg1", "AK", "SK")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	url, err := c.PresignGetObject(context.Background(), "backups", "db/2026-07-01.sql.gz", 15*time.Minute)
	if err != nil {
		t.Fatalf("PresignGetObject: %v", err)
	}
	if !strings.HasPrefix(url, "https://backups.nbg1.your-objectstorage.com/db/2026-07-01.sql.gz") {
		t.Errorf("presigned url %q does not address the virtual-hosted object", url)
	}
	for _, param := range []string{"X-Amz-Signature=", "X-Amz-Expires=900", "X-Amz-Credential=AK"} {
		if !strings.Contains(url, param) {
			t.Errorf("presigned url %q lacks %s", url, param)
		}
	}
}

// sizedTransport answers a GET with `body` while DECLARING contentLength on the
// response — the two are decoupled on purpose, so a test can reproduce the case
// this whole leg exists for: an endpoint that promises N bytes and sends fewer.
// declare=false leaves the length absent entirely (the S3-COMPATIBLE-not-S3
// case Hetzner may hand us).
type sizedTransport struct {
	body    string
	declare bool
	length  int64
}

func (t *sizedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp := &http.Response{
		StatusCode:    200,
		Header:        http.Header{},
		Body:          io.NopCloser(strings.NewReader(t.body)),
		Request:       req,
		ContentLength: -1,
	}
	if t.declare {
		resp.ContentLength = t.length
		resp.Header.Set("Content-Length", strconv.FormatInt(t.length, 10))
	}
	return resp, nil
}

// TestGetObjectSizedReportsTheDeclaredLength: the length rides the SAME GET
// response the caller already makes — no HeadObject, no Range probe, ONE
// request — and it is the endpoint's declaration, not a count of bytes read.
func TestGetObjectSizedReportsTheDeclaredLength(t *testing.T) {
	rt := &sizedTransport{body: "SHORT", declare: true, length: 4096}
	c, err := NewClient("fsn1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	rc, size, err := c.GetObjectSized(context.Background(), "backups", "db/x.sql.gz")
	if err != nil {
		t.Fatalf("GetObjectSized: %v", err)
	}
	defer rc.Close()
	if size != 4096 {
		t.Errorf("declared size = %d, want the endpoint's 4096 (NOT the 5 bytes actually sent)", size)
	}
	b, _ := io.ReadAll(rc)
	if string(b) != "SHORT" {
		t.Errorf("body = %q, want the (short) bytes verbatim", b)
	}
}

// TestGetObjectSizedAbsentLengthIsNotAZero: nothing declared must be
// DISTINGUISHABLE from a declared length, because the caller reports the first
// as unverified and must never read it as a length it checked against.
func TestGetObjectSizedAbsentLengthIsNotAZero(t *testing.T) {
	rt := &sizedTransport{body: "bytes-with-no-declaration", declare: false}
	c, err := NewClient("fsn1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	rc, size, err := c.GetObjectSized(context.Background(), "backups", "k")
	if err != nil {
		t.Fatalf("GetObjectSized: %v", err)
	}
	defer rc.Close()
	if size > 0 {
		t.Errorf("undeclared length reported as %d, want <= 0 so the caller reports it unverified", size)
	}
}

// TestGetObjectStillReturnsTwoValues pins the ADDITIVE choice: GetObject keeps
// its (io.ReadCloser, error) shape, so cloud.BundleStore, backup.ObjStore and
// every fake implementing them stay untouched. Widening it stops this
// compiling — which is exactly the tripwire wanted.
func TestGetObjectStillReturnsTwoValues(t *testing.T) {
	rt := &sizedTransport{body: "ok", declare: true, length: 2}
	c, err := NewClient("fsn1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	var get func(context.Context, string, string) (io.ReadCloser, error) = c.GetObject
	rc, err := get(context.Background(), "b", "k")
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	defer rc.Close()
}
