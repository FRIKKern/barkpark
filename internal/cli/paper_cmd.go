package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/mattn/go-isatty"
	"github.com/muesli/termenv"
	"golang.org/x/net/html"
	"golang.org/x/term"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// paper_cmd.go is `bp paper view <slug>` — a one-shot CLI render of a Bulldocs
// paper to the terminal, the headless counterpart to opening the paper in the
// browser (the HTML reader at /papers/:slug) or scrolling it in the TUI paper
// pane. It is a CLI-native BUILT-IN (dispatched from Execute, not the manifest
// tree) for the same reason `migrate` is: it composes a render pipeline
// (pdrender) the manifest's generic command runner knows nothing about, and it
// resolves the target server + scope through the saved-server config exactly
// like every other built-in.
//
// This command IS the deferred "-o ansi" render target — pdrender's M0–M2 work
// produced the renderer (internal/pdrender) and the TUI pane (paper.go); M3 is
// this finisher. Rendered terminal output is the default; `-o json` prints the
// raw paper document for piping/inspection.

// paperPerspectiveDefault is the read view a public paper is fetched under.
// Papers are public, so "published" is the floor; --perspective drafts|raw
// surfaces unpublished work (mirrors the TUI's drafts default, but the CLI
// keeps the public default unless asked).
const paperPerspectiveDefault = "published"

// paperWidthFallback is the column count used when stdout is NOT a TTY (piped or
// redirected) and no --width was given. 80 keeps `bp paper view x | less` and
// golden-style captures stable and narrow.
const paperWidthFallback = 80

// parsedPaperArgs holds the resolved `paper view` flags + the positional slug.
type parsedPaperArgs struct {
	slug          string
	theme         string // dark | light | auto   (default auto)
	perspective   string // published | drafts | raw (default published)
	width         int    // 0 = auto-detect
	widthSet      bool
	profile       string // auto | none | ansi256 | truecolor (default auto)
	server        string // -s/--server: a saved name or URL
	epicID        string
	waveID        string
	releaseGateID string
	revisionID    string
	candidateID   string
	paperRole     string
}

// runPaper is the `bp paper <verb> [args]` built-in entry. v1 ships exactly one
// verb — `view` — so any other verb is a clean usage error that prints the
// noun's help. A bare `bp paper` (no verb) prints usage and exits 2.
func runPaper(out *writer, g globals, args []string) int {
	// A bare `bp paper` (or `bp paper -h`) prints the noun usage. `-h` is consumed
	// by the global parser before we see it, so it surfaces as g.help with an
	// empty arg list — treat that as a help request (exit 0), not an error.
	if len(args) == 0 {
		usagePaper(out, g.help)
		if g.help {
			return exitOK
		}
		return exitUsage
	}
	verb := args[0]
	switch verb {
	case "view":
		// `bp paper view -h` strips -h into g.help; the only positional left may be
		// empty. Honour g.help as a clean help request for the view command.
		if g.help && len(args) == 1 {
			usagePaperView(out, true)
			return exitOK
		}
		return runPaperView(out, g, args[1:])
	case "capture":
		if g.help && len(args) == 1 {
			usagePaperCapture(out, true)
			return exitOK
		}
		return runPaperCapture(out, g, args[1:])
	// The BPML working copy (masterplan W3, paper_wc_cmd.go): read verbs above
	// render papers; these edit them as files under .barkpark/papers/. They
	// resolve the target context exactly like every other built-in.
	//
	// `new` (paper_new_cmd.go, charter D41) is the LOCAL scaffold half of the
	// one authoring door — no server call, so it takes globals only; the server
	// is met at push, whose sync endpoint creates an absent slug through the
	// full publish wall.
	case "new":
		if g.help && len(args) == 1 {
			usagePaperNew(out, true)
			return exitOK
		}
		return runPaperNew(out, g, args[1:])
	case "pull":
		return runPaperPull(out, g, resolveContext(g), args[1:])
	case "status":
		return runPaperStatus(out, g, resolveContext(g), args[1:])
	case "diff":
		return runPaperWCDiff(out, g, args[1:])
	case "push":
		return runPaperPush(out, g, resolveContext(g), args[1:])
	case "help":
		usagePaper(out, true)
		return exitOK
	default:
		out.userErr("unknown command %q %q", "paper", verb)
		usagePaper(out, false)
		return exitUsage
	}
}

