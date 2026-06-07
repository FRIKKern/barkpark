package main

import (
	"fmt"
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
