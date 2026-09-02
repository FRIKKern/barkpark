package cloud

// restore_driver.go — RestoreExecutor, the REAL work behind the provisioner's
// RestoreDriver seam (charter S14f / Decision 46): the provider + object-store +
// on-box actions of a portable-bundle RESURRECT. It composes the proven cloud
// primitives so the resurrect chain is not a fork:
//
//   - create    CreateWithFallback cold create (D40 — a resurrect NEVER warm-
//               assigns), stamping the box's barkpark-fqdn identity label so the
//               ordinary Remove/deprovision path can find it later.
//   - freshen   FreshenPlan scripts over the per-host runner (azure runs the
//               from-scratch base install; hetzner rides the baked warm-image).
//   - secure    an A-record repoint through the DNS seam (provider-orthogonal).
//   - configure the CARRIED-KEK unseal (OpenSecretsWithKEK — never env, never
//               minted) + an idempotent .env identity merge, then the agent beat.
//   - content   pg_restore of the bundle's db.dump + media, streamed into the box
//               over the NEW StdinStepRunner feed (the import-feed inverse).
//
// Verify (the golden-path gate) stays in the provisioner package — it is the one
// step this executor does NOT own, because the probe lives next to the worker's
// verify machinery. This type is deliberately cloud-native (it names no
// provisioner types, so package cloud stays import-cycle-free); the provisioner's
// CloudRestoreDriver is the thin adapter that satisfies the RestoreDriver
// interface and calls these methods, translating JobSpec/BundleRef into their
// pieces.
//
// Every field is an INJECTED seam (Provider/DNS/RunnerFor/Store), so the whole
// round-trip is proven offline against the fakes — no gate ever creates a box,
// dials S3, or SSHes anywhere.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
	"time"
)

// RestoreExecutor holds the injected seams a resurrect restore drives. In
// production main() fills it with the real Hetzner provider/DNS + the object store
// built from the worker's S3 env; tests fill it with FakeProvider/FakeDNS/a
// recording runner + a FakeBundleStore preloaded with a real WriteBundle output.
type RestoreExecutor struct {
	// Provider is the DEFAULT provider (the hetzner one main wires). An azure
	// resurrect resolves its own provider from the claim's decrypted creds via
	// ProviderFor, so this field is used only for the hetzner path + teardown.
	Provider CloudProvider
	// DNS repoints the bundle's fqdn A-record at the fresh box (the secure step).
	DNS DNSProvider
	// RunnerFor builds the per-host StepRunner (SSH in prod, a recorder in tests).
	// The restore's content step needs it to also satisfy StdinStepRunner.
	RunnerFor func(host string) StepRunner
	// Store is the object store the bundle lives in — built once from the worker's
	// S3 env (same creds the archive command uses). The manifest read that
	// TRANSLATES the claim happens worker-side; this store serves the member fetches
	// (secrets.enc, db.dump, media.tar.gz) the driver's on-box steps need.
	Store BundleStore
	// Mail is the shared relay (unused by restore today — identity comes from the
	// bundle — but carried so a future .env merge can point the box at it).
	Mail MailRelay
	// TrustedProxies is the control plane's EGRESS address, written into the
	// resurrected box's BARKPARK_TRUSTED_PROXIES. A resurrect does NOT run
	// configureHost (it is its own chain), so without this a resurrected box would
	// come back with loopback-only trust and silently keep ONE rate-limit bucket per
	// team for every proxied request. The archived bundle carries identity, never
	// this: the trust list is a property of the CURRENT control plane, not of the
	// box's past. Empty → the step is skipped, as before this field existed.
	TrustedProxies string
	// ControlURL is the origin the on-box agent beats to (InstallAgent writes it).
	ControlURL string
}

// azureRestoreUser is the non-root admin an AZURE box provisions (D56): the SSH key
// lands ONLY in /home/<user>/.ssh/authorized_keys and stock Canonical images lock
// root, so every azure restore step SSHes as this user and reaches root via sudo. It
// mirrors azure.DefaultAdminUsername (kept a local literal — package cloud cannot
// import cloud/azure, which imports cloud, without a cycle).
const azureRestoreUser = "barkpark"

