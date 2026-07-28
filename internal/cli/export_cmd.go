package cli

import (
	"context"
	"os"
	"os/signal"
	"strings"

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
		out.outf("")
		out.outf("On success the document count and byte total are reported on stderr.")
		out.outf("An interrupted or truncated stream exits NON-ZERO and names the output")
		out.outf("as PARTIAL — a backup that exits 0 is a backup that streamed to the end.")
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

	// Ctrl-C cancels the context, ending the stream early. That is a TRUNCATED
	// backup, so it is reported as a failure below — never a silent exit 0.
	sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	var docs int
	var byteCount int64
	err := client.Export(sigCtx, opts, func(line string) error {
		out.outf("%s", line)
		docs++
		byteCount += int64(len(line)) + 1 // +1 for the newline `outf` adds
		return nil
	})

	// The output is PARTIAL whenever the stream did not run to completion. An
	// operator redirecting into a file (`bp export > backup.ndjson`) otherwise
	// has no way to tell a whole backup from a stub until restore time.
	switch {
	case sigCtx.Err() != nil:
		out.errf("export: INTERRUPTED after %d documents — %s is PARTIAL, do not restore from it",
			docs, exportTarget())
		return exitGeneric
	case err != nil && docs > 0:
		out.errf("export: %v — stopped after %d documents; %s is PARTIAL, do not restore from it",
			err, docs, exportTarget())
		return exitGeneric
	case err != nil:
		out.errf("export: %v", err)
		return exitGeneric
	}

	out.errf("exported %d documents (%d bytes) from %s", docs, byteCount, exportScope(ctx))
	return exitOK
}

// exportTarget names what the NDJSON was written to, so the PARTIAL warning
// points at the file an operator would otherwise restore from. stdout is
// usually a redirect (`bp export > backup.ndjson`), and on Linux
// /proc/self/fd/1 resolves that redirect to its path. macOS exposes /dev/fd/1
// as a character device, not a symlink, so the readlink fails there and the
// message says "the export output (stdout)" — naming the stream it cannot
// resolve rather than guessing a filename. Either way the operator is told
// their backup is partial; only the path is best-effort.
func exportTarget() string {
	for _, fd := range []string{"/proc/self/fd/1", "/dev/fd/1"} {
		if name, err := os.Readlink(fd); err == nil && strings.HasPrefix(name, "/") {
			return name
		}
	}
	return "the export output (stdout)"
}

// exportScope renders the workspace/project/dataset the count belongs to — a
// bare "exported 12 documents" does not say WHICH dataset was backed up.
func exportScope(ctx manifest.Context) string {
	parts := make([]string, 0, 3)
	for _, p := range []string{ctx.Workspace, ctx.Project, ctx.Dataset} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) == 0 {
		return "the active dataset"
	}
	return strings.Join(parts, "/")
}
