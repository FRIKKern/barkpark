package cli

// hetzner_storage_cmd_test.go drives `bp cloud hetzner storage …` through a
// recording fake S3 transport — the objstore client stays REAL (SigV4 signing,
// virtual-hosted addressing, the SDK's wire encoding), only the network is
// faked, so every assertion reads the actual S3 request bp would send.

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

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

// fakeS3 is the recording RoundTripper AND a minimal in-memory S3. It FAILS
// CLOSED: a request the in-memory store cannot serve comes back as an S3-shaped
// error, never as the old 200-with-an-empty-body, so a post-read against this
// fake can actually prove something. HeadObject on a key nothing stored surfaces
// as *types.NotFound — the error a real absent object produces.
//
// handler (optional) still gets first refusal on every request, for the few
// wire shapes a test wants to script by hand; returning status 0 defers to the
// in-memory engine. Every response carries an ETag so the multipart UploadPart
// path completes.
// declaredLen (optional) makes the response DECLARE a Content-Length that is
// decoupled from the body it actually sends — the only way to reproduce, in a
// test, an endpoint that promises N bytes and hangs up early. Left nil, nothing
// is declared, which is Hetzner's S3-compatible-not-S3 worst case.
// dropWrites is the silent-drop endpoint: it answers every write 200/OK and
// persists NOTHING, so a verb that trusts its own exit code passes while a verb
// that reads back fails.
type fakeS3 struct {
	mu          sync.Mutex
	reqs        []s3Req
	handler     func(r s3Req) (int, string)
	declaredLen *int64
	dropWrites  bool

	buckets map[string]time.Time
	objects map[string]fakeObject
	uploads map[string]map[int][]byte
	parts   [][]byte
	uploadN int
}

// fakeObject is one stored object: its bytes and the modification time the
// listing reports.
type fakeObject struct {
	body     []byte
	modified time.Time
}

const fakeS3Suffix = ".your-objectstorage.com"

// fakeSeedTime is the modification time seeded objects carry unless a test asks
// for a specific one — deterministic so listings never depend on the clock.
var fakeSeedTime = time.Date(2026, 6, 1, 0, 0, 1, 0, time.UTC)

// newFakeS3 is the seeding constructor. The zero value `&fakeS3{}` stays valid
// (an empty store), so every existing construction keeps working.
func newFakeS3() *fakeS3 { return &fakeS3{} }

// init lazily allocates the store. Callers hold f.mu.
func (f *fakeS3) init() {
	if f.buckets == nil {
		f.buckets = map[string]time.Time{}
		f.objects = map[string]fakeObject{}
		f.uploads = map[string]map[int][]byte{}
	}
}

// seedBucket puts a bucket in the store with the creation date ListBuckets will
// report. created is RFC3339; empty means fakeSeedTime.
func (f *fakeS3) seedBucket(name, created string) *fakeS3 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.init()
	ts := fakeSeedTime
	if created != "" {
		parsed, err := time.Parse(time.RFC3339, created)
		if err != nil {
			panic("seedBucket: bad RFC3339 " + created + ": " + err.Error())
		}
		ts = parsed
	}
	f.buckets[name] = ts
	return f
}

// seedObject stores an object (creating its bucket) so GET/HEAD/list can serve
// it. modified is RFC3339; empty means fakeSeedTime.
func (f *fakeS3) seedObject(bucket, key, body, modified string) *fakeS3 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.init()
	ts := fakeSeedTime
	if modified != "" {
		parsed, err := time.Parse(time.RFC3339, modified)
		if err != nil {
			panic("seedObject: bad RFC3339 " + modified + ": " + err.Error())
		}
		ts = parsed
	}
	if _, ok := f.buckets[bucket]; !ok {
		f.buckets[bucket] = fakeSeedTime
	}
	f.objects[bucket+"/"+key] = fakeObject{body: []byte(body), modified: ts}
	return f
}

// stored reports whether a key is in the store — the post-read a test performs
// on the harness itself.
func (f *fakeS3) stored(bucket, key string) ([]byte, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.init()
	o, ok := f.objects[bucket+"/"+key]
	return o.body, ok
}

