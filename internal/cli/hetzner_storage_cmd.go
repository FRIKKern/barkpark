package cli

// hetzner_storage_cmd.go is the `bp cloud hetzner storage …` surface — the S3
// DATA PLANE of Hetzner Object Storage, spoken through internal/hetzner/
// objstore (aws-sdk-go-v2, SigV4, virtual-hosted addressing):
//
//	bp cloud hetzner storage bucket   list · create · delete
//	bp cloud hetzner storage object   list · put · get · rm · presign
//
// Auth is S3 credentials, NOT the Hetzner Cloud API token: --s3-access-key /
// --s3-secret-key flags or the HETZNER_S3_ACCESS_KEY / HETZNER_S3_SECRET_KEY
// env vars, plus --location (fsn1 | nbg1 | hel1, default fsn1). THE CONSOLE
// GATE: Hetzner has no API to create S3 credentials or to activate the billed
// Object Storage product — both happen once in the Hetzner Console (the secret
// key is shown exactly once). Everything AFTER that — including creating more
// buckets — works right here through the S3 API.
//
// Framework conventions (parseHzArgs, hzResDone, renderHzTable, useError) come
// from hetzner_cmd.go / hetzner_net_cmd.go; `bp cloud hetzner backup …` builds
// its client through the same seams in hetzner_backup_cmd.go.

import (
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// hzS3DefaultLocation is the location used when --location is omitted.
const hzS3DefaultLocation = "fsn1"

// newObjstoreClient builds the S3 client for one location + credential pair. A
// package var so the tests can point it at a recording fake transport; the
// backup commands build through the same seam.
var newObjstoreClient = func(location, accessKey, secretKey string) (*objstore.Client, error) {
	return objstore.NewClient(location, accessKey, secretKey)
}

// storageStdin is the `object put … -` source — a var so tests can feed bytes
// without owning the process's real stdin.
var storageStdin io.Reader = os.Stdin

// hzS3Location resolves --location with the fsn1 default.
func hzS3Location(a *hzArgs) string {
	if loc := a.val("location"); loc != "" {
		return loc
	}
	return hzS3DefaultLocation
}

// hzS3Client resolves the S3 credentials (flags > env) and builds the objstore
// client. The no-credentials error names the Console gate — there is no API
// that could mint these for you.
func hzS3Client(out *writer, a *hzArgs) (*objstore.Client, bool) {
	accessKey := a.val("s3-access-key")
	if accessKey == "" {
		accessKey = strings.TrimSpace(os.Getenv("HETZNER_S3_ACCESS_KEY"))
	}
	secretKey := a.val("s3-secret-key")
	if secretKey == "" {
		secretKey = strings.TrimSpace(os.Getenv("HETZNER_S3_SECRET_KEY"))
	}
	if accessKey == "" || secretKey == "" {
		useError(out, "auth", "no S3 credentials — pass --s3-access-key/--s3-secret-key or set HETZNER_S3_ACCESS_KEY/HETZNER_S3_SECRET_KEY (created once in the Hetzner Console under Object Storage; there is no API for this)", exitAuth)
		return nil, false
	}
	c, err := newObjstoreClient(hzS3Location(a), accessKey, secretKey)
	if err != nil {
		useError(out, "failed", err.Error(), exitGeneric)
		return nil, false
	}
	return c, true
}

// hzS3CredFlags are the value flags every storage/backup verb accepts on top
// of its own.
var hzS3CredFlags = []string{"location", "s3-access-key", "s3-secret-key"}

// hzS3Flags prepends the shared credential flags to a verb's own value flags.
func hzS3Flags(own ...string) []string {
	return append(append([]string{}, hzS3CredFlags...), own...)
}

// hzDuration parses a human duration: everything time.ParseDuration accepts,
// plus a whole-number `d` suffix for days (30d = 720h) — retention windows are
// spoken in days, not hours.
func hzDuration(s string) (time.Duration, error) {
	if strings.HasSuffix(s, "d") {
		days := strings.TrimSuffix(s, "d")
		n, err := strconv.ParseFloat(strings.TrimSpace(days), 64)
		if err != nil || math.IsInf(n, 0) || math.IsNaN(n) || n < 0 {
			return 0, fmt.Errorf("invalid duration %q (want like 30d, 12h, 90m)", s)
		}
		return time.Duration(n * float64(24*time.Hour)), nil
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q (want like 30d, 12h, 90m)", s)
	}
	return d, nil
}

// runHetznerStorage routes `bp cloud hetzner storage <resource> …`.
func runHetznerStorage(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerStorageHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing storage command (run `bp cloud hetzner storage -h` for usage)", exitUsage)
	}
	resource, rest := args[0], args[1:]
	switch resource {
	case "bucket", "buckets":
		return runHetznerStorageBucket(out, g, rest)
	case "object", "objects":
		return runHetznerStorageObject(out, g, rest)
	case "help":
		printHetznerStorageHelp(out)
		return exitOK
	default:
		return useError(out, "usage", fmt.Sprintf("unknown storage resource %q (run `bp cloud hetzner storage -h` for usage)", resource), exitUsage)
	}
}

