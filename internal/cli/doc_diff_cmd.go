package cli

// doc_diff_cmd.go is `bp doc diff <type> <id>`: what would publishing change?
//
//   - no flag            the draft compared to the published document
//   - --rev R            revision R compared to the current document
//   - --from A --to B    revision A compared to revision B
//
// It reads through the same routes as `bp doc get` and `bp doc revision` and
// writes nothing. The comparison is internal/docdiff, which the TUI's diff
// view also uses.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/docdiff"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// exitDocDiff is what `bp doc diff` returns when the two sides differ, the
// same code `bp schema diff` uses.
const exitDocDiff = exitGeneric

// docDiffNoise is what the server adds to every document it sends
// (Barkpark.Content.Envelope @reserved). A draft and its published twin always
// differ in these, so they are never part of the comparison.
var docDiffNoise = []string{"_id", "_type", "_rev", "_draft", "_publishedId", "_createdAt", "_updatedAt"}

func printDocDiffHelp(out *writer) {
	out.outf("usage: bp doc diff <type> <id> [--rev <revision>] [--from <revision> --to <revision>] [-o table|json|yaml]")
	out.outf("")
	out.outf("Shows what publishing would change: the draft of the document compared to")
	out.outf("its published version, field by field. A nested field is named by its path")
	out.outf("(seo.title, blocks[2].text). Array rows that carry a _key are matched by")
	out.outf("that key, so a row that moved is one reordered array, not a change to")
	out.outf("every row. A long text shows only the lines that differ. Nothing is written.")
	out.outf("")
	out.outf("A document with no draft prints \"no draft; nothing to publish\" and exits 0.")
	out.outf("A draft that was never published shows every field as added.")
	out.outf("The id, revision and timestamps the server sets are not compared.")
	out.outf("")
	out.outf("The credential must be able to read drafts. A token that may only read")
	out.outf("published documents (public-read, the default of `bp token create`), or")
	out.outf("no token at all, is refused with exit 3; it is never told there is no")
	out.outf("draft. A field the credential may not read is not compared.")
	out.outf("")
	out.outf("flags:")
	out.outf("  --rev <revision>   compare that revision to the current document (the draft")
	out.outf("                     when there is one, otherwise the published version)")
	out.outf("  --from <revision>  compare two revisions of the document; needs --to")
	out.outf("  --to <revision>")
	out.outf("  -o json            path, kind (added, removed, changed, moved), before and")
	out.outf("                     after for every difference; draft and published say")
	out.outf("                     which rows exist, or null when the mode did not look")
	out.outf("")
	out.outf("Revision ids come from `bp doc history <type> <id>`.")
	out.outf("")
	out.outf("exit codes: 0 when the two sides are the same, 1 when they differ. A")
	out.outf("request the server refuses exits with that refusal's own code (3 for a")
	out.outf("credential, 4 for a document or revision that does not exist). Use it as")
	out.outf("a CI check.")
	out.outf("")
	out.outf("example:")
	out.outf("  bp doc diff post hello-world")
}

type docDiffArgs struct {
	typ, id       string
	rev, from, to string
}

func parseDocDiffArgs(tail []string) (docDiffArgs, error) {
	var a docDiffArgs
	var pos []string
	for i := 0; i < len(tail); {
		key, inline, hasInline := splitFlagToken(tail[i])
		var dst *string
		switch key {
		case "--rev":
			dst = &a.rev
		case "--from":
			dst = &a.from
		case "--to":
			dst = &a.to
		default:
			if strings.HasPrefix(key, "-") && key != "-" {
				return a, fmt.Errorf("unknown flag %s", key)
			}
			pos = append(pos, tail[i])
			i++
			continue
		}
		v, ni, err := flagValue(tail, i, inline, hasInline, key)
		if err != nil {
			return a, err
		}
		if v == "" {
			return a, fmt.Errorf("flag %s needs a value", key)
		}
		*dst, i = v, ni
	}
	if len(pos) != 2 {
		return a, fmt.Errorf("name the document type and the document id")
	}
	a.typ, a.id = pos[0], strings.TrimPrefix(pos[1], "drafts.")
	switch {
	case (a.from == "") != (a.to == ""):
		return a, fmt.Errorf("--from and --to go together")
	case a.rev != "" && a.from != "":
		return a, fmt.Errorf("use --rev, or --from with --to, not both")
	}
	return a, nil
}

// docDiffSide is one side of the comparison: what it is called, and its
// fields with the server's own keys removed.
type docDiffSide struct {
	label  string
	fields map[string]any
}

