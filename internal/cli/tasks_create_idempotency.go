package cli

// tasks_create_idempotency.go — an Idempotency-Key on every leg of
// `bp task create`, one key PER LEG per invocation, and the narrow resend that
// key makes safe.
//
// THE HOLE THIS CLOSES. `bp task create` composes POST /v1/data/mutate/<dataset>
// itself (tasks_create_cmd.go → sendCreateTaskMutations, then the publish
// follow-up). Until this file, internal/ sent NO Idempotency-Key anywhere, and
// there was NO create retry:
//
//   - internal/cli/tasks_write_retry.go's ledgerWriteVerbs is a CLOSED set
//     (claim/next/close/stamp/pulse/release) attached at buildManifestRequest —
//     a seam `task create` never reaches, because it is a built-in that does not
//     go through the manifest dispatch;
//   - internal/apiclient/retry.go retries GETs only, and says why: "A 500 tells
//     you NOTHING about whether a write landed";
//   - run.go's 30s dispatchClientTimeout is a TIMEOUT, not a retry.
//
// So a 5xx or a dropped connection on the create leg ended the invocation in
// the ambiguous-write render (tasks_create_ambiguous_write.go): "the create
// request WAS SENT and may have landed", exit 9, and a human left to search by
// title. That render is CORRECT for a client that cannot ask again safely. This
// file makes asking again safe.
//
// THE SERVER HALF IS ALREADY LIVE (PR #16070, ea4fc7bc51): the mutate door is
// behind the :idempotent plug (api/lib/barkpark_web/plugs/idempotency.ex, wired
// at router.ex:2451). The key is CLAIMED before the handler runs and hashed over
// (raw_key, token_id, method, request_path); a completed request under a key
// replays its recorded response byte-identically with `Idempotency-Replay:
// true`; a concurrent one answers 409 idempotency_key_in_use without running the
// handler; a 5xx or a crash RELEASES the claim so a retry re-runs. That is
// exactly the safety precondition tasks_write_retry buys with a per-verb
// read-back — and create is the ONE ledger write with no server-assigned id to
// read back, which is why the header is the only way it can ever be retried.
//
// ONE POLICY, NOT TWO. tasks_write_retry.go warns, in its own words, that two
// retry policies on one request is the bug. There is no overlap here: this
// policy is attached ONLY to the built-in create/publish legs of `bp task
// create`, which carry no ledgerWrite policy and never can (ledgerWriteFor keys
// on a manifest command id and demands a worker_id-anchored read-back predicate;
// create has neither). `task.create` is deliberately NOT added to
// ledgerWriteVerbs — extending that map would attach a read-back-based policy to
// a request that has nothing to read back, on a dispatch path this verb does not
// use.
//
// NARROW ON PURPOSE. A resend fires only on a transport error/timeout, a 5xx, or
// the 409 that means our OWN earlier attempt still holds the claim — never on an
// ordinary 4xx, which is an ANSWER (the same refusal both sibling retry files
// state). Every attempt of one leg carries the SAME key, so a re-send of a
// request that DID commit is answered from the server's cache instead of writing
// a second row.

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"time"

	"github.com/FRIKKern/barkpark/internal/apierr"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// idempotencyHeader is the header name the mutate door reads.
const idempotencyHeader = "Idempotency-Key"

// newIdempotencyKey mints one key BASE per invocation: 128 bits of crypto/rand,
// hex. Per-INVOCATION: two invocations never share a base, and legKey below
// splits one base into the PER-LEG keys the plug's scope requires.
// crypto/rand.Read is documented never to return a short read without an error;
// a failing entropy source falls back to a time-seeded value rather than sending
// an empty key, because an empty key means NO idempotency at all (the plug skips
// the header when absent) and that is the pre-fix behaviour this file exists to
// remove.
func newIdempotencyKey() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		n := time.Now().UnixNano()
		for i := 0; i < 16; i++ {
			b[i] = byte(n >> (uint(i%8) * 8))
		}
	}
	return hex.EncodeToString(b[:])
}

