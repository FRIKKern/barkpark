package cloud

// bundle.go — bp-bundle-v1, the PORTABLE archive format that makes Barkpark
// Cloud better than either provider: an instance archived to an object-storage
// bundle can be resurrected on the OTHER provider (charter Decision 12). Where a
// Hetzner snapshot is perfect but project-bound (demoted to `--fast`), a bundle
// is pure data — a manifest plus a logical pg_dump, media tarball, and encrypted
// identity secrets — restorable onto any fresh box on any cloud.
//
// A bundle is four members written under one time-stamped prefix:
//
//	archives/<team_id|_>/<fqdn>/<utc-stamp>/
//	  db.dump        pg_dump --format=custom of the source database
//	  media.tar.gz   the box's media files (empty archive when it has none)
//	  secrets.enc    AES-256-GCM of the identity secrets (see IdentitySecretKeys)
//	  manifest.json  the bp-bundle-v1 descriptor — WRITTEN LAST
//
// manifest.json is written last on purpose: its presence is the completeness
// fence. A half-written bundle (upload died mid-db.dump) has no manifest, so the
// newest-first reader skips it — a resurrect never boots from a torn archive.
//
// This file is the pure library: format, manifest, streaming writer, newest-
// first reader, and the identity-secret selection + envelope crypto. The
// object-store transport is the BundleStore seam (bundle_store.go); tests run
// against the in-memory NewFakeBundleStore, so no gate ever dials S3.

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"
	"time"
)

// BundleFormat is the format tag stamped into every manifest; the reader refuses
// anything else, exactly as bp-export-v1 does for the snapshot-less export path.
const BundleFormat = "bp-bundle-v1"

// bundleCipher names the algorithm secrets.enc is sealed with — recorded in the
// manifest so the reader is self-describing and a future cipher migration is a
// data change, not a code fork.
const bundleCipher = "aes-256-gcm"

// The four member names under a bundle prefix. Fixed so the reader can address
// them without a directory listing.
const (
	bundleManifestName = "manifest.json"
	bundleDBName       = "db.dump"
	bundleMediaName    = "media.tar.gz"
	bundleSecretsName  = "secrets.enc"
)

// bundleStampFmt is the UTC time-stamp segment: sortable ISO-8601 basic form, so
// a lexical sort of prefixes IS a chronological sort (the newest-first reader
// leans on this).
const bundleStampFmt = "20060102T150405Z"

// bundleKEKEnv is the env var holding the key that wraps secrets.enc. Distinct
// from the DATA-level BARKPARK_KEK that TRAVELS INSIDE the bundle (an identity
// secret): this one is the operator's bundle-at-rest key, never archived.
const bundleKEKEnv = "BARKPARK_BUNDLE_KEK"

// IdentitySecretKeys are the env keys a bundle carries so the Cloak-encrypted
// database is READABLE after a cross-provider resurrect (the DB ciphertext is
// meaningless without the source's key material). This set INTENTIONALLY differs
// from bp-export-v1's (hetzner_instance_transfer_cmd.go): it adds BARKPARK_KEK —
// the run-secret key-encryption key the export path omits (charter D36). A box
// that has rotated its KEK also carries BARKPARK_KEK_PREVIOUS, but only WHEN SET
// (SelectIdentitySecrets adds it conditionally) so an un-rotated box does not
// ship an empty slot.
var IdentitySecretKeys = []string{
	"SECRET_KEY_BASE",
	"BARKPARK_CLOAK_KEY",
	"PREVIEW_JWT_SECRET",
	"BARKPARK_INGEST_TOKEN",
	"BARKPARK_KEK",
}

// identitySecretWhenSet are identity keys carried ONLY when present and non-empty
// in the source env — a rotated box ships its previous KEK so ciphertext written
// before the rotation still decrypts; an un-rotated box ships nothing extra.
var identitySecretWhenSet = []string{"BARKPARK_KEK_PREVIOUS"}

// SelectIdentitySecrets projects a box's env down to the bundle's identity set:
// every IdentitySecretKeys entry that is present, plus each identitySecretWhenSet
// entry that is present AND non-empty. Absent keys are simply omitted — the
// resurrect path merges what it finds, never faking a blank secret.
func SelectIdentitySecrets(env map[string]string) map[string]string {
	out := make(map[string]string, len(IdentitySecretKeys)+len(identitySecretWhenSet))
	for _, k := range IdentitySecretKeys {
		if v, ok := env[k]; ok {
			out[k] = v
		}
	}
	for _, k := range identitySecretWhenSet {
		if v, ok := env[k]; ok && v != "" {
			out[k] = v
		}
	}
	return out
}

