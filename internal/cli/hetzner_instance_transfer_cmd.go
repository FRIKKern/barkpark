package cli

// hetzner_instance_transfer_cmd.go — the PORTABLE half of the instance
// lifecycle: `export` and `import` move a Barkpark instance as DATA (logical
// pg_dump + media + identity secrets), where archive/resurrect move it as a
// Hetzner snapshot. Snapshots are perfect but project-bound — they cannot
// cross Hetzner projects, let alone providers. An export tarball can be
// restored onto ANY ssh-able box running Barkpark:
//
//	bp cloud hetzner instance export <fqdn|server|ip>  → bp-export-….tar.gz
//	bp cloud hetzner instance import <file> --target <fqdn|server|ip> --yes
//
// The tarball (format bp-export-v1) carries:
//
//	db.dump        pg_dump --format=custom of barkpark_prod (MVCC-consistent,
//	               no service stop needed)
//	env            the box's /opt/barkpark/.env — because the database is
//	               Cloak-ENCRYPTED at rest: a restore without the source's
//	               BARKPARK_CLOAK_KEY yields unreadable ciphertext
//	uploads/       media files (api/uploads), when any exist
//	manifest.json  {fqdn, db, format}
//
// import is deliberately asymmetric about env: the IDENTITY secrets
// (BARKPARK_CLOAK_KEY, SECRET_KEY_BASE, PREVIEW_JWT_SECRET,
// BARKPARK_INGEST_TOKEN) come from the export — they must match the data —
// while the HOST identity (DATABASE_URL, PHX_HOST, PHX_SCHEME, PORT, MIX_ENV)
// stays the target's own. It then drops + restores the database (hence the
// mandatory --yes), restores media, replays the target's migrations
// (best-effort — the target binary may be newer than the dump), restarts the
// service and health-gates on localhost.
//
// --bucket uploads the export to Hetzner Object Storage instead of a local
// file (HETZNER_S3_* credentials — the Console-created ones).

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// instExportFormat names the tarball layout; import refuses anything else.
const instExportFormat = "bp-export-v1"

// instSSHStream runs command on host as root, streaming its stdout into w —
// the export pipe. A var so tests substitute an in-memory stream.
var instSSHStream = func(host, command string, w io.Writer) error {
	cmd := exec.Command("ssh", instSSHArgs(host, command)...)
	cmd.Stdout = w
	var errBuf strings.Builder
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ssh root@%s: %w: %s", host, err, strings.TrimSpace(errBuf.String()))
	}
	return nil
}

