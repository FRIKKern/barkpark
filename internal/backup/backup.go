// Package backup is the reusable database-backup executor behind
// `bp cloud hetzner backup …`: it streams a pg_dump (or any DumpSource) through
// gzip into an S3-compatible object store via the MULTIPART path — no temp
// file, no size ceiling — and writes a small JSON manifest alongside each dump
// so a listing can show what a backup contains without downloading it.
//
// The package deliberately depends on two INTERFACES, not on a live pg_dump or
// a real bucket: DumpSource produces the SQL stream (the CLI wires `pg_dump`,
// tests wire fixed bytes) and ObjStore is the storage seam that
// *objstore.Client already satisfies (tests wire an in-memory fake). Layout in
// the bucket, for a prefix P and a dump taken at T (UTC):
//
//	P/20060102T150405Z.sql.gz               the gzipped dump (multipart upload)
//	P/20060102T150405Z.sql.gz.manifest.json {database, bytes, sha256, created_at}
//
// The compact UTC timestamp keys sort lexicographically == chronologically,
// which List and Prune lean on. bytes and sha256 describe the UNCOMPRESSED SQL
// stream — the integrity check a restore actually cares about.
package backup

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// DumpSource produces the database dump stream. Database names the database
// for the manifest; Open starts the dump. The ReadCloser's Close MUST report
// the producer's exit status (a pg_dump that died mid-stream must surface as a
// Close error) — Backup treats a Close error as a failed backup and aborts the
// upload rather than completing a truncated object.
type DumpSource interface {
	Database() string
	Open(ctx context.Context) (io.ReadCloser, error)
}

// RestoreSink consumes a restored dump stream (the CLI wires `psql` reading
// stdin; tests wire a buffer).
type RestoreSink interface {
	Restore(ctx context.Context, r io.Reader) error
}

// ObjStore is the storage seam — exactly the *objstore.Client methods Backup,
// Restore, List and Prune need, so tests inject an in-memory fake and the CLI
// passes the real Hetzner client unchanged.
type ObjStore interface {
	PutObject(ctx context.Context, bucket, key string, body io.Reader) error
	PutLarge(ctx context.Context, bucket, key string, body io.Reader) error
	GetObject(ctx context.Context, bucket, key string) (io.ReadCloser, error)
	ListObjects(ctx context.Context, bucket, prefix string) ([]objstore.Object, error)
	DeleteObject(ctx context.Context, bucket, key string) error
}

// dumpSuffix / manifestSuffix are the fixed key shapes List and Prune parse.
const (
	dumpSuffix     = ".sql.gz"
	manifestSuffix = ".manifest.json"
)

// keyTimeFormat is the compact UTC stamp in each dump key — lexicographic
// order equals chronological order, and it contains no ':' (annoying in URLs
// and on some filesystems when downloaded).
const keyTimeFormat = "20060102T150405Z"

// nowFunc is the clock seam — Prune's older-than cutoff and Backup's key
// timestamp read it; tests pin it.
var nowFunc = time.Now

// Manifest is the JSON object written alongside each dump. Bytes and SHA256
// describe the uncompressed SQL stream.
type Manifest struct {
	Database  string    `json:"database"`
	Bytes     int64     `json:"bytes"`
	SHA256    string    `json:"sha256"`
	CreatedAt time.Time `json:"created_at"`
}

