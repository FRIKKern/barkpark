package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// PRIMING IS THE HALF OF A CLAIM NOBODY RECORDS (task-b55fafd148bb2578, P1).
//
// A claim records WHO took a row and WHEN. It records nothing about what the
// agent was holding when it took it: which primer documents it had read, at
// which bytes, from which checkout, at which HEAD, under which model. When a
// lease lapses and a successor picks the row up, that loadout is gone — the
// successor reconstructs it by guessing, and a guess that is wrong is
// indistinguishable from one that is right until it has already shipped.
//
// This file writes that loadout down AT CLAIM TIME, next to the held-file
// append that already rides the same success path, and proves the write the
// same way: by READING IT BACK and re-parsing it. A manifest that silently did
// not land is the failure this exists to prevent, so it is never assumed.
//
// Opt-in by env var, so no existing invocation changes behaviour:
//
//	BARKPARK_PRIMING_DIR=/path/to/dir bp task claim <id> <worker>
//
// The primer set is named by BARKPARK_PRIMERS (os.PathListSeparator-separated
// paths). Each is hashed by content, so two agents that claim "the same brief"
// can be shown to have held the same bytes — or not.
//
// ============================== THE THREE-STATE LAW ==========================
//
// Every measured field is a POINTER. The three states are distinct and the
// distinction is the whole value of the record:
//
//	nil    UNMEASURED — there was no source to ask. Nothing is claimed.
//	false  a VERDICT — something was asked and answered "no".
//	true   a VERDICT — something was asked and answered "yes".
//
// An unset env var is UNMEASURED, never an empty-string answer. DirtyTree is
// false only when git RAN and reported a clean tree; git being absent or
// failing leaves it nil, because "we could not look" and "we looked and it was
// clean" are not the same fact and must never serialize to the same byte.
//
// THE ROLL-UP'S NIL RULE DOMINATES ITS FALSE RULE. Primed is nil if ANY
// component is UNMEASURED — an incomplete measurement cannot produce a verdict
// about the whole, in either direction. Only when every component answered may
// Primed be true or false.
//
// ONE DELIBERATE RULING, because it is the case where the two readings are
// genuinely arguable: a primer that is LISTED but could not be read is a
// MEASURED failure, not an unmeasured one. The filesystem was asked and it
// answered (absent / unreadable). So such a primer drives Primed to FALSE and
// carries Error naming why, while its SHA256 stays nil because no hash exists
// to record. A primer that cannot be read is a priming defect the successor
// must see, not a silence.
//
// ================================ ON "SIGNED" ================================
//
// Digest is a CONTENT CHECKSUM, not a signature. It binds the manifest's own
// bytes so tampering or truncation is detectable, and it is computed with no
// key material of any kind. This file mints no key, embeds no key, reads no
// key and rotates nothing. Real attribution — a server-stamped agent identity
// on every mutation — is the epic's P3 and is server-side work; nothing here
// should be read as providing it.

// primingSchema is the manifest format version. A successor that does not know
// this number must refuse to interpret the file rather than guess at it.
const primingSchema = 1

// PrimerArtifact is one primer document as it stood at claim time.
type PrimerArtifact struct {
	Path   string  `json:"path"`
	SHA256 *string `json:"sha256"`          // nil = no hash exists (unreadable)
	Bytes  *int64  `json:"bytes"`           // nil = not measured
	Error  string  `json:"error,omitempty"` // why it could not be read
}

// PrimingManifest is the loadout an agent held when it claimed a row.
type PrimingManifest struct {
	Schema    int              `json:"schema"`
	DocID     string           `json:"doc_id"`
	Worker    string           `json:"worker"`
	ClaimedAt string           `json:"claimed_at"`
	Model     *string          `json:"model"`
	Effort    *string          `json:"effort"`
	Worktree  *string          `json:"worktree"`
	Head      *string          `json:"head"`
	DirtyTree *bool            `json:"dirty_tree"`
	Primers   []PrimerArtifact `json:"primers"`
	Primed    *bool            `json:"primed"`
	Digest    string           `json:"digest"`
}

// primingEnv is every ambient input the builder is allowed to read, injected so
// both arms of each three-state field are provable without touching the host.
type primingEnv struct {
	getenv   func(string) string
	readFile func(string) ([]byte, error)
	git      func(args ...string) (string, error)
	now      func() time.Time
}

func defaultPrimingEnv() primingEnv {
	return primingEnv{
		getenv:   os.Getenv,
		readFile: os.ReadFile,
		git: func(args ...string) (string, error) {
			out, err := exec.Command("git", args...).Output()
			return string(out), err
		},
		now: time.Now,
	}
}