// docDiffGet reads one JSON object from a scoped /v1/ path. found is false on
// a 404. Any other answer that is not a 2xx comes back as an exit code, after
// the error has been printed.
func docDiffGet(out *writer, ctx manifest.Context, suffix string) (obj map[string]any, found bool, code int) {
	status, body, err := doRequest("GET", ctxScopedURL(ctx, suffix), ctxAuthHeaders(ctx), nil)
	if err != nil {
		return nil, false, useError(out, "request_failed", fmt.Sprintf("doc diff: the request failed: %v", err), exitGeneric)
	}
	if status == 404 {
		return nil, false, exitOK
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, body)
		exit := ae.exit
		if exit == exitOK || exit == exitDocDiff {
			// 1 means "the two sides differ" here, so a refusal with no
			// code of its own is reported as a server error.
			exit = exitServer
		}
		return nil, false, useError(out, ae.code, "doc diff: "+ae.errorMessage(), exit)
	}
	obj, derr := docdiff.Decode(body)
	if derr != nil {
		return nil, false, useError(out, "failed", fmt.Sprintf("doc diff: the server's answer did not parse: %v", derr), exitServer)
	}
	return obj, true, exitOK
}

func docDiffDataset(ctx manifest.Context) string {
	if ctx.Dataset == "" {
		return "production"
	}
	return ctx.Dataset
}

// docDiffDoc reads a document by its exact id, or with perspective "drafts"
// the draft when there is one and the published version otherwise.
func docDiffDoc(out *writer, ctx manifest.Context, typ, id, perspective string) (fields map[string]any, isDraft, found bool, code int) {
	suffix := "/v1/data/doc/" + url.PathEscape(docDiffDataset(ctx)) + "/" + url.PathEscape(typ) + "/" + url.PathEscape(id)
	if perspective != "" {
		suffix += "?perspective=" + url.QueryEscape(perspective)
	}
	obj, found, code := docDiffGet(out, ctx, suffix)
	if code != exitOK || !found {
		return nil, false, found, code
	}
	// The document comes inside {"result": {...}}; an older shape sends it bare.
	if inner, ok := obj["result"].(map[string]any); ok {
		obj = inner
	}
	isDraft, _ = obj["_draft"].(bool)
	for _, k := range docDiffNoise {
		delete(obj, k)
	}
	return obj, isDraft, true, exitOK
}

// docDiffRevision reads one revision and checks it belongs to the document.
func docDiffRevision(out *writer, ctx manifest.Context, a docDiffArgs, rev string) (docDiffSide, int) {
	obj, found, code := docDiffGet(out, ctx, "/v1/data/revision/"+url.PathEscape(docDiffDataset(ctx))+"/"+url.PathEscape(rev))
	if code != exitOK {
		return docDiffSide{}, code
	}
	r, _ := obj["revision"].(map[string]any)
	if !found || r == nil {
		return docDiffSide{}, useError(out, "not_found", fmt.Sprintf("doc diff: there is no revision %s. `bp doc history %s %s` lists the revisions.", rev, a.typ, a.id), exitNotFound)
	}
	docID, _ := r["doc_id"].(string)
	typ, _ := r["type"].(string)
	if strings.TrimPrefix(docID, "drafts.") != a.id || typ != a.typ {
		return docDiffSide{}, useError(out, "validation_failed", fmt.Sprintf("doc diff: revision %s belongs to %s %s, not to %s %s.", rev, typ, docID, a.typ, a.id), exitValidation)
	}
	fields, _ := r["content"].(map[string]any)
	if fields == nil {
		fields = map[string]any{}
	}
	for _, k := range docDiffNoise {
		delete(fields, k)
	}
	// A document sends its title as a field. A revision keeps it beside the
	// content when the content has none.
	if _, ok := fields["title"]; !ok {
		if t, _ := r["title"].(string); t != "" {
			fields["title"] = t
		}
	}
	return docDiffSide{label: "revision " + rev, fields: fields}, exitOK
}

