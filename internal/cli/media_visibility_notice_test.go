package cli

import (
	"encoding/json"
	"strings"
	"testing"
)

// The media visibility notice (task-cbb112a9b4c600cc) is copy the API renders
// for `bp media get` — BarkparkWeb.V1.MediaController.show/2 puts it in the
// response under `result.visibilityNotice`, and this file is the Go half of
// that agreement.
//
// It exists because the notice first shipped BESIDE `result`, and renderSuccess
// pipes every successful body through unwrapResult, which returns the `result`
// value and drops every top-level sibling. The API-side placement and bp's
// unwrap are two hand-maintained halves of one contract; the two tests below
// are what makes them disagree loudly instead of silently.
const mediaVisibilityNoticeKey = "visibilityNotice"

// Fixture shaped like the real GET /v1/media/:dataset/:id body: the asset in
// `result` (carrying BOTH its delivery-tier `visibility` string and the
// notice), with `syncTags`/`ms` as top-level siblings.
const mediaGetBody = `{
  "result": {
    "id": "file-1",
    "visibility": "public",
    "visibilityNotice": {
      "value": "public",
      "label": "Public — within this scope's sharing",
      "media_shared": false
    }
  },
  "syncTags": [],
  "ms": 3
}`

func TestUnwrapResultKeepsMediaVisibilityNotice(t *testing.T) {
	payload := unwrapResult([]byte(mediaGetBody))

	var asset map[string]json.RawMessage
	if err := json.Unmarshal(payload, &asset); err != nil {
		t.Fatalf("unwrapped payload is not an object: %v", err)
	}
	if _, ok := asset[mediaVisibilityNoticeKey]; !ok {
		t.Fatalf("%q missing from the payload bp renders; keys=%v",
			mediaVisibilityNoticeKey, noticeKeysOf(asset))
	}
	// The notice is a sibling of the tier string, never a replacement: if the
	// API ever reused the name, `visibility` would stop being a string here.
	var tier string
	if err := json.Unmarshal(asset["visibility"], &tier); err != nil {
		t.Fatalf("result.visibility must stay the tier STRING, got %s: %v",
			asset["visibility"], err)
	}
	if tier != "public" {
		t.Fatalf("tier = %q, want public", tier)
	}
}

// The control, and the reason the API-side key may not move back: a notice
// beside `result` is dropped before bp renders anything, so `bp media get`
// would print no copy at all while the raw JSON still carried it.
func TestUnwrapResultDropsATopLevelVisibilityNotice(t *testing.T) {
	body := `{"result":{"id":"file-1","visibility":"public"},` +
		`"visibility":{"label":"Public — within this scope's sharing"},"ms":3}`

	payload := unwrapResult([]byte(body))
	if strings.Contains(string(payload), "Public — within") {
		t.Fatalf("a top-level sibling survived the unwrap: %s", payload)
	}
}

func noticeKeysOf(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
