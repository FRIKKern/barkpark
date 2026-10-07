package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// importMaxMutations is the per-request mutation cap the server enforces in
// BarkparkWeb.Plugs.RequireWithinQuota (@max_mutations 1_000, a 422
// batch_too_large above it).
const importMaxMutations = 1000

// importDefaultBatchBytes is the default /v1/data body cap. The endpoint caps a
// /v1/data body at three documents at the per-document cap
// (endpoint.ex data_body_length/0: min(DocumentSize.max_bytes() * 3, 100 MB)),
// and the per-document default is 10_000_000 bytes, so the default body cap is
// 30_000_000 bytes. A server configured with a smaller document cap has a
// smaller body cap; --batch-bytes lowers the client side to match.
const importDefaultBatchBytes = 30_000_000

// importServerOwnedKeys are the envelope keys the server writes and a restore
// must not send back: Barkpark.Content.Envelope's reserved set minus _id and
// _type, which name the document. It is the same list the old manual recipe in
// `bp export --help` deleted with jq.
var importServerOwnedKeys = []string{"_rev", "_draft", "_publishedId", "_createdAt", "_updatedAt"}

// importRow is one document line of the NDJSON backup.
type importRow struct {
	Line   int    // 1-based physical line in the file
	ID     string // the exported _id, drafts.<id> for a draft row
	Type   string
	Draft  bool
	Action string // create | overwrite | skip
	// mutations are the encoded mutation objects for this row: one
	// createOrReplace, plus a publish for a published row. A row's mutations
	// always travel in the same batch, so a row is applied whole or not at all.
	mutations [][]byte
}

// importBatch is a run of rows sent as one /v1/data/mutate request.
type importBatch struct {
	rows      []*importRow
	mutations int
	body      []byte
}

