package cli

// context_map_cmd.go — `bp context map <keyword>`: mine one epic's worth of
// source into a single optical atlas page plus an AUTHORITATIVE laws sidecar,
// so a cold agent gains the shape of a system without re-traversing it.
//
// The sibling of `bp context pack`, and the same two-channel posture, aimed at
// a different question. `pack` is given the files and pictures their FULL
// text; `map` is given a KEYWORD and pictures the SHAPE — which modules exist,
// what each says it is for, what it exposes, and which of them reference which:
//
//	├─▶ laws channel  <kw>.laws.txt   every polarity sentence of every mined
//	│                                 moduledoc, VERBATIM — authoritative
//	└─▶ optical chan. page_N.png      the atlas: nodes, gists, defs, edges
//	    ledger        map.json        nodes + edges + token cost + instruction
//
// Why two channels (the intuition-atlas result, /papers/intuition-atlas-verdict
// rev2): the image is efficient for topology and preserved placement intuition
// at a fraction of the token cost, but polarity became reliable only once the
// complete boundary sentences travelled as text. An image is a fine map and a
// terrible contract. So the picture carries the shape, the text carries the
// rules, and the reading instruction tells the consumer, in writing, that the
// text file WINS for any trust-boundary claim.
//
// A map.json edge is an OBSERVATION, never an inference: each one names the
// file and the 1-based line where one node's text literally said another
// node's name (context_map_mine.go, mineEdges). An agent can therefore verify
// any relation before asserting it, with one grep.
//
// Local file I/O only — no network, no manifest noun, nothing to shadow.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// contextMapManifest is map.json: what was mined, the observed graph, the cost
// ledger, and the exact reading instruction a consumer pastes.
type contextMapManifest struct {
	Keyword string        `json:"keyword"`
	Root    string        `json:"root"`
	Outdir  string        `json:"outdir"`
	Nodes   []mapNode     `json:"nodes"`
	Edges   []mapEdge     `json:"edges"`
	Pages   []contextPage `json:"pages"`
	Laws    struct {
		File  string `json:"file"`
		Count int    `json:"count"`
	} `json:"laws"`
	// Matched is how many files the keyword hit; Included is how many made the
	// atlas. They differ only when --max-files clipped the set, and both are
	// reported so a clipped map can never read as a complete one.
	Matched  int     `json:"matched"`
	Included int     `json:"included"`
	Scale    float64 `json:"scale"`
	Glyph    string  `json:"glyph"`
	Tokens   struct {
		Bundle       int `json:"bundle"`
		Image        int `json:"image"`
		Laws         int `json:"laws"`
		TextBaseline int `json:"text_baseline"`
	} `json:"tokens"`
	Multiplier  float64 `json:"multiplier"`
	Instruction string  `json:"instruction"`
}

// ctxMapDefaultMaxFiles bounds one atlas. An epic wider than this is clipped
// (visibly — see Matched vs Included), never silently.
const ctxMapDefaultMaxFiles = 40

// ctxMapSkipDirs are directories no atlas ever descends into: build output,
// vendored code, and the git object store. Mining them would bury the epic's
// own modules under generated noise.
var ctxMapSkipDirs = map[string]bool{
	".git": true, "_build": true, "deps": true, "node_modules": true,
	"vendor": true, ".turbo": true, "dist": true, "cover": true,
	".elixir_ls": true, "static": true, ".next": true,
}

// ctxMapExts are the source kinds a node can be mined from.
var ctxMapExts = map[string]bool{".ex": true, ".exs": true, ".go": true, ".md": true}

