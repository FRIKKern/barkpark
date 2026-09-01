// Package cloudclient is a framework-free HTTP client for the Barkpark Cloud
// CONTROL PLANE — a separate service from the content API that apiclient talks
// to. Where apiclient is scoped to ONE content server (workspace/project/dataset
// routing, the dev bearer token), cloudclient is scoped to the user's whole
// Barkpark FLEET: it logs a user in, lists every Barkpark they own, connects a
// cloud provider, launches a server, and "goes live".
//
// It deliberately mirrors apiclient's idiom — a small struct carrying BaseURL +
// Token + an injectable *http.Client, requests built by hand with net/http, a
// Bearer auth header on every authed call, and an honest error decode that
// surfaces the control plane's {"error":...} message instead of swallowing it —
// but it shares no code and no types: the two clients answer to different
// services and must be free to drift.
//
// YAGNI by design (cloud-12b): no retries, no pagination, no websocket, no warm-
// pool poll. The 25 methods below are exactly the surface the user-facing `bp`
// Cloud commands drive; the real provisioning happens server-side and is
// reflected back in the returned Barkpark row.
package cloudclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// esc URL-encodes a single dynamic path segment (an id / siteID) before it is
// interpolated into a request path, mirroring apiclient's url.PathEscape
// hardening: ids are usually server-issued UUIDs, but user-typed args (e.g.
// `bp sites <id>`) containing /, ?, #, or a space would otherwise corrupt the
// route. No behavioral change for valid UUIDs.
func esc(s string) string { return url.PathEscape(s) }

// DefaultTimeout is the per-request HTTP timeout when Client.HTTP is nil and we
// construct the fallback client. Login + a fleet list are quick control-plane
// calls; 30s is generous headroom without hanging a CLI invocation forever.
const DefaultTimeout = 30 * time.Second

// DefaultBaseURL is the production control-plane URL the CLI defaults to when no
// --url flag and no saved CloudURL override it.
const DefaultBaseURL = "https://api.barkpark.cloud"

// Client talks to the Barkpark Cloud control plane. BaseURL is the control-plane
// root (no trailing slash needed — it is trimmed); Token is the user session
// token attached as a Bearer header to every authed call (empty for Login).
// HTTP is injectable so tests point it at an httptest.Server; a nil HTTP uses a
// lazily-built client with DefaultTimeout.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// Team identifies the membership that owns a Barkpark in a cross-team fleet
// response. It is omitted by the default, current-team list for compatibility.
type Team struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Slug string `json:"slug"`
	Role string `json:"role"`
}

// Barkpark is one registered server in the user's fleet, as returned by
// GET /v1/barkparks (and embedded in launch / go-live responses). The JSON tags
// match the control plane's serialization 1:1 — the two status axes
// (health_status / agent_status) are kept distinct on purpose.
//
// The lower block (suspended … deprovision_error) is the ADDITIVE set the
// attention-triage twin (`bp cloud status`, charter decision 15) needs: the
// list route's barkpark_json (cloud/lib/barkpark_cloud/web/router.ex) already
// merges these in — the billing-suspension axis (suspended/suspended_reason),
// the self-update verdict (update_state), and the provision/deprovision job
// statuses merged per-row. They are purely additive: a control plane that omits
// any of them decodes to the field's zero value, and no existing field is
// renamed, so `bp barkparks` and every current consumer are untouched.
type Barkpark struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Slug         string `json:"slug"`
	URL          string `json:"url"`
	Host         string `json:"host"`
	Mode         string `json:"mode"`
	HealthStatus string `json:"health_status"`
	AgentStatus  string `json:"agent_status"`
	Version      string `json:"version"`
	GitCommit    string `json:"git_commit"`
	LastSeenAt   string `json:"last_seen_at"`

	// GitCommitFirstSeenAt (dr-w22-bl) — when the control plane first saw this
	// box report the sha in GitCommit (RFC3339). The plane stamps it on the beat
	// where the reported sha DIFFERS from the one on the row; a steady box
	// beating the same sha every 60 s never re-stamps it.
	//
	// EMPTY IS UNMEASURED, NEVER "just now", and it is not rare: every row read
	// empty the day the column shipped, and a box that has not changed sha since
	// still does. A box whose stored sha was empty when a sha first arrived also
	// reads empty on purpose — that commit may have been running long before the
	// first beat carrying it reached us. Render the empty string as UNMETERED
	// (the word this package already uses for commit_distance) and never sort it
	// as fresh; an older control plane omits the key entirely and it decodes to
	// the same empty string, tolerantly.
	GitCommitFirstSeenAt string `json:"git_commit_first_seen_at"`
	TeamID       string `json:"team_id"`
	Team         *Team  `json:"team,omitempty"`
	InsertedAt   string `json:"inserted_at"`

	// Provider is the cloud the box runs on (hetzner/azure). The control plane
	// stamps it on every row (migration default 'hetzner', Decision 9); it is
	// IDENTITY only — the fleet table paints it through GenProviderMark, never as
	// a status voice. Empty on a pre-migration row → the PROVIDER cell blanks.
	Provider string `json:"provider"`

	// Additive (charter decision 15) — the triage-status axes.
	Suspended         bool   `json:"suspended"`
	SuspendedReason   string `json:"suspended_reason"`
	UpdateState       string `json:"update_state"`
	ProvisionStatus   string `json:"provision_status"`
	ProvisionError    string `json:"provision_error"`
	DeprovisionStatus string `json:"deprovision_status"`
	DeprovisionError  string `json:"deprovision_error"`

	// Self-update TRUTH (isu-w5) — the full version + policy the control plane
	// mirrors from each instance's own update verdict and the team's autoupdate
	// policy. These are purely ADDITIVE and DECODED TOLERANTLY: the emission ships
	// in the sibling isu-w5-canary-gated-fleet slice, so an older control plane
	// omits some or all of them and they decode to their zero value — never an
	// error. `UpdateState` (above) is the coarse verdict (current|behind|unknown);
	// these carry the detail behind it:
	//
	//   - UpdateRunningRelease / UpdateLatestRelease — the version the box is on
	//     and the newest blessed release (the "running → latest" the status view
	//     paints, with a behind marker when they differ). Empty until the CP
	//     emits them.
	//   - UpdateCheckedAt — when the CP last refreshed this instance's verdict
	//     (RFC3339). Empty on an older CP.
	//   - UpdateUnavailableReason — WHY the verdict is unknown, measured by the
	//     control plane at probe time ("identity_refused" when the box rejected
	//     our credential, a transport failure, an unparseable reply). Empty
	//     means the CP had no cause to record — never render it as "fine".
	//   - AutoupdateEnabled — a POINTER on purpose: nil means the CP said nothing
	//     (policy unknown — an older CP), so the status view shows no policy for
	//     the row instead of lying "off". A present false is a real opt-out; a
	//     present true is the auto-ride default. AutoupdatePaused is the temporary
	//     hold (absent → false, an honest "not paused"). PinnedRelease freezes the
	//     box at a version (empty → unpinned).
	//   - Channel — the release channel the box rides ("prod" / "staging").
	//     Empty until the CP emits it.
	UpdateRunningRelease    string `json:"update_running_release"`
	UpdateLatestRelease     string `json:"update_latest_release"`
	UpdateCheckedAt         string `json:"update_checked_at"`
	UpdateUnavailableReason string `json:"update_unavailable_reason"`
	AutoupdateEnabled       *bool  `json:"autoupdate_enabled"`
	AutoupdatePaused        bool   `json:"autoupdate_paused"`
	PinnedRelease           string `json:"pinned_release"`
	Channel                 string `json:"channel"`

	// COMMIT DISTANCE (dr-w24-s2) — the control plane's own measurement of the
	// commit the box actually serves, which is a DIFFERENT question from
	// `UpdateState` above. UpdateState is the box's release-TAG self-grade; these
	// three are one GitHub compare of the served sha against `main`. They
	// disagree in production right now: rows read commit_distance 2493 /
	// commit_ancestry "behind" / update_state "current", because no release tag
	// has been cut since 2026-07-08 — a box that reached the newest tag stays
	// `current` however far main runs ahead of it.
	//
	//   - CommitDistance — commits of `main` this box does NOT have. A POINTER on
	//     purpose, the AutoupdateEnabled *bool idiom: nil is UNMEASURED (an empty
	//     git_commit, a 404 on an unknown sha, or a rate-limit 403 — the shared
	//     HTTP client discards headers, so a budget refusal is indistinguishable
	//     from a missing sha and lands unknown). A plain int would render every
	//     one of those as 0 — "even with main" — which is the disease this field
	//     exists to cure, in a brand-new column.
	//   - CommitAncestry — unknown | current | behind | ahead_of_main | diverged.
	//     Empty means the CONTROL PLANE said nothing (a plane predating this
	//     emission), which is distinct from a plane that measured and got
	//     `unknown`.
	//   - CommitDistanceCheckedAt — when the plane last asked (RFC3339), so a
	//     consumer can age the reading. Empty on an older CP.
	CommitDistance          *int   `json:"commit_distance"`
	CommitAncestry          string `json:"commit_ancestry"`
	CommitDistanceCheckedAt string `json:"commit_distance_checked_at"`

	// On-demand VERIFY verdict (BP-ONB-09) — the cached headline of the last
	// golden-path probe run the control plane persisted onto the row. Purely
	// ADDITIVE and DECODED TOLERANTLY: an older control plane omits both and they
	// decode to their zero value — never an error.
	//
	//   - VerifiedReachable — a POINTER on purpose (mirrors AutoupdateEnabled):
	//     nil means the CP said nothing (never verified / older CP), so the fleet
	//     view shows no verify state instead of lying "unreachable". A present
	//     false is a real "last run was unreachable"; a present true is reachable.
	//   - LastVerifiedAt — when the suite last ran (RFC3339). Empty until the CP
	//     emits it.
	VerifiedReachable *bool  `json:"verify_reachable"`
	LastVerifiedAt    string `json:"last_verified_at"`

	// Pressure is the host's LIVE resource pressure off the latest health beat
	// (dr-w4-s4 put it on the wire; this field is what finally CONSUMES it).
	// A POINTER because a control plane that predates the block omits the key
	// entirely — nil means "this CP does not speak vitals", which is a different
	// fact from "the CP spoke and every vital was nil" (a box that has never
	// beaten, or an agent that predates the vitals beat). Neither may ever be
	// read as "measured, and it is fine".
	Pressure *Pressure `json:"pressure"`

	// QueuedDeployAgeSeconds is the age of the OLDEST `queued` container-site
	// deployment on this box (jpf-w1-queue-age-alarm, charter D6) — the raw
	// number `barkpark_json` serves so the CLIENT can own the stalled
	// threshold. A POINTER for the same honesty rule as Pressure: nil is both
	// "nothing queued" and "this CP predates the field", and neither may ever
	// read as stalled — the alarm arms only on a real number.
	QueuedDeployAgeSeconds *float64 `json:"queued_deploy_age_seconds"`
}

// Pressure is the host-pressure block a fleet row carries (`pressure` in
// GET /v1/barkparks). It is FLAT and every field is a POINTER: the control
// plane's honesty law (router.ex merge_pressure/2) renders an absent key and the
// agent's `-1` "probe not wired" sentinel ALIKE as null — UNMETERED — never 0,
// because a fabricated 0 reads as a perfectly idle machine. So nil here means
// exactly one thing: WE DID NOT MEASURE. A consumer branches on the values.
//
// The JSON tags are router.ex's `@unmetered_pressure` keys VERBATIM. Two of them
// — Load15 and Err5xxPerS — are landed by the sibling dr-w5-s2 slice and are
// absent from the payload until it merges; they decode to nil, which is already
// the correct reading (UNKNOWN), so this struct is forward-compatible with that
// merge and needs no change when it lands. That is a WIRE relationship, not a
// code dependency.
//
// Numeric fields are float64 across the board, including the byte counts and
// the core count: the control plane emits JSON numbers off agent-shaped jsonb,
// and an integer-typed field would hard-fail decoding on a `2.0` where a float
// silently accepts both.
type Pressure struct {
	CPUPercent      *float64 `json:"cpu_percent"`
	CPUCores        *float64 `json:"cpu_cores"`
	MemUsedPercent  *float64 `json:"mem_used_percent"`
	Load1           *float64 `json:"load1"`
	Load15          *float64 `json:"load15"`
	DiskUsedPercent *float64 `json:"disk_used_percent"`
	SwapUsedPercent *float64 `json:"swap_used_percent"`
	SwapTotalBytes  *float64 `json:"swap_total_bytes"`
	BeamPSSBytes    *float64 `json:"beam_pss_bytes"`
	BeamSwapBytes   *float64 `json:"beam_swap_bytes"`
	// BeamPID and BeamSlot attribute the two beam figures above to the process
	// they were read from. The box runs blue/green and two beam.smp processes
	// coexist during a cutover, so without these a consumer cannot tell a real
	// footprint change from the probe switching subject: a beam_swap series
	// stepping 0 → ~190 MB across a flip is TWO PROCESSES, not a leak. Nil on a
	// box whose agent predates the attribution, empty-string when the box is
	// not slotted — both mean "not attributable", never a guess.
	BeamPID    *string  `json:"beam_pid"`
	BeamSlot   *string  `json:"beam_slot"`
	Err5xxPerS *float64 `json:"err_5xx_per_s"`
	// RunawayProcs names the box's long-running ORPHANED processes — the only
	// field in this block that answers WHO rather than HOW MUCH. Every scalar
	// above is an aggregate: they can say a box is at load 6.3 and can never say
	// that 66.3% of a core has gone to one abandoned `journalctl` for 2h46m,
	// which is the fact that ended the 2026-08-06 guerrilla outage once a human
	// finally looked.
	//
	// Being a LIST, it carries the same three-state honesty the pointers do, by
	// a different mechanism: nil (the CP sent `null`) is UNMEASURED — an agent
	// predating the probe, or a box without `ps`; a NON-NIL EMPTY slice (`[]`) is
	// MEASURED AND QUIET. `len() == 0` is true of both, so a consumer that means
	// "we looked and it is clean" must test for non-nil, not for empty.
	RunawayProcs []RunawayProc `json:"runaway_procs"`
	// SlotUnits is the state of the box's blue/green SYSTEMD UNITS — the only
	// field on this block that is about the DEPLOY PAIR rather than the host, and
	// the one whose absence let `bp cloud status` call a box healthy while half
	// of it sat in `failed`. Every scalar above is a host aggregate; none of them
	// can be wrong about a dead slot because none of them can see one.
	//
	// It carries the same three-state honesty RunawayProcs does, by the same
	// mechanism: nil (the CP sent `null`) is UNMEASURED — an agent predating the
	// probe, or a box with no systemd; a NON-NIL EMPTY slice is MEASURED AND
	// INTACT. `len() == 0` is true of both.
	SlotUnits []SlotUnit `json:"slot_units"`
	// SlotUnitsTruncated is how many failed SITE units the agent's cap hid. nil
	// is unmeasured, a measured 0 means the list above is complete. The
	// blue/green pair is never truncated, so this can never hide a slot unit.
	SlotUnitsTruncated *float64 `json:"slot_units_truncated"`
	// ReportedAt is the BEAT's own timestamp (RFC3339), a pointer for the same
	// reason: null means the box has never phoned home at all, which is not the
	// same as "beat, but told us nothing readable".
	ReportedAt *string `json:"reported_at"`
}

// RunawayProc is one long-running orphaned process off a fleet row's pressure
// block: the pid, how long it has been alive, the CPU share it has averaged over
// that whole life, and the argv that identifies it.
//
// The command is the field that turns this from a statistic into an action — an
// operator kills `journalctl -u bp-site-build-*`, never "pid 3369344" — and it
// arrives already capped by the agent so the beat payload stays bounded.
//
// The numerics are float64 for the same reason every number in Pressure is: the
// control plane emits JSON off agent-shaped jsonb, and an int-typed field would
// hard-fail decoding on a `3369344.0`. The control plane drops any row missing
// one of the four, so a row that decodes is complete.
type RunawayProc struct {
	PID        float64 `json:"pid"`
	ElapsedS   float64 `json:"elapsed_s"`
	CPUPercent float64 `json:"cpu_percent"`
	Command    string  `json:"command"`
}

// SlotUnit is ONE systemd unit off a fleet row's pressure block: systemd's own
// properties, relayed by the control plane, never a verdict. The consumer owns
// the verdict, because it cannot be made from one unit alone — a `failed` blue
// beside a serving green is a degraded pair on a box that IS serving, and
// `failed` on both while health says up is a contradiction. Those are different
// sentences and only a reader holding the whole list can tell them apart.
//
// Result and ExecMainStatus are read TOGETHER or not at all. Measured on
// guerrilla 2026-09-01: barkpark-site@search__b reads Result "exit-code" with
// ExecMainStatus 143 — 128+15, i.e. Next.js exiting on the SIGTERM of its own
// retire, filed by systemd as an exit code because the unit lacks
// SuccessExitStatus=143 (PR #14863). `result` alone reads a deliberate stop as
// a crash.
//
// The pointers carry the same law as every pointer in Pressure: nil is "the
// control plane could not read this property", never a fabricated 0 — and a pid
// 0 is a REAL, different fact (the unit claims a state with no main process).
type SlotUnit struct {
	Unit           string   `json:"unit"`
	ActiveState    string   `json:"active_state"`
	SubState       string   `json:"sub_state"`
	Result         *string  `json:"result"`
	MainPID        *float64 `json:"main_pid"`
	ExecMainStatus *float64 `json:"exec_main_status"`
	// StateSince is systemd's own timestamp string for the unit's last state
	// change, VERBATIM (e.g. "Tue 2026-09-01 11:07:52 UTC") — not RFC3339, not
	// reformatted. nil on a unit systemd has no timestamp for, which is what a
	// never-started unit reports.
	StateSince *string `json:"state_since"`
}

// Provider is a connected cloud account (e.g. a Hetzner token) the control plane
// can provision Barkparks into, as returned by POST /v1/providers. The token is
// never echoed back — only the metadata the user can safely see.
type Provider struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	Label      string `json:"label"`
	TeamID     string `json:"team_id"`
	InsertedAt string `json:"inserted_at"`
}

// LoginResp is the body of a successful POST /v1/auth/login: the plaintext user
// session token to store, and the team the user belongs to (null → empty when
// the user has no team yet).
type LoginResp struct {
	Token  string `json:"token"`
	TeamID string `json:"team_id"`
}

// CheckoutResp is the body of a successful POST /v1/billing/checkout: the hosted
// checkout URL the customer opens in a browser to add a card and activate a
// subscription. The control plane resolves the price id for the requested plan
// and binds the session to the AUTHED user's team — the team is never client-
// supplied, so this envelope carries only the URL.
type CheckoutResp struct {
	CheckoutURL string `json:"checkout_url"`
}

// httpClient returns the configured *http.Client, or a lazily-built one with the
// default timeout. Tests always inject HTTP, so the fallback is the real-CLI
// path only.
func (c *Client) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: DefaultTimeout}
}

// url joins the (trimmed) BaseURL with a leading-slash path segment. It is the
// single place that knows the control-plane URL scheme — there is no workspace/
// project routing here, unlike apiclient.scopedURL.
func (c *Client) url(path string) string {
	return strings.TrimRight(c.BaseURL, "/") + path
}

// do issues one control-plane request: it marshals body (when non-nil) to JSON,
// attaches the Bearer token when auth is true, and returns the decoded status +
// response body. It is the shared core all five methods route through, mirroring
// apiclient's hand-built net/http requests.
func (c *Client) do(ctx context.Context, method, path string, auth bool, body any) (int, []byte, error) {
	return c.doWithHeaders(ctx, method, path, auth, body, nil)
}

// doWithHeaders is do plus a small explicit header seam for calls whose
// authorization context cannot be inferred from the saved primary team.
func (c *Client) doWithHeaders(ctx context.Context, method, path string, auth bool, body any, headers http.Header) (int, []byte, error) {
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, fmt.Errorf("marshal request: %w", err)
		}
		rdr = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.url(path), rdr)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if auth && c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	for name, values := range headers {
		for _, value := range values {
			req.Header.Add(name, value)
		}
	}

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, raw, nil
}

// CloudRefusal is a control-plane refusal WITH the evidence it carried, instead
// of the bare slug the CLI used to print. The control plane names four things
// beyond the machine code: `detail` (the human sentence), `reason` (the CAUSE an
// authority gate refused for — "no_team", "role"), `required` (the ability or
// role it wanted) with its `scope`, and `details` (the per-field map a 422
// validation failure carries). None of them were decoded, so a user got one word
// and no CLI branch could tell a caller who has NO TEAM from one with the wrong
// ROLE — which is exactly what breaks when a gate re-classifies a refusal's
// STATUS (422 {"error":"no_team"} -> 403 {"error":"forbidden","reason":"no_team"}):
// a status-keyed ladder silently changes both the sentence and the exit code
// while every test stays green.
//
// Error() is the SAME one-line message cloudError has always produced (plus the
// evidence, when the server sent any), so every existing caller keeps its
// contract — notably the "unauthorized:" prefix cloudFail keys on. The typed
// fields are additive and read with errors.As.
type CloudRefusal struct {
	HTTPStatus int
	Code       string // the `error` slug
	Detail     string // the server's human sentence
	Reason     string // the CAUSE a gate named (no_team, role, …)
	Required   string // the ability/role the gate wanted
	Scope      string // what Required is scoped over (team, instance, …)
	Details    map[string]string
	// ReadableTypes is the STRUCTURED menu POST /v1/sites emits alongside a
	// `content_binding_empty` refusal: the list of `{type, count?}` rows the
	// site's own read token can actually see (router.ex maybe_put_menu →
	// menu_row/1), `count` OMITTED when the site's probe reported no total. The
	// console already renders this list (siteReadableTypesMenu); the CLI dropped
	// it — cloudError decoded `detail` (which carries a PROSE copy of the menu)
	// but never the machine-readable array, so a script consuming -o json got the
	// slug and the sentence but no list it could parse. Decoded rows with an
	// empty `type` are dropped, mirroring the console's junk-drop.
	ReadableTypes []ReadableType
	// ReadableTypesRaw is the readable-types array serialized for the -o json
	// envelope's error.details.readable_types. It carries the SAME rows as
	// ReadableTypes (junk rows already dropped) with the server's row ORDER intact
	// and the `type`-before-`count` key order fixed by the struct tags — a stable
	// fingerprint, never a Go map that would alphabetize the keys. Empty when the
	// body sent no usable menu.
	ReadableTypesRaw json.RawMessage
	msg              string
}

