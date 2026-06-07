package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-isatty"
	"github.com/muesli/termenv"
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
// this finisher. `-o ansi` (the default) prints the rendered terminal output;
// `-o json` prints the raw paper document for piping/inspection.

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
	slug        string
	theme       string // dark | light | auto   (default auto)
	perspective string // published | drafts | raw (default published)
	width       int    // 0 = auto-detect
	widthSet    bool
	output      string // ansi | json  (default ansi)
	profile     string // auto | none | ansi256 | truecolor (default auto)
	server      string // -s/--server: a saved name or URL
}

// runPaper is the `bp paper <verb> [args]` built-in entry. v1 ships exactly one
// verb — `view` — so any other verb is a clean usage error that prints the
// noun's help. A bare `bp paper` (no verb) prints usage and exits 2.
func runPaper(out *writer, g globals, args []string) int {
	// A bare `bp paper` (or `bp paper -h`) prints the noun usage. `-h` is consumed
	// by the global parser before we see it, so it surfaces as g.help with an
	// empty arg list — treat that as a help request (exit 0), not an error.
	if len(args) == 0 {
		usagePaper(out)
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
			usagePaperView(out)
			return exitOK
		}
		return runPaperView(out, g, args[1:])
	case "help":
		usagePaper(out)
		return exitOK
	default:
		out.errf("barkpark: unknown command %q %q", "paper", verb)
		usagePaper(out)
		return exitUsage
	}
}

