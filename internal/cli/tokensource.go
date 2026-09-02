package cli

// tokensource.go — WHICH credential did bp just use?
//
// The CLI folds five layers to pick a bearer token (resolveContext):
//
//	--token flag  >  env (BARKPARK_API_TOKEN, BARKPARK_TOKEN)  >  repo .barkpark.json
//	              >  saved config's active server  >  the baked dev default
//
// Every one of them ends up as the same opaque string in manifest.Context.Token,
// and until this file existed nothing downstream could say which layer produced
// it. That is not a cosmetic gap. A rejected `BARKPARK_TOKEN` left over in a
// shell SILENTLY outranks a perfectly good saved login: the server answers
// auth_tier "none", every manifest-driven noun vanishes from the tier-filtered
// tree, and `bp task ready` reports "command task exists but is hidden at your
// auth tier … run barkpark login" — sending the operator to redo a login they
// already have, while `bp whoami` reports `source: saved, token_present: true`
// and names nothing. (Measured 2026-09-01; it cost two agents a debugging round
// and put `env -u BARKPARK_TOKEN` into a standing brief as a workaround.)
//
// THE TOKEN VALUE NEVER APPEARS. The most any message prints is a ≤4-character
// tail, the shape cloud_site_preflight.go's D7 shadow message already uses, and
// only so an operator can tell two credentials apart.
//
// The labels are NOT re-derived next to the resolver — manifest.ResolveWithSources
// returns the winning layer from the same pick that chose the value, and
// resolveContextProv only translates that layer into a name a human can act on
// ("env" → which of the two env vars; "active" → repo file or saved config).

import (
	"fmt"
	"strings"
)

// Token source labels. These six strings are the contract `bp whoami -o json`
// publishes as `token_source`; a machine reader may switch on them.
const (
	tokenSourceFlag     = "flag"      // --token <tok>
	tokenSourceRepoFile = "repo-file" // .barkpark.json's server → a saved entry's token
	tokenSourceSaved    = "saved"     // ~/.config/barkpark/config.json (or a -s <name> entry)
	tokenSourceDefault  = "default"   // the baked dev floor (barkpark-dev-token)
	tokenSourceNone     = "none"      // no token at all — anonymous
	tokenSourceUnknown  = "unknown"   // a token whose provenance was never resolved
)

// tokenEnvSource renders the env-layer label for one env var name, e.g.
// "env:BARKPARK_TOKEN". The name is always one of TokenEnvNames.
func tokenEnvSource(name string) string { return "env:" + name }

// tokenProvenance is the answer to "which credential is this command using, and
// is it hiding a better one?". It is produced ONLY by resolveContextProv, beside
// the context it describes.
type tokenProvenance struct {
	// Source is one of the tokenSource* constants or tokenEnvSource(name).
	Source string
	// EnvVar is the env var that supplied the token, empty unless Source is an
	// env: label. It is the thing the fix hint tells the operator to unset.
	EnvVar string
	// Tail identifies the token WITHOUT disclosing it: "…" + its last 4 chars
	// (or "(set)" for a value too short to tail safely).
	Tail string

	// Alt names the layer holding a DIFFERENT, non-empty token for the SAME
	// resolved server — the credential that would be used if EnvVar were unset.
	// Empty when there is none, when the lower layer holds the same value, or
	// when it belongs to a different server (in which case no shadow is claimed:
	// a wrong accusation is worse than silence). Only ever set alongside EnvVar.
	Alt string
	// AltTail is Alt's token tail, same redaction as Tail.
	AltTail string
	// AltServer is the server Alt's token belongs to — printed so the operator
	// can see the two facts line up.
	AltServer string
}

// fromEnv reports whether the resolved token came out of the environment.
func (p tokenProvenance) fromEnv() bool { return p.EnvVar != "" }

// shadowsSaved reports the STRUCTURAL half of the env-shadows-config hazard: an
// env token won, and a different saved/repo-file token for the same server sits
// underneath it. It says nothing about whether the env token WORKS — the caller
// adds that half (auth_tier none, or a 401/403), because a working env token
// shadowing a saved one is a deliberate, correct override and must stay silent.
func (p tokenProvenance) shadowsSaved() bool { return p.fromEnv() && p.Alt != "" }

// label renders the source for display, never empty: an unresolved provenance
// says so rather than printing a blank where a fact belongs.
func (p tokenProvenance) label() string {
	if p.Source == "" {
		return tokenSourceUnknown
	}
	return p.Source
}

// describe renders "source (tail)" for a one-line credit, e.g.
// "env:BARKPARK_TOKEN (…-xyz)". The tail is omitted when unknown.
func (p tokenProvenance) describe() string {
	if p.Tail == "" {
		return p.label()
	}
	return p.label() + " (" + p.Tail + ")"
}

// shadowWarning is the line printed when an env token the server did not accept
// is standing in front of a saved credential for the same server. It names the
// env var, its tail, the server, and — via `reason` — HOW the caller learned the
// env token is not working. The reason is a parameter and not a baked sentence
// because the two triggers are genuinely different observations (a 401 refusal
// vs a 200 that reports auth_tier "none"), and a warning that asserts the wrong
// one teaches the reader to distrust the rest of it. Empty when the hazard does
// not hold — callers print nothing rather than a hedged sentence.
func (p tokenProvenance) shadowWarning(reason string) string {
	if !p.shadowsSaved() {
		return ""
	}
	return fmt.Sprintf(
		"%s is set in your shell (%s) and SHADOWED the %s credential for %s (%s) — %s",
		p.EnvVar, p.Tail, p.Alt, p.AltServer, p.AltTail, reason)
}

// Reasons a caller may hand shadowWarning. They are constants so the three call
// sites cannot each invent their own phrasing for the same observation.
const (
	shadowReasonRefused  = "the server REFUSED it (HTTP 401/403), so every command reads as hidden at your auth tier"
	shadowReasonTierNone = "the server reports auth_tier none for it, so every command reads as hidden at your auth tier"
)

// shadowFix is the remedy line that rides under shadowWarning: the literal
// commands that select the credential the operator meant.
func (p tokenProvenance) shadowFix() string {
	if !p.shadowsSaved() {
		return ""
	}
	return fmt.Sprintf(
		"fix: `unset %s` to use the %s credential, or choose one deliberately with `bp use <name>` / `--token <tok>`",
		p.EnvVar, p.Alt)
}

// tokenTail redacts a token down to an identifying tail: "…" plus its last four
// characters, or the bare word "(set)" when the value is too short for even that
// to be safe. This is the SAME redaction ambientTokenShadow (cloud_site_preflight.go)
// has used for the D7 message; both call here so the two can never disagree on
// how much of a credential a diagnostic may show.
func tokenTail(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if len(v) > 6 {
		return "…" + v[len(v)-4:]
	}
	return "(set)"
}
