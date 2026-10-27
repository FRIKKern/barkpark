package cli

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

// stubInstanceProbes replaces the database and TLS probes for one test.
func stubInstanceProbes(t *testing.T, db func(context.Context, string) ([]instanceExtension, error), tlsErr error) *[]string {
	t.Helper()
	var dbURLs []string
	oldDB, oldTLS, oldOIDC := instanceDBProbe, instanceTLSProbe, instanceOIDCSecretProbe
	instanceDBProbe = func(ctx context.Context, u string) ([]instanceExtension, error) {
		dbURLs = append(dbURLs, u)
		return db(ctx, u)
	}
	instanceTLSProbe = func(context.Context, string) error { return tlsErr }
	instanceOIDCSecretProbe = func(context.Context, string) ([]instanceOIDCSecret, error) { return nil, nil }
	t.Cleanup(func() { instanceDBProbe, instanceTLSProbe, instanceOIDCSecretProbe = oldDB, oldTLS, oldOIDC })
	return &dbURLs
}

func allExtensions(context.Context, string) ([]instanceExtension, error) {
	var out []instanceExtension
	for _, n := range instanceRequiredExtensions {
		out = append(out, instanceExtension{Name: n, Installed: true, Available: true, Allowed: true})
	}
	return out, nil
}

func runInstanceVerb(t *testing.T, verb string, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{output: "table", outputSet: true}
	w.applyGlobals(g)
	code := runInstance(w, g, append([]string{verb}, args...))
	return stdout.String(), stderr.String(), code
}

// completeEnv is a correct containerapps environment.
func completeEnv(t *testing.T) map[string]string {
	t.Helper()
	secrets, err := instanceGenerateSecrets()
	if err != nil {
		t.Fatal(err)
	}
	env, err := parseInstanceEnv(strings.NewReader(instanceEnvFile(instanceTargetContainerApps, secrets, instanceInitValues{})))
	if err != nil {
		t.Fatal(err)
	}
	env["DATABASE_URL"] = "ecto://barkpark:" + secrets["database_password"] + "@pg.example.com/barkpark"
	env["PHX_HOST"] = "cms.example.com"
	env["BARKPARK_MEDIA_DIR"] = t.TempDir()
	env["BARKPARK_ALWAYS_ALLOWED_ORIGINS"] = "https://pensum.example.com"
	env["BARKPARK_OPERATOR_EMAILS"] = "ops@example.com"
	env["BARKPARK_BREAKGLASS_EMAILS"] = "glass@example.com"
	env["BARKPARK_BOOTSTRAP_OWNER_EMAIL"] = "owner@example.com"
	return env
}

func TestInstanceInitWritesPrivateCompleteFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "barkpark.env")
	stdout, stderr, code := runInstanceVerb(t, "init", "--out", path)
	if code != exitOK {
		t.Fatalf("init exit %d: %s", code, stderr)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, want 600", st.Mode().Perm())
	}
	body, _ := os.ReadFile(path)
	env, err := parseInstanceEnv(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range instanceSecretNames {
		v := env[name]
		if v == "" {
			t.Fatalf("%s is empty", name)
		}
		if strings.Contains(stdout+stderr, v) {
			t.Fatalf("init printed the value of %s", name)
		}
	}
	pw := strings.TrimPrefix(strings.Split(env["DATABASE_URL"], "@")[0], "ecto://barkpark:")
	if len(pw) != 48 || strings.Contains(stdout+stderr, pw) {
		t.Fatalf("database password: len %d, printed %v", len(pw), strings.Contains(stdout+stderr, pw))
	}
	if len(env["SECRET_KEY_BASE"]) < 64 {
		t.Fatalf("SECRET_KEY_BASE is %d bytes", len(env["SECRET_KEY_BASE"]))
	}
	if raw, _ := base64.StdEncoding.DecodeString(env["BARKPARK_KEK"]); len(raw) != 32 {
		t.Fatalf("BARKPARK_KEK decodes to %d bytes", len(raw))
	}
	for _, r := range instanceRecommendedSettings {
		if r.appliesTo(instanceTargetContainerApps) && env[r.name] == "" {
			t.Fatalf("recommended %s missing from the file", r.name)
		}
	}
	if env["DATABASE_SSL"] != "verify-full" {
		t.Fatalf("containerapps DATABASE_SSL = %q", env["DATABASE_SSL"])
	}

	// A second run refuses and leaves the file alone.
	_, stderr, code = runInstanceVerb(t, "init", "--out", path)
	if code == exitOK || !strings.Contains(stderr, "already exists") {
		t.Fatalf("second init: exit %d, stderr %q", code, stderr)
	}
	again, _ := os.ReadFile(path)
	if !bytes.Equal(body, again) {
		t.Fatal("second init changed the file")
	}
}

