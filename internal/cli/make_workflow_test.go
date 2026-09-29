package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// THE POINT OF THIS FILE. `bp make workflow` emits TEMPLATE CONTENT — a GitHub
// Actions workflow for the USER'S repository, never this repo's CI — and a test
// that only asserted "the string contains /deploy" would pass on a template that
// cannot run. So the steps are EXTRACTED and EXECUTED with bash against a fake
// control plane, and the fake asserts the wire contract: the mint body, the
// octet-stream upload with a real Content-Length and an X-Artifact-Sha256 that
// matches the bytes, and the poll to a terminal status.
//
// The steps are enrolled BY PREDICATE (every step whose name carries
// workflowStepPrefix) with a floor, not from a hand-kept list — the lane learned
// on #18810 that a listed fixture silently omits whatever is added next.

// wfStep is one extracted step.
type wfStep struct {
	Name   string
	Script string
}

// extractBarkparkSteps pulls the `run:` block out of every step whose name
// starts with workflowStepPrefix. It is deliberately indentation-literal: the
// emitter writes steps at a fixed indent, so a change to that shape should break
// this reader loudly rather than silently enrol zero steps.
func extractBarkparkSteps(t *testing.T, yaml string) []wfStep {
	t.Helper()
	const (
		nameIndent   = "      - name: "
		runMarker    = "        run: |"
		scriptIndent = "          "
	)
	var steps []wfStep
	lines := strings.Split(yaml, "\n")
	for i := 0; i < len(lines); i++ {
		if !strings.HasPrefix(lines[i], nameIndent) {
			continue
		}
		raw := strings.TrimPrefix(lines[i], nameIndent)
		// A step name containing ": " MUST be quoted or the YAML is a mapping.
		if strings.Contains(raw, ": ") && !strings.HasPrefix(raw, `"`) {
			t.Fatalf("step name is unquoted but contains a colon — GitHub will refuse to load this workflow:\n  %s", lines[i])
		}
		name := raw
		if unq, err := strconvUnquote(raw); err == nil {
			name = unq
		}
		if !strings.HasPrefix(name, workflowStepPrefix) {
			continue
		}
		if i+1 >= len(lines) || lines[i+1] != runMarker {
			t.Fatalf("step %q is not followed by a literal `run: |` block (got %q)", name, lines[min(i+1, len(lines)-1)])
		}
		var script []string
		j := i + 2
		for ; j < len(lines); j++ {
			l := lines[j]
			if l == "" {
				script = append(script, "")
				continue
			}
			if !strings.HasPrefix(l, scriptIndent) {
				break
			}
			script = append(script, strings.TrimPrefix(l, scriptIndent))
		}
		steps = append(steps, wfStep{Name: name, Script: strings.Join(script, "\n")})
		i = j - 1
	}
	return steps
}

func strconvUnquote(s string) (string, error) {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		var out string
		if err := json.Unmarshal([]byte(s), &out); err != nil {
			return "", err
		}
		return out, nil
	}
	return "", fmt.Errorf("not quoted")
}

// prebuiltWorkflowCP is the prebuilt lane as the workflow must find it. Every
// handler ASSERTS rather than accommodates: a workflow that gets the route, the
// method, the body or the digest header wrong fails here, not in production.
type prebuiltWorkflowCP struct {
	mu sync.Mutex

	site        string
	buildID     string
	deployRoute string
	polls       int
	// recorded
	mintBody     string
	mintAuth     string
	uploadCT     string
	uploadSHA    string
	uploadLen    int64
	uploadDigest string
	uploadRoute  string
	pollRoute    string
	failUpload   bool
}

