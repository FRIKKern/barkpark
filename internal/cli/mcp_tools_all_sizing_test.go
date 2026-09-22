package cli

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"sort"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcp_tools_all_sizing_test.go — the DURABLE half of ctx-b4-mcp-tools-all-sizing.
//
// The census found the MCP surface essentially unexercised, so the `--tools all`
// session-start cost (one tools/list payload every client pays before it can do
// anything) was real in code and unmeasured. TestMCPToolsListPayloadSize
// recomputes that figure from the COMMITTED manifest golden on every run, so the
// number stops being a one-off note in a PR body and becomes something the suite
// re-derives after any edit to bridgeInputSchema, the curated overlay, or the
// golden.
//
// WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT.
// It asserts only NON-VACUITY: each toolset advertises at least one tool, and
// `--tools all` advertises strictly more than the default. There is NO byte
// threshold here on purpose — the parent row ratifies that census thresholds are
// FORBIDDEN until measured, and a threshold picked in the same commit as the
// first measurement is a number invented, not observed. The bytes are LOGGED
// (`go test -run TestMCPToolsListPayloadSize -v ./internal/cli/`), so a change
// that doubles the payload is visible to a reader without this test turning red
// for legitimate growth in the manifest.
//
// LIVE FIGURES (2026-09-18, guerrilla admin tier, a REAL stdio session:
// `bp mcp serve --tools <sel>` fed an initialize + tools/list JSON-RPC pair on
// stdin, the tools/list response measured with wc -c):
//
//	--tools all    214 tools   146,385 B wire  (result.tools array 146,066 B)
//	--tools tasks   12 tools    25,433 B wire  (result.tools array  25,389 B)
//
// Of the live `--tools all` payload, 90,512 B is derived inputSchema and
// 34,131 B is description prose; a SINGLE command (bp_task_stage, 12,261 B) is
// 8.4% of the whole payload on its own.
//
// VERDICT: NO DIET NEEDED. ~146 KB (~36k tokens at the conventional 4 bytes/token
// approximation — no token-counting key was available in the measuring
// environment, so the token figure is an ESTIMATE and the BYTES are the measured
// fact) is a real but strictly OPT-IN cost: only `--tools all` pays it, and the
// default `--tools tasks` surface is 5.8x smaller. The bridge is already
// brief-shaped — name + summary + derived schema, nothing else — so there is no
// structural fat to cut. The only lever, if one is ever wanted, is trimming the
// fattest individual manifest summaries and schemas (the top-10 this test logs),
// which is a manifest-authoring question, not a bridge question.
//
// THE GOLDEN IS STRIPPED — READ THIS BEFORE QUOTING THE LOGGED NUMBERS.
// The golden used is internal/manifest/testdata/capabilities-guerrilla-2026-09-04.json
// (committed 2026-09-04, so it PREDATES #18611). It is a SHAPE fixture, not a
// byte-faithful capture: every command in it carries `"summary": null`, and its
// args/flags carry neither `summary` nor `type`. So the payload this test
// computes is a strict FLOOR that measures the SCHEMA SHAPE the bridge derives,
// and omits essentially all of the prose the live server sends. That is why the
// logged `--tools all` figure (~76 KB) is roughly half the live 146 KB, and why
// its whole description budget equals the curated tools\' alone (the curated
// descriptions are hardcoded in mcp_tasks.go/mcp_chat.go, not manifest-derived).
// The test LOGS the summary coverage of the golden so this stays visible: if the
// golden is ever refreshed from a real capabilities response, the coverage jumps
// off zero and the byte figure jumps with it — expected, not a regression.
// (internal/apiclient/testdata/capabilities.json, committed 2026-09-16, is
// stripped the same way, so it is no better a corpus; the manifest golden was
// chosen because it declares 207 commands against the live 212.)
//
// Tool-count cross-check, live vs golden, which confirms the bridge is pure over
// the manifest: golden 207 commands - 10 bridgeShadowedIDs + 12 curated = 209,
// exactly what this test observes; live 212 - 10 + 12 = 214, exactly what the
// stdio session observed.
const sizingCapabilitiesGolden = "../manifest/testdata/capabilities-guerrilla-2026-09-04.json"