func TestInstanceInitTargetVM(t *testing.T) {
	path := filepath.Join(t.TempDir(), "vm.env")
	if _, stderr, code := runInstanceVerb(t, "init", "--out", path, "--target", "vm"); code != exitOK {
		t.Fatalf("init exit %d: %s", code, stderr)
	}
	body, _ := os.ReadFile(path)
	env, _ := parseInstanceEnv(bytes.NewReader(body))
	if env["DATABASE_SSL"] != "off" {
		t.Fatalf("vm DATABASE_SSL=%q", env["DATABASE_SSL"])
	}
	// deploy.sh owns these on a VM; the file must not carry them.
	for _, name := range instanceDeployOwned {
		if _, ok := env[name]; ok {
			t.Fatalf("vm file sets %s, which deploy.sh owns", name)
		}
	}
	if !strings.Contains(string(body), "# deploy.sh sets DATABASE_URL") {
		t.Fatal("vm file does not say deploy.sh sets DATABASE_URL")
	}
	// check --target vm reports the missing owned settings as notes, not problems.
	env["PHX_HOST"] = "cms.example.com"
	problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetVM, skip: map[string]bool{"database": true, "media": true, "url": true}})
	for _, p := range problems {
		for _, name := range instanceDeployOwned {
			if p.Setting == name {
				t.Fatalf("check reports owned %s as a problem: %s", name, p.Problem)
			}
		}
	}
	owned := 0
	for _, n := range notes {
		if strings.Contains(n.Problem, "deploy.sh sets it") {
			owned++
		}
	}
	if owned != len(instanceDeployOwned) {
		t.Fatalf("check gave %d deploy.sh notes, want %d", owned, len(instanceDeployOwned))
	}
	if _, ok := env["BARKPARK_MEDIA_DIR"]; ok {
		t.Fatal("vm file sets BARKPARK_MEDIA_DIR")
	}
	if _, _, code := runInstanceVerb(t, "init", "--out", path+"2", "--target", "aws"); code != exitUsage {
		t.Fatalf("unknown target exit %d", code)
	}
}

// TestInstanceCheckAfterInit is criterion 2 of the init task: a fresh file
// reports only the values the operator must still supply.
func TestInstanceCheckAfterInit(t *testing.T) {
	stubInstanceProbes(t, func(context.Context, string) ([]instanceExtension, error) {
		t.Fatal("the database probe ran against a placeholder URL")
		return nil, nil
	}, nil)
	path := filepath.Join(t.TempDir(), "barkpark.env")
	if _, stderr, code := runInstanceVerb(t, "init", "--out", path); code != exitOK {
		t.Fatal(stderr)
	}
	stdout, _, code := runInstanceVerb(t, "check", "--env-file", path)
	if code != exitGeneric {
		t.Fatalf("check exit %d, want 1", code)
	}
	_, report, _ := strings.Cut(stdout, "\n\n")
	var got []string
	for _, l := range strings.Split(strings.TrimSpace(report), "\n") {
		if strings.HasPrefix(l, "note: ") {
			continue
		}
		if !strings.Contains(l, "placeholder") || !strings.Contains(l, " See docs/") {
			t.Fatalf("line is not a placeholder problem with a doc link: %q", l)
		}
		got = append(got, strings.Fields(l)[0])
	}
	sort.Strings(got)
	want := []string{"BARKPARK_ALWAYS_ALLOWED_ORIGINS", "BARKPARK_BOOTSTRAP_OWNER_EMAIL", "BARKPARK_BREAKGLASS_EMAILS", "BARKPARK_MEDIA_DIR", "BARKPARK_OPERATOR_EMAILS", "DATABASE_URL", "PHX_HOST"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("problems for %v, want %v", got, want)
	}
}

