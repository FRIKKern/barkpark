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
	slug        string
	theme       string // dark | light | auto   (default auto)
	perspective string // published | drafts | raw (default published)
	width       int    // 0 = auto-detect
	widthSet    bool
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
	case "help":
		usagePaper(out, true)
		return exitOK
	default:
		out.errf("barkpark: unknown command %q %q", "paper", verb)
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
		out.errf("barkpark: %v", perr)
		usagePaperView(out, false)
		return exitUsage
	}
	if opt.slug == "" {
		out.errf("barkpark: paper view needs a <slug>")
		usagePaperView(out, false)
		return exitUsage
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
	// is a no-op on this server, so we go through the RAW query body to get the
	// _id/slug/title for matching and the not-found slug list. (apiclient.Doc now
	// also normalizes "_id" into Doc.ID, but the raw path stays — it needs every
	// doc's slug, not just the typed subset.) The matched raw doc is then decoded
	// into an apiclient.Doc so Doc.PaperBlocks() drives the render, per the M0
	// client contract.
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
		Width:         width,
		Theme:         theme,
		Profile:       profile,
		RefResolver:   paperRefResolver(client, ctx.Dataset, perspective),
		TaskResolver:  paperTaskResolver(client, ctx.Dataset, perspective, raws),
		ValueResolver: paperValueResolver(client, ctx.Dataset, perspective, blocksRaw),
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
	p("  --profile auto|none|ansi256|truecolor")
	p("                             color profile (default auto → ANSI256 on a TTY,")
	p("                             NoColor when piped)")
	p("  --perspective published|drafts|raw")
	p("                             read view (default published; papers are public)")
	p("  -o json                    emit the raw paper document (default: rendered ANSI)")
	p("  -s, --server <name|url>    target a saved server or URL")
}
