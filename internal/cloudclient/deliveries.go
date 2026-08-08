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
// EVERY CLOCK IS A POINTER, AND nil MEANS UNMETERED — NEVER 0. Four of the ten
// wire keys are legitimately NULL on a live row (`merged_at`, `queued_seconds`,
// `build_seconds`, `serving_since`): the recorder writes NULL when a query it
// needs failed or when the fact does not exist, and the schema's law is "NULL,
// never 0". Decoding those into `int`/`string` zero values would turn "nobody
// measured this" into "it took no time" and "it never went live" into
// "1970-01-01" — the precise class of comforting lie this epic exists to end.
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

// PlatformDelivery is one row of the platform delivery record — exactly the ten
// keys PlatformDelivery.to_json/1 emits, in its order.
//
// SHA and DeliveringRunID together with FirstSeenAt are the row IDENTITY: ~36%
// of merged shas are CARRIED by a later sha's run, so one sha can legitimately
// have several rows and a reader must render all of them rather than "the" one.
//
// Carried is the single most load-bearing boolean here. When it is true the run
// this row names does NOT belong to this sha: a later sha's run swept it up, and
// therefore QueuedSeconds/BuildSeconds measure THAT run's queue and build, not
// this sha's. A renderer that prints those numbers without saying so is
// attributing another commit's timings to this one.
//
// RecordedAt is when the CONTROL PLANE wrote the row (inserted_at), which is
// strictly later than FirstSeenAt and is not a deploy clock at all. It is kept
// so a reader can tell "delivered long ago" from "recorded long after the fact"
// — the two look the same on any surface that prints only one of them.
type PlatformDelivery struct {
	SHA             string  `json:"sha"`
	DeliveringRunID string  `json:"delivering_run_id"`
	FirstSeenAt     string  `json:"first_seen_at"`
	MergedAt        *string `json:"merged_at"`
	QueuedSeconds   *int    `json:"queued_seconds"`
	BuildSeconds    *int    `json:"build_seconds"`
	ServingSince    *string `json:"serving_since"`
	Target          string  `json:"target"`
	Carried         bool    `json:"carried"`
	RecordedAt      string  `json:"recorded_at"`
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
// GET /v1/deliveries[?sha=][&limit=] (Bearer — a session OR a PAT carrying
// ability "read"; the route is deliberately not operator-gated, because a record
// only a browser session can read is a record no script can ever check).
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