// toolsListPayloadSize builds the MCP server for one toolset over the golden
// manifest, drains tools/list the way a client does, and returns the tool count
// plus the byte size of the advertised tool array (the JSON-RPC envelope is a
// fixed ~320 B on top, so the array IS the payload for sizing purposes).
func toolsListPayloadSize(t *testing.T, m *manifest.Manifest, toolset string) (int, int, []*mcp.Tool) {
	t.Helper()
	out := newWriter(io.Discard, io.Discard)
	srv, err := buildMCPServer(out, globals{}, manifest.Context{Server: "http://x"}, m, toolset, nil, false)
	if err != nil {
		t.Fatalf("buildMCPServer(%q): %v", toolset, err)
	}
	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect(%q): %v", toolset, err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "sizing", Version: "0"}, nil).Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect(%q): %v", toolset, err)
	}
	t.Cleanup(func() { cs.Close() })

	var tools []*mcp.Tool
	var cursor string
	for {
		res, lerr := cs.ListTools(bg, &mcp.ListToolsParams{Cursor: cursor})
		if lerr != nil {
			t.Fatalf("ListTools(%q): %v", toolset, lerr)
		}
		tools = append(tools, res.Tools...)
		if res.NextCursor == "" {
			break
		}
		cursor = res.NextCursor
	}
	raw, err := json.Marshal(tools)
	if err != nil {
		t.Fatalf("marshal tools(%q): %v", toolset, err)
	}
	return len(tools), len(raw), tools
}

func TestMCPToolsListPayloadSize(t *testing.T) {
	raw, err := os.ReadFile(sizingCapabilitiesGolden)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	m, err := manifest.Parse(raw)
	if err != nil {
		t.Fatalf("parse golden: %v", err)
	}

	curatedCount, curatedBytes, _ := toolsListPayloadSize(t, m, "tasks")
	allCount, allBytes, allTools := toolsListPayloadSize(t, m, "all")

	withSummary := 0
	for _, c := range m.Commands {
		if c.Summary != "" {
			withSummary++
		}
	}
	t.Logf("golden %s (%d B on disk, %d commands, committed 2026-09-04, PREDATES #18611)", sizingCapabilitiesGolden, len(raw), len(m.Commands))
	t.Logf("golden summary coverage: %d/%d commands carry a non-empty summary — at 0 the golden is STRIPPED and every byte figure below is a schema-shape FLOOR, not a live payload size (see the file comment)", withSummary, len(m.Commands))
	t.Logf("tools/list --tools tasks: %d tools, %d B", curatedCount, curatedBytes)
	t.Logf("tools/list --tools all:   %d tools, %d B", allCount, allBytes)

	// Non-vacuity only — no byte threshold (census thresholds are FORBIDDEN
	// until measured; see the file comment). A zero here means the surface did
	// not register at all and every figure above is meaningless.
	if curatedCount == 0 {
		t.Fatalf("--tools tasks advertised ZERO tools: the sizing figures measure nothing")
	}
	if allCount == 0 {
		t.Fatalf("--tools all advertised ZERO tools: the sizing figures measure nothing")
	}
	if allCount <= curatedCount {
		t.Fatalf("--tools all advertised %d tools, not more than the curated default's %d: the bridge registered nothing", allCount, curatedCount)
	}

	// Where the bytes are: the schema half vs the description half, and the
	// fattest tools. This is the part that makes the verdict actionable — a
	// diet, if ever wanted, targets the top of this list, not the bridge shape.
	var descBytes, schemaBytes int
	type row struct {
		n    string
		size int
	}
	rows := make([]row, 0, len(allTools))
	for _, tool := range allTools {
		descBytes += len(tool.Description)
		sb, serr := json.Marshal(tool.InputSchema)
		if serr != nil {
			t.Fatalf("marshal schema %s: %v", tool.Name, serr)
		}
		schemaBytes += len(sb)
		b, merr := json.Marshal(tool)
		if merr != nil {
			t.Fatalf("marshal tool %s: %v", tool.Name, merr)
		}
		rows = append(rows, row{tool.Name, len(b)})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].size > rows[j].size })
	t.Logf("--tools all byte split: descriptions %d B, inputSchemas %d B", descBytes, schemaBytes)
	for i := 0; i < 10 && i < len(rows); i++ {
		t.Logf("  top-%02d %7d B  %s", i+1, rows[i].size, rows[i].n)
	}
}
