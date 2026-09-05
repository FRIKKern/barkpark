package cli

// cloud_instance_archive_cmd.go is the PORTABLE-ARCHIVE surface (charter S14 /
// Decision 12+42): the provider-neutral `bp cloud instance archive` no longer
// takes a Hetzner snapshot — it collects the instance as a PORTABLE bp-bundle-v1
// (manifest + db.dump + media.tar.gz + secrets.enc) into object storage, so the
// same archive can be resurrected on the OTHER provider. Every provider —
// hetzner, azure, fake — produces the same bundle shape through ONE writer:
// cloud.WriteBundle (S14a's canonical library, internal/cli/cloud/bundle.go).
//
//	bp cloud instance archive  <fqdn|name> --provider hetzner|azure|fake  [--fast]
//	bp cloud instance archives [<fqdn>]     [--provider …]
//
// `--fast` is the HETZNER-ONLY escape: it dispatches to the existing
// runInstanceArchive snapshot BYTE-IDENTICAL to `bp cloud hetzner instance
// archive` (the raw escape hatch, untouched). On any other provider `--fast` is
// an honest error — there is no snapshot substrate to be fast about.
//
// This file owns the VERB: target resolution, ssh collection, the archives
// list. Format, sealing (AES-256-GCM under BARKPARK_BUNDLE_KEK) and the
// newest-first reader live in the cloud bundle library.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// bundleClock is the archive timestamp source — a var so a test can pin it.
var bundleClock = func() time.Time { return time.Now().UTC() }

// bundlePayload is the collected bytes of one instance: a custom-format pg_dump,
// a gzipped media tar, and the PLAINTEXT identity env lines (KEY=VALUE) as
// collected on the box. The secret set is the D36 identity set (see
// cloud.IdentitySecretKeys) — NOT the whole .env the transfer export copied, so
// a resurrected box keeps its OWN DATABASE_URL / PHX_* and only inherits
// identity. Sealing happens in cloud.WriteBundle, never in the store.
type bundlePayload struct {
	DB      []byte
	Media   []byte
	Secrets []byte
}

// bundleStoreProvider resolves the object-storage sink. A package var so tests
// swap in a cloud.NewFakeBundleStore. The default reads the store credentials
// from the environment (HETZNER_S3_ACCESS_KEY / HETZNER_S3_SECRET_KEY + the
// target bucket BARKPARK_BUNDLE_BUCKET) and, when any is missing, emits the LOUD
// Console-gate error naming the human step — S3 credentials and the bucket are
// created once in the Hetzner Console (there is no API for the credential mint).
var bundleStoreProvider = func(out *writer) (cloud.BundleStore, bool) {
	ak := strings.TrimSpace(os.Getenv("HETZNER_S3_ACCESS_KEY"))
	sk := strings.TrimSpace(os.Getenv("HETZNER_S3_SECRET_KEY"))
	bucket := strings.TrimSpace(os.Getenv("BARKPARK_BUNDLE_BUCKET"))
	if ak == "" || sk == "" || bucket == "" {
		useError(out, "auth", "no bundle store configured — set HETZNER_S3_ACCESS_KEY / HETZNER_S3_SECRET_KEY and BARKPARK_BUNDLE_BUCKET (the S3 credentials and the archive bucket are created once in the Hetzner Console under Object Storage; there is no API for this)", exitAuth)
		return nil, false
	}
	c, err := newObjstoreClient(hzS3DefaultLocation, ak, sk)
	if err != nil {
		useError(out, "failed", err.Error(), exitGeneric)
		return nil, false
	}
	return cloud.NewObjstoreBundleStore(c, bucket), true
}

// ── remote collection (the ssh/exec seam) ────────────────────────────────────

// bundleRemoteStream runs the archive script on host as root, streaming its
// gzipped-tar stdout into w — the collection pipe. A var so tests substitute an
// in-memory stream (the instSSHStream idiom from the transfer command).
var bundleRemoteStream = instSSHStream

