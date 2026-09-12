package cloudclient

// site_build_log_bytes.go is the client half of the SECOND operator read path
// for the black box recorder: GET /v1/sites/:id/deployments/:dep_id/build-log/
// bytes, added by dr-bl-recorder-http-read-path c1 (cloud PR #17752, merged
// 2026-09-11) and served by `BarkparkCloud.Sites.BuildLogBytes`.
//
// WHY A SECOND ROUTE AND A SECOND STRUCT. The record route (#16847,
// site_build_log.go) is a published contract whose three answers — 404 / 410 /
// 200-with-an-honest-log_state — a test asserts are pairwise distinct. Serving
// BYTES needs an answer that contract has no room for: a REFUSAL for a log that
// exists, is not evicted, and still may not be shown because its bytes were
// never folded through the secret scrubber. So the bytes got their own path and
// they get their own decoder here; the record decoder is byte-identical for
// every caller it already had.
//
// THE REFUSAL IS NOT AN ABSENCE. 422 build_log_unscrubbed means the bytes EXIST
// on the box and are withheld. A client that rendered that as "no log found"
// would tell an operator to stop looking for a log that is sitting on disk —
// which is the whole reason this slice is a slice.
//
// AN OLD BOX IS NOT AN EMPTY LOG. A box predating the `bytes=1` flag answers the
// RECORD instead: a 200, `log_state: "available"`, and no `tail` key at all. The
// control plane already fails that closed into a 502, but a decoder that keyed
// on the VALUE of `tail` could not tell "the key was absent" from "the key was
// null" — json.Unmarshal writes nil for both. So TailPresent is read off the raw
// body's KEY SET, never off the decoded pointer.

import (
	"context"
	"encoding/json"
	"fmt"
)

// SiteBuildLogBytes is the bytes answer for ONE deployment, whatever the answer
// was. HTTPStatus is the discriminator — never a field — for the same reason the
// record route makes the status the discriminator.
//
// THE TAG ORDER IS THE SERIALIZER'S ORDER. `BuildLogBytes.wire/3` merges
// `%{deployment_id, build_id}` with `available` and then with its explicit
// `@bytes_keys` allowlist (slug build_id record log_state log_scrub log_path
// log_bytes tail_bytes truncated tail evicted_at). These tags are listed in that
// order and pinned in that order by
// internal/cloudclient/producer_contract_test.go, so a diff of the struct reads
// like a diff of the serializer.
//
// LogScrub, LogBytes, TailBytes and Tail are POINTERS: the control plane sends
// explicit nulls for all four, and a plain value would decode those as 0 / "" —
// a zero-byte log, a pattern-set version zero and an empty tail are all
// meaningful values that must never be invented for an absent one. LogScrub in
// particular IS the criterion: nil means NEVER FOLDED.
type SiteBuildLogBytes struct {
	// HTTPStatus is the status the control plane answered with. Not a wire
	// field — set by the client after the response is read.
	HTTPStatus int `json:"-"`

	// TailPresent reports whether the body carried a `tail` KEY, regardless of
	// its value. Not a wire field: computed from the raw key set, because that
	// presence is what tells an old box's record answer apart from a genuine
	// null tail.
	TailPresent bool `json:"-"`

	DeploymentID string  `json:"deployment_id"`
	BuildID      string  `json:"build_id"`
	Available    bool    `json:"available"`
	Slug         string  `json:"slug"`
	Record       string  `json:"record"`
	LogState     string  `json:"log_state"`
	LogScrub     *int    `json:"log_scrub"`
	LogPath      string  `json:"log_path"`
	LogBytes     *int64  `json:"log_bytes"`
	TailBytes    *int64  `json:"tail_bytes"`
	Truncated    bool    `json:"truncated"`
	Tail         *string `json:"tail"`
	EvictedAt    string  `json:"evicted_at"`

	// The refusal envelope, shared with the record route: every non-200 answer
	// names itself in `error` and explains itself in `detail`.
	Error       string `json:"error"`
	Detail      string `json:"detail"`
	Reason      string `json:"reason"`
	BoxLogState string `json:"box_log_state"`
}

// Scrubbed reports whether the control plane said these bytes were folded
// through the secret scrubber. A nil LogScrub is NEVER FOLDED — the one state
// the 422 refusal exists for — and is not the same fact as a zero.
func (b SiteBuildLogBytes) Scrubbed() bool { return b.LogScrub != nil }

// TailText is the recorded bytes, or "" when the answer carried none. Callers
// must gate on Scrubbed()/HTTPStatus first: an empty tail from a served 200 is
// an empty log, and an empty tail from a 422 is a withheld one.
func (b SiteBuildLogBytes) TailText() string {
	if b.Tail == nil {
		return ""
	}
	return *b.Tail
}

// siteBuildLogBytesDocumented reports whether a status is one of the six answers
// `Sites.BuildLogBytes` documents. Anything else (the 401/403 this
// operator-gated route answers to a non-operator, a proxy's 500) is not this
// route speaking and goes down the ordinary refusal path.
func siteBuildLogBytesDocumented(status int) bool {
	switch status {
	case 200, 404, 409, 410, 422, 502:
		return true
	}
	return false
}

// SiteBuildLogBytes reads the recorded build log's BYTES for ONE deployment, BY
// DEPLOYMENT ID (Bearer, operator-gated).
//
// A documented answer comes back with HTTPStatus set and a nil error, INCLUDING
// the 404/409/410/422/502 ones — each of those is information about a specific
// deployment, and collapsing them into a bare *CloudRefusal would throw away the
// very distinctions the server made on purpose. err is non-nil only for a
// transport failure, an undecodable body, or a status this route does not
// document.
func (c *Client) SiteBuildLogBytes(ctx context.Context, siteID, deploymentID string) (SiteBuildLogBytes, error) {
	path := "/v1/sites/" + esc(siteID) + "/deployments/" + esc(deploymentID) + "/build-log/bytes"
	status, body, err := c.do(ctx, "GET", path, true, nil)
	if err != nil {
		return SiteBuildLogBytes{}, err
	}
	if !siteBuildLogBytesDocumented(status) {
		return SiteBuildLogBytes{HTTPStatus: status}, cloudError(status, body)
	}
	var out SiteBuildLogBytes
	if err := json.Unmarshal(body, &out); err != nil {
		return SiteBuildLogBytes{HTTPStatus: status}, fmt.Errorf("decode build log bytes response: %w", err)
	}
	// THE KEY SET, not the value. See the file header: an absent `tail` and a
	// null one decode identically into *string, and they mean opposite things.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err == nil {
		_, out.TailPresent = raw["tail"]
	}
	out.HTTPStatus = status
	return out, nil
}