// runPaperView fetches a paper by slug and renders it. args is everything after
// `paper view`, i.e. the slug plus paper-local flags.
func runPaperView(out *writer, g globals, args []string) int {
	// -h/--help anywhere wins over rendering (the global parser folds it into
	// g.help and strips it from args).
	if g.help {
		usagePaperView(out, true)
		return exitOK
	}
	opt, perr := parsePaperArgs(args)
	if perr != nil {
		out.userErr("%v", perr)
		usagePaperView(out, false)
		return exitUsage
	}
	if opt.slug == "" {
		out.userErr("paper view needs a <slug>")
		usagePaperView(out, false)
		return exitUsage
	}
	target := parsePaperRef(opt.slug)
	opt.slug = target.id
	suppressInheritedToken := false
	// A pasted Paper URL is a complete location, not merely an id. Make its
	// origin and tenant path authoritative so the CLI cannot silently read a
	// same-named Paper from the currently active server/workspace/project.
	if target.server != "" {
		if g.token == "" && !paperServerTrusted(target.server, resolveContext(g).Server) {
			suppressInheritedToken = true
		}
		g.server = target.server
	}
	if target.workspace != "" {
		g.workspace = target.workspace
	}
	if target.project != "" {
		g.project = target.project
	}
	if target.dataset != "" {
		g.dataset = target.dataset
	}

	// -o resolution: an explicit global -o/--json wins (the global parser already
	// reflected it into g/out.output); else ansi (this command's default — NOT the
	// tty-vs-pipe table/json default the manifest runner uses, because "render the
	// paper" is the whole point).
	output := "ansi"
	if g.outputSet {
		// The global layer only knows table|json|yaml|minimal; map json→json and
		// any non-json explicit output to ansi (the renderable form).
		if out.output == "json" {
			output = "json"
		} else {
			output = "ansi"
		}
	}
	jsonOut := output == "json"

	// Resolve the target server/token/scope EXACTLY like every other command:
	// flags (incl. -s) > env > saved active config > baked defaults. A paper-local
	// -s is folded onto the global server flag so resolveContext's saved-server
	// resolution (URL + carried token + scope) applies unchanged.
	if opt.server != "" && g.server == "" {
		g.server = opt.server
	}
	ctx := resolveContext(g)
	if suppressInheritedToken || target.share != "" {
		// Never attach an active/environment credential to an arbitrary pasted
		// origin or to a capability URL. Unknown origins require an explicit
		// --token; item-share URLs authenticate solely with their share token.
		ctx.Token = ""
	}

	// Perspective: papers are public → published by default; --perspective lets a
	// caller see drafts/raw. An empty/unknown value falls back to published.
	perspective := paperPerspectiveDefault
	switch opt.perspective {
	case "published", "drafts", "raw":
		perspective = opt.perspective
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: perspective,
		// A one-shot reader read gets a 30s budget, not the 5s apiclient
		// default: papers carrying live blocks (task-board/task-list/chart)
		// resolve their queries at render time, and the production dashboard
		// papers measure 10-14s steady-state under load (2026-08-23,
		// cloud-console-hardening-dashboard / block-wishlist-100 — the nightly
		// paper-reader audit's CLI edge failed BOTH while every curl edge, on
		// its 30s cap, passed). 30s matches fetchSharedPaper below and the
		// audit's BP_AUDIT_MAX_TIME; the server's own slowness stays a filed
		// defect, but a reader command must outlast a slow render, not error.
		Timeout: 30 * time.Second,
	})
	releaseRef, pinned, pinErr := releasePaperRef(opt)
	if pinErr != nil {
		return paperError(out, jsonOut, "invalid_release_pin", pinErr.Error(), exitUsage)
	}
	if pinned && target.share != "" {
		return paperError(out, jsonOut, "invalid_release_pin", "release-pinned Paper reads cannot use a mutable share URL", exitUsage)
	}

	// A Paper link already names canonical document identity. Read its narrow,
	// fail-closed source projection so the CLI cannot render a mixed blocks +
	// body_html document that the browser/email readers reject.
	var raw []byte
	var qerr error
	if pinned {
		var source apiclient.ReleasePaperSource
		source, qerr = client.PaperReleaseSource(releaseRef)
		if qerr == nil && source.DocID != opt.slug {
			qerr = fmt.Errorf("release Paper doc_id %q does not match requested slug %q", source.DocID, opt.slug)
		}
		if qerr == nil {
			if jsonOut {
				raw = source.Raw
			} else {
				raw, qerr = source.DocumentJSON(opt.slug)
			}
		}
	} else if target.share != "" {
		raw, qerr = fetchSharedPaper(ctx.Server, target)
	} else if jsonOut {
		// Machine output is a compatibility surface: preserve the complete raw
		// PaperDoc envelope consumers already parse. Only rendered output needs
		// the narrow canonical-source authority.
		raw, qerr = client.PaperDoc(ctx.Dataset, opt.slug, perspective)
	} else {
		var source apiclient.PaperSource
		source, qerr = client.PaperSource(ctx.Dataset, opt.slug, perspective)
		if qerr == nil {
			raw, qerr = source.DocumentJSON(opt.slug)
		}
	}
	if qerr != nil {
		return paperError(out, jsonOut, "not_found", fmt.Sprintf("read paper %q failed: %v", opt.slug, qerr), exitNotFound)
	}
	match := paperRawDoc{id: opt.slug, slug: opt.slug, raw: raw}

	// -o json: print the raw paper document verbatim (re-indented for stability).
	if jsonOut {
		out.renderRaw(raw)
		return exitOK
	}

	// Width is a property of every terminal representation, including the
	// legacy body_html adapter below. Resolve it before selecting the source
	// path so HTML-only Papers cannot bypass the same display boundary as blocks.
	stdoutTTY := isatty.IsTerminal(os.Stdout.Fd())
	width := paperResolveWidth(opt, stdoutTTY)

	// Decode the matched doc's block tree through the apiclient.Doc seam, then via
	// pdrender.Decode → []pdrender.Block.
	var doc apiclient.Doc
	if err := json.Unmarshal(raw, &doc); err != nil {
		return paperError(out, jsonOut, "decode", "decode paper: "+err.Error(), exitGeneric)
	}
	blocksRaw := doc.PaperBlocks()
	if len(blocksRaw) == 0 {
		// A paper with no block tree is NOT necessarily empty: some papers carry
		// only pre-rendered "body_html" (e.g. soc2-controls-mapping, 7.7 KB of
		// real content). Fall back to a plain-text dump of that HTML rather than
		// misreport the paper as having no content. Only when body_html is ALSO
		// empty is the paper genuinely blank.
		if text := htmlToPlainText(doc.BodyHTML); text != "" {
			out.outf("%s", wrapPaperPlainText(text, width))
			return exitOK
		}
		return paperError(out, jsonOut, "empty",
			fmt.Sprintf("paper %q has no renderable blocks", opt.slug), exitNotFound)
	}
	blocks, derr := pdrender.Decode(blocksRaw)
	if derr != nil {
		return paperError(out, jsonOut, "decode", "decode blocks: "+derr.Error(), exitGeneric)
	}

	// Resolve width + theme + profile from stdout's nature. The theme IDENTITY
	// (which emitted skin) comes from BP_THEME/config via ResolveThemeID; the
	// --theme flag (opt.theme) still selects the light/dark MODE this wave (D30).
	cfg, _ := LoadConfig() // missing/unreadable config → nil → env/default theme id
	theme := paperResolveTheme(opt.theme, ResolveThemeID(cfg))
	profile := paperResolveProfile(opt.profile, stdoutTTY)

	// Bind lipgloss's GLOBAL color profile to the resolved pdrender.Profile. This
	// is the piece that actually strips/keeps the SGR escapes the body/heading/
	// callout styles emit (pdrender.Profile alone gates only OSC-8 hyperlinks and
	// the chroma code formatter — lipgloss color output keys off the global
	// termenv profile). Without this, NoColor over a TTY would still emit color.
	// Deterministic and one-shot: the CLI process renders once and exits, so a
	// global mutation here is safe and gives `--profile` honest control.
	lipgloss.SetColorProfile(paperTermenvProfile(profile))

	rctx := pdrender.RenderCtx{
		Width:         width,
		Theme:         theme,
		Profile:       profile,
		RefResolver:   paperRefResolver(client, ctx.Dataset, perspective),
		TaskResolver:  paperTaskResolver(client, ctx.Dataset, perspective, []paperRawDoc{match}),
		ValueResolver: paperValueResolver(client, ctx.Dataset, perspective, blocksRaw),
		ImageResolver: paperImageResolver(ctx.Server, ctx.Token),
	}
	rendered := pdrender.DefaultRegistry(theme).RenderDoc(blocks, rctx)

	// Print verbatim — the renderer already guarantees no line exceeds Width
	// (chrome is dropped below MinWidth), so no post-processing that could break
	// that guarantee. outf adds the single trailing newline.
	out.outf("%s", rendered)

	// Append the Related section (weighted-tag + backlink affinity, ae-w10). A
	// SECONDARY read, FAIL-OPEN by contract: any transport error, non-2xx, or
	// empty result yields "" and the section simply does not appear — the paper
	// render above must never break on this new read. Skipped for the -o json /
	// share / release-pinned paths above (they return before here).
	if section := paperRenderRelated(client, ctx.Dataset, opt.slug, paperRelatedTopN, width); section != "" {
		out.outf("%s", section)
	}
	return exitOK
}

// paperRelatedTopN caps both the fetch limit and the rendered entry count of the
// Related section — the top matches are the only useful ones in a terminal.
const paperRelatedTopN = 5

// paperRelatedSharedTag is one shared-tag detail carried by a related entry: the
// tag NAME and the source/candidate strengths that scored the affinity.
type paperRelatedSharedTag struct {
	Tag          string `json:"tag"`
	SrcStrength  int    `json:"src_strength"`
	CandStrength int    `json:"cand_strength"`
}

// paperRelatedEntry mirrors ONE element of the GET /v1/data/related response's
// result.related array (query_controller.related → Content.Related.entry). Title
// is the documents.title COLUMN — empty for most weighted docs (a proven prod
// trap), so the renderer falls back to DocID.
type paperRelatedEntry struct {
	DocID      string                  `json:"doc_id"`
	Type       string                  `json:"type"`
	Title      string                  `json:"title"`
	Score      float64                 `json:"score"`
	Sources    []string                `json:"sources"`
	SharedTags []paperRelatedSharedTag `json:"shared_tags"`
}

