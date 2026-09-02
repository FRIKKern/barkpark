// Package secretscrub is the ONE owner of Barkpark's secret-shape redaction.
//
// Three worker-side log paths carry text that a person later reads and that the
// control plane PERSISTS, and every one of them used to keep its own copy of the
// same regex set:
//
//   - internal/cli/cloud   — captured remote SSH output, wrapped into the error
//     the provision worker stores in provision_jobs.error (rendered verbatim by
//     cloud/priv/static/app.js as provision_error / deprovision_error).
//   - internal/provisioner — the create→live + bootstrap console narration teed
//     to the control plane and persisted in provision_jobs.console.
//   - internal/builder     — build console lines teed from nixpacks/Docker.
//
// Three copies meant three DIFFERENT postures. The provisioner console's copy
// still carried the original six-name allowlist (SECRET_KEY_BASE,
// BARKPARK_KEK{,_PREVIOUS}, BARKPARK_CLOAK_KEY, PREVIEW_JWT_SECRET,
// DATABASE_URL) under a doc comment promising it stayed "in lockstep" with the
// cloud runner's — a promise a hand-maintained copy cannot keep, and by the time
// this package was extracted it was already behind by an ecto-userinfo clause, a
// bearer clause, every non-admin bp_ token shape, and the whole shape-based key
// match. The builder's copy was missing KEK and the ecto clause. A shared
// function is the only version of "in lockstep" that holds.
//
// The posture: redact the VALUE, keep the KEY NAME, so a failed provision stays
// diagnosable. Matching is on the SHAPE of a secret rather than a list of names,
// because captured remote output is arbitrary — a box runs systemd units, agent
// installers and third-party CLIs whose env the worker cannot enumerate.
package secretscrub

import (
	"regexp"
	"strings"
)

// Placeholder is the fixed replacement every redaction writes. Its presence in
// an output is how tests prove a scrub ran at all.
const Placeholder = "[REDACTED]"

// ectoUserinfoRe matches the userinfo of an ecto/postgres URL — the
// `<user>:<pass>@` after the scheme — so a leaked DATABASE_URL value
// (ecto://user:PASS@host/db) never carries the password, even when it appears
// bare in prose rather than as an assignment. Both the ecto:// scheme deploy.sh
// uses and the postgres(ql):// shapes are covered.
var ectoUserinfoRe = regexp.MustCompile(`(ecto|postgres|postgresql)://[^\s:/@]+:[^\s@]+@`)

// bearerRe scrubs an `Authorization: Bearer <token>` / bare `Bearer <token>` a
// verbose remote command (curl -v, an HTTP client's debug log) might echo.
var bearerRe = regexp.MustCompile(`(?i)bearer\s+\S+`)

// bpTokenRe scrubs a Barkpark-shaped bearer (bp_admin_…, bp_read_…, bp_write_…)
// wherever it appears, not just after "Bearer" — belt-and-suspenders on top of
// the literal scrub, which only covers tokens the worker itself minted. The
// [a-z]+ kind segment matters: the provisioner console's old copy matched
// bp_admin_ ONLY, so a control-plane read/write token echoed by a remote command
// passed straight through.
var bpTokenRe = regexp.MustCompile(`bp_[a-z]+_[A-Za-z0-9_-]+`)

// envSecretAssignRe redacts the VALUE of a secret-SHAPED uppercase env
// assignment. Uppercase-only so it never mangles ordinary lowercase prose.
//
// KEK is in the alternation on purpose: BARKPARK_KEK and BARKPARK_KEK_PREVIOUS
// contain neither SECRET nor KEY (K-E-K, not K-E-Y), so a shape match without it
// would SILENTLY stop redacting the key-encryption key mid-rotation — the exact
// narrowing TestKeepsLegacySixNameCoverage pins. The old allowlist needed
// BARKPARK_KEK_PREVIOUS ordered before BARKPARK_KEK so the longer key won the
// alternation; the shape match has no such hazard — the trailing [A-Z0-9_]*
// swallows the whole key name either way.
var envSecretAssignRe = regexp.MustCompile(`\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|APIKEY|API_KEY|PRIVATE_KEY|DATABASE_URL|KEK|KEY)[A-Z0-9_]*)=(\S+)`)

// placeholderValueRe recognises a value that is an angle-bracket PLACEHOLDER
// rather than a secret — `FOO_API_KEY=<your-key>`. The provisioner deliberately
// narrates one such line (internal/provisioner/support.go, PDF-D88: the agent
// provider key hand-off instruction a developer has to read and paste), and
// redacting it would destroy the instruction rather than protect anything.
//
// The guard is deliberately NARROW in two ways. It only matches a leading,
// complete `<…>` group with no whitespace or nested brackets inside; and the
// group must be followed by end-of-value or a NON-word character — so shell
// quoting debris (`<your-key>\n'`) still counts as a placeholder while
// `SECRET_KEY_BASE=<x>realsecret` does NOT, and is redacted. Nothing broader
// than an obvious placeholder is exempt.
var placeholderValueRe = regexp.MustCompile(`^<[^<>\s]*>(?:[^0-9A-Za-z_]|$)`)

// Literals replaces every non-empty substring in secrets with Placeholder. It is
// the KNOWN-VALUE half of the redaction: the tokens the worker itself minted and
// registered. It cannot catch a secret generated on the box, which is what
// Patterns is for.
func Literals(s string, secrets []string) string {
	for _, secret := range secrets {
		if secret == "" {
			continue
		}
		s = strings.ReplaceAll(s, secret, Placeholder)
	}
	return s
}

// Patterns is the SHAPE half: it redacts secret-shaped substrings whose values
// the worker cannot enumerate because they are generated on the box or belong to
// software the worker did not install. In order:
//
//   - ecto/postgres URL userinfo:  ecto://user:PASS@host  →  ecto://[REDACTED]@host
//   - bearer headers:              Bearer eyJ…            →  Bearer [REDACTED]
//   - Barkpark tokens:             bp_admin_…, bp_read_…  →  [REDACTED]
//   - secret-shaped assignments:   ANY *SECRET*/*TOKEN*/*PASSWORD*/*KEY*/… =…
//
// KEY NAMES always survive so a failed run stays diagnosable, and an
// angle-bracket placeholder value is passed through untouched.
func Patterns(s string) string {
	s = ectoUserinfoRe.ReplaceAllStringFunc(s, func(m string) string {
		// m is "<scheme>://user:pass@" — keep the scheme, redact the userinfo.
		scheme := m[:strings.Index(m, "://")]
		return scheme + "://" + Placeholder + "@"
	})
	s = bearerRe.ReplaceAllString(s, "Bearer "+Placeholder)
	s = bpTokenRe.ReplaceAllString(s, Placeholder)
	s = envSecretAssignRe.ReplaceAllStringFunc(s, func(m string) string {
		// The key part cannot contain '=', so the first one is the separator.
		i := strings.IndexByte(m, '=')
		key, value := m[:i], m[i+1:]
		if placeholderValueRe.MatchString(value) {
			// An instruction, not a credential — leave it readable.
			return m
		}
		return key + "=" + Placeholder
	})
	return s
}

// Line is the full scrub every caller should use: the literal secrets the caller
// registered, then the shape patterns. Literals run FIRST so a registered value
// is redacted whatever shape it happens to have.
func Line(s string, secrets []string) string {
	return Patterns(Literals(s, secrets))
}
