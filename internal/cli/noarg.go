package cli

// Content-first no-arg surfaces (AXI slice R7): the pieces a bare `bp` (no args,
// no usable terminal) and a bare `bp task` (noun, no verb) show instead of a raw
// bubbletea /dev/tty error or a bald usage block. Everything here is a small pure
// renderer plus one best-effort counts fetch — the network is never load-bearing:
// an offline server drops the extra line and the caller behaves exactly as before.
//
// Why this lives in `cli` and not `package main`: main.go is the composition root
// that already delegates its "where am I connected, and is this a fresh install"
// judgement to this package (FirstRun / ResolvedAPIConfig / ServerSource /
// LoggedInWithoutServer). The status card and the load-failure advice are the same
// kind of judgement — pure functions of the resolved target — so they belong here
// where the cli test harness can exercise them without a live server or a TTY.

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// LoadFailureAdvice returns the one actionable line to print when the TUI cannot
// load schemas from the resolved server. The old code hardcoded the local-dev
// remedy ("cd api && mix phx.server") even when the user was pointed at a remote
// host, which is useless advice for guerrilla/prod. Derive the remedy from the
// target instead: a localhost target keeps the mix line; anything else names the
// URL and points at `bp doctor` (the health gate that actually diagnoses a remote).
func LoadFailureAdvice(baseURL string) string {
	if isLocalTarget(baseURL) {
		return "Is the Phoenix API running? Start it with: cd api && mix phx.server"
	}
	return fmt.Sprintf("Check that %s is reachable, then run `bp doctor` to diagnose the connection.", baseURL)
}

// isLocalTarget reports whether baseURL points at a loopback / local-dev host.
// A parse failure or an empty host is treated as local — the historical default
// floor is localhost:4000, so an unparseable target is far more likely a local
// mistake than a remote one, and the mix-phx.server advice is the safe fallback.
func isLocalTarget(baseURL string) bool {
	if baseURL == "" {
		return true
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return true
	}
	host := u.Hostname()
	if host == "" {
		return true
	}
	switch host {
	case "localhost", "0.0.0.0":
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() || ip.IsUnspecified()
	}
	return false
}

// StatusCardInfo is the data a non-interactive status card renders. It is a plain
// struct so the renderer stays a pure function of already-resolved values (bin
// path, target, scope, schema count) — no DataStore, no network, no TTY.
type StatusCardInfo struct {
	Bin         string
	BaseURL     string
	Source      string // ServerSource() attribution: "env" / "saved: <name>" / "default"
	Workspace   string
	Project     string
	Dataset     string
	SchemaCount int
}

// RenderStatusCard builds the compact AXI-style status card a bare `bp` prints
// when schemas loaded fine but there is no usable terminal to run the interactive
// desk in. Without this, bubbletea tries to open /dev/tty, fails with a raw
// "could not open a new TTY: device not configured" error, and exits 1 — an
// opaque failure for a perfectly healthy connection. The card is the honest
// content-first alternative: what this binary is, where it is connected, how many
// schemas it sees, and the three commands that do useful work without a terminal.
func RenderStatusCard(info StatusCardInfo) string {
	server := info.BaseURL
	if info.Source != "" {
		server = fmt.Sprintf("%s [%s]", info.BaseURL, info.Source)
	}
	scope := fmt.Sprintf("workspace=%s · project=%s · dataset=%s",
		info.Workspace, info.Project, info.Dataset)

	var b strings.Builder
	b.WriteString("barkpark — a headless CMS you drive from one binary (interactive desk + bp CLI).\n")
	fmt.Fprintf(&b, "bin:      %s\n", info.Bin)
	fmt.Fprintf(&b, "server:   %s\n", server)
	fmt.Fprintf(&b, "scope:    %s\n", scope)
	fmt.Fprintf(&b, "schemas:  %d loaded\n", info.SchemaCount)
	b.WriteString("No interactive terminal — the desk needs a TTY. From here:\n")
	b.WriteString("help[1]:  `bp task ready`      — the ready work queue\n")
	b.WriteString("help[2]:  `bp doc ls <type>`   — list documents of a type\n")
	b.WriteString("help[3]:  `bp --help`          — the full command tree")
	return b.String()
}

// lifecycleOrder is the stable status order the counts line renders in — the same
// open → in_progress → blocked → done → cancelled progression the task board and
// design tokens use. Statuses outside this list (should not occur) are appended
// alphabetically after it so a novel status is surfaced, never silently dropped.
var lifecycleOrder = []string{"open", "in_progress", "blocked", "done", "cancelled"}

// formatTaskCountsLine renders one honest "tasks: …" summary from prime's
// lifecycle counts map (status → total). Zero-count statuses are omitted so the
// line stays scannable; the grand total closes it. An empty map yields "" so the
// caller drops the line rather than printing an empty "tasks:" header.
func formatTaskCountsLine(counts map[string]int) string {
	if len(counts) == 0 {
		return ""
	}
	seen := map[string]bool{}
	var parts []string
	total := 0
	add := func(status string) {
		n, ok := counts[status]
		if !ok || n <= 0 {
			return
		}
		seen[status] = true
		total += n
		parts = append(parts, fmt.Sprintf("%d %s", n, status))
	}
	for _, s := range lifecycleOrder {
		add(s)
	}
	// Any status the server emitted that is not in the canonical order — render it
	// too (alphabetical), so the line never hides real work behind a stale list.
	var extra []string
	for s := range counts {
		if !seen[s] {
			extra = append(extra, s)
		}
	}
	sort.Strings(extra)
	for _, s := range extra {
		add(s)
	}
	if len(parts) == 0 {
		return ""
	}
	return fmt.Sprintf("tasks: %s  (%d total)", strings.Join(parts, " · "), total)
}

// fetchTaskCounts issues ONE best-effort GET /v1/tasks/prime against the resolved
// target and returns its scope-wide lifecycle counts. It is deliberately cheap and
// short-fused: limit=1 keeps the body tiny (counts are scope-wide, independent of
// the in_progress/ready/events limit) and a 2s timeout means a bare `bp task`
// against a dead server degrades in two seconds, not the default five. Every error
// path returns (nil, err) so the caller simply omits the counts line.
func fetchTaskCounts(ctx manifest.Context) (map[string]int, error) {
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
		Timeout:   2 * time.Second,
	})
	res, err := client.GetConditional(client.BaseURL()+"/v1/tasks/prime?limit=1", "")
	if err != nil {
		return nil, err
	}
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("GET /v1/tasks/prime: status %d", res.StatusCode)
	}
	var env struct {
		Counts map[string]int `json:"counts"`
	}
	// Non-strict decode: prime carries in_progress/ready/events/rails too; we want
	// only the scope-wide counts and must not fail on the rest of the envelope.
	if err := json.Unmarshal(res.Body, &env); err != nil {
		return nil, err
	}
	return env.Counts, nil
}