// backlinkOnly reports whether an entry's provenance is inbound references ONLY
// (no shared-tag leg) — the "sources":["references"] degrade for a zero-tag or
// tag-mismatched neighbour. The renderer marks these so a reader knows the link
// is a backlink, not a tag affinity.
func (e paperRelatedEntry) backlinkOnly() bool {
	hasTags, hasRefs := false, false
	for _, s := range e.Sources {
		switch s {
		case "tags":
			hasTags = true
		case "references":
			hasRefs = true
		}
	}
	return hasRefs && !hasTags
}

// paperRenderRelated fetches GET /v1/data/related/:dataset/:id and renders the
// plain-text Related section (top paperRelatedTopN entries). It mirrors
// paperLoadTitles' secondary-read pattern exactly — paperScopedURL + doRequest +
// optional bearer, NO apiclient change. FAIL-OPEN: a nil client, empty id, any
// transport error, a non-2xx status (incl. the anon 404 existence-hiding), a
// decode failure, or an empty related list all yield "" so the caller prints
// nothing and the paper render is never broken by this read.
func paperRenderRelated(client *apiclient.Client, dataset, id string, limit, width int) string {
	id = strings.TrimSpace(id)
	if client == nil || dataset == "" || id == "" {
		return ""
	}
	u := paperScopedURL(client, "/v1/data/related/"+url.PathEscape(dataset)+"/"+url.PathEscape(id))
	if limit > 0 {
		u += "?limit=" + strconv.Itoa(limit)
	}
	headers := map[string]string{}
	if t := client.Token(); t != "" {
		headers["Authorization"] = "Bearer " + t
	}
	status, body, err := doRequest("GET", u, headers, nil)
	if err != nil || status < 200 || status >= 300 {
		return ""
	}
	var env struct {
		Result struct {
			Related []paperRelatedEntry `json:"related"`
		} `json:"result"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Result.Related) == 0 {
		return ""
	}
	return formatRelatedSection(env.Result.Related, width)
}

// formatRelatedSection renders up to paperRelatedTopN entries as a plain-text
// block: a leading blank line separates it from the paper body, then a "Related"
// heading, then one line per entry (score, title-or-id, type, backlink marker)
// with an indented shared-tags detail line. No SGR — plain text keeps piped and
// golden captures clean and honours a NoColor profile. Returns "" for no
// entries; the returned string carries NO trailing newline (outf adds it).
func formatRelatedSection(entries []paperRelatedEntry, width int) string {
	if len(entries) == 0 {
		return ""
	}
	if len(entries) > paperRelatedTopN {
		entries = entries[:paperRelatedTopN]
	}
	lines := []string{"", "Related"}
	for _, e := range entries {
		label := strings.TrimSpace(e.Title)
		if label == "" {
			label = e.DocID
		}
		typeSuffix := ""
		if e.Type != "" {
			typeSuffix = "  (" + e.Type + ")"
		}
		marker := ""
		if e.backlinkOnly() {
			marker = "  · backlink"
		}
		prefix := fmt.Sprintf("  %.2f  ", e.Score)
		lines = append(lines, wrapRelatedLine(prefix, label+typeSuffix+marker, width)...)
		if len(e.SharedTags) > 0 {
			parts := make([]string, 0, len(e.SharedTags))
			for _, t := range e.SharedTags {
				parts = append(parts, fmt.Sprintf("%s (%d·%d)", t.Tag, t.SrcStrength, t.CandStrength))
			}
			lines = append(lines, wrapRelatedLine("        tags: ", strings.Join(parts, ", "), width)...)
		}
	}
	return strings.Join(lines, "\n")
}

// wrapRelatedLine keeps the Related appendix under the same width contract as
// the PortableDoc body. Continuations align under the content, so a long title
// or tag list remains readable instead of becoming the only overflowing line
// in an otherwise valid 80-column render.
func wrapRelatedLine(prefix, content string, width int) []string {
	if width < 1 {
		width = 1
	}
	prefixWidth := ansi.StringWidth(prefix)
	if prefixWidth >= width {
		return strings.Split(wrapPaperPlainText(prefix+content, width), "\n")
	}
	wrapped := strings.Split(wrapPaperPlainText(content, width-prefixWidth), "\n")
	continuation := strings.Repeat(" ", prefixWidth)
	lines := make([]string, len(wrapped))
	for i, line := range wrapped {
		if i == 0 {
			lines[i] = prefix + line
			continue
		}
		lines[i] = continuation + line
	}
	return lines
}

// normalizePaperRef accepts the three forms users naturally paste into a
// terminal: a bare Paper id, a `/papers/<id>` path, or a full scoped/unscoped
// Paper URL. The public route segment is the stable boundary; query strings,
// fragments, and a trailing slash never become part of document identity.
type paperRef struct {
	id          string
	server      string
	workspace   string
	project     string
	dataset     string
	browserPath string
	share       string
}

func parsePaperRef(ref string) paperRef {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return paperRef{}
	}
	parsed, err := url.Parse(ref)
	if err != nil {
		return paperRef{id: ref}
	}
	path := parsed.Path
	if path == "" || (!strings.HasPrefix(ref, "/") && parsed.Scheme == "" && parsed.Host == "") {
		return paperRef{id: ref}
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	target := paperRef{browserPath: parsed.EscapedPath(), share: parsed.Query().Get("share")}
	if parsed.Scheme != "" && parsed.Host != "" {
		target.server = parsed.Scheme + "://" + parsed.Host
	}
	for i := 0; i+1 < len(parts); i++ {
		switch parts[i] {
		case "w":
			target.workspace, _ = url.PathUnescape(parts[i+1])
		case "p":
			target.project, _ = url.PathUnescape(parts[i+1])
		case "d":
			target.dataset, _ = url.PathUnescape(parts[i+1])
		}
	}
	for i := len(parts) - 2; i >= 0; i-- {
		if parts[i] == "papers" && parts[i+1] != "" {
			if id, unescapeErr := url.PathUnescape(parts[i+1]); unescapeErr == nil {
				target.id = id
				return completePaperRef(target)
			}
			target.id = parts[i+1]
			return completePaperRef(target)
		}
		if i > 0 && parts[i-1] == "studio" && parts[i] == "paper" && parts[i+1] != "" {
			if id, unescapeErr := url.PathUnescape(parts[i+1]); unescapeErr == nil {
				target.id = id
				return completePaperRef(target)
			}
			target.id = parts[i+1]
			return completePaperRef(target)
		}
	}
	target.id = ref
	return target
}

func completePaperRef(target paperRef) paperRef {
	if target.workspace == "" {
		target.workspace = "default"
	}
	if target.project == "" {
		target.project = "default"
	}
	if target.dataset == "" {
		target.dataset = "production"
	}
	return target
}

func paperServerTrusted(target, active string) bool {
	normalize := func(value string) string { return strings.TrimRight(value, "/") }
	if normalize(target) == normalize(active) {
		return true
	}
	if cfg, err := LoadConfig(); err == nil && cfg != nil {
		_, ok := cfg.FindServer(target)
		return ok
	}
	return false
}

func fetchSharedPaper(server string, target paperRef) ([]byte, error) {
	if target.browserPath == "" || target.share == "" {
		return nil, fmt.Errorf("invalid Paper share URL")
	}
	endpoint := strings.TrimRight(server, "/") + strings.TrimRight(target.browserPath, "/") +
		"/source?share=" + url.QueryEscape(target.share)
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "*/*")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Paper source status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, err
	}
	var payload struct {
		Title  string `json:"title"`
		Source struct {
			Kind   string          `json:"kind"`
			Blocks json.RawMessage `json:"blocks"`
			HTML   string          `json:"html"`
		} `json:"source"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, err
	}
	doc := map[string]any{"_id": target.id, "_type": "paper", "title": payload.Title}
	switch payload.Source.Kind {
	case "blocks":
		var blocks any
		if err := json.Unmarshal(payload.Source.Blocks, &blocks); err != nil {
			return nil, err
		}
		doc["blocks"] = blocks
	case "html":
		doc["body_html"] = payload.Source.HTML
	default:
		return nil, fmt.Errorf("Paper source is empty")
	}
	return json.Marshal(doc)
}

