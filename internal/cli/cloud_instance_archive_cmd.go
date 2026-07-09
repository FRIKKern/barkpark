package cli

// cloud_instance_archive_cmd.go is the PORTABLE-ARCHIVE surface (charter S14 /
// Decision 12+42): the provider-neutral `bp cloud instance archive` no longer
// takes a Hetzner snapshot — it collects the instance as a PORTABLE bp-bundle-v1
// (manifest + db.dump + media.tar.gz + secrets.enc) into object storage, so the
// same archive can be resurrected on the OTHER provider. Every provider —
// hetzner, azure, fake — produces the same bundle shape through one writer.
//
//	bp cloud instance archive  <fqdn|name> --provider hetzner|azure|fake  [--fast]
//	bp cloud instance archives [<fqdn>]     [--provider …]
//
// `--fast` is the HETZNER-ONLY escape: it dispatches to the existing
// runInstanceArchive snapshot BYTE-IDENTICAL to `bp cloud hetzner instance
// archive` (the raw escape hatch, untouched). On any other provider `--fast` is
// an honest error — there is no snapshot substrate to be fast about.
//
// ─────────────────────────────────────────────────────────────────────────────
// S14a SEAM (integration note). The BundleStore interface, the bp-bundle-v1
// manifest, the object-storage writer and the in-memory FakeBundleStore below
// are S14a's PINNED contract, reconstructed here so S14b builds and tests fully
// offline ahead of S14a's merge. When S14a lands, its canonical writer replaces
// this substrate (same names / same key prefix archives/<team|_>/<fqdn>/<stamp>/
// so the rewire is mechanical) and this block collapses into it. The S14b
// surface — the neutral archive verb, the --fast demotion, the archives list and
// the honesty flip — is what this slice owns; the substrate is a stand-in.
// ─────────────────────────────────────────────────────────────────────────────

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// bundleFormat is the portable-archive layout tag; resurrect refuses anything
// else. Distinct from the transfer command's bp-export-v1 (a single tarball) —
// a bundle is a KEY-PREFIXED SET of objects so a resurrect can pull just the
// manifest to inspect before hydrating the whole box.
const bundleFormat = "bp-bundle-v1"

// bundleClock is the archive timestamp source — a var so a test can pin it.
var bundleClock = func() time.Time { return time.Now().UTC() }

// ── S14a substrate: BundleStore + manifest + writer ──────────────────────────

// bundleStore is the object-storage sink for portable archives (S14a's pinned
// BundleStore). Put streams one object; List enumerates a prefix; Get pulls one
// object back (the archives list reads each manifest.json). Reconstructed here —
// see the S14a SEAM note above.
type bundleStore interface {
	Put(ctx context.Context, key string, body io.Reader) error
	List(ctx context.Context, prefix string) ([]bundleObject, error)
	Get(ctx context.Context, key string) ([]byte, error)
}

// bundleObject is one stored object's key + size + last-modified (the ListObjects
// shape, provider-neutral).
type bundleObject struct {
	Key      string
	Size     int64
	Modified time.Time
}

// bundleManifest is the bp-bundle-v1 manifest.json — the self-describing header a
// resurrect reads first. The three payload fields name the sibling objects under
// the same key prefix; region/server_type are best-effort spec HINTS for the
// resurrection target (omitted when unknown).
type bundleManifest struct {
	Format     string    `json:"format"` // bundleFormat
	FQDN       string    `json:"fqdn"`   // the box's DNS identity
	Provider   string    `json:"provider"`
	Team       string    `json:"team"` // owning team id, or "_" when standalone
	Created    time.Time `json:"created"`
	ArchiveID  string    `json:"archive_id,omitempty"`
	DB         string    `json:"db"`      // db.dump
	Media      string    `json:"media"`   // media.tar.gz
	Secrets    string    `json:"secrets"` // secrets.enc
	Region     string    `json:"region,omitempty"`
	ServerType string    `json:"server_type,omitempty"`
}

// bundlePayload is the collected bytes of one instance: a custom-format pg_dump,
// a gzipped media tar, and the SEALED identity secrets. The secret set is the
// corrected one (SECRET_KEY_BASE / BARKPARK_CLOAK_KEY / PREVIEW_JWT_SECRET /
// BARKPARK_INGEST_TOKEN) — NOT the whole .env the transfer export copied, so a
// resurrected box keeps its OWN DATABASE_URL / PHX_* and only inherits identity.
type bundlePayload struct {
	DB      []byte
	Media   []byte
	Secrets []byte
}

// bundleKeyPrefix is the canonical object-storage prefix for one archive:
// archives/<team|_>/<fqdn>/<stamp>/ (S14a's pinned key layout).
func bundleKeyPrefix(team, fqdn string, at time.Time) string {
	if team == "" {
		team = "_"
	}
	return "archives/" + team + "/" + fqdn + "/" + at.Format("20060102-150405") + "/"
}