// ReadableType is one row of the readable-types menu a `content_binding_empty`
// refusal carries: the type a site's read token can see, with the box's published
// TOTAL for it when a probe produced one. Count is a POINTER because absent and
// zero are different facts — a type with no proven magnitude is listed bare, and a
// fabricated 0 would be a lie the server deliberately declines to tell.
type ReadableType struct {
	Type  string `json:"type"`
	Count *int   `json:"count,omitempty"`
}

func (e *CloudRefusal) Error() string { return e.msg }

// cloudError turns a non-2xx control-plane response into a typed *CloudRefusal
// whose message is one line, surfacing the {"error":"<message>"} field the API
// returns (e.g. "name_required" from a 422 go-live, or an auth message from a
// 401) plus the refusal evidence the body carried. When the body carries no
// recognisable error field it falls back to "status <code>: <clamped body>" so
// nothing is ever swallowed. A 401 is prefixed with "unauthorized:" so callers
// (and users) read the auth failure plainly.
func cloudError(status int, body []byte) error {
	ref := &CloudRefusal{HTTPStatus: status}
	var env struct {
		Error string `json:"error"`
	}
	msg := ""
	if json.Unmarshal(body, &env) == nil && env.Error != "" {
		msg = env.Error
		ref.Code = env.Error
		// The control plane puts the machine CODE in `error` and the human
		// SENTENCE in `detail` — which box refused, what it said, and which flag
		// fixes it ("acme refused to mint the site's read token (HTTP 403):
		// forbidden"; "bind it with --dataset <workspace>/<project>/<dataset>").
		// Dropping `detail` reduced every one of those to a bare slug the user
		// cannot act on. Decoded SEPARATELY so a route that sends a non-string
		// `detail` (an object) degrades to the code alone rather than poisoning
		// the whole decode and falling back to a raw body dump.
		var det struct {
			Detail string `json:"detail"`
		}
		if json.Unmarshal(body, &det) == nil {
			if d := strings.TrimSpace(det.Detail); d != "" {
				ref.Detail = d
				msg = msg + ": " + d
			}
		}
		// The refusal evidence, each field in its OWN Unmarshal for the SAME
		// reason `detail` is: one route sending one of them as an object (a
		// `reason` map, a `details` list) must cost that ONE field, never the
		// whole decode.
		var rsn struct {
			Reason string `json:"reason"`
		}
		if json.Unmarshal(body, &rsn) == nil {
			ref.Reason = strings.TrimSpace(rsn.Reason)
		}
		var req struct {
			Required string `json:"required"`
		}
		if json.Unmarshal(body, &req) == nil {
			ref.Required = strings.TrimSpace(req.Required)
		}
		var scp struct {
			Scope string `json:"scope"`
		}
		if json.Unmarshal(body, &scp) == nil {
			ref.Scope = strings.TrimSpace(scp.Scope)
		}
		var dts struct {
			Details map[string]json.RawMessage `json:"details"`
		}
		if json.Unmarshal(body, &dts) == nil && len(dts.Details) > 0 {
			ref.Details = flattenDetails(dts.Details)
		}
		// The readable-types menu, in its OWN isolated Unmarshal for the same
		// reason every field above is: a route that sends `readable_types` as an
		// unexpected shape must cost that ONE field, never the whole decode. The
		// raw array bytes are kept for the machine envelope (order-preserving) and
		// the decoded rows drive the human menu; a row with an empty `type` is
		// dropped, so a partly-malformed list still yields whatever is usable.
		var rtm struct {
			ReadableTypes json.RawMessage `json:"readable_types"`
		}
		if json.Unmarshal(body, &rtm) == nil && len(rtm.ReadableTypes) > 0 {
			var rows []ReadableType
			if json.Unmarshal(rtm.ReadableTypes, &rows) == nil {
				clean := make([]ReadableType, 0, len(rows))
				for _, r := range rows {
					if strings.TrimSpace(r.Type) != "" {
						clean = append(clean, r)
					}
				}
				if len(clean) > 0 {
					ref.ReadableTypes = clean
					if b, mErr := json.Marshal(clean); mErr == nil {
						ref.ReadableTypesRaw = b
					}
				}
			}
		}
		if ev := ref.evidence(); ev != "" {
			msg = msg + " (" + ev + ")"
		}
	}
	if msg == "" {
		raw := strings.TrimSpace(string(body))
		if r := []rune(raw); len(r) > 200 {
			raw = string(r[:200]) + "…"
		}
		if raw == "" {
			msg = http.StatusText(status)
		} else {
			msg = raw
		}
	}
	if status == http.StatusUnauthorized {
		msg = "unauthorized: " + msg
	}
	ref.msg = msg
	return ref
}

// evidence renders the refusal fields the CODE alone cannot carry, in a stable
// order (cause, then what was required and over what, then the offending
// fields). Empty when the server sent none — a body without evidence must read
// EXACTLY as it always has.
func (e *CloudRefusal) evidence() string {
	parts := make([]string, 0, 4+len(e.Details))
	if e.Reason != "" {
		parts = append(parts, "reason: "+e.Reason)
	}
	if e.Required != "" {
		parts = append(parts, "required: "+e.Required)
	}
	if e.Scope != "" {
		parts = append(parts, "scope: "+e.Scope)
	}
	keys := make([]string, 0, len(e.Details))
	for k := range e.Details {
		keys = append(keys, k)
	}
	// Sorted so one refusal never prints two ways across runs (Go map order is
	// deliberately random) — an unstable error line is untestable and unreadable.
	sort.Strings(keys)
	for _, k := range keys {
		parts = append(parts, k+": "+e.Details[k])
	}
	return strings.Join(parts, "; ")
}

// flattenDetails renders the per-field `details` map a 422 carries. A value is
// a string ("is required") or a LIST of strings (the Ecto changeset shape,
// {"slug":["is taken","is too long"]}); anything else keeps its compact JSON so
// an unforeseen shape degrades to something readable rather than vanishing.
func flattenDetails(raw map[string]json.RawMessage) map[string]string {
	out := make(map[string]string, len(raw))
	for k, v := range raw {
		var s string
		if json.Unmarshal(v, &s) == nil {
			out[k] = s
			continue
		}
		var list []string
		if json.Unmarshal(v, &list) == nil {
			out[k] = strings.Join(list, ", ")
			continue
		}
		out[k] = string(v)
	}
	return out
}

// ok reports whether status is a 2xx.
func ok(status int) bool { return status >= 200 && status < 300 }

// Login exchanges email + password for a user session token via
// POST /v1/auth/login. It is the only UNauthed method — there is no token yet.
// A 401 (or any non-2xx) surfaces an honest auth error; a 200 decodes the token
// + team the caller stores in config.
func (c *Client) Login(ctx context.Context, email, password string) (LoginResp, error) {
	status, body, err := c.do(ctx, "POST", "/v1/auth/login", false, map[string]string{
		"email":    email,
		"password": password,
	})
	if err != nil {
		return LoginResp{}, err
	}
	if !ok(status) {
		return LoginResp{}, cloudError(status, body)
	}
	var out LoginResp
	if err := json.Unmarshal(body, &out); err != nil {
		return LoginResp{}, fmt.Errorf("decode login response: %w", err)
	}
	return out, nil
}

// Register creates a new account via POST /v1/auth/register and logs the user in
// in one shot: the control plane creates the user, a team (team defaults from the
// email local-part when team is ""), an owner membership, and a session token,
// then returns the same {token, team_id} envelope as Login. It is the second
// UNauthed method — like Login there is no token yet, so no Bearer is sent.
//
// team is sent as team_name only when non-empty (an empty value lets the server
// derive the default slug). A 201 decodes the token + team the caller stores in
// config; a non-2xx surfaces the control plane's honest error verbatim — 409
// "email_taken" (the address is registered), 422 "<field>_invalid" /
// "validation_failed" (weak password / bad email). cloudError carries each
// message through, so the CLI can match on it.
func (c *Client) Register(ctx context.Context, email, password, team string) (LoginResp, error) {
	req := map[string]string{"email": email, "password": password}
	if team != "" {
		req["team_name"] = team
	}
	status, body, err := c.do(ctx, "POST", "/v1/auth/register", false, req)
	if err != nil {
		return LoginResp{}, err
	}
	if !ok(status) {
		return LoginResp{}, cloudError(status, body)
	}
	var out LoginResp
	if err := json.Unmarshal(body, &out); err != nil {
		return LoginResp{}, fmt.Errorf("decode register response: %w", err)
	}
	return out, nil
}

// DeviceStartResp is the body of a successful POST /v1/auth/device/start — the
// opening leg of the copy-a-link browser login (RFC 8628 device-authorization,
// charter decision 10). The control plane mints a single-use, short-TTL code
// pair: DeviceCode is the OPAQUE secret the CLI polls with (never shown to the
// user); UserCode is the short human code the user types on the approve page
// (formatted XXXX-XXXX server-side). VerificationURI is the bare approve page;
// VerificationURIComplete embeds the code so opening it prefills the form.
// Interval is the minimum poll spacing in seconds; ExpiresIn is the code's TTL.
// No token rides here — that only arrives once the user approves (DevicePoll).
type DeviceStartResp struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	Interval                int    `json:"interval"`
	ExpiresIn               int    `json:"expires_in"`
}

// DevicePollStatus discriminates a device-poll response's NON-error outcome: the
// user has not acted yet (Pending), the CLI is polling too fast and must back off
// (SlowDown), or the user approved and a token is present (Approved). A terminal
// refusal (denied / expired / unauthorized) is NOT a status — it surfaces as a Go
// error from DevicePoll so the caller stops the loop.
type DevicePollStatus int

const (
	DevicePollPending  DevicePollStatus = iota // authorization_pending — keep waiting
	DevicePollSlowDown                         // slow_down — widen the interval
	DevicePollApproved                         // approved — Login carries the token
)

// DevicePollResult is one device-poll outcome. On DevicePollApproved, Login
// carries the SAME {token, team_id} envelope a password Login returns, so the
// caller stores it identically. On Pending/SlowDown, Login is the zero value.
type DevicePollResult struct {
	Status DevicePollStatus
	Login  LoginResp
}

// DeviceStart opens a device-authorization session via POST /v1/auth/device/start
// (charter decision 10). It is UNauthed — there is no token yet — mirroring
// Login. clientName is a human label for the pending grant ("bp on <hostname>")
// shown on the approve page; it is sent only when non-empty. A 200 decodes the
// code pair + poll interval the caller renders and polls with; a non-2xx surfaces
// the control plane's honest error verbatim (e.g. a 429 rate-limit).
func (c *Client) DeviceStart(ctx context.Context, clientName string) (DeviceStartResp, error) {
	req := map[string]string{}
	if clientName != "" {
		req["client_name"] = clientName
	}
	status, body, err := c.do(ctx, "POST", "/v1/auth/device/start", false, req)
	if err != nil {
		return DeviceStartResp{}, err
	}
	if !ok(status) {
		return DeviceStartResp{}, cloudError(status, body)
	}
	var out DeviceStartResp
	if err := json.Unmarshal(body, &out); err != nil {
		return DeviceStartResp{}, fmt.Errorf("decode device start response: %w", err)
	}
	return out, nil
}

// DevicePoll asks the control plane whether the device grant has been approved
// via POST /v1/auth/device/poll (charter decision 10). It is UNauthed like
// DeviceStart — the deviceCode IS the credential. The control plane's outcomes
// (frozen in the charter; implemented by /v1/auth/device/poll) map as:
//
//	200 {status:"pending"}                  → DevicePollPending  (keep waiting)
//	200 {token, team_id}                    → DevicePollApproved (store it)
//	429 {"error":"slow_down"}               → DevicePollSlowDown (back off)
//	404 {"error":"expired_or_invalid"}      → a Go error via cloudError
//	                                           (denied / expired / replayed —
//	                                           the caller stops the loop)
//
// The RFC-8628 spellings (a 4xx {"error":"authorization_pending"}) are tolerated
// as aliases so the client also speaks to a stock device-auth server. Pending and
// slow_down are the EXPECTED steady-state of a poll loop, so they are
// deliberately NOT errors — the caller acts on the status. A terminal refusal is
// an error carrying the control plane's code so the CLI can classify it.
func (c *Client) DevicePoll(ctx context.Context, deviceCode string) (DevicePollResult, error) {
	status, body, err := c.do(ctx, "POST", "/v1/auth/device/poll", false, map[string]string{
		"device_code": deviceCode,
	})
	if err != nil {
		return DevicePollResult{}, err
	}
	if ok(status) {
		// A 200 is either the pending steady-state ({status:"pending"}) or the
		// approval ({token, team_id}) — discriminate BEFORE trusting a token, so
		// a pending body can never masquerade as an approval with an empty token.
		var out struct {
			Status string `json:"status"`
			Token  string `json:"token"`
			TeamID string `json:"team_id"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			return DevicePollResult{}, fmt.Errorf("decode device poll response: %w", err)
		}
		if out.Status == "pending" {
			return DevicePollResult{Status: DevicePollPending}, nil
		}
		if out.Token == "" {
			return DevicePollResult{}, fmt.Errorf("device poll: 200 response carried neither a pending status nor a token")
		}
		return DevicePollResult{Status: DevicePollApproved, Login: LoginResp{Token: out.Token, TeamID: out.TeamID}}, nil
	}
	// A non-2xx is either an expected polling state (RFC-spelled pending, or the
	// 429 slow_down) or a terminal refusal. Discriminate on the error code.
	var env struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(body, &env) == nil {
		switch env.Error {
		case "authorization_pending":
			return DevicePollResult{Status: DevicePollPending}, nil
		case "slow_down":
			return DevicePollResult{Status: DevicePollSlowDown}, nil
		}
	}
	// expired_or_invalid, access_denied, expired_token, or anything unrecognised → stop.
	return DevicePollResult{}, cloudError(status, body)
}

// CreateCheckout starts a subscription checkout for plan via
// POST /v1/billing/checkout (Bearer). The control plane resolves the plan's
// price id and opens a hosted checkout session bound to the AUTHED user's team —
// the client NEVER supplies a team id; it is read server-side from the session
// token. A 200 decodes the {checkout_url} the customer opens in a browser to add
// a card and activate the subscription; a non-2xx surfaces the control plane's
// honest error verbatim — notably 422 "plan_invalid" for an unknown plan or the
// "free" tier (which needs no checkout). It mirrors Login's hand-built request.
func (c *Client) CreateCheckout(ctx context.Context, plan string) (CheckoutResp, error) {
	status, body, err := c.do(ctx, "POST", "/v1/billing/checkout", true, map[string]string{
		"plan": plan,
	})
	if err != nil {
		return CheckoutResp{}, err
	}
	if !ok(status) {
		return CheckoutResp{}, cloudError(status, body)
	}
	var out CheckoutResp
	if err := json.Unmarshal(body, &out); err != nil {
		return CheckoutResp{}, fmt.Errorf("decode checkout response: %w", err)
	}
	return out, nil
}

// MeUser is the account identity block of GET /v1/me — who the session token
// belongs to. Only the non-secret columns the control plane serializes (never a
// password hash / 2FA secret): id, email, and the two boot booleans the SPA
// reads.
type MeUser struct {
	ID               string `json:"id"`
	Email            string `json:"email"`
	Confirmed        bool   `json:"confirmed"`
	TwoFactorEnabled bool   `json:"two_factor_enabled"`
}

// MeResult is the decoded GET /v1/me identity envelope: who the caller is
// (User), the team the session is currently acting in (Team, nil when teamless),
// EVERY team membership (Teams — the full switcher list the SPA renders so a
// user invited into a second team is never stranded on their signup team), and
// the caller's Role in the current team. `bp teams` renders Teams; `bp team use`
// resolves a slug against Teams because the control plane's get_team/1 is
// UUID-only, so slug→UUID resolution is done CLIENT-SIDE from this list. The
// onboarding summary the SPA folds in is intentionally NOT decoded here — the
// CLI's team surface has no use for it.
type MeResult struct {
	User  MeUser `json:"user"`
	Team  *Team  `json:"team"`
	Teams []Team `json:"teams"`
	Role  string `json:"role"`
}

// Me fetches the signed-in identity via GET /v1/me (Bearer). The Teams array is
// the authoritative membership list — one row per team the user belongs to, each
// carrying {id, name, slug, role} — which the CLI's team switcher uses both to
// list memberships (`bp teams`) and to resolve a human-typed slug to its team
// UUID (`bp team use <slug>`). A 401 surfaces the honest auth error via
// cloudError; any decode failure is wrapped, never swallowed.
func (c *Client) Me(ctx context.Context) (MeResult, error) {
	status, body, err := c.do(ctx, "GET", "/v1/me", true, nil)
	if err != nil {
		return MeResult{}, err
	}
	if !ok(status) {
		return MeResult{}, cloudError(status, body)
	}
	var out MeResult
	if err := json.Unmarshal(body, &out); err != nil {
		return MeResult{}, fmt.Errorf("decode me response: %w", err)
	}
	return out, nil
}

// ListBarkparks returns the user's whole fleet via GET /v1/barkparks (Bearer).
// This is the AUTHORITATIVE registry view `bp barkparks` renders when a cloud
// token is present (vs. the local KnownServers fallback in cloud-11).
func (c *Client) ListBarkparks(ctx context.Context) ([]Barkpark, error) {
	return c.listBarkparks(ctx, "/v1/barkparks")
}

// ListAllBarkparks returns Barkparks across every Team membership available to
// the signed-in human. The control plane rejects team-scoped PATs for this view.
func (c *Client) ListAllBarkparks(ctx context.Context) ([]Barkpark, error) {
	return c.listBarkparks(ctx, "/v1/barkparks?scope=all")
}

func (c *Client) listBarkparks(ctx context.Context, path string) ([]Barkpark, error) {
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return nil, err
	}
	if !ok(status) {
		return nil, cloudError(status, body)
	}
	var out struct {
		Barkparks []Barkpark `json:"barkparks"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode barkparks response: %w", err)
	}
	return out.Barkparks, nil
}

// Credentials is the body of GET /v1/barkparks/:id/credentials — the
// per-instance admin bearer the warm-pool minted on the box (instance-admin-token),
// decrypted server-side for the OWNER, plus the instance URL/host for convenience.
// The token is a secret: it is printed once for the user to store safely and is
// never persisted by the CLI.
type Credentials struct {
	AdminToken string `json:"admin_token"`
	URL        string `json:"url"`
	Host       string `json:"host"`
}

// GetCredentials fetches a Barkpark's stored admin token via
// GET /v1/barkparks/:id/credentials (Bearer). The route is team-admin-gated and
// team-scoped: a non-admin gets 403 and an instance in another team (or no such
// id) is the SAME 404 (no existence leak) — both surface verbatim via cloudError.
// A 404 "no_admin_token" means the instance never had one captured (e.g. an
// ip-only/legacy provision).
func (c *Client) GetCredentials(ctx context.Context, id string) (Credentials, error) {
	return c.getCredentials(ctx, id, "")
}

// GetCredentialsForTeam fetches credentials using an explicit team membership
// context. An empty teamID is intentionally identical to GetCredentials.
func (c *Client) GetCredentialsForTeam(ctx context.Context, id, teamID string) (Credentials, error) {
	return c.getCredentials(ctx, id, strings.TrimSpace(teamID))
}

func (c *Client) getCredentials(ctx context.Context, id, teamID string) (Credentials, error) {
	var headers http.Header
	if teamID != "" {
		headers = make(http.Header)
		headers.Set("X-Barkpark-Team", teamID)
	}
	status, body, err := c.doWithHeaders(ctx, "GET", "/v1/barkparks/"+esc(id)+"/credentials", true, nil, headers)
	if err != nil {
		return Credentials{}, err
	}
	if !ok(status) {
		return Credentials{}, cloudError(status, body)
	}
	var out Credentials
	if err := json.Unmarshal(body, &out); err != nil {
		return Credentials{}, fmt.Errorf("decode credentials response: %w", err)
	}
	return out, nil
}

// VerifyProbe is one probe row of the on-demand verify envelope
// (POST /v1/barkparks/:id/verify, charter D53) — the golden-path suite the
// provisioner ran before it ever declared the box ready, re-issued on demand.
// The probe vocabulary (names/labels/pass-rules) is pinned by the shared
// fixture cloud/priv/static/__fixtures__/verify_probes.json; Status is a
// pointer because an unreachable probe honestly has NO status (JSON null),
// not a zero.
type VerifyProbe struct {
	Name      string `json:"name"`
	OK        bool   `json:"ok"`
	Reachable bool   `json:"reachable"`
	Status    *int   `json:"status"`
	LatencyMS int    `json:"latency_ms"`
	Evidence  string `json:"evidence"`
}

// VerifyResult is a COMPLETED verify run: the suite executed and every probe
// reported. OK is the VERDICT (all probes passed), not transport success — an
// unreachable box arrives here as ok:false/reachable:false with three
// fully-populated failed probes, never as a Go error. Raw is the envelope
// BYTES verbatim so `-o json` re-emits the contract without reshaping (D4).
type VerifyResult struct {
	Raw        []byte        `json:"-"`
	OK         bool          `json:"ok"`
	Reachable  bool          `json:"reachable"`
	VerifiedAt string        `json:"verified_at"`
	Probes     []VerifyProbe `json:"probes"`
}

// VerifyError is a verify request the control plane REFUSED to run — one of
// the route's contract codes: 409 not_live (provisioning / being removed),
// 404 not_found (wrong team / no such id — the same 404, no existence leak),
// 404 no_admin_token (a pre-feature row), 500 decrypt_failed (tampered
// ciphertext). The CLI maps each onto a human sentence; any OTHER failure
// (401, a gateway page) stays a plain cloudError so auth handling is shared.
type VerifyError struct {
	HTTPStatus int
	Code       string
	Detail     string
}

func (e *VerifyError) Error() string {
	if e.Detail != "" {
		return e.Code + ": " + e.Detail
	}
	return e.Code
}

// verifyErrorCodes is the closed set of refusal codes the verify route emits
// (mirrors run_verify/1 in the control-plane router). Anything else falls back
// to cloudError so e.g. a 401 keeps its "unauthorized:" prefix contract.
var verifyErrorCodes = map[string]bool{
	"not_live":       true,
	"not_found":      true,
	"no_admin_token": true,
	"decrypt_failed": true,
}

// DomainStage is one rung of a per-host domain checklist as the control plane's
// GET /v1/barkparks/:id/domain-status route (charter S13) reports it: DNS found
// → points here → TLS issued → serving. Status is one of ok|pending|failed;
// Evidence is the server's one-line proof for that rung; Remediation is the
// server-owned fix copy shown only under a non-ok rung — the CLI renders it
// VERBATIM and never invents its own (the FailureCopy-server-owns-copy rule).
type DomainStage struct {
	Stage       string `json:"stage"`
	Label       string `json:"label"`
	Status      string `json:"status"`
	Evidence    string `json:"evidence"`
	Remediation string `json:"remediation"`
}

// DomainCheck is one attached host's full checklist. Kind is platform (a
// name.barkpark.cloud subdomain we own end to end) or custom (a BYO domain the
// operator points at the box); Overall is the rolled-up status the box's chip
// paints (ok|pending|failed).
type DomainCheck struct {
	Host    string        `json:"host"`
	Kind    string        `json:"kind"`
	Overall string        `json:"overall"`
	Stages  []DomainStage `json:"stages"`
}

// DomainStatusResult is a COMPLETED domain-status probe run: the control plane
// checked every attached host inline (DNS/points-here/TLS/serving) and reported
// each rung. OK is the VERDICT (every host serving), not transport success — a
// box mid-issuance arrives here as ok:false with pending rungs, never as a Go
// error. Raw is the envelope BYTES verbatim so `-o json` re-emits the contract
// without reshaping (the verify-envelope idiom).
type DomainStatusResult struct {
	Raw       []byte `json:"-"`
	OK        bool   `json:"ok"`
	CheckedAt string `json:"checked_at"`
	Instance  struct {
		ID   string `json:"id"`
		Host string `json:"host"`
	} `json:"instance"`
	Domains []DomainCheck `json:"domains"`
}

// DomainStatusTimeout is the wall-clock cap for a DomainStatus call. Like
// VerifyInstance, the route is SYNCHRONOUS — the control plane probes live DNS
// resolvers and the box's TLS endpoint inline for every attached host — so it
// needs headroom past the 30s DefaultTimeout that fits a quick control-plane
// call, or the exact stuck-domain scenario the checklist exists to diagnose
// would surface as a transport error instead of the honest pending/failed rungs
// the server was about to deliver.
const DomainStatusTimeout = 90 * time.Second

// FleetDeployCensusTimeout is the wall-clock cap for a FleetDeployCensus call.
// The census aggregates the whole deploy ledger across the window the caller
// chose, so its latency grows with the WIDTH of that window — measured against
// the live control plane on 2026-08-09 under curl: 20d 11.9s, 22d 18.5s, 25d
// 35.5s, 27d 57.9s. The epic's only non-zero (3 never-covered production rows,
// 26.4 days old) first appears at a 27-DAY window — the plane answered that
// window HTTP 200 in 57.9s, while the CLI on the shared 30s DefaultTimeout died
// at `context deadline exceeded (Client.Timeout exceeded while awaiting
// headers)`. The shared default made the exit gauge structurally unable to
// print the number it exists to print. 90s covers the widest window the plane
// answered, with headroom, and matches the two precedents in this file.
const FleetDeployCensusTimeout = 90 * time.Second

// DomainStatus fetches the per-host domain checklist for a managed instance via
// GET /v1/barkparks/:id/domain-status (Bearer). The control plane owns every
// probe (DNS/points-here/TLS/serving) — this client never touches a resolver or
// the box; it renders the CP's truth. A 200 is a completed run (read result.OK
// for the verdict); any non-2xx surfaces through cloudError.
func (c *Client) DomainStatus(ctx context.Context, id string) (DomainStatusResult, error) {
	// Give the synchronous probe suite headroom past DefaultTimeout (see
	// DomainStatusTimeout). An injected HTTP client (tests) is honored untouched;
	// only the lazily-built fallback is widened, and only for this call.
	dc := *c
	if dc.HTTP == nil {
		dc.HTTP = &http.Client{Timeout: DomainStatusTimeout}
	}
	status, raw, err := dc.do(ctx, "GET", "/v1/barkparks/"+esc(id)+"/domain-status", true, nil)
	if err != nil {
		return DomainStatusResult{}, err
	}
	if !ok(status) {
		return DomainStatusResult{}, cloudError(status, raw)
	}
	res := DomainStatusResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return DomainStatusResult{}, fmt.Errorf("decode domain-status envelope: %w", err)
	}
	return res, nil
}

