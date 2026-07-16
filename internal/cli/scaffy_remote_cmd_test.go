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
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

func TestScaffyPullAndLsHelp(t *testing.T) {
	for _, c := range []struct {
		verb string
		want []string
	}{
		{"pull", []string{"usage: bp scaffy pull <concept>[/<variant>]", "BYTE-IDENTICAL", "provenance", "exit codes:", "5  fetched source failed validation"}},
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
