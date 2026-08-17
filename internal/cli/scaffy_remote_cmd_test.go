package cli

// scaffy_remote_cmd_test.go covers the W4 remote surface (D48–D50): the
// `ls --remote` catalog table, the `pull` pipeline (validate BEFORE any write,
// byte-identical source, committed provenance sidecar, unsubstituted ASSERT
// CMD templates), the ambiguity/not-found exits, and the D49 consent gate on
// running pulled commands. Every server is an httptest mock — no live network.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// scaffyRemoteNoteSrc is the pull/consent fixture: validate-clean, full
// label-spine header (DOMAIN/CONCEPT/VARIANT/DIRECTION), one CREATE + one
// marked INSERT, a token-bearing LOCAL CMD (substitution probe) and a TIER ci
// CMD (deferred probe).
const scaffyRemoteNoteSrc = `COMMAND "add-note" DESCRIPTION "Remote fixture: one CREATE plus one marked INSERT." DOMAIN "docs" CONCEPT "note" VARIANT "default" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name of the note." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/{{.note-name}}.txt"
::: note file :::
note {{.note-name}}
::: note file :::

IN "docs/list.txt"
INSERT AFTER FIRST
::: list head :::
head-anchor
::: list head :::
WITH
::: note entry :::
entry {{.note-name}} MARK:note-entry-{{.note-name}}
::: note entry :::
MARK "note-entry-{{.note-name}}"

ASSERT FILE "docs/{{.note-name}}.txt" CONTAINS "note {{.note-name}}"
ASSERT CMD "echo pulled {{.note-name}} # local gate"
ASSERT CMD "cd api && mix test" TIER ci
`

// scaffyRemoteCiOnlySrc declares ONLY a TIER ci CMD — the consent gate must
// say "no local commands run" honestly (4 of 7 corpus commands are ci-only).
const scaffyRemoteCiOnlySrc = `COMMAND "add-tag" DESCRIPTION "Remote fixture: ci-only asserts." DOMAIN "docs" CONCEPT "tag" VARIANT "default" DIRECTION "add"

VARIABLE 1 "TagName" TITLE "Tag" DESCRIPTION "Name of the tag." EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/tag-{{.tag-name}}.txt"
::: tag file :::
tag {{.tag-name}}
::: tag file :::

ASSERT FILE "docs/tag-{{.tag-name}}.txt" CONTAINS "tag {{.tag-name}}"
ASSERT CMD "cd api && mix test" TIER ci
`

// scaffyMockCommandServer serves {"documents": docs} for any GET on the
// generic /v1/data/query/<ds>/command route — the D50 zero-new-API shape.
func scaffyMockCommandServer(t *testing.T, docs []map[string]any) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.Contains(r.URL.Path, "/v1/data/query/") || !strings.HasSuffix(r.URL.Path, "/command") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"documents": docs})
	}))
	t.Cleanup(srv.Close)
	return srv
}

// scaffyMockPagingCommandServer serves the same {"documents": …} shape but
// HONORS ?limit=&offset= — the stock scaffyMockCommandServer ignores them and
// returns the whole slice every request, so it cannot expose ls --remote's
// single-page truncation. This one slices [offset:offset+limit], the exact
// contract the offset loop pages against.
func scaffyMockPagingCommandServer(t *testing.T, docs []map[string]any) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.Contains(r.URL.Path, "/v1/data/query/") || !strings.HasSuffix(r.URL.Path, "/command") {
			http.NotFound(w, r)
			return
		}
		q := r.URL.Query()
		limit, _ := strconv.Atoi(q.Get("limit"))
		if limit <= 0 {
			limit = len(docs)
		}
		offset, _ := strconv.Atoi(q.Get("offset"))
		page := []map[string]any{}
		if offset < len(docs) {
			end := offset + limit
			if end > len(docs) {
				end = len(docs)
			}
			page = docs[offset:end]
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"documents": page})
	}))
	t.Cleanup(srv.Close)
	return srv
}

// scaffyMutableCommandServer serves {"documents": *docs} — a POINTER-backed
// catalog so a test can drift the SAME server after a pull: mutate a doc's
// fields (source/rev) in place, or reassign *docs to shrink the catalog
// (doc-gone). This is what lets a server-drift test change the very server the
// sidecar was pulled from, instead of pointing --check at a different server —
// the D104 distinction the fix turns on.
func scaffyMutableCommandServer(t *testing.T, docs *[]map[string]any) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.Contains(r.URL.Path, "/v1/data/query/") || !strings.HasSuffix(r.URL.Path, "/command") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"documents": *docs})
	}))
	t.Cleanup(srv.Close)
	return srv
}

// scaffyGeneratedCatalog builds n served command docs with distinct
// concept/description per row — enough to overflow one page and to prove the
// description column survives across page boundaries.
func scaffyGeneratedCatalog(n int) []map[string]any {
	docs := make([]map[string]any, 0, n)
	for i := 0; i < n; i++ {
		docs = append(docs, map[string]any{
			"_id":         fmt.Sprintf("docs--cmd%04d--default", i),
			"title":       fmt.Sprintf("Cmd %04d", i),
			"concept":     fmt.Sprintf("cmd%04d", i),
			"variant":     "default",
			"domain":      "docs",
			"description": fmt.Sprintf("desc %04d", i),
		})
	}
	return docs
}