func TestInstanceCheckCompleteEnvPasses(t *testing.T) {
	urls := stubInstanceProbes(t, allExtensions, nil)
	env := completeEnv(t)
	env["SMTP_HOST"] = "smtp.example.com"
	problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{}})
	if len(problems) != 0 || len(notes) != 0 {
		t.Fatalf("problems %v notes %v", problems, notes)
	}
	if len(*urls) != 1 || !strings.Contains((*urls)[0], "sslmode=verify-full") || !strings.Contains((*urls)[0], "sslrootcert=system") || !strings.HasPrefix((*urls)[0], "postgresql://") {
		t.Fatalf("database probe URLs = %v", *urls)
	}
}

func TestInstanceCheckReportsEachProblem(t *testing.T) {
	stubInstanceProbes(t, func(context.Context, string) ([]instanceExtension, error) {
		return []instanceExtension{
			{Name: "citext", Installed: true, Available: true, Allowed: true},
			{Name: "pg_trgm", Available: false, Allowed: true},
			{Name: "pgcrypto", Available: true, Allowed: false},
		}, nil
	}, errors.New("x509: certificate signed by unknown authority"))
	env := completeEnv(t)
	delete(env, "PREVIEW_JWT_SECRET")
	env["SECRET_KEY_BASE"] = strings.Repeat("ab", 40)
	env["BARKPARK_KEK"] = base64.StdEncoding.EncodeToString(make([]byte, 31))
	env["BARKPARK_CLOAK_KEY"] = "short"
	env["BARKPARK_OPERATR_EMAILS"] = "x@example.com"
	env["BARKPARK_SOMETHING_ELSE_ENTIRELY"] = "1"
	env["BARKPARK_PLUGINS"] = "media,onixedit"
	env["BARKPARK_CAPABILITIES_OFF"] = "studio_chat"
	env["BARKPARK_MEDIA_DIR"] = filepath.Join(t.TempDir(), "missing")

	problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{}})
	text := ""
	for _, p := range problems {
		if p.Doc == "" || !strings.HasPrefix(p.Doc, "docs/setup/") {
			t.Fatalf("problem without a doc link: %+v", p)
		}
		text += p.String() + "\n"
	}
	for _, want := range []string{
		"PREVIEW_JWT_SECRET is not set",
		"SECRET_KEY_BASE looks weak",
		"BARKPARK_KEK is not base64 of exactly 32 bytes",
		"BARKPARK_CLOAK_KEY is shorter than 32",
		"BARKPARK_OPERATR_EMAILS is not a Barkpark setting. Did you mean BARKPARK_OPERATOR_EMAILS?",
		`BARKPARK_PLUGINS is "media,onixedit"; the recommended value is media.`,
		"BARKPARK_CAPABILITIES_OFF lacks cycle_fleet,epic_fleet",
		"BARKPARK_MEDIA_DIR",
		"extension pg_trgm is not available",
		"extension pgcrypto is not in azure.extensions",
		"has no valid TLS certificate",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing problem %q in:\n%s", want, text)
		}
	}
	if len(notes) != 2 || notes[0].Setting != "SMTP_HOST" || !strings.Contains(notes[0].Problem, "SSO") || notes[1].Setting != "BARKPARK_SOMETHING_ELSE_ENTIRELY" {
		t.Errorf("notes = %v", notes)
	}
	for _, v := range []string{env["SECRET_KEY_BASE"], env["BARKPARK_KEK"]} {
		if strings.Contains(text, v) {
			t.Fatal("a problem line printed a secret value")
		}
	}
}

func TestInstanceCheckDatabaseUnreachableAndSkips(t *testing.T) {
	stubInstanceProbes(t, func(context.Context, string) ([]instanceExtension, error) {
		return nil, errors.New("connection refused")
	}, nil)
	env := completeEnv(t)
	env["DATABASE_SSL"] = "required"
	problems, _ := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{}})
	var text string
	for _, p := range problems {
		text += p.String() + "\n"
	}
	for _, want := range []string{`DATABASE_SSL is "required"; use verify-full or off.`, "the database is not reachable", "connection refused"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in:\n%s", want, text)
		}
	}
	env["DATABASE_SSL"] = "verify-full"
	problems, _ = instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{"database": true}})
	if len(problems) != 0 {
		t.Fatalf("--skip database still reports %v", problems)
	}
}