// restoreRunner builds the per-host StepRunner for one restore step, applying the
// PER-PROVIDER ssh policy. Hetzner (and any other/empty kind) keeps the byte-
// identical root/no-sudo path the whole provisioner shares. AZURE boxes provision
// only the non-root barkpark admin (D56) while azure-base-install + the on-box
// restore pipeline require root, so an azure runner SSHes as barkpark and sudo-wraps
// every step. The user+sudo are set on the concrete *SSHStepRunner the production
// factory returns fresh per call; a non-SSH runner (a test recorder) is returned
// unchanged — the azure argv is proven at the SSHStepRunner level, and the scripts
// themselves stay byte-identical across providers (only the transport differs).
func (e *RestoreExecutor) restoreRunner(kind, ip string) StepRunner {
	r := e.RunnerFor(ip)
	if kind == ProviderAzure {
		if ssh, ok := r.(*SSHStepRunner); ok {
			ssh.User = azureRestoreUser
			ssh.Sudo = true
		}
	}
	return r
}

// restoreHealthURL is where the on-box agent self-probes after a resurrect. The
// agent runs ON the box, so localhost is the truthful target (and needs no fqdn
// threaded through the interface's agentless InstallAgent signature).
const restoreHealthURL = "http://localhost:4000/api/schemas"

// dbNameSafe fences a database name before it is interpolated into the restore
// shell — a postgres identifier, so anything outside [A-Za-z0-9_] is refused
// rather than quoted (injection-impossible by construction, the instFqdnSafe
// idiom).
var dbNameSafe = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

// secretKeyShape fences an identity-secret KEY before it is interpolated into the
// .env merge script (grep pattern + printf format). Values already ride
// secretValueAlphabet; keys get the env-var shape for the same reason — a torn or
// foreign bundle must fail loudly, never leak bytes into the box's shell.
var secretKeyShape = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)

// CreateHost cold-creates a fresh box for kind and returns its live IP. It is
// ALWAYS a cold create (D40 — a resurrect must land the bundle's sealed identity,
// so it can never take a warm box carrying the wrong empty identity). The box is
// stamped with its barkpark-fqdn identity label FAIL-CLOSED, so a later Remove can
// resolve it (and TearDown can reclaim an orphan) — an un-labelable box is torn
// down rather than leaked.
func (e *RestoreExecutor) CreateHost(ctx context.Context, kind string, creds map[string]string, base ServerSpec, fqdn string) (string, error) {
	provider, err := e.providerFor(kind, creds)
	if err != nil {
		return "", err
	}
	label, _ := splitFqdn(fqdn)
	base.Name = oneShotServerName(label)
	host, _, err := CreateWithFallback(ctx, provider, base)
	if err != nil {
		return "", fmt.Errorf("resurrect create %q: %w", base.Name, err)
	}

	// Stamp the box's stable identity (barkpark-fqdn) so the ordinary
	// deprovision/Remove path — which matches by this label, never IP alone — can
	// find it. FAIL CLOSED: an un-labelable box can't be safely removed later, so
	// tear it down now rather than leak an unidentifiable billed orphan.
	if labeler, ok := provider.(ServerLabeler); ok {
		if lerr := labeler.LabelServer(ctx, host.Name, FQDNLabelKey, fqdn); lerr != nil {
			if derr := provider.Delete(ctx, host.Name); derr != nil {
				return "", fmt.Errorf("resurrect label fqdn %q failed (%v) AND teardown of %s failed: %w", fqdn, lerr, host.Name, derr)
			}
			return "", fmt.Errorf("resurrect label fqdn %q: %w (box %s torn down)", fqdn, lerr, host.Name)
		}
	}

	// Wait for sshd on a freshly-created box before any configure step SSHes in.
	// Runners that don't probe (the test fakes) skip it — the same capability gate
	// configureHost uses.
	if e.RunnerFor != nil {
		if rw, ok := e.restoreRunner(kind, host.IP).(sshReadyWaiter); ok {
			if err := rw.WaitReady(ctx, sshReadyTimeout); err != nil {
				return "", fmt.Errorf("resurrect ssh not ready on %s: %w", host.IP, err)
			}
		}
	}
	return host.IP, nil
}

// Freshen brings the fresh box to a runnable Barkpark. Azure has no snapshot
// substrate, so it runs the from-scratch base install (D41); a hetzner box booted
// the baked warm-image and is already current, so its freshen is a light marker.
func (e *RestoreExecutor) Freshen(ctx context.Context, kind, ip string) error {
	if e.RunnerFor == nil {
		return fmt.Errorf("resurrect freshen: no runner factory wired")
	}
	return e.restoreRunner(kind, ip).Run(ctx, restoreFreshenStep(kind))
}

