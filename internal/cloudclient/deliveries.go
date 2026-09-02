package cloudclient

// deliveries.go is the wire side of `bp cloud deliveries <sha>`: the decoder for
// GET /v1/deliveries, the PLATFORM delivery record (BarkparkCloud.PlatformDelivery
// — one durable row per sha the platform delivered, the run that delivered it,
// and the clocks around it).
//
// IT IS NOT THE WEBHOOK DELIVERY LOG. `deliveries` is already a noun in this
// client family: `bp cloud webhook deliveries` proxies
// GET /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries, which is ONE
// TENANT's webhook send log. The schema's own moduledoc calls that collision out
// and renames its table `platform_deliveries` because of it. Everything here is
// named Platform* for the same reason, and the renderer prints the population on
// its header line so the two can never be confused on screen either.
//
// EVERY UNMEASURED FIELD IS A POINTER, AND nil MEANS UNMEASURED — NEVER 0 AND
// NEVER false. SEVEN of the fifteen wire keys are legitimately NULL on a live
// row: the four clocks (`merged_at`, `queued_seconds`, `build_seconds`,
// `serving_since`), the three queue-split columns (`queued_self_seconds`,
// `queued_pickup_seconds`, `queued_stall_seconds`) — and `carried`, which the
// schema deliberately declares with NO DEFAULT (charter D422) so an omitted
// value reads `nil`. The recorder writes NULL when a query it needs failed or
// when the fact does not exist, and the schema's law is "NULL, never 0".
// Decoding those into `int`/`string`/`bool` zero values would turn "nobody
// measured this" into "it took no time", "it never went live" into
// "1970-01-01", and "nobody measured whether this run belonged to this sha"
// into a confident "it did" — the precise class of comforting lie this epic
// exists to end, and `carried` is the one where the zero value is not merely
// wrong but ARGUES FOR ITSELF: false is a real, meaningful reading.
//
// `previous_sha` and `transition` are nullable as well and are counted with
// `carried` rather than with the seven clocks: they are a VERDICT about the move
// this row records, not a measurement of it, and their null says "no verdict was
// ever attempted" rather than "this interval went unmetered".
//
// A REFUSAL IS TYPED, NOT A ZERO PAGE. The route answers a 503
// {"error":"unavailable","reason":"platform_deliveries_missing","detail":…} when
// this control plane has not run the migration yet — an api-only merge deploys
// the instance leg without the cloud/ one, so this is a REAL, expected state and
// not a defensive branch. It must never decode to an empty page, which reads
// identically to "this sha delivered nothing".

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// PlatformDelivery is one row of the platform delivery record — exactly the
// FIFTEEN keys PlatformDelivery.to_json/1 emits, in its order.
//
// IT WAS THIRTEEN UNTIL dr-w27-s2, AND THE TWO MISSING ONES WERE THE ROLLBACK
// VERDICT. #11078 added `previous_sha` and `transition` to the serializer;
// nothing here followed, `json.Unmarshal` dropped both in silence, and a row
// whose transition was `rollback` rendered byte-identically to one that moved
// `forward`. Neither of the two exact key-count pins could see it — the Elixir
// one counts the Elixir side, the Go one counts a fixture — so the census pair
// in cloud/test/barkpark_cloud/payload_key_set_census_test.exs is what now reads
// both ends at once.
//
// PREVIOUSSHA AND TRANSITION ARE *string FOR THE SAME REASON CARRIED IS *bool.
// Both columns are NULLABLE with NO DATABASE DEFAULT (proved against
// information_schema in platform_delivery_test.exs), and a NULL `transition`
// says the writer NEVER ATTEMPTED a verdict — which is NOT the wire's own
// `"unknown"`, the word reserved for a writer that tried and could not decide (a
// gc'd sha, an unreachable box, a shallow clone). A plain `string` would decode
// both of those into ""; the renderer would then have one branch where the
// schema deliberately keeps two, and "never attempted" would read as "tried and
// failed" forever. The vocabulary is forward | rollback | diverged | noop |
// unknown, and it is deliberately NOT `commit_ancestry`'s words: this grades
// PREVIOUS-vs-NEW, that one grades BOX-vs-MAIN.
//
// SHA and DeliveringRunID together with Target are the row IDENTITY: ~36% of
// merged shas are CARRIED by a later sha's run, so one sha can legitimately have
// several rows and a reader must render all of them rather than "the" one.
//
// CARRIED IS A *bool AND THAT IS THE WHOLE POINT OF THIS TYPE. It has THREE
// states, not two:
//
//   - true — the run this row names does NOT belong to this sha. A later sha's
//     run swept it up, so QueuedSeconds/BuildSeconds measure THAT run's queue
//     and build, not this sha's.
//   - false — MEASURED as this sha's own run, so the seconds are this sha's.
//   - nil — NOBODY MEASURED IT. The schema declares `carried` with no default
//     (charter D422) precisely so a writer that does not know cannot record its
//     ignorance as a `false`, and a plain `bool` here would undo that at the
//     last hop: encoding/json decodes a JSON `null` into a `bool` as `false`,
//     silently converting "unrecorded" into the confident reading. When it is
//     nil the OWNERSHIP of every second on the row is unknown too — the seconds
//     themselves may be perfectly well measured and still belong to a run this
//     record cannot attribute.
//
// THE QUEUE SPLIT IS THREE NULLABLE INTEGERS BESIDE QueuedSeconds, NEVER
// INSTEAD OF IT (charter D430): Self (waiting on another deploy.yml run's
// build), Stall (residual co-incident with >= 2 other workflows created but
// unpicked) and Pickup, which is THE RESIDUAL — defined as what is left after
// the other two, never by a magnitude threshold. Each is independently nullable
// because each comes from its own query, and a failed query must read UNMETERED
// rather than contribute a 0 that makes the arithmetic look complete.
//
// RecordedAt is when the CONTROL PLANE wrote the row (inserted_at), which is
// strictly later than FirstSeenAt and is not a deploy clock at all. It is kept
// so a reader can tell "delivered long ago" from "recorded long after the fact"
// — the two look the same on any surface that prints only one of them.
type PlatformDelivery struct {
	SHA                 string  `json:"sha"`
	DeliveringRunID     string  `json:"delivering_run_id"`
	FirstSeenAt         string  `json:"first_seen_at"`
	MergedAt            *string `json:"merged_at"`
	QueuedSeconds       *int    `json:"queued_seconds"`
	QueuedSelfSeconds   *int    `json:"queued_self_seconds"`
	QueuedPickupSeconds *int    `json:"queued_pickup_seconds"`
	QueuedStallSeconds  *int    `json:"queued_stall_seconds"`
	BuildSeconds        *int    `json:"build_seconds"`
	ServingSince        *string `json:"serving_since"`
	Target              string  `json:"target"`
	Carried             *bool   `json:"carried"`
	PreviousSHA         *string `json:"previous_sha"`
	Transition          *string `json:"transition"`
	RecordedAt          string  `json:"recorded_at"`
}