func TestInstanceCheckReadsEnvironment(t *testing.T) {
	stubInstanceProbes(t, allExtensions, nil)
	for k, v := range completeEnv(t) {
		t.Setenv(k, v)
	}
	stdout, stderr, code := runInstanceVerb(t, "check")
	if code != exitOK {
		t.Fatalf("exit %d\n%s%s", code, stdout, stderr)
	}
	env := completeEnv(t)
	for _, name := range append(instanceSecretNames, "DATABASE_URL") {
		if strings.Contains(stdout, env[name]) {
			t.Fatalf("check printed the value of %s", name)
		}
	}
	pw := strings.TrimPrefix(strings.Split(os.Getenv("DATABASE_URL"), "@")[0], "ecto://barkpark:")
	for _, want := range []string{"settings in effect", "BARKPARK_PLUGINS=media", "BARKPARK_TOKEN_EXPIRY_WARNINGS=on", "SECRET_KEY_BASE=<set, 88 characters>", "DATABASE_URL=ecto://barkpark:xxxxx@pg.example.com/barkpark"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("output lacks %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, pw) || strings.Contains(stdout, os.Getenv("BARKPARK_KEK")) {
		t.Fatal("check printed a secret value")
	}
	t.Setenv("BARKPARK_KEK", "")
	if _, _, code := runInstanceVerb(t, "check"); code != exitGeneric {
		t.Fatalf("missing KEK exit %d, want 1", code)
	}
}

func TestParseInstanceExtensions(t *testing.T) {
	exts, err := parseInstanceExtensions("citext|true|true|*\npg_trgm|false|true|citext,pg_trgm\npgcrypto|false|true|citext")
	if err != nil {
		t.Fatal(err)
	}
	if !exts[0].Installed || !exts[1].Allowed || exts[2].Allowed {
		t.Fatalf("exts = %+v", exts)
	}
}

// TestInstanceKnownSettingsList keeps instance_known_settings.txt current.
// It lists every BARKPARK_* name in the server, deploy scripts and bp. Run
// with -update to rewrite it. Without -update it only checks the file is
// sorted and covers the names this file's checks use, so a new setting
// elsewhere never fails this test; at worst check prints a note for it.
func TestInstanceKnownSettingsList(t *testing.T) {
	if *updateGolden {
		root := filepath.Join("..", "..")
		re := regexp.MustCompile(`BARKPARK_[A-Z0-9_]*[A-Z0-9]`)
		names := map[string]bool{}
		for _, dir := range []string{"api/config", "api/lib", "api/rel", "deploy", "internal", "cmd", "docker-compose.yml"} {
			_ = filepath.WalkDir(filepath.Join(root, dir), func(p string, d fs.DirEntry, err error) error {
				if err != nil || d.IsDir() || strings.HasSuffix(p, "_test.go") || strings.HasSuffix(p, "instance_known_settings.txt") {
					return nil
				}
				body, err := os.ReadFile(p)
				if err != nil {
					return nil
				}
				for _, m := range re.FindAllString(string(body), -1) {
					names[m] = true
				}
				return nil
			})
		}
		list := make([]string, 0, len(names))
		for n := range names {
			list = append(list, n)
		}
		sort.Strings(list)
		if err := os.WriteFile("instance_known_settings.txt", []byte(strings.Join(list, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	lines := strings.Split(strings.TrimSpace(instanceKnownSettingsRaw), "\n")
	if len(lines) < 50 || !sort.StringsAreSorted(lines) {
		t.Fatalf("instance_known_settings.txt has %d lines or is unsorted; rerun with -update", len(lines))
	}
	have := map[string]bool{}
	for _, l := range lines {
		have[l] = true
	}
	for _, r := range instanceRecommendedSettings {
		if strings.HasPrefix(r.name, "BARKPARK_") && !have[r.name] {
			t.Errorf("%s is not in instance_known_settings.txt; rerun with -update", r.name)
		}
	}
}

// TestInstanceReleaseCaptureHMACSecret: migration 20260719020100 raises on a
// fresh database without BARKPARK_RELEASE_CAPTURE_HMAC_SECRET, so init writes
// it for containerapps and check requires it unless the target is vm, where
// deploy.sh generates it.
func TestInstanceReleaseCaptureHMACSecret(t *testing.T) {
	const name = "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"
	skip := map[string]bool{"database": true, "media": true, "url": true}
	stubInstanceProbes(t, allExtensions, nil)

	env := completeEnv(t)
	if raw, err := base64.StdEncoding.DecodeString(env[name]); err != nil || len(raw) != 32 {
		t.Fatalf("containerapps init wrote %s decoding to %d bytes (%v)", name, len(raw), err)
	}
	if problems, _ := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: skip}); len(problems) != 0 {
		t.Fatalf("complete env has problems: %+v", problems)
	}

	hasProblem := func(problems []instanceProblem, want string) bool {
		for _, p := range problems {
			if p.Setting == name && strings.Contains(p.Problem, want) {
				return true
			}
		}
		return false
	}

	delete(env, name)
	problems, _ := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: skip})
	if !hasProblem(problems, "is not set") {
		t.Fatalf("containerapps check without %s: %+v", name, problems)
	}

	env[name] = "short"
	problems, _ = instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: skip})
	if !hasProblem(problems, "shorter than 32 bytes") {
		t.Fatalf("containerapps check with a short %s: %+v", name, problems)
	}

	delete(env, name)
	problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetVM, skip: skip})
	if hasProblem(problems, "") {
		t.Fatalf("vm check reports %s as a problem: %+v", name, problems)
	}
	noted := false
	for _, n := range notes {
		noted = noted || (n.Setting == name && strings.Contains(n.Problem, "deploy.sh sets it"))
	}
	if !noted {
		t.Fatalf("vm check gave no deploy.sh note for %s", name)
	}
	if strings.Contains(instanceEnvFile(instanceTargetVM, map[string]string{name: "x"}, instanceInitValues{}), name+"=") {
		t.Fatalf("vm init file sets %s", name)
	}
}

