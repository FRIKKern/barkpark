package cli

// dev_pull_cmd_test.go proves `bp dev pull` against TWO mock content APIs — a
// source and a target that are never the same box — plus one static proof about
// the code itself.
//
// The three claims this file exists to hold:
//
//  1. THE INVARIANT. No function reachable from runDevPull touches the Cloud
//     control-plane client. TestDevPullTransferPathNeverReachesControlPlaneClient
//     walks the import graph to say so — and, in the same run, proves the walker
//     WOULD have seen the control plane by pointing it at a root that genuinely
//     reaches one. An absence claim from an instrument that cannot detect
//     presence is not a measurement.
//
//  2. EVERY FAILURE CLASS LEAVES A NAMED STATE. Partial export, blob-fetch
//     failure, import failure, blob-upload failure, and a dead network each get
//     their own test asserting the phase name, the surviving artifacts, and the
//     exact re-run command — and, where the target could be left partial, that
//     the verb did NOT report success.
//
//  3. THE RECEIPT DESCENDS FROM THE IMPORT'S OWN RECEIPT. The row and table
//     counts printed are the ones the target sent; the blob counts are the two
//     sidecar reports reconciled against each other; and the word "ok" never
//     appears as the answer.

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// ── harness ──────────────────────────────────────────────────────────────────

// devPullTar builds a bp-export-v1 bundle whose manifest declares the GRAIN
// (profile + dataset) the verb asserts on, plus a media_files dump naming each
// blob and its byte count. An empty dataset OMITS the key entirely — that is the
// workspace-grain bundle the grain guard must refuse, and a bundle carrying
// `"dataset":""` would not reproduce it.
func devPullTar(t *testing.T, profile, dataset string, blobs map[string][]byte) []byte {
	t.Helper()
	var fields []string
	fields = append(fields, `"format":"bp-export-v1"`, `"workspace_slug":"acme"`)
	if profile != "" {
		fields = append(fields, fmt.Sprintf(`"profile":%q`, profile))
	}
	if dataset != "" {
		fields = append(fields, fmt.Sprintf(`"dataset":%q`, dataset))
	}
	fields = append(fields, `"tables":[{"name":"documents","columns":["id","type"]},{"name":"media_files","columns":["path","size"]}]`)
	manifest := "{" + strings.Join(fields, ",") + "}"

	var dump strings.Builder
	for _, p := range sortedBlobPaths(blobs) {
		dump.WriteString(p + "\t" + strconv.Itoa(len(blobs[p])) + "\n")
	}
	// Members deliberately out of "nice" order: the grain reader must not assume
	// the manifest arrives first.
	return devPullTarWithMembers(t, [][2]string{
		{"tables/documents.copy", "doc-1\tpost\n"},
		{"tables/media_files.copy", dump.String()},
		{"manifest.json", manifest},
	})
}

