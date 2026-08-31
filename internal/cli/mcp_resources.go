package cli

// mcp_resources.go — published Barkpark Papers exposed as MCP *resources* over
// the same `bp mcp serve` stdio server (charter wave 2). Where the curated task
// tools (mcp_tasks.go) let an MCP client ACT on the queue, resources let it READ
// Barkpark content: a Cursor/Claude-Desktop user browses the published papers as
// first-class resources and pulls any one into context by URI.
//
// Two registrations, one shared read handler (SDK facts, go-sdk v1.6.1):
//
//   - resources/list is STATIC — it enumerates only the concrete AddResource
//     entries; there is no dynamic list callback. So at startup we enumerate the
//     published papers once (doc.ls type=paper) and AddResource each, so the
//     client can BROWSE them (barkpark://papers/<_id>, titled from the paper's
//     first level-1 heading).
//   - resources/templates/list surfaces AddResourceTemplate entries. One template
//     barkpark://papers/{id} is registered so a paper CREATED after startup (not
//     in the concrete list) still READS lazily — readResource matches a concrete
//     resource first, then falls through to the template.
//
// Both the concrete resources and the template share ONE handler that reads a
// paper by id through the dispatch seam (doc.get type=paper --perspective
// published via execManifestCommand, run.go) and returns the RAW response JSON
// as a single resource content — no re-render (charter decision 9 extends to
// resources: the server is the one renderer).
//
// Startup enumeration is BEST-EFFORT and that is load-bearing: an MCP client
// launches the server as a subprocess and expects it ready on the pipe. If the
// API is unreachable at boot (e.g. the smoke gate points BARKPARK_API_URL at a
// dead port), enumeration must WARN on stderr and continue template-only — never
// fatal, never a byte on stdout (that pipe is the JSON-RPC protocol stream).

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// paperResourceScheme is the URI prefix every paper resource carries:
// barkpark://papers/<id>. paperResourceTemplate is its RFC 6570 template form.
const (
	paperResourceScheme   = "barkpark://papers/"
	paperResourceTemplate = "barkpark://papers/{id}"
	paperResourceMIME     = "application/json"
)

// registerPaperResources wires published papers onto srv as MCP resources. It is
// wholly BEST-EFFORT: it registers the read template (so any paper reads lazily),
// then tries to enumerate the published papers for resources/list — but any
// enumeration failure (unreachable API, missing doc.ls, malformed body) degrades
// to template-only with a single stderr warning and NEVER fails server startup.
// Reads are backed by doc.get, so if the manifest has no doc.get verb at all,
// there is nothing to back a paper read: it warns and registers nothing.
//
// out is used ONLY for stderr diagnostics (out.errf) — this code writes nothing
// to stdout, preserving the sacred JSON-RPC stream.
func registerPaperResources(out *writer, srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest) {
	tree := m.Tree()

	getCmd, ok := tree.Lookup("doc", "get")
	if !ok {
		// No doc.get → no way to back a paper read. Resources would 404 every read,
		// so expose none. Not fatal: the task tools are the point of the server.
		out.errf("mcp serve: paper resources disabled — manifest has no doc.get verb")
		return
	}

	// The shared read handler for BOTH the concrete resources and the template.
	// It resolves the paper id from the requested URI and reads it through the
	// seam; an unreadable id (HTTP >= 400) becomes a resource error the SDK maps
	// onto the resources/read response.
	readHandler := func(_ context.Context, req *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
		uri := ""
		if req != nil && req.Params != nil {
			uri = req.Params.URI
		}
		id := paperIDFromURI(uri)
		if id == "" {
			return nil, mcp.ResourceNotFoundError(uri)
		}
		return readPaperResource(g, ctx, m, *getCmd, uri, id)
	}

	// The template is ALWAYS registered (given doc.get): it is what lets a paper
	// created after startup still read, and it is the one resource surface that
	// survives an unreachable-at-boot API.
	srv.AddResourceTemplate(&mcp.ResourceTemplate{
		Name:        "paper",
		Title:       "Barkpark paper",
		Description: "A published Barkpark paper (Bulldocs document) as raw JSON. Read barkpark://papers/<id> for any published paper by its id — including papers created after the server started, which resources/list may not yet enumerate.",
		MIMEType:    paperResourceMIME,
		URITemplate: paperResourceTemplate,
	}, readHandler)

	// Best-effort enumeration for resources/list (static in the SDK). doc.ls is
	// the query endpoint; on a manifest without it, stay template-only.
	lsCmd, ok := tree.Lookup("doc", "ls")
	if !ok {
		out.errf("mcp serve: paper resources: manifest has no doc.ls verb — template-only (papers read by id, not browsable)")
		return
	}

	papers, err := enumeratePublishedPapers(g, ctx, m, *lsCmd)
	if err != nil {
		// Load-bearing: enumeration is best-effort. Warn on stderr and continue —
		// the template still backs reads-by-id.
		out.errf("mcp serve: paper resources: could not enumerate published papers (%v) — template-only", err)
		return
	}

	for _, p := range papers {
		srv.AddResource(&mcp.Resource{
			Name:        p.ID,
			Title:       p.Title,
			Description: fmt.Sprintf("Published paper %q. Raw document JSON.", p.Title),
			MIMEType:    paperResourceMIME,
			URI:         paperResourceScheme + p.ID,
		}, readHandler)
	}
	out.errf("mcp serve: %d published paper(s) exposed as resources", len(papers))
}