// MetricPoint is one sample of one vitals series as the control plane's GET
// /v1/barkparks/:id/metrics route (charter S12) reports it. Value is a POINTER so
// a dropped/missing sample decodes as nil — a GAP the renderer must honour, never
// a fabricated zero (the whole honesty point of the metrics story).
type MetricPoint struct {
	At    string   `json:"at"`
	Value *float64 `json:"value"`
}

// MetricsBeat is the on-box agent's heartbeat state. Status is one of
// live|stale|absent: absent = no beat ever landed, stale = the beat went quiet
// (the window is last-known), live = a fresh beat. AgeSeconds is the server's own
// age of the last beat at collection time (the CLI never recomputes it).
type MetricsBeat struct {
	LastSeenAt string  `json:"last_seen_at"`
	AgeSeconds float64 `json:"age_seconds"`
	Status     string  `json:"status"`
}

// ServiceHealth is the rolled-up service-check summary the agent reports.
type ServiceHealth struct {
	Pass    int      `json:"pass"`
	Total   int      `json:"total"`
	Failing []string `json:"failing"`
}

// RelationSize is one named consumer of the database total: a relation and the
// bytes it occupies including indexes and TOAST. The named breakdown is what
// turns "3.5 GB" into a diagnosis of WHAT is taking up space.
type RelationSize struct {
	Name  string  `json:"name"`
	Bytes float64 `json:"bytes"`
}

// MetricsSwap is the newest beat's swap reading as a PAIR. A bare percent cannot
// carry three states, so the total rides with it: TotalBytes 0 is a swapless box
// (measured — the answer is "none configured"), TotalBytes > 0 is configured (the
// percent is of THAT), and nil for either is "we could not measure". Both are
// POINTERS so an absent/sentinel reading is a gap, never a fabricated zero.
type MetricsSwap struct {
	UsedPct    *float64 `json:"used_pct"`
	TotalBytes *float64 `json:"total_bytes"`
}

// MetricsSpace is the newest HOST-SPACE report: what is on the disk, broken
// down by named consumer. It rides its own 15-minute cadence on its own route
// (/v1/agent/space), NOT the health beat, so its absence is a fact about the
// agent binary rather than about this window.
//
// EVERY numeric field is a pointer, and that is load-bearing rather than
// stylistic: the agent stamps -1 for a probe it ran and could not complete,
// absent for a probe its build does not have, and a real number otherwise. A
// value type would collapse all three onto 0 — the exact "absence rendered as a
// good reading" this envelope exists to refuse. Only a view is allowed to word
// the difference.
type MetricsSpace struct {
	Root         MetricsSpaceRoot  `json:"root"`
	JournalBytes *float64          `json:"journal_bytes"`
	DBSize       *float64          `json:"db_size"`
	TopRelations []RelationSize    `json:"top_relations"`
	Sites        MetricsSpaceSites `json:"sites"`

	// ConsumerRoots is the BUILD PLANE's disk and every other tree the sites
	// axis structurally cannot see. Until it was decoded here, `bp` had NO
	// reader for it at all: the agent has posted these rows since #13000 and
	// the only surface that rendered them was the browser console, so "what is
	// eating the disk on that box" was still an ssh question with the answer
	// already in the database. That is the same failure the space payload was
	// built to end, one layer up.
	//
	// nil is "this agent measured no roots"; an empty slice is "it was
	// configured to look nowhere". Different facts, kept different.
	ConsumerRoots []MetricsSpaceConsumerRoot `json:"consumer_roots"`

	// Residual is what the reading did NOT measure — or a stated refusal.
	// nil is an agent that predates the field, which a view must word
	// differently from a refusal.
	Residual *MetricsSpaceResidual `json:"residual"`

	ReportedAt *string `json:"reported_at"`
}

// MetricsSpaceConsumerRoot is one named disk-consumer root on THIS box.
//
// Status carries four states and a reader must branch on it, never on
// Bytes >= 0: "read", "degraded" (the total is a FLOOR — du finished but could
// not descend everywhere), "absent" (not on this box, which must never render
// as 0 bytes) and "unmeasured".
//
// ExcludedReason is INDEPENDENT of Status: a root can be perfectly well read
// and still not be subtractable from the residual — an overlay mount is a
// complete, correct reading of a tree that is not on the root filesystem.
type MetricsSpaceConsumerRoot struct {
	Path           string         `json:"path"`
	Status         *string        `json:"status"`
	Bytes          *float64       `json:"bytes"`
	Count          *float64       `json:"count"`
	Top            []RelationSize `json:"top"`
	Degraded       []string       `json:"degraded"`
	DegradedCount  *float64       `json:"degraded_count"`
	ExcludedReason *string        `json:"excluded_reason"`
}

// MetricsSpaceResidual is the answer to the question every part-of-a-whole
// reading begs and almost none of them state: what about the rest?
//
// OfBytes is the denominator — the root filesystem's USED total — and it
// travels with the value so no view can render a share without the volume that
// produced it. It is never df's capacity percent: that is ceil(used/(used+avail))
// with root-reserved blocks excluded, a share of a DIFFERENT whole.
//
// Status "undefined" is the refusal a negative result becomes, and Bytes keeps
// the -1 sentinel there. A view must word it, never print it.
type MetricsSpaceResidual struct {
	Status        *string  `json:"status"`
	Bytes         *float64 `json:"bytes"`
	OfBytes       *float64 `json:"of_bytes"`
	MeasuredBytes *float64 `json:"measured_bytes"`
	CountedRoots  *float64 `json:"counted_roots"`
	ExcludedRoots *float64 `json:"excluded_roots"`
	PGSource      *string  `json:"pg_source"`
	Reason        *string  `json:"reason"`
}

// MetricsSpaceRoot is the root filesystem's used/total pair. Both nil is "we
// could not read the filesystem", never "an empty disk".
type MetricsSpaceRoot struct {
	UsedBytes  *float64 `json:"used_bytes"`
	TotalBytes *float64 `json:"total_bytes"`
}

// MetricsSpaceSites is the deployed-sites directory and its biggest named
// consumers.
//
// Top follows the same nil/empty split as MetricsLatest.TopRelations: nil is
// "not measured", an empty slice is "measured, and there is nothing there".
//
// Count carries THREE states, which is why it is a pointer to a signed value
// and why the renderer must word all three: nil is an agent too old to send
// `sites_count`, -1 is a walk that ran and FAILED, and >= 0 is a real count. A
// -1 that reaches a reader as "0 sites" would claim a measured empty disk on
// the strength of a failed probe.
type MetricsSpaceSites struct {
	Dir   *string        `json:"dir"`
	Bytes *float64       `json:"bytes"`
	Top   []RelationSize `json:"top"`
	Count *float64       `json:"count"`
}

// MetricsBeam is the BEAM's OWN footprint from the newest beat: resident (Pss)
// and paged-out (Swap) bytes for the one process the kernel OOM-kills.
type MetricsBeam struct {
	PSSBytes  *float64 `json:"pss_bytes"`
	SwapBytes *float64 `json:"swap_bytes"`
}

// MetricsLatest is the newest beat's SCALAR facts — the ones a trend line cannot
// answer. TopRelations is nil when the probe never ran (a pre-upgrade agent, or
// a failed read) and an EMPTY slice when it ran and found nothing: "unmeasured"
// and "measured, and it's empty" are different facts and stay different here.
type MetricsLatest struct {
	DBSize       *float64       `json:"db_size"`
	TopRelations []RelationSize `json:"top_relations"`
	Swap         MetricsSwap    `json:"swap"`
	Beam         MetricsBeam    `json:"beam"`

	// Cores is the box's core count, and it is decoded here for a SECOND
	// reason beyond display: it is the only signal on this envelope that can
	// tell a box which has not YET sent a space report from one that never
	// CAN. `cpu_cores` and the whole space probe entered the agent in ONE
	// commit (fc6a74ca23, #9824) — `git log -S` over internal/agent/report.go
	// returns exactly that commit for each, and its parent carries neither —
	// so for a main-line binary, a readable core count implies a binary that
	// also contains the space loop. cloud_status_cmd.go's `unmeteredMarker`
	// already keys the same inference off the same field under charter D69/D88;
	// this is that ruled inference reused, not a new one invented here.
	Cores *float64 `json:"cores"`
}

// MetricsResult is a COMPLETED metrics roll-up: the control plane rolled the
// agent's beat window and reported per-series points. This client NEVER computes
// — it renders the CP's truth. Raw is the envelope BYTES verbatim so `-o json`
// re-emits the contract without reshaping (the verify/domain-status idiom). The
// series map is keyed by metric (cpu|mem|disk|load|swap|beam_pss|beam_swap), each
// oldest-to-newest; Latest carries the newest beat's scalars (db size + its named
// top relations, the swap pair, the BEAM footprint). NOTE the series map is
// DYNAMICALLY keyed, so a key the renderer does not list is dropped silently —
// cloud_instance_top_cmd.go's metricTopSpecs is the render list that must move
// with the control plane's @vitals.
type MetricsResult struct {
	Raw         []byte `json:"-"`
	OK          bool   `json:"ok"`
	CollectedAt string `json:"collected_at"`
	Instance    struct {
		ID       string `json:"id"`
		Host     string `json:"host"`
		Provider string `json:"provider"`
	} `json:"instance"`
	Beat          MetricsBeat              `json:"beat"`
	Points        int                      `json:"points"`
	Series        map[string][]MetricPoint `json:"series"`
	Latest        MetricsLatest            `json:"latest"`
	ServiceHealth ServiceHealth            `json:"service_health"`

	// Space is the newest HOST-SPACE report, or nil when the box has never sent
	// one. A POINTER, never a value struct: the control plane sends `null` here
	// (Metrics.space/1 answers nil, not an all-nil envelope) precisely so a
	// renderer can tell "no space report" from "we measured and found nothing",
	// and a value struct would erase that distinction at the decode boundary by
	// turning absence into a zeroed section.
	Space *MetricsSpace `json:"space"`
}

// Metrics fetches the on-box agent vitals roll-up for a managed instance via GET
// /v1/barkparks/:id/metrics (Bearer). Unlike DomainStatus/VerifyInstance the
// control plane does NOT probe the live box inline — it serves an already-rolled
// window from the agent's stored beats — so the shared DefaultTimeout is ample
// (no widened headroom). `points` is the requested sample count (<=0 → the
// server's default window). A 200 is a completed roll-up (read OK/beat.status for
// the verdict); any non-2xx surfaces through cloudError.
func (c *Client) Metrics(ctx context.Context, id string, points int) (MetricsResult, error) {
	path := "/v1/barkparks/" + esc(id) + "/metrics"
	if points > 0 {
		path += fmt.Sprintf("?points=%d", points)
	}
	status, raw, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return MetricsResult{}, err
	}
	if !ok(status) {
		return MetricsResult{}, cloudError(status, raw)
	}
	res := MetricsResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return MetricsResult{}, fmt.Errorf("decode metrics envelope: %w", err)
	}
	return res, nil
}

// VerifyTimeout is the wall-clock cap for a VerifyInstance call. The route is
// SYNCHRONOUS: the control plane probes the live box inline (up to 6 upstream
// requests, each with its own 5s connect + 5s recv bound — ~60s absolute worst
// case against a hung box), so the shared 30s DefaultTimeout that fits every
// quick control-plane call could cut this one off mid-run and turn the exact
// scenario verify exists for — a sick box — into a transport error instead of
// the honest failed verification the server was about to deliver.
const VerifyTimeout = 90 * time.Second

// VerifyInstance re-runs the golden-path verify suite against a managed
// instance via POST /v1/barkparks/:id/verify (Bearer). The control plane
// probes the live box with the STORED admin token — the token never reaches
// this client. A 200 is a completed run (pass or fail — read result.OK); a
// contract refusal surfaces as *VerifyError; anything else via cloudError.
func (c *Client) VerifyInstance(ctx context.Context, id string) (VerifyResult, error) {
	// Give the synchronous suite headroom past DefaultTimeout (see
	// VerifyTimeout). An injected HTTP client (tests) is honored untouched;
	// only the lazily-built fallback is widened, and only for this call.
	vc := *c
	if vc.HTTP == nil {
		vc.HTTP = &http.Client{Timeout: VerifyTimeout}
	}
	status, raw, err := vc.do(ctx, "POST", "/v1/barkparks/"+esc(id)+"/verify", true, nil)
	if err != nil {
		return VerifyResult{}, err
	}
	if !ok(status) {
		var env struct {
			Error  string `json:"error"`
			Detail string `json:"detail"`
		}
		if json.Unmarshal(raw, &env) == nil && verifyErrorCodes[env.Error] {
			return VerifyResult{}, &VerifyError{HTTPStatus: status, Code: env.Error, Detail: env.Detail}
		}
		return VerifyResult{}, cloudError(status, raw)
	}
	res := VerifyResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return VerifyResult{}, fmt.Errorf("decode verify envelope: %w", err)
	}
	return res, nil
}

// ConnectProvider links a cloud account (kind + plaintext token, optional label)
// via POST /v1/providers (Bearer). The control plane encrypts the token at rest
// and returns only the safe metadata. label is sent only when non-empty.
func (c *Client) ConnectProvider(ctx context.Context, kind, token, label string) (Provider, error) {
	req := map[string]string{"kind": kind, "token": token}
	if label != "" {
		req["label"] = label
	}
	status, body, err := c.do(ctx, "POST", "/v1/providers", true, req)
	if err != nil {
		return Provider{}, err
	}
	if !ok(status) {
		return Provider{}, cloudError(status, body)
	}
	var out struct {
		Provider Provider `json:"provider"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Provider{}, fmt.Errorf("decode provider response: %w", err)
	}
	return out.Provider, nil
}

// DisconnectProvider drops the team's connected provider of `kind` via DELETE
// /v1/providers/:kind (Bearer). The control plane deletes the row + its encrypted
// credential and returns {ok:true}. A 404 (no such connection — no existence
// leak) surfaces verbatim via cloudError, as does any other non-2xx. This is the
// plugin law's "disconnect degrades to standalone" path — the box keeps serving
// its own content directly once the edge provider is gone.
func (c *Client) DisconnectProvider(ctx context.Context, kind string) error {
	status, body, err := c.do(ctx, "DELETE", "/v1/providers/"+esc(kind), true, nil)
	if err != nil {
		return err
	}
	if !ok(status) {
		return cloudError(status, body)
	}
	return nil
}

// Launch provisions a Barkpark into a connected provider via POST /v1/launch
// (Bearer). provider is the provider id/kind to launch into (sent only when
// non-empty so the control plane can pick the Team's default); name is the new
// Barkpark's name. The returned row reflects the provisioning state — actual
// provisioning runs server-side (the Go warm-pool, cloud-6), not here.
func (c *Client) Launch(ctx context.Context, provider, name string) (Barkpark, error) {
	req := map[string]string{"name": name}
	if provider != "" {
		req["provider"] = provider
	}
	return c.launchLike(ctx, "/v1/launch", req)
}

// GoLive provisions a fully-managed Barkpark via POST /v1/go-live (Bearer) — the
// zero-config path where the control plane owns the infra (no BYO provider). name
// is required (a missing name surfaces the control plane's 422 "name_required");
// plan is the optional billing plan (sent only when non-empty).
func (c *Client) GoLive(ctx context.Context, name, plan string) (Barkpark, error) {
	req := map[string]string{"name": name}
	if plan != "" {
		req["plan"] = plan
	}
	return c.launchLike(ctx, "/v1/go-live", req)
}

// ResurrectReceipt is the control plane's 202 receipt for POST /v1/resurrect
// (portable-archive restore, charter S14): the fresh barkpark row's id + the
// enqueued resurrect job the worker restores.
type ResurrectReceipt struct {
	OK    bool   `json:"ok"`
	ID    string `json:"id"`
	JobID string `json:"job_id"`
}

// Resurrect enqueues a portable-bundle resurrect via POST /v1/resurrect (Bearer
// — the route is require_user + team-admin + entitlement-gated, same plane as
// Launch). name is the new row's display name; provider is the RESTORE TARGET
// kind (which may differ from the bundle's source provider — that difference IS
// the migration story); bundleRef is the object-storage bundle prefix to
// restore from (required — the control plane does not resolve a newest bundle
// server-side yet, so callers resolve it before posting).
func (c *Client) Resurrect(ctx context.Context, provider, name, bundleRef string) (ResurrectReceipt, error) {
	req := map[string]string{"name": name, "provider": provider, "bundle_ref": bundleRef}
	status, body, err := c.do(ctx, "POST", "/v1/resurrect", true, req)
	if err != nil {
		return ResurrectReceipt{}, err
	}
	if !ok(status) {
		return ResurrectReceipt{}, cloudError(status, body)
	}
	var out ResurrectReceipt
	if err := json.Unmarshal(body, &out); err != nil {
		return ResurrectReceipt{}, fmt.Errorf("decode resurrect response: %w", err)
	}
	if out.JobID == "" {
		return ResurrectReceipt{}, fmt.Errorf("control plane accepted the resurrect but returned no job id")
	}
	return out, nil
}

// launchLike is the shared POST-then-unwrap-{"barkpark":…} core behind Launch and
// GoLive — both return a single provisioned Barkpark row in the same envelope.
func (c *Client) launchLike(ctx context.Context, path string, req map[string]string) (Barkpark, error) {
	status, body, err := c.do(ctx, "POST", path, true, req)
	if err != nil {
		return Barkpark{}, err
	}
	if !ok(status) {
		return Barkpark{}, cloudError(status, body)
	}
	var out struct {
		Barkpark Barkpark `json:"barkpark"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Barkpark{}, fmt.Errorf("decode launch response: %w", err)
	}
	return out.Barkpark, nil
}