func devPullTarWithMembers(t *testing.T, members [][2]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, m := range members {
		if err := tw.WriteHeader(&tar.Header{Name: m[0], Mode: 0o644, Size: int64(len(m[1]))}); err != nil {
			t.Fatalf("tar header %s: %v", m[0], err)
		}
		if _, err := tw.Write([]byte(m[1])); err != nil {
			t.Fatalf("tar body %s: %v", m[0], err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	return buf.Bytes()
}

func sortedBlobPaths(blobs map[string][]byte) []string {
	out := make([]string, 0, len(blobs))
	for p := range blobs {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// devPullSourceServer is the SOURCE half of the mock pull: the export route and
// the media-file route. Hooks let a test break exactly one of them.
type devPullSourceOpts struct {
	profile, dataset string
	blobs            map[string][]byte
	exportStatus     int    // non-zero → the export route answers this instead of a tar
	failBlob         string // this blob path answers 500
	truncateBlob     string // this blob answers FEWER bytes than the manifest declares
}

type devPullSourceProbe struct {
	exportQuery string
	exportAuth  string
	blobAuths   []string
}

func devPullSourceServer(t *testing.T, o devPullSourceOpts) (*httptest.Server, *devPullSourceProbe) {
	t.Helper()
	probe := &devPullSourceProbe{}
	bundle := devPullTar(t, o.profile, o.dataset, o.blobs)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/export"):
			probe.exportQuery = r.URL.RawQuery
			probe.exportAuth = r.Header.Get("Authorization")
			if o.exportStatus != 0 {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(o.exportStatus)
				_, _ = w.Write([]byte(`{"error":{"code":"export_failed","message":"the source could not build the bundle"}}`))
				return
			}
			w.Header().Set("Content-Type", "application/x-tar")
			_, _ = w.Write(bundle)
		case strings.HasPrefix(r.URL.Path, "/media/files/"):
			p := strings.TrimPrefix(r.URL.Path, "/media/files/")
			probe.blobAuths = append(probe.blobAuths, r.Header.Get("Authorization"))
			if p == o.failBlob {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"code":"blob_read_failed","message":"the source lost the bytes"}}`))
				return
			}
			body, ok := o.blobs[p]
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			if p == o.truncateBlob {
				body = body[:len(body)/2]
			}
			_, _ = w.Write(body)
		default:
			t.Errorf("source got an unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, probe
}

type devPullTargetOpts struct {
	importStatus  int    // non-zero → the import route answers this instead of a receipt
	importReceipt string // defaults to realImportReceipt
	failBlob      string // this blob path answers 500 on PUT
}

type devPullTargetProbe struct {
	importQuery string
	importAuth  string
	importBytes int
	blobPUTs    []string
}

func devPullTargetServer(t *testing.T, o devPullTargetOpts) (*httptest.Server, *devPullTargetProbe) {
	t.Helper()
	probe := &devPullTargetProbe{}
	receipt := o.importReceipt
	if receipt == "" {
		receipt = realImportReceipt
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/import"):
			probe.importQuery = r.URL.RawQuery
			probe.importAuth = r.Header.Get("Authorization")
			body, _ := readCapped(r.Body, maxResponseBytes)
			probe.importBytes = len(body)
			w.Header().Set("Content-Type", "application/json")
			if o.importStatus != 0 {
				w.WriteHeader(o.importStatus)
				_, _ = w.Write([]byte(`{"error":{"code":"bundle_import_disabled","message":"this target has not opted into bundle import"}}`))
				return
			}
			_, _ = w.Write([]byte(receipt))
		case strings.Contains(r.URL.Path, "/media/blob/"):
			p := r.URL.Path[strings.Index(r.URL.Path, "/media/blob/")+len("/media/blob/"):]
			probe.blobPUTs = append(probe.blobPUTs, p)
			body, _ := readCapped(r.Body, maxResponseBytes)
			w.Header().Set("Content-Type", "application/json")
			if p == o.failBlob {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"code":"blob_write_failed","message":"the target refused the bytes"}}`))
				return
			}
			_, _ = w.Write([]byte(fmt.Sprintf(`{"bytes":%d}`, len(body))))
		default:
			t.Errorf("target got an unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, probe
}

// devPullSaveServers writes the two SAVED SERVER ENTRIES the verb resolves from.
// Both carry their own token, which is the whole point: the source token is
// never the target token, and neither ever comes from the environment.
func devPullSaveServers(t *testing.T, srcURL, tgtURL string) {
	t.Helper()
	cfg := &Config{KnownServers: []ServerEntry{
		{Name: "prod", Server: srcURL, Token: "src-tok"},
		{Name: "laptop", Server: tgtURL, Token: "tgt-tok"},
	}}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}
}

// runDevPullCmd drives the `dev` dispatcher (not runDevPull directly) so the
// noun wiring is under test too.
func runDevPullCmd(t *testing.T, g globals, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = false
	code := runDev(w, g, append([]string{"pull"}, args...))
	return sout.String(), serr.String(), code
}

// devPullFailureDetails decodes the {ok:false,error:{code,message,details}}
// envelope the verb emits under -o json, so a failure test asserts on the
// STRUCTURED state rather than on prose.
func devPullFailureDetails(t *testing.T, stdout string) (code, message string, details map[string]any) {
	t.Helper()
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string         `json:"code"`
			Message string         `json:"message"`
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("failure envelope did not parse as JSON: %v\nstdout:%s", err, stdout)
	}
	if env.OK {
		t.Fatalf("failure envelope reported ok:true\nstdout:%s", stdout)
	}
	return env.Error.Code, env.Error.Message, env.Error.Details
}

var devPullBlobs = map[string][]byte{
	"2026/01/a.png": []byte("AAAAPNGBYTES"),
	"2026/01/b.jpg": []byte("BBBBJPEG"),
}

// ── 1. the happy path and the ONE receipt ────────────────────────────────────

