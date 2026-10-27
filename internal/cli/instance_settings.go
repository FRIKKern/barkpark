package cli

// instance_settings.go holds what `bp instance init` writes and what
// `bp instance check` reads: the settings a production instance needs, the
// secrets bp generates, and the recommended settings for a Pensum instance
// from docs/setup/SELF-HOST.md. Both verbs run on the operator's
// machine and need no server and no capabilities manifest.

import (
	"bufio"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Doc links printed after each problem. They are repo paths, as elsewhere in bp.
const (
	instanceDocRecommended = "docs/setup/SELF-HOST.md#pensum-settings"
	instanceDocKeys        = "docs/setup/SELF-HOST-OPERATIONS.md#rotate-keys"
	instanceDocDatabase    = "docs/setup/SELF-HOST-OPERATIONS.md#moving-an-instance"
	instanceDocContainer   = "docs/setup/SELF-HOST.md"
	instanceDocOIDCSecret  = "docs/setup/SELF-HOST-UPDATES.md#rotate-the-oidc-client-secret"
)

const (
	instanceTargetContainerApps = "containerapps"
	instanceTargetVM            = "vm"
)

// instanceRequired are the settings a fresh prod instance does not start
// without. api/config/runtime.exs refuses to boot without the first six.
// BARKPARK_RELEASE_CAPTURE_HMAC_SECRET only warns in runtime.exs, but
// migration 20260719020100 raises without it, so a fresh database never
// finishes migrating.
var instanceRequired = []struct{ name, doc string }{
	{"DATABASE_URL", instanceDocDatabase},
	{"PHX_HOST", instanceDocContainer},
	{"SECRET_KEY_BASE", instanceDocKeys},
	{"BARKPARK_CLOAK_KEY", instanceDocKeys},
	{"BARKPARK_KEK", instanceDocKeys},
	{"PREVIEW_JWT_SECRET", instanceDocKeys},
	{"BARKPARK_RELEASE_CAPTURE_HMAC_SECRET", instanceDocKeys},
}

// instanceRecommended is one recommended Pensum setting. A fixed value must
// match (for a list, every item must be present). An empty value means the
// operator supplies it and it must be set to something that is not a
// placeholder.
type instanceRecommended struct {
	name    string
	value   string
	list    bool
	targets string // "" means every target
	hint    string // the placeholder init writes when value is ""
}

var instanceRecommendedSettings = []instanceRecommended{
	{name: "PHX_SCHEME", value: "https"},
	{name: "DATABASE_SSL", value: "verify-full", targets: instanceTargetContainerApps},
	{name: "BARKPARK_MEDIA_DIR", targets: instanceTargetContainerApps, hint: "<Azure Files mount path>"},
	{name: "BARKPARK_SELF_UPDATE_CHECK", value: "off"},
	{name: "BARKPARK_RETIRE_SSE_ON_SIGTERM", value: "1"},
	{name: "BARKPARK_ALWAYS_ALLOWED_ORIGINS", hint: "<Pensum's browser origins, comma-separated>"},
	{name: "BARKPARK_PLUGINS", value: "media"},
	{name: "BARKPARK_TMUX_CONSOLE", value: "off"},
	{name: "BARKPARK_CAPABILITIES_OFF", value: "studio_chat,cycle_fleet,epic_fleet", list: true},
	{name: "BARKPARK_OPERATOR_EMAILS", hint: "<operator emails, comma-separated>"},
	{name: "BARKPARK_OPERATOR_FAIL_CLOSED", value: "1"},
	{name: "BARKPARK_SIGN_IN_POLICY_ALL_ROUTES", value: "1"},
	{name: "BARKPARK_CLOUD_HANDOFF", value: "off"},
	{name: "BARKPARK_BREAKGLASS_EMAILS", hint: "<break-glass account email>"},
	{name: "BARKPARK_TOKEN_EXPIRY_WARNINGS", value: "on"},
	{name: "BARKPARK_OIDC_KEEP_OWNER", value: "on"},
	{name: "BARKPARK_OIDC_EMAIL_FROM_UPN", value: "on"},
}

// instanceInitValues are the operator's values init can write in place of a
// placeholder. An empty field keeps the placeholder.
type instanceInitValues struct {
	host, studioOrigin, ownerEmail, operatorEmails, breakglassEmail string
}

// value returns the operator's value for a recommended setting, or "".
func (v instanceInitValues) value(name string) string {
	switch name {
	case "BARKPARK_ALWAYS_ALLOWED_ORIGINS":
		if v.host == "" {
			return ""
		}
		origins := "https://" + v.host
		// A Studio served by the instance itself has the instance's origin,
		// which is already first in the list.
		if v.studioOrigin != "" && !strings.EqualFold(v.studioOrigin, origins) {
			origins += "," + v.studioOrigin
		}
		return origins
	case "BARKPARK_OPERATOR_EMAILS":
		return v.operatorEmails
	case "BARKPARK_MEDIA_DIR":
		// The mount path deploy/azure/main.bicep uses. The template sets it.
		return instanceContainerAppsMediaDir
	case "BARKPARK_BREAKGLASS_EMAILS":
		return v.breakglassEmail
	}
	return ""
}

func (r instanceRecommended) appliesTo(target string) bool {
	return r.targets == "" || r.targets == target
}

// instanceContainerAppsMediaDir is where deploy/azure/main.bicep mounts the
// media share, and instanceContainerAppsDatabaseHost stands in for the database
// host, which the template sets. The template reads only the password from
// DATABASE_URL.
const (
	instanceContainerAppsMediaDir     = "/app/uploads"
	instanceContainerAppsDatabaseHost = "unused"
)

// instanceSecretNames are the values init generates. Each one is written to
// the env file only and never printed.
var instanceSecretNames = []string{"SECRET_KEY_BASE", "BARKPARK_CLOAK_KEY", "BARKPARK_KEK", "PREVIEW_JWT_SECRET", "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET"}

// instanceDeployOwned are the settings deploy.sh generates on a single VM and
// keeps when it merges BARKPARK_ENV_FILE. init leaves them out for --target vm.
var instanceDeployOwned = append([]string{"DATABASE_URL"}, instanceSecretNames...)

func instanceDeployOwns(target, name string) bool {
	if target != instanceTargetVM {
		return false
	}
	for _, n := range instanceDeployOwned {
		if n == name {
			return true
		}
	}
	return false
}

// instanceKnownSettings lists every BARKPARK_* name the server, its deploy
// scripts or bp read. `bp instance check` uses it to spot a misspelled name.
// Refresh it with: go test ./internal/cli -run TestInstanceKnownSettingsList -update
//
//go:embed instance_known_settings.txt
var instanceKnownSettingsRaw string

func instanceKnownSettings() map[string]bool {
	known := map[string]bool{}
	for _, line := range strings.Split(instanceKnownSettingsRaw, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			known[line] = true
		}
	}
	for _, r := range instanceRecommendedSettings {
		known[r.name] = true
	}
	for _, r := range instanceRequired {
		known[r.name] = true
	}
	return known
}