func normalizePaperRef(ref string) string { return parsePaperRef(ref).id }

// paperRawDoc is one fetched paper: its identity fields (for matching + the
// not-found list) and the verbatim JSON (for -o json and block decode).
type paperRawDoc struct {
	id    string
	slug  string
	title string
	raw   json.RawMessage
}

// paperFetchAll fetches every paper document via the RAW query body (so the real
// _id/slug/title survive). It mirrors the client's scoped URL + perspective and
// goes through doRequest like migrate does, because apiclient.Query loses the
// _id (the API emits "_id", Doc decodes "id"). Perspective is passed explicitly
// so the caller controls published vs drafts vs raw.
func paperFetchAll(client *apiclient.Client, perspective string) ([]paperRawDoc, error) {
	base := paperScopedURL(client, "/v1/data/query/"+url.PathEscape(client.Dataset)+"/paper")
	headers := map[string]string{}
	if t := client.Token(); t != "" {
		headers["Authorization"] = "Bearer " + t
	}

	// Page until a short page. The query endpoint defaults to limit=100 and
	// silently drops the rest, so an unbounded fetch capped the corpus at 100
	// docs — papers beyond that window (e.g. soc2-controls-mapping, dpa-template)
	// vanished and `bp paper view` reported "no paper matches" for papers that
	// exist. paperPageSize (1000) is the server's max clamp, so this loop drains
	// the whole corpus in as few round-trips as possible while staying correct
	// past 1000 papers. Mirrors migrateFetchAll's proven pagination.
	var out []paperRawDoc
	offset := 0
	for {
		params := url.Values{}
		if perspective != "" {
			params.Set("perspective", perspective)
		}
		// resolve=tasks (p-resolve-seam): the server swaps each task block's
		// authored `query` for a live `snapshot`/`task` before responding, so the
		// task widgets render live plans instead of "[task-list — unresolved]".
		// Read-only: paperFetchAll feeds the render path, never a write-back.
		params.Set("resolve", "tasks")
		params.Set("limit", strconv.Itoa(paperPageSize))
		params.Set("offset", strconv.Itoa(offset))
		u := base + "?" + params.Encode()

		status, body, err := doRequest("GET", u, headers, nil)
		if err != nil {
			return nil, err
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, body)
			return nil, fmt.Errorf("status %d: %s", status, ae.errorMessage())
		}

		var env struct {
			Result struct {
				Documents []json.RawMessage `json:"documents"`
			} `json:"result"`
			Documents []json.RawMessage `json:"documents"`
		}
		if jerr := json.Unmarshal(body, &env); jerr != nil {
			return nil, fmt.Errorf("parse query response: %w", jerr)
		}
		rawDocs := env.Result.Documents
		if rawDocs == nil {
			rawDocs = env.Documents
		}

		for _, r := range rawDocs {
			var ident struct {
				ID    string `json:"_id"`
				Slug  string `json:"slug"`
				Title string `json:"title"`
			}
			_ = json.Unmarshal(r, &ident)
			out = append(out, paperRawDoc{id: ident.ID, slug: ident.Slug, title: ident.Title, raw: r})
		}
		if len(rawDocs) < paperPageSize {
			break
		}
		offset += paperPageSize
	}
	return out, nil
}

// paperPageSize is the per-request page size for paperFetchAll. 1000 is the
// query endpoint's max limit clamp (see query_controller.ex), so it drains the
// corpus in the fewest round-trips while the loop still handles a >1000 corpus.
const paperPageSize = 1000

// paperScopedURL builds the workspace/project-scoped /v1/ URL for a paper read,
// mirroring apiclient.Client.scopedURL (which is unexported) so the built-in
// honours the same tenancy routing as the rest of the client.
func paperScopedURL(client *apiclient.Client, suffix string) string {
	return fmt.Sprintf("%s/w/%s/p/%s%s",
		strings.TrimRight(client.BaseURL(), "/"),
		url.PathEscape(client.Workspace),
		url.PathEscape(client.Project),
		suffix)
}

// paperMatch finds the paper whose _id or slug equals the requested slug
// (case-sensitive first, then case-insensitive as a courtesy). Returns the
// matched doc and ok=false when nothing matches.
func paperMatch(docs []paperRawDoc, slug string) (paperRawDoc, bool) {
	for _, d := range docs {
		if d.id == slug || (d.slug != "" && d.slug == slug) {
			return d, true
		}
	}
	for _, d := range docs {
		if strings.EqualFold(d.id, slug) || (d.slug != "" && strings.EqualFold(d.slug, slug)) {
			return d, true
		}
	}
	return paperRawDoc{}, false
}

// paperResolveWidth resolves the render width: an explicit --width wins; else the
// terminal width of stdout when it is a TTY (via term.GetSize); else the
// non-TTY fallback (80) so piped/redirected output is stable.
func paperResolveWidth(opt parsedPaperArgs, stdoutTTY bool) int {
	if opt.widthSet && opt.width > 0 {
		return opt.width
	}
	if stdoutTTY {
		if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
			return w
		}
	}
	return paperWidthFallback
}

// paperResolveTheme maps the --theme flag to a pdrender.Theme AND makes that
// choice authoritative over lipgloss's adaptive-color resolution.
//
// pdrender's DarkTheme/LightTheme build their palettes from lipgloss.Adaptive-
// Color values, which lipgloss resolves at render time against the DETECTED
// terminal background (via termenv), NOT against which preset was selected.
// Selecting DarkTheme() vs LightTheme() therefore produced byte-identical SGR
// output — `--theme` was a no-op. To make it real we force lipgloss's default-
// renderer background flag before rendering: dark → SetHasDarkBackground(true)
// (every AdaptiveColor resolves to its Dark side), light → false. This is the
// same one-shot global-mutation pattern as the SetColorProfile bridge below;
// the CLI renders once and exits, so a global set is safe. auto leaves
// detection untouched and just picks the preset via HasDarkBackground().
// themeID selects the emitted skin (pdrender.ThemeFor resolves it; unknown →
// evergreen); mode is the --theme flag value (light/dark/auto), still MODE this
// wave per D30. Identity and mode are the two orthogonal switches.
func paperResolveTheme(mode, themeID string) pdrender.Theme {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "light":
		lipgloss.SetHasDarkBackground(false)
		return pdrender.ThemeFor(themeID, "light")
	case "dark":
		lipgloss.SetHasDarkBackground(true)
		return pdrender.ThemeFor(themeID, "dark")
	default: // auto + unknown — don't force; honour the detected background
		if lipgloss.HasDarkBackground() {
			return pdrender.ThemeFor(themeID, "dark")
		}
		return pdrender.ThemeFor(themeID, "light")
	}
}

