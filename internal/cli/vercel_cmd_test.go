package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestVercelScopedPrefix pins the CRITICAL invariant: provisioning is driven
// against the SCOPED prefix /w/<site>/p/default — never the flat /v1/ alias
// (which resolves to the Default workspace and lands content in the wrong
// tenant; DEPLOYING.md gotcha #1).
func TestVercelScopedPrefix(t *testing.T) {
	got := vercelScopedPrefix("hundesteder", "default")
	want := "/w/hundesteder/p/default"
	if got != want {
		t.Fatalf("vercelScopedPrefix = %q, want %q", got, want)
	}
	if strings.Contains(got, "//") {
		t.Errorf("scoped prefix has a doubled slash: %q", got)
	}

	// A site slug with a space-y char is path-escaped, never raw.
	esc := vercelScopedPrefix("two words", "default")
	if strings.Contains(esc, " ") {
		t.Errorf("scoped prefix not path-escaped: %q", esc)
	}
}

// The scoped base must place /v1/tokens, /v1/schemas, /v1/data/mutate UNDER the
// /w/<site>/p/default prefix — the exact URLs the flow POSTs to.
func TestVercelScopedURLsAreNotFlat(t *testing.T) {
	base := "https://api.barkpark.cloud"
	scopedBase := base + vercelScopedPrefix("acme", "default")

	cases := map[string]string{
		"tokens": scopedBase + "/v1/tokens",
		"schema": scopedBase + "/v1/schemas/production",
		"mutate": scopedBase + "/v1/data/mutate/production",
	}
	for name, u := range cases {
		if !strings.HasPrefix(u, "https://api.barkpark.cloud/w/acme/p/default/v1/") {
			t.Errorf("%s URL is not scoped: %q", name, u)
		}
		// The flat form would be base + "/v1/..." with no /w/.../p/... — reject it.
		if strings.HasPrefix(u, base+"/v1/") {
			t.Errorf("%s URL is FLAT (wrong tenant): %q", name, u)
		}
	}
}

func TestParseVercelArgs(t *testing.T) {
	opt, err := parseVercelArgs([]string{
		"--site", "hundesteder",
		"--app-dir", "apps/hundesteder",
		"--schema", "s.json",
		"--seed", "seed.json",
		"--publish-type", "place",
		"--dataset", "production",
		"--vercel-team", "guerrilla",
		"--vercel-project", "hp",
		"--read-token", "tok-123",
	})
	if err != nil {
		t.Fatalf("parseVercelArgs error: %v", err)
	}
	if opt.site != "hundesteder" || opt.appDir != "apps/hundesteder" {
		t.Errorf("site/app-dir not parsed: %+v", opt)
	}
	if opt.schema != "s.json" || opt.seed != "seed.json" || opt.publishType != "place" {
		t.Errorf("schema/seed/publish-type not parsed: %+v", opt)
	}
	if opt.dataset != "production" || opt.vercelTeam != "guerrilla" || opt.vercelProject != "hp" {
		t.Errorf("dataset/team/project not parsed: %+v", opt)
	}
	if opt.readToken != "tok-123" {
		t.Errorf("read-token not parsed: %+v", opt)
	}
	if opt.noDeploy {
		t.Errorf("noDeploy should be false")
	}
}

func TestParseVercelArgsInlineForm(t *testing.T) {
	opt, err := parseVercelArgs([]string{"--site=acme", "--no-deploy"})
	if err != nil {
		t.Fatalf("parseVercelArgs error: %v", err)
	}
	if opt.site != "acme" {
		t.Errorf("inline --site=acme not parsed: %q", opt.site)
	}
	if !opt.noDeploy {
		t.Errorf("--no-deploy not parsed")
	}
}

func TestParseVercelArgsUnknownFlag(t *testing.T) {
	if _, err := parseVercelArgs([]string{"--bogus"}); err == nil {
		t.Fatal("parseVercelArgs accepted an unknown flag; want error")
	}
}