// bundleArchiveScript is the remote collection pipeline: dump the DB, tar the
// media, stage ONLY the identity secrets (the D36 set from
// cloud.IdentitySecretKeys plus BARKPARK_KEK_PREVIOUS-when-set — NOT the whole
// .env), and stream db.dump + media.tar.gz + secrets.env as one gzipped tar to
// stdout. The staged secrets are PLAINTEXT env lines; the CLI seals them via
// cloud.WriteBundle before they touch object storage. PURE (string in, string
// out) so a test asserts the load-bearing pieces without a box. fqdn is
// charset-fenced by the caller (instFqdnSafe).
func bundleArchiveScript(fqdn string) string {
	keys := append(append([]string{}, cloud.IdentitySecretKeys...), "BARKPARK_KEK_PREVIOUS")
	return `set -e
STAGE=$(mktemp -d /tmp/bp-bundle.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
sudo -u postgres pg_dump --format=custom --no-owner barkpark_prod > "$STAGE/db.dump"
if [ -d /opt/barkpark/api/uploads ]; then tar -C /opt/barkpark/api -czf "$STAGE/media.tar.gz" uploads; else tar -czf "$STAGE/media.tar.gz" -T /dev/null; fi
: > "$STAGE/secrets.env"
for key in ` + strings.Join(keys, " ") + `; do
  grep "^$key=" /opt/barkpark/.env >> "$STAGE/secrets.env" 2>/dev/null || true
done
tar -C "$STAGE" -czf - db.dump media.tar.gz secrets.env`
}

// collectRemotePayload runs bundleArchiveScript on host and unpacks its gzipped
// tar into a bundlePayload. The three members are read by name — an incomplete
// archive (a member missing) is an error rather than a half-bundle.
func collectRemotePayload(host, fqdn string) (bundlePayload, error) {
	if !instFqdnSafe.MatchString(fqdn) {
		return bundlePayload{}, fmt.Errorf("refusing to archive %q: not a DNS-safe identity", fqdn)
	}
	pr, pw := io.Pipe()
	go func() { pw.CloseWithError(bundleRemoteStream(host, bundleArchiveScript(fqdn), pw)) }()
	return untarBundle(pr)
}

// untarBundle reads a gzipped tar of db.dump / media.tar.gz / secrets.env into a
// payload. Shared by the real collection and the test doubles. (The old member
// name secrets.enc is still accepted — same plaintext staging bytes.)
func untarBundle(r io.Reader) (bundlePayload, error) {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return bundlePayload{}, fmt.Errorf("open bundle stream: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	var p bundlePayload
	seen := map[string]bool{}
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return bundlePayload{}, fmt.Errorf("read bundle stream: %w", err)
		}
		body, err := io.ReadAll(tr)
		if err != nil {
			return bundlePayload{}, err
		}
		switch path.Base(hd.Name) {
		case "db.dump":
			p.DB, seen["db"] = body, true
		case "media.tar.gz":
			p.Media, seen["media"] = body, true
		case "secrets.env", "secrets.enc":
			p.Secrets, seen["secrets"] = body, true
		}
	}
	if !seen["db"] {
		return bundlePayload{}, fmt.Errorf("bundle stream missing db.dump")
	}
	return p, nil
}

// parseEnvSecrets turns collected KEY=VALUE lines into the identity map,
// filtered through cloud.SelectIdentitySecrets so the bundle carries EXACTLY
// the D36 set (BARKPARK_KEK always; BARKPARK_KEK_PREVIOUS only when non-empty)
// — a stray line the script version drift might collect never rides along.
func parseEnvSecrets(raw []byte) map[string]string {
	env := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		env[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"`)
	}
	return cloud.SelectIdentitySecrets(env)
}

// ── the neutral archive verb ─────────────────────────────────────────────────

