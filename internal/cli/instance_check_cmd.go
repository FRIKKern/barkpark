package cli

// instance_check_cmd.go is `bp instance init` and `bp instance check`.
//
//	bp instance init  [--out <file>] [--target containerapps|vm] [--host <h>]
//	                  [--studio-origin <o>] [--owner-email <e>]
//	                  [--operator-emails <e,...>] [--breakglass-email <e>]
//	bp instance check [--env-file <file>] [--target containerapps|vm] [--skip database,media,url]
//	                  [--studio-url <url>]
//
// init writes a complete env file with generated secrets and the recommended
// Pensum settings. check reads that file, or the process environment, and
// prints one line per problem with a doc link. Neither verb talks to a
// Barkpark server, so both work before the server first starts. When check
// reaches a migrated database, it also reads each OIDC connection's recorded
// client secret expiry date.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"net"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// instanceProblem is one line of check output.
type instanceProblem struct {
	Setting string `json:"setting,omitempty"`
	Problem string `json:"problem"`
	Doc     string `json:"doc"`
}

func (p instanceProblem) String() string {
	return p.Problem + " See " + p.Doc
}

type instanceCheckOpts struct {
	target    string
	skip      map[string]bool
	studioURL string // --studio-url: check the Studio sign-in settings for it
}

// instanceRequiredExtensions are the extensions the migrations create.
var instanceRequiredExtensions = []string{"citext", "pg_trgm", "pgcrypto"}

// instanceExtension is what the database reports for one required extension.
type instanceExtension struct {
	Name      string
	Installed bool
	Available bool
	Allowed   bool // false only when azure.extensions is set and omits it
}

// instanceDBProbe connects with the configured TLS mode and reports the
// required extensions. Tests replace it.
var instanceDBProbe = psqlInstanceProbe

// instanceTLSProbe dials host:443 and verifies its certificate. Tests replace it.
var instanceTLSProbe = dialInstanceTLS

// instanceOIDCSecretProbe reads the recorded client secret expiry of each
// active OIDC connection. Tests replace it.
var instanceOIDCSecretProbe = psqlOIDCSecretProbe

// instanceNow is the clock for the expiry notes. Tests replace it.
var instanceNow = time.Now

// instanceOIDCSecret is one active OIDC connection. ExpiresAt is zero when
// no date is recorded.
type instanceOIDCSecret struct {
	Org       string
	ExpiresAt time.Time
}

// instanceOIDCSecretWarnDays matches the server's first warning step.
const instanceOIDCSecretWarnDays = 30

func instanceTargetFlag(a *hzArgs) (string, error) {
	t := strings.TrimSpace(a.val("target"))
	switch t {
	case "":
		return instanceTargetContainerApps, nil
	case instanceTargetContainerApps, instanceTargetVM:
		return t, nil
	}
	return "", fmt.Errorf("--target is %q; use containerapps or vm", t)
}

