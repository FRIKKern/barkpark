package cli

import (
	"errors"
	"net/http"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// fleet_credential_refusal.go holds the ONE place bp decides what a failed
// GetCredentialsForTeam means — and, just as important, the place where bp
// stopped deciding who is ALLOWED to call it.
//
// WHAT THIS REPLACED (task-3f8604ba07cfac82). Both fleet paths used to answer a
// ROLE-BASED AFFORDANCE locally, before any request left the process:
//
//	if only.Team != nil && strings.EqualFold(strings.TrimSpace(only.Team.Role), "member") {
//	        … "your member role cannot retrieve its admin token" … return exitOK
//	}
//
// Three things were wrong with it, and only the first is obvious:
//
//  1. It FAILS OPEN on every role that is not literally "member". A nil Team is
//     the DEFAULT shape of the fleet list, and an empty Role is what the wire
//     sends when the field is absent — so an actual member whose row arrived in
//     either shape was walked straight into the credential fetch. The check that
//     was supposed to protect the member only fired when the payload happened to
//     spell the word.
//  2. It is the unverified NEGATION of the server's set. The control plane grants
//     this on owner|admin; "not member" is its complement only if the role
//     vocabulary is exactly those three, forever, and nothing anywhere asserted
//     that. It was the ninth local copy of "who may" in the product and the only
//     one in Go.
//  3. A genuine refusal was indistinguishable from a blip. The fall-through
//     printed the error with a bare %v and returned exitOK, so a 403 and a DNS
//     hiccup produced the same sentence and the same "re-run setup" hint.
//
// THE REMEDY IS THE CONSOLE'S: do not derive authority locally, ask, and let the
// refusal speak. Every role now reaches GetCredentialsForTeam and the SERVER
// states the outcome; classifyFleetCredentialError reads that outcome off the
// typed *cloudclient.CloudRefusal (#10086's decode) rather than off prose.
//
// The behaviour a reader should hold on to: a member is refused because the
// server refused, not because bp guessed — which means a member arriving with a
// nil Team or an empty Role is refused too, the case the old check dropped.

// fleetCredentialOutcome is what a failed GetCredentialsForTeam actually was.
type fleetCredentialOutcome int

const (
	// fleetCredTransport: nothing was decided. A timeout, a DNS failure, a 5xx —
	// the caller learned nothing about authority and must say so.
	fleetCredTransport fleetCredentialOutcome = iota
	// fleetCredNoAdminToken: the server answered, and the answer is that this
	// Barkpark has no stored admin token (an older or ip-only provision). Not a
	// refusal of the caller — a property of the box. Diverts to manual paste.
	fleetCredNoAdminToken
	// fleetCredForbidden: the server REFUSED this account. This is the branch the
	// deleted local check was trying to predict.
	fleetCredForbidden
)

// classifyFleetCredentialError sorts a GetCredentialsForTeam error into one of
// the three outcomes and returns the typed refusal when there was one.
//
// KEYED ON THE TYPED FACT, NOT THE SENTENCE. A refusal carries its status in
// CloudRefusal.HTTPStatus and its cause in .Code/.Reason; those are what decide
// here. The no_admin_token substring fallback is deliberate and narrow: it exists
// only for an error that never became a *CloudRefusal at all (a transport wrapper
// around a body the decoder could not read), so the pre-existing manual-paste
// divert cannot regress. It is a FALLBACK under a typed check, never the primary.
func classifyFleetCredentialError(err error) (fleetCredentialOutcome, *cloudclient.CloudRefusal) {
	if err == nil {
		return fleetCredTransport, nil
	}

	var refusal *cloudclient.CloudRefusal
	if errors.As(err, &refusal) {
		if fleetCredentialCodeIsNoAdminToken(refusal.Code) || fleetCredentialCodeIsNoAdminToken(refusal.Reason) {
			return fleetCredNoAdminToken, refusal
		}
		switch refusal.HTTPStatus {
		case http.StatusUnauthorized, http.StatusForbidden:
			return fleetCredForbidden, refusal
		case http.StatusNotFound:
			// A 404 on the credentials route with no no_admin_token slug is the
			// control plane declining to confirm the Barkpark exists for this
			// account — an authority answer wearing a not-found status, which is
			// how the platform hides rows a caller may not see.
			return fleetCredForbidden, refusal
		}
		return fleetCredTransport, refusal
	}

	if fleetCredentialCodeIsNoAdminToken(err.Error()) {
		return fleetCredNoAdminToken, nil
	}
	return fleetCredTransport, nil
}

func fleetCredentialCodeIsNoAdminToken(s string) bool {
	return strings.Contains(s, "no_admin_token")
}

// fleetRefusalSentence renders the SERVER's reason for refusing this account,
// with no locally-invented claim about the caller's role in it.
//
// Precedence is most-specific-first: the server's own human sentence (Detail),
// then the machine cause it named (Reason/Code) turned into a sentence, and only
// if the server said nothing usable does bp fall back to naming the status. The
// caller supplies the Barkpark and team so the line reads as a place, not a code.
func fleetRefusalSentence(b cloudclient.Barkpark, re *cloudclient.CloudRefusal) string {
	name := strings.TrimSpace(b.Name)
	if name == "" {
		name = "that Barkpark"
	}
	prefix := name + " belongs to " + fleetTeamName(b) + ", and the server refused your access"

	if re == nil {
		return prefix + "."
	}
	if detail := strings.TrimSpace(re.Detail); detail != "" {
		return prefix + ": " + detail
	}
	if cause := strings.TrimSpace(re.Reason); cause != "" {
		return prefix + " (" + cause + ")."
	}
	if code := strings.TrimSpace(re.Code); code != "" {
		return prefix + " (" + code + ")."
	}
	return prefix + "."
}

// fleetRefusalRequirement renders what the server said it WANTED, when it said
// so — the Required ability and the Scope it is scoped over. Empty when the
// server named neither, because an invented requirement is the defect this whole
// file exists to remove.
func fleetRefusalRequirement(re *cloudclient.CloudRefusal) string {
	if re == nil {
		return ""
	}
	required := strings.TrimSpace(re.Required)
	if required == "" {
		return ""
	}
	if scope := strings.TrimSpace(re.Scope); scope != "" {
		return "The server requires " + required + " on the " + scope + "."
	}
	return "The server requires " + required + "."
}

// fleetRefusalCLIHint is the terminal's half of a refusal when the control plane
// sent one (CloudRefusal.CLIHint). Kept separate from Detail on purpose — see the
// field's own contract note in internal/cloudclient.
func fleetRefusalCLIHint(re *cloudclient.CloudRefusal) string {
	if re == nil {
		return ""
	}
	return strings.TrimSpace(re.CLIHint)
}
