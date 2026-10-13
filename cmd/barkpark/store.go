package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// The HTTP client and its data models now live in the framework-free apiclient
// package. These aliases keep the existing TUI code compiling while the client
// itself carries no Bubble Tea dependency.
type (
	// DataStore is the TUI's local name for the framework-free API client.
	DataStore     = apiclient.Client
	Doc           = apiclient.Doc
	WorkspaceInfo = apiclient.WorkspaceInfo
	ProjectInfo   = apiclient.ProjectInfo
	// apiclientDeskNode aliases the server desk-tree DTO for structure.go's
	// converter (fromDeskNode).
	apiclientDeskNode = apiclient.DeskNode
)

// DataStoreRefreshMsg is sent to the TUI when the API data changes. It is a
// tea.Msg, so it stays in package main — the apiclient signals change through
// its OnChange callback, which the TUI wires to program.Send(DataStoreRefreshMsg{}).
type DataStoreRefreshMsg struct{}

// ── Presentation helpers (TUI-only, not part of the client) ──────────────────

func timeAgo(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := time.Since(t)
	// Client/server clock skew can make a server timestamp appear to be in the
	// future, yielding a negative duration. Clamp it so we never render "-2m ago".
	if d < 0 {
		return "just now"
	}
	if d.Minutes() < 60 {
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	}
	if d.Hours() < 24 {
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

func statusIcon(status string) string {
	switch status {
	case "published":
		return "●"
	case "draft":
		return "○"
	case "active":
		return "◆"
	case "planning":
		return "◇"
	case "completed":
		return "✓"
	default:
		return "·"
	}
}

// publishState is a document's publish state, "draft" or "published", for the
// header badge, the list dot and the publish, unpublish and discard gates.
//
// Doc.Status is the publish state only while the schema has no "status"
// field of its own. The v1 envelope flattens content fields to the top level,
// and apiclient lets an explicit "status" win over the "_draft" flag, so for a
// schema that declares one (post: draft | published | archived) Doc.Status
// holds the CONTENT value and Values["status"] holds it too. An archived
// published post then read "[archived]" with a neutral dot and no publish
// state. For those documents the publish state comes from the envelope's
// "_draft" flag, then the "drafts." id prefix.
func publishState(d *Doc) string {
	if d == nil {
		return ""
	}
	if _, ok := d.Values["status"]; !ok {
		return d.Status
	}
	var draft bool
	if raw, ok := d.Extra["_draft"]; ok && json.Unmarshal(raw, &draft) == nil {
		if draft {
			return "draft"
		}
		return "published"
	}
	if strings.HasPrefix(d.ID, "drafts.") {
		return "draft"
	}
	return "published"
}

// contentStatus is the value of a schema-declared "status" content field, or
// "" when the document has none.
func contentStatus(d *Doc) string {
	if d == nil {
		return ""
	}
	return d.Values["status"]
}

// setPublishState records an optimistic publish or unpublish on d, so
// publishState reads the new state before the refresh re-queries. A document
// whose Status holds a content "status" field keeps that value; its "_draft"
// flag changes instead.
func setPublishState(d *Doc, state string) {
	if _, ok := d.Values["status"]; !ok {
		d.Status = state
		return
	}
	if d.Extra == nil {
		d.Extra = map[string]json.RawMessage{}
	}
	d.Extra["_draft"] = json.RawMessage(strconv.FormatBool(state == "draft"))
}
