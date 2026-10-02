package cli

// secret_unread_name_guard.go refuses a `bp secret set` whose NAME the
// instance runtime never reads out of the secret store.
//
// ── THE MEASUREMENT (task-512394bf1706afde, guerrilla 2026-09-17)
//
// `Barkpark.Secrets` is documented as a GENERAL encrypted store, and for an
// operator holding a credential for their own later retrieval that is exactly
// what it is. What it is NOT is a way to configure the running app: the only
// resolver in the whole api/ tree that reads a secret back by name is
//
//	api/lib/barkpark/secrets.ex           ingest_token/0  → get("ingest_token")
//
// reached from `api/lib/barkpark_web/plugs/require_ingest_token.ex`. Every
// other read of `Barkpark.Secrets` is the admin CRUD controller answering the
// operator's own `bp secret ls/get/set/rm`.
//
// The Anthropic credential the Studio chat title pass and the task judge need
// is read from the ENVIRONMENT, never from that store:
//
//	api/lib/barkpark/studio_chat/titles.ex:427  Application.get_env(:barkpark, :anthropic_api_key)
//	                                     :428     || System.get_env("ANTHROPIC_API_KEY")
//	api/lib/barkpark/tasks/judge.ex:226         Application.get_env(:barkpark, :anthropic_api_key)
//	                                     :227     || System.get_env("ANTHROPIC_API_KEY")
//
// So `bp secret set anthropic_api_key <key>` returned 200, wrote an encrypted
// row, and changed NOTHING about whether chat titles or the judge could reach
// Anthropic. Two ledger rows (ctx-b5-provision-count-tokens-key,
// task-cth-w1-dogfood) carried that write as the documented remedy, which sent
// the operator to a store nothing reads and left the feature dead with a green
// receipt in hand. A silently stored, never-read key is the failing state.
//
// ── THE RULE (a predicate over the route, not a list of verbs)
//
// The guard is keyed on the RESOLVED REQUEST — `PUT …/secrets/<name>` — the
// same choke-point shape claimed_draft_mutation_guard.go uses, so `secret set`,
// `secret scoped-set`, and any future door onto that route are covered by one
// check. The name is normalised (case, `-`/space → `_`) and looked up in
// envOnlySecretConsumers: the set of names whose VALUE the instance reads from
// its environment instead. That table is not curated by hand — TestEnvOnly…
// in secret_unread_name_guard_test.go greps api/ for every
// `System.get_env("…_API_KEY")` and fails if one is missing from it.
//
// The refusal names the environment variable, the file it belongs in, and the
// slot restart that makes it live. `--store-unread` is the escape hatch for the
// operator who genuinely wants the vault row anyway (it stays a vault row —
// the flag does not make anything read it), and the refusal says so.