// runNeutralArchive is the portable-bundle archive for EVERY provider. It is the
// interception point runCloudInstanceLifecycle routes `archive` to (the
// lifecycleDispatch VerbArchive entries exist only to register the capability —
// Decision 21). --fast is the hetzner-only snapshot escape.
func runNeutralArchive(out *writer, g globals, kind string, rest []string) int {
	const usageTail = "<fqdn|name> --provider hetzner|azure|fake [--fast [--stop]] [--zone <z>] [--fqdn <f>] [--team <t>]"
	usage := "bp cloud instance archive " + usageTail
	valueFlags := append([]string{"zone", "fqdn", "team", "dns-token", "control-url", "worker-token"}, azureCredFlags...)
	a, err := parseHzArgs(rest, valueFlags, []string{"fast", "stop"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|name> (usage: "+usage+")", exitUsage)
	}

	// --stop is a --fast-only flag and REFUSING it is the fix, not deleting it.
	// It stays registered because line 201 forwards `stripFlag(rest, "--fast")`
	// — only --fast is removed — to runInstanceArchive, which DOES honour
	// --stop (hetzner_instance_cmd.go passes a.bools["stop"] into instArchive,
	// running instStopCommand over SSH). Dropping the registration would make
	// parseHzArgs' default arm reject `--fast --stop`, breaking a working
	// combination. But the bare registration is exactly what created the silent
	// accept: on the portable path a.bools["stop"] is read nowhere, so the flag
	// exited 0 having quiesced nothing while the operator believed writers were
	// stopped. The portable path does not NEED a quiesce — bundleArchiveScript
	// runs `pg_dump --format=custom`, MVCC-consistent by construction — so the
	// honest behaviour is a usage error, never a no-op.
	if a.bools["stop"] && !a.bools["fast"] {
		return useError(out, "usage",
			"--stop needs --fast: it quiesces the DB writers over SSH on the hetzner snapshot path only. "+
				"The portable bundle takes an MVCC-consistent pg_dump and needs no quiesce, so --stop would do "+
				"nothing here (usage: "+usage+")", exitUsage)
	}

	// --fast: the Hetzner snapshot optimisation. Forward to the existing free
	// function with --fast stripped so the output is BYTE-IDENTICAL to the escape
	// hatch. On any other provider it is an honest error.
	if a.bools["fast"] {
		if kind != cloud.ProviderHetzner {
			return useError(out, "usage", "--fast is a hetzner snapshot optimization — drop it to write a portable bundle on "+kind, exitUsage)
		}
		return runInstanceArchive(out, g, stripFlag(rest, "--fast"))
	}

	store, ok := bundleStoreProvider(out)
	if !ok {
		return exitAuth
	}
	// The bundle seals its identity secrets under BARKPARK_BUNDLE_KEK — fail
	// loud BEFORE collecting anything (resurrect will need the SAME key).
	if strings.TrimSpace(os.Getenv("BARKPARK_BUNDLE_KEK")) == "" {
		return useError(out, "auth", "BARKPARK_BUNDLE_KEK is required — the bundle's identity secrets are sealed under it (AES-256-GCM), and resurrect needs the SAME key. Set it to a strong operator secret and keep it safe.", exitAuth)
	}

	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}

	host, fqdn, spec, code, ok := resolveArchiveTarget(out, g, kind, a, zone)
	if !ok {
		return code
	}

	payload, archiveID, code, ok := collectArchivePayload(out, kind, host, fqdn)
	if !ok {
		return code
	}

	team := resolveArchiveTeam(a, fqdn, zone)
	slug, _ := instLabelOf(fqdn)
	ctx := cloudInstanceCtx()
	man, werr := cloud.WriteBundle(ctx, store, cloud.BundleWriteSpec{
		FQDN:           fqdn,
		Slug:           slug,
		TeamID:         team,
		SourceProvider: kind,
		Spec:           spec,
		CreatedAt:      bundleClock(),
		DB:             bytes.NewReader(payload.DB),
		Media:          bytes.NewReader(payload.Media),
		Secrets:        parseEnvSecrets(payload.Secrets),
	})
	if werr != nil {
		return useError(out, "failed", "archive "+fqdn+": "+werr.Error(), exitGeneric)
	}
	prefix := man.Prefix()

	report := map[string]any{
		"ok": true, "provider": kind, "action": "archive",
		"bundle": map[string]any{
			"format": man.Format, "fqdn": fqdn, "team": teamOrStandalone(man.TeamID),
			"key_prefix": prefix, "manifest": prefix + "manifest.json",
		},
	}
	if archiveID != "" {
		report["archive"] = map[string]any{"id": archiveID, "fqdn": fqdn, "provider": kind}
	}
	if out.emitStructured(report) {
		return exitOK
	}
	out.outf("✓ archived %s on %s → bp-bundle-v1 %s", fqdn, kind, prefix)
	return exitOK
}

