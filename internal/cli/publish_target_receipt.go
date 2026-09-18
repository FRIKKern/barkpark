package cli

import (
	"fmt"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE TRAP THIS CLOSES (BP-ONB-18, onb-residue-onb18-target-mismatch-receipt).
// A publish reports success without ever naming WHERE the write landed, so a
// receipt produced against the wrong active context is byte-identical to one
// produced against the intended server. Reproduced 2026-09-18 against two local
// fake servers serving the same capabilities manifest, one saved context and
// one BARKPARK_SERVER override:
//
//	$ bp doc publish paper my-paper -q      # saved context → STAGING :8731
//	rev: 2
//	$ BARKPARK_SERVER=http://127.0.0.1:8732 bp doc publish paper my-paper -q
//	rev: 2                                   # PRODUCTION :8732
//
// Both wrote (the receiving servers logged the POST); both printed the same two
// tokens and exit 0. `rev:` is the WHOLE receipt, and a rev is minted per
// transaction by whichever server received it — it is not an identity, so it
// discriminates nothing. The author's only evidence of the target was the
// belief they started with.
//
// WHAT THIS NAMES, AND WHERE IT READS IT FROM. The line is derived from the
// REQUEST THAT WAS ACTUALLY SENT (manifestRequest.url), not from the resolved
// Context and not from a re-read. The Context is one precedence fold away from
// the wire, and a receipt that re-derives its own claim next to the code it
// describes is the drift this repo has been bitten by repeatedly; the request
// URL is the single artefact the POST was addressed with, so the line cannot
// say one server while the bytes went to another. The path rides along because
// the SAME wrong-context mistake mis-targets the dataset and the
// workspace/project scope, and they are all in that one string.
//
// SIBLING, NOT DUPLICATE. `bp bulldocs publish` answering a bare `rev:` while
// the paper landed under a slug the caller never typed was BP-ONB-17 (#18982,
// renderMinimal's `slug:` line): WHICH DOCUMENT. This is WHICH SERVER — the
// other half of the same receipt. The credential-pairing guard
// (cli.go, @canonical capability:bp-credential-server-pairing) warns when a
// SAVED token does not belong to the resolved server; it is silent in the case
// that matters here, where the saved context is simply the wrong one and the
// token matches it perfectly (arm T6 of the transcript above).
//
// STDERR IN EVERY OUTPUT SHAPE, like emitTaskRuling, emitPublishCiteAdvisory and
// emitMutatePerspective: `-o json` stays ONE byte-identical document, stdout is
// untouched for every pipeline reading the rev, and the exit code never moves.

// isPublishTargetCmd is a PREDICATE, not a list: any manifest command that
// declares itself a write and spells its verb `publish` gets the line, so a
// publish verb added to a future plugin inherits it without an edit here.
// Today that is doc/bulldocs/session publish.
func isPublishTargetCmd(cmd manifest.Command) bool {
	return cmd.Writes && cmd.Verb == "publish"
}

// publishTargetLine renders the one stderr line, or "" when the command is not
// a publish, the response was not a 2xx, or the request URL cannot be parsed
// into an absolute origin (in which case there is nothing honest to name and
// silence beats a guess).
func publishTargetLine(cmd manifest.Command, requestURL string, status int) string {
	if !isPublishTargetCmd(cmd) || status < 200 || status >= 300 {
		return ""
	}
	u, err := url.Parse(strings.TrimSpace(requestURL))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return ""
	}
	origin := u.Scheme + "://" + u.Host
	path := u.EscapedPath()
	if path == "" {
		return fmt.Sprintf("published to %s", origin)
	}
	return fmt.Sprintf("published to %s (%s %s)", origin, cmd.HTTP.Method, path)
}

// emitPublishTarget prints the line on stderr. Never touches stdout, never
// changes the exit code.
func emitPublishTarget(out *writer, cmd manifest.Command, requestURL string, status int) {
	if line := publishTargetLine(cmd, requestURL, status); line != "" {
		out.errf("bp: %s", line)
	}
}
