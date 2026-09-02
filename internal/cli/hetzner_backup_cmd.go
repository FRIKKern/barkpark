package cli

// hetzner_backup_cmd.go is the `bp cloud hetzner backup …` surface — real
// Postgres backups into Hetzner Object Storage, wired through internal/backup:
//
//	bp cloud hetzner backup create   pg_dump --database-url → gzip → multipart S3
//	bp cloud hetzner backup list     the backups (parsed keys + manifests)
//	bp cloud hetzner backup restore  S3 → gunzip → psql --database-url
//	bp cloud hetzner backup prune    retention: --keep N or --older-than 30d
//
// The library owns the streaming/gzip/manifest logic against interfaces; this
// file wires the REAL edges: `pg_dump` as the DumpSource, `psql` as the
// RestoreSink (both must be on PATH — the error says so plainly), and the
// objstore client (same S3 credentials + Console gate as `… storage`, see
// hetzner_storage_cmd.go).

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/backup"
)

// newDumpSource builds the pg_dump-backed DumpSource for a database URL. A
// package var so tests inject a fixed-bytes source and drive the REAL backup
// pipeline without a Postgres.
var newDumpSource = func(databaseURL string) (backup.DumpSource, error) {
	if _, err := exec.LookPath("pg_dump"); err != nil {
		return nil, fmt.Errorf("pg_dump is not on PATH — install the Postgres client tools (e.g. `brew install libpq` or `apt install postgresql-client`) to take backups")
	}
	return &pgDumpSource{databaseURL: databaseURL}, nil
}

// newRestoreSink builds the psql-backed RestoreSink for a database URL — the
// same seam idea for the restore direction.
var newRestoreSink = func(databaseURL string) (backup.RestoreSink, error) {
	if _, err := exec.LookPath("psql"); err != nil {
		return nil, fmt.Errorf("psql is not on PATH — install the Postgres client tools (e.g. `brew install libpq` or `apt install postgresql-client`) to restore backups")
	}
	return &psqlSink{databaseURL: databaseURL}, nil
}

// pgDumpSource runs `pg_dump <url>` (plain-SQL format, ownership stripped so
// the dump restores into any role) and streams its stdout.
type pgDumpSource struct {
	databaseURL string
}

// Database names the database for the manifest — the URL's path when present.
func (s *pgDumpSource) Database() string {
	if u, err := url.Parse(s.databaseURL); err == nil {
		if name := strings.Trim(u.Path, "/"); name != "" {
			return name
		}
	}
	return "postgres"
}

// splitPGURL peels the password out of a postgres:// URL so it rides the
// child's PGPASSWORD env instead of an argv element — argv is world-readable
// via `ps aux` / /proc/<pid>/cmdline for the life of the process (CWE-214).
// It returns the password-less DSN and the extracted password; a parse failure
// returns the raw URL and no password, preserving behavior for malformed input.
func splitPGURL(raw string) (dsn string, pgPassword string) {
	u, err := url.Parse(raw)
	if err != nil {
		return raw, ""
	}
	if u.User != nil {
		if pw, ok := u.User.Password(); ok {
			pgPassword = pw
		}
		if name := u.User.Username(); name != "" {
			u.User = url.User(name)
		} else {
			u.User = nil
		}
	}
	return u.String(), pgPassword
}

// buildCmd assembles the pg_dump command with the password kept off argv.
func (s *pgDumpSource) buildCmd(ctx context.Context) *exec.Cmd {
	dsn, pw := splitPGURL(s.databaseURL)
	cmd := exec.CommandContext(ctx, "pg_dump", "--no-owner", "--no-privileges", "--dbname", dsn)
	if pw != "" {
		cmd.Env = append(os.Environ(), "PGPASSWORD="+pw)
	}
	return cmd
}

func (s *pgDumpSource) Open(ctx context.Context) (io.ReadCloser, error) {
	cmd := s.buildCmd(ctx)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("pg_dump: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("pg_dump: %w", err)
	}
	return &cmdStream{r: stdout, cmd: cmd, stderr: &stderr, name: "pg_dump"}, nil
}

// cmdStream is a command's stdout as a ReadCloser whose Close REPORTS the exit
// status (stderr attached) — exactly the DumpSource contract, so a pg_dump
// that dies mid-stream fails the backup instead of completing a truncated one.
type cmdStream struct {
	r      io.Reader
	cmd    *exec.Cmd
	stderr *bytes.Buffer
	name   string
}

func (c *cmdStream) Read(p []byte) (int, error) { return c.r.Read(p) }

