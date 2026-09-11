package cli

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// refusedCredentialRefusal reports the refusal message for an invocation whose
// CONFIGURED credential the server has already told us it does not accept, or
// "" when there is nothing to refuse.
//
// THE DEFECT IT CLOSES (task-621bcf889e730f4c). `bp doc ls` and its tier-"none"
// siblings are public reads: authHeaders' floor used to send no credential at
// all for them, so with BARKPARK_TOKEN=not-a-real-token bp sent the garbage
// bearer to GET /v1/capabilities (server: auth_tier "none"), then sent the query
// read with NO Authorization header, and guerrilla answered it anonymously with
// 200. A credential the server would have refused with a 401 became a green,
// fully shaped listing at rc=0 — and every "read something, rc=0 ⇒ my token
// works" preflight in scripts/ inherited exactly that.
//
// Attaching the bearer (authHeaders, run.go) fixes the wire, and against a
// server that 401s a bad bearer it is already enough. This refusal is the
// CLIENT-SIDE half, and it fires one round-trip EARLIER on a fact the client
// already holds: the manifest's top-level auth_tier is the CALLER tier the
// server echoes back for the credential it just saw. `none` (or absent) while a
// token is present means "I do not know this credential" — so the honest answer
// is a named refusal, not a read whose result is silently the public corpus.
//
// THE CONTROL THIS MUST NOT BREAK: a caller with NO token is also tier "none",
// and that caller is entitled to read published documents anonymously. The
// token's PRESENCE is the whole discriminator; ctx.Token == "" never refuses.
//
// It is also skipped whenever --manifest/BARKPARK_MANIFEST supplies the
// manifest: a captured file legitimately carries whatever tier it was fetched
// at (load.go says so at length), and that copy is not evidence about the
// credential in this process's environment.
func refusedCredentialRefusal(g globals, ctx manifest.Context, m *manifest.Manifest) string {
	if ctx.Token == "" {
		return ""
	}
	if m == nil {
		return ""
	}
	if manifestOverridePath(g) != "" {
		return ""
	}
	// EXACTLY "none", never an ABSENT tier. The live server states the caller
	// tier on every /v1/capabilities answer — an anonymous or unrecognised
	// caller gets the literal "none" (manifest.Parse keeps it verbatim) — so
	// "none" is a server VERDICT about this credential. An empty string is the
	// absence of a verdict (a hand-built or older manifest that never carried
	// the field) and must not be read as one: inferring a refusal from silence
	// would refuse callers whose token is fine.
	if m.AuthTier != "none" {
		return ""
	}
	return fmt.Sprintf(
		"the configured API token was refused by %s — %s resolved auth_tier %q for it. "+
			"A present-but-refused credential is an error, not anonymity: this read is NOT falling through to an anonymous public answer. "+
			"Confirm with `bp whoami`, then fix the token (BARKPARK_API_TOKEN, or `bp setup --target connect --server %s --token <token>`) — "+
			"or unset it to read published documents anonymously on purpose.",
		ctx.Server, manifest.CapabilitiesPath, "none", ctx.Server)
}

// refusedCredentialCode is the envelope error code the refusal renders under.
// Distinct from "usage" — nothing about the invocation was malformed.
const refusedCredentialCode = "unauthorized"