func (f *prebuiltWorkflowCP) handler(t *testing.T) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		path := r.URL.Path
		switch {
		case r.Method == "POST" && path == "/v1/sites/"+f.site+"/deploy":
			body, _ := io.ReadAll(r.Body)
			f.mintBody = string(body)
			f.mintAuth = r.Header.Get("Authorization")
			f.deployRoute = path
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(201)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"deployment": map[string]any{
					"id":          "dep-123",
					"build_id":    f.buildID,
					"content_rev": "rev-9",
					"source":      "prebuilt",
					"status":      "queued",
				},
			})
		case r.Method == "POST" && strings.HasSuffix(path, "/artifact"):
			f.uploadRoute = path
			f.uploadCT = r.Header.Get("Content-Type")
			f.uploadSHA = r.Header.Get("X-Artifact-Sha256")
			f.uploadLen = r.ContentLength
			raw, _ := io.ReadAll(r.Body)
			sum := sha256.Sum256(raw)
			f.uploadDigest = hex.EncodeToString(sum[:])
			stored := f.uploadDigest
			if f.failUpload {
				stored = strings.Repeat("0", 64)
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(201)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"bytes": len(raw), "artifact_sha256": stored,
			})
		case r.Method == "GET" && strings.Contains(path, "/deployments/"):
			f.pollRoute = path
			f.polls++
			status := "building"
			if f.polls >= 2 {
				status = "live"
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"deployment": map[string]any{
					"id": "dep-123", "status": status,
					"url": "https://box.example/sites/" + f.site + "/",
				},
			})
		default:
			t.Errorf("the workflow called an UNKNOWN route: %s %s", r.Method, path)
			w.WriteHeader(404)
		}
	})
	return mux
}