// primingDirPath is the directory the manifest must reach, or "" when the
// caller opted out (the default).
func primingDirPath(getenv func(string) string) string {
	return strings.TrimSpace(getenv("BARKPARK_PRIMING_DIR"))
}

// optional returns a pointer to a trimmed env value, or nil when the variable
// is unset or blank. THIS is the three-state law's entry point: a blank env var
// is UNMEASURED, never an empty-string answer.
func optional(getenv func(string) string, key string) *string {
	v := strings.TrimSpace(getenv(key))
	if v == "" {
		return nil
	}
	return &v
}

// primerPaths splits BARKPARK_PRIMERS on the platform list separator, dropping
// blanks. An unset variable yields no paths — which is not an error: an agent
// may legitimately claim with no primer documents.
func primerPaths(getenv func(string) string) []string {
	raw := strings.TrimSpace(getenv("BARKPARK_PRIMERS"))
	if raw == "" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(raw, string(os.PathListSeparator)) {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// hashPrimers reads and content-hashes each listed primer. A primer that cannot
// be read is recorded as a MEASURED failure (see the ruling in the header), and
// the second return reports whether every primer hashed.
func hashPrimers(env primingEnv, paths []string) ([]PrimerArtifact, bool) {
	all := true
	arts := make([]PrimerArtifact, 0, len(paths))
	for _, p := range paths {
		b, err := env.readFile(p)
		if err != nil {
			all = false
			arts = append(arts, PrimerArtifact{Path: p, Error: err.Error()})
			continue
		}
		sum := sha256.Sum256(b)
		h := hex.EncodeToString(sum[:])
		n := int64(len(b))
		arts = append(arts, PrimerArtifact{Path: p, SHA256: &h, Bytes: &n})
	}
	return arts, all
}

// gitFacts resolves the checkout the claim was made from. Every field stays nil
// when git could not answer — an absent git, a non-repo directory, or a failed
// invocation are all UNMEASURED, never a clean-tree verdict.
func gitFacts(env primingEnv) (worktree, head *string, dirty *bool) {
	if env.git == nil {
		return nil, nil, nil
	}
	if out, err := env.git("rev-parse", "--show-toplevel"); err == nil {
		if v := strings.TrimSpace(out); v != "" {
			worktree = &v
		}
	}
	if out, err := env.git("rev-parse", "HEAD"); err == nil {
		if v := strings.TrimSpace(out); v != "" {
			head = &v
		}
	}
	// status --porcelain answers for BOTH verdicts: empty output is a clean
	// tree (false), any output is a dirty one (true). Only an ERROR leaves it
	// nil, and that is the whole point of running it separately.
	if out, err := env.git("status", "--porcelain"); err == nil {
		d := strings.TrimSpace(out) != ""
		dirty = &d
	}
	return worktree, head, dirty
}

// buildPrimingManifest is the pure core: it takes the claim and the injected
// ambient inputs and produces the manifest, digest included.
func buildPrimingManifest(env primingEnv, docID, worker string) PrimingManifest {
	worktree, head, dirty := gitFacts(env)
	primers, allHashed := hashPrimers(env, primerPaths(env.getenv))

	m := PrimingManifest{
		Schema:    primingSchema,
		DocID:     docID,
		Worker:    worker,
		ClaimedAt: env.now().UTC().Format(time.RFC3339),
		Model:     optional(env.getenv, "BARKPARK_AGENT_MODEL"),
		Effort:    optional(env.getenv, "BARKPARK_AGENT_EFFORT"),
		Worktree:  worktree,
		Head:      head,
		DirtyTree: dirty,
		Primers:   primers,
	}
	m.Primed = primedRollup(m, allHashed)
	m.Digest = primingDigest(m)
	return m
}

// primedRollup applies the nil rule. It is separate and named so the rule is a
// thing a test can drive directly, rather than a branch buried in a builder.
//
// NIL DOMINATES: any UNMEASURED component and the roll-up is nil. Only when
// every component answered does a verdict exist — and then it is false iff some
// listed primer could not be read.
func primedRollup(m PrimingManifest, allHashed bool) *bool {
	if m.Model == nil || m.Effort == nil || m.Worktree == nil || m.Head == nil || m.DirtyTree == nil {
		return nil
	}
	v := allHashed
	return &v
}

// primingDigest is a keyless content checksum over the manifest with the digest
// field itself blanked, so the value is well-defined and re-derivable. It is
// NOT a signature and proves no identity.
func primingDigest(m PrimingManifest) string {
	m.Digest = ""
	b, err := json.Marshal(m)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// primingManifestPath is where a row's manifest lives inside the priming dir.
func primingManifestPath(dir, docID string) string {
	return filepath.Join(dir, docID+".priming.json")
}

// primingIO is the filesystem writePrimingManifest is allowed to touch,
// injected for ONE reason that is not a style preference: the failure the
// readback exists to catch is a write that reports SUCCESS and does not land.
// os cannot be made to do that on demand, so without injection the readback has
// no arm that reds when it is deleted — measured, on this very file: removing
// the readback left the whole suite green. See TestReadbackCatchesASilentlyLostWrite.
type primingIO struct {
	mkdirAll  func(string, os.FileMode) error
	writeFile func(string, []byte, os.FileMode) error
	readFile  func(string) ([]byte, error)
}

func osPrimingIO() primingIO {
	return primingIO{mkdirAll: os.MkdirAll, writeFile: os.WriteFile, readFile: os.ReadFile}
}

// writePrimingManifest writes the manifest and then PROVES it: the file is read
// back, re-parsed, and its doc id and digest compared against what was written.
// A write that did not land, landed truncated, or landed as something that no
// longer parses fails loud here instead of being discovered by the successor
// who needed it.
func writePrimingManifest(dir string, m PrimingManifest) error {
	return writePrimingManifestIO(osPrimingIO(), dir, m)
}

func writePrimingManifestIO(io primingIO, dir string, m PrimingManifest) error {
	if err := io.mkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("could not create priming dir %s: %w — this claim's loadout is NOT recorded", dir, err)
	}
	path := primingManifestPath(dir, m.DocID)
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("could not encode priming manifest for %s: %w", m.DocID, err)
	}
	if err := io.writeFile(path, append(b, '\n'), 0o644); err != nil {
		return fmt.Errorf("could not write priming manifest %s: %w — this claim's loadout is NOT recorded", path, err)
	}
	// THE READBACK.
	back, err := io.readFile(path)
	if err != nil {
		return fmt.Errorf("priming-manifest readback FAILED: could not re-read %s: %w", path, err)
	}
	var got PrimingManifest
	if err := json.Unmarshal(back, &got); err != nil {
		return fmt.Errorf("priming-manifest readback FAILED: %s does not parse: %w", path, err)
	}
	if got.DocID != m.DocID || got.Digest != m.Digest {
		return fmt.Errorf(
			"priming-manifest readback FAILED: %s holds doc_id=%q digest=%q, expected doc_id=%q digest=%q",
			path, got.DocID, got.Digest, m.DocID, m.Digest)
	}
	// And the digest must still describe the bytes that came back, or the file
	// says one thing and hashes as another.
	if re := primingDigest(got); re != got.Digest {
		return fmt.Errorf(
			"priming-manifest readback FAILED: %s carries digest %q but its own content hashes to %q",
			path, got.Digest, re)
	}
	return nil
}

// recordPrimingManifest is the claim path's entry point. Returns exitOK when no
// priming dir is configured (the default — no existing invocation changes), and
// exitGeneric with a loud message when the manifest could not be PROVEN.
func recordPrimingManifest(out *writer, env primingEnv, docID, worker string) int {
	return recordPrimingManifestOf(out, env, docID, worker, nil)
}

// recordPrimingManifestOf is recordPrimingManifest with the manifest ALREADY
// BUILT — the shape the wire half needs (tasks_flight_recorder.go). The claim
// path builds once, before the POST, and hands that same value here so the
// ledger's copy and the directory's copy carry one ClaimedAt and one Digest.
// A nil `pre` means nobody built one yet, and this builds it exactly as before.
func recordPrimingManifestOf(out *writer, env primingEnv, docID, worker string, pre *PrimingManifest) int {
	dir := primingDirPath(env.getenv)
	if dir == "" {
		return exitOK
	}
	if strings.TrimSpace(docID) == "" {
		out.errf("priming: could not resolve the claimed doc id; no loadout recorded in %s\n", dir)
		return exitGeneric
	}
	m := buildPrimingManifest(env, docID, worker)
	if pre != nil {
		m = *pre
	}
	if err := writePrimingManifest(dir, m); err != nil {
		out.errf("priming: %v\n", err)
		return exitGeneric
	}
	out.errf("priming: %s loadout recorded in %s (readback confirmed, digest %s, primed=%s)\n",
		docID, primingManifestPath(dir, docID), m.Digest[:12], tristate(m.Primed))
	return exitOK
}

// tristate renders a three-state field for a human, keeping UNMEASURED visibly
// distinct from a false verdict on the terminal exactly as it is on the wire.
func tristate(b *bool) string {
	if b == nil {
		return "UNMEASURED"
	}
	if *b {
		return "true"
	}
	return "false"
}