// ---------------------------------------------------------------------------
// bucket
// ---------------------------------------------------------------------------

func runHetznerStorageBucket(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerStorageHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing storage bucket command (run `bp cloud hetzner storage bucket -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerBucketList(out, rest)
	case "get", "show":
		return runHetznerBucketGet(out, rest)
	case "create":
		return runHetznerBucketCreate(out, rest)
	case "delete", "rm":
		return runHetznerBucketDelete(out, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown storage bucket command %q (run `bp cloud hetzner storage bucket -h` for usage)", verb), exitUsage)
	}
}

func runHetznerBucketList(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage bucket list [--location <loc>]"
	a, err := parseHzArgs(args, hzS3Flags(), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	buckets, err := c.ListBuckets(hetznerCtx())
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(buckets))
		for _, b := range buckets {
			row := map[string]any{"name": b.Name}
			if !b.Created.IsZero() {
				row["created"] = b.Created.UTC().Format(time.RFC3339)
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"buckets": rows})
		return exitOK
	}
	if len(buckets) == 0 {
		out.outf("no buckets in %s — create one with 'bp cloud hetzner storage bucket create --name <n>'", hzS3Location(a))
		return exitOK
	}
	rows := make([][]string, 0, len(buckets))
	for _, b := range buckets {
		created := ""
		if !b.Created.IsZero() {
			created = b.Created.UTC().Format(time.RFC3339)
		}
		rows = append(rows, []string{hzCell(b.Name), hzCell(created)})
	}
	renderHzTable(out, []string{"NAME", "CREATED"}, rows)
	return exitOK
}

func runHetznerBucketGet(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage bucket get --name <n> [--location <loc>]"
	a, err := parseHzArgs(args, hzS3Flags("name"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	name := a.val("name")
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	// Hetzner Object Storage exposes no single-bucket GET; the credentials' own
	// ListBuckets is the authoritative existence + creation-time source, and the
	// location is the client's own truth.
	buckets, err := c.ListBuckets(hetznerCtx())
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	loc := hzS3Location(a)
	var found *objstore.Bucket
	for i := range buckets {
		if buckets[i].Name == name {
			found = &buckets[i]
			break
		}
	}
	if found == nil {
		return useError(out, "not_found", fmt.Sprintf("bucket %q not found in %s (see `bp cloud hetzner storage bucket list`)", name, loc), exitNotFound)
	}
	row := map[string]any{"name": found.Name, "location": loc}
	if !found.Created.IsZero() {
		row["created"] = found.Created.UTC().Format(time.RFC3339)
	}
	if out.emitStructured(map[string]any{"bucket": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerBucketCreate(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage bucket create --name <n> [--location <loc>]"
	a, err := parseHzArgs(args, hzS3Flags("name"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	name := a.val("name")
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	if err := c.CreateBucket(hetznerCtx(), name); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	return hzResDone(out, "create", "bucket", name, name, map[string]any{"location": hzS3Location(a)})
}

func runHetznerBucketDelete(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage bucket delete --name <n> [--location <loc>] [--yes]"
	a, err := parseHzArgs(args, hzS3Flags("name"), []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	name := a.val("name")
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "bucket", name, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if err := c.DeleteBucket(hetznerCtx(), name); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	// DECLARED NON-BINDING (see hzResDestroyedDeclared): Hetzner's S3-compatible
	// endpoint documents no consistency model, so a bucket still listed after a
	// DELETE is reported, never treated as a failed verb. The read fails CLOSED
	// — an error is confirmed_absent=false, never an optimistic true.
	return hzResDestroyedDeclared(out, "delete", "bucket", name, name, nil,
		"ListBuckets after the delete", func() (bool, error) {
			buckets, lerr := c.ListBuckets(hetznerCtx())
			if lerr != nil {
				return false, lerr
			}
			for _, b := range buckets {
				if b.Name == name {
					return false, nil
				}
			}
			return true, nil
		})
}

// ---------------------------------------------------------------------------
// object
// ---------------------------------------------------------------------------

func runHetznerStorageObject(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerStorageHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing storage object command (run `bp cloud hetzner storage object -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerObjectList(out, rest)
	case "put":
		return runHetznerObjectPut(out, rest)
	case "get":
		return runHetznerObjectGet(out, rest)
	case "rm", "delete":
		return runHetznerObjectRm(out, rest)
	case "presign":
		return runHetznerObjectPresign(out, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown storage object command %q (run `bp cloud hetzner storage object -h` for usage)", verb), exitUsage)
	}
}

// hzBucketKey pulls the required --bucket (and, when wantKey, --key) values.
func hzBucketKey(out *writer, a *hzArgs, usage string, wantKey bool) (string, string, bool) {
	bucket, key := a.val("bucket"), a.val("key")
	if bucket == "" || (wantKey && key == "") {
		what := "--bucket is"
		if wantKey {
			what = "--bucket and --key are"
		}
		useError(out, "usage", what+" required (usage: "+usage+")", exitUsage)
		return "", "", false
	}
	return bucket, key, true
}

func runHetznerObjectList(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage object list --bucket <b> [--prefix <p>]"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "prefix"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket, _, ok := hzBucketKey(out, a, usage, false)
	if !ok {
		return exitUsage
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	objects, err := c.ListObjects(hetznerCtx(), bucket, a.val("prefix"))
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(objects))
		for _, o := range objects {
			row := map[string]any{"key": o.Key, "size": o.Size}
			if !o.LastModified.IsZero() {
				row["last_modified"] = o.LastModified.UTC().Format(time.RFC3339)
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"objects": rows})
		return exitOK
	}
	if len(objects) == 0 {
		out.outf("no objects in %s%s", bucket, prefixNote(a.val("prefix")))
		return exitOK
	}
	rows := make([][]string, 0, len(objects))
	for _, o := range objects {
		modified := ""
		if !o.LastModified.IsZero() {
			modified = o.LastModified.UTC().Format(time.RFC3339)
		}
		rows = append(rows, []string{hzCell(o.Key), fmt.Sprintf("%d", o.Size), hzCell(modified)})
	}
	renderHzTable(out, []string{"KEY", "SIZE", "LAST-MODIFIED"}, rows)
	return exitOK
}