// runImport restores a `bp export` NDJSON backup into the active dataset
// (`bp import <file.ndjson>`). It keeps the semantics of the manual recipe that
// `bp export --help` used to print: a published row becomes createOrReplace +
// publish, a drafts.<id> row becomes createOrReplace on that draft id and stays
// a draft, published rows go first, and the server-owned keys are dropped. It
// adds what a shell recipe cannot: a dry run, a refusal for ids that already
// exist, batching under the mutate limits, and a resumable failure point.
func runImport(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		usageImport(out, true)
		return exitOK
	}
	var path string
	overwrite := false
	dryRun := g.dryRun
	yes := g.yes
	fromLine := 0
	batchBytes := importDefaultBatchBytes
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--overwrite":
			overwrite = true
			i++
		case "--dry-run":
			dryRun = true
			i++
		case "--yes":
			yes = true
			i++
		case "--from-line":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--from-line")
			if err != nil {
				return usageErrf(out, func() { usageImport(out, false) }, "%v", err)
			}
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 {
				return usageErrf(out, func() { usageImport(out, false) }, "invalid --from-line %q (want a line number, 1 or more)", v)
			}
			fromLine = n
			i = ni
		case "--batch-bytes":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--batch-bytes")
			if err != nil {
				return usageErrf(out, func() { usageImport(out, false) }, "%v", err)
			}
			n, err := strconv.Atoi(v)
			if err != nil || n < 1024 {
				return usageErrf(out, func() { usageImport(out, false) }, "invalid --batch-bytes %q (want a byte count, 1024 or more)", v)
			}
			batchBytes = n
			i = ni
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				return usageErrf(out, func() { usageImport(out, false) },
					"unknown import flag %q (want --dry-run / --overwrite / --from-line / --batch-bytes / --yes)", a)
			}
			if path != "" {
				return usageErrf(out, func() { usageImport(out, false) }, "import takes one file; got %q and %q", path, a)
			}
			path = a
			i++
		}
	}
	if path == "" {
		return usageErrf(out, func() { usageImport(out, false) }, "import needs the NDJSON file a `bp export` wrote")
	}

	if code := importCheckSidecar(out, path); code != exitOK {
		return code
	}

	rows, err := importReadRows(path)
	if err != nil {
		return useError(out, "validation_failed", fmt.Sprintf("import: %s: %v. Nothing was written.", path, err), exitValidation)
	}
	ordered := importApplyOrder(rows)

	// --from-line names the row a failed run stopped at. Everything the import
	// applies BEFORE that row in apply order is skipped, which is exactly the
	// set the failed run already wrote.
	if fromLine > 0 {
		start := -1
		for k, r := range ordered {
			if r.Line == fromLine {
				start = k
				break
			}
		}
		if start < 0 {
			return usageErrf(out, nil, "--from-line %d: %s has no document on line %d", fromLine, path, fromLine)
		}
		for _, r := range ordered[:start] {
			r.Action = "skip"
		}
	}

	dataset := ctx.Dataset
	if dataset == "" {
		dataset = "production"
	}
	scope := exportScope(manifest.Context{Workspace: ctx.Workspace, Project: ctx.Project, Dataset: dataset})

	existing, err := importTargetIDs(ctx, dataset)
	if err != nil {
		return useError(out, "request_failed",
			fmt.Sprintf("import: cannot read the ids already in %s: %v. Nothing was written.", scope, err), exitGeneric)
	}

	var collisions []string
	for _, r := range ordered {
		if r.Action == "skip" {
			continue
		}
		if importCollides(r, existing) {
			r.Action = "overwrite"
			collisions = append(collisions, r.ID)
		} else {
			r.Action = "create"
		}
	}

	batches, err := importBatches(ordered, batchBytes)
	if err != nil {
		return useError(out, "validation_failed", fmt.Sprintf("import: %v. Nothing was written.", err), exitValidation)
	}

	refused := len(collisions) > 0 && !overwrite
	if dryRun {
		// The dry run predicts the real run: when it would be refused, the
		// report says so and the exit code is the refusal's.
		var refusedIDs []string
		if refused {
			refusedIDs = collisions
		}
		importRenderPlan(out, path, scope, ordered, len(batches), refusedIDs)
		if refused {
			return exitConflict
		}
		return exitOK
	}

	if refused {
		details, _ := json.Marshal(map[string]any{"ids": collisions})
		msg := fmt.Sprintf("import: %d document(s) in %s already exist in %s and would be replaced: %s. Nothing was written.",
			len(collisions), path, scope, strings.Join(collisions, ", "))
		if !renderErrorEnvelopeRemedy(out, "conflict", msg, "", "re-run with --overwrite to replace them, or import into an empty dataset", details, "") {
			out.userErr("%s", msg)
			out.errf("  hint: re-run with --overwrite to replace them, or import into an empty dataset")
			humanErrorCode(out, "conflict")
		}
		return exitConflict
	}

	if isProd(ctx, &manifest.Manifest{}) && !yes && !serverDeclaredNonProd(ctx.Server) {
		if !confirmProdWrite(out, manifest.Command{Noun: "import", Verb: path}, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}

	u := ctxScopedURL(ctx, "/v1/data/mutate/"+url.PathEscape(dataset))
	applied := 0
	for n, b := range batches {
		if code, failed := importWriteBatch(out, u, ctx, b); failed {
			first := b.rows[0].Line
			out.errf("import: batch %d of %d stopped at line %d of %s. %d document(s) before it were applied; nothing from that batch was confirmed.",
				n+1, len(batches), first, path, applied)
			out.errf("  resume with: bp import %s --from-line %d", path, first)
			return code
		}
		applied += len(b.rows)
		if !out.machineOut() && len(batches) > 1 {
			out.errf("import: batch %d of %d applied (%d documents)", n+1, len(batches), applied)
		}
	}

	counts := importActionCounts(ordered)
	payload := map[string]any{
		"ok": true, "file": path, "scope": scope, "dry_run": false,
		"applied": applied, "batches": len(batches), "counts": counts,
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("imported %d documents into %s from %s (%d created, %d overwritten, %d skipped) in %d batch(es)",
		applied, scope, path, counts["create"], counts["overwrite"], counts["skip"], len(batches))
	return exitOK
}

// importCheckSidecar refuses a file whose `bp export --out` sidecar disagrees
// with it, because that file is a truncated or edited backup. A file with no
// sidecar (a `bp export > file` redirect) is imported with a note on stderr.
func importCheckSidecar(out *writer, path string) int {
	raw, err := os.ReadFile(path + exportMetaSuffix)
	if err != nil {
		if os.IsNotExist(err) {
			out.errf("import: %s has no %s sidecar, so it cannot be checked for truncation", path, exportMetaSuffix)
			return exitOK
		}
		return useError(out, "validation_failed", fmt.Sprintf("import: cannot read %s%s: %v", path, exportMetaSuffix, err), exitValidation)
	}
	var meta exportMeta
	if err := json.Unmarshal(raw, &meta); err != nil || meta.SHA256 == "" {
		return useError(out, "validation_failed",
			fmt.Sprintf("import: the sidecar %s%s is unreadable. Run `bp export --verify %s` before restoring from it.", path, exportMetaSuffix, path),
			exitValidation)
	}
	sum, docs, _, err := deriveExportDigest(path)
	if err != nil {
		return useError(out, "validation_failed", fmt.Sprintf("import: cannot read %s: %v", path, err), exitValidation)
	}
	if sum != meta.SHA256 || docs != meta.Documents {
		return useError(out, "validation_failed",
			fmt.Sprintf("import: %s does not match its sidecar (%d documents, sidecar says %d). Nothing was written. Run `bp export --verify %s` for the details.",
				path, docs, meta.Documents, path),
			exitValidation)
	}
	return exitOK
}

// importReadRows parses the backup. Each non-empty line must be one JSON
// object with a string _id and _type. The export controller's
// `{"_barkpark_export":"incomplete"}` marker has neither, so a backup the
// server cut short is refused here, before anything is written. The lines are
// read without a size cap because one exported document can be many megabytes.
func importReadRows(path string) ([]*importRow, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	r := bufio.NewReader(f)
	var rows []*importRow
	seen := map[string]int{}
	line := 0
	for {
		raw, rerr := r.ReadBytes('\n')
		if rerr != nil && !errors.Is(rerr, io.EOF) {
			return nil, rerr
		}
		if len(raw) > 0 {
			line++
			if trimmed := bytes.TrimSpace(raw); len(trimmed) > 0 {
				row, err := importParseRow(trimmed, line)
				if err != nil {
					return nil, err
				}
				if prev, dup := seen[row.ID]; dup {
					return nil, fmt.Errorf("line %d repeats the id %q from line %d", line, row.ID, prev)
				}
				seen[row.ID] = line
				rows = append(rows, row)
			}
		}
		if rerr != nil {
			break
		}
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("the file holds no documents")
	}
	return rows, nil
}

// importParseRow turns one NDJSON line into a row and its mutations. The
// fields are kept as raw JSON so every value round-trips byte for byte; only
// the server-owned keys are removed.
func importParseRow(raw []byte, line int) (*importRow, error) {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("line %d is not a JSON object: %v", line, err)
	}
	if _, ok := doc["_barkpark_export"]; ok {
		return nil, fmt.Errorf("line %d is the export's incomplete marker, so the backup was cut short; do not restore from it", line)
	}
	var id, typ string
	if err := json.Unmarshal(doc["_id"], &id); err != nil || id == "" {
		return nil, fmt.Errorf("line %d has no string _id", line)
	}
	if err := json.Unmarshal(doc["_type"], &typ); err != nil || typ == "" {
		return nil, fmt.Errorf("line %d (%s) has no string _type", line, id)
	}
	for _, k := range importServerOwnedKeys {
		delete(doc, k)
	}
	body, err := json.Marshal(doc)
	if err != nil {
		return nil, fmt.Errorf("line %d: %v", line, err)
	}

	row := &importRow{Line: line, ID: id, Type: typ, Draft: strings.HasPrefix(id, "drafts.")}
	row.mutations = append(row.mutations, importJoin(`{"createOrReplace":`, body, `}`))
	if !row.Draft {
		publish, _ := json.Marshal(map[string]any{"publish": map[string]string{"id": id, "type": typ}})
		row.mutations = append(row.mutations, publish)
	}
	return row, nil
}