// scaffyRemoteDoc builds one served command document (flat content fields,
// D45/D46 shape).
func scaffyRemoteDoc(id, rev, concept, variant, domain, source string) map[string]any {
	return map[string]any{
		"_id": id, "_rev": rev,
		"title":       "Add " + concept,
		"concept":     concept,
		"variant":     variant,
		"domain":      domain,
		"direction":   "add",
		"description": "fixture " + concept,
		"source":      source,
	}
}

// chdirTemp moves the test into a fresh temp dir (pull writes relative to the
// cwd, exactly like run/remove resolve the repo root).
func chdirTemp(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Chdir(root)
	return root
}

func TestScaffyLsWithoutRemoteIsUsageError(t *testing.T) {
	withTempConfigHome(t)
	code, _, stderr := runScaffyTest(t, globals{}, "", "ls")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, "--remote") {
		t.Errorf("usage error should point at --remote:\n%s", stderr)
	}
}

func TestScaffyLsRemoteRendersCatalogTable(t *testing.T) {
	withTempConfigHome(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		{"_id": "barkpark--oban-worker--cron", "title": "Add Oban Cron Worker", "concept": "oban-worker", "variant": "cron", "domain": "barkpark", "description": "worker + crontab tuple"},
		{"_id": "docs--docs-card--add", "title": "Add Docs Card", "concept": "docs-card", "variant": "add", "domain": "docs", "description": "routing-table row + card"},
	})
	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "ls", "--remote")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	for _, want := range []string{"concept", "variant", "domain", "oban-worker", "cron", "barkpark", "docs-card"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("catalog table missing %q:\n%s", want, stdout)
		}
	}
}

func TestScaffyLsRemoteJSONEmitsDocumentsPayload(t *testing.T) {
	withTempConfigHome(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		{"_id": "docs--note--default", "concept": "note", "variant": "default", "domain": "docs"},
	})
	code, stdout, _ := runScaffyTest(t, globals{server: srv.URL}, "json", "ls", "--remote")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	var env struct {
		Documents []map[string]any `json:"documents"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not the documents payload: %v\n%s", err, stdout)
	}
	if len(env.Documents) != 1 || env.Documents[0]["concept"] != "note" {
		t.Errorf("documents payload = %+v", env.Documents)
	}
}

func TestScaffyLsRemoteServerErrorMapsExit(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such dataset"}}`))
	}))
	t.Cleanup(srv.Close)
	code, _, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "ls", "--remote")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitNotFound, stderr)
	}
}