// paperResolveProfile maps the --profile flag to a pdrender.Profile. auto (the
// default) keys off stdout: a TTY uses a SAFE ANSI256 (faithful palette without
// the truecolor ANSI-bleed risk), TrueColor only when explicitly asked; a NON-
// TTY (piped/redirected) uses NoColor so `bp paper view x | less` and golden
// captures stay clean plain text.
func paperResolveProfile(profile string, stdoutTTY bool) pdrender.Profile {
	switch strings.ToLower(strings.TrimSpace(profile)) {
	case "none", "nocolor", "no-color", "plain":
		return pdrender.NoColor
	case "ansi16", "16":
		return pdrender.ANSI16
	case "ansi256", "256":
		return pdrender.ANSI256
	case "truecolor", "24bit", "rgb":
		return pdrender.TrueColor
	default: // auto + unknown
		if stdoutTTY {
			return pdrender.ANSI256
		}
		return pdrender.NoColor
	}
}

// paperTermenvProfile maps a pdrender.Profile onto the termenv profile lipgloss
// renders against. NoColor → Ascii (strips every SGR escape — clean plain text);
// ANSI16 → ANSI; ANSI256 → ANSI256; TrueColor → TrueColor. This is the bridge
// that makes the resolved profile authoritative over lipgloss's auto-detection.
func paperTermenvProfile(p pdrender.Profile) termenv.Profile {
	switch p {
	case pdrender.NoColor:
		return termenv.Ascii
	case pdrender.ANSI16:
		return termenv.ANSI
	case pdrender.ANSI256:
		return termenv.ANSI256
	case pdrender.TrueColor:
		return termenv.TrueColor
	default:
		return termenv.ANSI256
	}
}

// paperRefResolver is the field-reference seam: given a referenced doc id and
// its refType it returns that doc's TITLE for display, falling back to the raw
// id on any miss. It resolves through the RAW query body, keyed by the real
// _id. (Predates Doc's "_id" normalization; kept — it is correct and avoids
// decoding every doc through the typed seam just for an id→title map.) Each
// distinct refType is fetched once and memoised into an id→title map, so a paper
// with many references to the same type costs one query. A nil-safe, never-block
// render: an unreachable server or unknown type just yields the id.
func paperRefResolver(client *apiclient.Client, dataset, perspective string) func(id, refType string) string {
	byType := map[string]map[string]string{} // refType → (id → title)
	return func(id, refType string) string {
		if id == "" || refType == "" {
			return id
		}
		titles, loaded := byType[refType]
		if !loaded {
			titles = paperLoadTitles(client, dataset, refType, perspective)
			byType[refType] = titles
		}
		if t, ok := titles[id]; ok && t != "" {
			return t
		}
		return id
	}
}

// paperLoadTitles fetches one referenced type and builds an _id→title map from
// the raw query body. Best-effort: a non-2xx or parse failure yields an empty
// map (every lookup then falls back to the id), so the renderer stays robust.
func paperLoadTitles(client *apiclient.Client, dataset, refType, perspective string) map[string]string {
	out := map[string]string{}
	u := paperScopedURL(client, "/v1/data/query/"+url.PathEscape(dataset)+"/"+url.PathEscape(refType))
	params := url.Values{}
	if perspective != "" {
		params.Set("perspective", perspective)
	}
	if qs := params.Encode(); qs != "" {
		u += "?" + qs
	}
	headers := map[string]string{}
	if t := client.Token(); t != "" {
		headers["Authorization"] = "Bearer " + t
	}
	status, body, err := doRequest("GET", u, headers, nil)
	if err != nil || status < 200 || status >= 300 {
		return out
	}
	var env struct {
		Result struct {
			Documents []json.RawMessage `json:"documents"`
		} `json:"result"`
		Documents []json.RawMessage `json:"documents"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return out
	}
	docs := env.Result.Documents
	if docs == nil {
		docs = env.Documents
	}
	for _, r := range docs {
		var ident struct {
			ID    string `json:"_id"`
			Title string `json:"title"`
		}
		if json.Unmarshal(r, &ident) == nil && ident.ID != "" {
			out[ident.ID] = ident.Title
		}
	}
	return out
}

// paperTaskResolver is the wikilink task-chip seam (lvw-t7): given a
// wikilink's pinned docId or raw target, it returns the live *pdrender.TaskChip
// when that key names a TASK, or nil otherwise. It generalizes the
// paperRefResolver memoised-map pattern — the FIRST chip lookup fetches every
// task in ONE query and builds a key→chip map (id in both draft/published
// spellings + lowercased title), so a paper with many task links costs one
// HTTP GET, never one per node. `papers` (the already-fetched paper corpus)
// supplies a title/id exclusion set, preserving the server's type-dispatch
// precedence: a target that names a PAPER stays a paper link even when a task
// shares the title. Best-effort: an unreachable server yields an empty map and
// every wikilink degrades to the plain link — never an error, never a blank.
func paperTaskResolver(client *apiclient.Client, dataset, perspective string, papers []paperRawDoc) func(id string) *pdrender.TaskChip {
	var chips map[string]*pdrender.TaskChip
	return func(id string) *pdrender.TaskChip {
		id = strings.TrimSpace(id)
		if id == "" {
			return nil
		}
		if chips == nil {
			paperKeys := make(map[string]bool, len(papers)*2)
			for _, p := range papers {
				if p.id != "" {
					paperKeys[p.id] = true
				}
				if p.slug != "" {
					paperKeys[p.slug] = true
				}
				if t := strings.ToLower(strings.TrimSpace(p.title)); t != "" {
					paperKeys[t] = true
				}
			}
			chips = paperLoadTaskChips(client, dataset, perspective, paperKeys)
		}
		if c, ok := chips[id]; ok {
			return c
		}
		if c, ok := chips[strings.ToLower(id)]; ok {
			return c
		}
		return nil
	}
}

// paperLoadTaskChips fetches every task document in one query and builds the
// key→chip map for paperTaskResolver. Keys: the task's `_id` in BOTH the
// `drafts.` and published spellings (a picker/authoring pin may carry either)
// plus its lowercased title — except keys already naming a PAPER (paperKeys),
// which keep paper precedence. Field mapping is GARBAGE-TOLERANT (the wire §4
// contract): a non-string status is dropped, a non-integral priority is
// dropped (0 is valid — highest), and criteria count entries whose `met` is
// EXACTLY true over the entry total; absent/empty lists leave CriteriaTotal 0
// so the renderer omits the m/n segment.
func paperLoadTaskChips(client *apiclient.Client, dataset, perspective string, paperKeys map[string]bool) map[string]*pdrender.TaskChip {
	out := map[string]*pdrender.TaskChip{}
	u := paperScopedURL(client, "/v1/data/query/"+url.PathEscape(dataset)+"/task")
	params := url.Values{}
	if perspective != "" {
		params.Set("perspective", perspective)
	}
	if qs := params.Encode(); qs != "" {
		u += "?" + qs
	}
	headers := map[string]string{}
	if t := client.Token(); t != "" {
		headers["Authorization"] = "Bearer " + t
	}
	status, body, err := doRequest("GET", u, headers, nil)
	if err != nil || status < 200 || status >= 300 {
		return out
	}
	var env struct {
		Result struct {
			Documents []json.RawMessage `json:"documents"`
		} `json:"result"`
		Documents []json.RawMessage `json:"documents"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return out
	}
	docs := env.Result.Documents
	if docs == nil {
		docs = env.Documents
	}
	for _, r := range docs {
		var m map[string]any
		if json.Unmarshal(r, &m) != nil {
			continue
		}
		id, _ := m["_id"].(string)
		if id == "" {
			continue
		}
		chip := taskChipFromFields(m)
		pub := strings.TrimPrefix(id, "drafts.")
		for _, k := range []string{id, pub, "drafts." + pub} {
			if k != "" && !paperKeys[k] {
				out[k] = chip
			}
		}
		if t := strings.ToLower(strings.TrimSpace(chip.Title)); t != "" && !paperKeys[t] {
			// First task wins a duplicate-title collision (stable: server order).
			if _, taken := out[t]; !taken {
				out[t] = chip
			}
		}
	}
	return out
}

