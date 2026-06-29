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
	types := ""
	if len(args) > 0 {
		types = args[0]
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