// runPaperView fetches a paper by slug and renders it. args is everything after
// `paper view`, i.e. the slug plus paper-local flags.
func runPaperView(out *writer, g globals, args []string) int {
	// -h/--help anywhere wins over rendering (the global parser folds it into
	// g.help and strips it from args).
	if g.help {
		usagePaperView(out)
		return exitOK
	}
	opt, perr := parsePaperArgs(args)
	if perr != nil {
		out.errf("barkpark: %v", perr)
		usagePaperView(out)
		return exitUsage
	}
	if opt.slug == "" {
		out.errf("barkpark: paper view needs a <slug>")
		usagePaperView(out)
		return exitUsage
	}

	// -o resolution: an explicit global -o/--json wins (the global parser already
	// reflected it into g/out.output); else the paper-local -o ansi|json; else
	// ansi (this command's default — NOT the tty-vs-pipe table/json default the
	// manifest runner uses, because "render the paper" is the whole point).
	output := "ansi"
	if g.outputSet {
		// The global layer only knows table|json|yaml|minimal; map json→json and
		// any non-json explicit output to ansi (the renderable form).
		if out.output == "json" {
			output = "json"
		} else {
			output = "ansi"
		}
	} else if opt.output != "" {
		output = opt.output
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
	})

	// Fetch every paper, then match the slug. The query endpoint's `filter` param
	// is a no-op on this server, and apiclient.Doc decodes only "id" (the API
	// emits "_id"), so we go through the RAW query body to get the real _id/slug/
	// title for matching and the not-found slug list. The matched raw doc is then
	// decoded into an apiclient.Doc so Doc.PaperBlocks() drives the render, per
	// the M0 client contract.
	raws, qerr := paperFetchAll(client, perspective)
	if qerr != nil {
		return paperError(out, jsonOut, "query", fmt.Sprintf("query papers failed: %v", qerr), exitGeneric)
	}
	if len(raws) == 0 {
		return paperError(out, jsonOut, "empty",
			"no papers found on "+ctx.Server+" (dataset "+ctx.Dataset+", perspective "+perspective+")",
			exitNotFound)
	}

	match, found := paperMatch(raws, opt.slug)
	if !found {
		return paperNotFound(out, jsonOut, opt.slug, raws, ctx.Server)
	}

	// -o json: print the raw paper document verbatim (re-indented for stability).
	if jsonOut {
		out.renderRaw(match.raw)
		return exitOK
	}

	// Decode the matched doc's block tree through the apiclient.Doc seam, then via
	// pdrender.Decode → []pdrender.Block.
	var doc apiclient.Doc
	if err := json.Unmarshal(match.raw, &doc); err != nil {
		return paperError(out, jsonOut, "decode", "decode paper: "+err.Error(), exitGeneric)
	}
	blocksRaw := doc.PaperBlocks()
	if len(blocksRaw) == 0 {
		return paperError(out, jsonOut, "empty",
			fmt.Sprintf("paper %q has no renderable blocks", opt.slug), exitNotFound)
	}
	blocks, derr := pdrender.Decode(blocksRaw)
	if derr != nil {
		return paperError(out, jsonOut, "decode", "decode blocks: "+derr.Error(), exitGeneric)
	}

	// Resolve width + theme + profile from stdout's nature.
	stdoutTTY := isatty.IsTerminal(os.Stdout.Fd())
	width := paperResolveWidth(opt, stdoutTTY)
	theme := paperResolveTheme(opt.theme)
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
		Width:       width,
		Theme:       theme,
		Profile:     profile,
		RefResolver: paperRefResolver(client, ctx.Dataset, perspective),
	}
	rendered := pdrender.DefaultRegistry(theme).RenderDoc(blocks, rctx)

	// Print verbatim — the renderer already guarantees no line exceeds Width
	// (chrome is dropped below MinWidth), so no post-processing that could break
	// that guarantee. outf adds the single trailing newline.
	out.outf("%s", rendered)
	return exitOK
}

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
	u := paperScopedURL(client, "/v1/data/query/"+url.PathEscape(client.Dataset)+"/paper")
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

	out := make([]paperRawDoc, 0, len(rawDocs))
	for _, r := range rawDocs {
		var ident struct {
			ID    string `json:"_id"`
			Slug  string `json:"slug"`
			Title string `json:"title"`
		}
		_ = json.Unmarshal(r, &ident)
		out = append(out, paperRawDoc{id: ident.ID, slug: ident.Slug, title: ident.Title, raw: r})
	}
	return out, nil
}

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
func paperResolveTheme(theme string) pdrender.Theme {
	switch strings.ToLower(strings.TrimSpace(theme)) {
	case "light":
		lipgloss.SetHasDarkBackground(false)
		return pdrender.LightTheme()
	case "dark":
		lipgloss.SetHasDarkBackground(true)
		return pdrender.DarkTheme()
	default: // auto + unknown — don't force; honour the detected background
		if lipgloss.HasDarkBackground() {
			return pdrender.DarkTheme()
		}
		return pdrender.LightTheme()
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
// id on any miss. It resolves through the RAW query body (apiclient.Doc loses
// the _id — the API emits "_id", Doc decodes "id"), keyed by the real _id. Each
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
			p.theme = v
			i = ni
		case "--perspective":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--perspective")
			if err != nil {
				return p, err
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
			p.profile = v
			i = ni
		case "-o", "--output":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, key)
			if err != nil {
				return p, err
			}
			switch strings.ToLower(strings.TrimSpace(v)) {
			case "ansi", "json":
				p.output = strings.ToLower(strings.TrimSpace(v))
			default:
				return p, fmt.Errorf("invalid -o %q (want ansi|json)", v)
			}
			i = ni
		case "-s", "--server":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, key)
			if err != nil {
				return p, err
			}
			p.server = v
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
	out.errf("barkpark: no paper matches %q on %s", slug, server)
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
	out.errf("barkpark: %s", msg)
	return exit
}

// usagePaper prints the `bp paper` noun usage (its single verb).
func usagePaper(out *writer) {
	out.errf("usage: barkpark paper <verb> [args]")
	out.errf("  read Bulldocs papers from the terminal")
	out.errf("")
	out.errf("verbs:")
	out.errf("  view <slug>      render a paper to the terminal (the CLI counterpart")
	out.errf("                   to opening it in the browser)")
}

// usagePaperView prints the `bp paper view` command signature.
func usagePaperView(out *writer) {
	out.errf("usage: barkpark paper view <slug> [flags]")
	out.errf("  render a paper's block tree to ANSI terminal output")
	out.errf("")
	out.errf("flags:")
	out.errf("  --theme dark|light|auto    palette (default auto → detect background)")
	out.errf("  --width <N>                target columns (default: stdout TTY width, else 80)")
	out.errf("  --profile auto|none|ansi256|truecolor")
	out.errf("                             color profile (default auto → ANSI256 on a TTY,")
	out.errf("                             NoColor when piped)")
	out.errf("  --perspective published|drafts|raw")
	out.errf("                             read view (default published; papers are public)")
	out.errf("  -o ansi|json               ansi = rendered output (default); json = raw doc")
	out.errf("  -s, --server <name|url>    target a saved server or URL")
}
