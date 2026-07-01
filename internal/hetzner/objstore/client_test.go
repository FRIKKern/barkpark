package objstore

import (
	"context"
	"io"
	"net/http"
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
