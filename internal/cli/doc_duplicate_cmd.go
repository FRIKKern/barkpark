package cli

// doc_duplicate_cmd.go is `bp doc duplicate <type> <id>`: copy a document's
// content into a new draft and print the new id.
//
// There is no duplicate route on the server. Studio's Duplicate runs inside
// the LiveView; the TUI's `y` key sends a `create` mutation built by
// apiclient.DuplicateCreate. This verb sends the same mutation, built by the
// same function, through the same route `bp doc create` uses, so every guard
// on a create applies to the copy. A create is a draft: nothing is published.
//
// Studio does not offer Duplicate on a singleton type or on a type whose
// desk block says `authorCreatable: false` (DocActions.withheld_action_names).
// That rule is Studio's own and the mutate route does not check it, so this
// verb reads the schema and refuses the same two cases before it writes.

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

func printDocDuplicateHelp(out *writer) {
	out.outf("usage: bp doc duplicate <type> <id> [--id <new id>] [--title <title>] [--dry-run] [--yes] [-o table|json|yaml]")
	out.outf("")
	out.outf("Copies the content of a document into a new draft and prints the id of the")
	out.outf("copy. The draft of the document is copied when there is one, otherwise the")
	out.outf("published version. The copy is always a draft; publish it with")
	out.outf("`bp doc publish`. The title of the copy is the source title with \" (copy)\".")
	out.outf("")
	out.outf("Like Duplicate in Studio, it refuses a singleton type and a type whose")
	out.outf("schema says authorCreatable: false. A paper cannot be copied here; use Studio.")
	out.outf("")
	out.outf("flags:")
	out.outf("  --id <new id>    the id of the copy (default: the server assigns one);")
	out.outf("                   an id that is already taken is refused")
	out.outf("  --title <title>  the title of the copy")
	out.outf("  --dry-run        print the create that would be sent, and write nothing")
	out.outf("  --yes            skip the production confirmation")
	out.outf("")
	out.outf("example:")
	out.outf("  bp doc duplicate post hello-world --title \"Hello again\"")
}

type docDuplicateArgs struct {
	typ, id, newID, title string
}

func parseDocDuplicateArgs(tail []string) (docDuplicateArgs, error) {
	var a docDuplicateArgs
	var pos []string
	for i := 0; i < len(tail); {
		key, inline, hasInline := splitFlagToken(tail[i])
		var dst *string
		switch key {
		case "--id":
			dst = &a.newID
		case "--title":
			dst = &a.title
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
		if strings.TrimSpace(v) == "" {
			return a, fmt.Errorf("flag %s needs a value", key)
		}
		*dst, i = v, ni
	}
	if len(pos) != 2 {
		return a, fmt.Errorf("name the document type and the document id")
	}
	a.typ, a.id = pos[0], strings.TrimPrefix(pos[1], "drafts.")
	a.newID = strings.TrimPrefix(a.newID, "drafts.")
	return a, nil
}

// docDuplicateGet reads one JSON body from a scoped /v1/ path. A status that
// is not a 2xx is printed and comes back as its exit code; found is false on a
// 404 when notFoundOK lets the caller decide what a missing row means.
func docDuplicateGet(out *writer, ctx manifest.Context, suffix string, notFoundOK bool) (body []byte, found bool, code int) {
	status, body, err := doRequest("GET", ctxScopedURL(ctx, suffix), ctxAuthHeaders(ctx), nil)
	if err != nil {
		return nil, false, useError(out, "request_failed", fmt.Sprintf("doc duplicate: the request failed: %v. Nothing was written.", err), exitGeneric)
	}
	if status == 404 && notFoundOK {
		return nil, false, exitOK
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, body)
		return nil, false, useError(out, ae.code, "doc duplicate: "+ae.errorMessage()+". Nothing was written.", ae.exit)
	}
	return body, true, exitOK
}

// docDuplicateWithheld says why Studio would not offer Duplicate on a
// document of this schema, or "" when it would.
func docDuplicateWithheld(schemaBody []byte) string {
	var env struct {
		Schema struct {
			Singleton bool `json:"singleton"`
			Desk      struct {
				AuthorCreatable *bool `json:"authorCreatable"`
			} `json:"desk"`
		} `json:"schema"`
	}
	if json.Unmarshal(schemaBody, &env) != nil {
		return ""
	}
	switch {
	case env.Schema.Singleton:
		return "it is a singleton: there is one document of this type"
	case env.Schema.Desk.AuthorCreatable != nil && !*env.Schema.Desk.AuthorCreatable:
		return "its schema says authorCreatable: false"
	}
	return ""
}

