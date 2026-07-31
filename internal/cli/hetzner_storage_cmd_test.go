package cli

// hetzner_storage_cmd_test.go drives `bp cloud hetzner storage …` through a
// recording fake S3 transport — the objstore client stays REAL (SigV4 signing,
// virtual-hosted addressing, the SDK's wire encoding), only the network is
// faked, so every assertion reads the actual S3 request bp would send.

import (
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// TestHzDuration pins the retention-window parser feeding the destructive
// `backup prune` path: the `d`-day suffix must consume the WHOLE string (no
// silent 30d30d/30xd truncation) and reject inf/nan, while the non-suffix
// branch stays plain time.ParseDuration.
func TestHzDuration(t *testing.T) {
	ok := []struct {
		in   string
		want time.Duration
	}{
		{"30d", 720 * time.Hour},
		{"12h", 12 * time.Hour},
		{"90m", 90 * time.Minute},
	}
	for _, tc := range ok {
		got, err := hzDuration(tc.in)
		if err != nil {
			t.Errorf("hzDuration(%q) unexpected error: %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("hzDuration(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
	for _, in := range []string{"30d30d", "30xd", "infd", "nand", "-5d", "30d "} {
		if _, err := hzDuration(in); err == nil {
			t.Errorf("hzDuration(%q) accepted a malformed value, want error", in)
		}
	}
}

// s3Req is one recorded S3 request: everything an assertion needs to prove
// the wire shape.
type s3Req struct {
	Method string
	Host   string
	Path   string
	Query  url.Values
	Body   []byte
	Auth   string
}

// fakeS3 is the recording RoundTripper. handler (optional) picks the response
// per request; the default is 200 with an empty body. Every response carries
// an ETag so the multipart UploadPart path completes.
// declaredLen (optional) makes the response DECLARE a Content-Length that is
// decoupled from the body it actually sends — the only way to reproduce, in a
// test, an endpoint that promises N bytes and hangs up early. Left nil, nothing
// is declared, which is Hetzner's S3-compatible-not-S3 worst case.
type fakeS3 struct {
	mu          sync.Mutex
	reqs        []s3Req
	handler     func(r s3Req) (int, string)
	declaredLen *int64
}

func (f *fakeS3) RoundTrip(req *http.Request) (*http.Response, error) {
	var body []byte
	if req.Body != nil {
		body, _ = io.ReadAll(req.Body)
		req.Body.Close()
	}
	rec := s3Req{
		Method: req.Method,
		Host:   req.URL.Host,
		Path:   req.URL.Path,
		Query:  req.URL.Query(),
		Body:   body,
		Auth:   req.Header.Get("Authorization"),
	}
	f.mu.Lock()
	f.reqs = append(f.reqs, rec)
	f.mu.Unlock()

	status, respBody := 200, ""
	if f.handler != nil {
		status, respBody = f.handler(rec)
	}
	resp := &http.Response{
		StatusCode: status,
		Header: http.Header{
			"Content-Type": []string{"application/xml"},
			"Etag":         []string{`"fake-etag"`},
		},
		Body:          io.NopCloser(strings.NewReader(respBody)),
		Request:       req,
		ContentLength: -1,
	}
	if f.declaredLen != nil && req.Method == http.MethodGet {
		resp.ContentLength = *f.declaredLen
		resp.Header.Set("Content-Length", strconv.FormatInt(*f.declaredLen, 10))
	}
	return resp, nil
}

func (f *fakeS3) requests() []s3Req {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]s3Req(nil), f.reqs...)
}

func (f *fakeS3) find(method, path string) (s3Req, bool) {
	for _, r := range f.requests() {
		if r.Method == method && r.Path == path {
			return r, true
		}
	}
	return s3Req{}, false
}

// withFakeS3 points the storage/backup client seam at the fake transport; the
// client itself — signing, addressing, XML — stays real.
func withFakeS3(t *testing.T, f *fakeS3) {
	t.Helper()
	old := newObjstoreClient
	newObjstoreClient = func(location, accessKey, secretKey string) (*objstore.Client, error) {
		return objstore.NewClient(location, accessKey, secretKey,
			objstore.WithHTTPClient(&http.Client{Transport: f}))
	}
	t.Cleanup(func() { newObjstoreClient = old })
}

// multipartS3 answers the multipart conversation (initiate → parts → complete)
// and records the part bodies in order, so a test can reassemble exactly what
// was uploaded.
func multipartS3() (*fakeS3, *[][]byte) {
	parts := &[][]byte{}
	f := &fakeS3{}
	f.handler = func(r s3Req) (int, string) {
		switch {
		case r.Method == "POST" && r.Query.Has("uploads"):
			return 200, `<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>`
		case r.Method == "PUT" && r.Query.Get("partNumber") != "":
			*parts = append(*parts, r.Body)
			return 200, ""
		case r.Method == "POST" && r.Query.Get("uploadId") != "":
			return 200, `<?xml version="1.0"?><CompleteMultipartUploadResult><ETag>"fake-etag"</ETag></CompleteMultipartUploadResult>`
		case r.Method == "DELETE":
			return 204, ""
		}
		return 200, ""
	}
	return f, parts
}

// s3CredArgs are the flag-based credentials every test passes so nothing leans
// on the developer's environment.
var s3CredArgs = []string{"--s3-access-key", "AKTEST", "--s3-secret-key", "SKTEST"}

func storageArgs(args ...string) []string {
	return append(args, s3CredArgs...)
}

// TestHetznerStorageBucketCreate asserts the virtual-hosted PUT, the SigV4
// signature and the structured receipt.
func TestHetznerStorageBucketCreate(t *testing.T) {
	f := &fakeS3{}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "bucket", "create", "--name", "barkpark-backups", "--location", "nbg1")...)
	if code != exitOK {
		t.Fatalf("bucket create exited %d, stderr: %s", code, stderr)
	}
	if len(f.requests()) != 1 {
		t.Fatalf("bucket create issued %d requests, want 1", len(f.requests()))
	}
	req := f.requests()[0]
	if req.Method != "PUT" {
		t.Errorf("method = %s, want PUT", req.Method)
	}
	if want := "barkpark-backups.nbg1.your-objectstorage.com"; req.Host != want {
		t.Errorf("host = %q, want virtual-hosted %q (honouring --location)", req.Host, want)
	}
	if !strings.Contains(req.Auth, "AWS4-HMAC-SHA256") || !strings.Contains(req.Auth, "AKTEST/") {
		t.Errorf("Authorization %q is not SigV4 with the flag credentials", req.Auth)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	bucket, _ := payload["bucket"].(map[string]any)
	if payload["ok"] != true || payload["action"] != "create" || bucket["name"] != "barkpark-backups" || payload["location"] != "nbg1" {
		t.Errorf("receipt = %v, want ok/create/barkpark-backups/nbg1", payload)
	}
}

// TestHetznerStorageBucketGet asserts get looks the bucket up in ListBuckets,
// reports name/location/created, and 404s (exitNotFound) on an unknown name.
func TestHetznerStorageBucketGet(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "GET" {
			return 200, `<?xml version="1.0"?><ListAllMyBucketsResult><Buckets>
				<Bucket><Name>backups</Name><CreationDate>2026-06-01T10:00:00.000Z</CreationDate></Bucket>
				<Bucket><Name>media</Name><CreationDate>2026-06-15T08:30:00.000Z</CreationDate></Bucket>
			</Buckets></ListAllMyBucketsResult>`
		}
		return 204, ""
	}}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "bucket", "get", "--name", "media", "--location", "nbg1")...)
	if code != exitOK {
		t.Fatalf("bucket get exited %d, stderr: %s", code, stderr)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("bucket get output is not JSON: %v\n%s", err, stdout)
	}
	bucket, _ := payload["bucket"].(map[string]any)
	if bucket["name"] != "media" || bucket["location"] != "nbg1" || bucket["created"] != "2026-06-15T08:30:00Z" {
		t.Errorf("bucket = %v, want media @ nbg1 created 2026-06-15T08:30:00Z", payload["bucket"])
	}

	_, stderr, code = runHzCLI(t, "table", storageArgs("hetzner", "storage", "bucket", "get", "--name", "ghost")...)
	if code != exitNotFound {
		t.Fatalf("get of a missing bucket exited %d, want exitNotFound (%d); stderr: %s", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "not found") {
		t.Errorf("stderr = %q, want a not-found message", stderr)
	}
}