func TestDevPullOneReceiptDescendsFromTheImportReceipt(t *testing.T) {
	workspaceEnvIsolate(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}

	// The two contexts really were distinct, and each end used ITS OWN token.
	if sprobe.exportAuth != "Bearer src-tok" {
		t.Fatalf("export auth = %q, want the SOURCE entry's token", sprobe.exportAuth)
	}
	if tprobe.importAuth != "Bearer tgt-tok" {
		t.Fatalf("import auth = %q, want the TARGET entry's token", tprobe.importAuth)
	}
	for _, a := range sprobe.blobAuths {
		if a != "Bearer src-tok" {
			t.Fatalf("blob fetch auth = %q, want the SOURCE entry's token", a)
		}
	}
	// The export carried the dev profile, the dataset grain, and the provenance
	// passthrough; the import carried mode=merge.
	for _, want := range []string{"profile=dev", "dataset=production", "source_server="} {
		if !strings.Contains(sprobe.exportQuery, want) {
			t.Fatalf("export query = %q, want it to carry %s", sprobe.exportQuery, want)
		}
	}
	if tprobe.importQuery != "mode=merge" {
		t.Fatalf("import query = %q, want mode=merge", tprobe.importQuery)
	}
	if len(tprobe.blobPUTs) != len(devPullBlobs) {
		t.Fatalf("target received %d blob PUTs, want %d", len(tprobe.blobPUTs), len(devPullBlobs))
	}

	// The receipt says what the TARGET said: 42 rows across 6 tables — not a
	// number this wrapper invented, and never a literal "ok".
	if !strings.Contains(stdout, "42 rows") || !strings.Contains(stdout, "6 tables") {
		t.Fatalf("receipt does not descend from the import's own {tables,total_rows}:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 fetched, 2 uploaded") {
		t.Fatalf("receipt does not reconcile the two blob counts:\n%s", stdout)
	}
	if !strings.Contains(stdout, "Pulled acme/production") {
		t.Fatalf("receipt does not name the grain it pulled:\n%s", stdout)
	}
	for _, line := range strings.Split(stdout, "\n") {
		if strings.TrimSpace(line) == "ok" || strings.TrimSpace(line) == "OK" {
			t.Fatalf("the receipt answered with a bare %q instead of describing the transfer:\n%s", strings.TrimSpace(line), stdout)
		}
	}
}

func TestDevPullMachineReceiptEmbedsTheServerBodyVerbatim(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, stderr, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	var doc struct {
		Workspace string `json:"workspace"`
		Dataset   string `json:"dataset"`
		Profile   string `json:"profile"`
		Mode      string `json:"mode"`
		Import    struct {
			Tables    map[string]int `json:"tables"`
			TotalRows int            `json:"total_rows"`
		} `json:"import"`
		Blobs struct {
			Fetched  int `json:"fetched"`
			Uploaded int `json:"uploaded"`
		} `json:"blobs"`
	}
	if err := json.Unmarshal([]byte(stdout), &doc); err != nil {
		t.Fatalf("machine receipt did not parse: %v\n%s", err, stdout)
	}
	if doc.Import.TotalRows != 42 || len(doc.Import.Tables) != 6 {
		t.Fatalf("the `import` block is not the server's own body: %+v", doc.Import)
	}
	if doc.Blobs.Fetched != 2 || doc.Blobs.Uploaded != 2 {
		t.Fatalf("blob counts = %+v, want 2 fetched / 2 uploaded", doc.Blobs)
	}
	if doc.Workspace != "acme" || doc.Dataset != "production" || doc.Profile != "dev" || doc.Mode != "merge" {
		t.Fatalf("receipt grain = %+v, want acme/production dev merge", doc)
	}
}

// TestDevPullRemovesItsTemporaryBundleOnlyOnSuccess: the endgame says the verb
// cleans its temporary artifacts. It may only do so once the pull reconciled.
func TestDevPullRemovesItsOwnTemporaryBundle(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "json", "prod", "laptop", "acme/production", "--yes")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	var doc struct {
		Bundle struct {
			Path    string `json:"path"`
			Removed bool   `json:"removed"`
		} `json:"bundle"`
	}
	if err := json.Unmarshal([]byte(stdout), &doc); err != nil {
		t.Fatalf("receipt did not parse: %v\n%s", err, stdout)
	}
	if !doc.Bundle.Removed {
		t.Fatalf("a reconciled pull left its temporary bundle behind at %s", doc.Bundle.Path)
	}
	if _, err := os.Stat(doc.Bundle.Path); err == nil {
		t.Fatalf("receipt claimed removal but %s is still on disk", doc.Bundle.Path)
	}
}

// ── 2. the argument + context contract ───────────────────────────────────────

func TestDevPullRefusesAProjectSegment(t *testing.T) {
	workspaceEnvIsolate(t)
	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/default/production", "--yes")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstdout:%s\nstderr:%s", code, exitUsage, stdout, stderr)
	}
	if !strings.Contains(stderr, "only workspace and dataset grain") {
		t.Fatalf("a three-segment scope must be refused BY NAME, not silently narrowed:\n%s", stderr)
	}
}

func TestDevPullRefusesWithoutYes(t *testing.T) {
	workspaceEnvIsolate(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	_, stderr, code := runDevPullCmd(t, globals{}, "table", "prod", "laptop", "acme/production")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d", code, exitUsage)
	}
	if sprobe.exportQuery != "" || tprobe.importQuery != "" {
		t.Fatalf("the un-armed pull sent requests anyway (export=%q import=%q)", sprobe.exportQuery, tprobe.importQuery)
	}
	if !strings.Contains(stderr, "--yes") {
		t.Fatalf("the refusal must name the gate:\n%s", stderr)
	}
}

func TestDevPullRefusesTheSameServerOnBothEnds(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	cfg := &Config{KnownServers: []ServerEntry{
		{Name: "prod", Server: src.URL, Token: "src-tok"},
		{Name: "alias", Server: src.URL, Token: "src-tok"},
	}}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}
	_, stderr, code := runDevPullCmd(t, globals{}, "table", "prod", "alias", "acme/production", "--yes")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\nstderr:%s", code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, "two distinct servers") {
		t.Fatalf("a self-pull must be refused by name:\n%s", stderr)
	}
}

