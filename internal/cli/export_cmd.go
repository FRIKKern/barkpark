package cli

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// exportMetaSuffix names the sidecar written next to an `--out` artifact:
// backup.ndjson -> backup.ndjson.meta.
const exportMetaSuffix = ".meta"

// exportPartialSuffix names the file an `--out` export actually streams into:
// backup.ndjson -> backup.ndjson.partial. It sits in the SAME directory as the
// destination — same filesystem, so the promoting rename is atomic and can
// never be a cross-device copy. Until that rename the backup already at
// <file> is untouched, which is the whole point: `os.Create(<file>)` truncated
// last night's good backup to zero bytes before the first new byte arrived.
const exportPartialSuffix = ".partial"

// exportMeta is the sidecar an `--out` export leaves BESIDE the NDJSON, and the
// only artifact-local proof that a backup is whole. The count and the PARTIAL
// warning ride stderr, which on a cron box goes nowhere: six months later a
// truncated backup.ndjson is byte-indistinguishable from a complete one. The
// sidecar closes that hole WITHOUT touching the body — no terminal receipt
// line, because every line-oriented consumer (this command, the JS SDK's bare
// JSON.parse, the published "one document per line" contract) would ingest a
// receipt AS A DOCUMENT.
//
// It is written ONLY after a clean completion, so its ABSENCE is the truncation
// signal — the same discipline internal/backup.Backup uses when it aborts a
// multipart upload rather than completing a truncated object and writes its
// Manifest only after the pipe drains.
type exportMeta struct {
	Documents   int    `json:"documents"`
	Bytes       int64  `json:"bytes"`
	SHA256      string `json:"sha256"`
	Scope       string `json:"scope"`
	CompletedAt string `json:"completed_at"`
}

