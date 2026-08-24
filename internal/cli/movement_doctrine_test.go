package cli

// movement_doctrine_test.go — the DRIFT GATE for the movement-ledger doctrine.
//
// The doctrine's whole value is that it reaches an agent BEFORE the agent starts
// working, on whatever surface it entered through. A copy that quietly stops
// carrying it is indistinguishable from one that never did, so each priming
// surface is asserted here against the one const rather than trusted to stay in
// sync by review.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TestDoctrineInAgentsMDBlock proves the emitted `bp onramp agents-md` block —
// the AGENTS.md convergence standard that ships into a consumer's repo — leads
// with the doctrine, ahead of the verb list. Position is asserted, not just
// presence: a doctrine that trails the mechanics is read after the decision it
// was meant to change.
func TestDoctrineInAgentsMDBlock(t *testing.T) {
	block := agentsMDBlock()
	di := strings.Index(block, movementLedgerDoctrine)
	if di < 0 {
		t.Fatalf("agentsMDBlock no longer carries the movement-ledger doctrine")
	}
	vi := strings.Index(block, "- `bp task ready`")
	if vi < 0 {
		t.Fatalf("agentsMDBlock no longer carries the verb list — this test's ordering premise is gone")
	}
	if di > vi {
		t.Errorf("doctrine appears AFTER the verb list (doctrine@%d, verbs@%d) — it must lead", di, vi)
	}
}

// TestDoctrineOnEveryPrimingSurface walks every file an agent can be primed
// from and requires the doctrine verbatim (the three wrappers the canonical body
// pins) or a pointer to it by name (the per-tool onramp docs, which are prose
// around their own config stanza and would drift if they carried a copy).
//
// Relative paths, exactly as TestOnrampAgentsMdWrapperParity reads them: a
// wrapper file that stops embedding the body fails on the read or the Contains.
func TestDoctrineOnEveryPrimingSurface(t *testing.T) {
	// Verbatim: these three ARE the canonical body, in their own framing.
	for _, path := range []string{
		"../../.cursor/rules/barkpark-tasks.mdc",
		"../../.claude/CLAUDE-BARKPARK.md",
		"../../docs/setup/CODEX.md",
	} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("read %s: %v", path, err)
			continue
		}
		if !strings.Contains(string(raw), movementLedgerDoctrine) {
			t.Errorf("%s no longer carries the movement-ledger doctrine verbatim — drift", path)
		}
	}

	// Pointer: every per-surface onramp doc must at least name the doctrine, so
	// an agent that read only its own tool's page still learns the rule exists.
	// The marker is the doctrine's own sentence-opening phrase, which is what a
	// reader searches for.
	// NOT listed: ../../AGENTS.md. That is this repo's shell-danger card
	// (canonical-for shell-danger-rules) under a BINDING 700B cap it already sits
	// 2B under — a pointer would only fit by retiring a danger rule. This repo's
	// own agents meet the doctrine verbatim via .claude/CLAUDE-BARKPARK.md above.
	const pointer = "Register the movement"
	for _, path := range []string{
		"../../docs/setup/AGENT-ONRAMPS.md",
		"../../docs/setup/AGENTS-MD.md",
		"../../docs/setup/CLAUDE-CODE.md",
		"../../docs/setup/CURSOR.md",
		"../../docs/setup/CURSOR-CLOUD.md",
		"../../docs/setup/CODEX.md",
		"../../docs/setup/WINDSURF.md",
		"../../docs/setup/GEMINI-CLI.md",
		"../../docs/setup/COPILOT.md",
		"../../docs/setup/ZED.md",
		"../../docs/setup/REMOTE.md",
		"../../docs/setup/TASK-SYSTEM.md",
	} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("read %s: %v", path, err)
			continue
		}
		if !strings.Contains(string(raw), pointer) {
			t.Errorf("%s carries no %q pointer — an agent primed from this page alone never meets the doctrine", path, pointer)
		}
	}
}

// TestDoctrineInMCPInstructions proves an MCP-only client is primed WITHOUT
// reading any doc: the doctrine rides InitializeResult.Instructions, which the
// client receives during the handshake before it can call a single tool.
//
// It asserts through a real handshake rather than reading the struct back —
// mcp.Server exposes no getter for its options, so a test that read the const it
// just passed in would prove nothing about what a client actually sees.
func TestDoctrineInMCPInstructions(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		io.WriteString(rw, `{"result":{}}`)
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	var so, se strings.Builder
	out := newWriter(&so, &se)
	srv, err := buildMCPServer(out, globals{}, manifest.Context{Server: ts.URL, Token: "tok"}, m, "tasks", nil, false)
	if err != nil {
		t.Fatalf("buildMCPServer: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil) // performs the initialize handshake
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	got := cs.InitializeResult().Instructions
	if got != movementLedgerDoctrine {
		t.Errorf("MCP initialize instructions are not the doctrine.\n--- got ---\n%s\n--- want ---\n%s", got, movementLedgerDoctrine)
	}
}

// TestDoctrineLineOnTaskPrimeOnly proves the prime preamble fires for task.prime
// and for nothing else — and that it lands on STDERR, so stdout stays one
// parseable document for the json/yaml arms (the emitHelpHints invariant).
func TestDoctrineLineOnTaskPrimeOnly(t *testing.T) {
	cases := []struct {
		noun, verb string
		want       bool
	}{
		{"task", "prime", true},
		{"task", "ready", false},
		{"task", "close", false},
		{"doc", "prime", false},
	}
	for _, c := range cases {
		var so, se strings.Builder
		out := newWriter(&so, &se)
		emitMovementDoctrine(out, manifest.Command{Noun: c.noun, Verb: c.verb})
		got := strings.Contains(se.String(), movementLedgerDoctrineLine)
		if got != c.want {
			t.Errorf("%s %s: doctrine on stderr = %v, want %v", c.noun, c.verb, got, c.want)
		}
		if so.Len() != 0 {
			t.Errorf("%s %s: wrote %q to STDOUT — the doctrine must never enter the payload stream", c.noun, c.verb, so.String())
		}
	}
}

// TestDoctrineNamesOnlyPortableMechanisms is the guard against the most likely
// future mistake: this block ships into OTHER people's repositories via
// `bp onramp agents-md`, so a Barkpark-repo-only mechanic added here (a PR
// trailer, a merge gate, a CI job name) would be instruction that cannot
// possibly apply where it lands. Those belong in docs/setup/TASK-SYSTEM.md.
func TestDoctrineNamesOnlyPortableMechanisms(t *testing.T) {
	for _, banned := range []string{"Task:", "merge gate", "merge-gate", "pull request", "PR body", "github", "GitHub", "CI"} {
		if strings.Contains(movementLedgerDoctrine, banned) {
			t.Errorf("doctrine mentions %q — repo-local mechanics do not travel with the AGENTS.md block; move it to docs/setup/TASK-SYSTEM.md", banned)
		}
	}
}