// TestScaffyLsRemotePagesFullCatalog: a 1001-doc catalog served by a mock that
// honors limit+offset must ALL surface. Pre-fix (one doRequest, no loop) this
// returns 1000; post-fix the offset loop drains the second page too. This is
// the protective test the wave calls out (1000/1001 → 1001/1001).
func TestScaffyLsRemotePagesFullCatalog(t *testing.T) {
	withTempConfigHome(t)
	docs := scaffyGeneratedCatalog(1001)
	srv := scaffyMockPagingCommandServer(t, docs)

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "json", "ls", "--remote")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
	}
	var env struct {
		Documents []map[string]any `json:"documents"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not the documents payload: %v", err)
	}
	if len(env.Documents) != 1001 {
		t.Fatalf("ls --remote returned %d docs, want 1001 (single-page fix truncates to %d)", len(env.Documents), scaffyRemotePageLimit)
	}
	// The 1001st doc lives at offset 1000 — page two. Its presence proves the
	// loop advanced past the first page.
	last := env.Documents[len(env.Documents)-1]
	if last["concept"] != "cmd1000" {
		t.Errorf("last doc concept = %v, want cmd1000 (page-two doc dropped?)", last["concept"])
	}
}

// TestScaffyLsRemoteTableColumnsAcrossPages: the human table must keep the
// description column AND render a page-two row — accumulating RAW documents (not
// the typed scaffyCommandDoc, which has no Description field) is what preserves
// the column once the catalog spans more than one page.
func TestScaffyLsRemoteTableColumnsAcrossPages(t *testing.T) {
	withTempConfigHome(t)
	docs := scaffyGeneratedCatalog(1001)
	srv := scaffyMockPagingCommandServer(t, docs)

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "ls", "--remote")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
	}
	// "description" header + first-page and second-page description values must
	// all be present — the column is retained across the page boundary.
	for _, want := range []string{"description", "concept", "cmd1000", "desc 1000", "desc 0000"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("catalog table missing %q — column dropped or catalog truncated across pages", want)
		}
	}
}

func TestScaffyPullWritesByteIdenticalSourceAndSidecar(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "note")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}

	// Byte-identical source — no banner, no reformat (D49).
	dest := filepath.Join("scaffy", "commands", "docs--note--default.scaffy")
	got, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("pulled file missing: %v", err)
	}
	if string(got) != scaffyRemoteNoteSrc {
		t.Errorf("pulled bytes differ from the served source:\n%s", got)
	}

	// Committed sidecar next to it (NEVER under .scaffy/), sha matching the
	// written bytes.
	side := filepath.Join("scaffy", "commands", "docs--note--default.provenance.json")
	raw, err := os.ReadFile(side)
	if err != nil {
		t.Fatalf("provenance sidecar missing: %v", err)
	}
	var prov scaffyProvenance
	if err := json.Unmarshal(raw, &prov); err != nil {
		t.Fatalf("sidecar is not JSON: %v\n%s", err, raw)
	}
	sum := sha256.Sum256(got)
	want := scaffyProvenance{
		ProvenanceVersion: 1,
		Server:            srv.URL,
		DocID:             "docs--note--default",
		Rev:               "3",
		Concept:           "note",
		Variant:           "default",
		Domain:            "docs",
		Direction:         "add",
		FetchedAt:         prov.FetchedAt, // wall-clock; checked non-empty below
		SourceSHA256:      hex.EncodeToString(sum[:]),
	}
	if prov != want {
		t.Errorf("sidecar = %+v\nwant %+v", prov, want)
	}
	if prov.FetchedAt == "" {
		t.Error("sidecar fetched_at is empty")
	}
	if _, err := os.Stat(".scaffy"); err == nil {
		t.Error("pull created .scaffy/ — provenance must never live in the receipts lifecycle")
	}

	// The CMD templates print UNSUBSTITUTED, the ci tier is labeled, and the
	// dry-run preview hint is present.
	for _, wantOut := range []string{
		"UNSUBSTITUTED",
		"echo pulled {{.note-name}} # local gate",
		"cd api && mix test",
		"TIER ci",
		"--dry-run",
	} {
		if !strings.Contains(stdout, wantOut) {
			t.Errorf("pull output missing %q:\n%s", wantOut, stdout)
		}
	}
}

func TestScaffyPullValidationRefusalWritesNothing(t *testing.T) {
	withTempConfigHome(t)
	root := chdirTemp(t)
	// DIRECTION stripped — E-020, the validator's one lint-required header.
	corrupt := strings.Replace(scaffyRemoteNoteSrc, ` DIRECTION "add"`, "", 1)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", corrupt),
	})

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "note")
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	if !strings.Contains(stdout, "E-") {
		t.Errorf("refusal should print the validator findings:\n%s", stdout)
	}
	if !strings.Contains(stderr, "nothing written") {
		t.Errorf("stderr should state nothing was written:\n%s", stderr)
	}
	// NOTHING on disk — not the source, not the sidecar, not even the dir.
	entries, _ := os.ReadDir(root)
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("refused pull left files behind: %v", names)
	}
}

func TestScaffyPullAmbiguousConceptListsVariantsExitsTwo(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	fancy := strings.Replace(scaffyRemoteNoteSrc, `VARIANT "default"`, `VARIANT "fancy"`, 1)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
		scaffyRemoteDoc("docs--note--fancy", "1", "note", "fancy", "docs", fancy),
	})

	code, _, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "note")
	if code != exitUsage {
		t.Fatalf("ambiguous pull exit = %d, want %d\nstderr:\n%s", code, exitUsage, stderr)
	}
	for _, want := range []string{"note/default", "note/fancy", "2 variants"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("ambiguity message missing %q:\n%s", want, stderr)
		}
	}
	if entries, _ := os.ReadDir("."); len(entries) != 0 {
		t.Error("ambiguous pull must write nothing")
	}

	// Disambiguated, the same catalog pulls clean.
	code, _, stderr = runScaffyTest(t, globals{server: srv.URL}, "", "pull", "note/fancy")
	if code != exitOK {
		t.Fatalf("pull note/fancy exit = %d, want %d\nstderr:\n%s", code, exitOK, stderr)
	}
	if _, err := os.Stat(filepath.Join("scaffy", "commands", "docs--note--fancy.scaffy")); err != nil {
		t.Errorf("disambiguated pull did not land the variant file: %v", err)
	}
}

func TestScaffyPullUnknownConceptExitsFourWithKnownConcepts(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	code, _, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "nope")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "known concepts: note") {
		t.Errorf("not-found message should list the known concepts:\n%s", stderr)
	}
}

func TestScaffyPullUsageErrors(t *testing.T) {
	withTempConfigHome(t)
	cases := [][]string{
		{"pull"},                    // no target
		{"pull", "a", "b"},          // two targets
		{"pull", "note/"},           // empty variant after the slash
		{"pull", "--force", "note"}, // unknown flag
		{"pull", "/variant-only"},   // empty concept
	}
	for _, args := range cases {
		code, _, _ := runScaffyTest(t, globals{}, "", args...)
		if code != exitUsage {
			t.Errorf("scaffy %v exit = %d, want %d", args, code, exitUsage)
		}
	}
}

// seedPulledNoteTree lands the remote fixture AS IF pulled: source + adjacent
// provenance sidecar + the INSERT target, in a temp cwd.
func seedPulledNoteTree(t *testing.T) string {
	t.Helper()
	root := chdirTemp(t)
	writeCliFile(t, root, "pulled-note.scaffy", scaffyRemoteNoteSrc)
	writeCliFile(t, root, "pulled-note.provenance.json",
		`{"provenance_version":1,"server":"https://example.test","doc_id":"docs--note--default","concept":"note","variant":"default","domain":"docs","direction":"add","fetched_at":"2026-07-16T00:00:00Z","source_sha256":"x"}`)
	writeCliFile(t, root, "docs/list.txt", "head-anchor\ntail\n")
	return root
}

func TestScaffyRunPulledNonTTYWithoutYesRefusesListingSubstitutedCmds(t *testing.T) {
	root := seedPulledNoteTree(t)
	before := snapshotCliTree(t, root)

	code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitUsage, stdout, stderr)
	}
	// The would-run CMD prints SUBSTITUTED ({{.note-name}} → alpha) and the
	// TIER ci CMD is listed separately as deferred, never as would-run.
	if !strings.Contains(stdout, "$ echo pulled alpha # local gate") {
		t.Errorf("consent gate must list the substituted would-run CMD:\n%s", stdout)
	}
	if !strings.Contains(stdout, "deferred to CI") || !strings.Contains(stdout, "cd api && mix test") {
		t.Errorf("consent gate must list the deferred TIER ci CMD separately:\n%s", stdout)
	}
	if !strings.Contains(stderr, "--yes") {
		t.Errorf("refusal should name --yes:\n%s", stderr)
	}

	// Refusal ran NOTHING and wrote NOTHING.
	after := snapshotCliTree(t, root)
	if len(after) != len(before) {
		t.Errorf("refused run changed the tree: %d files -> %d", len(before), len(after))
	}
	for rel, b := range before {
		if after[rel] != b {
			t.Errorf("refused run mutated %s", rel)
		}
	}
	if _, err := os.Stat(filepath.Join(root, ".scaffy")); err == nil {
		t.Error("refused run wrote a receipt")
	}
}

func TestScaffyRunPulledWithYesProceeds(t *testing.T) {
	root := seedPulledNoteTree(t)
	code, stdout, stderr := runScaffyTest(t, globals{yes: true}, "", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	// The consent enumeration still prints (auditable even under --yes) and
	// the run then applies for real.
	if !strings.Contains(stdout, "consent gate") {
		t.Errorf("--yes should still print the CMD enumeration:\n%s", stdout)
	}
	if _, err := os.Stat(filepath.Join(root, "docs", "alpha.txt")); err != nil {
		t.Errorf("consented run did not apply: %v", err)
	}
	if !strings.Contains(stdout, "applied") {
		t.Errorf("summary line missing:\n%s", stdout)
	}
}

func TestScaffyRunPulledInteractiveConfirm(t *testing.T) {
	answer := func(t *testing.T, line string) {
		t.Helper()
		oldTTY, oldIn := scaffyStdinIsTTY, scaffyStdin
		scaffyStdinIsTTY = func(io.Reader) bool { return true }
		scaffyStdin = strings.NewReader(line)
		t.Cleanup(func() { scaffyStdinIsTTY, scaffyStdin = oldTTY, oldIn })
	}

	t.Run("yes proceeds", func(t *testing.T) {
		root := seedPulledNoteTree(t)
		answer(t, "y\n")
		code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
		if code != exitOK {
			t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
		}
		if _, err := os.Stat(filepath.Join(root, "docs", "alpha.txt")); err != nil {
			t.Errorf("confirmed run did not apply: %v", err)
		}
	})

	t.Run("decline refuses", func(t *testing.T) {
		root := seedPulledNoteTree(t)
		answer(t, "n\n")
		code, _, stderr := runScaffyTest(t, globals{}, "", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
		if code != exitUsage {
			t.Fatalf("exit = %d, want %d\nstderr:\n%s", code, exitUsage, stderr)
		}
		if !strings.Contains(stderr, "aborted") {
			t.Errorf("decline should say aborted:\n%s", stderr)
		}
		if _, err := os.Stat(filepath.Join(root, "docs", "alpha.txt")); err == nil {
			t.Error("declined run applied anyway")
		}
	})
}

func TestScaffyRunPulledCiOnlySaysNoLocalCommands(t *testing.T) {
	root := chdirTemp(t)
	writeCliFile(t, root, "pulled-tag.scaffy", scaffyRemoteCiOnlySrc)
	writeCliFile(t, root, "pulled-tag.provenance.json", `{"provenance_version":1}`)

	code, stdout, _ := runScaffyTest(t, globals{}, "", "run", "pulled-tag.scaffy", "--var", "TagName=Alpha")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d\n%s", code, exitUsage, stdout)
	}
	if !strings.Contains(stdout, "no local commands run") {
		t.Errorf("ci-only pulled command must say no local commands run:\n%s", stdout)
	}
	if strings.Contains(stdout, "$ ") {
		t.Errorf("ci-only command must not list any would-run CMD:\n%s", stdout)
	}
}

func TestScaffyRunPulledDryRunAbortRefusesWithOpError(t *testing.T) {
	root := seedPulledNoteTree(t)
	// Break the INSERT anchor: the consent dry-run aborts at that op and the
	// refusal carries THAT error — no CMD list implied for a command that
	// cannot even apply.
	writeCliFile(t, root, "docs/list.txt", "no anchor here\n")

	code, stdout, stderr := runScaffyTest(t, globals{yes: true}, "", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	if strings.Contains(stdout, "would run") || strings.Contains(stdout, "$ echo") {
		t.Errorf("an aborting dry-run must not imply a CMD list:\n%s", stdout)
	}
	if _, err := os.Stat(filepath.Join(root, "docs", "alpha.txt")); err == nil {
		t.Error("aborted consent run wrote the CREATE file")
	}
}

// TestScaffyRunSidecarlessKeepsW3Behavior: without a provenance sidecar the
// run applies straight through — no consent gate, no prompt, exit 0 on a
// non-TTY without --yes (alongside the W3 suite, which runs the same path).
func TestScaffyRunSidecarlessKeepsW3Behavior(t *testing.T) {
	root := chdirTemp(t)
	writeCliFile(t, root, "authored-note.scaffy", scaffyRemoteNoteSrc)
	writeCliFile(t, root, "docs/list.txt", "head-anchor\ntail\n")

	code, stdout, stderr := runScaffyTest(t, globals{}, "", "run", "authored-note.scaffy", "--var", "NoteName=Alpha")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if strings.Contains(stdout, "consent gate") {
		t.Errorf("sidecar-less run must not be consent-gated:\n%s", stdout)
	}
	if _, err := os.Stat(filepath.Join(root, "docs", "alpha.txt")); err != nil {
		t.Errorf("run did not apply: %v", err)
	}
}

// pullNoteAgainst pulls the note fixture from srv into the cwd (source +
// sidecar), asserting the pull itself succeeded — the shared setup for the
// --check drift tests below.
func pullNoteAgainst(t *testing.T, srvURL string) {
	t.Helper()
	code, stdout, stderr := runScaffyTest(t, globals{server: srvURL}, "", "pull", "note")
	if code != exitOK {
		t.Fatalf("setup pull exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
}

const scaffyPulledNoteDest = "scaffy/commands/docs--note--default.scaffy"

// TestScaffyPullCheckCleanExitsZero: a freshly pulled command, unchanged on
// both disk and server, audits clean with a summary line and exit 0.
func TestScaffyPullCheckClean(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	pullNoteAgainst(t, srv.URL)

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitOK {
		t.Fatalf("clean --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "clean:") || !strings.Contains(stdout, "1 pulled command") {
		t.Errorf("clean --check missing summary line:\n%s", stdout)
	}
	if strings.Contains(stdout, "R-004") || strings.Contains(stdout, "R-005") {
		t.Errorf("clean --check must emit no drift finding:\n%s", stdout)
	}
}

// TestScaffyPullCheckLocalEditRedsR004: a one-byte hand-edit of the pulled
// .scaffy trips R-004, exit 5, with the compiler-style named finding.
func TestScaffyPullCheckLocalEditRedsR004(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	pullNoteAgainst(t, srv.URL)

	// Hand-edit one byte of the landed source — server is untouched.
	edited := scaffyRemoteNoteSrc + "\n# hand-edited\n"
	if err := os.WriteFile(scaffyPulledNoteDest, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("local-edit --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	// Compiler-style "file:line: R-004 message", pointing at the edited source.
	lineRe := regexp.MustCompile(regexp.QuoteMeta(filepath.ToSlash(scaffyPulledNoteDest)) + `:\d+: R-004 `)
	if !lineRe.MatchString(stdout) {
		t.Errorf("no R-004 compiler-style finding on the edited source:\n%s", stdout)
	}
	if !strings.Contains(stdout, "local edit since pull") {
		t.Errorf("R-004 message should name the local edit:\n%s", stdout)
	}
	// Server axis is clean — no R-005 for an untouched server.
	if strings.Contains(stdout, "R-005") {
		t.Errorf("untouched server must not red R-005:\n%s", stdout)
	}
}

// TestScaffyPullCheckServerDriftRedsR005: real server-side drift — the command
// is pulled from a server, then THAT SAME server (prov.Server) drifts its served
// source (new sha + rev). --check must red R-005 (D104: the check re-fetches the
// command's own source server, not the connected one). Re-semanticized from the
// old two-server form, which mislabeled a wrong-server mismatch as legitimate
// drift; drift is now provoked on the very server the sidecar records.
func TestScaffyPullCheckServerDriftRedsR005(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	docs := []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	}
	srv := scaffyMutableCommandServer(t, &docs)
	pullNoteAgainst(t, srv.URL)

	// The SAME server's source drifts: a byte appended AND the rev advances.
	drifted := scaffyRemoteNoteSrc + "\nASSERT FILE \"docs/{{.note-name}}.txt\" CONTAINS \"note\"\n"
	docs[0]["source"] = drifted
	docs[0]["_rev"] = "9"

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("server-drift --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	lineRe := regexp.MustCompile(regexp.QuoteMeta(filepath.ToSlash(scaffyPulledNoteDest)) + `:\d+: R-005 `)
	if !lineRe.MatchString(stdout) {
		t.Errorf("no R-005 compiler-style finding for the drifted server source:\n%s", stdout)
	}
	if !strings.Contains(stdout, "server source changed") {
		t.Errorf("R-005 message should name the server source change:\n%s", stdout)
	}
	// The local file was never touched — no R-004.
	if strings.Contains(stdout, "R-004") {
		t.Errorf("untouched local file must not red R-004:\n%s", stdout)
	}
}

// TestScaffyPullCheckServerDocGoneRedsR005: the doc vanishes from its OWN source
// server's catalog entirely — still R-005 (no longer served), exit 5. Re-
// semanticized to shrink the same server the sidecar was pulled from (D104),
// rather than the old form which pointed --check at an unrelated empty server.
func TestScaffyPullCheckServerDocGoneRedsR005(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	docs := []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	}
	srv := scaffyMutableCommandServer(t, &docs)
	pullNoteAgainst(t, srv.URL)

	// The SAME server drops the doc from its catalog.
	docs = []map[string]any{}
	_ = docs // reassignment is observed through the pointer the server holds

	code, stdout, _ := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("gone-doc --check exit = %d, want %d\n%s", code, exitValidation, stdout)
	}
	if !strings.Contains(stdout, "R-005") || !strings.Contains(stdout, "no longer served") {
		t.Errorf("a vanished doc should red R-005 'no longer served':\n%s", stdout)
	}
}

// TestScaffyPullCheckBothAxesTogether: a file edited locally AND drifted on its
// OWN source server yields both R-004 and R-005 in one audit, exit 5. Re-
// semanticized to drift the same server the sidecar records (D104), so the R-005
// is genuine server drift rather than a wrong-server mismatch.
func TestScaffyPullCheckBothAxesTogether(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	docs := []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	}
	srv := scaffyMutableCommandServer(t, &docs)
	pullNoteAgainst(t, srv.URL)

	if err := os.WriteFile(scaffyPulledNoteDest, []byte(scaffyRemoteNoteSrc+"\n# local\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Same server drifts its served source.
	docs[0]["source"] = scaffyRemoteNoteSrc + "\n# server\n"
	docs[0]["_rev"] = "9"

	code, stdout, _ := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("both-axes --check exit = %d, want %d\n%s", code, exitValidation, stdout)
	}
	if !strings.Contains(stdout, "R-004") || !strings.Contains(stdout, "R-005") {
		t.Errorf("both axes should red together:\n%s", stdout)
	}
}

// ---- D104 two-server regression probe -------------------------------------
//
// These three tests are the permanent form of the two-live-httptest-server
// probe that reproduced D104: `pull --check` audited each sidecar against the
// server bp was CONNECTED to, not the server the command was PULLED FROM
// (prov.Server). Every assertion here is INVERTED against the pre-fix code —
// each fails on the old scaffyCheckOne(p, ctx.Server, byID) and passes on the
// per-provenance-server fix. They cover the three failure shapes the bug
// produced: a false R-005, a coincidental-collision false clean, and a
// realistic cross-server drift that must stay isolated per source server.

// TestScaffyPullCheckAuditsProvenanceServerNotConnected (false-R005): a command
// pulled from source server A, audited while bp is CONNECTED to a different
// server B that never served it. Pre-fix: --check audits B, the doc is absent,
// and it reds a FALSE R-005 "no longer served". Post-fix: --check audits A (the
// sidecar's own server, untouched) and stays clean, exit 0.
func TestScaffyPullCheckAuditsProvenanceServerNotConnected(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	serverA := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	pullNoteAgainst(t, serverA.URL)

	// Connected server B knows nothing of this doc.
	serverB := scaffyMockCommandServer(t, []map[string]any{})

	code, stdout, stderr := runScaffyTest(t, globals{server: serverB.URL}, "", "pull", "--check")
	if code != exitOK {
		t.Fatalf("wrong-connected-server --check exit = %d, want %d (pre-fix reds a false R-005 against server B)\nstdout:\n%s\nstderr:\n%s",
			code, exitOK, stdout, stderr)
	}
	if strings.Contains(stdout, "R-005") {
		t.Errorf("no drift on the sidecar's own server A — a false R-005 against the connected server B is the D104 bug:\n%s", stdout)
	}
	if !strings.Contains(stdout, "clean:") {
		t.Errorf("audit against the correct provenance server (A) should report clean:\n%s", stdout)
	}
}

// TestScaffyPullCheckCoincidentalCollisionNoFalseClean (coincidental-collision
// false-clean): a command pulled from source server A that then DRIFTS on A,
// while the CONNECTED server B coincidentally serves the same doc id at the
// sidecar's original bytes. Pre-fix: --check audits B, the sha matches, and it
// reports a FALSE clean — silently missing A's real drift. Post-fix: --check
// audits A and reds R-005.
func TestScaffyPullCheckCoincidentalCollisionNoFalseClean(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	docsA := []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	}
	serverA := scaffyMutableCommandServer(t, &docsA)
	pullNoteAgainst(t, serverA.URL)

	// A drifts AFTER the pull — genuine upstream drift on the sidecar's server.
	docsA[0]["source"] = scaffyRemoteNoteSrc + "\n# drifted on A\n"
	docsA[0]["_rev"] = "9"

	// Connected server B coincidentally serves the SAME doc id at the SAME
	// original bytes the sidecar recorded — the sha collides.
	serverB := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})

	code, stdout, stderr := runScaffyTest(t, globals{server: serverB.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("coincidental-collision --check exit = %d, want %d (pre-fix false-clean against server B misses A's drift)\nstdout:\n%s\nstderr:\n%s",
			code, exitValidation, stdout, stderr)
	}
	if !strings.Contains(stdout, "R-005") || !strings.Contains(stdout, "server source changed") {
		t.Errorf("A's real drift must red R-005 even though connected server B coincidentally matches the recorded sha:\n%s", stdout)
	}
}

// TestScaffyPullCheckCrossServerDriftIsolated (realistic cross-server drift):
// two commands pulled from two different servers — the note from A (untouched),
// the memo from B (drifts). Connected to B, --check must isolate per source
// server: pre-fix it audits everything against B, so the note (absent on B)
// reds a FALSE R-005; post-fix the note (A) stays clean and only the memo (B)
// reds R-005.
func TestScaffyPullCheckCrossServerDriftIsolated(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	serverA := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	docsB := []map[string]any{
		scaffyRemoteDoc("docs--memo--default", "3", "memo", "default", "docs", scaffyRemoteNoteSrc),
	}
	serverB := scaffyMutableCommandServer(t, &docsB)

	pullNoteAgainst(t, serverA.URL)
	if code, stdout, stderr := runScaffyTest(t, globals{server: serverB.URL}, "", "pull", "memo"); code != exitOK {
		t.Fatalf("setup pull memo exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}

	// B drifts the memo; A's note is untouched.
	docsB[0]["source"] = scaffyRemoteNoteSrc + "\n# drifted memo\n"
	docsB[0]["_rev"] = "9"

	code, stdout, stderr := runScaffyTest(t, globals{server: serverB.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("cross-server --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	noteFile := "scaffy/commands/docs--note--default.scaffy"
	memoFile := "scaffy/commands/docs--memo--default.scaffy"
	// The discriminating assertion: the note (source server A, untouched) must
	// carry NO R-005 — pre-fix it reds a false one against connected server B.
	if regexp.MustCompile(regexp.QuoteMeta(noteFile) + `:\d+: R-005 `).MatchString(stdout) {
		t.Errorf("the note (source server A, untouched) must not red — a false R-005 against connected server B is the D104 bug:\n%s", stdout)
	}
	// The memo (drifted on its own server B) must red R-005.
	if !regexp.MustCompile(regexp.QuoteMeta(memoFile) + `:\d+: R-005 `).MatchString(stdout) {
		t.Errorf("the memo (drifted on its own source server B) must red R-005:\n%s", stdout)
	}
}

// TestScaffyPullCheckNoPulledCommands: nothing under scaffy/commands/ is a
// clean, network-free exit 0 (the fetch is never attempted).
func TestScaffyPullCheckNoPulledCommands(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	// A server that fails any request — proves --check never touches it when
	// there is nothing to audit.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "should not be called", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitOK {
		t.Fatalf("empty --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "no pulled commands") {
		t.Errorf("empty --check should say so:\n%s", stdout)
	}
}

// TestScaffyPullCheckJSONEnvelope: --check honors -o json like its siblings —
// {ok, checked, findings}, ok=false + a R-004 finding on a local edit.
func TestScaffyPullCheckJSONEnvelope(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	pullNoteAgainst(t, srv.URL)

	// Clean first: ok=true, checked=1, no findings.
	code, stdout, _ := runScaffyTest(t, globals{server: srv.URL}, "json", "pull", "--check")
	if code != exitOK {
		t.Fatalf("clean json --check exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	var clean struct {
		Ok       bool             `json:"ok"`
		Checked  int              `json:"checked"`
		Findings []map[string]any `json:"findings"`
	}
	if err := json.Unmarshal([]byte(stdout), &clean); err != nil {
		t.Fatalf("clean stdout is not one JSON envelope: %v\n%s", err, stdout)
	}
	if !clean.Ok || clean.Checked != 1 || len(clean.Findings) != 0 {
		t.Errorf("clean envelope = %+v, want ok/checked=1/no findings", clean)
	}

	// Now edit and re-check under json: ok=false with the R-004 finding.
	if err := os.WriteFile(scaffyPulledNoteDest, []byte(scaffyRemoteNoteSrc+"\n# edit\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, stdout, _ = runScaffyTest(t, globals{server: srv.URL}, "json", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("drift json --check exit = %d, want %d\n%s", code, exitValidation, stdout)
	}
	var drift struct {
		Ok       bool `json:"ok"`
		Checked  int  `json:"checked"`
		Findings []struct {
			File string `json:"file"`
			Rule string `json:"rule"`
			Msg  string `json:"message"`
		} `json:"findings"`
	}
	if err := json.Unmarshal([]byte(stdout), &drift); err != nil {
		t.Fatalf("drift stdout is not one JSON envelope: %v\n%s", err, stdout)
	}
	if drift.Ok || len(drift.Findings) != 1 || drift.Findings[0].Rule != "R-004" {
		t.Errorf("drift envelope = %+v, want ok=false + one R-004 finding", drift)
	}
}

// TestScaffyPullCheckUnreachableProvenanceServerRedsR005: with a pulled command
// present but its OWN source server unreachable, --check cannot complete axis (b)
// for that command — so it emits a distinct NAMED R-005 finding (exit 5), never a
// silent skip and never a false-clean. Re-semanticized from the old
// hard-error form: under per-server grouping (D104) one unreachable server must
// not blank-abort the whole audit (other servers + the local axis still resolve),
// so an unreachable server is a finding on its commands, loudly named.
func TestScaffyPullCheckUnreachableProvenanceServerRedsR005(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	pullNoteAgainst(t, srv.URL)
	srv.Close() // the sidecar's own provenance server is now unreachable

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("unreachable --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	// The finding names the axis (R-005), the unreachable server, and that drift
	// was left unverified — never silent.
	if !strings.Contains(stdout, "R-005") || !strings.Contains(stdout, "unreachable") || !strings.Contains(stdout, "unverified") {
		t.Errorf("unreachable provenance server must red a named R-005 'unreachable … unverified' finding:\n%s", stdout)
	}
	// The local axis still ran: the on-disk file is untouched, so NO R-004.
	if strings.Contains(stdout, "R-004") {
		t.Errorf("untouched local file must not red R-004 even when the server is unreachable:\n%s", stdout)
	}
}

// TestScaffyPullCheckEmptyProvenanceServerRedsR005: a sidecar whose server
// field is empty cannot have axis (b) verified against ANY catalog — D104
// demands a distinct NAMED R-005 finding (exit 5), never a silent skip and
// never a verdict borrowed from the connected server.
func TestScaffyPullCheckEmptyProvenanceServerRedsR005(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	srv := scaffyMockCommandServer(t, []map[string]any{
		scaffyRemoteDoc("docs--note--default", "3", "note", "default", "docs", scaffyRemoteNoteSrc),
	})
	pullNoteAgainst(t, srv.URL)

	// Blank the sidecar's server field in place (a hand-edited or
	// legacy-migrated sidecar) — everything else stays intact.
	sidecar := "scaffy/commands/docs--note--default.provenance.json"
	raw, err := os.ReadFile(sidecar)
	if err != nil {
		t.Fatal(err)
	}
	var prov map[string]any
	if err := json.Unmarshal(raw, &prov); err != nil {
		t.Fatal(err)
	}
	prov["server"] = ""
	blanked, err := json.Marshal(prov)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sidecar, blanked, 0o644); err != nil {
		t.Fatal(err)
	}

	code, stdout, stderr := runScaffyTest(t, globals{server: srv.URL}, "", "pull", "--check")
	if code != exitValidation {
		t.Fatalf("empty-server --check exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitValidation, stdout, stderr)
	}
	if !strings.Contains(stdout, "R-005") || !strings.Contains(stdout, "records no source server") {
		t.Errorf("empty prov.Server must red a named R-005 'records no source server' finding:\n%s", stdout)
	}
	// The connected server still serves the doc at matching bytes — the
	// finding must come from the EMPTY server field, never a borrowed clean.
	if strings.Contains(stdout, "clean:") {
		t.Errorf("an empty prov.Server must never audit clean:\n%s", stdout)
	}
}

// TestScaffyPullCheckRejectsTarget: --check takes no positional.
func TestScaffyPullCheckRejectsTarget(t *testing.T) {
	withTempConfigHome(t)
	chdirTemp(t)
	code, _, stderr := runScaffyTest(t, globals{}, "", "pull", "--check", "note")
	if code != exitUsage {
		t.Fatalf("pull --check note exit = %d, want %d\nstderr:\n%s", code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, "takes no target") {
		t.Errorf("usage error should explain --check takes no target:\n%s", stderr)
	}
}

func TestScaffyPullAndLsHelp(t *testing.T) {
	for _, c := range []struct {
		verb string
		want []string
	}{
		{"pull", []string{"usage: bp scaffy pull <concept>[/<variant>]", "bp scaffy pull --check", "BYTE-IDENTICAL", "provenance", "R-004", "R-005", "exit codes:"}},
		{"ls", []string{"usage: bp scaffy ls --remote", "--remote", "exit codes:"}},
	} {
		code, stdout, _ := runScaffyTest(t, globals{help: true}, "", c.verb)
		if code != exitOK {
			t.Errorf("help(%s) exit = %d, want %d", c.verb, code, exitOK)
		}
		for _, w := range c.want {
			if !strings.Contains(stdout, w) {
				t.Errorf("help(%s) missing %q:\n%s", c.verb, w, stdout)
			}
		}
	}
}

// TestScaffyRunPulledMachineOutKeepsEnvelopeParity: under -o json the consent
// gate never interleaves prose with structured output — a refusal is ONE
// parseable {ok:false, error:{code:"consent_required"}, ...} envelope carrying
// the same CMD enumeration the human path prints, and --yes passes the gate
// silently so the run's own envelope is the only stdout (usageErrf's
// machine-parity convention).
func TestScaffyRunPulledMachineOutKeepsEnvelopeParity(t *testing.T) {
	t.Run("refusal is one envelope", func(t *testing.T) {
		seedPulledNoteTree(t)
		code, stdout, _ := runScaffyTest(t, globals{}, "json", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
		if code != exitUsage {
			t.Fatalf("exit = %d, want %d\n%s", code, exitUsage, stdout)
		}
		var env struct {
			Ok    bool `json:"ok"`
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
			WouldRun []string `json:"would_run_cmds"`
			Deferred []string `json:"deferred_cmds"`
		}
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not one JSON envelope: %v\n%s", err, stdout)
		}
		if env.Ok || env.Error.Code != "consent_required" {
			t.Errorf("envelope ok/code = %v/%q, want false/consent_required\n%s", env.Ok, env.Error.Code, stdout)
		}
		if len(env.WouldRun) != 1 || !strings.Contains(env.WouldRun[0], "echo pulled alpha") {
			t.Errorf("would_run_cmds must carry the substituted CMD: %v", env.WouldRun)
		}
		if len(env.Deferred) != 1 {
			t.Errorf("deferred_cmds = %v, want the one TIER ci CMD", env.Deferred)
		}
	})

	t.Run("yes passes silently", func(t *testing.T) {
		seedPulledNoteTree(t)
		code, stdout, stderr := runScaffyTest(t, globals{yes: true}, "json", "run", "pulled-note.scaffy", "--var", "NoteName=Alpha")
		if code != exitOK {
			t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, exitOK, stdout, stderr)
		}
		var env map[string]any
		if err := json.Unmarshal([]byte(stdout), &env); err != nil {
			t.Fatalf("stdout is not one JSON envelope: %v\n%s", err, stdout)
		}
		if env["ok"] != true {
			t.Errorf("run envelope not ok:\n%s", stdout)
		}
	})
}
