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
// ── A CORRECTION, MEASURED 2026-09-17 ────────────────────────────────────────
//
// This block used to state the hazard in (2) as: "the obvious fix — wire
// min_cli up as a hard refusal — fires for EVERYBODY: every published bp
// release is tagged v0.2.x, which is strictly below the literal floor 1.0.0,
// so a blocking gate keyed on today's value refuses 100% of released clients."
//
// That is FALSE, and it is false in the direction that matters: it conflated
// two different tag series in this one repo.
//
//	v0.2.x      — the SERVER/api release series. status.json reports
//	              "0.2.26.929". No bp CLI binary ever carries one of these.
//	cli-v1.x.y  — the CLI release series. cli-release.yml:47 does
//	              `VERSION=${TAG#cli-v}` and upgrade.go resolves ONLY cli-v*
//	              tags (CutPrefix "cli-v"), so a released bp carries "1.21.0".
//
// Measured on this tree: `git tag -l 'cli-v*' | sed 's/cli-v//' | sort -V`
// lists 27 releases, oldest 1.1.0, newest 1.21.0, and ZERO below 1.0.0. So
// every published bp client SATISFIES the live floor, and minCLICheck has
// never returned minCLIBelow for a real released binary in production.
//
// The true state is therefore the OPPOSITE of what was written: the floor is
// not unreachable, it is already met by everyone — which is why the inert
// guard stayed silent, and why nobody noticed it was inert. A wrong reason for
// a correct behaviour is the most durable kind of wrong, because the behaviour
// keeps confirming it.
//
// WHAT STILL HOLDS, and why this stays ADVISORY: a dev build carries no
// release identity at all, and a floor that has never once been exercised must
// not have its first exercise be a refusal. It reports at the diagnostic
// surface where a human is already asking what a box can do, and at the
// freshness leg (serverFloorStaleness, below); it never blocks a command and
// never spams one. Its message still names both versions and still says what
// to do when no release can satisfy the floor, because that remains the right
// thing to say IF the floor is ever raised past the channel.

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

// ── THE ONE SIGNAL THAT COMES FROM OUTSIDE THE BINARY ────────────────────────
//
// dr-w10-bl-cli-release-channel-is-stale's standing problem, in its own words:
// "the instrument that would tell you your binary is lying lives inside the
// binary that is lying."
//
// Every freshness reading the CLI takes today is SELF-SOURCED. The release leg
// compares cliVersion against the newest cli-v* tag; channelStaleness
// (cli_staleness.go) diffs the build commit against origin/main. Both are blind
// to exactly the population the row is about — the `curl | sh` install with no
// checkout, whose only clock is a tag nobody cut. A binary cannot be the oracle
// for its own staleness.
//
// min_cli is the one field on the wire that is not self-sourced: the SERVER
// states it, the client did not choose it, and it already rides the
// capabilities manifest that an authenticated session fetches anyway. That
// makes it the carrier, and it makes the LISTENING half the half that must
// ship first — an installed binary cannot learn a new field after the fact,
// which is precisely why the stale population is stuck. Ship the ear now; the
// mouth is an api-side field change (see the c1 note on the row).
//
// WHAT IT DOES TODAY, measured rather than assumed (prod, 2026-09-17):
//
//	GET http://89.167.28.206/v1/capabilities -> server.min_cli "1.0.0"
//	git tag -l 'cli-v*' | sed 's/cli-v//' | sort -V -> 1.1.0 … 1.21.0, none < 1.0.0
//
// so serverFloorStaleness is SILENT against today's prod for every released
// client — and that silence is CORRECT, not a bug: the server is not currently
// claiming anybody is stale. It speaks the moment min_cli becomes a real
// statement about client currency, and it reaches binaries already installed,
// with no checkout and no upgrade.
//
// WHY IT OUTRANKS channelStaleness at the call site: a git reading can be
// absent (no checkout), taken against the wrong checkout, or unresolvable. A
// server declaration about THIS client is none of those. When both have
// something to say they agree in direction, so the order only decides which
// remedy is printed, and the one the operator cannot argue with wins.

// serverFloorStaleness withholds an about-to-be-printed `up_to_date: true` when
// the SERVER advertises a client floor this binary does not reach.
//
// It is consulted ONLY on the leg where the release comparison was about to
// return up-to-date, and it speaks ONLY on minCLIBelow — never on Unknown
// (no floor advertised, offline, or a dev build with no release identity) and
// never on Satisfied. An absence is never laundered into a verdict.
//
// latest is carried through unchanged so the receipt still reports which
// release the operator is on.
func serverFloorStaleness(server manifest.Server, latest string) (onbCLICheck, bool) {
	verdict, msg := minCLICheck(server, cliVersion)
	if verdict != minCLIBelow || msg == "" {
		return onbCLICheck{}, false
	}
	return onbCLICheck{
		Installed: cliVersion,
		Latest:    latest,
		Status:    onbCLIBehind,
		UpToDate:  onbBool(false),
		Detail: "SERVER FLOOR — the server you are talking to declares this client below its " +
			"advertised minimum, which the binary cannot know on its own: " + msg,
	}, true
}

// manifestServer is the nil-safe read of the already-fetched manifest's server
// block. A nil manifest — offline, unreachable target, or a surface that never
// fetched one — yields the zero Server, whose MinCLI is nil, which minCLICheck
// reports as Unknown. No network call is ever made here: every caller passes a
// manifest it already had.
func manifestServer(m *manifest.Manifest) manifest.Server {
	if m == nil {
		return manifest.Server{}
	}
	return m.Server
}
