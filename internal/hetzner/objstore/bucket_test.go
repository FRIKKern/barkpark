package objstore

// bucket_test.go covers the PR4 bucket surface (CreateBucket / ListBuckets /
// DeleteBucket) with the same recording-transport pattern as client_test.go:
// every assertion reads the REAL wire request the SDK built — method, host,
// path, SigV4 — without any request ever dialing.

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// TestCreateBucket asserts CreateBucket issues PUT to the virtual-hosted
// bucket root with a SigV4 signature.
func TestCreateBucket(t *testing.T) {
	rt := &recordingTransport{body: ""}
	c, err := NewClient("fsn1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if err := c.CreateBucket(context.Background(), "backups"); err != nil {
		t.Fatalf("CreateBucket: %v", err)
	}
	if len(rt.reqs) != 1 {
		t.Fatalf("CreateBucket issued %d requests, want 1", len(rt.reqs))
	}
	req := rt.reqs[0]
	if req.Method != http.MethodPut {
		t.Errorf("CreateBucket method = %s, want PUT", req.Method)
	}
	if got, want := req.URL.Host, "backups.fsn1.your-objectstorage.com"; got != want {
		t.Errorf("CreateBucket host = %q, want virtual-hosted %q", got, want)
	}
	if req.URL.Path != "/" && req.URL.Path != "" {
		t.Errorf("CreateBucket path = %q, want the bucket root", req.URL.Path)
	}
	if auth := req.Header.Get("Authorization"); !strings.Contains(auth, "AWS4-HMAC-SHA256") || !strings.Contains(auth, "AK/") {
		t.Errorf("Authorization %q is not a SigV4 signature with the static key", auth)
	}
}

// TestDeleteBucket asserts DELETE against the virtual-hosted bucket root.
func TestDeleteBucket(t *testing.T) {
	rt := &recordingTransport{body: ""}
	c, err := NewClient("hel1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if err := c.DeleteBucket(context.Background(), "old-media"); err != nil {
		t.Fatalf("DeleteBucket: %v", err)
	}
	if len(rt.reqs) != 1 {
		t.Fatalf("DeleteBucket issued %d requests, want 1", len(rt.reqs))
	}
	req := rt.reqs[0]
	if req.Method != http.MethodDelete {
		t.Errorf("DeleteBucket method = %s, want DELETE", req.Method)
	}
	if got, want := req.URL.Host, "old-media.hel1.your-objectstorage.com"; got != want {
		t.Errorf("DeleteBucket host = %q, want %q", got, want)
	}
}

// TestListBuckets asserts GET against the BARE (bucket-less) endpoint and that
// the XML listing parses into names + creation times.
func TestListBuckets(t *testing.T) {
	rt := &recordingTransport{body: `<?xml version="1.0" encoding="UTF-8"?>
<ListAllMyBucketsResult>
  <Owner><ID>ceph</ID></Owner>
  <Buckets>
    <Bucket><Name>backups</Name><CreationDate>2026-06-01T10:00:00.000Z</CreationDate></Bucket>
    <Bucket><Name>media</Name><CreationDate>2026-06-15T08:30:00.000Z</CreationDate></Bucket>
  </Buckets>
</ListAllMyBucketsResult>`}
	c, err := NewClient("nbg1", "AK", "SK", WithHTTPClient(&http.Client{Transport: rt}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	buckets, err := c.ListBuckets(context.Background())
	if err != nil {
		t.Fatalf("ListBuckets: %v", err)
	}
	if len(rt.reqs) != 1 {
		t.Fatalf("ListBuckets issued %d requests, want 1", len(rt.reqs))
	}
	req := rt.reqs[0]
	if req.Method != http.MethodGet {
		t.Errorf("ListBuckets method = %s, want GET", req.Method)
	}
	if got, want := req.URL.Host, "nbg1.your-objectstorage.com"; got != want {
		t.Errorf("ListBuckets host = %q, want the bare endpoint %q (no bucket subdomain)", got, want)
	}
	if len(buckets) != 2 || buckets[0].Name != "backups" || buckets[1].Name != "media" {
		t.Fatalf("ListBuckets = %+v, want backups + media", buckets)
	}
	if buckets[0].Created.IsZero() || buckets[0].Created.UTC().Format("2006-01-02") != "2026-06-01" {
		t.Errorf("backups Created = %v, want 2026-06-01", buckets[0].Created)
	}
}