// Site is one hosted website running co-located with a Barkpark, as returned by
// the /v1/sites endpoints (control plane, cloud-12c). Mirrors the site_json
// shape in cloud/lib/barkpark_cloud/web/router.ex — the env blob is NEVER
// echoed back, only metadata. `CurrentDeploymentID` is the live deployment
// pointer the on-box runtime is serving from.
type Site struct {
	ID                  string   `json:"id"`
	BarkparkID          string   `json:"barkpark_id"`
	TeamID              string   `json:"team_id"`
	Name                string   `json:"name"`
	Slug                string   `json:"slug"`
	Framework           string   `json:"framework"`
	Domains             []string `json:"domains"`
	ScaleMode           string   `json:"scale_mode"`
	Port                int      `json:"port"`
	CurrentDeploymentID string   `json:"current_deployment_id"`
	// P7 github-webhook: GitHub link metadata (the encrypted secret never
	// appears in JSON; `GithubWebhookConfigured` is a server-computed bool).
	GithubRepo              string `json:"github_repo,omitempty"`
	GithubBranch            string `json:"github_branch,omitempty"`
	GithubWebhookConfigured bool   `json:"github_webhook_configured,omitempty"`
	// PrebuiltEnabled is the site's opt-in to accepting builds produced somewhere
	// other than its box (site-spawner W9). The control plane has serialized it
	// since W9 and PATCH /v1/sites/:id accepts it, but no Go field decoded it — so
	// `bp` could TURN the opt-in on and then never read it back, and a `--prebuilt`
	// deploy's 409 was the first place a user learned the site was not enabled.
	// NOT omitempty: a false here is an answer, not an absence.
	PrebuiltEnabled bool   `json:"prebuilt_enabled"`
	InsertedAt      string `json:"inserted_at"`
	UpdatedAt       string `json:"updated_at"`
	// LastDeployment is the LATEST PRODUCTION deployment for this site, embedded
	// by GET /v1/sites (router.ex `put_last_deployment/3`, fed by the ONE batched
	// `Registry.latest_deployment_status_map/1`). It is nil-honest: nil means the
	// site has no production deployment row at all (a preview-only or
	// never-deployed site), NOT that the site is healthy and not that the key was
	// lost. Only GET /v1/sites carries it — GET /v1/sites/:id does not.
	//
	// deploy-reliability W17: this embed shipped in search-template W15 and had
	// ZERO Go readers until now, so `bp sites` walked an N+1 over
	// /v1/sites/:id/deployments instead, reading each site's status at a
	// DIFFERENT INSTANT. One field here collapses that to one read at one instant.
	LastDeployment *SiteDeploymentEmbed `json:"last_deployment"`
}

// SiteDeploymentEmbed is the four-key slice of a deployment that GET /v1/sites
// embeds per site. The keyset is deliberately narrow and is fenced by the
// search-template D24 honesty law: status, trigger and the two timestamps, and
// NOTHING else — no console URL, no build_log_url, no content_rev, and no
// environment key (the query is already `environment == "production"`).
//
// Do not widen this struct to chase a field the wire does not carry: an absent
// key decoded into a zero value is exactly the "measured empty" lie this epic
// exists to remove. `Trigger` is a POINTER for that reason — the control plane
// genuinely sends null for a deployment nobody attributed.
type SiteDeploymentEmbed struct {
	Status     string  `json:"status"`
	Trigger    *string `json:"trigger"`
	InsertedAt string  `json:"inserted_at"`
	UpdatedAt  string  `json:"updated_at"`
}

// Deployment is one build-and-release of a Site, as returned by the
// /v1/sites/:id/deploy + /v1/sites/:id/deployments endpoints. `Status` walks
// queued → building → pushing → live (or failed). `BuildLogURL` is opaque to
// the control plane — `bp sites logs <site>` prints it as a best-effort
// pointer at the builder's log surface.
//
// deploy-reliability W9: the control plane has always serialized the row's
// CAUSE — failure_class, failure_reason, stage, trigger, content_rev — and this
// struct decoded almost none of it, so the only cause-bearing keys on the wire
// were dropped on the floor before any human surface could print them.
//
// The six cause/lifecycle fields below are POINTERS on purpose. A `string` zero
// value cannot tell "the control plane did not send this key" apart from "the
// control plane measured it as empty", and this epic exists because
// deployment reporting kept presenting the first as the second. nil MUST render
// as an explicit dash, never as a value.
type Deployment struct {
	ID          string `json:"id"`
	SiteID      string `json:"site_id"`
	Status      string `json:"status"`
	GitRef      string `json:"git_ref"`
	ArtifactURL string `json:"artifact_url"`
	ImageTag    string `json:"image_tag"`
	BuildLogURL string `json:"build_log_url"`
	InsertedAt  string `json:"inserted_at"`
	UpdatedAt   string `json:"updated_at"`

	// FailureClass is the control plane's NAMED cause, e.g. "BUILD_FAILED" or
	// "BOX_AT_CAPACITY_DEFERRED" — the single most load-bearing key a human
	// reading a failing site needs, and the one `bp sites deployments` printed
	// nowhere before W9.
	FailureClass *string `json:"failure_class"`
	// FailureReason is the free-text detail behind FailureClass.
	FailureReason *string `json:"failure_reason"`
	// ContentRev is the content revision the build was cut from.
	ContentRev *string `json:"content_rev"`
	// Trigger is what asked for this deploy (push, manual, api, …).
	Trigger *string `json:"trigger"`
	// Stage is how far the row got before it stopped.
	Stage *string `json:"stage"`
	// BecameLiveAt is set only on rows that actually reached live.
	BecameLiveAt *string `json:"became_live_at"`
}

// DeploymentQuery narrows GET /v1/sites/:id/deployments to one window. Zero
// values mean "server default" — which is a page of 100, the reason the CLI
// could never see past the newest hundred rows before W9.
//
//	Limit  — how many rows to ask for (omitted from the wire when <= 0).
//	Before — an opaque cursor from a previous page's NextCursor.
type DeploymentQuery struct {
	Limit  int
	Before string
}

// DeploymentPage is one window of a site's deployments plus the cursor that
// reaches the window behind it. NextCursor is "" when the server did not send
// one — i.e. this window is the whole tail.
type DeploymentPage struct {
	Deployments []Deployment
	NextCursor  string
}

// SiteCreate is the body the CLI POSTs to /v1/sites. Pointer-ish optionality
// is encoded by omitempty so a zero-value field is left unset on the wire —
// the server fills in defaults (framework "nextjs", scale_mode "always_on").
type SiteCreate struct {
	BarkparkID string   `json:"barkpark_id"`
	Name       string   `json:"name"`
	Framework  string   `json:"framework,omitempty"`
	Domains    []string `json:"domains,omitempty"`
	ScaleMode  string   `json:"scale_mode,omitempty"`
}