// TestInstanceInitValueFlags: the guide's values go in by flag, so a vm file
// written with every flag has no placeholder left, and both OIDC settings the
// guide recommends are on.
func TestInstanceInitValueFlags(t *testing.T) {
	path := filepath.Join(t.TempDir(), "vm.env")
	stdout, stderr, code := runInstanceVerb(t, "init", "--out", path, "--target", "vm",
		"--host", "cms.example.com", "--studio-origin", "https://studio.example.com",
		"--owner-email", "owner@example.com", "--operator-emails", "a@example.com,b@example.com",
		"--breakglass-email", "bg@example.com")
	if code != exitOK {
		t.Fatalf("init exit %d: %s", code, stderr)
	}
	if strings.Contains(stdout, "fill in") {
		t.Fatalf("init asks to fill in values after every flag: %s", stdout)
	}
	body, _ := os.ReadFile(path)
	env, _ := parseInstanceEnv(bytes.NewReader(body))
	want := map[string]string{
		"PHX_HOST":                        "cms.example.com",
		"BARKPARK_ALWAYS_ALLOWED_ORIGINS": "https://cms.example.com,https://studio.example.com",
		"BARKPARK_BOOTSTRAP_OWNER_EMAIL":  "owner@example.com",
		"BARKPARK_OPERATOR_EMAILS":        "a@example.com,b@example.com",
		"BARKPARK_BREAKGLASS_EMAILS":      "bg@example.com",
		"BARKPARK_OIDC_KEEP_OWNER":        "on",
		"BARKPARK_OIDC_EMAIL_FROM_UPN":    "on",
		"BARKPARK_STUDIO_SSO_ORIGINS":     "https://studio.example.com",
	}
	for k, v := range want {
		if env[k] != v {
			t.Errorf("%s = %q, want %q", k, env[k], v)
		}
	}
	for k, v := range env {
		if isPlaceholder(v) {
			t.Errorf("%s is still a placeholder: %s", k, v)
		}
	}
	if _, ok := env["BARKPARK_SEED_ADMIN_TOKEN"]; ok {
		t.Error("vm file sets BARKPARK_SEED_ADMIN_TOKEN; deploy.sh mints the admin token")
	}
	problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetVM, skip: map[string]bool{"database": true, "media": true, "url": true}})
	if len(problems) != 0 {
		t.Fatalf("check on a flag-filled vm file: %v", problems)
	}
	for _, n := range notes {
		if strings.Contains(n.Problem, "OIDC") {
			t.Errorf("check note names an OIDC setting: %s", n.Problem)
		}
	}
	if _, _, code := runInstanceVerb(t, "init", "--out", path+"2", "--host", "https://cms.example.com"); code != exitUsage {
		t.Fatalf("--host with a scheme exit %d", code)
	}
	if _, _, code := runInstanceVerb(t, "init", "--out", path+"3", "--studio-origin", "studio.example.com"); code != exitUsage {
		t.Fatalf("--studio-origin without a scheme exit %d", code)
	}
	// A Studio URL with a path and a trailing slash is written as its origin.
	p4 := path + "4"
	if _, stderr, code := runInstanceVerb(t, "init", "--out", p4, "--target", "vm", "--host", "cms.example.com", "--studio-origin", "https://Studio.example.com:443/studio/"); code != exitOK {
		t.Fatalf("init exit %d: %s", code, stderr)
	}
	b4, _ := os.ReadFile(p4)
	e4, _ := parseInstanceEnv(bytes.NewReader(b4))
	if e4["BARKPARK_STUDIO_SSO_ORIGINS"] != "https://studio.example.com" || e4["BARKPARK_ALWAYS_ALLOWED_ORIGINS"] != "https://cms.example.com,https://studio.example.com" {
		t.Fatalf("studio origin not normalised: %q, %q", e4["BARKPARK_STUDIO_SSO_ORIGINS"], e4["BARKPARK_ALWAYS_ALLOWED_ORIGINS"])
	}
	// A Studio on the instance's own origin is not listed a second time.
	p5 := path + "5"
	if _, stderr, code := runInstanceVerb(t, "init", "--out", p5, "--target", "vm", "--host", "cms.example.com", "--studio-origin", "https://cms.example.com/studio"); code != exitOK {
		t.Fatalf("init exit %d: %s", code, stderr)
	}
	b5, _ := os.ReadFile(p5)
	e5, _ := parseInstanceEnv(bytes.NewReader(b5))
	if e5["BARKPARK_ALWAYS_ALLOWED_ORIGINS"] != "https://cms.example.com" || e5["BARKPARK_STUDIO_SSO_ORIGINS"] != "https://cms.example.com" {
		t.Fatalf("instance origin repeated: %q, %q", e5["BARKPARK_ALWAYS_ALLOWED_ORIGINS"], e5["BARKPARK_STUDIO_SSO_ORIGINS"])
	}
	if problems, _ := instanceCheck(context.Background(), e4, instanceCheckOpts{target: instanceTargetVM, studioURL: "https://studio.example.com", skip: map[string]bool{"database": true, "media": true, "url": true}}); len(problems) != 0 {
		for _, p := range problems {
			if strings.Contains(p.Setting, "STUDIO_SSO") {
				t.Fatalf("check --studio-url on an init file: %s", p.Problem)
			}
		}
	}
}