// BundleSpec is the resurrection hint set: how the source box was shaped so the
// target can be created to match (empty values are legitimate — a resurrect may
// re-shape onto the other provider's nearest size). Both fields are always
// present in the wire bytes (the pinned manifest carries "" not an omission).
type BundleSpec struct {
	Region     string `json:"region"`
	ServerType string `json:"server_type"`
}

// BundleObjects maps each logical payload to its member filename under the
// bundle prefix. It is the manifest's directory: the reader learns the object
// names from here rather than hard-coding them, so a filename change is a data
// change. The values are the fixed member names below.
type BundleObjects struct {
	DB      string `json:"db"`
	Media   string `json:"media"`
	Secrets string `json:"secrets"`
}

// BundleManifest is the PINNED bp-bundle-v1 descriptor (manifest.json). Field
// names + shape are the wire contract S14b/c/d/e build against — the control
// plane and every reader unmarshal it, so grow it only additively.
type BundleManifest struct {
	Format         string        `json:"format"`
	FQDN           string        `json:"fqdn"`
	Slug           string        `json:"slug"`
	TeamID         string        `json:"team_id"`
	SourceProvider string        `json:"source_provider"`
	CreatedAt      time.Time     `json:"created_at"`
	DBName         string        `json:"db_name"`
	Spec           BundleSpec    `json:"spec"`
	Objects        BundleObjects `json:"objects"`
	SecretsCipher  string        `json:"secrets_cipher"`
}

// BundleWriteSpec is everything WriteBundle needs to stream one bundle. DB is
// required (the point of an archive); Media may be nil (an empty media.tar.gz is
// still written so the member set is uniform); Secrets is the plaintext identity
// map (usually from SelectIdentitySecrets) sealed into secrets.enc.
type BundleWriteSpec struct {
	FQDN           string
	Slug           string
	TeamID         string
	SourceProvider string
	DBName         string
	Spec           BundleSpec
	CreatedAt      time.Time // zero → time.Now(); always normalized to UTC
	DB             io.Reader
	Media          io.Reader
	Secrets        map[string]string
}

// bundleFQDNPrefix is the listing root for one instance's bundles:
// archives/<team_id|_>/<fqdn>/. Empty team collapses to "_" so an
// unassigned/self-hosted box still nests cleanly.
func bundleFQDNPrefix(teamID, fqdn string) string {
	t := teamID
	if t == "" {
		t = "_"
	}
	return fmt.Sprintf("archives/%s/%s/", t, fqdn)
}

// bundlePrefix is one bundle's write prefix: the fqdn root plus the utc stamp.
func bundlePrefix(teamID, fqdn string, at time.Time) string {
	return bundleFQDNPrefix(teamID, fqdn) + at.UTC().Format(bundleStampFmt) + "/"
}

// bundleKEK reads the bundle-at-rest key from the environment, erroring loudly
// when unset — a bundle must never be written or read with an empty key.
func bundleKEK() (string, error) {
	kek := strings.TrimSpace(os.Getenv(bundleKEKEnv))
	if kek == "" {
		return "", fmt.Errorf("cloud: %s is required to seal/open a bundle's secrets", bundleKEKEnv)
	}
	return kek, nil
}

// putStream streams r into the store at key, wrapping any transport error with
// the member name for a legible failure.
func putStream(ctx context.Context, store BundleStore, key string, r io.Reader) error {
	if err := store.PutLarge(ctx, key, r); err != nil {
		return fmt.Errorf("cloud: write bundle member %s: %w", path.Base(key), err)
	}
	return nil
}