func importJoin(prefix string, body []byte, suffix string) []byte {
	b := make([]byte, 0, len(prefix)+len(body)+len(suffix))
	b = append(b, prefix...)
	b = append(b, body...)
	return append(b, suffix...)
}

// importApplyOrder puts every published row before every draft row, keeping
// file order inside each group, so a draft lands on top of its published twin.
func importApplyOrder(rows []*importRow) []*importRow {
	ordered := make([]*importRow, 0, len(rows))
	for _, r := range rows {
		if !r.Draft {
			ordered = append(ordered, r)
		}
	}
	for _, r := range rows {
		if r.Draft {
			ordered = append(ordered, r)
		}
	}
	return ordered
}

// importTargetIDs reads every id already in the target dataset, drafts
// included, through the same streamed export `bp export` uses.
func importTargetIDs(ctx manifest.Context, dataset string) (map[string]bool, error) {
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   dataset,
	})
	ids := map[string]bool{}
	err := client.Export(context.Background(), apiclient.ExportOpts{Perspective: "raw"}, func(line string) error {
		var head struct {
			ID string `json:"_id"`
		}
		if err := json.Unmarshal([]byte(line), &head); err != nil {
			return fmt.Errorf("unreadable export line: %v", err)
		}
		if head.ID != "" {
			ids[head.ID] = true
		}
		return nil
	})
	return ids, err
}