import (
	"fmt"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// storeUnreadSecretFlag opts INTO writing a secret whose name nothing on the
// instance reads back. It is additive and CLI-only — the manifest never
// declares it, so it is stripped from tail before splitArgs sees it.
const storeUnreadSecretFlag = "--store-unread"

// envOnlySecretConsumers maps a NORMALISED secret name to the environment
// variable the instance actually reads that value from. Membership is the whole
// predicate: a name in here is provably configured through the environment, so
// a secret-store row of the same name is inert.
var envOnlySecretConsumers = map[string]string{
	"ANTHROPIC_API_KEY": "ANTHROPIC_API_KEY",
}

// normalizeSecretName folds the spellings an operator reaches for
// (`anthropic_api_key`, `anthropic-api-key`, `Anthropic Api Key`) onto the
// environment variable's own shape.
func normalizeSecretName(name string) string {
	repl := strings.NewReplacer("-", "_", " ", "_", ".", "_")
	return strings.ToUpper(repl.Replace(strings.TrimSpace(name)))
}

// secretRouteName returns the secret name a request STORES A VALUE under, and
// whether the request is such a write at all. Keyed on the path shape
// (`…/secrets/<name>`) plus a non-empty body, never on a command id and never
// on a method literal: the body is what distinguishes the write that lands a
// value (`secret set` / `scoped-set`, whose body is `{"value":…}`) from the
// bodyless reads and the bodyless `secret rm` — DELETING an inert row is a
// perfectly sensible thing to do and must never be refused.
func secretRouteName(req *manifestRequest) (string, bool) {
	if req == nil || len(req.body) == 0 {
		return "", false
	}
	switch strings.ToUpper(strings.TrimSpace(req.method)) {
	case "GET", "HEAD", "":
		return "", false
	}
	u, err := url.Parse(req.url)
	if err != nil {
		return "", false
	}
	segs := strings.Split(strings.Trim(u.EscapedPath(), "/"), "/")
	if len(segs) < 2 || segs[len(segs)-2] != "secrets" {
		return "", false
	}
	name, err := url.PathUnescape(segs[len(segs)-1])
	if err != nil || strings.TrimSpace(name) == "" {
		return "", false
	}
	return name, true
}

// unreadSecretRefusal is the message. It names the environment variable, the
// env FILES on the box, and the slot restart — the three things the operator
// has to do and the store write never did.
func unreadSecretRefusal(name, envVar string) string {
	return fmt.Sprintf(
		"`bp secret set %s` would store a row nothing reads. The instance reads %s from its ENVIRONMENT "+
			"(api/lib/barkpark/studio_chat/titles.ex and api/lib/barkpark/tasks/judge.ex both resolve "+
			"`Application.get_env(:barkpark, :anthropic_api_key) || System.get_env(%q)`), and the only name any "+
			"resolver reads back out of the secret store is `ingest_token`. "+
			"The remedy is to put %s= in the instance env file — /opt/barkpark/.env, and .slots/<slot>.env on a "+
			"slotted host — and then restart the slot (`systemctl restart barkpark-slot@<slot>`, or "+
			"`systemctl restart barkpark.service` on a single-slot box); a running BEAM never re-reads the file. "+
			"To keep the vault row anyway, knowing nothing will read it, re-run with %s.",
		name, envVar, envVar, envVar, storeUnreadSecretFlag)
}

// extractStoreUnreadSecretFlag strips storeUnreadSecretFlag out of tail.
func extractStoreUnreadSecretFlag(tail []string) (bool, []string) {
	found := false
	kept := make([]string, 0, len(tail))
	for _, a := range tail {
		if a == storeUnreadSecretFlag {
			found = true
			continue
		}
		kept = append(kept, a)
	}
	return found, kept
}

// storeUnreadSecretFlagApplies reports whether the opt-in should be stripped
// from this command's tail. Keyed on shape (a write command), and standing down
// for any command whose manifest already declares a flag of that name so the
// opt-in can never shadow a real server-declared one.
func storeUnreadSecretFlagApplies(cmd manifest.Command) bool {
	if !cmd.Writes {
		return false
	}
	return !commandDeclaresFlag(cmd, strings.TrimPrefix(storeUnreadSecretFlag, "--"))
}

// guardUnreadSecretName refuses a secret write whose name the instance reads
// from the environment instead. Returns (exit code, refused).
func guardUnreadSecretName(out *writer, req *manifestRequest, deliberate bool) (int, bool) {
	name, ok := secretRouteName(req)
	if !ok {
		return exitOK, false
	}
	envVar, inert := envOnlySecretConsumers[normalizeSecretName(name)]
	if !inert {
		return exitOK, false
	}
	if deliberate {
		// Say what the write will and will not do, rather than going quiet: the
		// row still lands, and still nothing reads it.
		out.errf("storing %q in the secret store — nothing on the instance reads it back (%s is read from the environment); %s was given.",
			name, envVar, storeUnreadSecretFlag)
		return exitOK, false
	}
	return useError(out, "unread_secret_name", unreadSecretRefusal(name, envVar), exitValidation), true
}