// TestHetznerStorageBucketListAndDelete asserts list parses the XML into rows
// (bare endpoint, no bucket subdomain) and delete issues DELETE.
func TestHetznerStorageBucketListAndDelete(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "GET" {
			return 200, `<?xml version="1.0"?><ListAllMyBucketsResult><Buckets>
				<Bucket><Name>backups</Name><CreationDate>2026-06-01T10:00:00.000Z</CreationDate></Bucket>
				<Bucket><Name>media</Name><CreationDate>2026-06-15T08:30:00.000Z</CreationDate></Bucket>
			</Buckets></ListAllMyBucketsResult>`
		}
		return 204, ""
	}}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "bucket", "list")...)
	if code != exitOK {
		t.Fatalf("bucket list exited %d, stderr: %s", code, stderr)
	}
	if req := f.requests()[0]; req.Host != "fsn1.your-objectstorage.com" {
		t.Errorf("list host = %q, want the bare default-location endpoint", req.Host)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, stdout)
	}
	buckets, _ := payload["buckets"].([]any)
	if len(buckets) != 2 {
		t.Fatalf("buckets = %v, want 2 rows", payload)
	}
	first, _ := buckets[0].(map[string]any)
	if first["name"] != "backups" || first["created"] != "2026-06-01T10:00:00Z" {
		t.Errorf("first bucket = %v, want backups @ 2026-06-01T10:00:00Z", first)
	}

	_, stderr, code = runHzCLI(t, "table", storageArgs("hetzner", "storage", "bucket", "delete", "--name", "media")...)
	if code != exitOK {
		t.Fatalf("bucket delete exited %d, stderr: %s", code, stderr)
	}
	// The DELETE is no longer the LAST request: a destroy now re-reads (the
	// declared non-binding ListBuckets) before it claims anything, so this looks
	// the DELETE up by shape instead of by position.
	var del s3Req
	for _, r := range f.requests() {
		if r.Method == "DELETE" {
			del = r
		}
	}
	if del.Method != "DELETE" || del.Host != "media.fsn1.your-objectstorage.com" {
		t.Errorf("delete = %s %s, want DELETE on media.fsn1…", del.Method, del.Host)
	}
}