// paperMeta is the sliver of a listed paper the resource registration needs: its
// id (the resource URI + the doc.get key) and a human title.
type paperMeta struct {
	ID    string
	Title string
}

// enumeratePublishedPapers lists the published papers via doc.ls through the
// dispatch seam and extracts each paper's id + title. It runs the SAME machinery
// `bp doc ls paper --perspective published` would (never a parallel HTTP path).
// A transport error or an HTTP >= 400 is returned as an error so the caller can
// degrade to template-only; a 2xx with a body it cannot parse is likewise an
// error. Individual malformed documents inside a good list are skipped, not
// fatal — a best-effort list of the papers that DID parse.
func enumeratePublishedPapers(g globals, ctx manifest.Context, m *manifest.Manifest, lsCmd manifest.Command) ([]paperMeta, error) {
	// Bound the page generously so more than the default page of papers list, but
	// keep it a single best-effort call (no --all loop). limit rides the
	// pagination globals exactly like `bp doc ls paper --limit N`.
	g.limit = 200
	g.limitSet = true

	tail := []string{"paper"}
	// Only ask for the published perspective if the command actually declares the
	// flag — splitArgs rejects an undeclared flag, and the query endpoint already
	// defaults to the published perspective, so this stays correct either way.
	if commandHasFlag(lsCmd, "perspective") {
		tail = append(tail, "--perspective", "published")
	}

	status, body, err := execManifestCommand(g, ctx, m, lsCmd, tail)
	if err != nil {
		return nil, err
	}
	if status >= 400 {
		return nil, fmt.Errorf("doc.ls paper returned HTTP %d", status)
	}
	return parsePaperList(body)
}