// RepointDNS points the bundle's fqdn A-record at the fresh box (the secure step).
func (e *RestoreExecutor) RepointDNS(ctx context.Context, fqdn, ip string) error {
	if e.DNS == nil {
		return fmt.Errorf("resurrect secure: no DNS provider wired")
	}
	name, zone := splitFqdn(fqdn)
	if name == "" || zone == "" {
		return fmt.Errorf("resurrect secure: fqdn %q is not <label>.<zone>", fqdn)
	}
	return e.DNS.UpsertRecord(ctx, Record{Zone: zone, Name: name, Type: "A", Value: ip})
}

// InstallSecrets unseals the bundle's identity secrets with the CARRIED kek
// (OpenSecretsWithKEK — never the env key, never minted) and merges them
// idempotently into the box's .env. It does NOT restart the service — the restart
// happens after the DATA lands (RestoreData's tail), so the box comes up ONCE with
// both the restored identity and the restored database.
func (e *RestoreExecutor) InstallSecrets(ctx context.Context, kind, prefix, kek, ip string) error {
	if e.Store == nil {
		return fmt.Errorf("resurrect configure: no bundle store wired")
	}
	if e.RunnerFor == nil {
		return fmt.Errorf("resurrect configure: no runner factory wired")
	}
	// Shape-gate the trust list FIRST: it is a pure string check, so a malformed
	// worker env fails the resurrect before a single byte is unsealed or shipped —
	// rather than leaving a .env that raises at the restart RestoreData ends with.
	egress, err := NormalizeTrustedProxies(e.TrustedProxies)
	if err != nil {
		return fmt.Errorf("resurrect configure: BARKPARK_CLOUD_EGRESS_IPS is malformed: %w", err)
	}
	secrets, err := OpenSecretsWithKEK(ctx, e.Store, prefix, kek)
	if err != nil {
		return err
	}
	step, err := restoreSecretsEnvStep(secrets)
	if err != nil {
		return err
	}
	runner := e.restoreRunner(kind, ip)
	// The trust list rides along with the identity merge — both are .env edits, and
	// the single restart that loads them comes later, at RestoreData's tail.
	if egress != "" {
		if err := runner.Run(ctx, trustedProxiesStep(egress)); err != nil {
			return fmt.Errorf("resurrect configure: trusted proxies: %w", err)
		}
	}
	return runner.Run(ctx, step)
}

// InstallAgent writes the freshly-minted monitoring token + enables the beat
// (reusing the exact configure sub-step a normal go-live runs). Called only when
// the job carries an agent token.
func (e *RestoreExecutor) InstallAgent(ctx context.Context, kind, agentToken, ip string) error {
	if e.RunnerFor == nil {
		return fmt.Errorf("resurrect configure: no runner factory wired")
	}
	// No health token: a resurrect carries the freshly-minted REPORT token, not
	// the box's admin bearer, and agentInstallStep never deletes an existing
	// /etc/barkpark/agent.health.token — so a resurrected box keeps whatever
	// metering it had rather than being silently unmetered by the restore.
	return e.restoreRunner(kind, ip).Run(ctx, agentInstallStep(agentToken, e.ControlURL, restoreHealthURL, ""))
}

// RestoreData is the content phase: fetch db.dump + media.tar.gz from the bundle
// store, stream them into the box over the StdinStepRunner feed, and run the
// on-box restore pipeline — DROP → createdb → pg_restore --no-owner → media untar →
// best-effort migrate → restart. The database name comes from the MANIFEST (fenced
// safe), so the restore lands in the right place regardless of the box's own env.
func (e *RestoreExecutor) RestoreData(ctx context.Context, kind, prefix, dbName, ip string) error {
	if e.Store == nil {
		return fmt.Errorf("resurrect content: no bundle store wired")
	}
	if strings.TrimSpace(dbName) == "" {
		return fmt.Errorf("resurrect content: the manifest names no database to restore into")
	}
	if !dbNameSafe.MatchString(dbName) {
		return fmt.Errorf("resurrect content: db name %q is not a safe postgres identifier", dbName)
	}
	if e.RunnerFor == nil {
		return fmt.Errorf("resurrect content: no runner factory wired")
	}
	runner := e.restoreRunner(kind, ip)
	feeder, ok := runner.(StdinStepRunner)
	if !ok {
		return fmt.Errorf("resurrect content: runner for %s cannot stream stdin (need StdinStepRunner)", ip)
	}

	dbBytes, err := e.fetchMember(ctx, prefix, bundleDBName)
	if err != nil {
		return err
	}
	// media.tar.gz is always written (an empty archive when the box has none), so a
	// missing member is a torn bundle — but tolerate an empty read defensively.
	mediaBytes, err := e.fetchMember(ctx, prefix, bundleMediaName)
	if err != nil {
		return err
	}

	stream, err := buildRestoreTar(dbBytes, mediaBytes)
	if err != nil {
		return err
	}
	if _, err := feeder.RunFeed(ctx, "restore database + media", restoreDataScript(dbName), stream); err != nil {
		return fmt.Errorf("resurrect content on %s: %w", ip, err)
	}
	return nil
}