// TestHetznerStorageObjectPutFile asserts the single-request PUT carries the
// file's exact bytes to the virtual-hosted key.
func TestHetznerStorageObjectPutFile(t *testing.T) {
	f := &fakeS3{}
	withFakeS3(t, f)
	content := "the exact payload bytes\n"
	path := filepath.Join(t.TempDir(), "payload.txt")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "put", "--bucket", "bkt", "--key", "dir/payload.txt", "--file", path)...)
	if code != exitOK {
		t.Fatalf("object put exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("PUT", "/dir/payload.txt")
	if !ok {
		t.Fatalf("no PUT /dir/payload.txt was issued; got %+v", f.requests())
	}
	if req.Host != "bkt.fsn1.your-objectstorage.com" {
		t.Errorf("put host = %q, want bk.fsn1…", req.Host)
	}
	if string(req.Body) != content {
		t.Errorf("put body = %q, want the file's bytes %q", req.Body, content)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not JSON: %v\n%s", err, stdout)
	}
	if payload["ok"] != true || payload["action"] != "put" || payload["bytes"] != float64(len(content)) {
		t.Errorf("receipt = %v, want ok/put/bytes=%d", payload, len(content))
	}
}

// TestHetznerStorageObjectPutStdin asserts the trailing `-` streams stdin via
// the MULTIPART path and the uploaded parts reassemble to the input bytes.
func TestHetznerStorageObjectPutStdin(t *testing.T) {
	f, parts := multipartS3()
	withFakeS3(t, f)
	oldStdin := storageStdin
	storageStdin = strings.NewReader("streamed via stdin")
	t.Cleanup(func() { storageStdin = oldStdin })

	_, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "put", "--bucket", "bkt", "--key", "stream.bin", "-")...)
	if code != exitOK {
		t.Fatalf("object put - exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("POST", "/stream.bin"); !ok {
		t.Fatal("stdin put never initiated a multipart upload")
	}
	var joined []byte
	for _, p := range *parts {
		joined = append(joined, p...)
	}
	if string(joined) != "streamed via stdin" {
		t.Errorf("multipart parts reassemble to %q, want the stdin bytes", joined)
	}
}