// parsePaperList extracts paper id + title from a doc.ls (query) response body.
// The query endpoint wraps its payload as {"result":{"documents":[…]}} (a
// filtered envelope); each document is a rendered doc carrying _id and, for a
// paper, content.blocks. The title is the first level-1 heading block's text,
// falling back to the id (charter: heading-derived title, _id fallback).
func parsePaperList(body []byte) ([]paperMeta, error) {
	var env struct {
		Result struct {
			Documents []json.RawMessage `json:"documents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("parse doc.ls response: %w", err)
	}

	out := make([]paperMeta, 0, len(env.Result.Documents))
	for _, raw := range env.Result.Documents {
		var doc paperDocShape
		if err := json.Unmarshal(raw, &doc); err != nil {
			continue // best-effort: skip a malformed document, keep the rest
		}
		if strings.TrimSpace(doc.ID) == "" {
			continue // a document without an id cannot be a resource URI
		}
		out = append(out, paperMeta{ID: doc.ID, Title: paperTitle(doc)})
	}
	return out, nil
}

// paperBlockShape is the sliver of a PortableDoc block the title derivation
// reads: type + level + text, enough to find the first level-1 heading.
type paperBlockShape struct {
	Type  string `json:"type"`
	Level int    `json:"level"`
	Text  string `json:"text"`
}

// paperDocShape is the minimal shape parsePaperList reads out of a rendered
// paper document: its _id and its blocks (for the level-1 heading title). The
// live query endpoint renders content fields FLAT on the document (top-level
// "blocks" — verified against guerrilla), while an unflattened doc nests them
// under "content"; read both so the title never silently degrades to the _id
// on one of the two shapes.
type paperDocShape struct {
	ID      string            `json:"_id"`
	Blocks  []paperBlockShape `json:"blocks"`
	Content struct {
		Blocks []paperBlockShape `json:"blocks"`
	} `json:"content"`
}

// paperTitle returns the paper's display title: the text of its first level-1
// heading block (top-level blocks first — the rendered shape — then
// content.blocks), or the _id when there is no such heading (charter fallback).
func paperTitle(doc paperDocShape) string {
	for _, blocks := range [][]paperBlockShape{doc.Blocks, doc.Content.Blocks} {
		for _, b := range blocks {
			if b.Type == "heading" && b.Level == 1 {
				if t := strings.TrimSpace(b.Text); t != "" {
					return t
				}
			}
		}
	}
	return doc.ID
}

// readPaperResource reads one paper by id through the seam (doc.get type=paper
// doc_id=<id> --perspective published) and returns its RAW response JSON as a
// single resource content — no re-render (charter decision 9). An HTTP >= 400 is
// turned into a resource error: a 404 into the SDK's ResourceNotFoundError (so an
// unknown id reads as "not found"), any other status into a plain error carrying
// the server's envelope. A STATED success (< 400) that carries no honest answer —
// an HTML proxy/login page, a non-JSON body, or an error envelope contradicting
// the 2xx — is likewise turned into an error rather than handed to the client as
// the paper's content: readPaperResource reuses run.go's unreadableReadBody (the
// SAME read discriminator mcpRunFor applies to a task_show/task_ready tool call)
// rather than re-deriving the predicate for resources.
func readPaperResource(g globals, ctx manifest.Context, m *manifest.Manifest, getCmd manifest.Command, uri, id string) (*mcp.ReadResourceResult, error) {
	tail := []string{"paper", id}
	if commandHasFlag(getCmd, "perspective") {
		tail = append(tail, "--perspective", "published")
	}

	status, body, err := execManifestCommand(g, ctx, m, getCmd, tail)
	if err != nil {
		return nil, fmt.Errorf("read paper %q: %w", id, err)
	}
	if status == 404 {
		return nil, mcp.ResourceNotFoundError(uri)
	}
	if status >= 400 {
		return nil, fmt.Errorf("read paper %q: HTTP %d: %s", id, status, strings.TrimSpace(string(body)))
	}
	if reason, contradiction := unreadableReadBody(body); reason != "" {
		hint := unreadableReadHint
		if contradiction {
			hint = unreadableReadContradictionHint
		}
		return nil, fmt.Errorf("read paper %q: unreadable read: HTTP %d %s (%d bytes): %s (%s)", id, status, reason, len(body), bodyPreview(body), hint)
	}
	return &mcp.ReadResourceResult{
		Contents: []*mcp.ResourceContents{{
			URI:      uri,
			MIMEType: paperResourceMIME,
			Text:     string(body),
		}},
	}, nil
}

// paperIDFromURI extracts the paper id from a barkpark://papers/<id> URI, for
// both a concrete-resource read and a template read (the SDK hands the handler
// the full concrete URI in both cases). Returns "" for anything that is not a
// paper URI or carries no id — the caller maps that to ResourceNotFoundError.
func paperIDFromURI(uri string) string {
	if !strings.HasPrefix(uri, paperResourceScheme) {
		return ""
	}
	return strings.Trim(strings.TrimPrefix(uri, paperResourceScheme), "/")
}

// commandHasFlag reports whether cmd declares a flag with the given name.
func commandHasFlag(cmd manifest.Command, name string) bool {
	for _, f := range cmd.Flags {
		if f.Name == name {
			return true
		}
	}
	return false
}