// runExport streams a dataset export (`bp export [--type <t>] [--perspective <p>]`),
// printing each document as one line of NDJSON to stdout — pipe it to a file for a
// backup: `bp export > backup.ndjson`. Exports the active dataset (set with the
// global `-d`). A built-in (not a manifest verb) because the response is a streamed
// NDJSON body, not the single JSON the generic command path decodes.
func runExport(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		out.outf("usage: bp export [--type <t>] [--perspective <p>] [--out <file>]")
		out.outf("       bp export --verify <file>")
		out.outf("")
		out.outf("Stream the active dataset as NDJSON (one document per line) for backup:")
		out.outf("  bp export > backup.ndjson")
		out.outf("")
		out.outf("On success the document count and byte total are reported on stderr.")
		out.outf("An interrupted or truncated stream exits NON-ZERO and names the output")
		out.outf("as PARTIAL — a backup that exits 0 is a backup that streamed to the end.")
		out.outf("")
		out.outf("--out <file> streams into <file>.partial and renames it onto")
		out.outf("<file> only after a clean completion, together with a <file>.meta")
		out.outf("sidecar {documents,bytes,sha256,scope,completed_at}. A run that")
		out.outf("dies leaves the stub at <file>.partial and does not touch the")
		out.outf("backup already at <file> or its sidecar. A missing sidecar IS the")
		out.outf("truncation signal, so an unattended box never needs stderr, the")
		out.outf("exit code or a log line.")
		out.outf("")
		out.outf("--verify <file> re-derives the sha256 and document count from the")
		out.outf("artifact itself and compares them to the sidecar. It FAILS CLOSED:")
		out.outf("a missing, empty or unparsable sidecar is a refusal, never a pass.")
		return exitOK
	}
	var opts apiclient.ExportOpts
	var outPath, verifyPath string
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--out":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--out")
			if err != nil {
				return usageErrf(out, nil, "%v", err)
			}
			outPath = v
			i = ni
		case "--verify":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--verify")
			if err != nil {
				return usageErrf(out, nil, "%v", err)
			}
			verifyPath = v
			i = ni
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
			return usageErrf(out, nil, "unknown export flag %q (want --type / --perspective / --out / --verify)", a)
		}
	}

	// --verify reads an artifact that already exists; it never streams. Mixing
	// it with the streaming flags would silently ignore one half of the command,
	// so say so instead.
	if verifyPath != "" {
		if outPath != "" || opts.Type != "" || opts.Perspective != "" {
			return usageErrf(out, nil, "--verify checks an existing artifact and cannot be combined with --out / --type / --perspective")
		}
		return runExportVerify(out, verifyPath)
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

	// sink is stdout unless --out names a file. With --out the bytes are hashed
	// as they are written, so the sidecar's sha256 describes exactly the file on
	// disk — no second read, nothing to drift.
	var docs int
	var byteCount int64
	writeLine := func(line string) error {
		out.outf("%s", line)
		docs++
		byteCount += int64(len(line)) + 1 // +1 for the newline `outf` adds
		return nil
	}
	target := exportTarget()
	hash := sha256.New()
	// flush drains the artifact's buffered tail to disk. It runs BEFORE the
	// sidecar is written and its error is fatal: a sidecar that appeared while
	// the last bytes were still in a buffer would attest a file that does not
	// yet exist in the form it describes.
	flush := func() error { return nil }
	// closeArtifact releases the `--out` file handle before the rename, so the
	// bytes are the OS's problem and not a buffer's. It is a no-op without --out.
	closeArtifact := func() error { return nil }
	partialPath := outPath + exportPartialSuffix
	if outPath != "" {
		// NOTHING at outPath is touched here — not the artifact, not its
		// sidecar. The earlier export sitting there is a real backup until this
		// run has a whole one to replace it with, and clearing its sidecar now
		// would strip the attestation off a file that is still perfectly good:
		// `--verify` fails closed, so the operator could not then prove the one
		// copy they have. Both moves happen together in promoteExportOut, after
		// the stream ran to the end.
		f, err := os.Create(partialPath)
		if err != nil {
			out.errf("export: %v", err)
			return exitGeneric
		}
		defer f.Close()
		buf := bufio.NewWriter(f)
		// Even a failed export flushes what it got: the partial file is evidence
		// an operator may want to inspect. It stays unattested either way.
		defer func() { _ = buf.Flush() }()
		flush = func() error {
			if err := buf.Flush(); err != nil {
				return err
			}
			return f.Sync()
		}
		closeArtifact = f.Close
		sink := io.MultiWriter(buf, hash)
		writeLine = func(line string) error {
			n, err := io.WriteString(sink, line+"\n")
			byteCount += int64(n)
			if err != nil {
				return err
			}
			docs++
			return nil
		}
		target = partialPath
	}

	err := client.Export(sigCtx, opts, writeLine)

	// The output is PARTIAL whenever the stream did not run to completion. An
	// operator redirecting into a file (`bp export > backup.ndjson`) otherwise
	// has no way to tell a whole backup from a stub until restore time. With
	// --out the file also stays UNATTESTED — no sidecar is written on any of
	// these paths, which is what makes absence mean truncation.
	switch {
	case sigCtx.Err() != nil:
		out.errf("export: INTERRUPTED after %d documents — %s is PARTIAL, do not restore from it",
			docs, target)
		return exitGeneric
	case err != nil && docs > 0:
		out.errf("export: %v — stopped after %d documents; %s is PARTIAL, do not restore from it",
			err, docs, target)
		return exitGeneric
	case err != nil:
		out.errf("export: %v", err)
		return exitGeneric
	}

	if outPath != "" {
		if err := flush(); err != nil {
			out.errf("export: cannot flush %s: %v — it is UNATTESTED, do not trust it", partialPath, err)
			return exitGeneric
		}
		// The sidecar is written BESIDE THE PARTIAL and travels with it, so the
		// pair is complete before either name at the destination changes.
		if code := writeExportMeta(out, partialPath, exportMeta{
			Documents:   docs,
			Bytes:       byteCount,
			SHA256:      hex.EncodeToString(hash.Sum(nil)),
			Scope:       exportScope(ctx),
			CompletedAt: time.Now().UTC().Format(time.RFC3339),
		}); code != exitOK {
			return code
		}
		if err := closeArtifact(); err != nil {
			out.errf("export: cannot close %s: %v — it is UNATTESTED, do not trust it", partialPath, err)
			return exitGeneric
		}
		if code := promoteExportOut(out, outPath, partialPath); code != exitOK {
			return code
		}
	}

	out.errf("exported %d documents (%d bytes) from %s", docs, byteCount, exportScope(ctx))
	if outPath != "" {
		out.errf("wrote %s and its sidecar %s — verify it later with: bp export --verify %s",
			outPath, outPath+exportMetaSuffix, outPath)
	}
	return exitOK
}

// writeExportMeta writes the sidecar — called ONLY after a clean stream and a
// successful flush. Any failure here leaves the artifact unattested (and says
// so), which is the safe direction: an unverifiable backup beats a falsely
// verified one.
func writeExportMeta(out *writer, outPath string, meta exportMeta) int {
	body, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		out.errf("export: cannot render sidecar: %v — %s is UNATTESTED", err, outPath)
		return exitGeneric
	}
	if err := os.WriteFile(outPath+exportMetaSuffix, append(body, '\n'), 0o644); err != nil {
		out.errf("export: cannot write sidecar %s: %v — %s is UNATTESTED, do not trust it",
			outPath+exportMetaSuffix, err, outPath)
		return exitGeneric
	}
	return exitOK
}