func runContextMap(out *writer, g globals, args []string) int {
	if g.help {
		printContextMapHelp(out)
		return exitOK
	}

	root := "."
	outdir := ""
	scale := ctxDefaultScale
	cols := ctxDefaultCols
	maxFiles := ctxMapDefaultMaxFiles
	var keywords []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--root":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--root needs a directory")
			}
			i++
			root = args[i]
		case a == "--out":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--out needs a directory")
			}
			i++
			outdir = args[i]
		case a == "--scale":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--scale needs a value in (0,1]")
			}
			i++
			v, err := strconv.ParseFloat(args[i], 64)
			if err != nil || v <= 0 || v > 1 {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--scale must be a number in (0,1], got %q", args[i])
			}
			scale = v
		case a == "--cols":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--cols needs a positive integer")
			}
			i++
			v, err := strconv.Atoi(args[i])
			if err != nil || v < 20 {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--cols must be an integer >= 20, got %q", args[i])
			}
			cols = v
		case a == "--max-files":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--max-files needs a positive integer")
			}
			i++
			v, err := strconv.Atoi(args[i])
			if err != nil || v < 1 {
				return usageErrf(out, func() { printContextMapHelp(out) }, "--max-files must be an integer >= 1, got %q", args[i])
			}
			maxFiles = v
		case strings.HasPrefix(a, "-"):
			return usageErrf(out, func() { printContextMapHelp(out) },
				"unknown flag %q (context map accepts --root, --out, --scale, --cols, --max-files)", a)
		default:
			keywords = append(keywords, a)
		}
	}
	if len(keywords) != 1 {
		return usageErrf(out, func() { printContextMapHelp(out) }, "context map needs exactly one <keyword>")
	}
	keyword := keywords[0]

	matches, sources, err := scanForKeyword(root, keyword, maxFiles)
	if err != nil {
		out.userErr("context map: %v", err)
		return exitGeneric
	}
	// REFUSE THE CONFIDENT ZERO. A map with no nodes is indistinguishable from
	// a scan that read nothing — a wrong --root, a typo'd keyword, a skip rule
	// that ate the tree. Emitting an empty atlas would hand a cold agent a
	// picture of nothing and call it the system's shape.
	if len(matches) == 0 {
		out.userErr("context map: no source file under %s mentions %q — refusing to emit an empty atlas (0 nodes is indistinguishable from a failed scan; check --root and the keyword)", root, keyword)
		return exitGeneric
	}

	nodes := make([]mapNode, 0, len(matches))
	for _, p := range matches {
		nodes = append(nodes, mineNode(p, sources[p]))
	}
	edges := mineEdges(nodes, sources)

	if outdir == "" {
		outdir = sanitizeKeyword(keyword) + ".map"
	}
	if err := os.MkdirAll(outdir, 0o755); err != nil {
		out.userErr("context map: %v", err)
		return exitGeneric
	}

	body := renderAtlasText(keyword, root, nodes, edges)
	lines := wrapContextLines(body, cols)
	pages, err := renderContextBundle(lines, scale, outdir)
	if err != nil {
		out.userErr("context map: %v", err)
		return exitGeneric
	}

	lawsBody, lawsCount := renderLaws(keyword, nodes)
	lawsName := sanitizeKeyword(keyword) + ".laws.txt"
	if err := os.WriteFile(filepath.Join(outdir, lawsName), []byte(lawsBody), 0o644); err != nil {
		out.userErr("context map: %v", err)
		return exitGeneric
	}

	var man contextMapManifest
	man.Keyword = keyword
	man.Root = root
	man.Outdir = outdir
	man.Nodes = nodes
	man.Edges = edges
	man.Pages = pages
	man.Laws.File = lawsName
	man.Laws.Count = lawsCount
	man.Matched = len(sources)
	man.Included = len(nodes)
	man.Scale = scale
	man.Glyph = fmt.Sprintf("7x13@%.2f", scale)
	for _, p := range pages {
		man.Tokens.Image += p.Tokens
	}
	man.Tokens.Laws = (len(lawsBody) + ctxTextTokenDivisor - 1) / ctxTextTokenDivisor
	man.Tokens.Bundle = man.Tokens.Image + man.Tokens.Laws
	baseline := 0
	for _, p := range matches {
		baseline += len(sources[p])
	}
	man.Tokens.TextBaseline = (baseline + ctxTextTokenDivisor - 1) / ctxTextTokenDivisor
	if man.Tokens.Bundle > 0 {
		man.Multiplier = float64(man.Tokens.TextBaseline) / float64(man.Tokens.Bundle)
		man.Multiplier = float64(int(man.Multiplier*100+0.5)) / 100
	}
	man.Instruction = contextMapInstruction(man)

	manJSON, err := json.MarshalIndent(man, "", " ")
	if err != nil {
		out.userErr("context map: %v", err)
		return exitGeneric
	}
	if err := os.WriteFile(filepath.Join(outdir, "map.json"), manJSON, 0o644); err != nil {
		out.userErr("context map: %v", err)
		return exitGeneric
	}

	if out.machineOut() {
		out.renderJSON(man)
		return exitOK
	}
	out.outf("mapped %q → %s\n", keyword, outdir)
	out.outf("  %d node(s) of %d matched, %d observed edge(s), %d law(s), %d page(s), glyph %s\n",
		man.Included, man.Matched, len(man.Edges), man.Laws.Count, len(man.Pages), man.Glyph)
	out.outf("  atlas %d tok vs sources %d tok = %.2f× cheaper\n",
		man.Tokens.Bundle, man.Tokens.TextBaseline, man.Multiplier)
	out.outf("\n%s\n", man.Instruction)
	return exitOK
}