// importCollides reports whether applying r replaces a document the target
// already holds. A published row writes its draft id and then publishes over
// the published id, so either one existing is a collision. A draft row writes
// only its own drafts.<id>.
func importCollides(r *importRow, existing map[string]bool) bool {
	if r.Draft {
		return existing[r.ID]
	}
	return existing[r.ID] || existing["drafts."+r.ID]
}

// importBatches packs the rows that are not skipped into requests of at most
// importMaxMutations mutations and maxBytes body bytes. The body is built here
// from the encoded mutations, so the size checked is the size sent. The order
// inside a batch is set by importBatchBody.
func importBatches(rows []*importRow, maxBytes int) ([]importBatch, error) {
	var batches []importBatch
	var cur importBatch
	curBytes := 0
	const envelope = len(`{"mutations":[]}`)
	for _, r := range rows {
		if r.Action == "skip" {
			continue
		}
		rowBytes := 0
		for _, m := range r.mutations {
			rowBytes += len(m) + 1 // +1 for the separating comma
		}
		if envelope+rowBytes > maxBytes {
			return nil, fmt.Errorf("the document on line %d (%s) needs %d bytes, over the %d-byte request cap; raise --batch-bytes if the server allows it",
				r.Line, r.ID, envelope+rowBytes, maxBytes)
		}
		if len(cur.rows) > 0 && (cur.mutations+len(r.mutations) > importMaxMutations || curBytes+rowBytes > maxBytes) {
			batches = append(batches, cur)
			cur = importBatch{}
			curBytes = 0
		}
		if curBytes == 0 {
			curBytes = envelope
		}
		cur.rows = append(cur.rows, r)
		cur.mutations += len(r.mutations)
		curBytes += rowBytes
	}
	if len(cur.rows) > 0 {
		batches = append(batches, cur)
	}
	for k := range batches {
		batches[k].body = importBatchBody(batches[k].rows)
		if len(batches[k].body) > maxBytes {
			return nil, fmt.Errorf("batch %d is %d bytes, over the %d-byte cap", k+1, len(batches[k].body), maxBytes)
		}
	}
	return batches, nil
}

func importBatchBody(rows []*importRow) []byte {
	var buf bytes.Buffer
	buf.WriteString(`{"mutations":[`)
	n := 0
	write := func(m []byte) {
		if n > 0 {
			buf.WriteByte(',')
		}
		buf.Write(m)
		n++
	}
	// Published rows' createOrReplace, then their publishes, then the draft
	// rows. A draft row's createOrReplace must come AFTER the publishes: it
	// writes drafts.<id>, and a publish of <id> later in the same batch would
	// promote that draft's content over the published row.
	for _, r := range rows {
		if !r.Draft {
			write(r.mutations[0])
		}
	}
	for _, r := range rows {
		for _, m := range r.mutations[1:] {
			write(m)
		}
	}
	for _, r := range rows {
		if r.Draft {
			write(r.mutations[0])
		}
	}
	buf.WriteString(`]}`)
	return buf.Bytes()
}

