package cli

import (
	"context"
	"os"
	"os/signal"

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
			out.errf("barkpark: unknown listen flag %q (bp listen takes one comma-separated type list)", a)
			return exitUsage
		}
		if haveTypes {
			out.errf("barkpark: bp listen takes one comma-separated type list (got extra %q)", a)
			return exitUsage
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

	err := client.Listen(sigCtx, types, func(_, data string) error {
		out.outf("%s", data)
		return nil
	})
	if err != nil && sigCtx.Err() == nil {
		out.errf("listen: %v", err)
		return exitGeneric
	}
	return 0
}