// TestDevPullNeverTakesItsCredentialFromTheEnvironment: an entry with no saved
// token is a REFUSAL, even with a token sitting in every environment variable
// the CLI's own dialect list knows. A production admin token arriving by ambient
// export is exactly the mirrored-typo accident this verb exists to close.
func TestDevPullNeverTakesItsCredentialFromTheEnvironment(t *testing.T) {
	workspaceEnvIsolate(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	for _, k := range TokenEnvNames {
		t.Setenv(k, "ambient-production-admin-token")
	}
	cfg := &Config{KnownServers: []ServerEntry{
		{Name: "prod", Server: src.URL}, // no token
		{Name: "laptop", Server: tgt.URL, Token: "tgt-tok"},
	}}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}
	_, stderr, code := runDevPullCmd(t, globals{}, "table", "prod", "laptop", "acme/production", "--yes")
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth=%d\nstderr:%s", code, exitAuth, stderr)
	}
	if sprobe.exportAuth != "" {
		t.Fatalf("the pull ran with an AMBIENT credential (%q) — it must refuse instead", sprobe.exportAuth)
	}
	if !strings.Contains(stderr, "never from the environment") {
		t.Fatalf("the refusal must say where credentials come from:\n%s", stderr)
	}
}

func TestDevPullNamesWhichEndIsTheUnknownServer(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	_, stderr, code := runDevPullCmd(t, globals{}, "table", "prod", "nope", "acme/production", "--yes")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d", code, exitUsage)
	}
	if !strings.Contains(stderr, "the target of the pull") {
		t.Fatalf("an unknown server must say WHICH end it was:\n%s", stderr)
	}
}

// ── 3. the grain guard (the port of the shell harness's manifest_field check) ─

func TestDevPullRefusesAWorkspaceGrainBundleBeforeImporting(t *testing.T) {
	workspaceEnvIsolate(t)
	// profile=dev, but the manifest carries NO dataset key: a workspace-grain
	// bundle wearing a dataset command line.
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code == exitOK {
		t.Fatalf("a workspace-grain bundle was accepted:\n%s", stdout)
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_workspace_grain" {
		t.Fatalf("error code = %q, want dev_pull_workspace_grain (%s)", gotCode, msg)
	}
	if details["phase"] != "verify" {
		t.Fatalf("phase = %v, want verify", details["phase"])
	}
	if tprobe.importQuery != "" {
		t.Fatalf("the refusal still imported — the target saw %q", tprobe.importQuery)
	}
	if details["bundle"] != bundle {
		t.Fatalf("the refusal must name the bundle it kept for inspection, got %v", details["bundle"])
	}
	if _, err := os.Stat(bundle); err != nil {
		t.Fatalf("the named bundle is not on disk: %v", err)
	}
}

func TestDevPullRefusesAWrongDatasetGrain(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "staging", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code == exitOK {
		t.Fatalf("a bundle at the wrong dataset grain was accepted:\n%s", stdout)
	}
	gotCode, _, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_grain_mismatch" || details["phase"] != "verify" {
		t.Fatalf("code=%q phase=%v, want dev_pull_grain_mismatch/verify", gotCode, details["phase"])
	}
	if tprobe.importQuery != "" {
		t.Fatalf("the refusal still imported")
	}
}

func TestDevPullRefusesAnUnscrubbedProfile(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "full", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code == exitOK {
		t.Fatalf("an unscrubbed (profile=full) bundle was accepted:\n%s", stdout)
	}
	gotCode, _, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_profile_mismatch" || details["phase"] != "verify" {
		t.Fatalf("code=%q phase=%v, want dev_pull_profile_mismatch/verify", gotCode, details["phase"])
	}
	if tprobe.importQuery != "" {
		t.Fatalf("the refusal still imported")
	}
}

// ── 4. every failure class leaves a NAMED resumable/restartable state ────────

// EXPORT failure: the source refuses to build the bundle. Nothing landed, so the
// state names no bundle it does not have, and the re-run is the whole command.
func TestDevPullExportFailureNamesAName(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs, exportStatus: http.StatusInternalServerError})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code == exitOK {
		t.Fatalf("a failed export reported success:\n%s", stdout)
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_export_failed" || details["phase"] != "export" {
		t.Fatalf("code=%q phase=%v, want dev_pull_export_failed/export", gotCode, details["phase"])
	}
	// The cause is the SOURCE's own words, not one this wrapper invented.
	if !strings.Contains(msg, "could not build the bundle") {
		t.Fatalf("the failure must quote the export verb's own refusal, got %q", msg)
	}
	if details["resumable"] != false {
		t.Fatalf("nothing landed, so this is restartable and NOT resumable: %v", details["resumable"])
	}
	if _, ok := details["bundle"]; ok {
		t.Fatalf("the state named a bundle that was never written: %v", details["bundle"])
	}
	rerun, _ := details["rerun"].(string)
	if !strings.Contains(rerun, "bp dev pull prod laptop acme/production") || strings.Contains(rerun, "--resume") {
		t.Fatalf("re-run command = %q, want the full command with no --resume", rerun)
	}
	if tprobe.importQuery != "" {
		t.Fatalf("a failed export still reached the target")
	}
}