func (c *cmdStream) Close() error {
	if err := c.cmd.Wait(); err != nil {
		msg := strings.TrimSpace(c.stderr.String())
		if msg != "" {
			return fmt.Errorf("%s: %w: %s", c.name, err, msg)
		}
		return fmt.Errorf("%s: %w", c.name, err)
	}
	return nil
}

// psqlSink feeds the restored SQL into `psql <url>` with ON_ERROR_STOP so a
// broken dump fails the restore instead of half-applying.
type psqlSink struct {
	databaseURL string
}

// buildCmd assembles the psql command with the password kept off argv.
func (s *psqlSink) buildCmd(ctx context.Context) *exec.Cmd {
	dsn, pw := splitPGURL(s.databaseURL)
	cmd := exec.CommandContext(ctx, "psql", "--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--quiet", "--dbname", dsn)
	if pw != "" {
		cmd.Env = append(os.Environ(), "PGPASSWORD="+pw)
	}
	return cmd
}

func (s *psqlSink) Restore(ctx context.Context, r io.Reader) error {
	cmd := s.buildCmd(ctx)
	cmd.Stdin = r
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg != "" {
			return fmt.Errorf("psql: %w: %s", err, msg)
		}
		return fmt.Errorf("psql: %w", err)
	}
	return nil
}