// WriteBundle streams a complete bp-bundle-v1 into store and returns the manifest
// it wrote. Members go db.dump → media.tar.gz → secrets.enc, and manifest.json
// LAST so a torn upload is invisible to readers. Secrets are sealed with the
// BARKPARK_BUNDLE_KEK envelope before they touch the store.
func WriteBundle(ctx context.Context, store BundleStore, spec BundleWriteSpec) (BundleManifest, error) {
	if store == nil {
		return BundleManifest{}, fmt.Errorf("cloud: WriteBundle requires a store")
	}
	if spec.FQDN == "" {
		return BundleManifest{}, fmt.Errorf("cloud: WriteBundle requires a non-empty fqdn")
	}
	if spec.DB == nil {
		return BundleManifest{}, fmt.Errorf("cloud: WriteBundle requires a db.dump reader")
	}
	kek, err := bundleKEK()
	if err != nil {
		return BundleManifest{}, err
	}

	createdAt := spec.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now()
	}
	// Whole-second UTC: the created_at bytes then match the folder stamp and stay
	// clean RFC3339 (no nanosecond tail) for downstream parsers.
	createdAt = createdAt.UTC().Truncate(time.Second)
	prefix := bundlePrefix(spec.TeamID, spec.FQDN, createdAt)

	if err := putStream(ctx, store, prefix+bundleDBName, spec.DB); err != nil {
		return BundleManifest{}, err
	}

	media := spec.Media
	if media == nil {
		media = bytes.NewReader(nil)
	}
	if err := putStream(ctx, store, prefix+bundleMediaName, media); err != nil {
		return BundleManifest{}, err
	}

	secretsJSON, err := json.Marshal(spec.Secrets)
	if err != nil {
		return BundleManifest{}, fmt.Errorf("cloud: encode bundle secrets: %w", err)
	}
	sealed, err := sealSecrets(secretsJSON, kek)
	if err != nil {
		return BundleManifest{}, err
	}
	if err := putStream(ctx, store, prefix+bundleSecretsName, bytes.NewReader(sealed)); err != nil {
		return BundleManifest{}, err
	}

	dbName := spec.DBName
	if dbName == "" {
		dbName = "barkpark_prod"
	}
	manifest := BundleManifest{
		Format:         BundleFormat,
		FQDN:           spec.FQDN,
		Slug:           spec.Slug,
		TeamID:         spec.TeamID,
		SourceProvider: spec.SourceProvider,
		CreatedAt:      createdAt,
		DBName:         dbName,
		Spec:           spec.Spec,
		Objects:        BundleObjects{DB: bundleDBName, Media: bundleMediaName, Secrets: bundleSecretsName},
		SecretsCipher:  bundleCipher,
	}
	mb, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return BundleManifest{}, fmt.Errorf("cloud: encode bundle manifest: %w", err)
	}
	// manifest LAST — its presence is the completeness fence.
	if err := store.PutLarge(ctx, prefix+bundleManifestName, bytes.NewReader(mb)); err != nil {
		return BundleManifest{}, fmt.Errorf("cloud: write bundle manifest: %w", err)
	}
	return manifest, nil
}

// Prefix returns the object-store key prefix this manifest's bundle lives
// under — archives/<team_id|_>/<fqdn>/<utc-stamp>/ — so a caller that just
// wrote a bundle can report where it landed without re-deriving the layout.
func (m BundleManifest) Prefix() string {
	return bundlePrefix(m.TeamID, m.FQDN, m.CreatedAt)
}

// BundleRef is a discovered, COMPLETE bundle (it has a manifest): its store
// prefix and the CreatedAt parsed from the stamp segment. It is the handle the
// reader hands to ReadManifest / OpenObject / OpenSecrets.
type BundleRef struct {
	Prefix    string
	FQDN      string
	TeamID    string
	CreatedAt time.Time
}

// ListBundles returns every COMPLETE bundle for one instance, NEWEST FIRST. A
// bundle counts only when its manifest.json is present (the completeness fence),
// so a torn upload never appears. Sort is by CreatedAt descending, prefix as the
// deterministic tiebreak.
func ListBundles(ctx context.Context, store BundleStore, teamID, fqdn string) ([]BundleRef, error) {
	if store == nil {
		return nil, fmt.Errorf("cloud: ListBundles requires a store")
	}
	base := bundleFQDNPrefix(teamID, fqdn)
	keys, err := store.List(ctx, base)
	if err != nil {
		return nil, fmt.Errorf("cloud: list bundles for %s: %w", fqdn, err)
	}
	var refs []BundleRef
	for _, key := range keys {
		if !strings.HasSuffix(key, "/"+bundleManifestName) {
			continue
		}
		prefix := strings.TrimSuffix(key, bundleManifestName) // keeps trailing slash
		stamp := path.Base(strings.TrimSuffix(prefix, "/"))
		at, _ := time.Parse(bundleStampFmt, stamp) // zero on unparsable — still listed, sorts last
		refs = append(refs, BundleRef{Prefix: prefix, FQDN: fqdn, TeamID: teamID, CreatedAt: at})
	}
	sort.Slice(refs, func(i, j int) bool {
		if !refs[i].CreatedAt.Equal(refs[j].CreatedAt) {
			return refs[i].CreatedAt.After(refs[j].CreatedAt)
		}
		return refs[i].Prefix > refs[j].Prefix
	})
	return refs, nil
}

// NewestBundle returns the most recent complete bundle for an instance. The bool
// is false (no error) when the instance has no bundle yet — the honest not-found
// the resurrect path turns into "nothing to restore".
func NewestBundle(ctx context.Context, store BundleStore, teamID, fqdn string) (BundleRef, bool, error) {
	refs, err := ListBundles(ctx, store, teamID, fqdn)
	if err != nil {
		return BundleRef{}, false, err
	}
	if len(refs) == 0 {
		return BundleRef{}, false, nil
	}
	return refs[0], true, nil
}