// runWorkflow executes every Barkpark step in order with bash, threading
// GITHUB_ENV between them exactly as the runner does.
func runWorkflow(t *testing.T, steps []wfStep, dir string, env map[string]string) (string, error) {
	t.Helper()
	githubEnv := filepath.Join(dir, "github_env")
	if err := os.WriteFile(githubEnv, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	var log strings.Builder
	for _, s := range steps {
		script := filepath.Join(dir, "step.sh")
		if err := os.WriteFile(script, []byte(s.Script), 0o755); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("bash", script)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GITHUB_ENV="+githubEnv, "RUNNER_TEMP="+dir)
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		// Everything a previous step exported through GITHUB_ENV.
		carried, _ := os.ReadFile(githubEnv)
		for _, line := range strings.Split(string(carried), "\n") {
			if strings.Contains(line, "=") {
				cmd.Env = append(cmd.Env, line)
			}
		}
		out, err := cmd.CombinedOutput()
		fmt.Fprintf(&log, "--- %s\n%s\n", s.Name, out)
		if err != nil {
			return log.String(), fmt.Errorf("step %q failed: %v", s.Name, err)
		}
	}
	return log.String(), nil
}

// writeFakeProject lays down a build command that stamps the marker HEALTH will
// assert, so the emitted build step's verification has something real to check.
func writeFakeProject(t *testing.T, dir, marker string) {
	t.Helper()
	build := filepath.Join(dir, "build.sh")
	body := `#!/bin/sh
set -eu
mkdir -p "$BARKPARK_DIST"
cat > "$BARKPARK_DIST/index.html" <<HTML
<!doctype html><html><head>
<meta name="bp-build-id" content="` + marker + `">
<meta name="bp-site-base" content="$BARKPARK_SITE_BASE">
</head><body>hi</body></html>
HTML
printf 'body{}' > "$BARKPARK_DIST/app.css"
`
	if err := os.WriteFile(build, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func requireTool(t *testing.T, names ...string) {
	t.Helper()
	for _, n := range names {
		if _, err := exec.LookPath(n); err != nil {
			t.Skipf("%s is not on PATH — the emitted workflow needs it", n)
		}
	}
}

// TestWorkflowTemplateActuallyDeploys is the RED arm: it runs the emitted steps
// end to end against a fake control plane and asserts the wire contract they
// must satisfy. Break any of mint body / route / octet-stream / digest header /
// Content-Length / poll and this fails.
func TestWorkflowTemplateActuallyDeploys(t *testing.T) {
	requireTool(t, "bash", "curl", "jq", "tar")

	fake := &prebuiltWorkflowCP{site: "my-site", buildID: "bld-abc123"}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()

	yaml := renderDeployWorkflow(workflowOptions{Site: "my-site"})
	steps := extractBarkparkSteps(t, yaml)
	// FLOOR. An extractor that silently enrols nothing would make every
	// assertion below vacuously true.
	if len(steps) < 4 {
		t.Fatalf("enrolled %d Barkpark steps, want at least 4 (mint/build/upload/follow) — the extractor found nothing to exercise", len(steps))
	}

	dir := t.TempDir()
	writeFakeProject(t, dir, fake.buildID)
	log, err := runWorkflow(t, steps, dir, map[string]string{
		"BARKPARK_SITE":        "my-site",
		"BARKPARK_API":         srv.URL,
		"BARKPARK_DIST":        "dist",
		"BARKPARK_BUILD_CMD":   "./build.sh",
		"BARKPARK_CLOUD_TOKEN": "pat-secret",
	})
	if err != nil {
		t.Fatalf("the emitted workflow does not run: %v\n%s", err, log)
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.mintBody != `{"source":"prebuilt"}` {
		t.Errorf("mint body = %q, want {\"source\":\"prebuilt\"} — the control plane starts a BOX BUILD for anything else", fake.mintBody)
	}
	if fake.mintAuth != "Bearer pat-secret" {
		t.Errorf("mint Authorization = %q, want the PAT as a Bearer", fake.mintAuth)
	}
	if fake.deployRoute != "/v1/sites/my-site/deploy" {
		t.Errorf("mint route = %q", fake.deployRoute)
	}
	if fake.uploadRoute != "/v1/sites/my-site/deployments/dep-123/artifact" {
		t.Errorf("upload route = %q — it must be DEPLOYMENT-scoped and carry the id the mint returned", fake.uploadRoute)
	}
	if fake.uploadCT != "application/octet-stream" {
		t.Errorf("upload Content-Type = %q, want application/octet-stream", fake.uploadCT)
	}
	if fake.uploadSHA == "" || fake.uploadSHA != fake.uploadDigest {
		t.Errorf("X-Artifact-Sha256 = %q but the body hashes to %q — the box re-verifies the digest before it stages anything", fake.uploadSHA, fake.uploadDigest)
	}
	if fake.uploadLen <= 0 {
		t.Errorf("upload Content-Length = %d — a chunked body cannot be rejected on the headers; the prebuilt lane declares its length", fake.uploadLen)
	}
	if fake.polls < 2 {
		t.Errorf("the follow step polled %d time(s) — it must poll until a terminal status, not read once", fake.polls)
	}
	if !strings.Contains(log, "live at https://box.example/sites/my-site/") {
		t.Errorf("the follow step did not report the live url:\n%s", log)
	}
}

// TestWorkflowRefusesAMismatchedBuildMarker is the QUIET-arm's twin: the build
// step must REFUSE bytes that do not carry the minted build id, because HEALTH
// asserts that marker by value and the upload would burn a nonced deployment.
func TestWorkflowRefusesAMismatchedBuildMarker(t *testing.T) {
	requireTool(t, "bash", "curl", "jq", "tar")

	fake := &prebuiltWorkflowCP{site: "my-site", buildID: "bld-abc123"}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()

	steps := extractBarkparkSteps(t, renderDeployWorkflow(workflowOptions{Site: "my-site"}))
	dir := t.TempDir()
	// The build stamps a DIFFERENT id than the mint returns.
	writeFakeProject(t, dir, "bld-somethingelse")
	log, err := runWorkflow(t, steps, dir, map[string]string{
		"BARKPARK_SITE":        "my-site",
		"BARKPARK_API":         srv.URL,
		"BARKPARK_DIST":        "dist",
		"BARKPARK_BUILD_CMD":   "./build.sh",
		"BARKPARK_CLOUD_TOKEN": "pat-secret",
	})
	if err == nil {
		t.Fatalf("a build stamped with the WRONG build id was uploaded instead of refused:\n%s", log)
	}
	if !strings.Contains(log, "bld-somethingelse") || !strings.Contains(log, "bld-abc123") {
		t.Errorf("the refusal does not name both the marker it found and the one it needed:\n%s", log)
	}
	if fake.uploadRoute != "" {
		t.Errorf("bytes were uploaded (%s) after the marker check failed", fake.uploadRoute)
	}
}

// TestWorkflowRefusesADigestDivergence proves the last guard: if the control
// plane stores a digest that differs from the bytes we packed, the job fails
// rather than reporting a deploy of bytes nobody verified.
func TestWorkflowRefusesADigestDivergence(t *testing.T) {
	requireTool(t, "bash", "curl", "jq", "tar")

	fake := &prebuiltWorkflowCP{site: "my-site", buildID: "bld-abc123", failUpload: true}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()

	steps := extractBarkparkSteps(t, renderDeployWorkflow(workflowOptions{Site: "my-site"}))
	dir := t.TempDir()
	writeFakeProject(t, dir, fake.buildID)
	log, err := runWorkflow(t, steps, dir, map[string]string{
		"BARKPARK_SITE":        "my-site",
		"BARKPARK_API":         srv.URL,
		"BARKPARK_DIST":        "dist",
		"BARKPARK_BUILD_CMD":   "./build.sh",
		"BARKPARK_CLOUD_TOKEN": "pat-secret",
	})
	if err == nil {
		t.Fatalf("a stored-digest divergence was not caught:\n%s", log)
	}
	if !strings.Contains(log, "stored sha256") {
		t.Errorf("the failure does not say the digests disagree:\n%s", log)
	}
}

// TestWorkflowArchiveRootIsTheDistDirectory is the QUIET arm on the packer: the
// archive root must be dist's CONTENTS (index.html at the root, no dist/
// prefix), and the dotenv family must not travel. It asserts what the upload
// bytes ARE rather than that an upload happened.
func TestWorkflowArchiveRootIsTheDistDirectory(t *testing.T) {
	requireTool(t, "bash", "curl", "jq", "tar")

	var body []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/artifact") {
			body, _ = io.ReadAll(r.Body)
			sum := sha256.Sum256(body)
			w.WriteHeader(201)
			_ = json.NewEncoder(w).Encode(map[string]any{"artifact_sha256": hex.EncodeToString(sum[:])})
			return
		}
		if r.Method == "POST" {
			w.WriteHeader(201)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"deployment": map[string]any{"id": "dep-1", "build_id": "bld-1"}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"deployment": map[string]any{"status": "live", "url": "u"}})
	}))
	defer srv.Close()

	steps := extractBarkparkSteps(t, renderDeployWorkflow(workflowOptions{Site: "my-site"}))
	dir := t.TempDir()
	writeFakeProject(t, dir, "bld-1")
	if err := os.MkdirAll(filepath.Join(dir, "dist"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dist", ".env"), []byte("SECRET=1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if log, err := runWorkflow(t, steps, dir, map[string]string{
		"BARKPARK_SITE": "my-site", "BARKPARK_API": srv.URL, "BARKPARK_DIST": "dist",
		"BARKPARK_BUILD_CMD": "./build.sh", "BARKPARK_CLOUD_TOKEN": "t",
	}); err != nil {
		t.Fatalf("workflow failed: %v\n%s", err, log)
	}

	art := filepath.Join(t.TempDir(), "a.tar.gz")
	if err := os.WriteFile(art, body, 0o644); err != nil {
		t.Fatal(err)
	}
	listing, err := exec.Command("tar", "-tzf", art).Output()
	if err != nil {
		t.Fatalf("the uploaded bytes are not a readable tar.gz: %v", err)
	}
	names := string(listing)
	if !strings.Contains(names, "index.html") {
		t.Errorf("index.html is not in the archive:\n%s", names)
	}
	if strings.Contains(names, "dist/") {
		t.Errorf("the archive carries a dist/ prefix — the box extracts straight into the release dir, so every path would be off by one:\n%s", names)
	}
	if strings.Contains(names, ".env") {
		t.Errorf("a .env travelled in the artifact — a secret a framework wrote beside the assets must never leave the runner:\n%s", names)
	}
}

// TestWorkflowTemplateIsNotDuplicated is the mechanical half of criterion 3: the
// template has exactly ONE owner (this emitter), and no copy lives in either of
// the two near-identical starter trees. It WALKS both trees for any workflow
// file rather than checking two known paths, so a copy added under a new starter
// is caught too.
func TestWorkflowTemplateIsNotDuplicated(t *testing.T) {
	trees := []string{
		"../../cloud/priv/templates",
		"../../js/packages/create-barkpark-app/templates",
	}
	seen := 0
	for _, tree := range trees {
		info, err := os.Stat(tree)
		if err != nil || !info.IsDir() {
			t.Fatalf("%s is not a directory — this guard names the two starter trees by path, and one of them moved: re-point it or the single-source rule is unenforced", tree)
		}
		seen++
		err = filepath.Walk(tree, func(path string, fi os.FileInfo, err error) error {
			if err != nil || fi.IsDir() {
				return err
			}
			if !strings.Contains(filepath.ToSlash(path), "/.github/workflows/") {
				return nil
			}
			raw, rerr := os.ReadFile(path)
			if rerr != nil {
				return rerr
			}
			if strings.Contains(string(raw), "source\":\"prebuilt") ||
				strings.Contains(string(raw), "BARKPARK_CLOUD_TOKEN") {
				t.Errorf("a prebuilt deploy workflow is duplicated at %s — the template has ONE owner, `bp make workflow` (internal/cli/make_workflow.go); a second copy is how the two starter trees diverge", path)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walk %s: %v", tree, err)
		}
	}
	if seen != 2 {
		t.Fatalf("walked %d starter trees, want 2 — a guard that walked nothing proves nothing", seen)
	}
}

// TestWorkflowPatValidityMatchesTheControlPlane keeps the number in the emitted
// warning honest. The template tells the user their PAT expires in N days; if
// the control plane's default moves and this does not, the template lies.
func TestWorkflowPatValidityMatchesTheControlPlane(t *testing.T) {
	const src = "../../cloud/lib/barkpark_cloud/accounts/user_token.ex"
	raw, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v — this guard cannot be silently skipped, the emitted warning quotes this number", src, err)
	}
	want := fmt.Sprintf("@pat_default_validity_days %d", patDefaultValidityDays)
	if !strings.Contains(string(raw), want) {
		t.Fatalf("the control plane no longer declares %q — `bp make workflow` prints %d days as the PAT default and would now be telling users a false number",
			want, patDefaultValidityDays)
	}
	if !strings.Contains(renderDeployWorkflow(workflowOptions{Site: "s"}), fmt.Sprintf("%d DAYS", patDefaultValidityDays)) {
		t.Fatalf("the emitted template does not state the PAT validity window")
	}
}

// TestMakeWorkflowCommandSurface covers the door: the site is required, a shell
// metacharacter is refused, --out writes the file, and --dist/--branch reach the
// output.
func TestMakeWorkflowCommandSurface(t *testing.T) {
	t.Run("site required", func(t *testing.T) {
		w, _, stderr := newTestWriter()
		if code := runMakeWorkflow(w, []string{"workflow"}); code != exitUsage {
			t.Fatalf("code = %d, want exitUsage; stderr=%s", code, stderr.String())
		}
	})
	t.Run("metacharacter refused", func(t *testing.T) {
		w, _, stderr := newTestWriter()
		if code := runMakeWorkflow(w, []string{"workflow", "a;curl evil"}); code != exitUsage {
			t.Fatalf("a site containing a shell metacharacter was accepted (code %d); stderr=%s", code, stderr.String())
		}
	})
	t.Run("out writes and dist/branch land", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "wf.yml")
		w, _, _ := newTestWriter()
		if code := runMakeWorkflow(w, []string{"workflow", "my-site", "--dist", "build", "--branch", "release", "--out", path}); code != exitOK {
			t.Fatalf("code = %d", code)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		got := string(raw)
		for _, want := range []string{"BARKPARK_DIST: build", "branches: [release]", "BARKPARK_SITE: my-site"} {
			if !strings.Contains(got, want) {
				t.Errorf("emitted workflow is missing %q", want)
			}
		}
	})
}