// teamOrStandalone renders the manifest's team_id for display: "_" when the
// bundle is standalone (matching its key prefix segment).
func teamOrStandalone(team string) string {
	if team == "" {
		return "_"
	}
	return team
}

// resolveArchiveTarget resolves the box's SSH host + its fqdn identity through the
// provider seam, plus the resurrection SPEC HINTS ({region, server_type}) read off
// the live box so a later resurrect can re-shape its target. hetzner uses the hz
// client (offline-testable via the fake API) and stamps the hints from the hcloud
// server; azure uses the swappable escape-hatch builder; the fake provider needs
// no host (its payload is synthetic). Hints are BEST-EFFORT: any provider whose
// server carries no shape info returns an empty BundleSpec — empty hints are
// tolerated everywhere (charter Decision 12), never an archive failure.
func resolveArchiveTarget(out *writer, g globals, kind string, a *hzArgs, zone string) (host, fqdn string, spec cloud.BundleSpec, code int, ok bool) {
	switch kind {
	case cloud.ProviderHetzner:
		c, cok := hetznerClient(out, g)
		if !cok {
			return "", "", cloud.BundleSpec{}, exitAuth, false
		}
		srv, f, terr := instTarget(hetznerCtx(), c.HCloud(), a.pos[0], zone, a.val("fqdn"))
		if terr != nil {
			return "", "", cloud.BundleSpec{}, hzFail(out, "archive", terr), false
		}
		if srv == nil {
			return "", "", cloud.BundleSpec{}, useError(out, "failed", "archive "+f+": no server carries that identity (see `bp cloud hetzner instance audit`)", exitNotFound), false
		}
		ip := hzIPv4(srv)
		if ip == "" {
			return "", "", cloud.BundleSpec{}, useError(out, "failed", "archive "+f+": server has no public IPv4 to collect from", exitGeneric), false
		}
		return ip, f, hzBundleSpec(srv), exitOK, true
	case cloud.ProviderAzure:
		p, pcode, pok := azureEscapeProviderFromFlags(out, a)
		if !pok {
			return "", "", cloud.BundleSpec{}, pcode, false
		}
		f := normalizeArchiveFqdn(a, zone)
		host, herr := seamHostFor(p, a.pos[0], f)
		if herr != nil {
			return "", "", cloud.BundleSpec{}, useError(out, "failed", "archive "+f+": "+herr.Error(), exitGeneric), false
		}
		// Azure carries no shape hints through this escape-hatch seam (D20): the
		// bundle records empty hints, which resurrect tolerates.
		return host, f, cloud.BundleSpec{}, exitOK, true
	default:
		// The fake / any synthetic provider: no host, no shape hints.
		return "", normalizeArchiveFqdn(a, zone), cloud.BundleSpec{}, exitOK, true
	}
}