// TearDown reclaims an orphaned restored box (the rare succeed-report-failed edge)
// — best-effort delete by the box's barkpark-fqdn identity label + the DNS record.
// It reuses DeprovisionByIP so it can never delete a box whose identity doesn't
// match. A resolution failure is surfaced (logged by the caller) but never crashes
// the drain.
func (e *RestoreExecutor) TearDown(ctx context.Context, kind string, creds map[string]string, fqdn, ip string) error {
	provider, err := e.providerFor(kind, creds)
	if err != nil {
		return err
	}
	name, zone := splitFqdn(fqdn)
	wp := &WarmPool{Provider: provider, DNS: e.DNS}
	return wp.DeprovisionByIP(ctx, ip, name, zone)
}

// providerFor resolves the provider for a resurrect kind: the injected default for
// hetzner (or an empty/legacy kind), else the registry-resolved provider from the
// claim's decrypted per-kind creds.
func (e *RestoreExecutor) providerFor(kind string, creds map[string]string) (CloudProvider, error) {
	if kind == "" || kind == ProviderHetzner {
		if e.Provider == nil {
			return nil, fmt.Errorf("resurrect: no hetzner provider wired")
		}
		return e.Provider, nil
	}
	return ProviderFor(kind, creds)
}

// fetchMember reads one bundle member fully into memory. The DB dump can be large,
// so this is the known cost of building a single sized tar for the stdin feed
// (tar headers need the length up front) — acceptable for the archives most boxes
// carry, and a streaming/sized-from-S3 path is a filed follow-up for huge dumps.
func (e *RestoreExecutor) fetchMember(ctx context.Context, prefix, name string) ([]byte, error) {
	rc, err := OpenObject(ctx, e.Store, prefix, name)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		return nil, fmt.Errorf("cloud: read bundle member %s: %w", name, err)
	}
	return b, nil
}

// restoreFreshenStep builds the freshen step for kind. Azure runs the from-scratch
// base install (D41 — no snapshot substrate); a hetzner box booted the baked
// warm-image and is already current, so its freshen is a benign marker that keeps
// the seven-step feed honest without a needless rebuild.
func restoreFreshenStep(kind string) CaddyStep {
	if kind == ProviderAzure {
		script := `set -e; test -f /opt/barkpark/` + AzureBaseInstallScript +
			` && bash /opt/barkpark/` + AzureBaseInstallScript +
			` || { echo "` + AzureBaseInstallScript + ` missing on the box" >&2; exit 1; }`
		return CaddyStep{
			Title: "azure base install (from-scratch freshen)",
			Cmd:   "run " + AzureBaseInstallScript,
			Argv:  []string{"bash", "-lc", script},
		}
	}
	return CaddyStep{
		Title: "freshen (hetzner warm-image — already current)",
		Cmd:   "hetzner box booted the baked warm-image; nothing to rebuild",
		Argv:  []string{"bash", "-lc", "true"},
	}
}