// taskChipFromFields maps a task document's v1 flat envelope (content fields
// ride at the top level beside _id) into a pdrender.TaskChip.
//
// TODO(lvw-t6): fable-w3 is landing the shared {met,total} criteria helper
// with lvw-t6 — align this inline count with it once merged.
func taskChipFromFields(m map[string]any) *pdrender.TaskChip {
	chip := &pdrender.TaskChip{}
	if t, ok := m["title"].(string); ok {
		chip.Title = t
	}
	if s, ok := m["lifecycle_status"].(string); ok {
		chip.Status = s
	}
	if p, ok := m["priority"].(float64); ok && p == float64(int(p)) && p >= 0 {
		chip.Priority = int(p)
		chip.HasPriority = true
	}
	if list, ok := m["acceptance_criteria"].([]any); ok && len(list) > 0 {
		chip.CriteriaTotal = len(list)
		for _, e := range list {
			if em, ok := e.(map[string]any); ok {
				if met, ok := em["met"].(bool); ok && met {
					chip.CriteriaMet++
				}
			}
		}
	}
	return chip
}

// paperValueResolver is the inline live-value seam (lvw-t1, wire §3/§5): given
// a valueref's (target, field) it returns the CURRENT canonical value from the
// server, or "" (→ pdrender shows the node's pinned fallback). It generalizes
// the paperRefResolver/paperTaskResolver memoised-map pattern: the FIRST
// lookup walks the paper's raw block tree once for every DISTINCT valueref
// target, then batch-resolves them — one `filter[_id][in]=…` query per schema
// TYPE until every target is found (targets are TYPELESS doc_id slugs and the
// query surface is type-scoped, so declared types are probed with one batched
// query each, early-exiting once all targets resolve) — NEVER one HTTP GET per
// node. Best-effort: an unreachable server / unknown type / redacted field
// yields "" and the valueref degrades to its fallback — never an error, never
// a blank.
func paperValueResolver(client *apiclient.Client, dataset, perspective string, blocksRaw json.RawMessage) func(target, field string) string {
	var docs map[string]map[string]any // target doc_id → flat envelope
	return func(target, field string) string {
		target = strings.TrimSpace(target)
		field = strings.TrimSpace(field)
		// Wire §3: a single top-level declared field name — no dot-paths, no
		// `content.` prefix. Malformed → unresolved → fallback.
		if target == "" || field == "" || strings.Contains(field, ".") {
			return ""
		}
		if docs == nil {
			docs = paperLoadValueDocs(client, dataset, perspective, collectValuerefTargets(blocksRaw))
		}
		doc, ok := docs[target]
		if !ok {
			return ""
		}
		return valueScalarString(doc[field])
	}
}

// collectValuerefTargets deep-walks the paper's RAW block-array JSON and
// returns every distinct inline `valueref` node's non-empty `target`, in
// document order — the Go twin of the Elixir BodyWalk collector (node form
// only; the mark form exists only inside the TipTap editor state, never in a
// stored paper).
func collectValuerefTargets(blocksRaw json.RawMessage) []string {
	seen := map[string]bool{}
	var out []string
	var walk func(v any)
	walk = func(v any) {
		switch t := v.(type) {
		case map[string]any:
			if t["type"] == "valueref" {
				if target, _ := t["target"].(string); strings.TrimSpace(target) != "" {
					target = strings.TrimSpace(target)
					if !seen[target] {
						seen[target] = true
						out = append(out, target)
					}
				}
			}
			for _, child := range t {
				walk(child)
			}
		case []any:
			for _, child := range t {
				walk(child)
			}
		}
	}
	var v any
	if json.Unmarshal(blocksRaw, &v) == nil {
		walk(v)
	}
	return out
}

// paperLoadValueDocs batch-resolves TYPELESS doc_id targets: one
// `filter[_id][in]` query per declared schema type, early-exiting once every
// target resolved. Best-effort throughout — any failure just leaves targets
// unresolved (fallback rendering), never an error.
func paperLoadValueDocs(client *apiclient.Client, dataset, perspective string, targets []string) map[string]map[string]any {
	out := map[string]map[string]any{}
	if len(targets) == 0 {
		return out
	}
	schemas, err := client.LoadSchemas()
	if err != nil {
		return out
	}
	remaining := map[string]bool{}
	for _, t := range targets {
		remaining[t] = true
	}
	for _, s := range schemas {
		if len(remaining) == 0 {
			break
		}
		ids := make([]string, 0, len(remaining))
		for t := range remaining {
			ids = append(ids, t)
		}
		sort.Strings(ids)
		for id, doc := range paperQueryByIDs(client, dataset, s.Name, perspective, ids) {
			out[id] = doc
			delete(remaining, id)
		}
	}
	return out
}

// paperQueryByIDs runs ONE batched id-filtered query against a type and maps
// the returned flat envelopes by `_id`. Mirrors paperLoadTitles' raw-body read
// (the real `_id` survives) with the CSV `filter[_id][in]` op the JS SDK's
// getDocuments uses.
func paperQueryByIDs(client *apiclient.Client, dataset, typeName, perspective string, ids []string) map[string]map[string]any {
	out := map[string]map[string]any{}
	u := paperScopedURL(client, "/v1/data/query/"+url.PathEscape(dataset)+"/"+url.PathEscape(typeName))
	params := url.Values{}
	params.Set("filter[_id][in]", strings.Join(ids, ","))
	if perspective != "" {
		params.Set("perspective", perspective)
	}
	u += "?" + params.Encode()
	headers := map[string]string{}
	if t := client.Token(); t != "" {
		headers["Authorization"] = "Bearer " + t
	}
	status, body, err := doRequest("GET", u, headers, nil)
	if err != nil || status < 200 || status >= 300 {
		return out
	}
	var env struct {
		Result struct {
			Documents []json.RawMessage `json:"documents"`
		} `json:"result"`
		Documents []json.RawMessage `json:"documents"`
	}
	if jerr := json.Unmarshal(body, &env); jerr != nil {
		return out
	}
	docs := env.Result.Documents
	if docs == nil {
		docs = env.Documents
	}
	for _, r := range docs {
		var m map[string]any
		if json.Unmarshal(r, &m) != nil {
			continue
		}
		if id, _ := m["_id"].(string); id != "" {
			out[id] = m
		}
	}
	return out
}

// valueScalarString renders a resolved field value for display: only scalars
// resolve (string / number / bool); an empty string counts as UNRESOLVED (the
// "" convention → fallback), and maps/lists/nil never stringify — so a
// FieldCipher `_bpenc` envelope or a nested object degrades to the fallback,
// mirroring the Elixir value_to_string/1 rule.
func valueScalarString(v any) string {
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case float64:
		if t == float64(int64(t)) {
			return fmt.Sprintf("%d", int64(t))
		}
		return fmt.Sprintf("%g", t)
	case bool:
		return fmt.Sprintf("%t", t)
	default:
		return ""
	}
}