// runDocDuplicate is `bp doc duplicate <type> <id>`.
func runDocDuplicate(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printDocDuplicateHelp(out)
		return exitOK
	}
	// Like the manifest's write verbs, a pipe gets the short receipt (the new
	// id) unless -o asks for json or yaml.
	out.resolveOutputForCommand(g, "minimal")
	a, err := parseDocDuplicateArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printDocDuplicateHelp(out) }, "doc duplicate: %v", err)
	}
	dataset := docDiffDataset(ctx)

	// 1. The rule Studio follows. A type with no schema in this dataset is
	// left to the server to judge.
	schemaBody, found, code := docDuplicateGet(out, ctx, "/v1/schemas/"+url.PathEscape(dataset)+"/"+url.PathEscape(a.typ), true)
	if code != exitOK {
		return code
	}
	if found {
		if why := docDuplicateWithheld(schemaBody); why != "" {
			return useError(out, "duplicate_withheld", fmt.Sprintf("doc duplicate: a %s document cannot be duplicated: %s. Nothing was written.", a.typ, why), exitValidation)
		}
	}

	// 2. The source: the draft when there is one, otherwise the published
	// version.
	docBody, found, code := docDuplicateGet(out, ctx, "/v1/data/doc/"+url.PathEscape(dataset)+"/"+url.PathEscape(a.typ)+"/"+url.PathEscape(a.id)+"?perspective=drafts", true)
	if code != exitOK {
		return code
	}
	if !found {
		return useError(out, "not_found", fmt.Sprintf("doc duplicate: there is no %s document %s. Nothing was written.", a.typ, a.id), exitNotFound)
	}
	var wrapped struct {
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal(docBody, &wrapped) == nil && strings.HasPrefix(strings.TrimSpace(string(wrapped.Result)), "{") {
		docBody = wrapped.Result
	}
	var src apiclient.Doc
	if err := json.Unmarshal(docBody, &src); err != nil {
		return useError(out, "failed", fmt.Sprintf("doc duplicate: the document did not parse: %v. Nothing was written.", err), exitGeneric)
	}
	newID := a.newID
	if newID != "" {
		newID = "drafts." + newID
	}
	create, err := apiclient.DuplicateCreate(a.typ, src, apiclient.DuplicateOptions{ID: newID, Title: a.title})
	if err != nil {
		return useError(out, "validation_failed", fmt.Sprintf("doc duplicate: %v. Nothing was written.", err), exitValidation)
	}
	reqBody, err := json.Marshal(map[string]any{"mutations": []any{map[string]any{"create": create}}})
	if err != nil {
		return useError(out, "failed", fmt.Sprintf("doc duplicate: %v. Nothing was written.", err), exitGeneric)
	}
	u := ctxScopedURL(ctx, "/v1/data/mutate/"+url.PathEscape(dataset))
	headers := ctxAuthHeaders(ctx)
	headers["Content-Type"] = "application/json"

	// The one write of this verb. --dry-run prints it and stops.
	const method = "POST"
	if g.dryRun {
		return dryRun(out, manifest.Command{Noun: "doc", Verb: "duplicate", HTTP: manifest.HTTP{Method: method}}, u, headers, reqBody)
	}
	if isProd(ctx, &manifest.Manifest{}) && !g.yes && !serverDeclaredNonProd(ctx.Server) {
		if !confirmProdWrite(out, manifest.Command{Noun: "doc", Verb: "duplicate"}, ctx) {
			out.errf("aborted: prod write not confirmed")
			return exitUsage
		}
	}

	status, respBody, err := doRequest(method, u, headers, reqBody)
	if err != nil {
		return useError(out, "request_failed", fmt.Sprintf("doc duplicate: the request failed: %v. The copy may or may not have been made.", err), exitGeneric)
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		return useError(out, ae.code, "doc duplicate: "+ae.errorMessage()+". No copy was made.", ae.exit)
	}
	if code, done := screenBuiltinWriteReceipt(out, "doc duplicate", status, respBody); done {
		return code
	}
	var receipt struct {
		Results []struct {
			ID string `json:"id"`
		} `json:"results"`
	}
	if json.Unmarshal(respBody, &receipt) != nil || len(receipt.Results) == 0 || receipt.Results[0].ID == "" {
		return useError(out, "unreadable_write_receipt", "doc duplicate: the server accepted the request but named no new document. Check with `bp doc ls "+a.typ+" --perspective drafts` before you run it again.", exitGeneric)
	}
	id := receipt.Results[0].ID
	if !out.emitStructured(map[string]any{"id": id, "type": a.typ, "source": a.id, "draft": strings.HasPrefix(id, "drafts.")}) {
		// The id alone on stdout, so `new=$(bp doc duplicate …)` works.
		out.outf("%s", id)
		out.errf("copied %s %s to a new draft", a.typ, a.id)
	}
	return exitOK
}
