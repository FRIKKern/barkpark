package cli

import (
	"context"
	"encoding/json"
	"os"
	"os/signal"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runListen streams the live change feed (`bp listen [type[,type…]]`), printing
// each event's data payload one per line until interrupted (Ctrl-C) or the
// stream ends. A built-in (not a manifest verb) because SSE is a long-lived
// streaming response, not the single JSON body the generic command path decodes.
func runListen(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		out.outf("usage: bp listen [type[,type…]]")
		out.outf("")
		out.outf("Stream the live change feed as JSON, one event per line, until Ctrl-C.")
		out.outf("Optional positional: a comma-separated type list (e.g. `bp listen post,article`).")
		return exitOK
	}
	// bp listen takes exactly one non-flag positional: the comma-separated type
	// list. Reject unknown flags and a second positional instead of silently
	// dropping them (so `bp listen post article` and `bp listen --type post`
	// error at exit-usage rather than streaming a mysteriously filtered feed).
	// Validate before opening any connection, mirroring runExport.
	types := ""
	haveTypes := false
	for _, a := range args {
		if len(a) > 1 && a[0] == '-' {
			return usageErrf(out, nil, "unknown listen flag %q (bp listen takes one comma-separated type list)", a)
		}
		if haveTypes {
			return usageErrf(out, nil, "bp listen takes one comma-separated type list (got extra %q)", a)
		}
		types = a
		haveTypes = true
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
	})

	// Ctrl-C cancels the context, which ends the stream cleanly (exit 0).
	sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	// On an interactive terminal, print a one-line readiness banner to stderr
	// (like `stripe listen`) so the user knows the stream connected instead of
	// staring at a frozen cursor until the first event. Gated to isTTY and on
	// stderr, so `bp listen | jq` keeps stdout NDJSON clean.
	if out.isTTY {
		if types != "" {
			out.errf("listening for changes on %s (types: %s) — Ctrl-C to stop", ctx.Server, types)
		} else {
			out.errf("listening for changes on %s — Ctrl-C to stop", ctx.Server)
		}
	}

	// The stream now survives drops (deploy / proxy idle timeout): Listen backs
	// off and reconnects, resuming from the last event id. On an interactive
	// terminal, note each reconnect on stderr so the user sees the gap; stdout
	// NDJSON stays clean for `bp listen | jq`.
	// The type list is applied HERE. The server's listen route does not read
	// `?types=` — it streams every type in scope — so `bp listen post` printed
	// article mutations too (stranger walk, 2026-09-30). The param still rides
	// the request for a server that learns to filter.
	wanted := listenTypeSet(types)
	err := client.Listen(sigCtx, types, func(event, data string) error {
		if !listenEventWanted(wanted, event, data) {
			return nil
		}
		out.outf("%s", data)
		return nil
	}, func() {
		if out.isTTY {
			out.errf("reconnecting to %s …", ctx.Server)
		}
	})
	if err != nil && sigCtx.Err() == nil {
		out.errf("listen: %v", err)
		return exitGeneric
	}
	return 0
}

// listenTypeSet turns `post, article` into its set of names; nil when no type
// was asked for (every event passes).
func listenTypeSet(types string) map[string]bool {
	set := map[string]bool{}
	for _, t := range strings.Split(types, ",") {
		if t = strings.TrimSpace(t); t != "" {
			set[t] = true
		}
	}
	if len(set) == 0 {
		return nil
	}
	return set
}

// listenEventWanted reports whether one SSE frame belongs on stdout. Only a
// `mutation` frame is judged, by its document type (top-level `type`, else
// `result._type`); welcome and other control frames always pass, and a frame
// that names no type is kept rather than lost.
func listenEventWanted(wanted map[string]bool, event, data string) bool {
	if wanted == nil || event != "mutation" {
		return true
	}
	var frame struct {
		Type   string `json:"type"`
		Result struct {
			Type string `json:"_type"`
		} `json:"result"`
	}
	if json.Unmarshal([]byte(data), &frame) != nil {
		return true
	}
	t := frame.Type
	if t == "" {
		t = frame.Result.Type
	}
	if t == "" {
		return true
	}
	return wanted[t]
}