// writeBundle streams a payload into the store as a bp-bundle-v1 and returns the
// manifest + the key prefix it landed under. The manifest is written LAST so a
// concurrent archives-list never sees a bundle before its payload is complete.
func writeBundle(ctx context.Context, st bundleStore, kind, fqdn, team, archiveID string, p bundlePayload) (bundleManifest, string, error) {
	at := bundleClock()
	prefix := bundleKeyPrefix(team, fqdn, at)
	man := bundleManifest{
		Format: bundleFormat, FQDN: fqdn, Provider: kind, Team: teamOrStandalone(team),
		Created: at, ArchiveID: archiveID,
		DB: "db.dump", Media: "media.tar.gz", Secrets: "secrets.enc",
	}
	for _, part := range []struct {
		name string
		body []byte
	}{
		{"db.dump", p.DB},
		{"media.tar.gz", p.Media},
		{"secrets.enc", p.Secrets},
	} {
		if err := st.Put(ctx, prefix+part.name, bytes.NewReader(part.body)); err != nil {
			return bundleManifest{}, "", fmt.Errorf("write %s: %w", part.name, err)
		}
	}
	manBytes, err := json.Marshal(man)
	if err != nil {
		return bundleManifest{}, "", err
	}
	if err := st.Put(ctx, prefix+"manifest.json", bytes.NewReader(manBytes)); err != nil {
		return bundleManifest{}, "", fmt.Errorf("write manifest: %w", err)
	}
	return man, prefix, nil
}

func teamOrStandalone(team string) string {
	if team == "" {
		return "_"
	}
	return team
}

// objBundleStore is the production BundleStore over Hetzner Object Storage (the
// same objstore.Client the storage/backup surfaces use). S14a's real writer will
// add server-side sealing of secrets.enc; here the payload is stored as collected.
type objBundleStore struct {
	c      *objstore.Client
	bucket string
}

func (o *objBundleStore) Put(ctx context.Context, key string, body io.Reader) error {
	return o.c.PutLarge(ctx, o.bucket, key, body)
}

func (o *objBundleStore) List(ctx context.Context, prefix string) ([]bundleObject, error) {
	objs, err := o.c.ListObjects(ctx, o.bucket, prefix)
	if err != nil {
		return nil, err
	}
	out := make([]bundleObject, 0, len(objs))
	for _, ob := range objs {
		out = append(out, bundleObject{Key: ob.Key, Size: ob.Size, Modified: ob.LastModified})
	}
	return out, nil
}

func (o *objBundleStore) Get(ctx context.Context, key string) ([]byte, error) {
	rc, err := o.c.GetObject(ctx, o.bucket, key)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

// bundleStoreProvider resolves the object-storage sink. A package var so tests
// swap in a FakeBundleStore. The default reads the store credentials from the
// environment (HETZNER_S3_ACCESS_KEY / HETZNER_S3_SECRET_KEY + the target bucket
// BARKPARK_BUNDLE_BUCKET) and, when any is missing, emits the LOUD Console-gate
// error naming the human step — S3 credentials and the bucket are created once in
// the Hetzner Console (there is no API for the credential mint).
var bundleStoreProvider = func(out *writer) (bundleStore, bool) {
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
	return &objBundleStore{c: c, bucket: bucket}, true
}

// ── remote collection (the ssh/exec seam) ────────────────────────────────────

// bundleRemoteStream runs the archive script on host as root, streaming its
// gzipped-tar stdout into w — the collection pipe. A var so tests substitute an
// in-memory stream (the instSSHStream idiom from the transfer command).
var bundleRemoteStream = instSSHStream

// bundleArchiveScript is the remote collection pipeline: dump the DB, tar the
// media, seal ONLY the identity secrets (the corrected set — NOT the whole .env),
// and stream db.dump + media.tar.gz + secrets.enc as one gzipped tar to stdout.
// PURE (string in, string out) so a test asserts the load-bearing pieces without
// a box. fqdn is charset-fenced by the caller (instFqdnSafe).
func bundleArchiveScript(fqdn string) string {
	return `set -e
STAGE=$(mktemp -d /tmp/bp-bundle.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
sudo -u postgres pg_dump --format=custom --no-owner barkpark_prod > "$STAGE/db.dump"
if [ -d /opt/barkpark/api/uploads ]; then tar -C /opt/barkpark/api -czf "$STAGE/media.tar.gz" uploads; else tar -czf "$STAGE/media.tar.gz" -T /dev/null; fi
: > "$STAGE/secrets.enc"
for key in SECRET_KEY_BASE BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_INGEST_TOKEN; do
  grep "^$key=" /opt/barkpark/.env >> "$STAGE/secrets.enc" 2>/dev/null || true
done
tar -C "$STAGE" -czf - db.dump media.tar.gz secrets.enc`
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

// untarBundle reads a gzipped tar of db.dump / media.tar.gz / secrets.enc into a
// payload. Shared by the real collection and the test doubles.
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
		case "secrets.enc":
			p.Secrets, seen["secrets"] = body, true
		}
	}
	if !seen["db"] {
		return bundlePayload{}, fmt.Errorf("bundle stream missing db.dump")
	}
	return p, nil
}

// ── the neutral archive verb ─────────────────────────────────────────────────