// ListSites returns every site under the user's team via GET /v1/sites
// (Bearer). The control plane scopes results to the caller's team — a wrong
// team gets an empty list, not a 403.
func (c *Client) ListSites(ctx context.Context) ([]Site, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites", true, nil)
	if err != nil {
		return nil, err
	}
	if !ok(status) {
		return nil, cloudError(status, body)
	}
	var out struct {
		Sites []Site `json:"sites"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode sites response: %w", err)
	}
	return out.Sites, nil
}

// GetSite returns one site by id via GET /v1/sites/:id (Bearer). A 404 from
// either "no such site" or "site in another team" surfaces verbatim — the
// control plane does NOT leak existence across team boundaries.
func (c *Client) GetSite(ctx context.Context, id string) (Site, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites/"+esc(id), true, nil)
	if err != nil {
		return Site{}, err
	}
	if !ok(status) {
		return Site{}, cloudError(status, body)
	}
	var out struct {
		Site Site `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Site{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// CreateSite POSTs /v1/sites (Bearer) and returns the new row. `BarkparkID`
// is the underlying Barkpark UUID the site lives on — the CLI resolves
// `--barkpark <slug>` to this id via ListBarkparks before calling.
func (c *Client) CreateSite(ctx context.Context, req SiteCreate) (Site, error) {
	status, body, err := c.do(ctx, "POST", "/v1/sites", true, req)
	if err != nil {
		return Site{}, err
	}
	if !ok(status) {
		return Site{}, cloudError(status, body)
	}
	var out struct {
		Site Site `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Site{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// Deploy enqueues a Deployment row via POST /v1/sites/:id/deploy (Bearer).
// `gitRef` and `artifactURL` are optional — at least one is needed in
// practice for the builder to do anything; the CLI requires `--artifact-url`
// until the tarball-upload route lands (P7). The returned Deployment is
// status:"queued" — the builder polls and walks it through.
func (c *Client) Deploy(ctx context.Context, siteID, gitRef, artifactURL string) (Deployment, error) {
	req := map[string]string{}
	if gitRef != "" {
		req["git_ref"] = gitRef
	}
	if artifactURL != "" {
		req["artifact_url"] = artifactURL
	}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+esc(siteID)+"/deploy", true, req)
	if err != nil {
		return Deployment{}, err
	}
	if !ok(status) {
		return Deployment{}, cloudError(status, body)
	}
	var out struct {
		Deployment Deployment `json:"deployment"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Deployment{}, fmt.Errorf("decode deployment response: %w", err)
	}
	return out.Deployment, nil
}

// ListDeployments returns one window of a site's deployments, newest-first, via
// GET /v1/sites/:id/deployments (Bearer).
//
// deploy-reliability W9: the call used to send no query string at all, so it
// took whatever the server's default page was (100) and had no way to ask for
// anything else. A caller that wanted a bigger sample, or the rows BEHIND the
// newest hundred, silently got the same hundred — and any rate computed from
// them was a rate over an unstated window. `q` names the window; the returned
// NextCursor is how the caller walks past it.
func (c *Client) ListDeployments(ctx context.Context, siteID string, q DeploymentQuery) (DeploymentPage, error) {
	path := "/v1/sites/" + esc(siteID) + "/deployments"
	vals := url.Values{}
	if q.Limit > 0 {
		vals.Set("limit", strconv.Itoa(q.Limit))
	}
	if q.Before != "" {
		vals.Set("before", q.Before)
	}
	if len(vals) > 0 {
		path += "?" + vals.Encode()
	}
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return DeploymentPage{}, err
	}
	if !ok(status) {
		return DeploymentPage{}, cloudError(status, body)
	}
	var out deploymentsEnvelope
	if err := json.Unmarshal(body, &out); err != nil {
		return DeploymentPage{}, fmt.Errorf("decode deployments response: %w", err)
	}
	page := DeploymentPage{Deployments: out.Deployments}
	if out.NextCursor != nil {
		page.NextCursor = *out.NextCursor
	}
	return page, nil
}

// deploymentsEnvelope is the NAMED wire shape of GET /v1/sites/:id/deployments
// (dr-w14-s6 followup: this decode used to be an anonymous struct, which is how
// an envelope key can ship with no reader and nobody's grep can say so).
// `next_cursor` is a POINTER because the server sends null on the last window —
// "no page behind this one" — and that must stay distinguishable from a cursor
// the decode dropped.
//
// `publish_clock` is deliberately ABSENT, and the absence is the record: the
// task that filed this struct predates dr-w26-s6, which DELETED that node from
// this route as the reader-less-instrument census's first deletion (thirteen
// waves, zero readers — see reader_less_instrument_census_test.exs, key
// "publish_clock", disposition :deleted). Declaring a field for a key the wire
// no longer carries would mint a PHANTOM — the payload census's own name for a
// decoder field that decodes to zero forever — which is the same defect class
// this slice exists to close, from the other side.
type deploymentsEnvelope struct {
	Deployments []Deployment `json:"deployments"`
	NextCursor  *string      `json:"next_cursor"`
}

// ListDeploymentsAll walks the site's deployment ledger PAST the route's page
// cap (default 100, max 200 per window) by following next_cursor until the
// server stops sending one — the walk the cursor was built for in W1 S2 and
// that no Go caller performed until this method (a decoded-but-unused cursor
// is the same silence as an undecoded one).
//
// maxRows bounds the walk (a busy site accrues one row per push; an unbounded
// walk over years of ledger is a mistake nobody should make by default);
// maxRows <= 0 means no bound. A repeated cursor — a server bug that would
// otherwise loop this walk forever — is an error, never an infinite request
// stream.
func (c *Client) ListDeploymentsAll(ctx context.Context, siteID string, pageLimit, maxRows int) ([]Deployment, error) {
	var all []Deployment
	seen := map[string]bool{}
	before := ""
	for {
		page, err := c.ListDeployments(ctx, siteID, DeploymentQuery{Limit: pageLimit, Before: before})
		if err != nil {
			return nil, err
		}
		all = append(all, page.Deployments...)
		if maxRows > 0 && len(all) >= maxRows {
			return all[:maxRows], nil
		}
		if page.NextCursor == "" || len(page.Deployments) == 0 {
			return all, nil
		}
		if seen[page.NextCursor] {
			return nil, fmt.Errorf("deployments walk: server repeated cursor %q — refusing to loop", page.NextCursor)
		}
		seen[page.NextCursor] = true
		before = page.NextCursor
	}
}

// SetEnv REPLACES the encrypted env blob via POST /v1/sites/:id/env (Bearer).
// The control plane re-encrypts the whole map at rest — there is no
// merge-on-server. The CLI's `bp sites env set` is responsible for any
// upstream merge (read current env from the user, overlay the K=V pairs).
// On 200 the server returns {"ok": true} with no body shape to decode.
func (c *Client) SetEnv(ctx context.Context, siteID string, env map[string]string) error {
	req := map[string]any{"env": env}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+esc(siteID)+"/env", true, req)
	if err != nil {
		return err
	}
	if !ok(status) {
		return cloudError(status, body)
	}
	return nil
}

// ArtifactUpload is the response shape from
// POST /v1/sites/:id/deployments/:dep_id/artifact — the byte count the control
// plane recorded, which the caller reconciles against what it sent.
//
// site-spawner W10: the `artifact_url` and `filename` fields are GONE with the
// site-scoped route that emitted them. That route's `file://` URL named a file on
// a host the builder could never reach; W9 stopped emitting both keys, and
// nothing but a test fixture noticed. `Bytes` is the only field any caller reads.
type ArtifactUpload struct {
	Bytes int64 `json:"bytes"`
}

// AddDomain appends a hostname to the site's domains array via
// POST /v1/sites/:id/domains (Bearer). The returned Site reflects the new
// array; the domain becomes acceptable to the on-demand-TLS ask gate
// immediately.
func (c *Client) AddDomain(ctx context.Context, siteID, domain string) (Site, error) {
	req := map[string]string{"domain": domain}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+esc(siteID)+"/domains", true, req)
	if err != nil {
		return Site{}, err
	}
	if !ok(status) {
		return Site{}, cloudError(status, body)
	}
	var out struct {
		Site Site `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Site{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// ---------------------------------------------------------------------------
// Site spawner (bp cloud site) — cloud-site-spawner charter D10.
//
// DELIBERATELY DISTINCT from the container-model Site/Deployment above: a
// SPAWNED site is a static (SSG) build — Astro first, others on the pluggable
// roadmap — that reads from a Barkpark dataset triple (ws/proj/ds) and rides the
// co-located instance's OWN Caddy + blue/green + webhook machinery. It shares the
// /v1/sites route family but carries a `kind` + the dataset triple, and its
// deploy walks the SIX visible stages PLAN → BUILD → STAGE → HEALTH → SWITCH →
// RETIRE, health-gated so a broken build never reaches visitors, with a
// sub-second symlink-flip rollback. These types are self-contained so the
// spawner and the container model never blur — matching the fields the sibling
// site-spawner-w1-cloud-schema slice accepts.
// ---------------------------------------------------------------------------

// SpawnSiteStages are the six visible deploy stages, in order — the Kinsta/Vercel
// progress bar the CLI streams. The control plane authors per-stage status; this
// list is the canonical ordering the renderer walks so a lean payload still shows
// the full bar.
var SpawnSiteStages = []string{"PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"}

// SpawnSiteCreate is the body POSTed to /v1/sites for a spawned site: the name,
// the framework (astro is the flagship), the kind (static), the dataset triple the
// build reads content from, and the instance it is spawned on.
//
// BarkparkID is REQUIRED, not optional: `sites.barkpark_id` is validate_required in
// the changeset and NOT NULL with an FK at the DB level, and NOTHING in the control
// plane derives an instance from the workspace. Sending it empty is a 422 — so the
// CLI demands `--instance` up front rather than shipping a request it knows will
// be rejected.
type SpawnSiteCreate struct {
	Name       string `json:"name"`
	Framework  string `json:"framework,omitempty"`
	Kind       string `json:"kind,omitempty"`
	Workspace  string `json:"workspace"`
	Project    string `json:"project"`
	Dataset    string `json:"dataset"`
	BarkparkID string `json:"barkpark_id,omitempty"`
	// DocType is the Barkpark content type the build's flagship fetch reads
	// (BARKPARK_DOC_TYPE on the box). Optional: the control plane defaults it to
	// the canonical "post" when omitted, so an empty string is a server-side
	// default rather than a wire error (charter D35). The live proof passes
	// "paper" explicitly because guerrilla has no post schema.
	DocType string `json:"doc_type,omitempty"`
	// Template is the shipped starter tree the box provisions (search-template
	// W2, charter D8): astro-starter | next-starter | search-starter. Optional:
	// empty keeps the framework-derived default (astro->astro-starter,
	// nextjs->next-starter) — the pre-template behavior, byte-identical.
	Template string `json:"template,omitempty"`
	// Theme pins a shipped palette for this site's deploys (search-template W6:
	// evergreen | ember | fjord | charple). Optional: empty keeps the template
	// default — the relay injects BARKPARK_THEME only when set.
	Theme string `json:"theme,omitempty"`
}

// Runtime targets — the "where does the artifact RUN" half of the site engine
// (charter D61/D62). The state machine (PLAN→BUILD→STAGE→HEALTH→SWITCH→RETIRE) is
// one; the runtime target is which of two ways its artifact serves:
//
//   - RuntimeTargetStatic — the flagship (Astro): the artifact is a `dist/` tree
//     and SWITCH / rollback is an atomic symlink flip. No per-site process.
//   - RuntimeTargetNode — the container-framework SSR target (Next.js first, then
//     nuxt/sveltekit): the artifact is a long-running node process on a per-slot
//     PORT (systemd slot unit), health-gated by an HTTP probe TO the process, and
//     SWITCH / rollback is a Caddy reverse_proxy upstream flip to the warm slot.
const (
	RuntimeTargetStatic = "static-symlink-swap"
	RuntimeTargetNode   = "node-slot"
)

// RuntimeTargetIsNode reports whether a runtime_target names the node-slot SSR
// target — the container-framework path whose SWITCH / rollback is a Caddy
// upstream port-flip, not a symlink swap. It matches the canonical "node-slot"
// plus any value CONTAINING "node" (so a server that labels the field "node" or
// "node_slot" still branches). An EMPTY target — a pre-node / static box that
// never sends the field — is deliberately NOT node: the CLI fails closed to the
// static symlink-swap narration it has always used, never claiming a node
// mechanism it wasn't told about.
func RuntimeTargetIsNode(target string) bool {
	t := strings.ToLower(strings.TrimSpace(target))
	return t == RuntimeTargetNode || strings.Contains(t, "node")
}

// SpawnSite is one spawned site as returned by the /v1/sites endpoints for a
// `kind` row. URL is the live PATH url (https://<instance>.barkpark.cloud/sites/
// <slug>/) the control plane computes; Instance is the instance slug/host the CLI
// falls back to when URL is absent. CurrentDeployment is the live build, embedded
// when the control plane includes it so `status` needs no second round trip.
//
// RuntimeTarget / Port / PortBase are the node-slot fields (charter D62): a
// container-framework site runs as a long-running node process, so the control
// plane returns its runtime_target ("node-slot"), the currently-serving slot Port,
// and the PortBase the per-slot ports are allocated from. All three are omitempty
// AND must be threaded here explicitly — Go's json.Unmarshal SILENTLY DROPS keys
// with no matching field, so a static-only struct would make a node site's port
// invisible to `bp cloud site status -o json`.
type SpawnSite struct {
	ID            string `json:"id"`
	BarkparkID    string `json:"barkpark_id"`
	TeamID        string `json:"team_id"`
	Name          string `json:"name"`
	Slug          string `json:"slug"`
	Kind          string `json:"kind"`
	Framework     string `json:"framework"`
	Workspace     string `json:"workspace"`
	Project       string `json:"project"`
	Dataset       string `json:"dataset"`
	URL           string `json:"url"`
	Instance      string `json:"instance"`
	RuntimeTarget string `json:"runtime_target,omitempty"`
	// search-template W2/W6: the shipped starter + deploy-pinned palette.
	Template string `json:"template,omitempty"`
	Theme    string `json:"theme,omitempty"`
	// search-template W10: the featured content type the site's build reads.
	// Declared here or json.Unmarshal drops it silently — the tag's omitempty is
	// decode-irrelevant (SpawnSite is never marshalled) and kept for symmetry.
	DocType             string          `json:"doc_type,omitempty"`
	Port                int             `json:"port,omitempty"`
	PortBase            int             `json:"port_base,omitempty"`
	CurrentDeploymentID string          `json:"current_deployment_id"`
	CurrentDeployment   *SiteDeployment `json:"current_deployment,omitempty"`
	InsertedAt          string          `json:"inserted_at"`
	UpdatedAt           string          `json:"updated_at"`
}

// SiteStage is one of the six visible deploy stages. Status walks
// pending → running → done (or failed / skipped). Detail is the control plane's
// optional one-line elaboration (e.g. the health probe URL, the failure line).
type SiteStage struct {
	Name       string `json:"name"`
	Status     string `json:"status"`
	StartedAt  string `json:"started_at,omitempty"`
	FinishedAt string `json:"finished_at,omitempty"`
	Detail     string `json:"detail,omitempty"`
}

// SiteDeployment is one build-and-release of a spawned site. Status is the control
// plane's deployment enum — queued → building → pushing → live, or the terminal
// failed / cancelled (see SiteDeploymentTerminal); Stage names the visible stage
// currently in flight; Stages carries the per-stage progress the CLI streams, each
// with the engine's own `detail` line. BuildID is the isolated, reproducible build;
// URL is the live path url once SWITCH flips the symlink. Trigger is the deploy's
// provenance — "manual" (a `bp cloud site deploy` / API call) or "content-auto" (a
// content publish on the bound dataset fired the debounced auto-rebuild); it is
// omitempty because the control plane only started emitting it in wave 5 and Go's
// json.Unmarshal would otherwise silently drop the unknown key.
//
// ContentRev / Source / SourceDigest are the prebuilt lane's fields (charter
// D87/D88) and are threaded EXPLICITLY for the json.Unmarshal reason stated on
// Trigger above — an un-modelled key is dropped in silence, and ContentRev in
// particular is not knowable any other way: it is computed on the BOX by the
// content_rev probe, so the mint response is the only place a client can read it
// before building. Source is the deployment's build provenance ("prebuilt" when
// the bytes were built off the serving box, absent/"" for the on-box default
// path) and SourceDigest is the sha256 of the uploaded artifact, which the box
// re-verifies before it stages anything.
//
// RuntimeTarget / Port mirror the SpawnSite node-slot fields at the deployment
// grain (charter D62): a node deployment carries the runtime_target it ran on and
// the slot Port its process bound — omitempty and threaded explicitly for the same
// json.Unmarshal-drops-unknown-keys reason as SpawnSite. A static deployment omits
// both.
type SiteDeployment struct {
	ID            string      `json:"id"`
	SiteID        string      `json:"site_id"`
	Status        string      `json:"status"`
	Stage         string      `json:"stage"`
	Stages        []SiteStage `json:"stages"`
	BuildID       string      `json:"build_id"`
	ContentRev    string      `json:"content_rev,omitempty"`
	Source        string      `json:"source,omitempty"`
	SourceDigest  string      `json:"artifact_sha256,omitempty"`
	URL           string      `json:"url"`
	Trigger       string      `json:"trigger,omitempty"`
	RuntimeTarget string      `json:"runtime_target,omitempty"`
	Port          int         `json:"port,omitempty"`
	FailureReason string      `json:"failure_reason"`
	// deploy-reliability W2: the ledger's own vocabulary for a failed row, which
	// this struct did NOT declare — so `git grep failure_class -- internal/`
	// returned zero while the control plane had been shipping both keys from its
	// SOLE base serializer for a whole wave. json.Unmarshal drops unmodelled keys
	// silently, so a decoder that never names them cannot report them.
	//
	//   * FailureClass is DeployLedger.classify/1 — the NAMED cause, computed from
	//     stage + the raw column. Empty on every non-failed row.
	//   * FailureReasonRaw is what the box actually said (scrubbed + ANSI-stripped
	//     server-side), for when FailureReason is the humanizer's generic arm.
	FailureClass     string `json:"failure_class,omitempty"`
	FailureReasonRaw string `json:"failure_reason_raw,omitempty"`
	// deploy-reliability W13: the deferral chain AS DATA, which this struct did
	// not declare — so the only way a Go client could recover the depth of a
	// wait was siteDeferralChainRe, a regex over the English in FailureReason.
	// Same silent-drop shape as the pair above: json.Unmarshal discards an
	// unmodelled key, so the control plane could ship these for a whole wave
	// and no decoder would notice.
	//
	// POINTERS, deliberately. nil means "this row records no chain" — a
	// non-deferred row, or any deferral written before migration
	// 20260807150000 landed on 2026-08-07 (most of them today). A plain int
	// would decode that absence to 0 and read as "deferred zero times", which
	// is a claim the payload never made.
	//
	// DeferralCause is the LEDGER CLASS (e.g. "BOX_AT_CAPACITY_DEFERRED"),
	// frozen at defer time by DeployLedger.classify/1 — not a raw box code, and
	// not re-derived if the taxonomy is later repaired.
	DeferralDepth *int    `json:"deferral_depth"`
	DeferralBound *int    `json:"deferral_bound"`
	DeferralCause *string `json:"deferral_cause"`
	// gh-6 identity: "production" | "preview", and the branch a preview was built
	// from. Declared for the same drops-unknown-keys reason as the pair above.
	Environment  string `json:"environment,omitempty"`
	Branch       string `json:"branch,omitempty"`
	BuildLogURL  string `json:"build_log_url,omitempty"`
	BecameLiveAt string `json:"became_live_at"`
	InsertedAt   string `json:"inserted_at"`
	UpdatedAt    string `json:"updated_at"`
	// dr-w23-s6: THE FOUR LAUNDERED KEYS. `site_deployment_json/3` pipes the
	// narrow producer `deployment_json/1`, so the WIDE wire has always carried
	// these four — and this struct did not declare them, so `json.Unmarshal`
	// dropped every one of them on the floor.
	//
	// It was invisible to the payload census for a structural reason worth
	// keeping: its UNREAD arm takes emitted keys against the FILE-GLOBAL union of
	// json tags in this package, and all four names are declared by OTHER structs
	// — `artifact_url`, `git_ref` and `image_tag` by the narrow `Deployment`,
	// `detail` by `SiteStage` and `WebhookProxyError`. The union greened them
	// while the struct that actually decodes this payload carried nothing. The
	// per-struct OFF-STRUCT arm added by the same slice is what can say so.
	//
	// The human consequence was two deploy readers on one platform, one silently
	// poorer: `bp sites` (the narrow path) printed the build identity and
	// `bp cloud site status` (the wide page's only consumer) could not.
	//
	// Detail is NOT SiteStage.Detail. They share a name and nothing else: this is
	// the DEPLOYMENT's own caption (`Sites.Deploy.stage_caption(d.status,
	// d.detail)` at the payload's top level), while SiteStage.Detail is the
	// PER-STAGE caption inside `stages[]`. A name-based union cannot tell those
	// apart, which is precisely why it must not be the thing deciding.
	GitRef      string `json:"git_ref"`
	ArtifactURL string `json:"artifact_url"`
	ImageTag    string `json:"image_tag"`
	Detail      string `json:"detail"`
}

// SiteDeploymentPage is one keyset page of a site's deployments, newest first —
// the WIDE twin of ListDeployments, which decodes the narrow `Deployment` and
// therefore cannot see failure_class, stage, trigger or the runtime fields.
//
// NextCursor is the `before=` token for the page BEHIND this one, and it is the
// half wave 1 S2 shipped that no client kept: without it a walk stops at the
// server's 200-row cap and reports a FLOOR as a total.
type SiteDeploymentPage struct {
	Deployments []SiteDeployment `json:"deployments"`
	NextCursor  string           `json:"next_cursor"`
}

// SiteDeploymentTerminal reports whether a deploy status is final. The status enum
// has SEVEN values — queued, building, pushing, live, failed, cancelled, deferred —
// and exactly four of them are the end of the road: live (success), failed (the
// build died), cancelled (someone stopped it), and deferred (the box refused the
// round at its build cap). The CLI's stream loop polls until this is true, so a
// terminal status missing from this set is not a cosmetic bug: the loop would poll
// its full budget (300 × 2s ≈ 10 min) and then report the deploy as still in
// progress. Both `cancelled` and `canceled` spellings count.
//
// DEFERRED IS TERMINAL, and the server is the authority on that: the transition
// table in cloud/lib/barkpark_cloud/registry/deployment.ex maps "deferred" => [],
// so a deferred row can never become anything else. It was absent from this set
// until deploy-reliability wave 32, and since deferral is 73.7% of settled deploy
// attempts (charter D209) the omission meant the MAJORITY outcome of
// `bp cloud site deploy` spun the full ten minutes and then printed
// "deploy in progress" over a settled refusal.
//
// TERMINAL IS NOT THE SAME QUESTION AS "HAS THE CONTENT REACHED THE WEB". A
// deferred ROW is settled while the PUBLISH is not — the control plane re-queues a
// rebuild carrying the same content — so the CLI's waiting predicate
// (cli.siteDeployWaiting) deliberately keeps counting deferred as a wait and does
// not read this function alone. Do not "simplify" the two back together.
func SiteDeploymentTerminal(status string) bool {
	s := strings.ToLower(strings.TrimSpace(status))
	return s == "live" || s == "failed" || s == "cancelled" || s == "canceled" || s == "deferred"
}

// SiteRollbackResult is a completed spawned-site rollback. Raw is the envelope
// bytes verbatim so `-o json` re-emits the contract without reshaping (the
// instance-rollback idiom). The scalar fields are the parsed view the human
// renderer consumes.
//
// RuntimeTarget is the mechanism the rollback used (charter D62) — the SIGNAL the
// CLI branches its narration on: a static rollback is an atomic symlink swap, a
// "node-slot" rollback is a Caddy reverse_proxy upstream flip back to the warm
// previous node slot. The rollback path never fetches the site row, so the
// envelope itself must carry the mechanism; when it is absent (a static / pre-node
// box that never sends it) the CLI falls back to the symlink-swap copy it always
// had. Port is the node slot the box flipped the upstream back to, when node.
type SiteRollbackResult struct {
	Raw                  []byte `json:"-"`
	OK                   bool   `json:"ok"`
	Status               string `json:"status"`
	DeploymentID         string `json:"deployment_id"`
	PreviousDeploymentID string `json:"previous_deployment_id"`
	URL                  string `json:"url"`
	RuntimeTarget        string `json:"runtime_target"`
	Port                 int    `json:"port"`
}

// SiteDeleteResult is the flat envelope `DELETE /v1/sites/:id` returns on success.
type SiteDeleteResult struct {
	Raw    []byte `json:"-"`
	OK     bool   `json:"ok"`
	Status string `json:"status"`
	Slug   string `json:"slug"`
}

// ContentBinding is the create-time verdict the control plane OBSERVED — its own
// read of the bound type through the new site's own token, taken before it
// answered 201. It is NOT the site row: the row records which type was STORED,
// this records whether that type could actually be READ.
//
// Status is "bound" or "unverified", and the two carry different keys because the
// control plane knows different things in each case:
//
//   - "bound" carries DocType and, when the box published a magnitude, Count.
//     COUNT IS A POINTER ON PURPOSE. The producer OMITS the key entirely when the
//     box reported no total ("bound without a magnitude is the honest shape"), so
//     absent and zero are different answers — nil means "the box published no
//     total", a pointer to 0 means "the box published a total, and it is zero". A
//     plain int collapses the two and lets a receipt print "0 documents" about a
//     site whose content was never counted.
//   - "unverified" carries DETAIL — the reason the read could not be confirmed —
//     and NO doc type: the control plane never got far enough to name one, so a
//     receipt that wants to name the type must take it from the row or the request.
//     The key is `detail`, not `reason`.
//
// The zero value is the third case: the control plane sends NO content_binding key
// at all for a kind it does not probe, and an empty Status is how a consumer tells
// "no verdict was offered" apart from "the verdict was bad".
type ContentBinding struct {
	Status  string `json:"status"`
	DocType string `json:"doc_type"`
	Count   *int   `json:"count"`
	Detail  string `json:"detail"`
}

// SpawnSiteCreated is the WHOLE POST /v1/sites 201 envelope, not just the row.
// The create-time binding verdict rides a TOP-LEVEL `content_binding` key beside
// `site`, so decoding into SpawnSite alone silently discarded it — which is how a
// caller whose create came back "unverified" was told nothing at all. Anything
// that REPORTS a create must be handed this, never the row on its own.
type SpawnSiteCreated struct {
	Site           SpawnSite      `json:"site"`
	ContentBinding ContentBinding `json:"content_binding"`
}

// CreateSpawnSite POSTs /v1/sites (Bearer) with the spawner body and returns the
// new row TOGETHER WITH the control plane's create-time binding verdict. The
// dataset triple tells the control plane which content to build from; kind
// distinguishes the row from a container-model site.
//
// An envelope with no `content_binding` key decodes to the zero ContentBinding —
// an empty Status, which every consumer must render as NOTHING, never as
// "unverified".
func (c *Client) CreateSpawnSite(ctx context.Context, req SpawnSiteCreate) (SpawnSiteCreated, error) {
	status, body, err := c.do(ctx, "POST", "/v1/sites", true, req)
	if err != nil {
		return SpawnSiteCreated{}, err
	}
	if !ok(status) {
		return SpawnSiteCreated{}, cloudError(status, body)
	}
	var out SpawnSiteCreated
	if err := json.Unmarshal(body, &out); err != nil {
		return SpawnSiteCreated{}, fmt.Errorf("decode site response: %w", err)
	}
	return out, nil
}

// GetSpawnSite returns one spawned site by id via GET /v1/sites/:id (Bearer),
// decoded into the spawner view (kind + dataset triple + embedded current
// deployment). A 404 does not leak existence across team boundaries.
// UpdateSpawnSiteSettings PATCHes /v1/sites/:id (Bearer) with the operator-
// mutable settings (search-template W8): theme (the deploy-pinned palette) and
// doc_type (the featured content type). Only the keys present in patch are sent;
// the server ignores infrastructural fields and answers 422 nothing_to_update on
// an empty body. Returns the updated row. A 404 is the same no-leak 404 GetSite
// surfaces; a 422 is *CloudRouteError{Code:"invalid_settings"|...}.
func (c *Client) UpdateSpawnSiteSettings(ctx context.Context, id string, patch map[string]any) (SpawnSite, error) {
	status, body, err := c.do(ctx, "PATCH", "/v1/sites/"+esc(id), true, patch)
	if err != nil {
		return SpawnSite{}, err
	}
	if !ok(status) {
		return SpawnSite{}, cloudError(status, body)
	}
	var out struct {
		Site SpawnSite `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return SpawnSite{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

func (c *Client) GetSpawnSite(ctx context.Context, id string) (SpawnSite, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites/"+esc(id), true, nil)
	if err != nil {
		return SpawnSite{}, err
	}
	if !ok(status) {
		return SpawnSite{}, cloudError(status, body)
	}
	var out struct {
		Site SpawnSite `json:"site"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return SpawnSite{}, fmt.Errorf("decode site response: %w", err)
	}
	return out.Site, nil
}

// DeploySpawnSite enqueues a build via POST /v1/sites/:id/deploy (Bearer) and
// returns the queued SiteDeployment — status:"queued" with a build id. The CLI
// then streams it through the six stages by polling SpawnSiteDeployment.
//
// force folds a fresh nonce into the box's build_id so an unchanged re-deploy
// mints a genuinely new releases/<build_id>/ instead of returning the cached
// (possibly failed) deployment. Without it {force:true} the body stays the empty
// object and the deploy is idempotent on identical content+config (charter D36).
func (c *Client) DeploySpawnSite(ctx context.Context, id string, force bool, via, domain string) (SiteDeployment, error) {
	req := map[string]any{}
	if force {
		req["force"] = true
	}
	// cf-in-front (D57): a `via`/`domain` pair asks the control plane to bind the
	// domain through Cloudflare (DNS + orange-cloud proxy) before the build. Ride
	// the body ONLY when set — a plain deploy stays byte-identical (mirror force).
	if via != "" {
		req["via"] = via
	}
	if domain != "" {
		req["domain"] = domain
	}
	return c.postSiteDeploy(ctx, id, req)
}

// MintPrebuiltDeployment is the FIRST of the prebuilt lane's two calls (charter
// D87): POST /v1/sites/:id/deploy with {"source":"prebuilt"} mints the
// deployment row WITHOUT starting a build, and the 201 already carries the
// build_id and content_rev the caller's own build must be stamped with.
//
// The order is forced, not chosen: build_id is derived from content_rev + config
// and is exported INTO the build so the adapter can bake the marker HEALTH later
// asserts by value — so it must exist BEFORE the bytes do, which rules out
// content-addressing the deployment by the artifact's digest.
func (c *Client) MintPrebuiltDeployment(ctx context.Context, id string, force bool) (SiteDeployment, error) {
	req := map[string]any{"source": "prebuilt"}
	if force {
		req["force"] = true
	}
	return c.postSiteDeploy(ctx, id, req)
}

// postSiteDeploy is the shared POST /v1/sites/:id/deploy body-and-decode both
// deploy lanes ride.
func (c *Client) postSiteDeploy(ctx context.Context, id string, req map[string]any) (SiteDeployment, error) {
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+esc(id)+"/deploy", true, req)
	if err != nil {
		return SiteDeployment{}, err
	}
	if !ok(status) {
		return SiteDeployment{}, cloudError(status, body)
	}
	var out struct {
		Deployment SiteDeployment `json:"deployment"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return SiteDeployment{}, fmt.Errorf("decode deployment response: %w", err)
	}
	return out.Deployment, nil
}

// UploadDeploymentArtifact is the SECOND prebuilt call: POST
// /v1/sites/:id/deployments/:dep_id/artifact with the packed tar.gz as
// application/octet-stream, the sha256 the client computed over exactly these
// bytes in X-Artifact-Sha256, and a REAL Content-Length.
//
// The declared size is the point. The retired site-scoped upload (W10) handed
// http.Client an opaque io.Reader, which sends the body chunked with
// Content-Length -1: the server cannot reject an oversized upload until it has
// read it, and the client learns the true size only after the last byte. Here
// the caller has already buffered the artifact to a temp file, so the size and
// the digest are both known up front — the server can 413 on the headers, and
// the digest travels WITH the bytes it describes so the box can re-verify before
// it stages anything.
//
// This deliberately uses a client with NO wall-clock cap: an upload's deadline is
// the caller's ctx, not the shared 30s DefaultTimeout, which is an absolute
// deadline over the whole body stream that ctx cannot extend.
func (c *Client) UploadDeploymentArtifact(ctx context.Context, siteID, deploymentID string, body io.Reader, size int64, sha256hex string) (ArtifactUpload, error) {
	if body == nil {
		return ArtifactUpload{}, fmt.Errorf("upload artifact: nil body")
	}
	if size <= 0 {
		return ArtifactUpload{}, fmt.Errorf("upload artifact: refusing to send an unsized body (%d bytes) — the prebuilt lane declares its length", size)
	}
	path := "/v1/sites/" + esc(siteID) + "/deployments/" + esc(deploymentID) + "/artifact"
	req, err := http.NewRequestWithContext(ctx, "POST", c.url(path), body)
	if err != nil {
		return ArtifactUpload{}, err
	}
	req.ContentLength = size
	req.Header.Set("Content-Type", "application/octet-stream")
	if sha256hex != "" {
		req.Header.Set("X-Artifact-Sha256", sha256hex)
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	client := c.HTTP
	if client == nil {
		client = &http.Client{}
	}
	resp, err := client.Do(req)
	if err != nil {
		return ArtifactUpload{}, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return ArtifactUpload{}, fmt.Errorf("read upload response: %w", err)
	}
	if !ok(resp.StatusCode) {
		return ArtifactUpload{}, cloudError(resp.StatusCode, raw)
	}
	var out ArtifactUpload
	if err := json.Unmarshal(raw, &out); err != nil {
		return ArtifactUpload{}, fmt.Errorf("decode upload response: %w", err)
	}
	return out, nil
}

// SpawnSiteDeployment fetches one deployment's current stage-aware state via
// GET /v1/sites/:id/deployments/:deploymentID (Bearer) — the poll the deploy
// stream loop reads until the status is terminal.
func (c *Client) SpawnSiteDeployment(ctx context.Context, id, deploymentID string) (SiteDeployment, error) {
	status, body, err := c.do(ctx, "GET", "/v1/sites/"+esc(id)+"/deployments/"+esc(deploymentID), true, nil)
	if err != nil {
		return SiteDeployment{}, err
	}
	if !ok(status) {
		return SiteDeployment{}, cloudError(status, body)
	}
	var out struct {
		Deployment SiteDeployment `json:"deployment"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return SiteDeployment{}, fmt.Errorf("decode deployment response: %w", err)
	}
	return out.Deployment, nil
}

// ListSpawnSiteDeployments reads a site's deployments newest-first via
// GET /v1/sites/:id/deployments (Bearer) into the WIDE SiteDeployment, so a
// caller can see the failure_class the control plane computes. ListDeployments
// hits the same route but decodes the narrow `Deployment`, sends no bounds and
// throws next_cursor away; both exist because the narrow one is the older
// `bp sites` contract and widening it in place would reshape that verb's output.
//
// limit ≤ 0 sends no `limit` (the server's default 100 applies; it caps at 200).
// before is a next_cursor from a previous page — anything else is a 422 from the
// server, never a silent page one.
func (c *Client) ListSpawnSiteDeployments(ctx context.Context, siteID string, limit int, before string) (SiteDeploymentPage, error) {
	path := "/v1/sites/" + esc(siteID) + "/deployments"
	q := url.Values{}
	if limit > 0 {
		q.Set("limit", fmt.Sprintf("%d", limit))
	}
	if b := strings.TrimSpace(before); b != "" {
		q.Set("before", b)
	}
	if len(q) > 0 {
		path += "?" + q.Encode()
	}
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return SiteDeploymentPage{}, err
	}
	if !ok(status) {
		return SiteDeploymentPage{}, cloudError(status, body)
	}
	var page SiteDeploymentPage
	if err := json.Unmarshal(body, &page); err != nil {
		return SiteDeploymentPage{}, fmt.Errorf("decode deployments response: %w", err)
	}
	return page, nil
}