// legKey derives the key for ONE leg of one invocation.
//
// WHY PER-LEG AND NOT ONE KEY FOR THE WHOLE INVOCATION. The plug hashes
// (raw_key, token_id, method, request_path) and NOTHING FROM THE BODY —
// plugs/idempotency.ex, `Idempotency.hash_key/4` and the moduledoc's key row). Both legs of `bp task create --publish` POST
// the SAME path (/v1/data/mutate/<dataset>); only the mutation in the body
// differs. So one key across both legs would make the publish request REPLAY the
// create's cached response, byte for byte, with `Idempotency-Replay: true` — the
// publish handler would never run, and bp would print a receipt for a row that
// is still an unclaimable `drafts.` twin. The replay is silent by design; nothing
// in the response body would say the publish had been skipped.
//
// Suffixing one random base is preferred over minting two independent randoms
// because it keeps the invocation VISIBLE on the wire: the two keys share a
// prefix, so a server-side log or a packet capture can tell "one invocation, two
// legs" from "two invocations", which is exactly the distinction an operator
// debugging a duplicate needs. Both halves of the requirement still hold — the
// legs differ, and two invocations never collide, because the base carries all
// 128 bits of entropy.
func legKey(base, leg string) string {
	if base == "" {
		return ""
	}
	return base + "-" + leg
}

// createResendAttempts is the TOTAL number of sends for one leg — one attempt
// plus two resends. Deliberately shorter than ledgerWriteRetries (4 total): each
// attempt here costs the full 30s client budget in the worst case, and a create
// is interactive.
const createResendAttempts = 3

// createResendDelays are the waits before resend 1 and 2. Indexed by the number
// of resends already made; the last entry repeats if the count ever grows.
var createResendDelays = []time.Duration{
	500 * time.Millisecond,
	1500 * time.Millisecond,
}

// createResendSleep is the clock seam. Tests replace it so the schedule is
// exercised without waiting for it.
var createResendSleep = time.Sleep

// keyedMutationSender is one send of one mutate batch under a named key.
type keyedMutationSender func(manifest.Context, []map[string]any, string) (int, []byte, error)

// idempotencyInUseCode is the plug's answer when a request already holds a fresh
// claim on this key (plugs/idempotency.ex → 409). On this path that request is
// almost always THIS invocation's own previous attempt, still committing on a
// connection we stopped listening to.
const idempotencyInUseCode = "idempotency_key_in_use"

// resendableMutateOutcome answers "should this leg be sent again?" for one
// attempt.
//
//   - a transport error (the connection died, or the 30s budget fired) and a 5xx
//     leave the outcome UNKNOWN, and both are shapes the server's claim RELEASES
//     for, so re-asking under the same key re-runs the handler;
//   - a 409 idempotency_key_in_use is the plug telling us our own earlier attempt
//     is STILL IN FLIGHT. Waiting and asking again is the whole point of the
//     header: the next answer is either the replayed success or a fresh run.
//     Treating it as a refusal would report "the server said no" about a write
//     that is at that moment committing.
//
// Every OTHER 4xx is an ANSWER — a validation refusal, a dedup wall — and
// repeating it is noise. A 2xx is done, replayed or not.
func resendableMutateOutcome(status int, body []byte, err error) bool {
	if err != nil {
		return true
	}
	if status >= 500 {
		return true
	}
	if status == http.StatusConflict {
		if env, ok := apierr.Parse(body); ok && env.Code == idempotencyInUseCode {
			return true
		}
	}
	return false
}

// THE REPLAY, AND WHY THERE IS NO CODE FOR IT HERE. When a resend meets a key
// the server has already served, the plug answers with the FIRST attempt's
// recorded status and body plus `Idempotency-Replay: true`. That answer needs no
// special handling and gets none: a replayed 2xx is a 2xx, and it is the
// STRONGEST outcome available on this path — it proves the earlier attempt
// landed AND that this one wrote nothing. So the invocation renders the ordinary
// receipt instead of the "WAS SENT and may have landed" caveat of
// tasks_create_ambiguous_write.go. That is the whole behavioural change, and it
// is asserted end-to-end by TestTaskCreateReplayedResendIsASuccessNotAnAmbiguity
// rather than by a header check, because what matters is the RENDERED outcome,
// not that the client read a header.

// sendMutationsIdempotent sends one leg under key, resending the SAME key on an
// unknown outcome. Returns the LAST attempt's status/body/err, so a leg that
// never succeeds lands in exactly the ambiguous-write render it landed in before
// this file existed — with the caveat still honest, because after
// createResendAttempts unknown outcomes nobody knows whether a row exists.
//
// It also returns how many attempts were made, which is what lets a caller say
// "3 attempts" instead of implying one.
func sendMutationsIdempotent(send keyedMutationSender, ctx manifest.Context, mutations []map[string]any, key string) (status int, body []byte, attempts int, err error) {
	for attempts = 1; ; attempts++ {
		status, body, err = send(ctx, mutations, key)
		if !resendableMutateOutcome(status, body, err) || attempts >= createResendAttempts {
			return status, body, attempts, err
		}
		d := createResendDelays[len(createResendDelays)-1]
		if i := attempts - 1; i < len(createResendDelays) {
			d = createResendDelays[i]
		}
		createResendSleep(d)
	}
}