// instSSHFeed runs command on host as root with r as its stdin — the import
// pipe. Combined output rides back in the error on failure and is returned on
// success so callers can look for sentinel lines (the health gate).
var instSSHFeed = func(host, command string, r io.Reader) (string, error) {
	cmd := exec.Command("ssh", instSSHArgs(host, command)...)
	cmd.Stdin = r
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("ssh root@%s: %w: %s", host, err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// instSSHArgs is the shared ssh argv (same key conventions as instSSH).
func instSSHArgs(host, command string) []string {
	key := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY_FILE"))
	if key == "" {
		if home, err := os.UserHomeDir(); err == nil {
			key = filepath.Join(home, ".ssh", "barkpark_indx")
		}
	}
	return []string{
		"-i", key,
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		"root@" + host, command,
	}
}

// instFqdnSafe fences a value embedded in a remote shell script. fqdns and
// labels are DNS names — anything outside their charset is refused rather
// than quoted, so injection is impossible by construction.
var instFqdnSafe = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)

// instExportScript builds the remote export pipeline: stage, dump, collect,
// stream one gzipped tarball to stdout. PURE (string in, string out) so tests
// assert the load-bearing pieces without a box.
func instExportScript(fqdn string) string {
	return `set -e
STAGE=$(mktemp -d /tmp/bp-export.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
sudo -u postgres pg_dump --format=custom --no-owner barkpark_prod > "$STAGE/db.dump"
cp /opt/barkpark/.env "$STAGE/env"
if [ -d /opt/barkpark/api/uploads ]; then cp -R /opt/barkpark/api/uploads "$STAGE/uploads"; fi
printf '{"fqdn":"%s","db":"barkpark_prod","format":"%s"}' '` + fqdn + `' '` + instExportFormat + `' > "$STAGE/manifest.json"
tar -C "$STAGE" -czf - .`
}

// instImportScript builds the remote import pipeline: unpack from stdin,
// merge the identity secrets, drop + restore the database as the target's own
// DB role, restore media, replay migrations (best-effort), restart, health-
// gate on localhost. Emits BP_IMPORT_HEALTH_OK as the success sentinel. PURE.
func instImportScript() string {
	return `set -e
STAGE=$(mktemp -d /tmp/bp-import.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
tar -C "$STAGE" -xzf -
test -f "$STAGE/db.dump" || { echo "no db.dump in the archive" >&2; exit 1; }
test -f "$STAGE/env" || { echo "no env in the archive" >&2; exit 1; }
grep -q '` + instExportFormat + `' "$STAGE/manifest.json" || { echo "not a ` + instExportFormat + ` archive" >&2; exit 1; }
systemctl stop barkpark
# Identity secrets travel WITH the data (the DB is Cloak-encrypted); the
# target keeps its own DATABASE_URL/PHX_HOST/PHX_SCHEME/PORT/MIX_ENV.
for key in SECRET_KEY_BASE BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_INGEST_TOKEN; do
  v=$(grep "^$key=" "$STAGE/env" | head -1 || true)
  if [ -n "$v" ]; then
    grep -v "^$key=" /opt/barkpark/.env > /opt/barkpark/.env.new || true
    printf '%s\n' "$v" >> /opt/barkpark/.env.new
    mv /opt/barkpark/.env.new /opt/barkpark/.env
  fi
done
DBUSER=$(grep '^DATABASE_URL=' /opt/barkpark/.env | sed -E 's|.*//([^:@/]+)[:@].*|\1|')
sudo -u postgres psql -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS barkpark_prod'
sudo -u postgres createdb -O "${DBUSER:-postgres}" barkpark_prod
sudo -u postgres pg_restore --no-owner --role="${DBUSER:-postgres}" -d barkpark_prod "$STAGE/db.dump"
rm -rf /opt/barkpark/api/uploads
if [ -d "$STAGE/uploads" ]; then cp -R "$STAGE/uploads" /opt/barkpark/api/uploads; fi
# Replay the target's migrations: the dump may predate the target's code.
(set +e; set -a; . /opt/barkpark/.env; set +a; cd /opt/barkpark/api && bash -lc 'mix ecto.migrate' >/dev/null 2>&1; true)
systemctl start barkpark
PORT=$(grep '^PORT=' /opt/barkpark/.env | cut -d= -f2)
curl -sf -m 60 --retry 30 --retry-delay 3 --retry-connrefused "http://localhost:${PORT:-4000}/api/schemas" > /dev/null
echo BP_IMPORT_HEALTH_OK`
}

// instTransferHost resolves an export/import endpoint to an SSH-able address:
// a literal IP rides as-is (the "anywhere" case — the box need not be in this
// Hetzner project, or in Hetzner at all), anything else goes through the
// managed-fleet lookup. Returns (host, fqdn-or-empty).
func instTransferHost(out *writer, g globals, target, zone, fqdnFlag string) (string, string, bool) {
	if ip := net.ParseIP(target); ip != nil {
		fqdn := fqdnFlag
		if fqdn == "" {
			fqdn = target
		}
		return target, fqdn, true
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return "", "", false
	}
	srv, fqdn, err := instTarget(hetznerCtx(), c.HCloud(), target, zone, fqdnFlag)
	if err != nil {
		hzFail(out, "resolve "+target, err)
		return "", "", false
	}
	if srv == nil {
		useError(out, "failed", "no server carries the identity "+fqdn+" — pass an IP to reach a box outside this project", exitNotFound)
		return "", "", false
	}
	return hzIPv4(srv), fqdn, true
}

func runInstanceExport(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance export <fqdn|server|ip> [--out <file>] [--zone <z>] [--fqdn <f>] [--bucket <b> [--key <k>] [--location <l>] [--s3-access-key <k>] [--s3-secret-key <k>]]"
	a, err := parseHzArgs(args, hzS3Flags("out", "zone", "fqdn", "bucket", "key"), nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|server|ip> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	host, fqdn, ok := instTransferHost(out, g, a.pos[0], zone, a.val("fqdn"))
	if !ok {
		return exitGeneric
	}
	if !instFqdnSafe.MatchString(fqdn) {
		return useError(out, "usage", fmt.Sprintf("fqdn %q contains characters outside the DNS charset", fqdn), exitUsage)
	}

	script := instExportScript(fqdn)

	// S3 sink: stream straight to Object Storage, no local temp file.
	if bucket := a.val("bucket"); bucket != "" {
		s3, sok := hzS3Client(out, a)
		if !sok {
			return exitAuth
		}
		key := a.val("key")
		if key == "" {
			key = "bp-export-" + strings.ReplaceAll(fqdn, ".", "-") + "-" + time.Now().UTC().Format("20060102-150405") + ".tar.gz"
		}
		pr, pw := io.Pipe()
		errCh := make(chan error, 1)
		go func() {
			errCh <- instSSHStream(host, script, pw)
			_ = pw.Close()
		}()
		if perr := s3.PutLarge(hetznerCtx(), bucket, key, pr); perr != nil {
			return useError(out, "failed", "export "+fqdn+": upload: "+perr.Error(), exitGeneric)
		}
		if serr := <-errCh; serr != nil {
			return useError(out, "failed", "export "+fqdn+": "+serr.Error(), exitGeneric)
		}
		return instTransferDone(out, "export", fqdn, map[string]any{"bucket": bucket, "key": key})
	}

	outPath := a.val("out")
	if outPath == "" {
		outPath = "bp-export-" + strings.ReplaceAll(fqdn, ".", "-") + "-" + time.Now().UTC().Format("20060102-150405") + ".tar.gz"
	}
	f, ferr := os.Create(outPath)
	if ferr != nil {
		return useError(out, "failed", "export "+fqdn+": "+ferr.Error(), exitGeneric)
	}
	if serr := instSSHStream(host, script, f); serr != nil {
		_ = f.Close()
		_ = os.Remove(outPath) // never leave a truncated archive looking valid
		return useError(out, "failed", "export "+fqdn+": "+serr.Error(), exitGeneric)
	}
	if cerr := f.Close(); cerr != nil {
		return useError(out, "failed", "export "+fqdn+": "+cerr.Error(), exitGeneric)
	}
	info, _ := os.Stat(outPath)
	extra := map[string]any{"file": outPath}
	if info != nil {
		extra["bytes"] = info.Size()
	}
	return instTransferDone(out, "export", fqdn, extra)
}

func runInstanceImport(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance import <file> --target <fqdn|server|ip> --yes [--zone <z>]"
	a, err := parseHzArgs(args, []string{"target", "zone"}, []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("target") == "" {
		return useError(out, "usage", "want <file> and --target (usage: "+usage+")", exitUsage)
	}
	if !a.bools["yes"] {
		return useError(out, "usage", "import OVERWRITES the target's database and media — re-run with --yes to confirm", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	host, fqdn, ok := instTransferHost(out, g, a.val("target"), zone, "")
	if !ok {
		return exitGeneric
	}
	f, ferr := os.Open(a.pos[0])
	if ferr != nil {
		return useError(out, "failed", "import: "+ferr.Error(), exitGeneric)
	}
	defer f.Close()

	output, serr := instSSHFeed(host, instImportScript(), f)
	if serr != nil {
		return useError(out, "failed", "import onto "+fqdn+": "+serr.Error(), exitGeneric)
	}
	if !strings.Contains(output, "BP_IMPORT_HEALTH_OK") {
		return useError(out, "failed", "import onto "+fqdn+": restore ran but the health sentinel never appeared:\n"+strings.TrimSpace(output), exitGeneric)
	}
	return instTransferDone(out, "import", fqdn, map[string]any{"file": a.pos[0], "health": "ok"})
}

// instTransferDone reports an export/import receipt (no *hcloud.Server here —
// the endpoint may be a bare IP outside the project).
func instTransferDone(out *writer, action, fqdn string, extra map[string]any) int {
	payload := map[string]any{"ok": true, "action": action, "fqdn": fqdn}
	for k, v := range extra {
		payload[k] = v
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("✓ %s %s", action, fqdn)
	for k, v := range extra {
		out.outf("  %s: %v", k, v)
	}
	return exitOK
}