// BackupInfo is one listed backup: the dump key plus its manifest fields (when
// the manifest is readable) and the stored (gzipped) object size.
type BackupInfo struct {
	Key       string    `json:"key"`
	Database  string    `json:"database,omitempty"`
	Bytes     int64     `json:"bytes,omitempty"`  // uncompressed dump bytes (manifest)
	Stored    int64     `json:"stored,omitempty"` // gzipped object bytes (listing)
	SHA256    string    `json:"sha256,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// joinPrefix joins prefix and name with exactly one slash; an empty prefix
// yields the bare name.
func joinPrefix(prefix, name string) string {
	prefix = strings.Trim(prefix, "/")
	if prefix == "" {
		return name
	}
	return prefix + "/" + name
}

// Backup streams src through gzip into s3://bucket/<prefix>/<UTC-stamp>.sql.gz
// via the multipart path, then writes the manifest alongside. It returns the
// dump object's key. The dump is never buffered whole: the source is gzipped
// into a pipe the uploader reads, so a multi-GB database backs up in constant
// memory. Any source error — including a producer that exits dirty at Close —
// fails the pipe, which makes the multipart upload abort instead of completing
// a truncated backup.
func Backup(ctx context.Context, src DumpSource, cl ObjStore, bucket, prefix string) (string, error) {
	createdAt := nowFunc().UTC()
	key := joinPrefix(prefix, createdAt.Format(keyTimeFormat)+dumpSuffix)

	rc, err := src.Open(ctx)
	if err != nil {
		return "", fmt.Errorf("backup: open dump source: %w", err)
	}

	pr, pw := io.Pipe()
	hash := sha256.New()
	var rawBytes int64
	done := make(chan struct{})
	go func() {
		defer close(done)
		gzw := gzip.NewWriter(pw)
		n, cerr := io.Copy(gzw, io.TeeReader(rc, hash))
		rawBytes = n
		if cerr == nil {
			// Close reports the producer's exit status — a dirty pg_dump exit
			// fails the backup even though its stream ended in a clean EOF.
			cerr = rc.Close()
		} else {
			_ = rc.Close()
		}
		if cerr == nil {
			cerr = gzw.Close()
		}
		if cerr != nil {
			pw.CloseWithError(cerr)
			return
		}
		_ = pw.Close()
	}()

	if err := cl.PutLarge(ctx, bucket, key, pr); err != nil {
		_ = pr.CloseWithError(err) // unblock the gzip goroutine if it is still writing
		<-done
		return "", fmt.Errorf("backup: upload %s/%s: %w", bucket, key, err)
	}
	<-done // hash and rawBytes are final only after the pipe drains

	manifest, err := json.Marshal(Manifest{
		Database:  src.Database(),
		Bytes:     rawBytes,
		SHA256:    hex.EncodeToString(hash.Sum(nil)),
		CreatedAt: createdAt,
	})
	if err != nil {
		return "", fmt.Errorf("backup: encode manifest for %s: %w", key, err)
	}
	if err := cl.PutObject(ctx, bucket, key+manifestSuffix, strings.NewReader(string(manifest))); err != nil {
		return "", fmt.Errorf("backup: write manifest %s/%s%s: %w", bucket, key, manifestSuffix, err)
	}
	return key, nil
}

// Restore downloads bucket/key, gunzips it and streams the SQL into sink. The
// gzip reader's Close is checked so a truncated download fails loudly instead
// of silently restoring a partial dump.
func Restore(ctx context.Context, cl ObjStore, bucket, key string, sink RestoreSink) error {
	rc, err := cl.GetObject(ctx, bucket, key)
	if err != nil {
		return fmt.Errorf("backup: download %s/%s: %w", bucket, key, err)
	}
	defer rc.Close()

	gzr, err := gzip.NewReader(rc)
	if err != nil {
		return fmt.Errorf("backup: %s/%s is not a gzip stream: %w", bucket, key, err)
	}
	if err := sink.Restore(ctx, gzr); err != nil {
		_ = gzr.Close()
		return fmt.Errorf("backup: restore %s/%s: %w", bucket, key, err)
	}
	if err := gzr.Close(); err != nil {
		return fmt.Errorf("backup: %s/%s: corrupt gzip stream: %w", bucket, key, err)
	}
	return nil
}

// List returns every backup under prefix, newest first. Each *.sql.gz key is
// one backup; its manifest (when present and parseable) fills in database,
// bytes and sha256 — a dump whose manifest is missing still lists, dated by
// the object's LastModified, so a hand-uploaded or half-written backup is
// visible rather than invisible.
func List(ctx context.Context, cl ObjStore, bucket, prefix string) ([]BackupInfo, error) {
	objects, err := cl.ListObjects(ctx, bucket, strings.Trim(prefix, "/"))
	if err != nil {
		return nil, fmt.Errorf("backup: list %s/%s*: %w", bucket, prefix, err)
	}
	var infos []BackupInfo
	for _, obj := range objects {
		if !strings.HasSuffix(obj.Key, dumpSuffix) {
			continue
		}
		info := BackupInfo{Key: obj.Key, Stored: obj.Size, CreatedAt: obj.LastModified}
		if man, merr := readManifest(ctx, cl, bucket, obj.Key+manifestSuffix); merr == nil {
			info.Database = man.Database
			info.Bytes = man.Bytes
			info.SHA256 = man.SHA256
			if !man.CreatedAt.IsZero() {
				info.CreatedAt = man.CreatedAt
			}
		}
		infos = append(infos, info)
	}
	sort.Slice(infos, func(i, j int) bool {
		if !infos[i].CreatedAt.Equal(infos[j].CreatedAt) {
			return infos[i].CreatedAt.After(infos[j].CreatedAt)
		}
		return infos[i].Key > infos[j].Key
	})
	return infos, nil
}

func readManifest(ctx context.Context, cl ObjStore, bucket, key string) (Manifest, error) {
	rc, err := cl.GetObject(ctx, bucket, key)
	if err != nil {
		return Manifest{}, err
	}
	defer rc.Close()
	var man Manifest
	if err := json.NewDecoder(rc).Decode(&man); err != nil {
		return Manifest{}, err
	}
	return man, nil
}

// PrunePolicy is the retention rule Prune applies — exactly ONE of the fields
// must be set: Keep > 0 keeps the N most-recent backups and deletes the rest;
// OlderThan > 0 deletes every backup older than the duration.
type PrunePolicy struct {
	Keep      int
	OlderThan time.Duration
}

// Prune deletes the backups under prefix that fall outside policy, each with
// its manifest, and returns the deleted dump keys (newest first, mirroring
// List's order).
func Prune(ctx context.Context, cl ObjStore, bucket, prefix string, policy PrunePolicy) ([]string, error) {
	if (policy.Keep > 0) == (policy.OlderThan > 0) {
		return nil, fmt.Errorf("backup: prune policy must set exactly one of Keep or OlderThan")
	}
	infos, err := List(ctx, cl, bucket, prefix)
	if err != nil {
		return nil, err
	}

	var doomed []BackupInfo
	if policy.Keep > 0 {
		if len(infos) > policy.Keep {
			doomed = infos[policy.Keep:] // infos is newest first
		}
	} else {
		cutoff := nowFunc().UTC().Add(-policy.OlderThan)
		for _, info := range infos {
			if info.CreatedAt.Before(cutoff) {
				doomed = append(doomed, info)
			}
		}
	}

	deleted := make([]string, 0, len(doomed))
	for _, info := range doomed {
		if err := cl.DeleteObject(ctx, bucket, info.Key); err != nil {
			return deleted, fmt.Errorf("backup: prune %s/%s: %w", bucket, info.Key, err)
		}
		// The manifest rides along; S3 DELETE is idempotent, so a manifest that
		// never existed still succeeds.
		if err := cl.DeleteObject(ctx, bucket, info.Key+manifestSuffix); err != nil {
			return deleted, fmt.Errorf("backup: prune manifest %s/%s%s: %w", bucket, info.Key, manifestSuffix, err)
		}
		deleted = append(deleted, info.Key)
	}
	return deleted, nil
}