func TestParseVercelArgsMissingValue(t *testing.T) {
	if _, err := parseVercelArgs([]string{"--site"}); err == nil {
		t.Fatal("parseVercelArgs accepted --site with no value; want error")
	}
}

// runVercelQuickSetup must reject a missing --site (exit 2) before any network.
func TestVercelQuickSetupRequiresSite(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := runVercelQuickSetup(w, globals{}, []string{"--no-deploy"})
	if code != exitUsage {
		t.Errorf("missing --site exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "--site is required") {
		t.Errorf("stderr missing site-required message: %q", stderr.String())
	}
}

// Without --no-deploy, --app-dir is required.
func TestVercelQuickSetupRequiresAppDir(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := runVercelQuickSetup(w, globals{}, []string{"--site", "acme"})
	if code != exitUsage {
		t.Errorf("missing --app-dir exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "--app-dir is required") {
		t.Errorf("stderr missing app-dir-required message: %q", stderr.String())
	}
}

// runVercel with no subcommand prints usage; with --help exits 0 and routes the
// help text to stdout (so `bp vercel --help` is pipeable, like every sibling).
func TestRunVercelHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := runVercel(w, globals{help: true}, []string{})
	if code != exitOK {
		t.Errorf("bare `vercel -h` exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "quick-setup") {
		t.Errorf("stdout missing quick-setup: %q", stdout.String())
	}

	// Explicit --help subcommand — help goes to stdout on the exit-0 path.
	stdout.Reset()
	stderr.Reset()
	if code := runVercel(w, globals{}, []string{"--help"}); code != exitOK {
		t.Errorf("`vercel --help` exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "quick-setup") {
		t.Errorf("`vercel --help` stdout missing quick-setup: %q", stdout.String())
	}
}

func TestRunVercelUnknownSubcommand(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code := runVercel(w, globals{}, []string{"bogus"})
	if code != exitUsage {
		t.Errorf("unknown subcommand exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "unknown vercel subcommand") {
		t.Errorf("stderr missing unknown-subcommand message: %q", stderr.String())
	}
}

func TestVercelSeedIDs(t *testing.T) {
	seed := []byte(`{"mutations":[
		{"createOrReplace":{"_id":"place-a","_type":"place"}},
		{"create":{"_id":"place-b","_type":"place"}},
		{"createOrReplace":{"title":"no id here"}}
	]}`)
	ids, err := vercelSeedIDs(seed)
	if err != nil {
		t.Fatalf("vercelSeedIDs error: %v", err)
	}
	want := []string{"place-a", "place-b"}
	if !reflect.DeepEqual(ids, want) {
		t.Errorf("vercelSeedIDs = %v, want %v", ids, want)
	}
}

// The publish payload must carry BOTH id AND type per mutation (id-only 400s).
func TestVercelPublishPayload(t *testing.T) {
	pub := vercelPublishPayload([]string{"place-a", "place-b"}, "place")
	muts, ok := pub["mutations"].([]map[string]any)
	if !ok || len(muts) != 2 {
		t.Fatalf("publish payload mutations = %v", pub["mutations"])
	}
	first := muts[0]["publish"].(map[string]string)
	if first["id"] != "place-a" || first["type"] != "place" {
		t.Errorf("publish mutation = %v, want id+type", first)
	}
}

func TestLastNonEmptyLine(t *testing.T) {
	in := "Building…\nUploading…\nhttps://acme.vercel.app\n\n"
	if got := lastNonEmptyLine(in); got != "https://acme.vercel.app" {
		t.Errorf("lastNonEmptyLine = %q, want the URL", got)
	}
	if got := lastNonEmptyLine("   \n  "); got != "" {
		t.Errorf("lastNonEmptyLine of blank = %q, want empty", got)
	}
}

func TestParseVercelArgsStatic(t *testing.T) {
	opt, err := parseVercelArgs([]string{"--static", "site/index.html", "--vercel-team", "guerrilla"})
	if err != nil {
		t.Fatalf("parseVercelArgs error: %v", err)
	}
	if opt.static != "site/index.html" {
		t.Errorf("--static not parsed: %q", opt.static)
	}
	if opt.vercelTeam != "guerrilla" {
		t.Errorf("--vercel-team not parsed alongside --static: %q", opt.vercelTeam)
	}
}

// STATIC mode must skip ALL Barkpark steps: with --static, runVercelQuickSetup
// routes straight to the static branch BEFORE any token resolution, workspace
// POST, or backed-mode required-flag enforcement. We make the assertion
// deterministic (and never actually call `vercel`) by pointing --static at a
// nonexistent path: the function fails at STAGING, proving it entered the
// static branch — and it must NOT report any Barkpark concern.
func TestVercelStaticSkipsBarkpark(t *testing.T) {
	// In backed mode an empty token would exit exitAuth ("no admin token"); we
	// clear it to make that path observable if it were (wrongly) taken.
	t.Setenv("BARKPARK_API_TOKEN", "")

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	// No --site / --app-dir at all — backed mode would exit 2 on the missing
	// required flags. Static mode ignores them and proceeds. The path does not
	// exist, so staging fails deterministically without ever calling vercel.
	code := runVercelQuickSetup(w, globals{}, []string{"--static", "/no/such/static/path"})

	combined := stdout.String() + stderr.String()
	if code != exitGeneric {
		t.Errorf("static staging miss exit = %d, want %d; out=%q", code, exitGeneric, combined)
	}
	if !strings.Contains(combined, "staging failed") {
		t.Errorf("expected a static staging error, got: %q", combined)
	}
	// It must NOT have taken any Barkpark path.
	for _, bad := range []string{"no admin token", "--site is required", "--app-dir is required", "workspace"} {
		if strings.Contains(combined, bad) {
			t.Errorf("static mode leaked a Barkpark concern (%q): %q", bad, combined)
		}
	}
}

func TestVercelStageStaticDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, cleanup, err := vercelStageStatic(dir)
	if cleanup != nil {
		defer cleanup()
	}
	if err != nil {
		t.Fatalf("vercelStageStatic(dir) error: %v", err)
	}
	if got != dir {
		t.Errorf("a directory should be deployed as-is: got %q want %q", got, dir)
	}
	if cleanup != nil {
		t.Errorf("directory mode should have no cleanup")
	}
}

func TestVercelStageStaticHTMLFile(t *testing.T) {
	src := t.TempDir()
	page := filepath.Join(src, "landing.html")
	if err := os.WriteFile(page, []byte("<h1>marketing</h1>"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Adjacent assets/ dir must be copied alongside.
	if err := os.MkdirAll(filepath.Join(src, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "assets", "app.css"), []byte("body{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	staged, cleanup, err := vercelStageStatic(page)
	if cleanup != nil {
		defer cleanup()
	}
	if err != nil {
		t.Fatalf("vercelStageStatic(html) error: %v", err)
	}
	if staged == src || staged == "" {
		t.Fatalf("html file should stage into a fresh dir, got %q", staged)
	}
	// The page lands as index.html.
	idx, rerr := os.ReadFile(filepath.Join(staged, "index.html"))
	if rerr != nil || string(idx) != "<h1>marketing</h1>" {
		t.Errorf("staged index.html missing/wrong: %v %q", rerr, string(idx))
	}
	// assets/ copied.
	if _, serr := os.Stat(filepath.Join(staged, "assets", "app.css")); serr != nil {
		t.Errorf("adjacent assets/ not copied into the staged dir: %v", serr)
	}
}

func TestVercelStaticProjectName(t *testing.T) {
	if got := vercelStaticProjectName("/x/y/landing.html"); got != "landing" {
		t.Errorf("html basename project = %q, want landing", got)
	}
	if got := vercelStaticProjectName("/x/marketing-site/"); got != "marketing-site" {
		t.Errorf("dir basename project = %q, want marketing-site", got)
	}
}

// jsonMachineWriter returns a writer whose resolved output is json — the shape a
// scripted `bp vercel … -o json` produces after applyGlobals runs.
func jsonMachineWriter(stdout, stderr *bytes.Buffer) *writer {
	w := newWriter(stdout, stderr)
	w.output = "json"
	return w
}

// With -o json, a successful --no-deploy provision must print EXACTLY ONE
// parseable envelope to stdout (url absent, read_token present, deployed:false);
// all human progress chatter (▸ / ✓) is diverted to stderr so a scripted caller
// can `jq` stdout. Driven against an httptest fake so no network is touched.
func TestVercelQuickSetupJSONNoDeploy(t *testing.T) {
	// Neutralise ambient BARKPARK_* so only the flag layer (g.server/g.token)
	// resolves the context.
	// axi-b4: derived from the shared dialect lists rather than typed.
	for _, k := range append(append([]string{}, ServerEnvNames...), TokenEnvNames...) {
		t.Setenv(k, "")
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "POST" && r.URL.Path == "/api/workspaces":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"id":"ws-1"}`))
		case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/tokens"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"token":"read-xyz"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	w := jsonMachineWriter(&stdout, &stderr)
	code := runVercelQuickSetup(w, globals{server: srv.URL, token: "admin-tok"}, []string{"--site", "acme", "--no-deploy"})
	if code != exitOK {
		t.Fatalf("no-deploy json exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}

	// stdout must be a single parseable object — nothing else.
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not a single json object: %v\n%q", err, stdout.String())
	}
	if env["ok"] != true {
		t.Errorf("ok = %v, want true", env["ok"])
	}
	if env["read_token"] != "read-xyz" {
		t.Errorf("read_token = %v, want read-xyz", env["read_token"])
	}
	if env["site"] != "acme" {
		t.Errorf("site = %v, want acme", env["site"])
	}
	if env["deployed"] != false {
		t.Errorf("deployed = %v, want false", env["deployed"])
	}
	// No human chatter may leak onto stdout.
	if strings.ContainsAny(stdout.String(), "▸✓") {
		t.Errorf("human progress leaked onto json stdout: %q", stdout.String())
	}
	// Progress + the (secret) token line go to stderr, not stdout.
	if !strings.Contains(stderr.String(), "minted") {
		t.Errorf("expected progress on stderr, got: %q", stderr.String())
	}
}

// With -o json, an argument-validation failure must emit a json error envelope
// on stdout (ok:false, error.code) — never bare usage text — so a scripted
// caller sees a parseable failure. Human mode is covered separately and stays
// byte-identical (errf on stderr + usage).
func TestVercelQuickSetupJSONError(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := jsonMachineWriter(&stdout, &stderr)
	code := runVercelQuickSetup(w, globals{}, []string{"--no-deploy"}) // missing --site
	if code != exitUsage {
		t.Fatalf("missing --site json exit = %d, want %d", code, exitUsage)
	}
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not a json error envelope: %v\n%q", err, stdout.String())
	}
	if env["ok"] != false {
		t.Errorf("ok = %v, want false", env["ok"])
	}
	errObj, _ := env["error"].(map[string]any)
	if errObj == nil || errObj["code"] != "usage" {
		t.Errorf("error envelope = %v, want code=usage", env["error"])
	}
	// The human usage block must NOT pollute json stdout.
	if strings.Contains(stdout.String(), "usage: bp vercel") {
		t.Errorf("human usage leaked onto json stdout: %q", stdout.String())
	}
}

func TestVercelAuthPaths(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "/xdg")
	paths := vercelAuthPaths()
	var sawXDG bool
	for _, p := range paths {
		if strings.HasPrefix(p, "/xdg/com.vercel.cli/") {
			sawXDG = true
		}
	}
	if !sawXDG {
		t.Errorf("vercelAuthPaths did not honour XDG_DATA_HOME: %v", paths)
	}
}
