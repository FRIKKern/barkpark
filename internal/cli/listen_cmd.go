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
func runListen(out *writer, _ globals, ctx manifest.Context, args []string) int {
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