// hasBucket reports whether the store still holds a bucket.
func (f *fakeS3) hasBucket(name string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.init()
	_, ok := f.buckets[name]
	return ok
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

	status, respBody := 0, ""
	if f.handler != nil {
		status, respBody = f.handler(rec)
	}
	if status == 0 {
		status, respBody = f.serve(rec)
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

// fakeBucketOf reads the bucket out of a virtual-hosted host name; the bare
// location endpoint (no bucket subdomain) yields "".
func fakeBucketOf(host string) string {
	h := strings.TrimSuffix(host, fakeS3Suffix)
	if i := strings.Index(h, "."); i >= 0 {
		return h[:i]
	}
	return ""
}

// fakeS3Error renders an S3-shaped error document — the fail-closed answer.
func fakeS3Error(status int, code, message string) (int, string) {
	return status, `<?xml version="1.0" encoding="UTF-8"?><Error><Code>` + code +
		`</Code><Message>` + message + `</Message><RequestId>fake</RequestId></Error>`
}

// serve is the in-memory S3: PUT/GET/HEAD/DELETE object, create/delete/list
// bucket, ListObjectsV2 and the three-step multipart conversation. Anything it
// does not recognise is a 501, never a 200 — the whole point of the harness.
func (f *fakeS3) serve(r s3Req) (int, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.init()

	bucket := fakeBucketOf(r.Host)
	key := strings.TrimPrefix(r.Path, "/")

	if bucket == "" {
		if r.Method == "GET" && key == "" {
			return 200, f.listBucketsXML()
		}
		return fakeS3Error(501, "NotImplemented", "fakeS3 has no route for "+r.Method+" "+r.Host+r.Path)
	}

	if key == "" {
		switch {
		case r.Method == "PUT":
			f.buckets[bucket] = fakeSeedTime
			return 200, ""
		case r.Method == "DELETE":
			if _, ok := f.buckets[bucket]; !ok {
				return fakeS3Error(404, "NoSuchBucket", "no such bucket: "+bucket)
			}
			delete(f.buckets, bucket)
			return 204, ""
		case r.Method == "GET" && r.Query.Get("list-type") == "2":
			return 200, f.listObjectsXML(bucket, r.Query.Get("prefix"))
		}
		return fakeS3Error(501, "NotImplemented", "fakeS3 has no bucket route for "+r.Method+" "+r.Host+r.Path)
	}

	full := bucket + "/" + key
	switch {
	case r.Method == "POST" && r.Query.Has("uploads"):
		f.uploadN++
		id := "upload-" + strconv.Itoa(f.uploadN)
		f.uploads[id] = map[int][]byte{}
		return 200, `<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>` + bucket +
			`</Bucket><Key>` + key + `</Key><UploadId>` + id + `</UploadId></InitiateMultipartUploadResult>`

	case r.Method == "PUT" && r.Query.Get("partNumber") != "":
		id := r.Query.Get("uploadId")
		parts, ok := f.uploads[id]
		if !ok {
			return fakeS3Error(404, "NoSuchUpload", "no such upload: "+id)
		}
		n, err := strconv.Atoi(r.Query.Get("partNumber"))
		if err != nil {
			return fakeS3Error(400, "InvalidArgument", "bad partNumber "+r.Query.Get("partNumber"))
		}
		f.parts = append(f.parts, append([]byte(nil), r.Body...))
		if !f.dropWrites {
			parts[n] = append([]byte(nil), r.Body...)
		}
		return 200, ""

	case r.Method == "POST" && r.Query.Get("uploadId") != "":
		id := r.Query.Get("uploadId")
		parts, ok := f.uploads[id]
		if !ok {
			return fakeS3Error(404, "NoSuchUpload", "no such upload: "+id)
		}
		delete(f.uploads, id)
		nums := make([]int, 0, len(parts))
		for n := range parts {
			nums = append(nums, n)
		}
		sort.Ints(nums)
		var joined []byte
		for _, n := range nums {
			joined = append(joined, parts[n]...)
		}
		if !f.dropWrites {
			f.putLocked(full, joined)
		}
		return 200, `<?xml version="1.0"?><CompleteMultipartUploadResult><Bucket>` + bucket +
			`</Bucket><Key>` + key + `</Key><ETag>"fake-etag"</ETag></CompleteMultipartUploadResult>`

	case r.Method == "DELETE" && r.Query.Get("uploadId") != "":
		delete(f.uploads, r.Query.Get("uploadId"))
		return 204, ""

	case r.Method == "PUT":
		if !f.dropWrites {
			f.putLocked(full, r.Body)
		}
		return 200, ""

	case r.Method == "GET":
		o, ok := f.objects[full]
		if !ok {
			return fakeS3Error(404, "NoSuchKey", "no such key: "+key)
		}
		return 200, string(o.body)

	case r.Method == "HEAD":
		if _, ok := f.objects[full]; !ok {
			// A HEAD carries no body; the SDK maps the bare 404 to
			// *types.NotFound, which is what an absent object must look like.
			return 404, ""
		}
		return 200, ""

	case r.Method == "DELETE":
		// Real S3 answers 204 whether or not the key existed — the fake keeps
		// that, because pretending a delete can report absence is exactly the
		// lie a post-read exists to catch.
		delete(f.objects, full)
		return 204, ""
	}
	return fakeS3Error(501, "NotImplemented", "fakeS3 has no object route for "+r.Method+" "+r.Host+r.Path)
}

// putLocked stores body under full ("bucket/key"), registering the bucket.
// Callers hold f.mu.
func (f *fakeS3) putLocked(full string, body []byte) {
	if bucket, _, ok := strings.Cut(full, "/"); ok {
		if _, seen := f.buckets[bucket]; !seen {
			f.buckets[bucket] = fakeSeedTime
		}
	}
	f.objects[full] = fakeObject{body: append([]byte(nil), body...), modified: fakeSeedTime}
}

// listBucketsXML renders the store's buckets. Callers hold f.mu.
func (f *fakeS3) listBucketsXML() string {
	names := make([]string, 0, len(f.buckets))
	for name := range f.buckets {
		names = append(names, name)
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString(`<?xml version="1.0"?><ListAllMyBucketsResult><Buckets>`)
	for _, name := range names {
		b.WriteString(`<Bucket><Name>` + name + `</Name><CreationDate>` +
			f.buckets[name].UTC().Format("2006-01-02T15:04:05.000Z") + `</CreationDate></Bucket>`)
	}
	b.WriteString(`</Buckets></ListAllMyBucketsResult>`)
	return b.String()
}

// listObjectsXML renders a ListObjectsV2 page for one bucket+prefix. Callers
// hold f.mu.
func (f *fakeS3) listObjectsXML(bucket, prefix string) string {
	keys := make([]string, 0, len(f.objects))
	for full := range f.objects {
		b, key, ok := strings.Cut(full, "/")
		if !ok || b != bucket || !strings.HasPrefix(key, prefix) {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(`<?xml version="1.0"?><ListBucketResult><Name>` + bucket + `</Name><KeyCount>` +
		strconv.Itoa(len(keys)) + `</KeyCount><IsTruncated>false</IsTruncated>`)
	for _, key := range keys {
		o := f.objects[bucket+"/"+key]
		b.WriteString(`<Contents><Key>` + key + `</Key><Size>` + strconv.Itoa(len(o.body)) +
			`</Size><LastModified>` + o.modified.UTC().Format("2006-01-02T15:04:05.000Z") +
			`</LastModified></Contents>`)
	}
	b.WriteString(`</ListBucketResult>`)
	return b.String()
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

// multipartS3 returns the stateful fake plus a handle on the part bodies it
// recorded, in arrival order, so a test can reassemble exactly what was
// uploaded. The conversation itself (initiate → parts → complete) is served by
// the in-memory engine, which also ASSEMBLES the parts into a stored object —
// so a post-read of the completed key finds the real bytes.
func multipartS3() (*fakeS3, *[][]byte) {
	f := newFakeS3()
	return f, &f.parts
}

// fakeS3Client builds the REAL objstore client over one fake, for the tests
// that interrogate the harness itself rather than a bp verb.
func fakeS3Client(t *testing.T, f *fakeS3) *objstore.Client {
	t.Helper()
	c, err := objstore.NewClient("fsn1", "AKTEST", "SKTEST",
		objstore.WithHTTPClient(&http.Client{Transport: f}))
	if err != nil {
		t.Fatalf("build objstore client over the fake: %v", err)
	}
	return c
}

// TestFakeS3FailsClosed is the harness's own protective test, and it is the
// reason this file can prove anything about a post-read. Before it, fakeS3
// answered EVERY unhandled request 200-with-an-empty-body: a HeadObject
// post-read added to `object put` reported confirmed:true for a key the fake
// had never stored, and all 21 tests here stayed green while proving nothing.
//
// The fence keys on *types.NotFound, never on *awshttp.ResponseError — measured:
// ResponseError is true for BOTH a 404 and a connection refusal (status 404 vs
// 0), so keying on it conflates "absent" with "unreachable".
func TestFakeS3FailsClosed(t *testing.T) {
	f := newFakeS3()
	c := fakeS3Client(t, f)
	ctx := context.Background()

	_, err := c.S3().HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String("bkt"), Key: aws.String("never/stored.txt"),
	})
	if err == nil {
		t.Fatal("HeadObject on a key the fake never stored returned no error — the fake is answering 200 to everything again")
	}
	var missing *types.NotFound
	if !errors.As(err, &missing) {
		t.Errorf("HeadObject error = %v (%T), want *types.NotFound", err, err)
	}

	// A GET of the same absent key is NoSuchKey, with an S3-shaped body.
	if _, gerr := c.S3().GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String("bkt"), Key: aws.String("never/stored.txt"),
	}); gerr == nil {
		t.Error("GetObject on an unstored key succeeded")
	} else {
		var noKey *types.NoSuchKey
		if !errors.As(gerr, &noKey) {
			t.Errorf("GetObject error = %v (%T), want *types.NoSuchKey", gerr, gerr)
		}
	}

	// A route the in-memory S3 does not implement is a refusal, not a 200.
	if _, uerr := c.S3().GetBucketPolicy(ctx, &s3.GetBucketPolicyInput{
		Bucket: aws.String("bkt"),
	}); uerr == nil {
		t.Error("an unrecognised request succeeded; the fake must fail closed")
	} else if !strings.Contains(uerr.Error(), "NotImplemented") {
		t.Errorf("unrecognised-request error = %v, want an S3-shaped NotImplemented", uerr)
	}
}

// TestFakeS3IsStatefulAcrossASequence proves the property a post-read depends
// on: a PUT is REMEMBERED, and an endpoint that silently drops writes — 200 on
// the PUT, nothing persisted — is caught by the very next HEAD. Flipping
// dropWrites is the mutation: with it false the HEAD succeeds, with it true the
// identical sequence fails, so this test can red for the right reason.
func TestFakeS3IsStatefulAcrossASequence(t *testing.T) {
	for _, tc := range []struct {
		name       string
		dropWrites bool
		wantHead   bool
	}{
		{"honest endpoint", false, true},
		{"silent-drop endpoint", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeS3()
			f.dropWrites = tc.dropWrites
			c := fakeS3Client(t, f)
			ctx := context.Background()

			if _, err := c.S3().PutObject(ctx, &s3.PutObjectInput{
				Bucket: aws.String("bkt"), Key: aws.String("seq/one.txt"),
				Body: strings.NewReader("stateful bytes"),
			}); err != nil {
				t.Fatalf("PUT failed: %v — a silent-drop endpoint still 200s the write", err)
			}

			_, herr := c.S3().HeadObject(ctx, &s3.HeadObjectInput{
				Bucket: aws.String("bkt"), Key: aws.String("seq/one.txt"),
			})
			if tc.wantHead {
				if herr != nil {
					t.Fatalf("HEAD after PUT failed: %v, want the stored object", herr)
				}
				body, ok := f.stored("bkt", "seq/one.txt")
				if !ok || string(body) != "stateful bytes" {
					t.Errorf("stored body = %q (%v), want the PUT bytes", body, ok)
				}
				return
			}
			var missing *types.NotFound
			if herr == nil || !errors.As(herr, &missing) {
				t.Fatalf("HEAD after a SILENTLY DROPPED PUT = %v, want *types.NotFound — this is the vacuous pass the harness must make impossible", herr)
			}
			if _, ok := f.stored("bkt", "seq/one.txt"); ok {
				t.Error("dropWrites persisted the object anyway")
			}
		})
	}
}

// TestFakeS3HandlerOverridesTheStore keeps the scripting seam honest: a handler
// still gets first refusal, so a test can inject a wire fault the in-memory
// store would never produce. Returning 0 defers to the store — which is why no
// handler can silently 200 an unimplemented route any more.
func TestFakeS3HandlerOverridesTheStore(t *testing.T) {
	f := newFakeS3().seedObject("bkt", "a/b.txt", "stored bytes", "")
	f.handler = func(r s3Req) (int, string) {
		if r.Method == "HEAD" {
			return fakeS3Error(403, "AccessDenied", "scripted fault")
		}
		return 0, "" // everything else: the store answers
	}
	c := fakeS3Client(t, f)
	ctx := context.Background()

	if _, err := c.S3().HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String("bkt"), Key: aws.String("a/b.txt"),
	}); err == nil {
		t.Error("the scripted 403 did not surface; the handler no longer overrides")
	} else {
		var missing *types.NotFound
		if errors.As(err, &missing) {
			t.Errorf("a scripted 403 read as *types.NotFound (%v) — denial must not look like absence", err)
		}
	}
	out, err := c.S3().GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String("bkt"), Key: aws.String("a/b.txt"),
	})
	if err != nil {
		t.Fatalf("GET should have fallen through to the store: %v", err)
	}
	got, _ := io.ReadAll(out.Body)
	if string(got) != "stored bytes" {
		t.Errorf("GET body = %q, want the seeded bytes", got)
	}
}