func runInstanceInit(out *writer, args []string) int {
	const usage = "bp instance init [--out <file>] [--target containerapps|vm] [--host <h>] [--studio-origin <o>] [--owner-email <e>] [--operator-emails <e,...>] [--breakglass-email <e>]"
	a, err := parseHzArgs(args, []string{"out", "target", "host", "studio-origin", "owner-email", "operator-emails", "breakglass-email"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", "unexpected argument "+a.pos[0]+" (usage: "+usage+")", exitUsage)
	}
	target, err := instanceTargetFlag(a)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	path := strings.TrimSpace(a.val("out"))
	if path == "" {
		path = "barkpark.env"
	}
	vals := instanceInitValues{
		host:            strings.TrimSpace(a.val("host")),
		studioOrigin:    strings.TrimSpace(a.val("studio-origin")),
		ownerEmail:      strings.TrimSpace(a.val("owner-email")),
		operatorEmails:  strings.TrimSpace(a.val("operator-emails")),
		breakglassEmail: strings.TrimSpace(a.val("breakglass-email")),
	}
	if vals.studioOrigin != "" {
		origin, err := instanceStudioOrigin(vals.studioOrigin)
		if err != nil {
			return useError(out, "usage", fmt.Sprintf("--studio-origin is %q; give the Studio's origin, such as https://studio.example.com", vals.studioOrigin), exitUsage)
		}
		vals.studioOrigin = origin
	}
	if strings.Contains(vals.host, "/") || strings.Contains(vals.host, ":") {
		return useError(out, "usage", fmt.Sprintf("--host is %q; give the host name only, such as cms.example.com", vals.host), exitUsage)
	}
	secrets, err := instanceGenerateSecrets()
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	body := instanceEnvFile(target, secrets, vals)
	if err := writeNewPrivateFile(path, body); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	env, _ := parseInstanceEnv(strings.NewReader(body))
	var fill []string
	for k, v := range env {
		if isPlaceholder(v) {
			fill = append(fill, k)
		}
	}
	sort.Strings(fill)
	generated := append(append([]string{}, instanceSecretNames...), "BARKPARK_SEED_ADMIN_TOKEN", "its id on BARKPARK_OPERATOR_TOKEN_IDS", "the database password in DATABASE_URL")
	if target == instanceTargetVM {
		generated = []string{}
	}
	if out.emitStructured(map[string]any{"ok": true, "action": "init", "file": path, "target": target, "generated": generated, "fill_in": fill}) {
		return exitOK
	}
	out.outf("wrote %s with mode 600 for target %s.", path, target)
	if target == instanceTargetVM {
		out.outf("deploy.sh sets %s on the VM, so the file leaves them out.", strings.Join(instanceDeployOwned, ", "))
	} else {
		out.outf("generated %s. The values are in the file only.", strings.Join(generated, ", "))
	}
	if len(fill) > 0 {
		out.outf("fill in %s.", strings.Join(fill, ", "))
	}
	out.outf("then run: bp instance check --env-file %s --target %s", path, target)
	return exitOK
}

// writeNewPrivateFile creates path with mode 0600 and refuses to replace an
// existing file.
func writeNewPrivateFile(path, body string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("%s already exists; bp instance init does not overwrite it. Choose another --out or move the file", path)
		}
		return err
	}
	if _, err := f.WriteString(body); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func runInstanceCheck(out *writer, args []string) int {
	const usage = "bp instance check [--env-file <file>] [--target containerapps|vm] [--skip database,media,url] [--studio-url <url>]"
	a, err := parseHzArgs(args, []string{"env-file", "target", "skip", "studio-url"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", "unexpected argument "+a.pos[0]+" (usage: "+usage+")", exitUsage)
	}
	opts := instanceCheckOpts{skip: map[string]bool{}}
	if opts.target, err = instanceTargetFlag(a); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if opts.studioURL = strings.TrimSpace(a.val("studio-url")); opts.studioURL != "" {
		if _, err := instanceStudioOrigin(opts.studioURL); err != nil {
			return useError(out, "usage", err.Error(), exitUsage)
		}
	}
	for _, s := range a.list("skip") {
		for _, part := range strings.Split(s, ",") {
			part = strings.TrimSpace(part)
			switch part {
			case "database", "media", "url":
				opts.skip[part] = true
			case "":
			default:
				return useError(out, "usage", fmt.Sprintf("--skip %q is not one of database, media, url", part), exitUsage)
			}
		}
	}
	source := "the environment"
	var env map[string]string
	if path := strings.TrimSpace(a.val("env-file")); path != "" {
		f, err := os.Open(path)
		if err != nil {
			return useError(out, "usage", err.Error(), exitUsage)
		}
		env, err = parseInstanceEnv(f)
		f.Close()
		if err != nil {
			return useError(out, "usage", path+": "+err.Error(), exitUsage)
		}
		source = path
	} else {
		env = environEnv(os.Environ())
	}

	problems, notes := instanceCheck(context.Background(), env, opts)
	effective := instanceEffectiveSettings(env)
	if out.emitStructured(map[string]any{"ok": len(problems) == 0, "action": "check", "source": source, "target": opts.target, "settings": effective, "problems": problems, "notes": notes}) {
		if len(problems) > 0 {
			return exitGeneric
		}
		return exitOK
	}
	out.outf("settings in effect from %s, secrets masked:", source)
	names := make([]string, 0, len(effective))
	for k := range effective {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		out.outf("  %s=%s", k, effective[k])
	}
	out.outf("")
	for _, p := range problems {
		out.outf("%s", p)
	}
	for _, n := range notes {
		out.outf("note: %s", n)
	}
	if len(problems) > 0 {
		out.errf("%d problems in %s.", len(problems), source)
		return exitGeneric
	}
	out.outf("no problems in %s.", source)
	return exitOK
}

// instanceCheck returns the problems in env and notes that do not fail the check.
func instanceCheck(ctx context.Context, env map[string]string, opts instanceCheckOpts) (problems, notes []instanceProblem) {
	add := func(setting, doc, format string, a ...any) {
		problems = append(problems, instanceProblem{Setting: setting, Problem: fmt.Sprintf(format, a...), Doc: doc})
	}
	set := func(name string) bool { v, ok := env[name]; return ok && v != "" }
	usable := func(name string) bool { return set(name) && !isPlaceholder(env[name]) }

	for _, r := range instanceRequired {
		switch {
		case !set(r.name) && instanceDeployOwns(opts.target, r.name):
			notes = append(notes, instanceProblem{Setting: r.name, Problem: fmt.Sprintf("%s is not set here. deploy.sh sets it on the VM.", r.name), Doc: r.doc})
		case !set(r.name):
			add(r.name, r.doc, "%s is not set. The server does not start without it.", r.name)
		case isPlaceholder(env[r.name]):
			add(r.name, r.doc, "%s still holds a placeholder. Replace the <...> part.", r.name)
		}
	}

	// Secrets: the shapes runtime.exs accepts, and no two the same.
	if usable("SECRET_KEY_BASE") {
		v := env["SECRET_KEY_BASE"]
		if len(v) < 64 {
			add("SECRET_KEY_BASE", instanceDocKeys, "SECRET_KEY_BASE is %d bytes; it must be at least 64. Generate one with openssl rand -base64 64.", len(v))
		} else if weakSecret(v) {
			add("SECRET_KEY_BASE", instanceDocKeys, "SECRET_KEY_BASE looks weak: it repeats too few characters. Generate one with openssl rand -base64 64.")
		}
	}
	if usable("BARKPARK_KEK") {
		if raw, err := base64.StdEncoding.DecodeString(env["BARKPARK_KEK"]); err != nil || len(raw) != 32 {
			add("BARKPARK_KEK", instanceDocKeys, "BARKPARK_KEK is not base64 of exactly 32 bytes. Generate one with openssl rand -base64 32.")
		} else if weakSecret(string(raw)) {
			add("BARKPARK_KEK", instanceDocKeys, "BARKPARK_KEK looks weak: its bytes repeat too much. Generate one with openssl rand -base64 32.")
		}
	}
	if usable("BARKPARK_CLOAK_KEY") {
		if v := env["BARKPARK_CLOAK_KEY"]; len(v) < 32 || weakSecret(v) {
			add("BARKPARK_CLOAK_KEY", instanceDocKeys, "BARKPARK_CLOAK_KEY is shorter than 32 characters or repeats too few characters. Generate one with openssl rand -base64 32.")
		}
	}
	if usable("PREVIEW_JWT_SECRET") {
		if v := env["PREVIEW_JWT_SECRET"]; len(v) < 32 || weakSecret(v) {
			add("PREVIEW_JWT_SECRET", instanceDocKeys, "PREVIEW_JWT_SECRET is shorter than 32 characters or repeats too few characters. Generate one with openssl rand -base64 48.")
		}
	}
	if usable("BARKPARK_RELEASE_CAPTURE_HMAC_SECRET") {
		if v := env["BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"]; len(v) < 32 || weakSecret(v) {
			add("BARKPARK_RELEASE_CAPTURE_HMAC_SECRET", instanceDocKeys, "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET is shorter than 32 bytes or repeats too few characters. A fresh database does not finish migrating without a valid one. Generate one with openssl rand -base64 32.")
		}
	}
	seen := map[string]string{}
	for _, name := range instanceSecretNames {
		if !usable(name) {
			continue
		}
		if other, dup := seen[env[name]]; dup {
			add(name, instanceDocKeys, "%s has the same value as %s. Each key must be independent.", name, other)
		}
		seen[env[name]] = name
	}

	// Settings whose values runtime.exs validates.
	switch ssl := env["DATABASE_SSL"]; ssl {
	case "", "off", "verify-full":
	default:
		add("DATABASE_SSL", instanceDocDatabase, "DATABASE_SSL is %q; use verify-full or off.", ssl)
	}
	if ca := env["DATABASE_SSL_CA_FILE"]; ca != "" && !isPlaceholder(ca) && !opts.skip["media"] {
		if st, err := os.Stat(ca); err != nil || !st.Mode().IsRegular() {
			add("DATABASE_SSL_CA_FILE", instanceDocDatabase, "DATABASE_SSL_CA_FILE %s is not a file on this machine.", ca)
		}
	}
	if s := env["PHX_SCHEME"]; s != "" && s != "http" && s != "https" {
		add("PHX_SCHEME", instanceDocContainer, "PHX_SCHEME is %q; use https.", s)
	}

	// Recommended Pensum settings.
	for _, r := range instanceRecommendedSettings {
		if !r.appliesTo(opts.target) {
			continue
		}
		v := env[r.name]
		switch {
		case !set(r.name):
			if r.value != "" {
				add(r.name, instanceDocRecommended, "%s is not set; the recommended value is %s.", r.name, r.value)
			} else {
				add(r.name, instanceDocRecommended, "%s is not set; set it to %s.", r.name, r.hint)
			}
		case isPlaceholder(v):
			add(r.name, instanceDocRecommended, "%s still holds a placeholder. Replace the <...> part.", r.name)
		case r.list:
			have := map[string]bool{}
			for _, item := range strings.Split(v, ",") {
				have[strings.TrimSpace(item)] = true
			}
			var missing []string
			for _, item := range strings.Split(r.value, ",") {
				if !have[item] {
					missing = append(missing, item)
				}
			}
			if len(missing) > 0 {
				add(r.name, instanceDocRecommended, "%s lacks %s; the recommended value is %s.", r.name, strings.Join(missing, ","), r.value)
			}
		case r.value != "" && v != r.value:
			add(r.name, instanceDocRecommended, "%s is %q; the recommended value is %s.", r.name, v, r.value)
		}
	}
	if isPlaceholder(env["BARKPARK_BOOTSTRAP_OWNER_EMAIL"]) {
		add("BARKPARK_BOOTSTRAP_OWNER_EMAIL", instanceDocRecommended, "BARKPARK_BOOTSTRAP_OWNER_EMAIL still holds a placeholder. Set the owner's email, or remove the line after the first boot.")
	}

	// Mail is optional for a Pensum instance; /status.json still shows it.
	if !set("SMTP_HOST") {
		notes = append(notes, instanceProblem{Setting: "SMTP_HOST", Doc: instanceDocRecommended,
			Problem: "SMTP_HOST is not set, so /status.json shows the mail component as degraded. Mail carries magic-link sign-in, password reset, email verification and access invitations. An instance whose editors sign in with SSO and whose break-glass account uses a password and TOTP does not need it."})
	}

	// Misspelled or unknown BARKPARK_* names.
	known := instanceKnownSettings()
	var names []string
	for k := range env {
		if strings.HasPrefix(k, "BARKPARK_") && !known[k] {
			names = append(names, k)
		}
	}
	sort.Strings(names)
	for _, k := range names {
		if near := nearestSetting(k, known); near != "" {
			add(k, instanceDocRecommended, "%s is not a Barkpark setting. Did you mean %s?", k, near)
		} else {
			notes = append(notes, instanceProblem{Setting: k, Problem: fmt.Sprintf("%s is not a setting this bp knows. A newer server may read it.", k), Doc: instanceDocRecommended})
		}
	}

	// Media directory, on this machine.
	if dir := env["BARKPARK_MEDIA_DIR"]; dir != "" && !isPlaceholder(dir) && !opts.skip["media"] {
		if err := checkWritableDir(dir); err != nil {
			add("BARKPARK_MEDIA_DIR", instanceDocContainer, "BARKPARK_MEDIA_DIR %s is not writable here: %v. Run the check where the server runs, or pass --skip media.", dir, err)
		}
	}

	// Database: reachable with the configured TLS mode, extensions available.
	if usable("DATABASE_URL") && !opts.skip["database"] {
		dbURL, err := instanceDatabaseURL(env)
		if err != nil {
			add("DATABASE_URL", instanceDocDatabase, "DATABASE_URL is malformed: %v.", err)
		} else {
			pctx, cancel := context.WithTimeout(ctx, 20*time.Second)
			exts, err := instanceDBProbe(pctx, dbURL)
			cancel()
			if err != nil {
				add("DATABASE_URL", instanceDocDatabase, "the database is not reachable with DATABASE_SSL=%s: %v.", orDefault(env["DATABASE_SSL"], "off"), err)
			} else {
				p, n := instanceOIDCSecretNotes(ctx, dbURL)
				problems, notes = append(problems, p...), append(notes, n...)
			}
			for _, e := range exts {
				switch {
				case e.Installed:
				case !e.Available:
					add("DATABASE_URL", instanceDocDatabase, "the Postgres extension %s is not available on the database server.", e.Name)
				case !e.Allowed:
					add("DATABASE_URL", instanceDocDatabase, "the Postgres extension %s is not in azure.extensions. Allow citext,pg_trgm,pgcrypto.", e.Name)
				}
			}
		}
	}

	if opts.studioURL != "" {
		p, n := instanceStudioCheck(env, opts.studioURL)
		problems, notes = append(problems, p...), append(notes, n...)
	}

	// Public URL and its TLS certificate.
	if usable("PHX_HOST") && !opts.skip["url"] {
		host := env["PHX_HOST"]
		// Without PHX_SCHEME=https the recommended-settings pass names it.
		if env["PHX_SCHEME"] == "https" {
			if err := instanceTLSProbe(ctx, host); err != nil {
				add("PHX_HOST", instanceDocContainer, "https://%s has no valid TLS certificate: %v.", host, err)
			}
		}
	}
	return problems, notes
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

// weakSecret reports a value with fewer than 10 distinct bytes, such as a
// repeated character or a short word.
func weakSecret(v string) bool {
	distinct := map[byte]bool{}
	for i := 0; i < len(v); i++ {
		distinct[v[i]] = true
	}
	return len(distinct) < 10
}

func checkWritableDir(dir string) error {
	st, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return fmt.Errorf("not a directory")
	}
	f, err := os.CreateTemp(dir, ".bp-instance-check-*")
	if err != nil {
		return err
	}
	name := f.Name()
	f.Close()
	return os.Remove(name)
}

// instanceDatabaseURL turns DATABASE_URL and DATABASE_SSL into a libpq URL
// with the TLS mode the server uses.
func instanceDatabaseURL(env map[string]string) (string, error) {
	raw := env["DATABASE_URL"]
	if rest, ok := strings.CutPrefix(raw, "ecto://"); ok {
		raw = "postgresql://" + rest
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", errors.New("it does not parse as a URL")
	}
	if u.Scheme != "postgresql" && u.Scheme != "postgres" || u.Host == "" {
		return "", errors.New("want ecto://USER:PASS@HOST/DATABASE")
	}
	q := u.Query()
	q.Set("connect_timeout", "10")
	if env["DATABASE_SSL"] == "verify-full" {
		q.Set("sslmode", "verify-full")
		if ca := env["DATABASE_SSL_CA_FILE"]; ca != "" {
			q.Set("sslrootcert", ca)
		} else {
			q.Set("sslrootcert", "system")
		}
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

const instanceExtensionQuery = `SELECT e.name || '|' || (i.extname IS NOT NULL) || '|' || (a.name IS NOT NULL) || '|' || coalesce(current_setting('azure.extensions', true), '*')
FROM unnest(ARRAY['citext','pg_trgm','pgcrypto']) AS e(name)
LEFT JOIN pg_extension i ON i.extname = e.name
LEFT JOIN pg_available_extensions a ON a.name = e.name
ORDER BY e.name;`

func psqlInstanceProbe(ctx context.Context, dbURL string) ([]instanceExtension, error) {
	if _, err := exec.LookPath("psql"); err != nil {
		return nil, errors.New("psql is not on PATH; install the Postgres client tools or pass --skip database")
	}
	outText, err := psqlQuery(ctx, dbURL, instanceExtensionQuery)
	if err != nil {
		return nil, err
	}
	return parseInstanceExtensions(outText)
}

// instanceOIDCSecretQuery returns no rows before the migration that adds the
// column, so an older server reads as "nothing recorded" rather than an error.
const instanceOIDCSecretQuery = `SELECT o.slug || '|' || coalesce(to_char(c.client_secret_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')
FROM oidc_connections c JOIN organizations o ON o.id = c.organization_id
WHERE c.active ORDER BY o.slug;`

const instanceOIDCSecretColumnQuery = `SELECT count(*) FROM information_schema.columns
WHERE table_name = 'oidc_connections' AND column_name = 'client_secret_expires_at';`

func psqlOIDCSecretProbe(ctx context.Context, dbURL string) ([]instanceOIDCSecret, error) {
	n, err := psqlQuery(ctx, dbURL, instanceOIDCSecretColumnQuery)
	if err != nil || strings.TrimSpace(n) != "1" {
		return nil, err
	}
	text, err := psqlQuery(ctx, dbURL, instanceOIDCSecretQuery)
	if err != nil {
		return nil, err
	}
	return parseInstanceOIDCSecrets(text)
}

func parseInstanceOIDCSecrets(text string) ([]instanceOIDCSecret, error) {
	var out []instanceOIDCSecret
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		org, at, ok := strings.Cut(line, "|")
		if !ok {
			return nil, fmt.Errorf("unexpected OIDC connection row %q", line)
		}
		s := instanceOIDCSecret{Org: org}
		if at != "" {
			t, err := time.Parse(time.RFC3339, at)
			if err != nil {
				return nil, fmt.Errorf("unexpected OIDC secret expiry %q", at)
			}
			s.ExpiresAt = t
		}
		out = append(out, s)
	}
	return out, nil
}

// instanceOIDCSecretNotes turns the recorded expiry dates into a problem for
// a passed date and a note for every other connection. A database it cannot
// read, such as one not yet migrated, gives neither.
func instanceOIDCSecretNotes(ctx context.Context, dbURL string) (problems, notes []instanceProblem) {
	pctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	secrets, err := instanceOIDCSecretProbe(pctx, dbURL)
	cancel()
	if err != nil {
		return nil, nil
	}
	now := instanceNow()
	for _, s := range secrets {
		p := instanceProblem{Setting: "oidc:" + s.Org, Doc: instanceDocOIDCSecret}
		switch days := int(math.Ceil(s.ExpiresAt.Sub(now).Hours() / 24)); {
		case s.ExpiresAt.IsZero():
			p.Problem = fmt.Sprintf("the OIDC client secret of org %s has no recorded expiry date, so Barkpark cannot warn before it. Set it with bp org oidc-update %s --client_secret_expires_at <date>.", s.Org, s.Org)
			notes = append(notes, p)
		case !s.ExpiresAt.After(now):
			p.Problem = fmt.Sprintf("the OIDC client secret of org %s expired %s. Sign-ins through it fail. Rotate it.", s.Org, s.ExpiresAt.Format("2006-01-02"))
			problems = append(problems, p)
		case days <= instanceOIDCSecretWarnDays:
			p.Problem = fmt.Sprintf("the OIDC client secret of org %s expires %s, in %d days. Rotate it before then.", s.Org, s.ExpiresAt.Format("2006-01-02"), days)
			notes = append(notes, p)
		default:
			p.Problem = fmt.Sprintf("the OIDC client secret of org %s expires %s.", s.Org, s.ExpiresAt.Format("2006-01-02"))
			notes = append(notes, p)
		}
	}
	return problems, notes
}

func parseInstanceExtensions(text string) ([]instanceExtension, error) {
	var exts []instanceExtension
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		f := strings.Split(strings.TrimSpace(line), "|")
		if len(f) != 4 {
			return nil, fmt.Errorf("unexpected extension row %q", line)
		}
		allowed := f[3] == "*"
		for _, x := range strings.Split(f[3], ",") {
			if strings.TrimSpace(x) == f[0] {
				allowed = true
			}
		}
		exts = append(exts, instanceExtension{Name: f[0], Installed: f[1] == "true", Available: f[2] == "true", Allowed: allowed})
	}
	return exts, nil
}

func dialInstanceTLS(ctx context.Context, host string) error {
	addr := host
	if _, _, err := net.SplitHostPort(host); err != nil {
		addr = net.JoinHostPort(host, "443")
	}
	d := &tls.Dialer{NetDialer: &net.Dialer{Timeout: 10 * time.Second}, Config: &tls.Config{MinVersion: tls.VersionTLS12}}
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		var unknown x509.UnknownAuthorityError
		var invalid x509.CertificateInvalidError
		var hostErr x509.HostnameError
		if errors.As(err, &unknown) || errors.As(err, &invalid) || errors.As(err, &hostErr) {
			return err
		}
		return fmt.Errorf("could not connect to %s: %v. Pass --skip url before DNS and ingress exist", addr, err)
	}
	defer conn.Close()
	certs := conn.(*tls.Conn).ConnectionState().PeerCertificates
	if len(certs) > 0 {
		if left := time.Until(certs[0].NotAfter); left < 14*24*time.Hour {
			return fmt.Errorf("the certificate expires %s", certs[0].NotAfter.Format("2006-01-02"))
		}
	}
	return nil
}