// runDocDiff is `bp doc diff <type> <id>`.
func runDocDiff(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printDocDiffHelp(out)
		return exitOK
	}
	a, err := parseDocDiffArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printDocDiffHelp(out) }, "doc diff: %v", err)
	}

	var before, after docDiffSide
	var extra map[string]any
	var code int
	switch {
	case a.from != "":
		if before, code = docDiffRevision(out, ctx, a, a.from); code != exitOK {
			return code
		}
		if after, code = docDiffRevision(out, ctx, a, a.to); code != exitOK {
			return code
		}
	case a.rev != "":
		if before, code = docDiffRevision(out, ctx, a, a.rev); code != exitOK {
			return code
		}
		fields, isDraft, found, code := docDiffDoc(out, ctx, a.typ, a.id, "drafts")
		if code != exitOK {
			return code
		}
		if !found {
			return useError(out, "not_found", fmt.Sprintf("doc diff: there is no %s document %s.", a.typ, a.id), exitNotFound)
		}
		after = docDiffSide{label: "published", fields: fields}
		if isDraft {
			after.label = "draft"
		}
		extra = map[string]any{"draft": isDraft}
	default:
		// The draft is read with perspective=raw: a credential that may only
		// read published documents is refused there. The default perspective
		// answers such a credential 404 on every drafts. id, which reads as
		// "no draft" when there is one.
		draft, _, hasDraft, code := docDiffDoc(out, ctx, a.typ, "drafts."+a.id, "raw")
		if code != exitOK {
			return code
		}
		if !hasDraft {
			// A 404 on the draft is only "no draft" from a credential that
			// could have seen one. A caller with no token is pinned to
			// published too, and the raw read above does not refuse it. The
			// history read refuses both (401 without a token, 403 for
			// public-read), so it is asked before anything is concluded.
			_, ok, code := docDiffGet(out, ctx, "/v1/data/history/"+url.PathEscape(docDiffDataset(ctx))+"/"+url.PathEscape(a.typ)+"/"+url.PathEscape(a.id)+"?limit=1")
			if code != exitOK {
				return code
			}
			if !ok {
				return useError(out, "not_found", fmt.Sprintf("doc diff: there is no %s document %s.", a.typ, a.id), exitNotFound)
			}
		}
		// The published side is read by its exact id with NO perspective. A
		// raw read of a plain id falls back to the draft when there is no
		// published row (QueryController tries the id, then its drafts. twin),
		// and the draft would then be compared with itself: a document that
		// was never published read as "the same", exit 0. An answer that says
		// it is a draft is not a published row, whatever door sent it.
		pub, pubIsDraft, hasPub, code := docDiffDoc(out, ctx, a.typ, a.id, "")
		if code != exitOK {
			return code
		}
		if pubIsDraft {
			pub, hasPub = nil, false
		}
		switch {
		case !hasDraft && !hasPub:
			return useError(out, "not_found", fmt.Sprintf("doc diff: there is no %s document %s.", a.typ, a.id), exitNotFound)
		case !hasDraft:
			if !out.emitStructured(docDiffPayload(a, "published", "draft", nil, map[string]any{"draft": false, "published": true})) {
				out.outf("no draft; nothing to publish")
			}
			return exitOK
		case !hasPub:
			before = docDiffSide{label: "published", fields: map[string]any{}}
		default:
			before = docDiffSide{label: "published", fields: pub}
		}
		after = docDiffSide{label: "draft", fields: draft}
		changes := docdiff.Diff(before.fields, after.fields)
		note := ""
		if !hasPub {
			note = "never published: every field is new"
		}
		return renderDocDiff(out, a, before.label, after.label, changes, map[string]any{"draft": true, "published": hasPub}, note)
	}
	return renderDocDiff(out, a, before.label, after.label, docdiff.Diff(before.fields, after.fields), extra, "")
}

func docDiffPayload(a docDiffArgs, before, after string, changes []docdiff.Change, extra map[string]any) map[string]any {
	if changes == nil {
		changes = []docdiff.Change{}
	}
	// draft and published say whether the document has each row. They are
	// null when the mode did not look: a comparison of revisions reads neither.
	payload := map[string]any{
		"draft":       nil,
		"published":   nil,
		"type":        a.typ,
		"id":          a.id,
		"before":      before,
		"after":       after,
		"differences": len(changes) > 0,
		"summary":     toGeneric(docdiff.Count(changes)),
		"changes":     docDiffChangesJSON(changes),
	}
	for k, v := range extra {
		payload[k] = v
	}
	return payload
}

// docDiffChangesJSON turns the changes into plain maps and lists, the shape
// both the JSON and the YAML printer take. Numbers stay as the server wrote
// them.
func docDiffChangesJSON(changes []docdiff.Change) any {
	b, _ := json.Marshal(changes)
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	_ = dec.Decode(&v)
	return v
}

var docDiffColors = map[byte]string{'-': "\x1b[31m", '+': "\x1b[32m", '~': "\x1b[33m"}

func renderDocDiff(out *writer, a docDiffArgs, before, after string, changes []docdiff.Change, extra map[string]any, note string) int {
	exit := exitOK
	if len(changes) > 0 {
		exit = exitDocDiff
	}
	if out.emitStructured(docDiffPayload(a, before, after, changes, extra)) {
		return exit
	}
	out.outf("%s %s: %s compared to %s", a.typ, a.id, after, before)
	if note != "" {
		out.outf("%s", note)
	}
	for _, row := range docdiff.Render(changes) {
		line := row.Format()
		if c := docDiffColors[row.Sign]; c != "" && out.color {
			line = c + line + "\x1b[0m"
		}
		out.outf("%s", line)
	}
	if len(changes) == 0 {
		out.outf("%s and %s are the same", after, before)
	}
	out.outf("%s", docdiff.Summary(changes))
	return exit
}