// restoreSecretsEnvStep builds the idempotent .env identity merge (the
// secretsInstallStep style, generalized to the bundle's full identity map so
// BARKPARK_INGEST_TOKEN + BARKPARK_KEK[_PREVIOUS] survive, which the typed
// secretsInstallStep drops). Keys are sorted for a deterministic script; each
// value is single-quoted into a shell export after a shape guard, and listed in
// Redact so a step failure never surfaces a secret. It does NOT restart — the
// restart rides RestoreData's tail so the box comes up once with identity + data.
func restoreSecretsEnvStep(secrets map[string]string) (CaddyStep, error) {
	const envFile = "/opt/barkpark/.env"
	keys := make([]string, 0, len(secrets))
	for k := range secrets {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var exports, strip, appends strings.Builder
	var redact []string
	n := 0
	for _, k := range keys {
		v := secrets[k]
		if v == "" {
			continue // never install a blank identity secret
		}
		if !secretKeyShape.MatchString(k) {
			return CaddyStep{}, fmt.Errorf("resurrect identity secret key %q is not env-var shaped; refusing to interpolate it into a shell command", k)
		}
		if !secretValueAlphabet.MatchString(v) {
			return CaddyStep{}, fmt.Errorf("resurrect identity secret %s has an unexpected shape; refusing to interpolate it into a shell command", k)
		}
		vn := fmt.Sprintf("BP_ID_%d", n)
		fmt.Fprintf(&exports, `export %s='%s'; `, vn, v)
		fmt.Fprintf(&strip, ` -e '^%s='`, k)
		fmt.Fprintf(&appends, `printf '%s=%%s\n' "$%s" >> %s.bpnew; `, k, vn, envFile)
		redact = append(redact, v)
		n++
	}
	if n == 0 {
		return CaddyStep{}, fmt.Errorf("resurrect identity: the bundle carried no installable identity secrets")
	}

	script := exports.String() +
		`touch ` + envFile + `; ` +
		`grep -v` + strip.String() + ` ` + envFile + ` > ` + envFile + `.bpnew || true; ` +
		appends.String() +
		`mv ` + envFile + `.bpnew ` + envFile

	return CaddyStep{
		Title:            "install the bundle's sealed identity secrets (values redacted)",
		Cmd:              "merge the restored identity set into " + envFile + " (no restart — data restore restarts)",
		Argv:             []string{"bash", "-lc", script},
		Redact:           redact,
		RedactEnvSecrets: true,
	}, nil
}

// restoreDataScript is the on-box restore pipeline — the instImportScript inverse,
// reading db.dump + media.tar.gz members from a fed tar (not a single export
// tarball). It stages the fed stream, stops the service, drops + recreates the
// MANIFEST-named database as the target's own DB role, pg_restore --no-owner,
// replaces the media, replays migrations best-effort (the dump may predate the
// box's code), restarts, and health-gates on localhost. Emits BP_RESTORE_OK. PURE
// (dbName in, script out) so a test asserts the load-bearing bytes without a box.
// dbName is fenced by the caller (dbNameSafe).
func restoreDataScript(dbName string) string {
	return `set -e
STAGE=$(mktemp -d /tmp/bp-restore.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
tar -C "$STAGE" -xzf -
test -f "$STAGE/` + bundleDBName + `" || { echo "no ` + bundleDBName + ` in the restore stream" >&2; exit 1; }
systemctl stop barkpark
DBUSER=$(grep '^DATABASE_URL=' /opt/barkpark/.env | sed -E 's|.*//([^:@/]+)[:@].*|\1|')
sudo -u postgres psql -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS ` + dbName + `'
sudo -u postgres createdb -O "${DBUSER:-postgres}" ` + dbName + `
sudo -u postgres pg_restore --no-owner --role="${DBUSER:-postgres}" -d ` + dbName + ` "$STAGE/` + bundleDBName + `"
rm -rf /opt/barkpark/api/uploads
if [ -s "$STAGE/` + bundleMediaName + `" ]; then mkdir -p /opt/barkpark/api/uploads; tar -C /opt/barkpark/api/uploads -xzf "$STAGE/` + bundleMediaName + `" || true; fi
(set +e; set -a; . /opt/barkpark/.env; set +a; cd /opt/barkpark/api && bash -lc 'mix ecto.migrate' >/dev/null 2>&1; true)
systemctl start barkpark
PORT=$(grep '^PORT=' /opt/barkpark/.env | cut -d= -f2)
curl -sf -m 60 --retry 30 --retry-delay 3 --retry-connrefused "http://localhost:${PORT:-4000}/api/schemas" > /dev/null
echo BP_RESTORE_OK`
}

// buildRestoreTar packs db.dump + media.tar.gz into one gzipped tar — the byte
// stream fed into the box's `tar -xzf -`. Members are sized (tar headers need the
// length), which is why the callers read them fully first. media may be empty
// (an empty archive), still written so the member set is uniform.
func buildRestoreTar(db, media []byte) (io.Reader, error) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	write := func(name string, body []byte) error {
		if err := tw.WriteHeader(&tar.Header{
			Name:    name,
			Mode:    0o600,
			Size:    int64(len(body)),
			ModTime: time.Unix(0, 0).UTC(),
		}); err != nil {
			return fmt.Errorf("cloud: restore tar header %s: %w", name, err)
		}
		if _, err := tw.Write(body); err != nil {
			return fmt.Errorf("cloud: restore tar write %s: %w", name, err)
		}
		return nil
	}
	if err := write(bundleDBName, db); err != nil {
		return nil, err
	}
	if err := write(bundleMediaName, media); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, fmt.Errorf("cloud: restore tar close: %w", err)
	}
	if err := gz.Close(); err != nil {
		return nil, fmt.Errorf("cloud: restore gzip close: %w", err)
	}
	return bytes.NewReader(buf.Bytes()), nil
}