// runHetznerBackup routes `bp cloud hetzner backup <verb> …`.
func runHetznerBackup(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerBackupHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing backup command (run `bp cloud hetzner backup -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "create":
		return runHetznerBackupCreate(out, rest)
	case "list", "ls":
		return runHetznerBackupList(out, rest)
	case "restore":
		return runHetznerBackupRestore(out, rest)
	case "prune":
		return runHetznerBackupPrune(out, rest)
	case "help":
		printHetznerBackupHelp(out)
		return exitOK
	default:
		return useError(out, "usage", fmt.Sprintf("unknown backup command %q (run `bp cloud hetzner backup -h` for usage)", verb), exitUsage)
	}
}

func runHetznerBackupCreate(out *writer, args []string) int {
	const usage = "bp cloud hetzner backup create --database-url <postgres-url> --bucket <b> [--prefix <p>] [--location <loc>]"
	a, err := parseHzArgs(args, hzS3Flags("database-url", "bucket", "prefix"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	dbURL, bucket := a.val("database-url"), a.val("bucket")
	if dbURL == "" || bucket == "" {
		return useError(out, "usage", "--database-url and --bucket are required (usage: "+usage+")", exitUsage)
	}
	src, serr := newDumpSource(dbURL)
	if serr != nil {
		return useError(out, "failed", serr.Error(), exitGeneric)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	key, err := backup.Backup(hetznerCtx(), src, c, bucket, a.val("prefix"))
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	// THE POST-READ (PDS-D427): the key backup.Backup returns is the one it
	// COMPOSED, not one anybody read. A HEAD on it is what turns this receipt
	// from "the upload call did not error" into "the object is there" — and a
	// backup that is not there is the one lie in this CLI that costs a database.
	// The basis names the HEAD (PDS-D437). It is the weaker of the two things a
	// reader might hope for: the key holds bytes. That the bytes are THIS dump
	// is not confirmed, which is why hzObserveBackupStored declares `database`
	// rather than asserting it.
	return hzResObserved(out, hetznerCtx(), "create", "backup", key, key, nil,
		hzS3HeadRead(c, bucket, key), hzObserveBackupStored(bucket, src.Database()), hzResBasisHead)
}

// hzObserveBackupStored reads the dump's receipt off the HEAD of its stored key,
// and DECLARES the one field that read cannot carry.
func hzObserveBackupStored(bucket, database string) hzResObserveFn[hzS3Head] {
	return func(h *hzS3Head) hzResObservation {
		extra := map[string]any{
			"bucket": bucket,
			// DECLARED, NEVER CONFIRMED: an object store can confirm that a KEY
			// holds bytes; it cannot report which database produced them. The
			// name comes from --database-url, and the receipt says so rather
			// than letting it sit beside observed fields as if it were one.
			"database":           database,
			"database_confirmed": false,
			"database_basis": "declared from --database-url — the object store can confirm the KEY exists, " +
				"never which database produced its bytes",
		}
		if h.length != nil {
			extra["bytes"] = *h.length
		} else {
			extra["bytes_verified"] = false
			extra["bytes_reason"] = "the endpoint declared no length for the stored dump, so its size is UNKNOWN " +
				"— the key's existence is what this receipt confirms"
		}
		return hzResAgrees(extra)
	}
}

func runHetznerBackupList(out *writer, args []string) int {
	const usage = "bp cloud hetzner backup list --bucket <b> [--prefix <p>]"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "prefix"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket := a.val("bucket")
	if bucket == "" {
		return useError(out, "usage", "--bucket is required (usage: "+usage+")", exitUsage)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	infos, err := backup.List(hetznerCtx(), c, bucket, a.val("prefix"))
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(infos))
		for _, in := range infos {
			row := map[string]any{"key": in.Key, "created_at": in.CreatedAt.UTC().Format(time.RFC3339)}
			if in.Database != "" {
				row["database"] = in.Database
			}
			if in.Bytes > 0 {
				row["bytes"] = in.Bytes
			}
			if in.Stored > 0 {
				row["stored"] = in.Stored
			}
			if in.SHA256 != "" {
				row["sha256"] = in.SHA256
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"backups": rows})
		return exitOK
	}
	if len(infos) == 0 {
		out.outf("no backups in %s%s — take one with 'bp cloud hetzner backup create --database-url <url> --bucket %s'", bucket, prefixNote(a.val("prefix")), bucket)
		return exitOK
	}
	rows := make([][]string, 0, len(infos))
	for _, in := range infos {
		rows = append(rows, []string{
			hzCell(in.Key),
			hzCell(in.Database),
			hzCell(fmtBytes(in.Bytes)),
			hzCell(in.CreatedAt.UTC().Format(time.RFC3339)),
		})
	}
	renderHzTable(out, []string{"KEY", "DATABASE", "BYTES", "CREATED"}, rows)
	return exitOK
}

// fmtBytes renders a byte count, empty for the unknown (no-manifest) case so
// the table dashes it out.
func fmtBytes(n int64) string {
	if n <= 0 {
		return ""
	}
	return strconv.FormatInt(n, 10)
}

func runHetznerBackupRestore(out *writer, args []string) int {
	const usage = "bp cloud hetzner backup restore --bucket <b> --key <k> --database-url <postgres-url>"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "key", "database-url"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket, key, dbURL := a.val("bucket"), a.val("key"), a.val("database-url")
	if bucket == "" || key == "" || dbURL == "" {
		return useError(out, "usage", "--bucket, --key and --database-url are required (usage: "+usage+")", exitUsage)
	}
	sink, serr := newRestoreSink(dbURL)
	if serr != nil {
		return useError(out, "failed", serr.Error(), exitGeneric)
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	rep, rerr := backup.Restore(hetznerCtx(), c, bucket, key, sink)
	if rerr != nil {
		return useError(out, "failed", rerr.Error(), exitGeneric)
	}
	return hzResDone(out, "restore", "backup", key, key, hzRestoreNotConfirmed(bucket, rep))
}

// hzRestoreNotConfirmed is `backup restore`'s DECLARED EXEMPTION, spelled as
// code so the census can name a SYMBOL rather than trust a sentence.
//
// Every other write in this file earns its ✓ by re-reading what it wrote. This
// one cannot, and the reason is a boundary rather than a cost: the post-condition
// of a restore lives INSIDE THE TARGET POSTGRES — that the tables are now there
// — and this verb holds S3 credentials, not database ones. The bytes it can
// account for (the object streamed, gunzipped, and accepted by psql) it already
// accounted for; the state it cannot see it REFUSES TO FABRICATE. So the receipt
// carries the same `confirmation: unavailable` vocabulary the destroy half uses
// when its read fails, and says in words that the restored state is not
// confirmed — instead of a confirmed_present key nothing read.
func hzRestoreNotConfirmed(bucket string, rep backup.RestoreReport) map[string]any {
	extra := map[string]any{
		"bucket":              bucket,
		hzKeyConfirmation:     hzConfirmUnavail,
		hzKeyConfirmedPresent: false,
		hzKeyConfirmBasis:     "none — DECLARED EXEMPTION",
		"restored_bytes":      rep.Bytes,
		"restored_sha256":     rep.SHA256,
		"manifest_check":      rep.Verification,
		"note": "the dump was streamed into the target database and the restore sink accepted it; whether that " +
			"database now HOLDS it is a post-condition inside Postgres, outside this verb's S3 credential plane, " +
			"so the restored state is " + hzNotConfirmedPhras + " (verify with a query against the target)",
	}
	// The unverified case keeps its OWN key rather than sharing the verified
	// one, so a reader (and a script) counts the two apart: a restore whose
	// manifest could not be read is never tallied as a manifest that passed.
	if !rep.Verified() {
		extra["manifest_unverified_reason"] = rep.Reason
	}
	return extra
}

func runHetznerBackupPrune(out *writer, args []string) int {
	const usage = "bp cloud hetzner backup prune --bucket <b> [--prefix <p>] (--keep <n> | --older-than <30d>) [--yes]"
	a, err := parseHzArgs(args, hzS3Flags("bucket", "prefix", "keep", "older-than"), []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	bucket := a.val("bucket")
	if bucket == "" {
		return useError(out, "usage", "--bucket is required (usage: "+usage+")", exitUsage)
	}
	keepStr, olderStr := a.val("keep"), a.val("older-than")
	if (keepStr == "") == (olderStr == "") {
		return useError(out, "usage", "want exactly one retention rule: --keep <n> or --older-than <dur> (usage: "+usage+")", exitUsage)
	}
	var policy backup.PrunePolicy
	if keepStr != "" {
		n, perr := strconv.Atoi(keepStr)
		if perr != nil || n <= 0 {
			return useError(out, "usage", fmt.Sprintf("invalid --keep %q (want a positive integer)", keepStr), exitUsage)
		}
		policy.Keep = n
	} else {
		d, derr := hzDuration(olderStr)
		if derr != nil || d <= 0 {
			return useError(out, "usage", fmt.Sprintf("invalid --older-than %q (want like 30d, 12h)", olderStr), exitUsage)
		}
		policy.OlderThan = d
	}
	c, ok := hzS3Client(out, a)
	if !ok {
		return exitAuth
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "backups outside the retention rule in bucket", bucket, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	deleted, err := backup.Prune(hetznerCtx(), c, bucket, a.val("prefix"), policy)
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	if out.emitStructured(map[string]any{"ok": true, "action": "prune", "bucket": bucket, "deleted": deleted, "count": len(deleted)}) {
		return exitOK
	}
	if len(deleted) == 0 {
		out.outf("✓ prune — nothing to delete in %s%s", bucket, prefixNote(a.val("prefix")))
		return exitOK
	}
	out.outf("✓ prune — deleted %d backup(s) from %s", len(deleted), bucket)
	for _, k := range deleted {
		out.outf("  %s", k)
	}
	return exitOK
}

// printHetznerBackupHelp writes `bp cloud hetzner backup` usage.
func printHetznerBackupHelp(out *writer) {
	const help = `bp cloud hetzner backup — Postgres backups into Hetzner Object Storage.

USAGE
  bp cloud hetzner backup create --database-url <postgres-url> --bucket <b>
                                 [--prefix <p>] [--location <loc>]
  bp cloud hetzner backup list --bucket <b> [--prefix <p>]
  bp cloud hetzner backup restore --bucket <b> --key <k> --database-url <postgres-url>
  bp cloud hetzner backup prune --bucket <b> [--prefix <p>] (--keep <n> | --older-than <30d>) [--yes]

PIPELINE
  create   runs pg_dump on --database-url, gzips the stream and multipart-
           uploads it to s3://<bucket>/<prefix>/<UTC-stamp>.sql.gz — constant
           memory, no temp file, no size ceiling — plus a small JSON manifest
           alongside (database, bytes, sha256, created_at)
  restore  downloads, gunzips and streams into psql (ON_ERROR_STOP=1)
  prune    --keep N keeps the N most-recent; --older-than 30d deletes older
           (d = days; 12h etc. also accepted); manifests ride along

REQUIREMENTS
  pg_dump / psql on PATH (create / restore fail with a plain error otherwise)
  S3 credentials — same flags/env and one-time Hetzner Console gate as
  'bp cloud hetzner storage' (see bp cloud hetzner storage -h): --s3-access-key/
  --s3-secret-key or $HETZNER_S3_ACCESS_KEY/$HETZNER_S3_SECRET_KEY, --location
  fsn1|nbg1|hel1 (default fsn1)

EXAMPLES
  bp cloud hetzner backup create --database-url postgres://bp@db.internal/barkpark \
      --bucket barkpark-backups --prefix prod
  bp cloud hetzner backup list --bucket barkpark-backups --prefix prod
  bp cloud hetzner backup prune --bucket barkpark-backups --prefix prod --keep 14
  bp cloud hetzner backup restore --bucket barkpark-backups \
      --key prod/20260701T031500Z.sql.gz --database-url postgres://bp@db.internal/barkpark_restore`
	out.outf("%s", help)
}