// TestHetznerStorageObjectGetAndRm asserts get streams the RAW body to stdout
// (pipe-friendly, no envelope) and rm issues DELETE on the key.
func TestHetznerStorageObjectGetAndRm(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		if r.Method == "GET" {
			return 200, "raw object bytes — no envelope"
		}
		return 204, ""
	}}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "table", storageArgs("hetzner", "storage", "object", "get", "--bucket", "bkt", "--key", "a/b.txt")...)
	if code != exitOK {
		t.Fatalf("object get exited %d, stderr: %s", code, stderr)
	}
	if stdout != "raw object bytes — no envelope" {
		t.Errorf("get stdout = %q, want the raw body with nothing appended", stdout)
	}
	if req, ok := f.find("GET", "/a/b.txt"); !ok || req.Host != "bkt.fsn1.your-objectstorage.com" {
		t.Errorf("get request = %+v, want GET bk.fsn1…/a/b.txt", req)
	}

	_, stderr, code = runHzCLI(t, "table", storageArgs("hetzner", "storage", "object", "rm", "--bucket", "bkt", "--key", "a/b.txt")...)
	if code != exitOK {
		t.Fatalf("object rm exited %d, stderr: %s", code, stderr)
	}
	if req, ok := f.find("DELETE", "/a/b.txt"); !ok || req.Host != "bkt.fsn1.your-objectstorage.com" {
		t.Errorf("rm request = %+v, want DELETE bk.fsn1…/a/b.txt", req)
	}
}

// hzGetJSON runs `object get --out <path>` against f and returns the decoded
// receipt, so the size verdict is read as data rather than scraped from prose.
func hzGetJSON(t *testing.T, outPath string) (map[string]any, string, int) {
	t.Helper()
	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "get", "--bucket", "bkt", "--key", "a/b.txt", "--out", outPath)...)
	payload := map[string]any{}
	if code == exitOK {
		if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
			t.Fatalf("get receipt is not JSON: %v\n%s", err, stdout)
		}
	}
	return payload, stderr, code
}

// TestHetznerStorageObjectGetVerifiesDeclaredLength: the receipt's byte count
// is CHECKED against the length the endpoint declared in the same response, and
// says so. Before this, `bytes` was io.Copy's own counter echoed back — a number
// that agreed with itself no matter what arrived.
func TestHetznerStorageObjectGetVerifiesDeclaredLength(t *testing.T) {
	body := "exactly-these-bytes"
	n := int64(len(body))
	f := &fakeS3{
		handler:     func(r s3Req) (int, string) { return 200, body },
		declaredLen: &n,
	}
	withFakeS3(t, f)

	outPath := filepath.Join(t.TempDir(), "obj.bin")
	payload, stderr, code := hzGetJSON(t, outPath)
	if code != exitOK {
		t.Fatalf("get exited %d, stderr: %s", code, stderr)
	}
	if payload["bytes"] != float64(n) || payload["declared_bytes"] != float64(n) {
		t.Errorf("receipt = %v, want bytes and declared_bytes both %d", payload, n)
	}
	if payload["size_verified"] != true || payload["unverified"] != float64(0) {
		t.Errorf("receipt = %v, want size_verified true with a zero unverified counter", payload)
	}
	got, rerr := os.ReadFile(outPath)
	if rerr != nil || string(got) != body {
		t.Errorf("file = %q (%v), want the object's bytes", got, rerr)
	}
}