// scanForKeyword walks root and returns the mined file set (deterministically
// ordered), plus every matching file's contents keyed by path. Files whose
// PATH carries the keyword rank ahead of files that only mention it in their
// text, so clipping keeps the epic's own modules and drops its mentions.
func scanForKeyword(root, keyword string, maxFiles int) ([]string, map[string]string, error) {
	needle := strings.ToLower(keyword)
	type cand struct {
		path string
		rank int
	}
	var cands []cand
	sources := map[string]string{}
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // an unreadable corner must not abort the whole atlas
		}
		if info.IsDir() {
			if ctxMapSkipDirs[info.Name()] || (strings.HasPrefix(info.Name(), ".") && info.Name() != "." && p != root) {
				return filepath.SkipDir
			}
			return nil
		}
		if !ctxMapExts[strings.ToLower(filepath.Ext(p))] {
			return nil
		}
		if info.Size() > 512*1024 {
			return nil
		}
		data, rerr := os.ReadFile(p)
		if rerr != nil {
			return nil
		}
		text := string(data)
		switch {
		case strings.Contains(strings.ToLower(p), needle):
			cands = append(cands, cand{p, 0})
		case strings.Contains(strings.ToLower(text), needle):
			cands = append(cands, cand{p, 1})
		default:
			return nil
		}
		sources[p] = text
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].rank != cands[j].rank {
			return cands[i].rank < cands[j].rank
		}
		return cands[i].path < cands[j].path
	})
	if len(cands) > maxFiles {
		cands = cands[:maxFiles]
	}
	paths := make([]string, 0, len(cands))
	for _, c := range cands {
		paths = append(paths, c.path)
	}
	sort.Strings(paths)
	return paths, sources, nil
}

// renderAtlasText is the body the optical page pictures: the node roster with
// gists and definitions, then the observed edge list. Deterministic — nodes
// and edges arrive pre-sorted, and nothing here ranges a map.
func renderAtlasText(keyword, root string, nodes []mapNode, edges []mapEdge) string {
	var b strings.Builder
	fmt.Fprintf(&b, "CONTEXT ATLAS — keyword %q under %s\n", keyword, root)
	fmt.Fprintf(&b, "%d nodes, %d observed edges. Trust-boundary rules live in the laws sidecar, not here.\n\n", len(nodes), len(edges))
	b.WriteString("NODES\n")
	for i, n := range nodes {
		fmt.Fprintf(&b, "[%d] %s  (%s)\n", i+1, n.Path, n.Symbol)
		if n.Gist != "" {
			fmt.Fprintf(&b, "    %s\n", n.Gist)
		}
		if len(n.Defs) > 0 {
			fmt.Fprintf(&b, "    defs: %s\n", strings.Join(n.Defs, ", "))
		}
		if len(n.Laws) > 0 {
			fmt.Fprintf(&b, "    laws: %d (see the sidecar — verbatim there, NOT here)\n", len(n.Laws))
		}
	}
	b.WriteString("\nEDGES (observed: From names To at From:Line)\n")
	for _, e := range edges {
		fmt.Fprintf(&b, "  %s -> %s   via %s at %s:%d\n", e.From, e.To, e.Via, e.From, e.Line)
	}
	return b.String()
}