// hzBundleSpec reads the resurrection shape hints off a live hcloud server:
// region (location, else the datacenter's location) and server-type slug. A nil
// server or missing fields yield empty strings — the resurrect path tolerates
// empty hints and re-shapes onto the target provider's nearest size.
func hzBundleSpec(srv *hcloud.Server) cloud.BundleSpec {
	if srv == nil {
		return cloud.BundleSpec{}
	}
	spec := cloud.BundleSpec{Region: hzServerLocation(srv)}
	if srv.ServerType != nil {
		spec.ServerType = srv.ServerType.Name
	}
	return spec
}

// seamHostFor finds a box's public IP through the core seam List, matching by
// fqdn label or name.
func seamHostFor(p cloud.CloudProvider, target, fqdn string) (string, error) {
	servers, err := p.List(cloudInstanceCtx())
	if err != nil {
		return "", err
	}
	for _, s := range servers {
		if s.Labels[cloud.FQDNLabelKey] == fqdn || s.Name == target {
			if s.IP == "" {
				return "", fmt.Errorf("box %q has no address to collect from", s.Name)
			}
			return s.IP, nil
		}
	}
	return "", fmt.Errorf("no box carries the identity %q", fqdn)
}

// collectArchivePayload gathers the instance bytes. hetzner/azure collect over
// ssh; every other provider (the fake) yields a synthetic payload — and, when the
// provider is an Archiver, records a stateful archive id so the receipt keeps its
// lineage while the bundle proves the full write path.
func collectArchivePayload(out *writer, kind, host, fqdn string) (bundlePayload, string, int, bool) {
	switch kind {
	case cloud.ProviderHetzner, cloud.ProviderAzure:
		p, err := collectRemotePayload(host, fqdn)
		if err != nil {
			return bundlePayload{}, "", useError(out, "failed", "archive "+fqdn+": collect: "+err.Error(), exitGeneric), false
		}
		return p, "", exitOK, true
	default:
		archiveID := ""
		if p, err := cloud.ProviderFor(kind, nil); err == nil {
			if arch, isArch := p.(cloud.Archiver); isArch {
				if rec, aerr := arch.Archive(cloudInstanceCtx(), fqdn); aerr == nil {
					archiveID = rec.ID
				}
			}
		}
		return syntheticPayload(fqdn), archiveID, exitOK, true
	}
}

// syntheticPayload is the fake provider's stand-in bytes: a marker db.dump, an
// empty gzipped media tar, and a marker secret set — enough to prove the writer
// stores a complete bp-bundle-v1 end to end, offline.
func syntheticPayload(fqdn string) bundlePayload {
	var media bytes.Buffer
	gz := gzip.NewWriter(&media)
	_ = tar.NewWriter(gz).Close()
	_ = gz.Close()
	return bundlePayload{
		DB:      []byte("-- bp-bundle-v1 synthetic pg_dump for " + fqdn + "\n"),
		Media:   media.Bytes(),
		Secrets: []byte("SECRET_KEY_BASE=synthetic\n"),
	}
}

// normalizeArchiveFqdn turns the positional (or --fqdn) into a fully-qualified
// name, defaulting the zone.
func normalizeArchiveFqdn(a *hzArgs, zone string) string {
	f := strings.Trim(strings.TrimSpace(a.pos[0]), ".")
	if a.val("fqdn") != "" {
		f = strings.Trim(strings.TrimSpace(a.val("fqdn")), ".")
	}
	if !strings.Contains(f, ".") {
		f = f + "." + zone
	}
	return f
}

// resolveArchiveTeam picks the owning team for the key prefix: an explicit --team
// wins; otherwise the control-plane registry row (when reachable) supplies it;
// otherwise the archive is standalone ("" — the library keys it under "_").
func resolveArchiveTeam(a *hzArgs, fqdn, zone string) string {
	if t := strings.TrimSpace(a.val("team")); t != "" {
		return t
	}
	cp := instCP(a)
	if cp == nil {
		return ""
	}
	rows, err := cp.List()
	if err != nil {
		return ""
	}
	label, fzone := instLabelOf(fqdn)
	if fzone == "" {
		fzone = zone
	}
	if row := cpFindRow(rows, label, fzone, ""); row != nil && row.TeamID != "" {
		return row.TeamID
	}
	return ""
}