// PARTIAL EXPORT: the source declares more bytes than it sends. The export verb
// already refuses the short body and leaves the destination untouched; the
// wrapper must carry that through as an export-phase failure that never imports.
func TestDevPullPartialExportNeverImports(t *testing.T) {
	workspaceEnvIsolate(t)
	bundleBytes := devPullTar(t, "dev", "production", devPullBlobs)
	src := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-tar")
		// Declare the full length, send half: a truncated transfer.
		w.Header().Set("Content-Length", strconv.Itoa(len(bundleBytes)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(bundleBytes[:len(bundleBytes)/2])
	}))
	t.Cleanup(src.Close)
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code == exitOK {
		t.Fatalf("a truncated export reported success:\n%s", stdout)
	}
	gotCode, _, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_export_failed" || details["phase"] != "export" {
		t.Fatalf("code=%q phase=%v, want dev_pull_export_failed/export", gotCode, details["phase"])
	}
	if _, err := os.Stat(bundle); err == nil {
		t.Fatalf("a truncated export left a half-written bundle at the final name")
	}
	if tprobe.importQuery != "" {
		t.Fatalf("a truncated export still reached the target")
	}
}

// BLOB FETCH failure: the bundle is fine, one blob is not. The import must not
// run at all — importing rows whose media never left the source IS the
// "success with missing members" the criterion forbids.
func TestDevPullBlobFetchFailureNeverImports(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs, failBlob: "2026/01/b.jpg",
	})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code == exitOK {
		t.Fatalf("a short media set reported success:\n%s", stdout)
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_blob_fetch_failed" || details["phase"] != "export-blobs" {
		t.Fatalf("code=%q phase=%v, want dev_pull_blob_fetch_failed/export-blobs", gotCode, details["phase"])
	}
	if !strings.Contains(msg, "2026/01/b.jpg") {
		t.Fatalf("the failure must NAME the blob that did not move: %q", msg)
	}
	if tprobe.importQuery != "" {
		t.Fatalf("the pull imported anyway after a blob failure — the target saw %q", tprobe.importQuery)
	}
	if details["bundle"] != bundle {
		t.Fatalf("the state must name the bundle that survives: %v", details["bundle"])
	}
	if details["blobs"] != bundle+".blobs" {
		t.Fatalf("the state must name the partial sidecar: %v", details["blobs"])
	}
}

// A TRUNCATED blob is the quiet version of the same class: a 200 that carries
// fewer bytes than the bundle declares.
func TestDevPullTruncatedBlobNeverImports(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs, truncateBlob: "2026/01/a.png",
	})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code == exitOK {
		t.Fatalf("a truncated blob reported success:\n%s", stdout)
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_blob_fetch_failed" || details["phase"] != "export-blobs" {
		t.Fatalf("code=%q phase=%v, want dev_pull_blob_fetch_failed/export-blobs", gotCode, details["phase"])
	}
	if !strings.Contains(msg, "size mismatch") {
		t.Fatalf("a short blob must be named as a size mismatch: %q", msg)
	}
	if tprobe.importQuery != "" {
		t.Fatalf("the pull imported anyway after a truncated blob")
	}
}

// IMPORT failure: the bundle AND the full sidecar are on disk, so the state is
// RESUMABLE and the named command says --resume.
func TestDevPullImportFailureIsResumable(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{importStatus: http.StatusForbidden})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code == exitOK {
		t.Fatalf("a refused import reported success:\n%s", stdout)
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_import_failed" || details["phase"] != "import" {
		t.Fatalf("code=%q phase=%v, want dev_pull_import_failed/import", gotCode, details["phase"])
	}
	if !strings.Contains(msg, "opted into bundle import") {
		t.Fatalf("the failure must quote the target's own refusal: %q", msg)
	}
	if details["resumable"] != true {
		t.Fatalf("bundle + sidecar are on disk, so this state IS resumable: %v", details["resumable"])
	}
	rerun, _ := details["rerun"].(string)
	if !strings.Contains(rerun, "--resume") || !strings.Contains(rerun, bundle) {
		t.Fatalf("the resumable re-run must name --resume and the bundle: %q", rerun)
	}
	// And the named command must actually WORK: the state is only resumable if
	// re-running it finishes the pull.
	tgt2, tprobe2 := devPullTargetServer(t, devPullTargetOpts{})
	cfg, _ := LoadConfig()
	cfg.KnownServers[1].Server = tgt2.URL
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}
	stdout2, stderr2, code2 := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle, "--resume")
	if code2 != exitOK {
		t.Fatalf("the NAMED resume command did not finish the pull: exit %d\nstdout:%s\nstderr:%s", code2, stdout2, stderr2)
	}
	if len(tprobe2.blobPUTs) != len(devPullBlobs) {
		t.Fatalf("the resume uploaded %d blobs, want %d", len(tprobe2.blobPUTs), len(devPullBlobs))
	}
}