// TestFakeS3MultipartAssembles proves the multipart conversation ends in a
// STORED object, not just a 200 on complete — so a post-read of a streamed
// upload (backup create, object put -) has something real to find.
func TestFakeS3MultipartAssembles(t *testing.T) {
	f, parts := multipartS3()
	withFakeS3(t, f)
	oldStdin := storageStdin
	storageStdin = strings.NewReader("multipart body bytes")
	t.Cleanup(func() { storageStdin = oldStdin })

	_, stderr, code := runHzCLI(t, "json", storageArgs("hetzner", "storage", "object", "put", "--bucket", "bkt", "--key", "mp/stream.bin", "-")...)
	if code != exitOK {
		t.Fatalf("multipart put exited %d, stderr: %s", code, stderr)
	}
	if len(*parts) == 0 {
		t.Fatal("the recorder saw no part bodies")
	}
	body, ok := f.stored("bkt", "mp/stream.bin")
	if !ok || string(body) != "multipart body bytes" {
		t.Errorf("stored object = %q (%v), want the assembled stdin bytes", body, ok)
	}
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
	f := newFakeS3().
		seedBucket("backups", "2026-06-01T10:00:00Z").
		seedBucket("media", "2026-06-15T08:30:00Z")
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
	f := newFakeS3().
		seedBucket("backups", "2026-06-01T10:00:00Z").
		seedBucket("media", "2026-06-15T08:30:00Z")
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
	// …and the store agrees: the bucket is gone, not merely 204'd.
	if f.hasBucket("media") {
		t.Error("bucket delete exited 0 but the bucket is still in the store")
	}
	if !f.hasBucket("backups") {
		t.Error("bucket delete removed the wrong bucket")
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
	f := newFakeS3().seedObject("bkt", "a/b.txt", "raw object bytes — no envelope", "")
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
	// The store agrees the key is gone — the read-back a 204 alone cannot give.
	if _, ok := f.stored("bkt", "a/b.txt"); ok {
		t.Error("object rm exited 0 but the key is still stored")
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
	f := newFakeS3().seedObject("bkt", "a/b.txt", body, "")
	f.declaredLen = &n
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
	f := newFakeS3().seedObject("bkt", "a/b.txt", "TRUNCATED", "")
	f.declaredLen = &declared
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
	f := newFakeS3().seedObject("bkt", "a/b.txt", "some bytes", "") // declaredLen nil
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
	f := newFakeS3().
		seedObject("bkt", "prod/a.sql.gz", strings.Repeat("x", 123), "2026-07-01T00:00:00Z").
		seedObject("bkt", "other/skip.txt", "not under the prefix", "")
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