// promoteExportOut moves a finished export from <file>.partial to <file>, in the
// one order that has no bad interleaving.
//
//  1. rename the ARTIFACT — atomic, so <file> is either last night's backup or
//     this one, never a half-written mix and never the zero bytes os.Create used
//     to leave there;
//  2. remove the STALE sidecar, which until this instant still described the old
//     <file> it was written for;
//  3. rename the NEW sidecar LAST.
//
// Between 1 and 3 the artifact is present and unattested, and an unattested
// artifact is exactly what `--verify` refuses — the safe direction. The reverse
// order would leave a sidecar attesting a file that is not there yet, or worse,
// attesting the wrong one. Every failure below stops with the artifact either
// old-and-attested or new-and-unattested; none of them can produce a pass on a
// file nobody proved.
func promoteExportOut(out *writer, outPath, partialPath string) int {
	if err := os.Rename(partialPath, outPath); err != nil {
		out.errf("export: cannot move %s into place at %s: %v — the previous backup at %s is UNTOUCHED",
			partialPath, outPath, err, outPath)
		return exitGeneric
	}
	if err := os.Remove(outPath + exportMetaSuffix); err != nil && !os.IsNotExist(err) {
		out.errf("export: cannot clear stale sidecar %s: %v — %s is UNATTESTED, do not trust it",
			outPath+exportMetaSuffix, err, outPath)
		return exitGeneric
	}
	if err := os.Rename(partialPath+exportMetaSuffix, outPath+exportMetaSuffix); err != nil {
		out.errf("export: cannot move sidecar %s into place: %v — %s is UNATTESTED, do not trust it",
			partialPath+exportMetaSuffix, err, outPath)
		return exitGeneric
	}
	return exitOK
}

// runExportVerify proves an artifact whole from the artifact alone: it re-derives
// the sha256, the document count and the byte total from the file on disk and
// compares them to the sidecar. Nothing here reads stderr, the exit code of the
// run that produced the file, or a log — six months and one machine later, none
// of those exist.
//
// It FAILS CLOSED. scripts/pds-pull-proof.sh:1232-1245 is the design precedent,
// but its `""|full) return 0` treats a missing meta as a pass; here a missing,
// empty, unparsable or sha-less sidecar is a REFUSAL. The whole point is that
// absence means truncation, so absence cannot also mean fine.
func runExportVerify(out *writer, path string) int {
	metaPath := path + exportMetaSuffix
	raw, err := os.ReadFile(metaPath)
	if err != nil {
		if os.IsNotExist(err) {
			out.errf("export --verify: no sidecar at %s — %s is UNVERIFIED and must be treated as PARTIAL",
				metaPath, path)
		} else {
			out.errf("export --verify: cannot read sidecar %s: %v — %s is UNVERIFIED", metaPath, err, path)
		}
		return exitGeneric
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		out.errf("export --verify: sidecar %s is empty — %s is UNVERIFIED and must be treated as PARTIAL",
			metaPath, path)
		return exitGeneric
	}
	var meta exportMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		out.errf("export --verify: sidecar %s is not valid JSON (%v) — %s is UNVERIFIED", metaPath, err, path)
		return exitGeneric
	}
	if meta.SHA256 == "" {
		out.errf("export --verify: sidecar %s carries no sha256 — %s is UNVERIFIED", metaPath, path)
		return exitGeneric
	}

	sum, docs, byteCount, err := deriveExportDigest(path)
	if err != nil {
		out.errf("export --verify: cannot read %s: %v", path, err)
		return exitGeneric
	}

	var mismatches []string
	if sum != meta.SHA256 {
		mismatches = append(mismatches, fmt.Sprintf("sha256 %s, sidecar says %s", sum, meta.SHA256))
	}
	if docs != meta.Documents {
		mismatches = append(mismatches, fmt.Sprintf("%d documents, sidecar says %d", docs, meta.Documents))
	}
	if byteCount != meta.Bytes {
		mismatches = append(mismatches, fmt.Sprintf("%d bytes, sidecar says %d", byteCount, meta.Bytes))
	}
	if len(mismatches) > 0 {
		out.errf("export --verify: %s does NOT match its sidecar — %s. Do not restore from it.",
			path, strings.Join(mismatches, "; "))
		return exitGeneric
	}

	out.outf("%s verified: %d documents, %d bytes, sha256 %s", path, docs, byteCount, sum)
	if meta.Scope != "" || meta.CompletedAt != "" {
		out.outf("exported from %s at %s", orDash(meta.Scope), orDash(meta.CompletedAt))
	}
	return exitOK
}

// deriveExportDigest reads the artifact once and returns its sha256, its
// document count (non-empty NDJSON lines — the same lines the export wrote) and
// its size in bytes.
func deriveExportDigest(path string) (string, int, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, 0, err
	}
	defer f.Close()

	hash := sha256.New()
	counter := &lineCounter{}
	byteCount, err := io.Copy(io.MultiWriter(hash, counter), f)
	if err != nil {
		return "", 0, 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), counter.docs, byteCount, nil
}

// lineCounter counts NEWLINE-TERMINATED non-empty lines in a stream, without
// buffering a whole document — an exported document can be many megabytes, so a
// Scanner with a token cap would be one more thing to get wrong.
//
// A trailing line with no newline is deliberately NOT counted: `bp export`
// terminates every document it writes, so an unterminated tail means the file
// was cut mid-document. Not counting it makes the count disagree with the
// sidecar, which is a refusal — the correct direction.
type lineCounter struct {
	docs     int
	nonEmpty bool // the current line has content
}

func (c *lineCounter) Write(p []byte) (int, error) {
	for _, b := range p {
		if b == '\n' {
			if c.nonEmpty {
				c.docs++
			}
			c.nonEmpty = false
			continue
		}
		c.nonEmpty = true
	}
	return len(p), nil
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