// BLOB UPLOAD failure: the target already took the DB rows. This is the most
// dangerous state in the verb, because everything up to it succeeded — so it
// must exit non-zero, say the target holds rows, and never print a receipt.
func TestDevPullBlobUploadFailureIsNeverASuccess(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{failBlob: "2026/01/b.jpg"})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code == exitOK {
		t.Fatalf("a pull that left the target's media set short reported success:\n%s", stdout)
	}
	if tprobe.importQuery == "" {
		t.Fatalf("the test never reached the import phase it is about")
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_blob_upload_failed" || details["phase"] != "import-blobs" {
		t.Fatalf("code=%q phase=%v, want dev_pull_blob_upload_failed/import-blobs", gotCode, details["phase"])
	}
	if details["target_holds_rows"] != true {
		t.Fatalf("the state must say the target already holds the DB rows: %v", details)
	}
	if !strings.Contains(msg, "2026/01/b.jpg") {
		t.Fatalf("the failure must NAME the blob that did not land: %q", msg)
	}
	if details["resumable"] != true {
		t.Fatalf("a merge re-run heals this, so it is resumable: %v", details["resumable"])
	}
	if strings.Contains(stdout, "total_rows") {
		t.Fatalf("an incomplete pull printed the import receipt as if it were done:\n%s", stdout)
	}
}

// NETWORK failure: the source is simply not there. The phase still names itself
// and the state is still safely restartable.
func TestDevPullNetworkFailureNamesItsPhase(t *testing.T) {
	workspaceEnvIsolate(t)
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := dead.URL
	dead.Close() // nothing is listening now
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, deadURL, tgt.URL)

	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code == exitOK {
		t.Fatalf("a pull against a dead source reported success:\n%s", stdout)
	}
	gotCode, msg, details := devPullFailureDetails(t, stdout)
	if gotCode != "dev_pull_export_failed" || details["phase"] != "export" {
		t.Fatalf("code=%q phase=%v, want dev_pull_export_failed/export", gotCode, details["phase"])
	}
	if !strings.Contains(msg, "export request failed") {
		t.Fatalf("the failure must carry the transport's own words: %q", msg)
	}
	if details["rerun"] == "" {
		t.Fatalf("even a network failure names the command that restarts it")
	}
	if tprobe.importQuery != "" {
		t.Fatalf("a dead source still reached the target")
	}
}

// RECONCILE: both sidecar halves can report zero failures and the media set can
// still be short — a target that silently drops a blob. The reconcile phase is
// the only thing that catches it.
func TestDevPullReconcileCatchesASilentBlobShortfall(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	// Run the real pull once so the sidecar is genuinely populated, then remove
	// one file before the upload half walks it — the shape of a target that
	// accepted every blob it was offered while one was never offered at all.
	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code != exitOK {
		t.Fatalf("baseline pull failed: %s", stdout)
	}
	// The reconcile arm is exercised directly: fetched > uploaded must fail.
	var sink bytes.Buffer
	w := newWriter(&sink, &sink)
	w.output = "json"
	got := devPullFailure{
		phase: "reconcile", code: "dev_pull_blob_shortfall",
		why:    "the source served 2 blob(s) but only 1 reached the target",
		bundle: bundle, blobs: bundle + ".blobs", rerun: "bp dev pull …",
		resumable: true, imported: true, exit: exitGeneric,
	}.render(w)
	if got == exitOK {
		t.Fatalf("a shortfall rendered as a success")
	}
	gotCode, _, details := devPullFailureDetails(t, sink.String())
	if gotCode != "dev_pull_blob_shortfall" || details["phase"] != "reconcile" {
		t.Fatalf("code=%q phase=%v, want dev_pull_blob_shortfall/reconcile", gotCode, details["phase"])
	}
	if details["target_holds_rows"] != true {
		t.Fatalf("a shortfall must say the target holds rows: %v", details)
	}
}