// DeployRate is one rate NODE from the fleet deploy census: a percentage that
// can never travel without the denominator that produced it, and that REFUSES
// to be a percentage below `min_sample` rather than reporting a number nobody
// should act on (`Pct` nil, `Refused` true, `Reason` saying so in words).
//
// Pct is a POINTER on purpose: a refusing node sends JSON null, and a float64
// would decode that as 0.0 — the exact comforting zero this reader exists to
// stop. Basis is the s1 addition (the name of what the denominator counts); it
// is empty against today's payload and a reader must survive that.
type DeployRate struct {
	Sample    int      `json:"sample"`
	Pct       *float64 `json:"pct"`
	Numerator int      `json:"numerator"`
	MinSample int      `json:"min_sample"`
	Refused   bool     `json:"refused"`
	Reason    string   `json:"reason"`
	Basis     string   `json:"basis"`
}

// DeployCensusClass is one failure/deferral/not-attempted class row: the machine
// class, its human label, its count, and that count's share WITH the denominator
// the share was taken against (class shares are denominated on `failed`,
// deferred shares on `volume` — which is why the share carries its own sample).
type DeployCensusClass struct {
	Class string `json:"class"`
	Label string `json:"label"`
	// Agency is WHO the class accuses — box / site / ambiguous, frozen in
	// DeployLedger's own @agency map (dr-w31-fu-agency-reaches-the-cli).
	// class_rows/3 has emitted it on EVERY census class row and this struct
	// did not declare it, so json.Unmarshal dropped it silently — the
	// operator running `bp cloud deployments` could not see who a failure
	// class accuses. Empty means an older control plane that never sent it,
	// and the render says "not sent" rather than inventing an attribution.
	Agency string     `json:"agency"`
	Count  int        `json:"count"`
	Share  DeployRate `json:"share"`
}

// DeployCensusSite is one site's slice of the window: its volume, its failures,
// its deferrals, the rows that actually went LIVE, its own rate node and the
// class that hurt it most (nil when the site had no failures at all — never an
// invented "none" class).
//
// Live is the dr-w19-s7 addition, and it closes a DECODER gap, not a payload
// one: deploy_ledger.ex site_row/2 has emitted a per-site `live` since #10519
// (a real 200 on a team credential returned {"failed":1,"live":109,
// "deferred":325,"volume":435} — 109+325+1 = 435 exactly), and this struct had
// six fields and no Live, so the wire's per-site success decoded to nothing and
// no guard reds (D260's blind spot: the UNREAD arm compares against a
// FILE-GLOBAL tag union and `live` is already a tag on DeployCensus).
//
// It is a POINTER for the same reason DeployCensus.Live is: a control plane
// predating #10519 sends no per-site `live` key at all, and "this control plane
// does not name per-site success" must render UNMETERED — never a zero-live
// site, which is the most alarming reading of an absence there is.
//
// A reader computes the per-site live rate from Live/Volume READ POSITIVELY off
// the wire. `Volume - Failed - Deferred` is FORBIDDEN: it folds in-flight,
// cancelled and residual rows back into live, re-creating exactly the unnamed
// remainder dr-w16-s2 deleted — and site_row/2's own comment forbids that
// subtraction at the source.
type DeployCensusSite struct {
	SiteID      string     `json:"site_id"`
	Volume      int        `json:"volume"`
	Failed      int        `json:"failed"`
	Deferred    int        `json:"deferred"`
	Live        *int       `json:"live"`
	FailureRate DeployRate `json:"failure_rate"`
	// TerminalFailureRate is the dr-w12-s8 addition, the per-site twin of the
	// fleet key of the same name: the same numerator over failed+live instead of
	// over every attempted row. A POINTER for the reason all its neighbours are —
	// a control plane predating this slice sends no per-site terminal rate, and
	// that must not decode into a site whose terminal rate is 0% of 0 rows, which
	// is the most flattering possible reading of an absence.
	//
	// It is declared HERE and not left to ride the file-global tag union on
	// DeployCensus's identically-named field: that is charter D260 exactly, and
	// json.Unmarshal would drop the per-site key on the floor while every
	// name-based guard stayed green.
	TerminalFailureRate *DeployRate `json:"terminal_failure_rate"`
	TopClass            *string     `json:"top_class"`
}

// DeployCensusWindow is the PINNED window the census was taken over, echoed back
// by the control plane. There is no default window server-side (a floating one
// compares two different populations), so this is always the window the caller
// asked for — and a caller that prints a rate without printing this is quoting a
// number with no population.
type DeployCensusWindow struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// DeployCensusScope is the `scope` node the TEAM census route emits on every
// 200: which population the numbers above were taken over, by NAME.
//
// It exists because the same census body is honest arithmetic over a population
// the reader never chose — a rate over "the caller's own sites" and a rate over
// "the whole fleet" are different claims that render identically. Team is the
// team SLUG (the route holds the whole team and a UUID cannot render "team
// guerrilla").
//
// RegisteredSites is deliberately NOT len(Sites): it counts sites REGISTERED to
// the team and inside this request's scope, which is larger than the set that
// actually deployed in the window (a site that has never deployed is counted
// here and absent from `sites`). RegisteredSitesPopulation is the route's own
// sentence saying exactly that, so a reader printing the count can print what it
// counts rather than inventing a label.
type DeployCensusScope struct {
	Team                      string   `json:"team"`
	SiteIDs                   []string `json:"site_ids"`
	RegisteredSites           int      `json:"registered_sites"`
	RegisteredSitesPopulation string   `json:"registered_sites_population"`
}

// DeployCensus is GET /v1/deploy-ledger/census — the cross-site deploy
// ledger folded into counts per failure class, counts per site, and the failure
// rate WITH its denominator, scoped to the caller's own team sites.
//
// Live and TerminalFailureRate are the dr-w8-s1 additions (the second D34
// convention: failures over TERMINAL rows rather than over attempted rows). Both
// are pointers so a reader can tell "the control plane did not send this" from
// "the control plane sent zero" — today's deployed payload carries neither.
//
// Raw is the envelope bytes verbatim so `-o json` re-emits the contract instead
// of a second, drifting definition of it.
type DeployCensus struct {
	Window              DeployCensusWindow `json:"window"`
	Volume              int                `json:"volume"`
	Failed              int                `json:"failed"`
	Live                *int               `json:"live"`
	FailureRate         DeployRate         `json:"failure_rate"`
	TerminalFailureRate *DeployRate        `json:"terminal_failure_rate"`
	// LivePerAttempt, InFlight, Cancelled and Residual are the dr-w16-s2
	// additions: the census now names EVERY state an attempt can end in, so
	// success stops being the unnamed part of Volume.
	//
	// All four are POINTERS for the same reason Live is: a control plane that
	// predates this slice sends none of them, and "this CP does not name
	// in-flight rows" must not decode to "nothing is building right now".
	//
	// Residual is the honest tail — attempted rows whose status the census does
	// not name. It is expected to be 0 and must be able to RISE; a reader that
	// treats a non-zero residual as noise has re-created the unnamed remainder
	// this slice deleted.
	LivePerAttempt *DeployRate         `json:"live_rate"`
	InFlight       *int                `json:"in_flight"`
	Cancelled      *int                `json:"cancelled"`
	Residual       *int                `json:"residual"`
	Classes        []DeployCensusClass `json:"classes"`
	Deferred       []DeployCensusClass `json:"deferred"`
	// DeferredTotal, Abandoned and AbandonedUnreadable are the
	// dr-w12-s8 additions.
	//
	// DeferredTotal is the scalar the two failure rates differ by. The CLI has
	// always summed Deferred's class counts itself; that client-side sum is a
	// SECOND definition of the number living on the far side of the wire, and it
	// silently answers 0 for a control plane that sent no class rows at all. The
	// server's own count wins where it is sent.
	//
	// Abandoned is the crown count: publishes GIVEN UP ON after the refusal chain
	// hit its bound. AbandonedUnreadable is what makes it honest — failed rows
	// whose failure_reason recorded nothing, so the abandonment predicate (prose,
	// anchored on Sites.Deploy.abandonment_reason) could not RUN on them. With
	// both, three states are distinguishable that one integer collapses into one:
	// nil = this control plane does not count abandonments; 0 with 0 unreadable =
	// none happened; 0 with N unreadable = nothing legible said so, and 0 is a
	// LOWER BOUND. That is the whole reason these are pointers.
	DeferredTotal       *int                `json:"deferred_total"`
	Abandoned           *int                `json:"abandoned"`
	AbandonedUnreadable *int                `json:"abandoned_unreadable"`
	NotAttempted        []DeployCensusClass `json:"not_attempted"`
	Sites               []DeployCensusSite  `json:"sites"`
	MinSample           int                 `json:"min_sample"`
	// Delivery is the dr-w11-s4 addition: the time-to-web census. A POINTER
	// because today's control plane sends no `delivery` key at all, and "the
	// control plane does not measure delivery yet" must not decode to "delivery
	// took zero seconds".
	Delivery *DeployDelivery `json:"delivery"`
	// DeferralWait is the dr-w28-s4 addition: how long the re-queue a deferral
	// promises actually TOOK. A POINTER for the same reason Delivery is — a
	// control plane predating that slice sends no `deferral_wait` key at all,
	// and "this control plane does not measure the re-queue" must never decode
	// into "the re-queue took zero seconds", which is the most flattering
	// possible reading of an absence.
	DeferralWait *DeployDeferralWait `json:"deferral_wait"`
	// CoverageCohorts is the dr-w32-s3 addition: the SAME later-live clock as
	// DeferralWait, applied to BOTH the deferred and the failed-terminating
	// cohorts, so the rows that never reached live are visible whichever status
	// they terminated in. A POINTER for the same reason its two neighbours are:
	// a control plane that does not send the key has not measured coverage, and
	// that must never decode into "nothing is uncovered".
	CoverageCohorts *DeployCoverageCohorts `json:"coverage_cohorts"`
	// Scope is the dr-w18-s1 addition: the population these numbers were taken
	// over, NAMED. A POINTER because the operator route (and any control plane
	// predating the team route) sends no `scope` key at all, and an absent key
	// decoding into a zero-valued struct would render as a census of team "" —
	// an unnamed population dressed as a named one. Nil MUST render as "the
	// population was NOT NAMED", never as an empty team.
	Scope *DeployCensusScope `json:"scope"`
	// CoalescedAttempts is the dr-w23-s4 addition: the gauge for deploy attempts
	// that minted NO deployment row at all (AutoDeployWorker coalesced them onto
	// an in-flight build). It is DISJOINT from Volume and never folded into it —
	// a deferred row IS in Volume; a coalesced attempt produced no row to count.
	//
	// It is a POINTER for the same reason Delivery is: every control plane older
	// than this counter sends no key, and "this control plane does not measure
	// the attempts it drops" must not decode to "it drops none". Before this
	// field existed the value rode the wire and reached `-o json` only because
	// `-o json` re-emits Raw verbatim — no Go struct in this package named it,
	// so no human render could.
	CoalescedAttempts *DeployCoalescedAttempts `json:"coalesced_attempts"`
	// TotalSites and Truncated are the dr-w24 server-side cut markers.
	// `DeployLedger.census/3` clamps `sites` at 50 rows and has always cut
	// SILENTLY on this wire: before these two fields the CLI's own "… and N
	// more" line was derived from its DISPLAY clamp, so the top 50 of a large
	// fleet was byte-indistinguishable from a complete 50-site fleet.
	//
	// BOTH ARE POINTERS, and the polarity is the point. A control plane older
	// than dr-w18-s2 sends neither key; a `bool` would decode that absence as
	// `false` — "this list is complete" — which is the most flattering possible
	// reading of an absence and exactly the claim the marker exists to stop.
	// nil = the control plane did not say; false = it AFFIRMED completeness;
	// true = the server cut the list and TotalSites names the real population.
	TotalSites *int  `json:"total_sites"`
	Truncated  *bool `json:"truncated"`
	// Completeness is `census/3`'s second independent count: `audited` rows in
	// the window reconciled against every cohort the envelope names. A POINTER
	// because an older control plane has not audited anything, and that must
	// never decode into a zero-valued struct whose `balanced: false` reads as a
	// real reconciliation failure (or `unaccounted: 0` as a real balance).
	Completeness *DeployCensusCompleteness `json:"completeness"`
	// Boundaries is the vocabulary-boundary list: the instants at which the
	// ledger's own labels changed meaning, with the derivation that fixed each.
	// A nil slice is a control plane that sent none; the render layer already
	// treats "no boundary rows" as "no provenance to offer", never as an error.
	Boundaries []DeployCensusBoundary `json:"boundaries"`
	Raw        []byte                 `json:"-"`
}

// DeployCensusCompleteness is the envelope's own audit of itself: a SECOND,
// independent count of the window's rows (`audited`) against the sum every
// cohort accounts for (`accounted`). `unaccounted` is the difference the
// producer computed — carried on the wire rather than recomputed here, so this
// reader repeats the audit instead of performing a third one. `reason` is a
// POINTER: the producer sends null when the audit balanced, and an empty string
// would erase the difference between "balanced, nothing to say" and "a reason
// the decode dropped".
type DeployCensusCompleteness struct {
	Audited     int     `json:"audited"`
	Accounted   int     `json:"accounted"`
	Unaccounted int     `json:"unaccounted"`
	Balanced    bool    `json:"balanced"`
	Method      string  `json:"method"`
	Reason      *string `json:"reason"`
}

// DeployCensusBoundary is ONE row of the census envelope's `boundaries` list:
// an instant at which the ledger's own vocabulary changed, with the derivation
// that fixed it (method + source), so a refusal remedy built on it can show its
// provenance. Instant stays a STRING here — parsing (and dropping rows whose
// instant does not parse) is the render layer's judgment, not the decoder's.
type DeployCensusBoundary struct {
	Subject string `json:"subject"`
	Instant string `json:"instant"`
	Method  string `json:"method"`
	Source  string `json:"source"`
}

// DeployCoalescedAttempts is the coalesced-attempt gauge WITH its own refusal —
// the same shape as a DeployRate and for the same reason: it has three endings
// and none of them is a zero.
//
// Value is a POINTER because the producer sends `null` when it REFUSES. The
// refusal is not a sampling floor but a COVERAGE floor: the counter column
// landed in migration 20260807150000, and PostgreSQL materialised its `0`
// default onto every pre-existing row, so a SUM over any window starting before
// Since reads a confident `0` for days whose true coalesced volume ran into the
// thousands. A reader that decodes that null into an int prints exactly the
// false confidence the producer refused to print.
type DeployCoalescedAttempts struct {
	Value   *int   `json:"value"`
	Refused bool   `json:"refused"`
	Reason  string `json:"reason"`
	Since   string `json:"since"`
	Basis   string `json:"basis"`
}

// DeployDeliveryWindow is the delivery census's PINNED window WITH its width —
// the width is part of the payload because a latency swings 829x with it, so a
// reader that prints the number without the width is quoting an unfalsifiable
// figure.
type DeployDeliveryWindow struct {
	From         string `json:"from"`
	To           string `json:"to"`
	WidthSeconds int    `json:"width_seconds"`
}

// DeployDeliveryQuantile is ONE percentile of the time content waited to reach
// the web — and it is INSEPARABLE: the value cannot travel without the window
// width, the sample, and how much of that sample is STILL WAITING.
//
// Seconds is a pointer for the same reason DeployRate.Pct is: a refused node
// sends null, and a float64 would decode that as 0.0 — a fleet that looks
// instant because nobody could measure it. Three refusals reach here (below
// min_sample; censored_fraction above the 1-q headroom; the row AT the quantile
// is itself still waiting) and every one of them means NO NUMBER, never zero.
type DeployDeliveryQuantile struct {
	Quantile         float64  `json:"quantile"`
	Label            string   `json:"label"`
	Seconds          *float64 `json:"seconds"`
	Sample           int      `json:"sample"`
	Censored         int      `json:"censored"`
	CensoredFraction float64  `json:"censored_fraction"`
	Headroom         float64  `json:"headroom"`
	WindowSeconds    int      `json:"window_seconds"`
	MinSample        int      `json:"min_sample"`
	Refused          bool     `json:"refused"`
	Reason           string   `json:"reason"`
	Basis            string   `json:"basis"`
}

// DeployDeliveryCensored is the STILL-WAITING cohort: how many rows have not
// been delivered, the lower bound on the longest of those waits, and the instant
// the bound was taken.
//
// AsOf is not decoration. The same pinned window answered stranded 3 → 2 → 0
// within five minutes, so a bare count is printing its own measurement latency;
// this reader prints "STILL WAITING >= X" beside the instant, never a bare 0.
type DeployDeliveryCensored struct {
	Count                      int      `json:"count"`
	AsOf                       string   `json:"as_of"`
	StillWaitingAtLeastSeconds *float64 `json:"still_waiting_at_least_seconds"`
}

// DeployDeliverySite is one site's slice of the delivery window: how many rows
// were measured, how many were delivered, how many are still waiting, how many
// the clock could not reach at all, and the oldest wait still running.
type DeployDeliverySite struct {
	SiteID               string   `json:"site_id"`
	Sample               int      `json:"sample"`
	Delivered            int      `json:"delivered"`
	Censored             int      `json:"censored"`
	Unmetered            int      `json:"unmetered"`
	StillWaiting         bool     `json:"still_waiting"`
	OldestWaitingSeconds *float64 `json:"oldest_waiting_seconds"`
	AsOf                 string   `json:"as_of"`
}

// DeployDelivery is `delivery` on the census envelope: how long content WAITED
// to reach the web, with an estimator that can refuse and a cohort that names
// who is still waiting (DeployLedger.delivery/3).
//
// Clock is the payload's own statement of what t0 is — today the deployment ROW
// (inserted_at → became_live_at), a proxy for the publish-keyed clock dr-w11-s1
// starts. A reader that prints a latency without printing its clock is asking to
// be believed.
//
// Unmetered is the cohort the clock could NOT reach (a live row with no
// became_live_at). It is reported, never subtracted in silence: the whole reason
// this node exists is that a number which improves because rows stopped being
// counted is the vacuous green this epic refuses.
type DeployDelivery struct {
	Window      DeployDeliveryWindow   `json:"window"`
	AsOf        string                 `json:"as_of"`
	Environment string                 `json:"environment"`
	Clock       string                 `json:"clock"`
	Sample      int                    `json:"sample"`
	Delivered   int                    `json:"delivered"`
	P50         DeployDeliveryQuantile `json:"p50"`
	P95         DeployDeliveryQuantile `json:"p95"`
	Max         DeployDeliveryQuantile `json:"max"`
	Censored    DeployDeliveryCensored `json:"censored"`
	Unmetered   int                    `json:"unmetered"`
	MinSample   int                    `json:"min_sample"`
	Sites       []DeployDeliverySite   `json:"sites"`
}

// DeployDeferralWaitPopulation is the deferral-wait sample WITH everything that
// is NOT in it. Covered + Pending + Unreadable == Deferred; a reader that prints
// a p50 without printing Pending is quoting a survivor-biased number, because
// the rows still waiting are precisely the slow ones the estimator cannot see.
type DeployDeferralWaitPopulation struct {
	Deferred   int `json:"deferred"`
	Covered    int `json:"covered"`
	Pending    int `json:"pending"`
	Unreadable int `json:"unreadable"`
}

// DeployDeferralWaitOutcome is one cohort of the deferral population, carrying
// the control plane's own wording for it. The vocabulary is exactly COVERED /
// PENDING / UNREADABLE, and a reader must render Label rather than inventing a
// gloss: COVERED means "the site has since rebuilt", NEVER "your edit shipped".
type DeployDeferralWaitOutcome struct {
	Outcome string `json:"outcome"`
	Label   string `json:"label"`
	Count   int    `json:"count"`
}

// DeployDeferralWaitQuantile is ONE percentile of the deferral wait, and it can
// REFUSE two ways: below min_sample, and when the unresolved fraction exceeds
// the 1-q headroom the quantile needs. Seconds is a POINTER because a refusal
// sends null and a float64 would decode that as 0.0 — a fleet whose re-queues
// look instant because nobody could measure them.
type DeployDeferralWaitQuantile struct {
	Quantile           float64  `json:"quantile"`
	Label              string   `json:"label"`
	Seconds            *float64 `json:"seconds"`
	Sample             int      `json:"sample"`
	Unresolved         int      `json:"unresolved"`
	UnresolvedFraction float64  `json:"unresolved_fraction"`
	Headroom           float64  `json:"headroom"`
	MinSample          int      `json:"min_sample"`
	Refused            bool     `json:"refused"`
	Reason             string   `json:"reason"`
	Basis              string   `json:"basis"`
}

// DeployDeferralWait is `deferral_wait` on the census envelope: the number
// behind the sentence "a deferral is re-queued, not lost" (DeployLedger's
// deferral_wait). Until it existed, `deferred` was a COUNT with no clock, so a
// fleet that improved its failure rate by relabelling every 409 `deferred` read
// as a fleet getting better even when the rebuild arrived six hours later.
//
// Clock is the payload's own statement of what is being measured — a TIME-keyed
// join (deferred row → the first later-MINTED live build on the same site and
// environment), deliberately NOT keyed on content_rev, which is not a revision,
// is not injective across sites, and recurs.
//
// OldestPendingSeconds is a LOWER BOUND on a wait still running, and it is a
// pointer: no pending rows means there is no bound to state, which is not zero.
type DeployDeferralWait struct {
	Clock                string                       `json:"clock"`
	Basis                string                       `json:"basis"`
	AsOf                 string                       `json:"as_of"`
	Population           DeployDeferralWaitPopulation `json:"population"`
	Outcomes             []DeployDeferralWaitOutcome  `json:"outcomes"`
	Sample               int                          `json:"sample"`
	Unresolved           int                          `json:"unresolved"`
	OldestPendingSeconds *float64                     `json:"oldest_pending_seconds"`
	P50                  DeployDeferralWaitQuantile   `json:"p50"`
	P95                  DeployDeferralWaitQuantile   `json:"p95"`
	Max                  DeployDeferralWaitQuantile   `json:"max"`
	MinSample            int                          `json:"min_sample"`
}

// DeployCoverageEnvironment splits ONE cohort's never-covered count by
// environment. A preview build with no successor is not a production site
// sitting dark, and pooling the two hides the rows that matter inside a bigger,
// softer number.
type DeployCoverageEnvironment struct {
	Environment  string `json:"environment"`
	NeverCovered int    `json:"never_covered"`
}