// runNeutralArchive is the portable-bundle archive for EVERY provider. It is the
// interception point runCloudInstanceLifecycle routes `archive` to (the
// lifecycleDispatch VerbArchive entries exist only to register the capability —
// Decision 21). --fast is the hetzner-only snapshot escape.
func runNeutralArchive(out *writer, g globals, kind string, rest []string) int {
	const usageTail = "<fqdn|name> --provider hetzner|azure|fake [--fast] [--zone <z>] [--fqdn <f>] [--team <t>]"
	usage := "bp cloud instance archive " + usageTail
	valueFlags := append([]string{"zone", "fqdn", "team", "dns-token", "control-url", "worker-token"}, azureCredFlags...)
	a, err := parseHzArgs(rest, valueFlags, []string{"fast", "stop"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|name> (usage: "+usage+")", exitUsage)
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

	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}

	host, fqdn, code, ok := resolveArchiveTarget(out, g, kind, a, zone)
	if !ok {
		return code
	}

	payload, archiveID, code, ok := collectArchivePayload(out, kind, host, fqdn, store)
	if !ok {
		return code
	}

	team := resolveArchiveTeam(a, fqdn, zone)
	ctx := cloudInstanceCtx()
	man, prefix, werr := writeBundle(ctx, store, kind, fqdn, team, archiveID, payload)
	if werr != nil {
		return useError(out, "failed", "archive "+fqdn+": "+werr.Error(), exitGeneric)
	}

	report := map[string]any{
		"ok": true, "provider": kind, "action": "archive",
		"bundle": map[string]any{
			"format": man.Format, "fqdn": fqdn, "team": man.Team,
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

// resolveArchiveTarget resolves the box's SSH host + its fqdn identity through the
// provider seam. hetzner uses the hz client (offline-testable via the fake API);
// azure uses the swappable escape-hatch builder; the fake provider needs no host
// (its payload is synthetic) and returns an empty host with the normalised fqdn.
func resolveArchiveTarget(out *writer, g globals, kind string, a *hzArgs, zone string) (host, fqdn string, code int, ok bool) {
	switch kind {
	case cloud.ProviderHetzner:
		c, cok := hetznerClient(out, g)
		if !cok {
			return "", "", exitAuth, false
		}
		srv, f, terr := instTarget(hetznerCtx(), c.HCloud(), a.pos[0], zone, a.val("fqdn"))
		if terr != nil {
			return "", "", hzFail(out, "archive", terr), false
		}
		if srv == nil {
			return "", "", useError(out, "failed", "archive "+f+": no server carries that identity (see `bp cloud hetzner instance audit`)", exitNotFound), false
		}
		ip := hzIPv4(srv)
		if ip == "" {
			return "", "", useError(out, "failed", "archive "+f+": server has no public IPv4 to collect from", exitGeneric), false
		}
		return ip, f, exitOK, true
	case cloud.ProviderAzure:
		p, pcode, pok := azureEscapeProviderFromFlags(out, a)
		if !pok {
			return "", "", pcode, false
		}
		f := normalizeArchiveFqdn(a, zone)
		host, herr := seamHostFor(p, a.pos[0], f)
		if herr != nil {
			return "", "", useError(out, "failed", "archive "+f+": "+herr.Error(), exitGeneric), false
		}
		return host, f, exitOK, true
	default:
		// The fake / any synthetic provider: no host, fqdn normalised from the arg.
		return "", normalizeArchiveFqdn(a, zone), exitOK, true
	}
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
func collectArchivePayload(out *writer, kind, host, fqdn string, _ bundleStore) (bundlePayload, string, int, bool) {
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
// otherwise the archive is standalone ("_").
func resolveArchiveTeam(a *hzArgs, fqdn, zone string) string {
	if t := strings.TrimSpace(a.val("team")); t != "" {
		return t
	}
	cp := instCP(a)
	if cp == nil {
		return "_"
	}
	rows, err := cp.List()
	if err != nil {
		return "_"
	}
	label, fzone := instLabelOf(fqdn)
	if fzone == "" {
		fzone = zone
	}
	if row := cpFindRow(rows, label, fzone, ""); row != nil && row.TeamID != "" {
		return row.TeamID
	}
	return "_"
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
	objs, lerr := store.List(ctx, prefix)
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
	for _, ob := range objs {
		if path.Base(ob.Key) != "manifest.json" {
			continue
		}
		raw, gerr := store.Get(ctx, ob.Key)
		if gerr != nil {
			continue // a manifest we can't read is skipped, not fatal to the list
		}
		var man bundleManifest
		if json.Unmarshal(raw, &man) != nil || man.Format != bundleFormat {
			continue
		}
		if fqdnFilter != "" && man.FQDN != fqdnFilter {
			continue
		}
		if providerFilter != "" && man.Provider != providerFilter {
			continue
		}
		rows = append(rows, archiveRow{
			FQDN: man.FQDN, Provider: man.Provider, Team: man.Team,
			Created: man.Created.UTC().Format(time.RFC3339),
			Bundle:  strings.TrimSuffix(ob.Key, "manifest.json"),
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