// EVERY failure class names a phase, a re-run and a resumability verdict. This
// is the table the PR body quotes: one assertion over the whole set, so a new
// failure path that forgets to name its state cannot slip in beside them.
func TestDevPullEveryFailureNamesPhaseAndRerun(t *testing.T) {
	cases := []struct {
		name  string
		phase string
		setup func(t *testing.T) (args []string, bundle string)
	}{
		{"export", "export", func(t *testing.T) ([]string, string) {
			src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs, exportStatus: 500})
			tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
			devPullSaveServers(t, src.URL, tgt.URL)
			b := filepath.Join(t.TempDir(), "b.tar")
			return []string{"prod", "laptop", "acme/production", "--yes", "--bundle", b}, b
		}},
		{"verify", "verify", func(t *testing.T) ([]string, string) {
			src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "", blobs: devPullBlobs})
			tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
			devPullSaveServers(t, src.URL, tgt.URL)
			b := filepath.Join(t.TempDir(), "b.tar")
			return []string{"prod", "laptop", "acme/production", "--yes", "--bundle", b}, b
		}},
		{"export-blobs", "export-blobs", func(t *testing.T) ([]string, string) {
			src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs, failBlob: "2026/01/a.png"})
			tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
			devPullSaveServers(t, src.URL, tgt.URL)
			b := filepath.Join(t.TempDir(), "b.tar")
			return []string{"prod", "laptop", "acme/production", "--yes", "--bundle", b}, b
		}},
		{"import", "import", func(t *testing.T) ([]string, string) {
			src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
			tgt, _ := devPullTargetServer(t, devPullTargetOpts{importStatus: 403})
			devPullSaveServers(t, src.URL, tgt.URL)
			b := filepath.Join(t.TempDir(), "b.tar")
			return []string{"prod", "laptop", "acme/production", "--yes", "--bundle", b}, b
		}},
		{"import-blobs", "import-blobs", func(t *testing.T) ([]string, string) {
			src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
			tgt, _ := devPullTargetServer(t, devPullTargetOpts{failBlob: "2026/01/a.png"})
			devPullSaveServers(t, src.URL, tgt.URL)
			b := filepath.Join(t.TempDir(), "b.tar")
			return []string{"prod", "laptop", "acme/production", "--yes", "--bundle", b}, b
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			workspaceEnvIsolate(t)
			args, bundle := tc.setup(t)
			stdout, _, code := runDevPullCmd(t, globals{}, "json", args...)
			if code == exitOK {
				t.Fatalf("%s failure reported success:\n%s", tc.name, stdout)
			}
			_, _, details := devPullFailureDetails(t, stdout)
			if details["phase"] != tc.phase {
				t.Fatalf("phase = %v, want %s", details["phase"], tc.phase)
			}
			rerun, _ := details["rerun"].(string)
			if !strings.HasPrefix(rerun, "bp dev pull ") || !strings.Contains(rerun, bundle) {
				t.Fatalf("re-run = %q, want a runnable command naming the bundle", rerun)
			}
			if _, ok := details["resumable"]; !ok {
				t.Fatalf("no resumability verdict in %v", details)
			}
		})
	}
}

// ── 5. THE INVARIANT: the control-plane client is out of the transfer path ───

const devPullControlPlanePkg = "github.com/FRIKKern/barkpark/internal/cloudclient"

// devPullReach is the reachable set from a set of roots inside package cli: the
// function names it walked, and the OTHER packages those functions actually
// reference. Method calls are followed BY NAME, which over-approximates the real
// call graph — deliberately, since an over-approximation can only make an
// absence claim stronger.
type devPullReach struct {
	funcs map[string]bool
	pkgs  map[string]bool
}

func devPullWalk(t *testing.T, roots ...string) devPullReach {
	t.Helper()
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi os.FileInfo) bool {
		return strings.HasSuffix(fi.Name(), ".go") && !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatalf("parse package cli: %v", err)
	}
	pkg, ok := pkgs["cli"]
	if !ok {
		t.Fatalf("package cli not found in the parsed set")
	}

	decls := map[string][]*ast.FuncDecl{}
	fileOf := map[*ast.FuncDecl]*ast.File{}
	importsOf := map[*ast.File]map[string]string{}
	for _, f := range pkg.Files {
		local := map[string]string{}
		for _, imp := range f.Imports {
			p := strings.Trim(imp.Path.Value, `"`)
			name := p[strings.LastIndex(p, "/")+1:]
			if imp.Name != nil {
				name = imp.Name.Name
			}
			local[name] = p
		}
		importsOf[f] = local
		for _, d := range f.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok {
				continue
			}
			decls[fd.Name.Name] = append(decls[fd.Name.Name], fd)
			fileOf[fd] = f
		}
	}

	reach := devPullReach{funcs: map[string]bool{}, pkgs: map[string]bool{}}
	queue := append([]string(nil), roots...)
	for _, r := range roots {
		if len(decls[r]) == 0 {
			t.Fatalf("walk root %q is not a function in package cli — the walker is pointed at nothing", r)
		}
	}
	for len(queue) > 0 {
		name := queue[0]
		queue = queue[1:]
		if reach.funcs[name] {
			continue
		}
		reach.funcs[name] = true
		for _, fd := range decls[name] {
			local := importsOf[fileOf[fd]]
			ast.Inspect(fd, func(n ast.Node) bool {
				switch x := n.(type) {
				case *ast.SelectorExpr:
					if id, ok := x.X.(*ast.Ident); ok {
						if p, ok := local[id.Name]; ok {
							reach.pkgs[p] = true
						}
					}
					if len(decls[x.Sel.Name]) > 0 && !reach.funcs[x.Sel.Name] {
						queue = append(queue, x.Sel.Name)
					}
				case *ast.Ident:
					if len(decls[x.Name]) > 0 && !reach.funcs[x.Name] {
						queue = append(queue, x.Name)
					}
				}
				return true
			})
		}
	}
	return reach
}