// renderLaws writes the authoritative sidecar: every polarity sentence of
// every mined moduledoc, verbatim, attributed to its file. Returns the body
// and the law count.
func renderLaws(keyword string, nodes []mapNode) (string, int) {
	var b strings.Builder
	fmt.Fprintf(&b, "LAWS — %q (AUTHORITATIVE)\n", keyword)
	b.WriteString("Every sentence below is copied from the named file's moduledoc word for word, in\n")
	b.WriteString("order, unabridged. The only transform is whitespace: a sentence wrapped across\n")
	b.WriteString("several indented source lines is joined into one line here. Nothing is reworded,\n")
	b.WriteString("shortened, or summarised — grep the file for any clause below and you will find it.\n")
	b.WriteString("For ANY trust-boundary claim (must / must not / never / only / always) THIS FILE WINS\n")
	b.WriteString("over the atlas image: a downscaled glyph can lose a negation, text cannot.\n")
	n := 0
	for _, node := range nodes {
		if len(node.Laws) == 0 {
			continue
		}
		fmt.Fprintf(&b, "\n%s\n", node.Path)
		for _, l := range node.Laws {
			fmt.Fprintf(&b, "  - %s\n", l)
			n++
		}
	}
	if n == 0 {
		b.WriteString("\n(no moduledoc in the mined set states a polarity rule — the atlas asserts none either)\n")
	}
	return b.String(), n
}

// contextMapInstruction is the exact prompt block a consumer pastes in front
// of a cold agent. It says, in writing, which channel wins and that a relation
// must be verified before it is asserted.
func contextMapInstruction(man contextMapManifest) string {
	var b strings.Builder
	b.WriteString("READING INSTRUCTION (paste before the agent's question):\n")
	fmt.Fprintf(&b, "You have a CONTEXT ATLAS for %q: %d page image(s) picturing the shape of the system. Read EACH page in order with the Read tool:\n", man.Keyword, len(man.Pages))
	for _, p := range man.Pages {
		fmt.Fprintf(&b, "  %s\n", filepath.Join(man.Outdir, p.Name))
	}
	b.WriteString("The rules are NOT in the image. Every must / must not / never / only / always sentence is in an AUTHORITATIVE text sidecar — for ANY trust-boundary claim trust it over the picture:\n")
	fmt.Fprintf(&b, "  %s\n", filepath.Join(man.Outdir, man.Laws.File))
	b.WriteString("VERIFY BEFORE YOU ASSERT: every relation in the atlas is an OBSERVATION carrying the file and line where it was seen (")
	fmt.Fprintf(&b, "%s", filepath.Join(man.Outdir, "map.json"))
	b.WriteString(", edges[].from/to/via/line). Before stating that one module calls, depends on, or is constrained by another, open that line and see it. State no relation the atlas does not carry — an atlas is a map of what was observed, never a licence to infer what was not.\n")
	if man.Included < man.Matched {
		fmt.Fprintf(&b, "THIS ATLAS IS CLIPPED: %d of %d matching files were mined. Absence from it is NOT evidence of absence in the repo.\n", man.Included, man.Matched)
	}
	b.WriteString("This atlas is READ-ONLY context: to edit any mapped file, open the original as text.")
	return b.String()
}

// sanitizeKeyword makes a keyword safe as a path segment.
func sanitizeKeyword(kw string) string {
	var b strings.Builder
	for _, r := range kw {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" {
		return "atlas"
	}
	return s
}

func printContextMapHelp(out *writer) {
	out.outf(`usage: bp context map <keyword> [--root <dir>] [--out <dir>] [--scale <0-1>] [--cols <n>] [--max-files <n>]

Mine one epic's worth of source into a context ATLAS: an optical page picturing
the system's SHAPE (modules, self-described gists, public definitions, and the
reference edges observed between them) plus an AUTHORITATIVE text sidecar
carrying every trust-boundary sentence VERBATIM.

Two channels, on purpose (/papers/intuition-atlas-verdict): the image is cheap
and preserves placement intuition; polarity is only reliable as text. A gist is
cut at sentence boundaries ONLY — a dangling clause inverts the rule it was
compressing — and every must / must not / never / only / always sentence rides
the sidecar whole.

  --root <dir>       tree to mine (default: .)
  --out <dir>        output directory (default: <keyword>.map)
  --scale <f>        glyph scale in (0,1] (default %.2f — the validated point)
  --cols <n>         hard-wrap width for long lines (default %d)
  --max-files <n>    node cap (default %d); a clipped atlas says so in map.json
                     and in its reading instruction, never silently

The output directory holds page_N.png, <keyword>.laws.txt, and map.json (the
node/edge ledger, token cost, and the reading instruction, also printed on
stdout; -o json emits the manifest).

Every edge is an OBSERVATION with a file and 1-based line, so a consumer can
verify a relation before asserting it. A keyword that matches nothing is an
ERROR, not an empty atlas: 0 nodes is indistinguishable from a failed scan.
`, ctxDefaultScale, ctxDefaultCols, ctxMapDefaultMaxFiles)
}
