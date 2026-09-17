package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// BP-ONB-17 — `bp bulldocs publish <slug> --file paper.json` DISCARDED the slug
// the caller typed.
//
// The command posts to /v1/plugins/bulldocs/papers, a path template with no
// `:slug` placeholder, so manifest.Command.ArgLocation puts `slug` in the BODY.
// buildBody's --file shortcut — "a plain (non-mutation) write with no body
// flags to merge ships the file verbatim" — returned before the body-arg
// seeding loop ever ran, so the typed slug never reached the wire. Measured on
// guerrilla before the fix:
//
//	$ bp bulldocs publish cli-r21-w25-scratch-alpha --file paper-noslug.json --yes
//	bp: slug plus either blocks (list), body_html (string), or bpml (string) are required
//	  code: malformed
//
//	$ bp bulldocs publish cli-r21-w25-scratch-alpha --file paper-otherslug.json --yes
//	rev: 1
//	warning[label_norm]: cli-r21-w25-scratch-beta: 1 tag(s) …
//	  → the paper landed at cli-r21-w25-scratch-beta; `alpha` was never sent,
//	    and the receipt never named the slug it DID use.
//
// bulldocsPublishCmd is that shipped command, verbatim from the guerrilla
// manifest (source plugin:bulldocs) minus the summaries.
func bulldocsPublishCmd() manifest.Command {
	return manifest.Command{
		ID:     "bulldocs.publish",
		Noun:   "bulldocs",
		Verb:   "publish",
		Writes: true,
		Args:   []manifest.Arg{{Name: "slug", Type: "slug", Required: true}},
		Flags:  []manifest.Flag{{Name: "file", Type: "file"}},
		HTTP:   manifest.HTTP{Method: "POST", PathTemplate: "/v1/plugins/bulldocs/papers"},
	}
}

func writeTempJSON(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

// RED WITHOUT THE FIX: before commandHasSuppliedBodyArgs joined the shortcut's
// guard, buildBody returned the file bytes verbatim and the body had no "slug"
// key at all — exactly the request the server answered `malformed` to.
func TestPublishFileKeepsTheGivenSlug(t *testing.T) {
	path := writeTempJSON(t, "paper.json", `{"title":"Probe","blocks":[]}`)

	body, stream, ct, err := buildBody(
		bulldocsPublishCmd(),
		map[string][]string{"file": {path}},
		map[string]string{"slug": "the-slug-i-typed"},
	)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if stream != nil || ct != "application/json" {
		t.Fatalf("stream=%v contentType=%q, want a JSON body", stream, ct)
	}

	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body is not a JSON object: %v (%s)", err, body)
	}
	if got["slug"] != "the-slug-i-typed" {
		t.Errorf("slug = %v, want the slug the caller typed; the --file shortcut dropped it (BP-ONB-17). body=%s", got["slug"], body)
	}
	// The file's own fields still ride along — the arg is a merge, not a
	// replacement.
	if got["title"] != "Probe" {
		t.Errorf("title = %v, want the file's title preserved. body=%s", got["title"], body)
	}
}

// The quiet arm: a --file write on a command with NO supplied body arg still
// ships the file byte-for-byte. This is the contract the shortcut exists for
// (schema.apply, doc.mutate), and it must not move.
func TestPublishFileWithoutBodyArgStillShipsVerbatim(t *testing.T) {
	const raw = `{"title":"Probe","blocks":[],"extra":{"nested":[1,2,3]}}`
	path := writeTempJSON(t, "paper.json", raw)

	body, _, _, err := buildBody(
		bulldocsPublishCmd(),
		map[string][]string{"file": {path}},
		map[string]string{}, // no slug supplied
	)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if string(body) != raw {
		t.Errorf("body = %s, want the file shipped verbatim (%s)", body, raw)
	}
}

// A file that names a DIFFERENT slug loses to the one the caller typed — the
// same precedence TestBuildBodyDocCreateFileMergeAndDryRun pins for
// `doc create <type>` — and the receipt arm below is what keeps that from being
// silent.
func TestPublishFileGivenSlugBeatsTheFilesSlug(t *testing.T) {
	path := writeTempJSON(t, "paper.json", `{"slug":"the-files-slug","title":"Probe","blocks":[]}`)

	body, _, _, err := buildBody(
		bulldocsPublishCmd(),
		map[string][]string{"file": {path}},
		map[string]string{"slug": "the-slug-i-typed"},
	)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body is not a JSON object: %v", err)
	}
	if got["slug"] != "the-slug-i-typed" {
		t.Errorf("slug = %v, want the slug the caller typed to beat the file's", got["slug"])
	}
}

// An AGREEING file slug is not a conflict — it is the same write spelled twice.
func TestPublishFileAgreeingSlugIsAccepted(t *testing.T) {
	path := writeTempJSON(t, "paper.json", `{"slug":"same-slug","title":"Probe","blocks":[]}`)

	body, _, _, err := buildBody(
		bulldocsPublishCmd(),
		map[string][]string{"file": {path}},
		map[string]string{"slug": "same-slug"},
	)
	if err != nil {
		t.Fatalf("buildBody refused an agreeing slug: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body is not a JSON object: %v", err)
	}
	if got["slug"] != "same-slug" {
		t.Errorf("slug = %v, want same-slug", got["slug"])
	}
}

// The receipt half. The ingest endpoint answers
// {"ok":true,"slug":…,"rev":…,"title":…} with no id key, and renderMinimal
// printed `rev: 2` alone — so a substitution (or an upsert onto an existing
// paper) was invisible from the receipt.
func TestMinimalReceiptNamesThePublishedSlug(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderMinimal(w, []byte(`{"ok":true,"slug":"the-landed-slug","rev":"2","title":"Probe"}`))
	got := stdout.String()
	if !strings.Contains(got, "slug: the-landed-slug") {
		t.Errorf("receipt = %q, want it to name the slug the write landed on", got)
	}
	if !strings.Contains(got, "rev: 2") {
		t.Errorf("receipt = %q, want the rev line kept", got)
	}
}

// The quiet arm for the receipt: an id-bearing payload keeps its existing
// shape. Adding "slug" to collectIDs would have re-keyed every slug-bearing
// row; this pins that it did not.
func TestMinimalReceiptLeavesIDBearingPayloadsAlone(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderMinimal(w, []byte(`{"ok":true,"_id":"doc-1","slug":"a-slug","rev":"7"}`))
	got := stdout.String()
	if strings.Contains(got, "slug:") {
		t.Errorf("receipt = %q, want no slug line on an id-bearing payload", got)
	}
	if !strings.Contains(got, "id: doc-1") || !strings.Contains(got, "rev: 7") {
		t.Errorf("receipt = %q, want the existing id/rev receipt unchanged", got)
	}
}