// parsePaperArgs parses the slug positional plus paper-local flags. It tolerates
// the global flags the global parser already consumed (e.g. -o json) and accepts
// --theme/--width/--profile/--perspective/-o/-s here.
func parsePaperArgs(args []string) (parsedPaperArgs, error) {
	var p parsedPaperArgs
	var pos []string
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--theme":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--theme")
			if err != nil {
				return p, err
			}
			// Validate against the full set paperResolveTheme accepts; an unknown
			// value would otherwise silently fall through to auto.
			if !validPaperTheme(v) {
				return p, fmt.Errorf("invalid --theme %q (want dark|light|auto)", v)
			}
			p.theme = v
			i = ni
		case "--perspective":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--perspective")
			if err != nil {
				return p, err
			}
			// Reject an unknown value up front — the perspective switch below
			// silently falls back to published, so a typo (e.g. singular "draft")
			// would show the PUBLISHED paper instead of the caller's draft.
			if !validPerspective(v) {
				return p, fmt.Errorf("invalid --perspective %q (want published|drafts|raw)", v)
			}
			p.perspective = v
			i = ni
		case "--width":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--width")
			if err != nil {
				return p, err
			}
			n, perr := paperAtoi(v)
			if perr != nil {
				return p, fmt.Errorf("invalid --width %q", v)
			}
			p.width = n
			p.widthSet = true
			i = ni
		case "--profile":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--profile")
			if err != nil {
				return p, err
			}
			// Validate against every alias paperResolveProfile accepts; an unknown
			// value would otherwise silently fall through to auto.
			if !validPaperProfile(v) {
				return p, fmt.Errorf("invalid --profile %q (want auto|none|ansi16|ansi256|truecolor)", v)
			}
			p.profile = v
			i = ni
		case "-s", "--server":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, key)
			if err != nil {
				return p, err
			}
			p.server = v
			i = ni
		case "--epic-id", "--wave-id", "--release-gate-id", "--revision-id", "--candidate-id", "--paper-role":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, key)
			if err != nil {
				return p, err
			}
			switch key {
			case "--epic-id":
				p.epicID = v
			case "--wave-id":
				p.waveID = v
			case "--release-gate-id":
				p.releaseGateID = v
			case "--revision-id":
				p.revisionID = v
			case "--candidate-id":
				p.candidateID = v
			case "--paper-role":
				p.paperRole = v
			}
			i = ni
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				return p, fmt.Errorf("unknown paper flag %q", a)
			}
			pos = append(pos, a)
			i++
		}
	}
	if len(pos) > 1 {
		return p, fmt.Errorf("too many arguments; usage: bp paper view <slug>")
	}
	if len(pos) == 1 {
		p.slug = pos[0]
	}
	return p, nil
}

func releasePaperRef(opt parsedPaperArgs) (apiclient.ReleasePaperRef, bool, error) {
	values := []struct {
		name  string
		value string
	}{
		{"--epic-id", opt.epicID},
		{"--wave-id", opt.waveID},
		{"--release-gate-id", opt.releaseGateID},
		{"--revision-id", opt.revisionID},
		{"--candidate-id", opt.candidateID},
		{"--paper-role", opt.paperRole},
	}
	pinned := false
	for _, field := range values {
		pinned = pinned || strings.TrimSpace(field.value) != ""
	}
	if !pinned {
		return apiclient.ReleasePaperRef{}, false, nil
	}
	for _, field := range values {
		if strings.TrimSpace(field.value) == "" {
			return apiclient.ReleasePaperRef{}, true, fmt.Errorf("%s is required with release-pinned Paper reads", field.name)
		}
	}
	return apiclient.ReleasePaperRef{
		EpicID: opt.epicID, WaveID: opt.waveID, ReleaseGateID: opt.releaseGateID,
		RevisionID: opt.revisionID, CandidateID: opt.candidateID, Role: opt.paperRole,
	}, true, nil
}

// validPaperTheme reports whether v names a theme paperResolveTheme understands,
// under the same ToLower/TrimSpace normalization the resolver applies (so no
// currently-working spelling breaks). Mirrors validPerspective's role for --theme.
func validPaperTheme(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "dark", "light", "auto":
		return true
	default:
		return false
	}
}

// validPaperProfile reports whether v names a color profile paperResolveProfile
// understands, under the same ToLower/TrimSpace normalization the resolver
// applies. Covers every alias (ansi16/16, ansi256/256, truecolor/24bit/rgb,
// none/nocolor/no-color/plain, auto) so a valid spelling is never rejected.
func validPaperProfile(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "auto", "none", "nocolor", "no-color", "plain",
		"ansi16", "16", "ansi256", "256", "truecolor", "24bit", "rgb":
		return true
	default:
		return false
	}
}

// paperAtoi parses a non-negative integer flag value without importing strconv
// into this file's hot path (keeps the built-in self-contained).
func paperAtoi(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty")
	}
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("not a number")
		}
		n = n*10 + int(r-'0')
	}
	return n, nil
}

// paperNotFound is the clean miss path for an unknown slug: list a few available
// slugs (sorted) so the user can correct the typo. Exit 4 (not found).
func paperNotFound(out *writer, jsonOut bool, slug string, docs []paperRawDoc, server string) int {
	avail := make([]string, 0, len(docs))
	for _, d := range docs {
		id := d.id
		if id == "" {
			id = d.slug
		}
		if id != "" {
			avail = append(avail, id)
		}
	}
	sort.Strings(avail)

	const maxList = 10
	shown := avail
	more := 0
	if len(shown) > maxList {
		more = len(shown) - maxList
		shown = shown[:maxList]
	}

	if jsonOut {
		out.renderJSON(map[string]any{
			"ok": false,
			"error": map[string]any{
				"code":             "not_found",
				"message":          "no paper matches " + slug,
				"available_sample": shown,
				"available_total":  len(avail),
			},
		})
		return exitNotFound
	}
	out.userErr("no paper matches %q on %s", slug, server)
	if len(shown) > 0 {
		out.errf("available papers:")
		for _, s := range shown {
			out.errf("  %s", s)
		}
		if more > 0 {
			out.errf("  … and %d more (run `bp paper view <slug>` with one of these)", more)
		}
	} else {
		out.errf("no papers are published on this server")
	}
	return exitNotFound
}

// paperError emits a JSON {ok:false,error:{code,message}} on -o json, else a
// one-line stderr message, and returns the exit code.
func paperError(out *writer, jsonOut bool, code, msg string, exit int) int {
	if jsonOut {
		out.renderJSON(map[string]any{
			"ok":    false,
			"error": map[string]any{"code": code, "message": msg},
		})
		return exit
	}
	out.userErr("%s", msg)
	return exit
}

// paperHTMLEntities decodes the handful of entities a paper's body_html
// serializer emits — a plain-text dump needs readable text, not a full parser.
var paperHTMLEntities = strings.NewReplacer(
	"&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", `"`,
	"&#39;", "'", "&apos;", "'", "&nbsp;", " ", "&mdash;", "—", "&ndash;", "–",
)

var paperBlockBreakTags = map[string]bool{
	"p": true, "h1": true, "h2": true, "h3": true, "h4": true,
	"h5": true, "h6": true, "li": true, "tr": true, "div": true,
	"blockquote": true, "ul": true, "ol": true, "table": true,
	"section": true, "article": true, "pre": true,
}