// TestHetznerStorageObjectGetShortBodyIsNotSuccess is the mutation this whole
// leg exists for: the endpoint DECLARES 4096 bytes and sends nine. The verb must
// not exit 0, must NAME the mismatch — and must leave the operator's
// pre-existing file byte-identical, because it now writes to a temp beside the
// destination instead of truncating it before the first byte arrives.
func TestHetznerStorageObjectGetShortBodyIsNotSuccess(t *testing.T) {
	declared := int64(4096)
	f := &fakeS3{
		handler:     func(r s3Req) (int, string) { return 200, "TRUNCATED" },
		declaredLen: &declared,
	}
	withFakeS3(t, f)

	dir := t.TempDir()
	outPath := filepath.Join(dir, "yesterdays-good-backup.tar.gz")
	if err := os.WriteFile(outPath, []byte("THE OPERATOR'S GOOD COPY"), 0o644); err != nil {
		t.Fatalf("seed pre-existing file: %v", err)
	}
	before := sha256.Sum256([]byte("THE OPERATOR'S GOOD COPY"))

	stdout, stderr, code := runHzCLI(t, "table", storageArgs("hetzner", "storage", "object", "get", "--bucket", "bkt", "--key", "a/b.txt", "--out", outPath)...)
	if code == exitOK {
		t.Fatalf("a short body exited 0\nstdout: %s\nstderr: %s", stdout, stderr)
	}
	said := stdout + stderr
	if !strings.Contains(said, "size mismatch") || !strings.Contains(said, "4096") || !strings.Contains(said, "wrote 9") {
		t.Errorf("failure must name the mismatch and both numbers:\n%s", said)
	}
	after, rerr := os.ReadFile(outPath)
	if rerr != nil {
		t.Fatalf("the pre-existing file is gone: %v", rerr)
	}
	if sha256.Sum256(after) != before {
		t.Errorf("the pre-existing file changed: %q", after)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("temp litter left behind: %v", entries)
	}
}

// TestHetznerStorageObjectGetUndeclaredLengthIsUnverified: Hetzner is
// S3-COMPATIBLE, not S3. When no length comes back there is nothing to check
// against, and the receipt says exactly that — with its own counter — instead of
// reporting a verification it never performed.
func TestHetznerStorageObjectGetUndeclaredLengthIsUnverified(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) { return 200, "some bytes" }} // declaredLen nil
	withFakeS3(t, f)

	outPath := filepath.Join(t.TempDir(), "obj.bin")
	payload, stderr, code := hzGetJSON(t, outPath)
	if code != exitOK {
		t.Fatalf("an undeclared length must still transfer, exited %d: %s", code, stderr)
	}
	if payload["size_verified"] != false || payload["unverified"] != float64(1) {
		t.Errorf("receipt = %v, want size_verified false with unverified=1", payload)
	}
	if _, ok := payload["declared_bytes"]; ok {
		t.Errorf("receipt = %v, must not invent a declared_bytes it never received", payload)
	}
	if reason, _ := payload["unverified_reason"].(string); !strings.Contains(reason, "declared no object length") {
		t.Errorf("receipt = %v, want a stated reason", payload)
	}
}

