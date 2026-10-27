package cli

// instance_backup_cmd.go is `bp instance backup` and `bp instance restore`: a
// backup of one self-hosted instance taken from any Postgres reachable by URL
// and any media directory, with no SSH, no sudo and no /opt/barkpark layout.
//
//	bp instance backup  --database-url <url> --media-dir <dir> --out <dir>
//	bp instance restore <dir> --database-url <url> --media-dir <dir>
//
// The backup is one directory with three members. db.dump and media.tar.gz use
// the same names and formats as a bp-bundle-v1 (internal/cli/cloud/bundle.go):
//
//	db.dump        pg_dump --format=custom --no-owner --no-privileges
//	media.tar.gz   the media directory (directories and regular files only)
//	manifest.json  bp-instance-backup-v1, written last: Postgres major,
//	               document counts per type, sha256 of both members and of
//	               every media file
//
// Key material is never read or written. The app's keys (cloud.IdentitySecretKeys)
// must come from the operator's secret store at restore time; the manifest says
// so. The document counts and the dump come from one exported snapshot, so a
// backup of a live instance is consistent.
//
// Restore refuses an older Postgres major, a non-empty database and a
// non-empty media directory, verifies both member checksums before it touches
// anything, and after pg_restore checks every media file and every per-type
// count against the manifest. Any difference fails the command.

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

const (
	instanceBackupFormat   = "bp-instance-backup-v1"
	instanceBackupDB       = "db.dump"
	instanceBackupMedia    = "media.tar.gz"
	instanceBackupManifest = "manifest.json"
	instanceBackupDocCount = "SELECT type || E'\\t' || count(*) FROM documents GROUP BY type ORDER BY type;"
	instanceBackupEndMark  = "bp-instance-backup-end"
)

// instanceBackupFile is one checksummed file. Path is relative to the backup
// directory for members and to the media directory for media files.
type instanceBackupFile struct {
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}

type instanceBackupSecrets struct {
	Included bool     `json:"included"`
	Keys     []string `json:"keys"`
	Note     string   `json:"note"`
}

type instanceBackupManifestV1 struct {
	Format        string                `json:"format"`
	CreatedAt     time.Time             `json:"created_at"`
	Database      string                `json:"database"`
	PostgresMajor int                   `json:"postgres_major"`
	Documents     map[string]int64      `json:"documents"`
	DB            instanceBackupFile    `json:"db"`
	MediaArchive  instanceBackupFile    `json:"media_archive"`
	Media         []instanceBackupFile  `json:"media"`
	Secrets       instanceBackupSecrets `json:"secrets"`
}

// instanceBackupFlags reads --database-url and --media-dir, falling back to the
// DATABASE_URL and BARKPARK_MEDIA_DIR the app itself reads. An Ecto-style
// ecto:// URL is rewritten to postgresql:// so libpq accepts it.
func instanceBackupFlags(a *hzArgs) (dbURL, mediaDir string, err error) {
	dbURL = strings.TrimSpace(a.val("database-url"))
	if dbURL == "" {
		dbURL = strings.TrimSpace(os.Getenv("DATABASE_URL"))
	}
	mediaDir = strings.TrimSpace(a.val("media-dir"))
	if mediaDir == "" {
		mediaDir = strings.TrimSpace(os.Getenv("BARKPARK_MEDIA_DIR"))
	}
	if dbURL == "" {
		return "", "", fmt.Errorf("--database-url (or DATABASE_URL) is required")
	}
	if mediaDir == "" {
		return "", "", fmt.Errorf("--media-dir (or BARKPARK_MEDIA_DIR) is required")
	}
	if rest, ok := strings.CutPrefix(dbURL, "ecto://"); ok {
		dbURL = "postgresql://" + rest
	}
	for _, tool := range []string{"pg_dump", "pg_restore", "psql"} {
		if _, lerr := exec.LookPath(tool); lerr != nil {
			return "", "", fmt.Errorf("%s is not on PATH: install the Postgres client tools for the server's major version", tool)
		}
	}
	return dbURL, mediaDir, nil
}

