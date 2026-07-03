package cli

import (
	"context"
	"os"
	"os/signal"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runExport streams a dataset export (`bp export [--type <t>] [--perspective <p>]`),
// printing each document as one line of NDJSON to stdout — pipe it to a file for a
// backup: `bp export > backup.ndjson`. Exports the active dataset (set with the
// global `-d`). A built-in (not a manifest verb) because the response is a streamed
// NDJSON body, not the single JSON the generic command path decodes.
func runExport(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		out.outf("usage: bp export [--type <t>] [--perspective <p>]")
		out.outf("")
		out.outf("Stream the active dataset as NDJSON (one document per line) for backup:")
		out.outf("  bp export > backup.ndjson")
		return exitOK
	}
	var opts apiclient.ExportOpts
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--type":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--type")
			if err != nil {
				return usageErrf(out, nil, "%v", err)
			}
			opts.Type = v
			i = ni
		case "--perspective":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--perspective")
			if err != nil {
				return usageErrf(out, nil, "%v", err)
			}
			opts.Perspective = v
			if !validPerspective(v) {
				return usageErrf(out, nil, "invalid --perspective %q (want published|drafts|raw)", v)
			}
			i = ni
		default:
			return usageErrf(out, nil, "unknown export flag %q (want --type / --perspective)", a)
		}
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
	})

	// Ctrl-C cancels the context, ending the stream cleanly (exit 0).
	sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	err := client.Export(sigCtx, opts, func(line string) error {
		out.outf("%s", line)
		return nil
	})
	if err != nil && sigCtx.Err() == nil {
		out.errf("export: %v", err)
		return exitGeneric
	}
	return 0
}