// instanceRandom is the entropy source. Tests may replace it.
var instanceRandom io.Reader = rand.Reader

func instanceRandomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := io.ReadFull(instanceRandom, b); err != nil {
		return nil, fmt.Errorf("read random bytes: %w", err)
	}
	return b, nil
}

// instanceGenerateSecrets returns fresh values in the shapes runtime.exs
// accepts: SECRET_KEY_BASE is 88 characters (at least 64 bytes), the KEK is
// base64 of exactly 32 bytes, the release capture HMAC secret is 44
// characters (at least 32 bytes), and the database password is 48 hex characters
// so it needs no escaping in a URL. The seed admin token is bp_admin_ and 48
// hex characters, the shape deploy/azure/main.example.bicepparam generates.
func instanceGenerateSecrets() (map[string]string, error) {
	sizes := map[string]int{"SECRET_KEY_BASE": 64, "BARKPARK_CLOAK_KEY": 32, "BARKPARK_KEK": 32, "PREVIEW_JWT_SECRET": 48, "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET": 32}
	out := map[string]string{}
	for _, name := range instanceSecretNames {
		b, err := instanceRandomBytes(sizes[name])
		if err != nil {
			return nil, err
		}
		out[name] = base64.StdEncoding.EncodeToString(b)
	}
	pw, err := instanceRandomBytes(24)
	if err != nil {
		return nil, err
	}
	out["database_password"] = hex.EncodeToString(pw)
	tok, err := instanceRandomBytes(24)
	if err != nil {
		return nil, err
	}
	out["BARKPARK_SEED_ADMIN_TOKEN"] = "bp_admin_" + hex.EncodeToString(tok)
	id, err := instanceRandomBytes(16)
	if err != nil {
		return nil, err
	}
	out["BARKPARK_SEED_ADMIN_TOKEN_ID"] = uuidV4(id)
	return out, nil
}