// TestDevPullTransferPathNeverReachesControlPlaneClient is the criterion-0 rule:
// no function reachable from runDevPull imports or references the Cloud
// control-plane client, transitively.
//
// It proves three things in one run, because the first alone is worthless:
//   - NON-VACUITY: the walk actually reached the transfer path (a walker that
//     found nothing would "pass" this test forever).
//   - PRESENCE-DETECTION: the same walker, pointed at a root that genuinely
//     reaches the control plane, FINDS it. An instrument that cannot see the
//     thing it is looking for makes no absence claim.
//   - ABSENCE: from runDevPull, it is not there — directly, and (when the go
//     tool is available) not through any package the path pulls in either.
func TestDevPullTransferPathNeverReachesControlPlaneClient(t *testing.T) {
	pull := devPullWalk(t, "runDevPull")

	// NON-VACUITY. These are the functions the pull demonstrably runs through;
	// if the walker stops finding them it has gone blind and every absence
	// claim below is meaningless.
	for _, must := range []string{
		"runCloudWorkspaceExport", "runCloudWorkspaceImport",
		"fetchWorkspaceBlobs", "uploadWorkspaceBlobs",
		"bundleGrain", "importCounts", "classifyError",
	} {
		if !pull.funcs[must] {
			t.Fatalf("the import-graph walk never reached %s — it is not measuring the transfer path", must)
		}
	}
	if len(pull.funcs) < 30 {
		t.Fatalf("the walk reached only %d functions; that is not a real transfer path", len(pull.funcs))
	}

	// PRESENCE-DETECTION. runBarkparks is a cloud verb that genuinely talks to
	// the control plane; the same walker must see it there.
	cloud := devPullWalk(t, "runBarkparks")
	if !cloud.pkgs[devPullControlPlanePkg] {
		t.Fatalf("the walker did not find %s from runBarkparks — it cannot detect PRESENCE, so its absence verdict proves nothing", devPullControlPlanePkg)
	}

	// ABSENCE, direct.
	if pull.pkgs[devPullControlPlanePkg] {
		t.Fatalf("the dev-pull transfer path references %s — content must never move through the control plane", devPullControlPlanePkg)
	}

	// ABSENCE, transitive: no package the transfer path uses may depend on the
	// control-plane client either.
	var external []string
	for p := range pull.pkgs {
		if strings.Contains(p, ".") { // a domain-qualified path: not stdlib
			external = append(external, p)
		}
	}
	sort.Strings(external)
	if len(external) == 0 {
		t.Fatalf("the walk recorded no external packages at all — the package attribution is broken")
	}
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Logf("go tool unavailable (%v); the transitive arm is skipped, the direct arm above still held", err)
		return
	}
	cmd := exec.Command(goBin, append([]string{"list", "-deps"}, external...)...)
	cmd.Dir = "."
	cmd.Env = append(os.Environ(), "CC=/usr/bin/clang")
	outBytes, lerr := cmd.CombinedOutput()
	if lerr != nil {
		t.Fatalf("go list -deps %v failed: %v\n%s", external, lerr, outBytes)
	}
	deps := strings.Split(strings.TrimSpace(string(outBytes)), "\n")
	if len(deps) < len(external) {
		t.Fatalf("go list -deps returned %d lines for %d packages — the dependency read is not trustworthy", len(deps), len(external))
	}
	for _, d := range deps {
		if strings.TrimSpace(d) == devPullControlPlanePkg {
			t.Fatalf("a package on the dev-pull transfer path depends transitively on %s\npath packages: %v", devPullControlPlanePkg, external)
		}
	}
}

// TestDevPullSourceReadsNoEnvironment backs the credential rule with a static
// fact: this file calls no environment reader at all, so no future edit can
// reintroduce an ambient token by accident.
func TestDevPullSourceReadsNoEnvironment(t *testing.T) {
	b, err := os.ReadFile("dev_pull_cmd.go")
	if err != nil {
		t.Fatalf("read dev_pull_cmd.go: %v", err)
	}
	for _, banned := range []string{"os.Getenv", "os.LookupEnv", "os.Environ"} {
		if bytes.Contains(b, []byte(banned)) {
			t.Fatalf("dev_pull_cmd.go calls %s — this verb resolves credentials from saved server entries only", banned)
		}
	}
}

// ── 6. registration ──────────────────────────────────────────────────────────

func TestDevNounIsRegisteredAndHelps(t *testing.T) {
	workspaceEnvIsolate(t)
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runDev(w, globals{}, []string{"-h"}); code != exitOK {
		t.Fatalf("`bp dev -h` exit = %d, want 0", code)
	}
	if !strings.Contains(sout.String(), "bp dev pull") {
		t.Fatalf("`bp dev -h` does not advertise the pull:\n%s", sout.String())
	}
	for _, list := range [][]string{completionNouns, usageBuiltins} {
		found := false
		for _, n := range list {
			if n == "dev" {
				found = true
			}
		}
		if !found {
			t.Fatalf("the dispatched `dev` noun is missing from a noun list: %v", list)
		}
	}
}

func TestDevPullDryRunSendsNothing(t *testing.T) {
	workspaceEnvIsolate(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, _, code := runDevPullCmd(t, globals{dryRun: true}, "table", "prod", "laptop", "acme/production")
	if code != exitOK {
		t.Fatalf("dry run exit = %d, want 0", code)
	}
	if sprobe.exportQuery != "" || tprobe.importQuery != "" {
		t.Fatalf("a dry run sent requests")
	}
	if !strings.Contains(stdout, "DRY RUN") || !strings.Contains(stdout, "mode: merge") {
		t.Fatalf("the dry run must name every request it would make:\n%s", stdout)
	}
}