// htmlToPlainText renders a paper's body_html to a readable plain-text dump: it
// turns block-level tag boundaries into line breaks, strips every remaining tag,
// decodes the common entities, and trims stray whitespace. It is a best-effort
// FALLBACK for body_html-only papers (no block tree), NOT a full HTML renderer
// — the goal is legible content in the terminal, not fidelity. Returns "" for
// empty/whitespace-only or all-tag input, so the caller can distinguish a truly
// empty paper from one that renders.
func htmlToPlainText(source string) string {
	if strings.TrimSpace(source) == "" {
		return ""
	}

	// Tokenize rather than globally replacing entities after stripping tags.
	// Raw text inside code/pre is authored literal data and must remain byte-
	// faithful; semantic prose gets the finite decoder exactly once. Using Raw
	// also avoids the tokenizer's full HTML entity decoder widening this policy.
	z := html.NewTokenizer(strings.NewReader(source))
	var b strings.Builder
	literalDepth := 0
	for {
		tt := z.Next()
		switch tt {
		case html.ErrorToken:
			s := b.String()
			lines := strings.Split(s, "\n")
			for i, ln := range lines {
				lines[i] = strings.TrimRight(ln, " \t")
			}
			s = strings.Join(lines, "\n")
			for strings.Contains(s, "\n\n\n") {
				s = strings.ReplaceAll(s, "\n\n\n", "\n\n")
			}
			return strings.TrimSpace(s)
		case html.TextToken:
			raw := string(z.Raw())
			if literalDepth == 0 {
				raw = paperHTMLEntities.Replace(raw)
			}
			b.WriteString(raw)
		case html.StartTagToken:
			tok := z.Token()
			if tok.Data == "code" || tok.Data == "pre" {
				literalDepth++
			}
			if tok.Data == "br" {
				b.WriteByte('\n')
			}
		case html.SelfClosingTagToken:
			if z.Token().Data == "br" {
				b.WriteByte('\n')
			}
		case html.EndTagToken:
			tok := z.Token()
			if tok.Data == "code" || tok.Data == "pre" {
				if literalDepth > 0 {
					literalDepth--
				}
			}
			if paperBlockBreakTags[tok.Data] {
				b.WriteByte('\n')
			}
		}
	}
}

// wrapPaperPlainText applies the resolved terminal width without flattening the
// explicit paragraph boundaries produced by htmlToPlainText. ansi.Wrap counts
// display cells (wide runes included) and hard-breaks overlong tokens.
func wrapPaperPlainText(text string, width int) string {
	if width < 1 {
		width = 1
	}
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if ansi.StringWidth(line) > width {
			wrapped := strings.Split(ansi.Wrap(line, width, " "), "\n")
			for j, segment := range wrapped {
				if ansi.StringWidth(segment) > width {
					wrapped[j] = ansi.Hardwrap(segment, width, false)
				}
			}
			lines[i] = strings.Join(wrapped, "\n")
		}
	}
	return strings.Join(lines, "\n")
}

// usagePaper prints the `bp paper` noun usage (its single verb). An explicit
// `--help` request routes to stdout (toStdout); the error paths keep it on stderr.
func usagePaper(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp paper <verb> [args]")
	p("  read Bulldocs papers from the terminal")
	p("")
	p("verbs:")
	p("  view <slug>      render a paper to the terminal (the CLI counterpart")
	p("                   to opening it in the browser)")
	p("  capture <url>    capture immutable CLI, task-board, and TUI readers")
	p("")
	p("working copy (BPML — papers as files under .barkpark/papers/):")
	p("  new <slug>       scaffold a wall-passing BPML starter + rev-0 anchor")
	p("                   (LOCAL — no server call); push creates the paper")
	p("  pull <slug>      fetch the paper as BPML + a pristine snapshot + rev anchor")
	p("  status [<slug>]  edited? (vs pristine) and behind? (anchor vs server)")
	p("  diff <slug>      line diff of your edits")
	p("  push <slug>      send the edited file; the SERVER derives and applies the")
	p("                   op batch under your anchor, then the file converges on")
	p("                   the returned canonical BPML. An ABSENT slug is CREATED")
	p("                   through the full publish wall. --check dry-runs the")
	p("                   wall (every violation, nothing written)")
	p("")
	p("to author a NEW paper: bp paper new <slug> → edit → bp paper push <slug>")
	p("  (--check first to see violations). Guide: /papers/paper-authoring-excellence")
	p("  JSON producers: bp bulldocs publish <slug> --file payload.json (blocks")
	p("  payload — never hand-rolled HTML; the slug also goes INSIDE the JSON)")
}

// usagePaperView prints the `bp paper view` command signature. An explicit
// `--help` request routes to stdout (toStdout); the error paths keep it on stderr.
func usagePaperView(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp paper view <slug> [flags]")
	p("  render a paper's block tree to ANSI terminal output")
	p("")
	p("flags:")
	p("  --theme dark|light|auto    palette (default auto → detect background)")
	p("  --width <N>                target columns (default: stdout TTY width, else 80)")
	p("  --profile auto|none|ansi16|ansi256|truecolor")
	p("                             color profile (default auto → ANSI256 on a TTY,")
	p("                             NoColor when piped)")
	p("  --perspective published|drafts|raw")
	p("                             read view (default published; papers are public)")
	p("  -o json                    emit the raw paper document (default: rendered ANSI)")
	p("  -s, --server <name|url>    target a saved server or URL")
	p("  --epic-id <id>              release gate epic (requires all release pins)")
	p("  --wave-id <id>              release gate Wave key")
	p("  --release-gate-id <uuid>    immutable open admission")
	p("  --revision-id <uuid>        immutable Wave revision (wire: wave_revision)")
	p("  --candidate-id <uuid>       exact immutable Paper candidate")
	p("  --paper-role campaign|successor")
}

// paperImageResolver is the image-bytes seam (pdrender-terminal-images): given
// an image block's src it fetches the encoded bytes so the renderer can paint
// a half-block mosaic on TrueColor terminals. A relative src (the /media/…
// shape papers store) resolves against the configured server; absolute
// http(s) URLs fetch as-is. Misses return nil — the renderer degrades to its
// labeled box, never errors. Memoised per render (a figure-wrapped image and
// its standalone twin share one fetch); responses over the mosaic byte cap
// are dropped here so a hostile paper can't balloon the process.
func paperImageResolver(server, token string) func(src string) []byte {
	cache := map[string][]byte{}

	return func(src string) []byte {
		if cached, ok := cache[src]; ok {
			return cached
		}
		cache[src] = nil // negative-cache a miss up front

		u := src
		switch {
		case strings.HasPrefix(src, "http://"), strings.HasPrefix(src, "https://"):
			// absolute — fetch as-is
		case strings.HasPrefix(src, "/"):
			u = strings.TrimRight(server, "/") + src
		default:
			return nil // data:, protocol-relative, or junk — box degrade
		}

		headers := map[string]string{}
		if token != "" && !strings.HasPrefix(src, "http") {
			// Only the configured server gets the bearer token — never a
			// third-party absolute URL from document content.
			headers["Authorization"] = "Bearer " + token
		}
		status, body, err := doRequest("GET", u, headers, nil)
		if err != nil || status < 200 || status >= 300 || len(body) == 0 || len(body) > 16<<20 {
			return nil
		}
		cache[src] = body
		return body
	}
}
