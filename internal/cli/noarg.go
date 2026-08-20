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
	// Counts is the published per-type document tally (type → total) from
	// GET /v1/data/counts/:dataset. Optional and best-effort: an empty or nil
	// map (an offline / pre-counts server) simply drops the "documents:" line —
	// the card is complete and honest without it.
	Counts map[string]int
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
	if line := formatDatasetCountsLine(info.Counts); line != "" {
		fmt.Fprintf(&b, "%s\n", line)
	}
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

// formatNounCountsLine renders the ONE honest count line a bare `bp <noun>` prints
// above its verb list, from the dataset-wide published counts map (type → total).
// It returns "" when the noun has no entry — a pre-counts server, or a command noun
// that is not a stored content type (`bp doc`, `bp search`) — so the caller drops
// the line and prints the bare verb list exactly as before. A present-but-zero
// count DOES render ("0 published"): "this type exists and is empty" is honest,
// scannable information, distinct from "this server does not report counts".
func formatNounCountsLine(noun string, counts map[string]int) string {
	n, ok := counts[noun]
	if !ok {
		return ""
	}
	unit := "documents"
	if n == 1 {
		unit = "document"
	}
	return fmt.Sprintf("%s: %d published %s", noun, n, unit)
}

// formatDatasetCountsLine renders the compact per-type summary the non-TTY status
// card shows (it stands in for a specific noun, so it aggregates every type). Types
// order by count (desc, then name) so the heaviest are first; zero-count types are
// omitted; a grand total closes the line and the list caps at datasetCountsCap with
// a "+N more" tail so a schema-rich dataset never floods the card. "" for an empty
// map so the card simply omits the line — the same best-effort discipline.
func formatDatasetCountsLine(counts map[string]int) string {
	type row struct {
		typ string
		n   int
	}
	var rows []row
	total := 0
	for t, n := range counts {
		if n <= 0 {
			continue
		}
		rows = append(rows, row{t, n})
		total += n
	}
	if len(rows) == 0 {
		return ""
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].n != rows[j].n {
			return rows[i].n > rows[j].n
		}
		return rows[i].typ < rows[j].typ
	})
	overflow := len(rows) - datasetCountsCap
	var parts []string
	for i, r := range rows {
		// Collapse the tail into "+N more" only when it hides more than one row —
		// a "+1 more" is wider than the single "N type" it replaces, so a lone
		// trailing type is shown, not hidden.
		if i >= datasetCountsCap && overflow > 1 {
			parts = append(parts, fmt.Sprintf("+%d more", overflow))
			break
		}
		parts = append(parts, fmt.Sprintf("%d %s", r.n, r.typ))
	}
	return fmt.Sprintf("documents: %s  (%d total)", strings.Join(parts, " · "), total)
}

// datasetCountsCap bounds how many per-type rows the status card's documents line
// shows before collapsing the rest into "+N more" — enough to be informative, few
// enough to stay one scannable line on a dataset with dozens of content types.
const datasetCountsCap = 6

// fetchDatasetCounts issues ONE best-effort GET /v1/data/counts/:dataset against
// the resolved target and returns its published per-type counts. Same short-fused
// discipline as fetchTaskCounts: a 2s timeout so a bare `bp <noun>` against a dead
// or pre-counts server (no data.counts route) degrades in two seconds, and every
// error path returns (nil, err) so the caller simply omits the counts line. Frozen
// response shape (charter decision 19 — do not improvise):
// {"ok":true,"dataset":"<ds>","perspective":"published","counts":{"<type>":N,...}}.
func fetchDatasetCounts(ctx manifest.Context) (map[string]int, error) {
	dataset := ctx.Dataset
	if dataset == "" {
		return nil, fmt.Errorf("no dataset resolved")
	}
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   dataset,
		Timeout:   2 * time.Second,
	})
	res, err := client.GetConditional(client.BaseURL()+"/v1/data/counts/"+url.PathEscape(dataset), "")
	if err != nil {
		return nil, err
	}
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("GET /v1/data/counts/%s: status %d", dataset, res.StatusCode)
	}
	var env struct {
		Counts map[string]int `json:"counts"`
	}
	// Non-strict decode: the envelope also carries ok/dataset/perspective; we want
	// only counts and must not fail on the surrounding keys.
	if err := json.Unmarshal(res.Body, &env); err != nil {
		return nil, err
	}
	return env.Counts, nil
}

// nounCountsLine resolves the single best-effort counts line for a bare `bp <noun>`
// at the shared usage block, or "" when it must be omitted. Keeping the omission
// rules here (not inline in the dispatcher) makes every branch unit-testable without
// a live Execute: machine output (-o json|yaml) carries no line; the `task` noun is
// excluded because it prints its own richer lifecycle line above the verb list; and
// any fetch or shape failure against the resolved server drops the line silently so
// the verb usage still renders. counts[noun] present → the line; absent → "".
func nounCountsLine(noun string, machineOut bool, ctx manifest.Context) string {
	if machineOut || noun == "task" {
		return ""
	}
	counts, err := fetchDatasetCounts(ctx)
	if err != nil {
		return ""
	}
	return formatNounCountsLine(noun, counts)
}

// BestEffortDatasetCounts fetches the published per-type counts for the non-TTY
// status card. Exported so cmd/barkpark's headless path can populate
// StatusCardInfo.Counts without reaching into the unexported fetch; it returns nil
// on any error (offline / pre-counts server) so the card simply omits the line.
func BestEffortDatasetCounts(server, token, workspace, project, dataset string) map[string]int {
	counts, err := fetchDatasetCounts(manifest.Context{
		Server:    server,
		Token:     token,
		Workspace: workspace,
		Project:   project,
		Dataset:   dataset,
	})
	if err != nil {
		return nil
	}
	return counts
}