// TestInstanceInitContainerAppsSecretsMatchBicep: init --target containerapps
// generates the seven secrets deploy/azure/main.example.bicepparam lists.
func TestInstanceInitContainerAppsSecretsMatchBicep(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ca.env")
	stdout, stderr, code := runInstanceVerb(t, "init", "--out", path)
	if code != exitOK {
		t.Fatalf("init exit %d: %s", code, stderr)
	}
	body, _ := os.ReadFile(path)
	env, _ := parseInstanceEnv(bytes.NewReader(body))
	tok := env["BARKPARK_SEED_ADMIN_TOKEN"]
	if !regexp.MustCompile(`^bp_admin_[0-9a-f]{48}$`).MatchString(tok) || strings.Contains(stdout+stderr, tok) {
		t.Fatalf("BARKPARK_SEED_ADMIN_TOKEN shape or echo wrong")
	}
	param, err := os.ReadFile(filepath.Join("..", "..", "deploy", "azure", "main.example.bicepparam"))
	if err != nil {
		t.Fatal(err)
	}
	// The bicepparam reads barkpark.env and names each required secret exactly
	// as init writes it. env.?NAME marks an optional one, which init leaves out.
	want := []string{
		"DATABASE_URL",
		"SECRET_KEY_BASE",
		"BARKPARK_CLOAK_KEY",
		"BARKPARK_KEK",
		"PREVIEW_JWT_SECRET",
		"BARKPARK_SEED_ADMIN_TOKEN",
		"BARKPARK_RELEASE_CAPTURE_HMAC_SECRET",
	}
	got := regexp.MustCompile(`(?m)^param \w+ = .*\benv\.([A-Z0-9_]+)\b`).FindAllStringSubmatch(string(param), -1)
	if len(got) != len(want) {
		t.Fatalf("bicepparam reads %d required secrets, want %d", len(got), len(want))
	}
	for _, m := range got {
		if !slices.Contains(want, m[1]) {
			t.Errorf("bicepparam reads %s, which init does not generate", m[1])
			continue
		}
		if env[m[1]] == "" {
			t.Errorf("init leaves %s empty", m[1])
		}
	}
}