// DeliveriesPage is the GET /v1/deliveries envelope: the rows, how many came
// back, the sha the control plane actually filtered on, the window it clamped
// to, and the POPULATION those rows were drawn from.
//
// SHA IS A POINTER because the route echoes back its own normalised filter and
// sends `null` when the caller named no sha at all. A "" would render as "sha "
// — a filter that looks pinned and is not.
//
// SCOPE IS NOT DECORATION AND IS DELIBERATELY NOT A POINTER-WITH-FALLBACK: the
// route sends the literal string "platform" on every 200 to say these rows are
// NOT team-filtered (a platform deploy has no site row and therefore no team_id
// to scope by). A reader that drops it invites the assumption that the page was
// narrowed to the caller's own fleet, which it never is. Empty means the control
// plane named no population and the renderer says so.
//
// Raw is the envelope bytes verbatim so `-o json` re-emits the contract rather
// than becoming a second, drifting definition of it (the emitDeployCensusRaw
// idiom).
type DeliveriesPage struct {
	Deliveries []PlatformDelivery `json:"deliveries"`
	Count      int                `json:"count"`
	SHA        *string            `json:"sha"`
	Limit      int                `json:"limit"`
	Scope      string             `json:"scope"`
	Raw        []byte             `json:"-"`
}

// DeliveriesError is a delivery record the control plane REFUSED to answer.
// Three shapes reach it:
//
//   - 401 {"error":"unauthorized"} — no credential, or a dead one. The route is
//     require_user_or_pat + require_ability("read"), so a PAT is enough; there
//     is no operator allowlist in this refusal and telling the caller to edit
//     PLATFORM_ADMIN_EMAILS would send them after a remedy that cannot work.
//   - 503 {"error":"unavailable","reason":"platform_deliveries_missing",
//     "detail":…} — this control plane has not run the platform_deliveries
//     migration. Reason is what makes this refusal actionable; Detail is the
//     route's own sentence and is printed verbatim rather than paraphrased.
//   - 500 {"error":"read_failed"} — the query itself failed; opaque by design.
//
// A caller MUST branch on this before reading Count, because a refusal body and
// a 200 body share zero keys: a nil-coalescing read renders "0 deliveries", i.e.
// a silent deploy, which is exactly the sentence this record exists to prevent.
type DeliveriesError struct {
	HTTPStatus int
	Code       string
	Reason     string
	Detail     string
	Raw        []byte
}