func prefixNote(prefix string) string {
	if prefix == "" {
		return ""
	}
	return " under prefix " + prefix
}

func runHetznerObjectPut(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage object put --bucket <b> --key <k> (--file <f> | -)"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "key", "file"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket, key, ok := hzBucketKey(out, a, usage, true)
	if !ok {
		return exitUsage
	}
	file := a.val("file")
	fromStdin := len(a.pos) == 1 && a.pos[0] == "-"
	if len(a.pos) > 0 && !fromStdin {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	if (file == "") == !fromStdin {
		return useError(out, "usage", "want exactly one source: --file <f> or a trailing - for stdin (usage: "+usage+")", exitUsage)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()

	var size any
	if fromStdin {
		// Unbounded stream → the multipart path (no size known up front).
		if err := c.PutLarge(ctx, bucket, key, storageStdin); err != nil {
			return useError(out, "failed", err.Error(), exitGeneric)
		}
	} else {
		f, ferr := os.Open(file)
		if ferr != nil {
			return useError(out, "usage", ferr.Error(), exitUsage)
		}
		defer f.Close()
		if st, serr := f.Stat(); serr == nil {
			size = st.Size()
		}
		if err := c.PutObject(ctx, bucket, key, f); err != nil {
			return useError(out, "failed", err.Error(), exitGeneric)
		}
	}
	extra := map[string]any{"bucket": bucket}
	if size != nil {
		extra["bytes"] = size
	}
	return hzResDone(out, "put", "object", key, key, extra)
}

func runHetznerObjectGet(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage object get --bucket <b> --key <k> [--out <f>]"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "key", "out"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket, key, ok := hzBucketKey(out, a, usage, true)
	if !ok {
		return exitUsage
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	// GetObjectSized, not GetObject: the length the endpoint declared rides the
	// SAME response, and without it the receipt below could only echo its own
	// io.Copy counter — a byte count nothing verified.
	rc, declared, err := c.GetObjectSized(hetznerCtx(), bucket, key)
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	defer rc.Close()

	if outPath := a.val("out"); outPath != "" {
		// Write beside the destination and rename only once the bytes check out:
		// os.Create(outPath) truncated a pre-existing file BEFORE the first S3
		// byte arrived, so a mid-stream drop destroyed the good copy the operator
		// already had. Same directory = same filesystem = atomic rename.
		destDir := filepath.Dir(outPath)
		tmp, ferr := os.CreateTemp(destDir, "."+filepath.Base(outPath)+".part-*")
		if ferr != nil {
			return useError(out, "usage", "create temp file in "+destDir+": "+ferr.Error(), exitUsage)
		}
		tmpName := tmp.Name()
		n, cerr := io.Copy(tmp, rc)
		if closeErr := tmp.Close(); closeErr != nil && cerr == nil {
			cerr = closeErr
		}
		if cerr != nil {
			_ = os.Remove(tmpName)
			return useError(out, "failed", "write "+outPath+": "+cerr.Error(), exitGeneric)
		}
		if declared > 0 && n != declared {
			_ = os.Remove(tmpName)
			return useError(out, "failed",
				fmt.Sprintf("size mismatch: %s/%s declared %d bytes, wrote %d — %s left untouched", bucket, key, declared, n, outPath),
				exitGeneric)
		}
		if rerr := os.Rename(tmpName, outPath); rerr != nil {
			_ = os.Remove(tmpName)
			return useError(out, "failed", "promote "+tmpName+" to "+outPath+": "+rerr.Error(), exitGeneric)
		}
		extra := map[string]any{"bucket": bucket, "out": outPath, "bytes": n}
		for k, v := range hzSizeVerdict(declared) {
			extra[k] = v
		}
		return hzResDone(out, "get", "object", key, key, extra)
	}
	// No --out: the object's bytes ARE the output — raw to stdout, no envelope,
	// so `… object get … > file` and piping into tar Just Work. There is no
	// receipt to carry a verdict here, so the only honest signal a truncated
	// pipe has is the exit code.
	n, cerr := io.Copy(out.stdout, rc)
	if cerr != nil {
		return useError(out, "failed", cerr.Error(), exitGeneric)
	}
	if declared > 0 && n != declared {
		return useError(out, "failed",
			fmt.Sprintf("size mismatch: %s/%s declared %d bytes, streamed %d", bucket, key, declared, n),
			exitGeneric)
	}
	return exitOK
}

// hzSizeVerdict turns a DECLARED object length into the receipt fields that say
// whether the byte count was checked against anything. An absent (-1) or
// non-positive declaration is reported as unverified with its own counter —
// Hetzner is S3-compatible, not S3, so "no Content-Length came back" must never
// read as a pass.
func hzSizeVerdict(declared int64) map[string]any {
	if declared > 0 {
		return map[string]any{"declared_bytes": declared, "size_verified": true, "unverified": 0}
	}
	return map[string]any{
		"size_verified":     false,
		"unverified":        1,
		"unverified_reason": "the endpoint declared no object length; the byte count is what we wrote, not what was promised",
	}
}

func runHetznerObjectRm(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage object rm --bucket <b> --key <k> [--yes]"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "key"), []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket, key, ok := hzBucketKey(out, a, usage, true)
	if !ok {
		return exitUsage
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "object", key, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if err := c.DeleteObject(hetznerCtx(), bucket, key); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	// DECLARED NON-BINDING, same reasoning as bucket delete: the key is looked
	// for under its own exact prefix, and anything but a clean absence is an
	// honest ⚠ partial rather than a ✓.
	return hzResDestroyedDeclared(out, "rm", "object", key, key, map[string]any{"bucket": bucket},
		"ListObjects on the exact key prefix after the delete", func() (bool, error) {
			objs, lerr := c.ListObjects(hetznerCtx(), bucket, key)
			if lerr != nil {
				return false, lerr
			}
			for _, o := range objs {
				if o.Key == key {
					return false, nil
				}
			}
			return true, nil
		})
}

func runHetznerObjectPresign(out *writer, args []string) int {
	const usage = "bp cloud hetzner storage object presign --bucket <b> --key <k> [--expires 1h]"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "key", "expires"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket, key, ok := hzBucketKey(out, a, usage, true)
	if !ok {
		return exitUsage
	}
	expires := time.Hour
	if e := a.val("expires"); e != "" {
		d, derr := hzDuration(e)
		if derr != nil {
			return useError(out, "usage", derr.Error(), exitUsage)
		}
		expires = d
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	url, err := c.PresignGetObject(hetznerCtx(), bucket, key, expires)
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	// Only an EXPLICIT -o json/yaml gets the envelope; the piped default must stay
	// the bare URL so `open $(bp … presign …)` (stdout is a pipe inside $(...))
	// keeps working.
	if out.outputExplicit && (out.output == "json" || out.output == "yaml") &&
		out.emitStructured(map[string]any{"url": url, "bucket": bucket, "key": key, "expires_in": expires.String()}) {
		return exitOK
	}
	// Bare URL on the human path: `open $(bp … presign …)`.
	out.outf("%s", url)
	return exitOK
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

// printHetznerStorageHelp writes `bp cloud hetzner storage` usage — including
// the Console gate every S3 command depends on.
func printHetznerStorageHelp(out *writer) {
	const help = `bp cloud hetzner storage — Hetzner Object Storage (S3-compatible data plane).

USAGE
  bp cloud hetzner storage bucket list
  bp cloud hetzner storage bucket get --name <n> [--location <loc>]
  bp cloud hetzner storage bucket create --name <n> [--location <loc>]
  bp cloud hetzner storage bucket delete --name <n> [--yes]
  bp cloud hetzner storage object list --bucket <b> [--prefix <p>]
  bp cloud hetzner storage object put --bucket <b> --key <k> (--file <f> | - for stdin)
  bp cloud hetzner storage object get --bucket <b> --key <k> [--out <f>]
  bp cloud hetzner storage object rm --bucket <b> --key <k> [--yes]
  bp cloud hetzner storage object presign --bucket <b> --key <k> [--expires 1h]

AUTH (S3 credentials, NOT the Hetzner Cloud API token; first match wins)
  --s3-access-key <k> / --s3-secret-key <k>    explicit credentials
  $HETZNER_S3_ACCESS_KEY / $HETZNER_S3_SECRET_KEY
  --location <loc>    fsn1 | nbg1 | hel1 (default fsn1)

ONE-TIME CONSOLE GATE (no API exists for this)
  Hetzner offers NO API to create S3 credentials or to activate the billed
  Object Storage product in a location — both are done ONCE in the Hetzner
  Console (Object Storage → generate credentials; the SECRET KEY is shown
  exactly once, store it then). These commands only USE existing credentials.
  Everything after the gate — including creating further buckets — works from
  here: 'bucket create' is the S3 API's own CreateBucket call.

NOTES
  put -             a trailing '-' streams stdin via the multipart path (no
                    size limit); --file uploads a file in one request
  get               without --out the raw bytes go to stdout (pipe-friendly);
                    --out <f> writes the file and prints a receipt
  presign           prints a time-limited GET URL (bare URL on the human view)
  --expires         accepts 90m, 12h, 7d (d = days)
  -o json|yaml      structured output for every verb

EXAMPLES
  bp cloud hetzner storage bucket create --name barkpark-backups --location fsn1
  pg_dump db | gzip | bp cloud hetzner storage object put --bucket barkpark-backups --key adhoc.sql.gz -
  bp cloud hetzner storage object presign --bucket barkpark-backups --key adhoc.sql.gz --expires 12h`
	out.outf("%s", help)
}