// instanceEffectiveSettings returns the settings that matter, with secret
// values replaced by their length. From the process environment it keeps only
// the server's own prefixes, so unrelated shell variables stay out.
func instanceEffectiveSettings(env map[string]string) map[string]string {
	keep := map[string]bool{}
	for _, r := range instanceRequired {
		keep[r.name] = true
	}
	for _, r := range instanceRecommendedSettings {
		keep[r.name] = true
	}
	for k := range env {
		for _, prefix := range []string{"BARKPARK_", "DATABASE_", "PHX_", "SMTP_", "MAIL_", "PREVIEW_JWT_", "MEDIA_SIGNING_", "SECRET_KEY_BASE", "POOL_SIZE", "PORT"} {
			if strings.HasPrefix(k, prefix) {
				keep[k] = true
			}
		}
	}
	out := map[string]string{}
	for k := range keep {
		v, ok := env[k]
		switch {
		case !ok:
			out[k] = "<not set>"
		case k == "DATABASE_URL":
			out[k] = maskDatabaseURL(v)
		case isSecretSetting(k) && v != "":
			out[k] = fmt.Sprintf("<set, %d characters>", len(v))
		default:
			out[k] = v
		}
	}
	return out
}

func isSecretSetting(name string) bool {
	if name == "SECRET_KEY_BASE" || name == "BARKPARK_KEK" || name == "BARKPARK_KEK_PREVIOUS" {
		return true
	}
	for _, suffix := range []string{"_SECRET", "_KEY", "_TOKEN", "_PASSWORD", "_CREDENTIALS"} {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}

// maskDatabaseURL replaces the password in USER:PASS@ with xxxxx. It works on
// the text, so a URL that still holds a placeholder is masked too.
func maskDatabaseURL(v string) string {
	scheme, rest, ok := strings.Cut(v, "://")
	if !ok {
		return fmt.Sprintf("<set, %d characters, not a URL>", len(v))
	}
	at := strings.LastIndex(rest, "@")
	if at < 0 {
		return v
	}
	if user, _, has := strings.Cut(rest[:at], ":"); has {
		return scheme + "://" + user + ":xxxxx" + rest[at:]
	}
	return v
}