func runInstanceBackup(out *writer, args []string) int {
	const usage = "bp instance backup --database-url <url> --media-dir <dir> --out <dir>"
	a, err := parseHzArgs(args, []string{"database-url", "media-dir", "out"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	outDir := strings.TrimSpace(a.val("out"))
	if outDir == "" || len(a.pos) != 0 {
		return useError(out, "usage", "--out <dir> is required (usage: "+usage+")", exitUsage)
	}
	dbURL, mediaDir, err := instanceBackupFlags(a)
	if err != nil {
		return useError(out, "usage", err.Error()+" (usage: "+usage+")", exitUsage)
	}
	man, err := instanceBackup(context.Background(), dbURL, mediaDir, outDir)
	if err != nil {
		return useError(out, "failed", "backup: "+err.Error(), exitGeneric)
	}
	if out.emitStructured(map[string]any{"ok": true, "action": "backup", "dir": outDir, "manifest": man}) {
		return exitOK
	}
	out.outf("backed up %s: %d document types, %d media files, Postgres %d, to %s",
		man.Database, len(man.Documents), len(man.Media), man.PostgresMajor, outDir)
	out.outf("keys are not in the backup: restore needs %s from your secret store", strings.Join(man.Secrets.Keys, ", "))
	return exitOK
}

func runInstanceRestore(out *writer, args []string) int {
	const usage = "bp instance restore <dir> --database-url <url> --media-dir <dir>"
	a, err := parseHzArgs(args, []string{"database-url", "media-dir"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one backup <dir> (usage: "+usage+")", exitUsage)
	}
	dbURL, mediaDir, err := instanceBackupFlags(a)
	if err != nil {
		return useError(out, "usage", err.Error()+" (usage: "+usage+")", exitUsage)
	}
	man, err := instanceRestore(context.Background(), a.pos[0], dbURL, mediaDir)
	if err != nil {
		return useError(out, "failed", "restore: "+err.Error(), exitGeneric)
	}
	if out.emitStructured(map[string]any{"ok": true, "action": "restore", "dir": a.pos[0], "verified": true, "manifest": man}) {
		return exitOK
	}
	out.outf("restored %s: %d document types and %d media files match the manifest", a.pos[0], len(man.Documents), len(man.Media))
	out.outf("load %s from your secret store before starting the app", strings.Join(man.Secrets.Keys, ", "))
	return exitOK
}

// instanceBackup writes the backup into outDir, which must be absent or empty.
func instanceBackup(ctx context.Context, dbURL, mediaDir, outDir string) (instanceBackupManifestV1, error) {
	var man instanceBackupManifestV1
	if err := requireEmptyDir(outDir); err != nil {
		return man, err
	}
	media, err := hashMediaDir(mediaDir)
	if err != nil {
		return man, err
	}
	if err := os.MkdirAll(outDir, 0o700); err != nil {
		return man, err
	}

	// One REPEATABLE READ transaction exports its snapshot; the counts are read
	// in it and pg_dump dumps from it, so both describe the same data.
	sess := pgCommand(ctx, "psql", dbURL, "--no-psqlrc", "--quiet", "--tuples-only", "--no-align", "--set", "ON_ERROR_STOP=1")
	stdin, _ := sess.StdinPipe()
	stdout, _ := sess.StdoutPipe()
	var stderr strings.Builder
	sess.Stderr = &stderr
	if err := sess.Start(); err != nil {
		return man, fmt.Errorf("psql: %w", err)
	}
	fmt.Fprintf(stdin, "BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY;\nSELECT pg_export_snapshot();\nSHOW server_version_num;\nSELECT current_database();\n%s\n\\echo %s\n",
		instanceBackupDocCount, instanceBackupEndMark)
	var lines []string
	ended := false
	sc := bufio.NewScanner(stdout)
	for !ended && sc.Scan() {
		if ended = sc.Text() == instanceBackupEndMark; !ended {
			lines = append(lines, sc.Text())
		}
	}
	finish := func() error {
		fmt.Fprintln(stdin, "COMMIT;")
		stdin.Close()
		_, _ = io.Copy(io.Discard, stdout)
		if err := sess.Wait(); err != nil {
			return fmt.Errorf("psql: %w: %s", err, strings.TrimSpace(stderr.String()))
		}
		return nil
	}
	if !ended || len(lines) < 3 {
		_ = stdin.Close()
		_ = sess.Wait()
		return man, fmt.Errorf("psql: could not read the snapshot and document counts: %s", strings.TrimSpace(stderr.String()))
	}
	snapshot, version, dbName := lines[0], lines[1], lines[2]
	if man.PostgresMajor, err = pgMajor(version); err != nil {
		_ = finish()
		return man, err
	}
	if man.Documents, err = parseDocCounts(lines[3:]); err != nil {
		_ = finish()
		return man, err
	}
	dumpPath := filepath.Join(outDir, instanceBackupDB)
	dump := pgCommand(ctx, "pg_dump", dbURL, "--format=custom", "--no-owner", "--no-privileges", "--snapshot="+snapshot, "--file="+dumpPath)
	if b, derr := dump.CombinedOutput(); derr != nil {
		_ = finish()
		return man, fmt.Errorf("pg_dump: %w: %s", derr, strings.TrimSpace(string(b)))
	}
	if err := finish(); err != nil {
		return man, err
	}
	// pg_dump creates the file with the umask, 0644 on most hosts. It holds
	// password and token hashes, so keep it as private as the other members.
	if err := os.Chmod(dumpPath, 0o600); err != nil {
		return man, err
	}

	mediaPath := filepath.Join(outDir, instanceBackupMedia)
	f, err := os.OpenFile(mediaPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return man, err
	}
	werr := writeTarball(f, mediaDir, nil, 0, nil)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return man, fmt.Errorf("pack media: %w", werr)
	}

	man.Format = instanceBackupFormat
	man.CreatedAt = time.Now().UTC().Truncate(time.Second)
	man.Database = dbName
	man.Media = media
	man.Secrets = instanceBackupSecretsNote()
	if man.DB, err = hashFile(outDir, instanceBackupDB); err != nil {
		return man, err
	}
	if man.MediaArchive, err = hashFile(outDir, instanceBackupMedia); err != nil {
		return man, err
	}
	b, err := json.MarshalIndent(man, "", "  ")
	if err != nil {
		return man, err
	}
	// The manifest is written last: a backup directory without one is incomplete.
	return man, os.WriteFile(filepath.Join(outDir, instanceBackupManifest), append(b, '\n'), 0o600)
}

// instanceRestore restores the backup in dir into an empty database and an
// empty media directory, then verifies the result against the manifest.
func instanceRestore(ctx context.Context, dir, dbURL, mediaDir string) (instanceBackupManifestV1, error) {
	var man instanceBackupManifestV1
	raw, err := os.ReadFile(filepath.Join(dir, instanceBackupManifest))
	if err != nil {
		return man, fmt.Errorf("read manifest: %w", err)
	}
	if err := json.Unmarshal(raw, &man); err != nil {
		return man, fmt.Errorf("read manifest: %w", err)
	}
	if man.Format != instanceBackupFormat {
		return man, fmt.Errorf("%s is %q, not a %s backup", instanceBackupManifest, man.Format, instanceBackupFormat)
	}
	for _, want := range []instanceBackupFile{man.DB, man.MediaArchive} {
		got, herr := hashFile(dir, want.Path)
		if herr != nil {
			return man, herr
		}
		if got != want {
			return man, fmt.Errorf("%s does not match the manifest: manifest has %d bytes sha256 %s, file has %d bytes sha256 %s",
				want.Path, want.Bytes, want.SHA256, got.Bytes, got.SHA256)
		}
	}

	version, err := psqlQuery(ctx, dbURL, "SHOW server_version_num;")
	if err != nil {
		return man, err
	}
	major, err := pgMajor(strings.TrimSpace(version))
	if err != nil {
		return man, err
	}
	if err := restoreMajorAllowed(man.PostgresMajor, major); err != nil {
		return man, err
	}
	tables, err := psqlQuery(ctx, dbURL, "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';")
	if err != nil {
		return man, err
	}
	if strings.TrimSpace(tables) != "0" {
		return man, fmt.Errorf("the target database already has %s tables: restore needs an empty database", strings.TrimSpace(tables))
	}
	if err := requireEmptyDir(mediaDir); err != nil {
		return man, err
	}

	restore := pgCommand(ctx, "pg_restore", dbURL, "--no-owner", "--no-privileges", "--exit-on-error", "--single-transaction", filepath.Join(dir, man.DB.Path))
	if b, rerr := restore.CombinedOutput(); rerr != nil {
		return man, fmt.Errorf("pg_restore: %w: %s", rerr, strings.TrimSpace(string(b)))
	}
	if err := extractMedia(filepath.Join(dir, man.MediaArchive.Path), mediaDir); err != nil {
		return man, err
	}

	var faults []string
	media, err := hashMediaDir(mediaDir)
	if err != nil {
		return man, err
	}
	faults = append(faults, diffMedia(man.Media, media)...)
	countRows, err := psqlQuery(ctx, dbURL, instanceBackupDocCount)
	if err != nil {
		return man, err
	}
	counts, err := parseDocCounts(strings.Split(countRows, "\n"))
	if err != nil {
		return man, err
	}
	faults = append(faults, diffCounts(man.Documents, counts)...)
	if len(faults) > 0 {
		return man, fmt.Errorf("the restored instance does not match the manifest:\n  %s", strings.Join(faults, "\n  "))
	}
	return man, nil
}

func instanceBackupSecretsNote() instanceBackupSecrets {
	keys := append(append([]string{}, cloud.IdentitySecretKeys...), "BARKPARK_KEK_PREVIOUS")
	return instanceBackupSecrets{
		Included: false,
		Keys:     keys,
		Note:     "No key material is in this backup. Load these keys from the secret store the source instance used; BARKPARK_KEK_PREVIOUS only if it was set. Without the source's BARKPARK_CLOAK_KEY and BARKPARK_KEK the encrypted fields stay unreadable.",
	}
}

// psqlQuery runs one query and returns its unaligned, tuples-only output.
func psqlQuery(ctx context.Context, dbURL, query string) (string, error) {
	cmd := pgCommand(ctx, "psql", dbURL, "--no-psqlrc", "--quiet", "--tuples-only", "--no-align", "--set", "ON_ERROR_STOP=1", "--command", query)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	b, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("psql: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimRight(string(b), "\n"), nil
}

// restoreMajorAllowed lets a backup restore into the same or a newer Postgres
// major. pg_restore reads archives from older servers, and a move from a
// single VM (Ubuntu's Postgres 14 or 16) onto Flexible Server 17 needs it. An
// older target is refused: its pg_restore cannot be trusted with a newer dump.
func restoreMajorAllowed(backup, target int) error {
	if target < backup {
		return fmt.Errorf("the backup is from Postgres %d and the target runs Postgres %d: restore into Postgres %d or newer",
			backup, target, backup)
	}
	return nil
}

func pgMajor(versionNum string) (int, error) {
	n, err := strconv.Atoi(strings.TrimSpace(versionNum))
	if err != nil || n < 100000 {
		return 0, fmt.Errorf("unexpected server_version_num %q: Postgres 10 or newer is required", versionNum)
	}
	return n / 10000, nil
}

func parseDocCounts(lines []string) (map[string]int64, error) {
	counts := map[string]int64{}
	for _, line := range lines {
		if line == "" {
			continue
		}
		typ, n, ok := strings.Cut(line, "\t")
		v, err := strconv.ParseInt(n, 10, 64)
		if !ok || err != nil {
			return nil, fmt.Errorf("unexpected document count row %q", line)
		}
		counts[typ] = v
	}
	return counts, nil
}

func diffCounts(want, got map[string]int64) []string {
	var faults []string
	for typ, n := range want {
		if got[typ] != n {
			faults = append(faults, fmt.Sprintf("documents of type %q: manifest has %d, database has %d", typ, n, got[typ]))
		}
	}
	for typ, n := range got {
		if _, ok := want[typ]; !ok {
			faults = append(faults, fmt.Sprintf("documents of type %q: manifest has 0, database has %d", typ, n))
		}
	}
	sort.Strings(faults)
	return faults
}

func diffMedia(want, got []instanceBackupFile) []string {
	have := make(map[string]instanceBackupFile, len(got))
	for _, f := range got {
		have[f.Path] = f
	}
	var faults []string
	for _, w := range want {
		g, ok := have[w.Path]
		switch {
		case !ok:
			faults = append(faults, "media file "+w.Path+" is missing")
		case g != w:
			faults = append(faults, fmt.Sprintf("media file %s: manifest has sha256 %s, restored file has sha256 %s", w.Path, w.SHA256, g.SHA256))
		}
		delete(have, w.Path)
	}
	for p := range have {
		faults = append(faults, "media file "+p+" is not in the manifest")
	}
	sort.Strings(faults)
	return faults
}

// requireEmptyDir accepts a missing directory or an empty one.
func requireEmptyDir(dir string) error {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if len(entries) > 0 {
		return fmt.Errorf("%s is not empty: use a new or empty directory", dir)
	}
	return nil
}

func hashFile(dir, name string) (instanceBackupFile, error) {
	f, err := os.Open(filepath.Join(dir, filepath.FromSlash(name)))
	if err != nil {
		return instanceBackupFile{}, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return instanceBackupFile{}, err
	}
	return instanceBackupFile{Path: name, Bytes: n, SHA256: hex.EncodeToString(h.Sum(nil))}, nil
}

// hashMediaDir checksums every regular file under dir. A missing directory is
// an empty media store. Symlinks and special files are refused so the archive
// holds only what restore can recreate exactly.
func hashMediaDir(dir string) ([]instanceBackupFile, error) {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return []instanceBackupFile{}, nil
	}
	files := []instanceBackupFile{}
	err := walkTarballEntries(dir, nil, func(path, rel string, info os.FileInfo) error {
		if info.IsDir() {
			return nil
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("media entry %s is not a regular file or directory", rel)
		}
		f, err := hashFile(dir, filepath.ToSlash(rel))
		if err != nil {
			return err
		}
		files = append(files, f)
		return nil
	})
	return files, err
}

// extractMedia unpacks a media.tar.gz into dir, refusing any entry that would
// land outside it and any entry that is not a directory or a regular file.
func extractMedia(archive, dir string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("%s: %w", archive, err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", archive, err)
		}
		rel := filepath.FromSlash(strings.TrimSuffix(hdr.Name, "/"))
		if !filepath.IsLocal(rel) {
			return fmt.Errorf("%s: refusing entry %q outside the media directory", archive, hdr.Name)
		}
		target := filepath.Join(dir, rel)
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
			if err != nil {
				return err
			}
			_, err = io.Copy(out, tr)
			if cerr := out.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return err
			}
		default:
			return fmt.Errorf("%s: refusing entry %q: not a directory or regular file", archive, hdr.Name)
		}
	}
}