func TestInstanceCheckOIDCSecretExpiry(t *testing.T) {
	stubInstanceProbes(t, allExtensions, nil)
	now := time.Date(2026, 11, 1, 8, 0, 0, 0, time.UTC)
	oldNow := instanceNow
	instanceNow = func() time.Time { return now }
	t.Cleanup(func() { instanceNow = oldNow })
	instanceOIDCSecretProbe = func(context.Context, string) ([]instanceOIDCSecret, error) {
		return []instanceOIDCSecret{
			{Org: "expired", ExpiresAt: now.Add(-time.Hour)},
			{Org: "soon", ExpiresAt: now.Add(10 * 24 * time.Hour)},
			{Org: "later", ExpiresAt: now.Add(200 * 24 * time.Hour)},
			{Org: "unset"},
		}, nil
	}
	env := completeEnv(t)
	env["SMTP_HOST"] = "smtp.example.com"
	problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{}})
	if len(problems) != 1 || problems[0].Setting != "oidc:expired" || !strings.Contains(problems[0].Problem, "expired 2026-11-01") {
		t.Fatalf("problems %v", problems)
	}
	want := map[string]string{
		"oidc:soon":  "expires 2026-11-11, in 10 days",
		"oidc:later": "expires 2027-05-20.",
		"oidc:unset": "--client_secret_expires_at",
	}
	if len(notes) != len(want) {
		t.Fatalf("notes %v", notes)
	}
	for _, n := range notes {
		if !strings.Contains(n.Problem, want[n.Setting]) || n.Doc != instanceDocOIDCSecret {
			t.Fatalf("note %+v, want it to contain %q", n, want[n.Setting])
		}
	}

	// A probe error, such as a database not yet migrated, adds nothing.
	instanceOIDCSecretProbe = func(context.Context, string) ([]instanceOIDCSecret, error) {
		return nil, errors.New("relation does not exist")
	}
	if problems, notes := instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{}}); len(problems)+len(notes) != 0 {
		t.Fatalf("problems %v notes %v", problems, notes)
	}
	// --skip database skips it.
	called := false
	instanceOIDCSecretProbe = func(context.Context, string) ([]instanceOIDCSecret, error) { called = true; return nil, nil }
	instanceCheck(context.Background(), env, instanceCheckOpts{target: instanceTargetContainerApps, skip: map[string]bool{"database": true}})
	if called {
		t.Fatal("the OIDC probe ran with --skip database")
	}
}

func TestParseInstanceOIDCSecrets(t *testing.T) {
	got, err := parseInstanceOIDCSecrets("acme|2027-10-27T00:00:00Z\nbeta|\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Org != "acme" || got[0].ExpiresAt.Format("2006-01-02") != "2027-10-27" || got[1].Org != "beta" || !got[1].ExpiresAt.IsZero() {
		t.Fatalf("got %+v", got)
	}
	if _, err := parseInstanceOIDCSecrets("no separator"); err == nil {
		t.Fatal("want an error for a malformed row")
	}
}