// TestHetznerStorageObjectList asserts the prefix rides the query and the XML
// listing lands in structured rows.
func TestHetznerStorageObjectList(t *testing.T) {
	f := &fakeS3{handler: func(r s3Req) (int, string) {
		return 200, `<?xml version="1.0"?><ListBucketResult><Name>bk</Name><KeyCount>1</KeyCount><IsTruncated>false</IsTruncated>
			<Contents><Key>prod/a.sql.gz</Key><Size>123</Size><LastModified>2026-07-01T00:00:00.000Z</LastModified></Contents>
		</ListBucketResult>`
	}}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "list", "--bucket", "bkt", "--prefix", "prod/")...)
	if code != exitOK {
		t.Fatalf("object list exited %d, stderr: %s", code, stderr)
	}
	if req := f.requests()[0]; req.Query.Get("prefix") != "prod/" {
		t.Errorf("list prefix = %q, want prod/", req.Query.Get("prefix"))
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, stdout)
	}
	objects, _ := payload["objects"].([]any)
	if len(objects) != 1 {
		t.Fatalf("objects = %v, want 1 row", payload)
	}
	row, _ := objects[0].(map[string]any)
	if row["key"] != "prod/a.sql.gz" || row["size"] != float64(123) {
		t.Errorf("row = %v, want key=prod/a.sql.gz size=123", row)
	}
}

// TestHetznerStorageObjectPresign asserts the printed URL is the virtual-
// hosted object with SigV4 query auth and the requested expiry — no request
// is ever sent.
func TestHetznerStorageObjectPresign(t *testing.T) {
	f := &fakeS3{}
	withFakeS3(t, f)

	stdout, stderr, code := runHzCLI(t, "table", storageArgs("hetzner", "storage", "object", "presign", "--bucket", "bkt", "--key", "share.pdf", "--expires", "2h")...)
	if code != exitOK {
		t.Fatalf("presign exited %d, stderr: %s", code, stderr)
	}
	urlLine := strings.TrimSpace(stdout)
	if !strings.HasPrefix(urlLine, "https://bkt.fsn1.your-objectstorage.com/share.pdf") {
		t.Errorf("presign url = %q, want the virtual-hosted object", urlLine)
	}
	for _, param := range []string{"X-Amz-Signature=", "X-Amz-Expires=7200", "X-Amz-Credential=AKTEST"} {
		if !strings.Contains(urlLine, param) {
			t.Errorf("presign url %q lacks %s", urlLine, param)
		}
	}
	if len(f.requests()) != 0 {
		t.Errorf("presign sent %d requests, want 0", len(f.requests()))
	}
}

// TestHetznerStorageNoCredentials: without flags or env the command refuses
// with exitAuth and points at the Console (the only place credentials exist).
func TestHetznerStorageNoCredentials(t *testing.T) {
	withFakeS3(t, &fakeS3{})
	t.Setenv("HETZNER_S3_ACCESS_KEY", "")
	t.Setenv("HETZNER_S3_SECRET_KEY", "")

	_, stderr, code := runHzCLI(t, "table", "hetzner", "storage", "bucket", "list")
	if code != exitAuth {
		t.Fatalf("no-credentials exited %d, want exitAuth (%d)", code, exitAuth)
	}
	for _, want := range []string{"HETZNER_S3_ACCESS_KEY", "Hetzner Console", "no API"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("no-credentials error %q lacks %q", stderr, want)
		}
	}
}

// TestHetznerStorageHelpDocumentsConsoleGate: the storage help must spell out
// that S3 credentials (and product activation) exist ONLY via the Hetzner
// Console — there is no API — and that the secret is shown once.
func TestHetznerStorageHelpDocumentsConsoleGate(t *testing.T) {
	stdout, _, _ := runHzCLI(t, "table", "hetzner", "storage", "help")
	for _, want := range []string{
		"NO API to create S3 credentials",
		"Hetzner",
		"Console",
		"SECRET KEY is shown",
		"exactly once",
		"CreateBucket",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("storage help lacks the console-gate phrase %q\n%s", want, stdout)
		}
	}
}