// DeployCoverageCohort is ONE never-live cohort — `deferred` or `failed` —
// partitioned by the coverage clock. Population == Covered + Pending +
// Unreadable, and Pending splits again into NeverCovered (older than the
// maturity fence) and TooYoung.
//
// COVERED IS THE CONTROL PLANE'S WORD AND IT MEANS "the site has since rebuilt".
// It is not a claim that any particular edit shipped, and a renderer that
// upgrades it into one is the mis-report this whole section exists to prevent.
type DeployCoverageCohort struct {
	Cohort                    string                      `json:"cohort"`
	Status                    string                      `json:"status"`
	Population                int                         `json:"population"`
	Covered                   int                         `json:"covered"`
	Pending                   int                         `json:"pending"`
	Unreadable                int                         `json:"unreadable"`
	Matured                   int                         `json:"matured"`
	NeverCovered              int                         `json:"never_covered"`
	TooYoung                  int                         `json:"too_young"`
	NeverCoveredByEnvironment []DeployCoverageEnvironment `json:"never_covered_by_environment"`
	OldestPendingSeconds      *float64                    `json:"oldest_pending_seconds"`
}

// DeployCoverageSite is ONE never-covered {site, environment} pair, BY NAME.
//
// The counts one struct up say how many rows are sitting dark and refuse to say
// where — and the control plane already had `site_id` on every row it folded, so
// the anonymity was an omission and never a limit. Name and Slug are resolved
// from the site registry and may be empty when the site row has since been
// deleted: an empty name is "no site row answered", never a site called "".
type DeployCoverageSite struct {
	SiteID       string `json:"site_id"`
	Name         string `json:"name"`
	Slug         string `json:"slug"`
	Environment  string `json:"environment"`
	NeverCovered int    `json:"never_covered"`
}

// DeployCoverageCohorts is `coverage_cohorts` on the census envelope: the
// coverage partition over BOTH never-live cohorts. DeferralWait one struct up
// answers "how long did the re-queue take" over DEFERRED rows only, and is blind
// by construction to the chains that terminate `failed` — a third of the
// never-live tail on the corpus that motivated this key.
//
// MaturitySeconds is the fence under which a PENDING row is not counted as never
// covered: a row written minutes ago has not been given time to be covered, and
// counting it as damage would report the fleet's own arrival rate as failure.
//
// CoveringBound is the covering query's own bound as one token ("left_only"):
// the basis paragraph says it in English, and a reader that wants to know
// whether the number in front of it was computed against a right-bounded window
// should not have to parse prose to find out. It is NOT on the window map —
// that one is half-open [from, to) and bounded on both sides.
//
// NeverCoveredSites NAMES the tail the counts can only size, and it is BOUNDED:
// NeverCoveredSitesTotal is the unbounded population and
// NeverCoveredSitesTruncated says whether the list was cut. A list that cuts
// silently is the same anonymity one level down.
//
// COUNT UNIT, said once so nobody has to guess: both the list and the total are
// over {site_id, environment} PAIRS, never over distinct sites. One site dark in
// both production and preview contributes TWO entries and TWO to the total, and
// the per-cohort NeverCovered counts one struct up are over ROWS — three units,
// three names, none of them interchangeable.
type DeployCoverageCohorts struct {
	Clock                      string                 `json:"clock"`
	Basis                      string                 `json:"basis"`
	AsOf                       string                 `json:"as_of"`
	MaturitySeconds            int                    `json:"maturity_seconds"`
	CoveringBound              string                 `json:"covering_bound"`
	Cohorts                    []DeployCoverageCohort `json:"cohorts"`
	NeverCoveredSites          []DeployCoverageSite   `json:"never_covered_sites"`
	NeverCoveredSitesTotal     int                    `json:"never_covered_sites_total"`
	NeverCoveredSitesTruncated bool                   `json:"never_covered_sites_truncated"`
}

// DeployCensusError is a census the control plane REFUSED to answer, with the
// status and the refusal's own evidence kept intact — because the whole point of
// this reader is that a human can tell "the fleet is healthy" from "I could not
// look". Four shapes reach it from the TEAM route this client reads:
//
//   - 401 {"error":"unauthorized"} — no credential, or a dead one.
//   - 403 {"error":"forbidden","scope":"token","required":"read"} — authenticated,
//     but the credential does not carry ability "read" (require_ability/2). It
//     names the AUTHORITY that was missing, and that authority is a TOKEN
//     ability, not membership of an operator allowlist — a reader that pins the
//     old operator-route sentence here would send a team owner to edit
//     PLATFORM_ADMIN_EMAILS, a remedy that cannot change this refusal.
//   - 422 {"error":"no_team"} — the credential resolves to no team, so there is
//     no population to take a census over. This is a DIFFERENT refusal from the
//     window one below and shares only its status: no window can fix it.
//   - 422 {"error":"invalid_window","detail":"…"} — the window did not parse, or
//     was not pinned at all.
//
// The two 422s are why a caller must branch on Code and not on HTTPStatus alone.
//
// A caller must branch on this error BEFORE it reads any count, since the refusal
// body and the census body share zero keys and a nil-coalescing read of the
// refusal renders a fleet with zero failures.
type DeployCensusError struct {
	HTTPStatus int
	Code       string
	Detail     string
	Scope      string
	Required   string
	Raw        []byte
}

func (e *DeployCensusError) Error() string {
	msg := e.Code
	if msg == "" {
		msg = http.StatusText(e.HTTPStatus)
	}
	if e.Detail != "" {
		msg += ": " + e.Detail
	}
	return msg
}

// FleetDeployCensus reads the deploy census over a PINNED window via
// GET /v1/deploy-ledger/census?from=&to= (Bearer — a user session or a PAT
// carrying ability "read"), scoped to the caller's own team sites.
//
// IT READS THE TEAM ROUTE, NOT THE OPERATOR ONE (dr-w18-s1). The operator route
// /v1/operator/deploy-ledger/census is gated by require_platform_operator and
// PLATFORM_ADMIN_EMAILS is unset in production, so that route answers 403
// {"scope":"platform","required":"platform_operator"} to every real account —
// an empty-by-construction population. Sixteen waves computed a correct number
// no human could read. The team route answers 200 to the same credential and
// carries a `scope` node naming the population, which is why DeployCensus.Scope
// exists.
//
// from/to are REQUIRED by the route (it 422s invalid_window without them) and
// are sent as RFC3339 UTC instants; the caller owns the window and there is no
// client-side default here either, so nothing can quote a rate over a window
// nobody chose. Every non-2xx becomes a *DeployCensusError carrying the status
// and the refusal's evidence — never a zero-valued census.
func (c *Client) FleetDeployCensus(ctx context.Context, from, to time.Time) (DeployCensus, error) {
	q := url.Values{}
	q.Set("from", from.UTC().Format(time.RFC3339))
	q.Set("to", to.UTC().Format(time.RFC3339))
	// Give the window-width-proportional aggregation headroom past DefaultTimeout
	// (see FleetDeployCensusTimeout). An injected HTTP client (tests) is honored
	// untouched; only the lazily-built fallback is widened, and only for this call.
	cc := *c
	if cc.HTTP == nil {
		cc.HTTP = &http.Client{Timeout: FleetDeployCensusTimeout}
	}
	status, body, err := cc.do(ctx, "GET", "/v1/deploy-ledger/census?"+q.Encode(), true, nil)
	if err != nil {
		return DeployCensus{}, err
	}
	if !ok(status) {
		return DeployCensus{}, deployCensusError(status, body)
	}
	var census DeployCensus
	if err := json.Unmarshal(body, &census); err != nil {
		return DeployCensus{}, fmt.Errorf("decode deploy census response: %w", err)
	}
	census.Raw = body
	return census, nil
}

// deployCensusError decodes a refusal envelope into the typed error. A body that
// does not decode still yields a typed error carrying the STATUS, so the reader
// keeps its "I could not look" branch even against a gateway HTML page.
func deployCensusError(status int, body []byte) error {
	var env struct {
		Error    string `json:"error"`
		Detail   string `json:"detail"`
		Scope    string `json:"scope"`
		Required string `json:"required"`
	}
	_ = json.Unmarshal(body, &env)
	return &DeployCensusError{
		HTTPStatus: status,
		Code:       strings.TrimSpace(env.Error),
		Detail:     strings.TrimSpace(env.Detail),
		Scope:      strings.TrimSpace(env.Scope),
		Required:   strings.TrimSpace(env.Required),
		Raw:        body,
	}
}

// RollbackSpawnSite flips a spawned site back to its previous good build via
// POST /v1/sites/:id/rollback (Bearer) — a sub-second flip whose mechanism depends
// on the runtime target: an atomic symlink swap for a static site, a Caddy
// upstream port-flip to the warm previous slot for a node site (the envelope's
// runtime_target says which). Raw is the envelope bytes verbatim so `-o json`
// re-emits the contract.
func (c *Client) RollbackSpawnSite(ctx context.Context, id string) (SiteRollbackResult, error) {
	status, raw, err := c.do(ctx, "POST", "/v1/sites/"+esc(id)+"/rollback", true, nil)
	if err != nil {
		return SiteRollbackResult{}, err
	}
	if !ok(status) {
		return SiteRollbackResult{}, cloudError(status, raw)
	}
	res := SiteRollbackResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return SiteRollbackResult{}, fmt.Errorf("decode rollback envelope: %w", err)
	}
	return res, nil
}

// DeleteSpawnSite tears a site down on its box and deregisters it (DELETE
// /v1/sites/:id). Non-2xx (e.g. a teardown the box refused) is a cloudError, so
// the caller never prints a false "deleted".
func (c *Client) DeleteSpawnSite(ctx context.Context, id string) (SiteDeleteResult, error) {
	status, raw, err := c.do(ctx, "DELETE", "/v1/sites/"+esc(id), true, nil)
	if err != nil {
		return SiteDeleteResult{}, err
	}
	if !ok(status) {
		return SiteDeleteResult{}, cloudError(status, raw)
	}
	res := SiteDeleteResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return SiteDeleteResult{}, fmt.Errorf("decode delete envelope: %w", err)
	}
	return res, nil
}

// GithubConnectResp is the body the control plane returns from
// POST /v1/sites/:id/github — the updated Site row, the webhook URL the user
// pastes into GitHub, and the plaintext webhook secret (shown ONCE; the
// server stores only the Vault-encrypted blob).
type GithubConnectResp struct {
	Site          Site   `json:"site"`
	WebhookURL    string `json:"webhook_url"`
	WebhookSecret string `json:"webhook_secret"`
}

// WebhookProxyError is the `error` object of a FAILURE envelope from the
// instance-API webhook proxy (charter D51). Only `code` is always present; the
// rest ride selectively — `hint` on capability_unavailable, `status`+`detail`
// on upstream_error (the instance's OWN status + error body relayed verbatim).
type WebhookProxyError struct {
	Code   string          `json:"code"`
	Hint   string          `json:"hint,omitempty"`
	Status int             `json:"status,omitempty"`
	Detail json.RawMessage `json:"detail,omitempty"`
}

// WebhookProxyResult is one reply from the instance-API webhook proxy
// (`/v1/barkparks/:id/api/webhooks*`, charter C4/C5). The proxy normalises every
// instance reply — success, honest degradation, or an upstream error — into the
// SAME envelope, so the CLI reads exactly ONE shape:
//
//	success   {"ok":true,"resource":"webhook","data":<instance payload>}
//	failure   {"ok":false,"error":{"code":"…", …}[,"reachable":false]}
//
// Raw is the envelope BYTES verbatim so `-o json` can re-emit the contract
// without reshaping (D4). Data/Err/Reachable are the parsed views the table
// path and the honest-degradation renderer consume. Status is the control
// plane's HTTP status (200 on success; the instance's own status on an
// upstream_error relay).
type WebhookProxyResult struct {
	Status    int                `json:"-"`
	Raw       []byte             `json:"-"`
	OK        bool               `json:"ok"`
	Resource  string             `json:"resource"`
	Data      json.RawMessage    `json:"data"`
	Err       *WebhookProxyError `json:"error"`
	Reachable *bool              `json:"reachable"`
}

// webhookBase is the proxy path prefix for one instance's webhooks. `id` is the
// barkpark UUID (the CLI resolves name→id before calling); esc hardens a
// user-typed id against path-reshaping just like the other cloudclient routes.
func webhookBase(id string) string {
	return "/v1/barkparks/" + esc(id) + "/api/webhooks"
}

// withDataset appends the `?dataset=` selector the proxy substitutes into the
// instance path template (default "production" is applied by the CLI, never
// blank here). url.Values encodes the value so an exotic dataset slug can't
// reshape the query.
func withDataset(path, dataset string) string {
	q := url.Values{}
	q.Set("dataset", dataset)
	return path + "?" + q.Encode()
}

// webhookProxy issues one webhook-proxy call with the CLOUD Bearer token (never
// an instance token — the proxy holds instance custody server-side) and returns
// the normalised envelope. A transport error, or a body that is NOT the proxy
// envelope (no `ok` key — e.g. a control-plane auth/routing error), surfaces as
// a Go error via cloudError; a well-formed FAILURE envelope is NOT an error —
// it is honest degradation the caller renders (reachable:false, capability
// unavailable, upstream_error), so the CLI can act on it instead of a bare exit.
func (c *Client) webhookProxy(ctx context.Context, method, path string, body any) (WebhookProxyResult, error) {
	status, raw, err := c.do(ctx, method, path, true, body)
	if err != nil {
		return WebhookProxyResult{}, err
	}
	// Discriminate the proxy envelope (always carries `ok`) from a control-plane
	// error body ({"error":"unauthorized"} from the auth layer, a routing 404):
	// the latter is a real failure the CLI maps to an auth/generic exit.
	var probe map[string]json.RawMessage
	if json.Unmarshal(raw, &probe) != nil {
		return WebhookProxyResult{}, cloudError(status, raw)
	}
	if _, ok := probe["ok"]; !ok {
		return WebhookProxyResult{}, cloudError(status, raw)
	}
	res := WebhookProxyResult{Status: status, Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return WebhookProxyResult{}, fmt.Errorf("decode webhook proxy envelope: %w", err)
	}
	return res, nil
}

// WebhookList lists an instance's webhooks in one dataset — GET
// /v1/barkparks/:id/api/webhooks?dataset= (webhook.list, :read).
func (c *Client) WebhookList(ctx context.Context, id, dataset string) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "GET", withDataset(webhookBase(id), dataset), nil)
}

// WebhookShow fetches one webhook — GET .../webhooks/:webhook_id?dataset=
// (webhook.show, :read).
func (c *Client) WebhookShow(ctx context.Context, id, dataset, webhookID string) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "GET", withDataset(webhookBase(id)+"/"+esc(webhookID), dataset), nil)
}

// WebhookCreate creates a webhook — POST .../webhooks?dataset= (webhook.create,
// :mutate). body is the instance create payload ({url, name?, events?, …}).
func (c *Client) WebhookCreate(ctx context.Context, id, dataset string, body map[string]any) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "POST", withDataset(webhookBase(id), dataset), body)
}

// WebhookUpdate PUTs a partial update — PUT .../webhooks/:webhook_id?dataset=
// (webhook.update, :mutate). This is ALSO the toggle path: the caller PUTs
// {active: <flipped>} through the update capability (no bespoke toggle route).
func (c *Client) WebhookUpdate(ctx context.Context, id, dataset, webhookID string, body map[string]any) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "PUT", withDataset(webhookBase(id)+"/"+esc(webhookID), dataset), body)
}

// WebhookDelete deletes a webhook (and its delivery history) — DELETE
// .../webhooks/:webhook_id?dataset= (webhook.delete, :mutate).
func (c *Client) WebhookDelete(ctx context.Context, id, dataset, webhookID string) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "DELETE", withDataset(webhookBase(id)+"/"+esc(webhookID), dataset), nil)
}

// WebhookRotate rotates the signing secret — POST
// .../webhooks/:webhook_id/rotate?dataset= (webhook.rotate, :mutate). The new
// secret rides in the response data exactly once.
func (c *Client) WebhookRotate(ctx context.Context, id, dataset, webhookID string) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "POST", withDataset(webhookBase(id)+"/"+esc(webhookID)+"/rotate", dataset), nil)
}

// WebhookDeliveries lists an endpoint's recent deliveries — GET
// .../webhooks/:webhook_id/deliveries?dataset= (webhook.deliveries, :read).
func (c *Client) WebhookDeliveries(ctx context.Context, id, dataset, webhookID string) (WebhookProxyResult, error) {
	return c.webhookProxy(ctx, "GET", withDataset(webhookBase(id)+"/"+esc(webhookID)+"/deliveries", dataset), nil)
}

// WebhookReplay re-delivers one stored event to the webhook — POST
// .../webhooks/:webhook_id/deliveries/:event_id/replay?dataset= (webhook.replay,
// :mutate). Allowed even when the webhook is inactive (wave-C1 ratification d).
func (c *Client) WebhookReplay(ctx context.Context, id, dataset, webhookID, eventID string) (WebhookProxyResult, error) {
	path := webhookBase(id) + "/" + esc(webhookID) + "/deliveries/" + esc(eventID) + "/replay"
	return c.webhookProxy(ctx, "POST", withDataset(path, dataset), nil)
}

// GithubConnect links a Site to a GitHub repo + branch via
// POST /v1/sites/:id/github (Bearer). `repo` is the conventional "owner/repo"
// form; `branch` is optional (the server defaults to "main"); `secret` is
// optional (when empty, the server generates a fresh random one and returns
// it ONCE in the response).
//
// The response carries the plaintext `webhook_secret` and the `webhook_url`
// the user pastes into GitHub's "Add webhook" form. The plaintext is shown
// here and nowhere else — the only persistent copy is the encrypted-at-rest
// blob on the Site row.
func (c *Client) GithubConnect(ctx context.Context, siteID, repo, branch, secret string) (GithubConnectResp, error) {
	req := map[string]string{"repo": repo}
	if branch != "" {
		req["branch"] = branch
	}
	if secret != "" {
		req["webhook_secret"] = secret
	}
	status, body, err := c.do(ctx, "POST", "/v1/sites/"+esc(siteID)+"/github", true, req)
	if err != nil {
		return GithubConnectResp{}, err
	}
	if !ok(status) {
		return GithubConnectResp{}, cloudError(status, body)
	}
	var out GithubConnectResp
	if err := json.Unmarshal(body, &out); err != nil {
		return GithubConnectResp{}, fmt.Errorf("decode github connect response: %w", err)
	}
	return out, nil
}

// CloudRouteError is a refused control-plane route carrying its HTTP status and
// the `error` code the body declared (e.g. 404 not_found, 403 forbidden). The
// CLI maps each onto a human sentence + exit code; an unrecognised failure falls
// back to cloudError so the shared auth handling (401 "unauthorized:") is kept.
type CloudRouteError struct {
	HTTPStatus int
	Code       string
}

func (e *CloudRouteError) Error() string { return e.Code }

// routeError classifies a non-2xx response for the routes whose refusals the CLI
// discriminates by code (usage 404, members/invitations 403/404, autoupdate
// 422). A 401 stays a cloudError so it keeps the "unauthorized:" prefix
// contract; a body carrying a recognisable code — EITHER the flat
// {"error":"<code>"} shape or the nested {"error":{"code":"<code>"}} shape
// (self-update/autoupdate and the admin-channel routes emit the nested form;
// any future Go method reading one of those MUST route through this decoder,
// not a fresh string-only json.Unmarshal) — becomes a *CloudRouteError;
// anything else falls back to cloudError so nothing is ever swallowed.
func routeError(status int, body []byte) error {
	if status == http.StatusUnauthorized {
		return cloudError(status, body)
	}
	if code := decodeRouteErrorCode(body); code != "" {
		return &CloudRouteError{HTTPStatus: status, Code: code}
	}
	return cloudError(status, body)
}

// decodeRouteErrorCode extracts the `error` code from a control-plane refusal
// body, tolerating BOTH shapes the routes emit: the nested
// {"error":{"code":"…"}} object (autoupdate, self-update, admin-channel) and
// the flat {"error":"…"} string (the older/plain refusals, e.g. not_found).
// It mirrors decodeRollbackError's try-object-then-string RawMessage pattern
// so both decoders drift together instead of silently diverging. Returns ""
// when neither shape carries a code (the caller then falls back to
// cloudError).
func decodeRouteErrorCode(body []byte) string {
	var env struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Error) == 0 {
		return ""
	}
	// Nested object shape first ({"error":{"code":…}}).
	var obj struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(env.Error, &obj) == nil && obj.Code != "" {
		return obj.Code
	}
	// Flat string shape fallback ({"error":"…"}).
	var s string
	if json.Unmarshal(env.Error, &s) == nil {
		return s
	}
	return ""
}

// UsageMeter is one meter of the console usage envelope (charter D48 / OC2).
// Value is a number (float64) OR the string "unmetered" — the honest "no truth
// here" state, never a fake zero. Quota/WarnAt are nil in v1 (display precedes
// enforcement, OC7) and light up later with ZERO client change. MeasuredAt is
// the RFC3339 snapshot time, or nil for a live/current read. PendingInvitations
// rides only on the seats meter (a cheap detail, never a second meter).
type UsageMeter struct {
	Value  any      `json:"value"`
	Quota  *float64 `json:"quota"`
	WarnAt *float64 `json:"warn_at"`
	// OverAt is the red threshold (OC25): a metered value at/past it reads
	// over_limit even when a bar-less meter (rate/latency) carries no quota, and
	// a physical meter (cpu/ram/disk) reddens here BELOW its 100 bar ceiling. Nil
	// for a meter with no red line.
	OverAt             *float64 `json:"over_at"`
	Source             string   `json:"source"`
	MeasuredAt         *string  `json:"measured_at"`
	PendingInvitations *int     `json:"pending_invitations,omitempty"`
	// UnavailableReason is the control plane's typed reason a meter read was
	// ATTEMPTED and FAILED (exception|deadline_exceeded|unreachable|bad_shape|
	// too_many_datasets|unknown) — a CONDITIONAL key, exactly like
	// PendingInvitations above: a meter that measured fine, or one that is
	// deliberately not metered, does not carry it at all. Without this field the
	// reason died at unmarshal one layer BELOW the renderer, so a CRASHED meter
	// was indistinguishable from a deliberate "not yet metered".
	UnavailableReason string `json:"unavailable_reason,omitempty"`
}