// importWriteBatch sends one batch. It reports failed=true with the exit code
// when the batch was not confirmed: a transport error, a non-2xx answer, a
// receipt the write screen refuses, or a results array shorter than the
// mutations sent. The server applies one request in one transaction, so a
// refused batch applied nothing.
func importWriteBatch(out *writer, u string, ctx manifest.Context, b importBatch) (int, bool) {
	headers := ctxAuthHeaders(ctx)
	headers["Content-Type"] = "application/json"
	status, respBody, err := doRequest("POST", u, headers, b.body)
	if err != nil {
		useError(out, "request_failed", fmt.Sprintf("import: request failed: %v. The server may or may not have applied this batch; if it did, the resume needs --overwrite.", err), exitGeneric)
		return exitGeneric, true
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		renderError(out, ae)
		return ae.exit, true
	}
	if rc, handled := screenBuiltinWriteReceipt(out, "import mutate", status, respBody); handled {
		if rc == exitOK {
			rc = exitGeneric
		}
		return rc, true
	}
	written, werr := migrateBatchWritten(respBody)
	if werr != nil {
		useError(out, "unreadable_write_receipt", "import: "+werr.Error(), exitGeneric)
		return exitGeneric, true
	}
	if written != b.mutations {
		useError(out, "unreadable_write_receipt",
			fmt.Sprintf("import: the server confirmed %d of %d mutations in this batch", written, b.mutations), exitGeneric)
		return exitGeneric, true
	}
	return exitOK, false
}

func importActionCounts(rows []*importRow) map[string]int {
	counts := map[string]int{"create": 0, "overwrite": 0, "skip": 0}
	for _, r := range rows {
		counts[r.Action]++
	}
	return counts
}

// importRenderPlan prints the dry-run report: one row per document in apply
// order, with what a real run would do to it.
func importRenderPlan(out *writer, path, scope string, rows []*importRow, batches int, refusedIDs []string) {
	counts := importActionCounts(rows)
	docs := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		docs = append(docs, map[string]any{"line": r.Line, "id": r.ID, "type": r.Type, "draft": r.Draft, "action": r.Action})
	}
	payload := map[string]any{
		"ok": true, "file": path, "scope": scope, "dry_run": true,
		"batches": batches, "counts": counts, "documents": docs,
	}
	if len(refusedIDs) > 0 {
		payload["refused_ids"] = refusedIDs
	}
	if out.emitStructured(payload) {
		return
	}
	out.outf("dry run: importing %s into %s. Nothing was written.", path, scope)
	for _, r := range rows {
		state := "published"
		if r.Draft {
			state = "draft"
		}
		out.outf("  %-9s line %-6d %-9s %s (%s)", r.Action, r.Line, state, r.ID, r.Type)
	}
	out.outf("%d to create, %d to overwrite, %d to skip, in %d batch(es)",
		counts["create"], counts["overwrite"], counts["skip"], batches)
	if len(refusedIDs) > 0 {
		out.outf("a real run would be refused: %d document(s) already exist: %s. Add --overwrite to replace them.",
			len(refusedIDs), strings.Join(refusedIDs, ", "))
	}
}

// usageImport prints the import help. An explicit --help goes to stdout; the
// error paths keep it on stderr.
func usageImport(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp import <file.ndjson> [--dry-run] [--overwrite] [--from-line N] [--batch-bytes N] [--yes]")
	p("")
	p("Restore a `bp export` NDJSON backup into the active dataset (set it with -d).")
	p("")
	p("A published row (no `drafts.` prefix) becomes createOrReplace + publish. A draft")
	p("row (`drafts.<id>`) becomes createOrReplace on that draft id and stays a draft.")
	p("Published rows are applied first, so a draft lands on top of its published twin.")
	p("The server-owned keys _rev, _draft, _publishedId, _createdAt and _updatedAt are")
	p("dropped. When <file>.meta exists, the file must match it or nothing is written.")
	p("")
	p("flags:")
	p("  --dry-run          report per document whether it would be created, overwritten")
	p("                     or skipped, and write nothing")
	p("  --overwrite        replace documents that already exist in the target. Without it")
	p("                     the import refuses and names the ids that exist")
	p("  --from-line N      resume a failed import: skip every row applied before the row")
	p("                     on line N. A failed batch prints the line to resume from")
	p("  --batch-bytes N    request body cap (default 30000000, the server default for")
	p("                     /v1/data). Lower it for a server with a smaller document cap")
	p("  --yes              skip the confirmation for a production target")
	p("")
	p("A batch holds at most 1000 mutations and is applied by the server as one")
	p("transaction, so a refused batch applies nothing from that batch.")
	p("")
	p("  bp import backup.ndjson --dry-run")
	p("  bp import backup.ndjson")
}