// ReadManifest fetches and validates the manifest at prefix. A wrong format tag
// is an error — the reader refuses a foreign archive exactly as import does.
func ReadManifest(ctx context.Context, store BundleStore, prefix string) (BundleManifest, error) {
	rc, err := store.Get(ctx, prefix+bundleManifestName)
	if err != nil {
		return BundleManifest{}, fmt.Errorf("cloud: read bundle manifest: %w", err)
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		return BundleManifest{}, fmt.Errorf("cloud: read bundle manifest: %w", err)
	}
	var m BundleManifest
	if err := json.Unmarshal(b, &m); err != nil {
		return BundleManifest{}, fmt.Errorf("cloud: decode bundle manifest: %w", err)
	}
	if m.Format != BundleFormat {
		return BundleManifest{}, fmt.Errorf("cloud: not a %s bundle (format=%q)", BundleFormat, m.Format)
	}
	return m, nil
}

// OpenObject streams one member (db.dump / media.tar.gz) out of a bundle. The
// caller must Close the returned reader.
func OpenObject(ctx context.Context, store BundleStore, prefix, name string) (io.ReadCloser, error) {
	rc, err := store.Get(ctx, prefix+name)
	if err != nil {
		return nil, fmt.Errorf("cloud: open bundle member %s: %w", name, err)
	}
	return rc, nil
}

// OpenSecrets fetches secrets.enc and decrypts it with BARKPARK_BUNDLE_KEK (read
// from the environment), returning the identity map. A wrong key fails GCM
// authentication — the bytes never decode to a plausible-but-wrong plaintext.
func OpenSecrets(ctx context.Context, store BundleStore, prefix string) (map[string]string, error) {
	kek, err := bundleKEK()
	if err != nil {
		return nil, err
	}
	return OpenSecretsWithKEK(ctx, store, prefix, kek)
}

// OpenSecretsWithKEK fetches secrets.enc at prefix and decrypts it with the
// CARRIED kek — the resurrect-drain unseal (charter S14f, Decision 46), distinct
// from OpenSecrets which reads BARKPARK_BUNDLE_KEK from the environment. A
// resurrect CARRIES its archive-time KEK (routed in via the claim, never minted at
// restore time) so the box keeps its prior identity; passing the kek EXPLICITLY —
// rather than re-reading the env — keeps that "the carried key was used" guarantee
// testable (a wrong env key can never masquerade as the archive's). A wrong key
// fails the GCM tag; the bytes never decode to a plausible-but-wrong plaintext.
func OpenSecretsWithKEK(ctx context.Context, store BundleStore, prefix, kek string) (map[string]string, error) {
	if strings.TrimSpace(kek) == "" {
		return nil, fmt.Errorf("cloud: OpenSecretsWithKEK requires a non-empty carried KEK")
	}
	rc, err := store.Get(ctx, prefix+bundleSecretsName)
	if err != nil {
		return nil, fmt.Errorf("cloud: open bundle secrets: %w", err)
	}
	defer rc.Close()
	sealed, err := io.ReadAll(rc)
	if err != nil {
		return nil, fmt.Errorf("cloud: read bundle secrets: %w", err)
	}
	plain, err := openSecrets(sealed, kek)
	if err != nil {
		return nil, err
	}
	var out map[string]string
	if err := json.Unmarshal(plain, &out); err != nil {
		return nil, fmt.Errorf("cloud: decode bundle secrets: %w", err)
	}
	return out, nil
}

// ── secrets envelope: AES-256-GCM ────────────────────────────────────────────
// The 32-byte AES key is SHA-256(kek), so any-length operator key material is
// accepted while the cipher stays AES-256. The nonce is random per seal and
// prepended to the ciphertext; Open re-splits it. A wrong key (or a tampered
// byte) fails the GCM tag — Open returns an error, never garbage.

func gcmForKEK(kek string) (cipher.AEAD, error) {
	key := sha256.Sum256([]byte(kek))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, fmt.Errorf("cloud: bundle cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("cloud: bundle gcm: %w", err)
	}
	return gcm, nil
}

func sealSecrets(plaintext []byte, kek string) ([]byte, error) {
	gcm, err := gcmForKEK(kek)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("cloud: bundle nonce: %w", err)
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

func openSecrets(sealed []byte, kek string) ([]byte, error) {
	gcm, err := gcmForKEK(kek)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(sealed) < ns {
		return nil, fmt.Errorf("cloud: bundle secrets truncated")
	}
	nonce, ct := sealed[:ns], sealed[ns:]
	plain, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("cloud: bundle secrets failed authentication (wrong %s?)", bundleKEKEnv)
	}
	return plain, nil
}
