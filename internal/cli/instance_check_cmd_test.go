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
	"sort"
	"strings"
	"testing"
)

// stubInstanceProbes replaces the database and TLS probes for one test.
func stubInstanceProbes(t *testing.T, db func(context.Context, string) ([]instanceExtension, error), tlsErr error) *[]string {
	t.Helper()
	var dbURLs []string
	oldDB, oldTLS := instanceDBProbe, instanceTLSProbe
	instanceDBProbe = func(ctx context.Context, u string) ([]instanceExtension, error) {
		dbURLs = append(dbURLs, u)
		return db(ctx, u)
	}
	instanceTLSProbe = func(context.Context, string) error { return tlsErr }
	t.Cleanup(func() { instanceDBProbe, instanceTLSProbe = oldDB, oldTLS })
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
	env, err := parseInstanceEnv(strings.NewReader(instanceEnvFile(instanceTargetContainerApps, secrets)))
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