func (e *DeliveriesError) Error() string {
	msg := e.Code
	if msg == "" {
		msg = http.StatusText(e.HTTPStatus)
	}
	if e.Reason != "" {
		msg += " (" + e.Reason + ")"
	}
	if e.Detail != "" {
		msg += ": " + e.Detail
	}
	return msg
}

// PlatformDeliveries reads the platform delivery record via
// GET /v1/deliveries[?sha=][&limit=] (Bearer — a session, a PAT carrying ability
// "read", OR the faceless WORKER token; the route is deliberately not
// operator-gated, because a record only a browser session can read is a record
// no script can ever check).
//
// THE WORKER IS ON THAT LIST SINCE task-e2acb66e9ed0da09, and it is the
// principal that WRITES these rows (POST /v1/internal/platform-deliveries, which
// deploy.yml's crown step calls with WORKER_TOKEN and nothing else). Until then
// the route answered it 401, so `bp cloud deliveries <sha>` was dark for every
// CI caller and crown-reconcile read the table over SSH+psql instead.
//
// THIS CLIENT IS CREDENTIAL-AGNOSTIC AND MUST STAY SO. It sends `c.Token`
// verbatim as `Authorization: Bearer <token>` (client.go doWithHeaders) and
// makes no judgement about which of the three kinds it holds — so the verb
// works for whichever credential the caller configured the moment the ROUTE
// accepts it. Pinned by TestCloudDeliveriesSendsTheBearerItWasGiven.
//
// AN UNKNOWN SHA IS A 200 WITH AN EMPTY LIST, never a 404 — "nothing was ever
// recorded for this sha" is the single most useful thing this table can say
// about a deploy that went silent, and it arrives here as an empty page, not as
// an error. limit <= 0 sends no limit and lets the route apply its own default.
func (c *Client) PlatformDeliveries(ctx context.Context, sha string, limit int) (DeliveriesPage, error) {
	q := url.Values{}
	if s := strings.TrimSpace(sha); s != "" {
		q.Set("sha", strings.ToLower(s))
	}
	if limit > 0 {
		q.Set("limit", strconv.Itoa(limit))
	}
	path := "/v1/deliveries"
	if enc := q.Encode(); enc != "" {
		path += "?" + enc
	}
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return DeliveriesPage{}, err
	}
	if !ok(status) {
		return DeliveriesPage{}, deliveriesError(status, body)
	}
	var page DeliveriesPage
	if err := json.Unmarshal(body, &page); err != nil {
		return DeliveriesPage{}, fmt.Errorf("decode deliveries response: %w", err)
	}
	page.Raw = body
	return page, nil
}

// deliveriesError decodes a refusal envelope into the typed error. A body that
// does not decode at all still yields a typed error carrying the STATUS, so the
// reader keeps its "I could not look" branch even against a gateway HTML page.
func deliveriesError(status int, body []byte) error {
	var env struct {
		Error  string `json:"error"`
		Reason string `json:"reason"`
		Detail string `json:"detail"`
	}
	_ = json.Unmarshal(body, &env)
	return &DeliveriesError{
		HTTPStatus: status,
		Code:       strings.TrimSpace(env.Error),
		Reason:     strings.TrimSpace(env.Reason),
		Detail:     strings.TrimSpace(env.Detail),
		Raw:        body,
	}
}