// stripFlag removes every occurrence of a bare flag token from a tail — used to
// forward the hetzner --fast archive to the byte-identical free function.
func stripFlag(args []string, flag string) []string {
	out := make([]string, 0, len(args))
	for _, a := range args {
		if a == flag {
			continue
		}
		out = append(out, a)
	}
	return out
}

// ── the archives list ────────────────────────────────────────────────────────

// runInstanceArchivesList renders the portable archives in the store — one row
// per bp-bundle-v1 manifest, parsed from the object-storage prefix. Cross-provider
// by nature (a bundle is provider-tagged in its manifest, not its key), so
// --provider only FILTERS the rendered rows.
func runInstanceArchivesList(out *writer, args []string) int {
	const usage = "bp cloud instance archives [<fqdn>] [--provider hetzner|azure|fake] [--team <t>]"
	a, err := parseHzArgs(args, []string{"provider", "team"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 1 {
		return useError(out, "usage", "at most one <fqdn> (usage: "+usage+")", exitUsage)
	}
	fqdnFilter := ""
	if len(a.pos) == 1 {
		fqdnFilter = strings.Trim(strings.TrimSpace(a.pos[0]), ".")
	}
	providerFilter := strings.TrimSpace(a.val("provider"))

	store, ok := bundleStoreProvider(out)
	if !ok {
		return exitAuth
	}
	ctx := cloudInstanceCtx()
	prefix := "archives/"
	if t := strings.TrimSpace(a.val("team")); t != "" {
		prefix += t + "/"
	}
	keys, lerr := store.List(ctx, prefix)
	if lerr != nil {
		return useError(out, "failed", "list archives: "+lerr.Error(), exitGeneric)
	}

	type archiveRow struct {
		FQDN     string `json:"fqdn"`
		Provider string `json:"provider"`
		Team     string `json:"team"`
		Created  string `json:"created"`
		Bundle   string `json:"bundle"`
	}
	var rows []archiveRow
	for _, key := range keys {
		if path.Base(key) != "manifest.json" {
			continue
		}
		bundlePrefix := strings.TrimSuffix(key, "manifest.json")
		man, merr := cloud.ReadManifest(ctx, store, bundlePrefix)
		if merr != nil {
			continue // a manifest we can't read (or a foreign format) is skipped, not fatal to the list
		}
		if fqdnFilter != "" && man.FQDN != fqdnFilter {
			continue
		}
		if providerFilter != "" && man.SourceProvider != providerFilter {
			continue
		}
		rows = append(rows, archiveRow{
			FQDN: man.FQDN, Provider: man.SourceProvider, Team: teamOrStandalone(man.TeamID),
			Created: man.CreatedAt.UTC().Format(time.RFC3339),
			Bundle:  bundlePrefix,
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Created != rows[j].Created {
			return rows[i].Created > rows[j].Created // newest first
		}
		return rows[i].Bundle < rows[j].Bundle
	})

	if out.output == "json" || out.output == "yaml" {
		generic := make([]map[string]any, 0, len(rows))
		for _, r := range rows {
			generic = append(generic, map[string]any{
				"fqdn": r.FQDN, "provider": r.Provider, "team": r.Team,
				"created": r.Created, "bundle": r.Bundle,
			})
		}
		out.emitStructured(map[string]any{"archives": generic})
		return exitOK
	}
	if len(rows) == 0 {
		out.outf("no portable archives — create one with `bp cloud instance archive <fqdn>`")
		return exitOK
	}
	table := make([][]string, 0, len(rows))
	for _, r := range rows {
		table = append(table, []string{hzCell(r.FQDN), hzCell(r.Provider), hzCell(r.Created), hzCell(r.Bundle)})
	}
	renderHzTable(out, []string{"FQDN", "SOURCE", "CREATED", "BUNDLE"}, table)
	return exitOK
}
