package cli

// mcp_serve.go — `bp mcp serve`: a stdio Model-Context-Protocol server that
// exposes Barkpark Tasks to MCP-native clients (Cursor, Claude Desktop, any MCP
// host). This is "path B" for task tracking: path A is the shell-based
// .cursor/rules/barkpark-tasks.mdc card (an agent shells out to `bp task …`);
// path B lets a client that speaks MCP call the SAME task verbs as first-class
// tools, no shell, with the claim-first/epoch-CAS doctrine carried in each
// tool's description so the model uses the queue correctly.
//
// A CLI built-in intercepted before manifest dispatch (like cmux/doctor): `mcp`
// is not a manifest noun, so this intercept shadows nothing and needs no server
// change. runMCPServe loads the capabilities manifest ONCE and reuses the CLI's
// manifest-driven request machinery (BuildURL → buildBody → authHeaders →
// doRequest, run.go) to back each MCP tool — so the tools can never drift from
// what `bp task …` does.
//
// CRITICAL stdio invariant: the JSON-RPC framing rides os.Stdout. A single stray
// byte on os.Stdout corrupts the protocol stream. So every tool handler returns
// its payload as MCP result content and writes NOTHING to os.Stdout — no
// handleResponse, no render*, no receipt. Diagnostics (the startup line, fatal
// errors) go to os.Stderr only.

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// runMCPServe handles `bp mcp serve [--tools tasks|all]`. It loads the manifest,
// registers the curated task tools (and, with --tools all, the generic
// capabilities→MCP bridge), then serves the MCP protocol over stdin/stdout until
// the client disconnects or the process is signalled. Returns the exit code.
//
// The manifest load is fail-fast: an MCP client launches `bp mcp serve` as a
// long-lived subprocess and expects a ready server on the pipe, so a server it
// can't back (no manifest reachable) must die immediately with a clear stderr
// line rather than come up half-alive and 500 every tool call.
func runMCPServe(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printMCPServeHelp(out)
		return exitOK
	}

	toolset, err := parseMCPServeArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printMCPServeHelp(out) }, "%v", err)
	}

	// Load the manifest ONCE (honours --manifest / $BARKPARK_MANIFEST, else the
	// ETag cache / GET /v1/capabilities). Fail fast to stderr + non-zero: the MCP
	// tools are backed by this manifest, so an unreachable one is fatal now, not
	// per-tool-call later.
	m, err := loadManifest(g, ctx)
	if err != nil {
		out.userErr("mcp serve: cannot start — %v", err)
		return exitGeneric
	}

	srv := mcp.NewServer(&mcp.Implementation{
		Name:    "barkpark-tasks",
		Title:   "Barkpark Tasks",
		Version: cliVersion,
	}, nil)

	// The curated five task tools are ALWAYS registered — they are the point of
	// this server. --tools all additionally exposes every other bp capability as a
	// generic tool via the bridge (bridge slice owns registerBridgeTools).
	// Headless liveness (charter decision 5): tool handlers ride the guard-free
	// execManifestCommand seam, but force g.yes anyway as belt-and-braces — a
	// stdin-reading confirm prompt would hang a server whose stdin is the
	// protocol pipe.
	g.yes = true

	if err := registerTaskTools(srv, g, ctx, m); err != nil {
		out.userErr("mcp serve: register task tools: %v", err)
		return exitGeneric
	}
	if toolset == "all" {
		if err := registerBridgeTools(srv, g, ctx, m); err != nil {
			out.userErr("mcp serve: register bridge tools: %v", err)
			return exitGeneric
		}
	}

	// Published papers as read-only MCP resources — independent of --tools (the
	// 40-tool Cursor cap is about TOOLS, not resources). Wholly best-effort: it
	// registers the read template and enumerates the published papers for
	// resources/list, warning to stderr and degrading to template-only on any
	// failure (unreachable API, missing doc verbs) — never fatal to startup.
	registerPaperResources(out, srv, g, ctx, m)

	// Announce readiness on stderr (never stdout — that pipe is the protocol).
	out.errf("bp mcp serve: %s tools over stdio (server %s) — Ctrl-C to stop", toolset, ctx.Server)

	// A signalled process (Ctrl-C, SIGTERM) cancels the context so Run returns
	// cleanly instead of leaving a zombie on the pipe. Run also returns on its own
	// when the client closes stdin (EOF) — the normal end of an MCP session.
	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := srv.Run(runCtx, &mcp.StdioTransport{}); err != nil {
		// A cancelled context (we asked it to stop) is a clean shutdown, not a
		// failure. Any other error (transport fault) is real.
		if runCtx.Err() != nil {
			return exitOK
		}
		out.userErr("mcp serve: %v", err)
		return exitGeneric
	}
	return exitOK
}

// parseMCPServeArgs reads the `--tools tasks|all` selector (default "tasks")
// from the command tail. It accepts both `--tools all` and `--tools=all`. Any
// other flag/positional is a usage error so a typo is not silently ignored.
func parseMCPServeArgs(tail []string) (string, error) {
	toolset := "tasks"
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		key, val, hasInline := a, "", false
		if eq := strings.IndexByte(a, '='); eq >= 0 && strings.HasPrefix(a, "--") {
			key, val, hasInline = a[:eq], a[eq+1:], true
		}
		switch key {
		case "--tools":
			if !hasInline {
				if i+1 >= len(tail) {
					return "", fmt.Errorf("flag --tools needs a value (tasks|all)")
				}
				val = tail[i+1]
				i++
			}
			switch val {
			case "tasks", "all":
				toolset = val
			default:
				return "", fmt.Errorf("invalid --tools %q (want tasks|all)", val)
			}
		default:
			return "", fmt.Errorf("unknown argument %q (mcp serve accepts --tools tasks|all)", a)
		}
	}
	return toolset, nil
}

func printMCPServeHelp(out *writer) {
	out.outf(`usage: bp mcp serve [--tools tasks|all]
  Run a stdio Model-Context-Protocol server exposing Barkpark to MCP clients
  (Cursor, Claude Desktop, any MCP host). Path B for task tracking — the
  MCP-native counterpart to the shell-based .cursor/rules/barkpark-tasks.mdc
  card. Speaks JSON-RPC over stdin/stdout; run it as a subprocess from your MCP
  client config, never interactively.

flags:
  --tools tasks|all   Which tools to expose. "tasks" (default) is the curated
                      five — task_ready, task_next, task_show, task_close,
                      task_create. "all" additionally bridges every other bp
                      capability into a generic tool.

The server resolves its target Barkpark the same way every other bp command
does (-s / --token / BARKPARK_* env / saved config). Register it in Cursor via
~/.cursor/mcp.json (global) or .cursor/mcp.json (per-project):

  {
    "mcpServers": {
      "barkpark": {
        "command": "bp",
        "args": ["mcp", "serve"],
        "env": { "BARKPARK_API_URL": "https://your.barkpark", "BARKPARK_API_TOKEN": "…" }
      }
    }
  }`)
}
