package cli

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE MEASUREMENT THIS FILE EXISTS FOR (prod, 2026-09-16).
//
//	GET http://89.167.28.206/v1/capabilities -> server.version "0.1.0", server.min_cli "1.0.0"
//	GET http://89.167.28.206/status.json     -> version "0.2.26.929", commit ca4534461
//
// Two separate facts, both verified against the live box:
//
//  1. server.version is a PLACEHOLDER. It is Application.spec(:barkpark, :vsn)
//     — the mix.exs project version, frozen at 0.1.0 — not the running
//     release. The honest oracle for "what is this box running" is
//     GET /status.json. Nothing in the CLI may branch on Server.Version; it is
//     display-only (see manifest.Server's doc comment).
//
//  2. server.min_cli was NOT a gate. It is a hardcoded literal "1.0.0" in the
//     server's default_server/0, it was decoded into manifest.Server.MinCLI,
//     and it was compared at ZERO call sites — an inert guard that read as
//     working. run.go's cliVersion comment even claimed a gate existed.
//
// The hazard in (2) is not "it never fires". It is that the obvious fix — wire
// min_cli up as a hard refusal — fires for EVERYBODY: every published bp
// release is tagged v0.2.x, which is strictly below the literal floor "1.0.0",
// so a blocking gate keyed on today's value refuses 100% of released clients.
// So the gate here is ADVISORY by construction: it reports, at the diagnostic
// surface where a human is already asking what a box can do, and it never
// blocks a command and never spams one. Its message names both versions and
// says what to do when no release can satisfy the floor, because with today's
// server value that is the actual situation.

// minCLIVerdict is the outcome of comparing this binary's version against the
// server-advertised floor.
type minCLIVerdict int

const (
	// minCLIUnknown: no comparison was possible, so no claim is made. Either
	// the manifest omits min_cli (an old or minimal server) or this binary is
	// a dev build with no release identity. Silence, never a green.
	minCLIUnknown minCLIVerdict = iota
	// minCLISatisfied: this binary is at or above the advertised floor.
	minCLISatisfied
	// minCLIBelow: this binary is strictly below the advertised floor.
	minCLIBelow
)

// minCLICheck compares cliVer against server.MinCLI.
//
// It returns a verdict and, for minCLIBelow ONLY, a non-empty actionable
// message. Satisfied and Unknown return "": a check that narrates its own
// success is noise, and a check that cannot compare must not imply it did.
func minCLICheck(server manifest.Server, cliVer string) (minCLIVerdict, string) {
	if server.MinCLI == nil || *server.MinCLI == "" {
		return minCLIUnknown, ""
	}
	if cliVer == "" || cliVer == "dev" {
		// A `go build` binary carries no release version, so it cannot be
		// placed relative to a floor. Reporting it as below would red every
		// developer build; reporting it as satisfied would be a lie.
		return minCLIUnknown, ""
	}
	floor := *server.MinCLI
	if compareVersions(cliVer, floor) >= 0 {
		return minCLISatisfied, ""
	}
	return minCLIBelow, fmt.Sprintf(
		"bp %s is below this server's advertised min_cli %s — run `bp upgrade`; "+
			"if no published release reaches %s, the server's min_cli is misconfigured "+
			"(it is a hardcoded literal, not derived from the running build)",
		cliVer, floor, floor)
}

// minCLINotice is minCLICheck's message for the current binary, or "" when
// there is nothing honest to say. This is the one seam callers use.
func minCLINotice(server manifest.Server) string {
	_, msg := minCLICheck(server, cliVersion)
	return msg
}