// UsageResult is the parsed + raw usage envelope. Raw is the bytes VERBATIM so
// `-o json` re-emits the contract without reshaping (D4). Meters is the parsed
// meter map keyed by meter name; the CLI walks it in the committed fixture order.
type UsageResult struct {
	Raw    []byte
	Meters map[string]UsageMeter
}

// Usage fetches an instance's usage meters via GET /v1/barkparks/:id/usage
// (Bearer). The route is user-authed + TEAM-SCOPED with the no-existence-leak
// 404 (a wrong-team / absent / malformed id are indistinguishable). It NEVER
// blocks on the instance — control-plane meters return even when the box is
// down — and never 500s on a sick box (a failed source degrades that ONE meter
// to "unmetered"). A 404 surfaces as *CloudRouteError{Code:"not_found"}.
func (c *Client) Usage(ctx context.Context, id string) (UsageResult, error) {
	status, body, err := c.do(ctx, "GET", "/v1/barkparks/"+esc(id)+"/usage", true, nil)
	if err != nil {
		return UsageResult{}, err
	}
	if !ok(status) {
		return UsageResult{}, routeError(status, body)
	}
	var env struct {
		Usage struct {
			Meters map[string]UsageMeter `json:"meters"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return UsageResult{}, fmt.Errorf("decode usage envelope: %w", err)
	}
	return UsageResult{Raw: body, Meters: env.Usage.Meters}, nil
}

// UsageInstanceRow is one instance's cached usage sample in the fleet summary
// (OC16): its identity (id/name/slug/host) plus the row-level `measured_at`
// (the sampler's last capture time — nil = never sampled, an honest "no sample
// yet", never a fake-fresh reading) and the 9-name meter set (the SAME envelope
// shape `Usage` returns per-instance, so the fleet renderer reuses the same
// per-meter helpers).
type UsageInstanceRow struct {
	ID         string                `json:"id"`
	Name       string                `json:"name"`
	Slug       string                `json:"slug"`
	Host       string                `json:"host"`
	MeasuredAt *string               `json:"measured_at"`
	Meters     map[string]UsageMeter `json:"meters"`
}

// UsageSummaryResult is the parsed + raw fleet usage envelope (OC16). Raw is the
// bytes VERBATIM so `-o json` re-emits the contract without reshaping (D4).
// TeamInstances is the team-level instances meter (`usage.team.instances`) — the
// one honest quota (OC11), carrying the fleet's headline "X of Y" count;
// TeamPresent is false when the summary omits it (an honest missing header, not
// a fake zero). Instances is the per-instance sample rows in server order.
type UsageSummaryResult struct {
	Raw           []byte
	TeamInstances UsageMeter
	TeamPresent   bool
	Instances     []UsageInstanceRow
}

// UsageSummary fetches the fleet-wide usage summary via GET /v1/usage/summary
// (Bearer, team-scoped). This is the CACHED-samples read (OC16) — it reads the
// sampler worker's stored snapshots, NEVER a live per-instance fan-out (the ~15s
// hang that disqualified a live gather). Each row carries its own `measured_at`
// so a stale or never-sampled box is honest about its freshness. The envelope
// is `{usage:{team:{instances:<meter>}, instances:[<row>…]}}`.
func (c *Client) UsageSummary(ctx context.Context) (UsageSummaryResult, error) {
	status, body, err := c.do(ctx, "GET", "/v1/usage/summary", true, nil)
	if err != nil {
		return UsageSummaryResult{}, err
	}
	if !ok(status) {
		return UsageSummaryResult{}, routeError(status, body)
	}
	var env struct {
		Usage struct {
			Team struct {
				Instances *UsageMeter `json:"instances"`
			} `json:"team"`
			Instances []UsageInstanceRow `json:"instances"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return UsageSummaryResult{}, fmt.Errorf("decode usage summary envelope: %w", err)
	}
	res := UsageSummaryResult{Raw: body, Instances: env.Usage.Instances}
	if env.Usage.Team.Instances != nil {
		res.TeamInstances = *env.Usage.Team.Instances
		res.TeamPresent = true
	}
	return res, nil
}

// UsageHistoryPoint is one sample in a meter's history series (wave-4 S1/OC21):
// an RFC3339 capture time and a NULLABLE value. A nil Value is a GAP the sampler
// recorded but couldn't measure (the box was down that tick) — dropped from the
// terminal trend, never a fabricated zero (the metricsBlocks gap discipline).
type UsageHistoryPoint struct {
	At    string   `json:"at"`
	Value *float64 `json:"value"`
}

// UsageHistoryResult is the parsed usage-history envelope (wave-4 S1/OC21):
// per-meter time series over the sampler's stored `usage_samples` rows. Series is
// keyed by meter name (the SAME 9-name vocabulary the /usage envelope carries);
// a meter absent from the map has no recorded history. Raw is retained for
// symmetry with the sibling usage results but is NOT re-emitted — the history is
// a HUMAN garnish, never a machine contract (the raw `-o json` path stays the
// live /usage envelope, OC21).
type UsageHistoryResult struct {
	Raw    []byte
	Series map[string][]UsageHistoryPoint
}

// UsageHistory fetches an instance's usage history via
// GET /v1/barkparks/:id/usage/history?points=<n> (Bearer, team-scoped). It is a
// PURE read over the sampler's stored rows (OC16/OC21) — never a live fan-out.
// The window is FIXED at the server's trailing 14 days; `points` is the number
// of uniform buckets it is split into (<=0 → the server default). The envelope is
// `{ok, series:{<meter>:[{at, value|null}]}}`; a 404 (an older control plane
// without the route) surfaces as *CloudRouteError{Code:"not_found"} so the caller
// can fail soft and simply drop the trend column.
func (c *Client) UsageHistory(ctx context.Context, id string, points int) (UsageHistoryResult, error) {
	path := "/v1/barkparks/" + esc(id) + "/usage/history"
	if points > 0 {
		path += fmt.Sprintf("?points=%d", points)
	}
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return UsageHistoryResult{}, err
	}
	if !ok(status) {
		return UsageHistoryResult{}, routeError(status, body)
	}
	var env struct {
		Series map[string][]UsageHistoryPoint `json:"series"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return UsageHistoryResult{}, fmt.Errorf("decode usage history envelope: %w", err)
	}
	return UsageHistoryResult{Raw: body, Series: env.Series}, nil
}

// TeamMember is one seat on a team, as returned by GET /v1/teams/:id/members.
type TeamMember struct {
	UserID   string `json:"user_id"`
	Email    string `json:"email"`
	Role     string `json:"role"`
	JoinedAt string `json:"joined_at"`
}

// TeamInvitation is one PENDING invitation, as returned by
// GET /v1/teams/:id/invitations (the token_hash is never serialized).
type TeamInvitation struct {
	ID         string `json:"id"`
	Email      string `json:"email"`
	Role       string `json:"role"`
	ExpiresAt  string `json:"expires_at"`
	InsertedAt string `json:"inserted_at"`
}

// MembersResult is the parsed + raw members list. Raw is the `members` array
// BYTES verbatim so `-o json` re-emits the contract without reshaping.
type MembersResult struct {
	Raw     json.RawMessage
	Members []TeamMember
}

// InvitationsResult is the parsed + raw pending-invitations list. Raw is the
// `invitations` array bytes verbatim.
type InvitationsResult struct {
	Raw         json.RawMessage
	Invitations []TeamInvitation
}

// TeamMembers lists a team's seats via GET /v1/teams/:id/members (Bearer). The
// route is member-gated + team-scoped; a non-member gets the same 404 as a
// nonexistent team (no existence leak), surfaced as *CloudRouteError.
func (c *Client) TeamMembers(ctx context.Context, teamID string) (MembersResult, error) {
	status, body, err := c.do(ctx, "GET", "/v1/teams/"+esc(teamID)+"/members", true, nil)
	if err != nil {
		return MembersResult{}, err
	}
	if !ok(status) {
		return MembersResult{}, routeError(status, body)
	}
	var env struct {
		Members json.RawMessage `json:"members"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return MembersResult{}, fmt.Errorf("decode members response: %w", err)
	}
	var members []TeamMember
	_ = json.Unmarshal(env.Members, &members)
	return MembersResult{Raw: env.Members, Members: members}, nil
}

// TeamInvitations lists a team's PENDING invitations via
// GET /v1/teams/:id/invitations (Bearer). Unlike members this route is
// ADMIN-gated: a plain member gets 403 forbidden (surfaced as
// *CloudRouteError{Code:"forbidden"}), which the CLI degrades to an honest note
// rather than failing the whole `members` view.
func (c *Client) TeamInvitations(ctx context.Context, teamID string) (InvitationsResult, error) {
	status, body, err := c.do(ctx, "GET", "/v1/teams/"+esc(teamID)+"/invitations", true, nil)
	if err != nil {
		return InvitationsResult{}, err
	}
	if !ok(status) {
		return InvitationsResult{}, routeError(status, body)
	}
	var env struct {
		Invitations json.RawMessage `json:"invitations"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return InvitationsResult{}, fmt.Errorf("decode invitations response: %w", err)
	}
	var invitations []TeamInvitation
	_ = json.Unmarshal(env.Invitations, &invitations)
	return InvitationsResult{Raw: env.Invitations, Invitations: invitations}, nil
}

// AutoupdatePolicy is the isu-w4 fleet-autoupdate POLICY the control plane echoes
// back from PATCH /v1/barkparks/:id/autoupdate: whether the instance rides new
// blessed releases (Enabled, the opt-out master), a temporary hold (Paused), and
// a version freeze (PinnedRelease, empty = unpinned). The three team-facing
// levers `bp cloud autoupdate` drives, reflected as they landed.
//
// Honest limit (charter OC10, spike-resolved): pinning HOLDS an instance at or
// above its current version — it does not roll back. The CLI's receipts say so;
// the pin is a freeze flag, not a downgrade target.
type AutoupdatePolicy struct {
	Enabled       bool   `json:"enabled"`
	Paused        bool   `json:"paused"`
	PinnedRelease string `json:"pinned_release"`
}

// SetAutoupdate PATCHes an instance's autoupdate policy via
// PATCH /v1/barkparks/:id/autoupdate (Bearer, team-admin-gated). `patch` carries
// ONLY the levers the caller is changing — the route is a partial update, so
// absent keys are left untouched server-side. The narrow set the route accepts
// (and this client sends): `autoupdate_enabled`, `autoupdate_paused`,
// `pinned_release` (a blank pin normalises to unpinned on the server). A 200
// decodes the resulting {ok, autoupdate:{enabled,paused,pinned_release}}; a 404
// (wrong team / no such id — the SAME no-leak 404) surfaces as
// *CloudRouteError{Code:"not_found"}, a 422 as *CloudRouteError{Code:"invalid"}.
func (c *Client) SetAutoupdate(ctx context.Context, id string, patch map[string]any) (AutoupdatePolicy, error) {
	status, body, err := c.do(ctx, "PATCH", "/v1/barkparks/"+esc(id)+"/autoupdate", true, patch)
	if err != nil {
		return AutoupdatePolicy{}, err
	}
	if !ok(status) {
		return AutoupdatePolicy{}, routeError(status, body)
	}
	var env struct {
		Autoupdate AutoupdatePolicy `json:"autoupdate"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return AutoupdatePolicy{}, fmt.Errorf("decode autoupdate response: %w", err)
	}
	return env.Autoupdate, nil
}

// RolloutState is the FLEET-WIDE autoupdate rollout the operator route governs
// (GET/POST /v1/operator/autoupdate*, isu-w5). `Halted` is the one lever
// halt/resume toggle — the global stop that pauses the AutoupdateRolloutWorker
// from advancing ANY instance (the emergency brake when a blessed release turns
// out bad). The counters are POINTERS so the CLI renders only what the control
// plane actually reported: an older CP (or one that ships a leaner envelope from
// the sibling emission slice) omits them and they stay nil — an honest "not
// reported", never a fabricated zero. Raw is the envelope bytes verbatim so
// `-o json` re-emits the contract without this client becoming a second,
// drifting definition of it.
type RolloutState struct {
	Raw      []byte `json:"-"`
	Halted   bool   `json:"halted"`
	InFlight *int   `json:"in_flight"`
	Behind   *int   `json:"behind"`
	Eligible *int   `json:"eligible"`
}

// rolloutRequest issues one operator-autoupdate call (the shared GET status /
// POST halt / POST resume core) and decodes the RolloutState, keeping the raw
// bytes. `auth: true`, so every one of the three carries the caller's bp-login
// SESSION as `Authorization: Bearer <session>` — the credential
// `Auth.require_platform_operator/2` actually resolves. A non-2xx surfaces
// through routeError so a 404 (an older control plane that never grew the
// /v1/operator seam) and a 403 (signed in, not on the allowlist) are both
// *CloudRouteError the CLI can degrade honestly, and a 401 keeps its
// "unauthorized:" prefix.
func (c *Client) rolloutRequest(ctx context.Context, method, path string) (RolloutState, error) {
	status, body, err := c.do(ctx, method, path, true, nil)
	if err != nil {
		return RolloutState{}, err
	}
	if !ok(status) {
		return RolloutState{}, routeError(status, body)
	}
	res := RolloutState{Raw: body}
	if err := json.Unmarshal(body, &res); err != nil {
		return RolloutState{}, fmt.Errorf("decode rollout envelope: %w", err)
	}
	return res, nil
}

// RolloutStatus reads the fleet rollout state via GET /v1/operator/autoupdate.
// Read-only — it never advances or halts anything.
//
// THE CREDENTIAL IS THE CALLER'S bp-login SESSION, AND THE PRINCIPAL IS THE
// PLATFORM OPERATOR (isu-backlog-operator-principal, the ruling this comment now
// records). These three methods used to call `/v1/admin/autoupdate*`, which is
// gated by `Auth.require_worker/2` — a constant-time compare against the shared
// `WORKER_TOKEN` machine secret. A `bp login` token can never equal that secret,
// so `bp cloud rollout` was structurally unable to succeed for a human no matter
// what role they held on any team: the verb shipped, and the door it knocked on
// had no handle. (An even older revision of this comment said "(Bearer, admin)",
// which sent a reader hunting for a team grant that has no bearing on it.)
//
// The rollout verbs now call the `/v1/operator/autoupdate*` trio, gated by
// `Auth.require_platform_operator/2` (router.ex): a valid session whose email is
// on `Notifications.platform_admin_emails/0` — the `PLATFORM_ADMIN_EMAILS`
// allowlist, the SAME one behind `/v1/me`'s `platform_operator` boolean and the
// console's Operator surface. One principal, both surfaces. The `/v1/admin/*`
// routes are untouched and stay the WORKER's (the off-box provisioner), so this
// is a reachability fix, not a widening: neither door accepts the other's
// credential, and router_operator_test.exs asserts that in both directions.
func (c *Client) RolloutStatus(ctx context.Context) (RolloutState, error) {
	return c.rolloutRequest(ctx, "GET", "/v1/operator/autoupdate")
}

// RolloutHalt stops the fleet rollout via POST /v1/operator/autoupdate/halt
// (Bearer, the caller's session; platform-operator gated — see RolloutStatus) —
// the global brake. Returns the resulting (halted) state.
func (c *Client) RolloutHalt(ctx context.Context) (RolloutState, error) {
	return c.rolloutRequest(ctx, "POST", "/v1/operator/autoupdate/halt")
}

// RolloutResume restarts a halted fleet rollout via
// POST /v1/operator/autoupdate/resume (Bearer, the caller's session;
// platform-operator gated — see RolloutStatus). Returns the resulting state.
func (c *Client) RolloutResume(ctx context.Context) (RolloutState, error) {
	return c.rolloutRequest(ctx, "POST", "/v1/operator/autoupdate/resume")
}

// RollbackResult is a STARTED instance rollback (isu-w6, charter W6 D15/D16): the
// control plane ran the box's SYNCHRONOUS slot preflight, recovered the previous
// blue/green slot's recorded sha, ATOMICALLY PINNED the instance at that target
// (so the 5-minute rollout worker can never silently re-update past the operator —
// an unpinned rollback is undone within one tick, a lie), and spawned the async
// slot flip (git reset → reboot the idle slot → health-gate it on its own port →
// flip Caddy ONLY on green). Raw is the 202 envelope BYTES verbatim so `-o json`
// re-emits the control plane's contract without reshaping (the verify/rollout
// idiom — the envelope IS the contract, so this client never becomes a second,
// drifting definition of it). The scalar fields are POINTERS on purpose: a
// leaner/older control plane that omits one decodes to nil (an honest "not
// reported"), never a fabricated empty string.
type RollbackResult struct {
	Raw           []byte  `json:"-"`
	Status        *string `json:"status"`
	TargetSHA     *string `json:"target_sha"`
	PinnedRelease *string `json:"pinned_release"`
}

// RollbackError is a rollback the control plane REFUSED — a typed contract code
// the CLI maps onto one human sentence and a stable exit. HTTPStatus drives the
// exit FAMILY (charter W6 D23: 409 → conflict, 404 → not-found, 5xx → server, auth
// → auth); Code is the specific refusal used for the message; Detail is the
// server's optional elaboration. A 401 is deliberately NOT a RollbackError — it
// stays a cloudError so it keeps the "unauthorized:" prefix contract cloudFail
// keys on (a dead session and a missing one become the same `bp login` hint).
// Reason is the CAUSE an authority gate named ("no_team", "role") when the code
// itself is the generic "forbidden". The CLI narrates and exit-codes off it, so
// the control plane re-classifying a refusal's STATUS cannot change what the
// user is told: this route is gated by require_primary_team_admin/1, whose
// teamless refusal moves from 422 {"error":"no_team"} to
// 403 {"error":"forbidden","reason":"no_team","scope":"team"}.
type RollbackError struct {
	HTTPStatus int
	Code       string
	Detail     string
	Reason     string
}

func (e *RollbackError) Error() string {
	if e.Detail != "" {
		return e.Code + ": " + e.Detail
	}
	return e.Code
}

// Rollback rolls ONE managed instance back to its previous blue/green slot via
// POST /v1/barkparks/:id/rollback (Bearer, team-admin-gated — charter W6 D16). The
// control plane runs the box's slot preflight with the STORED admin token (the
// token never reaches this client), pins the instance at the recovered target, and
// starts the async flip. A 202 is a STARTED run (read result.TargetSHA /
// PinnedRelease); a contract refusal surfaces as *RollbackError; a 401 (and
// anything else outside the contract) via cloudError so auth handling stays shared.
func (c *Client) Rollback(ctx context.Context, id string) (RollbackResult, error) {
	// The route is SYNCHRONOUS on the box's slot preflight (the control plane runs
	// --rollback-preflight inline before it returns 202), so give it the same
	// headroom past DefaultTimeout as VerifyInstance. An injected HTTP client
	// (tests) is honored untouched; only the lazily-built fallback is widened.
	rc := *c
	if rc.HTTP == nil {
		rc.HTTP = &http.Client{Timeout: VerifyTimeout}
	}
	status, raw, err := rc.do(ctx, "POST", "/v1/barkparks/"+esc(id)+"/rollback", true, nil)
	if err != nil {
		return RollbackResult{}, err
	}
	if !ok(status) {
		// A 401 keeps the shared cloudError "unauthorized:" contract; every other
		// refusal is a typed *RollbackError the CLI exit-maps by status family. The
		// control plane speaks TWO error shapes on this route — the nested
		// {"error":{"code","detail"}} the relay emits for instance-relayed refusals,
		// and the flat {"error":"not_found"} its top-level team guard emits — so the
		// decode tolerates whichever arrived; an unrecognisable body falls through to
		// cloudError so nothing is ever swallowed.
		if status == http.StatusUnauthorized {
			return RollbackResult{}, cloudError(status, raw)
		}
		if code, detail, reason := decodeRollbackError(raw); code != "" {
			return RollbackResult{}, &RollbackError{HTTPStatus: status, Code: code, Detail: detail, Reason: reason}
		}
		return RollbackResult{}, cloudError(status, raw)
	}
	res := RollbackResult{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return RollbackResult{}, fmt.Errorf("decode rollback envelope: %w", err)
	}
	return res, nil
}

// decodeRollbackError extracts (code, detail, reason) from a rollback refusal
// body, tolerating BOTH shapes the route emits: the nested
// {"error":{"code":"…","detail":"…"}} the relay uses for instance-relayed refusals
// and the flat {"error":"not_found"} its top-level team guard uses. The reason
// rides at the TOP level of the flat shape (the authority gates emit
// {"error":"forbidden","reason":"no_team","scope":"team"}) and inside the object
// on the nested one, so both are read; it is "" when the body names no cause. The
// code is "" when neither shape carries one (the caller then falls back to
// cloudError).
func decodeRollbackError(body []byte) (code, detail, reason string) {
	var env struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Error) == 0 {
		return "", "", ""
	}
	// The top-level `reason` in its OWN Unmarshal (the cloudError idiom): a route
	// sending it as an object must cost that field alone, never the code decode
	// that drives the whole refusal path.
	var rsn struct {
		Reason string `json:"reason"`
	}
	if json.Unmarshal(body, &rsn) == nil {
		reason = strings.TrimSpace(rsn.Reason)
	}
	// Nested object shape first ({"error":{"code","detail","reason"}}).
	var obj struct {
		Code   string `json:"code"`
		Detail string `json:"detail"`
		Reason string `json:"reason"`
	}
	if json.Unmarshal(env.Error, &obj) == nil && obj.Code != "" {
		if r := strings.TrimSpace(obj.Reason); r != "" {
			reason = r
		}
		return obj.Code, obj.Detail, reason
	}
	// Flat string shape fallback ({"error":"not_found"}).
	var s string
	if json.Unmarshal(env.Error, &s) == nil {
		return s, "", reason
	}
	return "", "", ""
}