// uuidV4 formats 16 random bytes as a version 4 UUID.
func uuidV4(b []byte) string {
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// instanceEnvFile renders the env file init writes.
func instanceEnvFile(target string, secrets map[string]string, vals instanceInitValues) string {
	var b strings.Builder
	line := func(format string, a ...any) { fmt.Fprintf(&b, format+"\n", a...) }
	line("# Barkpark instance settings, written by bp instance init --target %s.", target)
	line("# This file holds secrets. Keep it at mode 600 and out of version control.")
	line("# Replace every <...> value, then run: bp instance check --env-file <this file>")
	line("")
	line("# Required")
	if target == instanceTargetVM {
		line("# deploy.sh sets %s on the VM.", strings.Join(instanceDeployOwned, ", "))
	} else {
		line("# deploy/azure/main.bicep sets the database host and BARKPARK_MEDIA_DIR.")
		line("DATABASE_URL=ecto://barkpark:%s@%s/barkpark", secrets["database_password"], instanceContainerAppsDatabaseHost)
	}
	if vals.host != "" {
		line("PHX_HOST=%s", vals.host)
	} else {
		line("PHX_HOST=<public host name, such as cms.example.com>")
	}
	if target != instanceTargetVM {
		for _, name := range instanceSecretNames {
			line("%s=%s", name, secrets[name])
		}
	}
	line("BARKPARK_KEK_VERSION=1")
	line("")
	line("# Recommended settings for a Pensum instance (%s)", instanceDocRecommended)
	if target == instanceTargetVM {
		line("DATABASE_SSL=off")
	}
	for _, r := range instanceRecommendedSettings {
		if !r.appliesTo(target) {
			continue
		}
		v := r.value
		if v == "" {
			v = vals.value(r.name)
		}
		if v == "" {
			v = r.hint
		}
		line("%s=%s", r.name, v)
	}
	// Studio SSO reads only BARKPARK_STUDIO_SSO_ORIGINS, not the CORS list.
	if vals.studioOrigin != "" {
		line("BARKPARK_STUDIO_SSO_ORIGINS=%s", vals.studioOrigin)
	} else {
		line("# For a Studio that signs in with SSO, its origin with no path:")
		line("# BARKPARK_STUDIO_SSO_ORIGINS=<Studio origin>")
	}
	if target == instanceTargetContainerApps {
		line("# Set when the OS trust store lacks the Flexible Server CA:")
		line("# DATABASE_SSL_CA_FILE=<CA bundle path>")
	}
	line("# First boot only. Remove it once the owner has signed in:")
	if vals.ownerEmail != "" {
		line("BARKPARK_BOOTSTRAP_OWNER_EMAIL=%s", vals.ownerEmail)
	} else {
		line("BARKPARK_BOOTSTRAP_OWNER_EMAIL=<owner email>")
	}
	if target == instanceTargetContainerApps {
		line("# First boot only. The first admin token, an operator token under this id:")
		line("BARKPARK_SEED_ADMIN_TOKEN=%s", secrets["BARKPARK_SEED_ADMIN_TOKEN"])
		line("BARKPARK_SEED_ADMIN_TOKEN_ID=%s", secrets["BARKPARK_SEED_ADMIN_TOKEN_ID"])
		line("BARKPARK_OPERATOR_TOKEN_IDS=%s", secrets["BARKPARK_SEED_ADMIN_TOKEN_ID"])
	}
	return b.String()
}

// parseInstanceEnv reads KEY=VALUE lines. It skips blank lines and comments,
// accepts an `export ` prefix and strips one pair of matching quotes.
func parseInstanceEnv(r io.Reader) (map[string]string, error) {
	env := map[string]string{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	n := 0
	for sc.Scan() {
		n++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, val, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			return nil, fmt.Errorf("line %d is not KEY=VALUE", n)
		}
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val)-1] == val[0] {
			val = val[1 : len(val)-1]
		}
		env[key] = val
	}
	return env, sc.Err()
}

// environEnv turns os.Environ-style pairs into a map.
func environEnv(pairs []string) map[string]string {
	env := map[string]string{}
	for _, p := range pairs {
		if k, v, ok := strings.Cut(p, "="); ok {
			env[k] = v
		}
	}
	return env
}

func isPlaceholder(v string) bool {
	i := strings.Index(v, "<")
	return i >= 0 && strings.Contains(v[i:], ">")
}

// nearestSetting returns the known name closest to name within two edits.
func nearestSetting(name string, known map[string]bool) string {
	best, bestD := "", 3
	names := make([]string, 0, len(known))
	for k := range known {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		if d := levenshtein(name, k); d < bestD {
			best, bestD = k, d
		}
	}
	return best
}
