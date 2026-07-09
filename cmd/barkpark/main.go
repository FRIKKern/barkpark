package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-isatty"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/cli"
)

// main routes between the two faces of the one binary. With any positional
// argument it is the CLI (`barkpark <noun> <verb> …`); with no args it launches
// the interactive TUI unchanged. The CLI returns a process exit code; the TUI
// path is identical to before this split.
func main() {
	if len(os.Args) > 1 {
		code := cli.Execute(os.Args[1:])
		// A login-connect path can ask, on a terminal, to drop the user straight
		// into the TUI desk after a successful auto-connect ("Press Enter to open
		// the desk"). It signals that in-process wish with the ExitOpenDesk
		// sentinel — never a real process status — so we launch the desk here
		// against the freshly-saved server instead of os.Exit-ing the code.
		if code == cli.ExitOpenDesk {
			os.Exit(runTUI())
		}
		os.Exit(code)
	}
	os.Exit(runTUI())
}

// runTUI is the original main() body: connect to Phoenix, load schemas, build
// the structure tree, and run the Bubble Tea program with the live-refresh SSE
// wiring intact. Returns the process exit code.
func runTUI() int {
	// First run (no config.json, no BARKPARK_* env) on a genuine terminal:
	// route into the setup wizard before touching the network, then fall
	// through into the TUI against the freshly-saved server. Non-TTY callers
	// keep the old behaviour (never prompts).
	if cli.FirstRun() && isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stdout.Fd()) {
		configured, code := cli.RunFirstTimeSetup()
		if !configured {
			return code
		}
	}

	// Follow the SAME active server the `bp` CLI uses: resolved through
	// flags(none here) > explicitly-set BARKPARK_* env > saved-config active
	// server > baked defaults. So `bp use prod` moves the TUI too, and an
	// explicit BARKPARK_API_URL still overrides. The TUI also reads the editing
	// "drafts" perspective by default (overridable via BARKPARK_PERSPECTIVE).
	cfg := cli.ResolvedAPIConfig()
	ds := apiclient.New(cfg)

	// Load schemas from Phoenix API
	fmt.Fprintf(os.Stderr, "Connecting to %s [%s] (workspace=%s project=%s dataset=%s perspective=%s)...\n",
		cfg.BaseURL, cli.ServerSource(), ds.Workspace, ds.Project, ds.Dataset, ds.Perspective)
	loaded, err := ds.LoadSchemas()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading schemas: %v\n", err)
		switch {
		case cli.FirstRun():
			fmt.Fprintf(os.Stderr, "No server is configured yet — run `bp setup` to connect to one or bring one up.\n")
		case cli.LoggedInWithoutServer():
			// Signed in to Barkpark Cloud but no barkpark connected: saving the
			// Cloud token made FirstRun() false, so without this branch the user
			// would hit the misleading "Is the Phoenix API running?" hint below
			// (they never asked for a local Phoenix). Point them at setup instead.
			fmt.Fprintf(os.Stderr, "logged in to Barkpark Cloud but no barkpark connected — run `bp setup` to connect one.\n")
		default:
			fmt.Fprintf(os.Stderr, "Is the Phoenix API running? Start it with: cd api && mix phx.server\n")
		}
		return 1
	}
	schemas = loaded
	fmt.Fprintf(os.Stderr, "Loaded %d schemas\n", len(schemas))

	// Desk structure: the server's canonical tree when available (plugin
	// groups included), schema-derived fallback otherwise.
	if buildDesk(ds) {
		fmt.Fprintf(os.Stderr, "Desk structure from server\n")
	} else {
		fmt.Fprintf(os.Stderr, "Desk structure built client-side (server endpoint unavailable)\n")
	}

	// Start TUI
	p := tea.NewProgram(initialModel(ds), tea.WithAltScreen())
	// Wire the client's framework-free change callback to the TUI: when the SSE
	// listener / poll fallback detects a dataset change, push a refresh msg into
	// the program. This preserves the exact live-refresh path.
	ds.OnChange = func() { p.Send(DataStoreRefreshMsg{}) }
	go ds.StartSSE(ds.Token())

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 1
	}
	return 0
}
