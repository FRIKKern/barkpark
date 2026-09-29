package cli

// context_map_mine.go — the deterministic miner behind `bp context map
// <keyword>`: turn a keyword into a set of source nodes (module identity +
// sentence-bounded gist + public definitions + polarity laws) and the
// reference edges observed BETWEEN them.
//
// Two laws govern this file, both learned the expensive way by the
// intuition-atlas experiment (/papers/intuition-atlas-verdict):
//
//  1. NEVER TRUNCATE MID-SENTENCE. A dangling clause is a hallucination seed:
//     "this module must not be called" cut to "this module must" inverts the
//     rule it was compressing. gistWithin therefore cuts at sentence
//     boundaries ONLY — when even the first sentence overruns the budget it
//     ships whole and over budget, because a correct long gist beats a short
//     wrong one.
//  2. POLARITY SENTENCES RIDE TEXT, NEVER PIXELS. Every MUST / MUST NOT /
//     NEVER / ONLY / ALWAYS sentence in a mined moduledoc is copied into the
//     laws sidecar whole and unabridged, and the reading instruction says the
//     text file wins over the image for any trust-boundary claim.
//
//     VERBATIM, STATED EXACTLY: a law carries every word of its source
//     sentence, in order, with nothing dropped or reworded. The ONE transform
//     is whitespace — a moduledoc sentence wrapped across three indented lines
//     is joined into one line, because the sidecar is read as prose, not
//     re-indented into a file. normalizeWS() is that transform and the ONLY
//     one; the checkable property is that normalizeWS(law) is a substring of
//     normalizeWS(source), which TestLawsAreVerbatimModuloWhitespace pins on a
//     multi-line fixture and the end-to-end test re-checks against real files.
//     Claiming byte-identity here would be false on every wrapped sentence in
//     the repo — 102 of 137 laws in a live `cmux` atlas are wrapped.
//
// A third property is enforced by mineEdges: an edge exists only where one
// mined node's text literally names another mined node's symbol, and the edge
// records the file and 1-based line where that name was OBSERVED. An edge a
// reader cannot re-derive by opening that line is not emitted, which is what
// makes "zero invented relations" a checkable claim rather than a hope.

import (
	"regexp"
	"sort"
	"strings"
)

// mapNode is one mined source file: its identity, what it says about itself,
// and what it exposes.
type mapNode struct {
	Path string `json:"path"`
	// Symbol is the node's primary identity (an Elixir module name, a Go file
	// stem) — the name OTHER nodes are searched for when mining edges.
	Symbol string `json:"symbol"`
	// Gist is the moduledoc compressed to a budget, cut at sentence
	// boundaries only.
	Gist string `json:"gist"`
	// GistTruncated records whether the gist dropped any sentence.
	GistTruncated bool `json:"gist_truncated"`
	// Defs are the public definitions this node exposes, in source order.
	Defs []string `json:"defs"`
	// Laws are the verbatim polarity sentences of the moduledoc.
	Laws []string `json:"laws"`
}

// mapEdge is one OBSERVED reference: node From names node To at From:Line.
type mapEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
	// Via is the exact symbol observed — the string a verifier greps for.
	Via string `json:"via"`
	// Line is the 1-based line in From where Via was seen.
	Line int `json:"line"`
}

// ctxMapGistBudget is the per-node gist character budget. It is a BUDGET, not
// a cap: gistWithin never breaks a sentence to honour it.
const ctxMapGistBudget = 220

// ctxPolarity matches a sentence that carries a trust boundary. Case matters
// for the bare words (MUST/NEVER/ONLY/ALWAYS are shouted in this repo's docs)
// but `must not` and `never` also appear in ordinary prose, so both casings
// are admitted — a false positive costs a sidecar line, a false negative
// loses a rule.
var ctxPolarity = regexp.MustCompile(`(?i)\b(must not|must never|must|never|always|only|shall not|cannot|do not|don't|refuses?|forbidden)\b`)

// splitSentences splits prose into sentences, keeping each terminator
// attached. A blank line is also a boundary, so bullet lists and paragraph
// breaks do not fuse into one run-on "sentence". Returned sentences are
// trimmed of surrounding whitespace and never empty.
//
// This is the ONE place sentence boundaries are decided; gistWithin and
// extractPolarity both call it, so a gist can never end somewhere a law
// would not have ended.
func splitSentences(doc string) []string {
	var out []string
	var cur strings.Builder
	flush := func() {
		s := strings.TrimSpace(cur.String())
		cur.Reset()
		if s != "" {
			out = append(out, s)
		}
	}
	lines := strings.Split(doc, "\n")
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		for i := 0; i < len(line); i++ {
			cur.WriteByte(line[i])
			if line[i] != '.' && line[i] != '!' && line[i] != '?' {
				continue
			}
			// A terminator ends a sentence only when the next character is a
			// space or the line ends: "e.g." and "0.4" stay whole.
			if i+1 < len(line) && line[i+1] != ' ' {
				continue
			}
			flush()
		}
		cur.WriteByte(' ')
	}
	flush()
	return out
}

// gistWithin compresses doc to at most budget characters by DROPPING whole
// trailing sentences — never by cutting one. It returns the gist and whether
// anything was dropped.
//
// The budget is deliberately soft in one direction: if the first sentence
// alone exceeds it, that sentence is returned whole and over budget. A gist
// that ends mid-clause is worse than a long one, because a reader cannot tell
// a truncated rule from a complete one.
func gistWithin(doc string, budget int) (string, bool) {
	sents := splitSentences(doc)
	if len(sents) == 0 {
		return "", false
	}
	kept := []string{sents[0]}
	n := len(sents[0])
	for _, s := range sents[1:] {
		if n+1+len(s) > budget {
			break
		}
		kept = append(kept, s)
		n += 1 + len(s)
	}
	return strings.Join(kept, " "), len(kept) < len(sents)
}

// normalizeWS collapses every run of whitespace to a single space and trims.
// It is the ONE transform a law undergoes between the source and the sidecar,
// so "verbatim" is checkable: normalizeWS(law) must be a substring of
// normalizeWS(source file).
func normalizeWS(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// extractPolarity returns every polarity sentence of doc, VERBATIM (modulo
// normalizeWS — see the file header) and in source order. These are the sentences that must never be paraphrased,
// abridged, or entrusted to a downscaled glyph.
func extractPolarity(doc string) []string {
	var out []string
	for _, s := range splitSentences(doc) {
		if ctxPolarity.MatchString(s) {
			out = append(out, s)
		}
	}
	return out
}

var (
	ctxElixirModule   = regexp.MustCompile(`(?m)^\s*defmodule\s+([A-Z][\w.]*)\s+do`)
	ctxElixirDef      = regexp.MustCompile(`(?m)^\s*def\s+([a-z_][\w?!]*)`)
	ctxGoFunc         = regexp.MustCompile(`(?m)^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(`)
	ctxGoTypeOrConst  = regexp.MustCompile(`(?m)^type\s+([A-Za-z_]\w*)\b`)
	ctxElixirModuleDo = regexp.MustCompile(`@moduledoc\s+"""`)
)

// mineModuleDoc pulls the self-description out of a source file: the Elixir
// @moduledoc heredoc, or the leading `//` comment block that follows a Go
// `package` clause (this repo's own house style, as at the top of this file).
// Markdown files describe themselves; their whole body is the doc.
func mineModuleDoc(path, content string) string {
	switch {
	case strings.HasSuffix(path, ".ex"), strings.HasSuffix(path, ".exs"):
		loc := ctxElixirModuleDo.FindStringIndex(content)
		if loc == nil {
			return ""
		}
		rest := content[loc[1]:]
		end := strings.Index(rest, `"""`)
		if end < 0 {
			return ""
		}
		return dedentDoc(rest[:end])
	case strings.HasSuffix(path, ".go"):
		var b strings.Builder
		seenPkg := false
		for _, line := range strings.Split(content, "\n") {
			t := strings.TrimSpace(line)
			if !seenPkg {
				if strings.HasPrefix(t, "package ") {
					seenPkg = true
				}
				continue
			}
			if t == "" {
				if b.Len() == 0 {
					continue
				}
				b.WriteString("\n")
				continue
			}
			if !strings.HasPrefix(t, "//") {
				break
			}
			b.WriteString(strings.TrimSpace(strings.TrimPrefix(t, "//")))
			b.WriteString("\n")
		}
		return strings.TrimSpace(b.String())
	case strings.HasSuffix(path, ".md"):
		// Every active doc in this repo opens with a `<!-- doc-tier: … -->`
		// banner. Left in, it becomes the first "sentence" and eats the whole
		// gist budget with front-matter, so the atlas would picture the
		// ration header instead of what the doc is about.
		body := strings.TrimSpace(content)
		if strings.HasPrefix(body, "<!--") {
			if end := strings.Index(body, "-->"); end >= 0 {
				body = strings.TrimSpace(body[end+3:])
			}
		}
		return body
	}
	return ""
}

// dedentDoc strips the common leading indentation of a heredoc body.
func dedentDoc(s string) string {
	lines := strings.Split(s, "\n")
	indent := -1
	for _, l := range lines {
		if strings.TrimSpace(l) == "" {
			continue
		}
		n := len(l) - len(strings.TrimLeft(l, " "))
		if indent < 0 || n < indent {
			indent = n
		}
	}
	if indent <= 0 {
		return strings.TrimSpace(s)
	}
	for i, l := range lines {
		if len(l) >= indent {
			lines[i] = l[indent:]
		} else {
			lines[i] = strings.TrimLeft(l, " ")
		}
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

// minePublicDefs lists what a node exposes, in source order and deduplicated.
func minePublicDefs(path, content string) []string {
	var pats []*regexp.Regexp
	switch {
	case strings.HasSuffix(path, ".ex"), strings.HasSuffix(path, ".exs"):
		pats = []*regexp.Regexp{ctxElixirDef}
	case strings.HasSuffix(path, ".go"):
		pats = []*regexp.Regexp{ctxGoFunc, ctxGoTypeOrConst}
	default:
		return nil
	}
	seen := map[string]bool{}
	type hit struct {
		at   int
		name string
	}
	var hits []hit
	for _, p := range pats {
		for _, m := range p.FindAllStringSubmatchIndex(content, -1) {
			name := content[m[2]:m[3]]
			if seen[name] {
				continue
			}
			seen[name] = true
			hits = append(hits, hit{at: m[0], name: name})
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].at < hits[j].at })
	out := make([]string, 0, len(hits))
	for _, h := range hits {
		out = append(out, h.name)
	}
	return out
}

// mineSymbol is the node's identity for edge mining: the Elixir module name,
// or the Go file stem (files in one Go package share a namespace, so the
// file's own definitions are what other files name — see mineEdges).
func mineSymbol(path, content string) string {
	if m := ctxElixirModule.FindStringSubmatch(content); m != nil {
		return m[1]
	}
	base := path
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	return strings.TrimSuffix(base, ".go")
}

// mineNode builds one node from a file's path and contents.
func mineNode(path, content string) mapNode {
	doc := mineModuleDoc(path, content)
	gist, truncated := gistWithin(doc, ctxMapGistBudget)
	return mapNode{
		Path:          path,
		Symbol:        mineSymbol(path, content),
		Gist:          gist,
		GistTruncated: truncated,
		Defs:          minePublicDefs(path, content),
		Laws:          extractPolarity(doc),
	}
}

// mineEdges finds every OBSERVED reference between mined nodes. sources maps
// a node path to its full text.
//
// An edge is emitted only when node A's text literally contains node B's
// symbol (or one of B's definitions) at a word boundary, and it carries the
// 1-based line where that happened. Nothing is inferred: a reader holding
// map.json can open From at Line and see Via there, or the edge is a bug.
// At most one edge per (From, To) pair — the FIRST observation — so the
// ledger names a relation once instead of once per call site.
func mineEdges(nodes []mapNode, sources map[string]string) []mapEdge {
	// Symbol → owning node path. A symbol owned by two nodes is ambiguous and
	// is dropped rather than guessed at: a mis-bound edge is exactly the
	// invented relation this command exists to avoid.
	owner := map[string]string{}
	ambiguous := map[string]bool{}
	claim := func(sym, path string) {
		if sym == "" {
			return
		}
		if prev, ok := owner[sym]; ok && prev != path {
			ambiguous[sym] = true
			return
		}
		owner[sym] = path
	}
	for _, n := range nodes {
		// A Go file's STEM is not how other Go files name it — they name its
		// declarations, because one package shares a namespace. Claiming the
		// stem made `errors.go` the target of every `errors.New` and `cli.go`
		// the target of its own `package cli` line: edges that ARE re-derivable
		// at the line they cite (so not invented) and still carry no signal,
		// because the token means a PACKAGE there, not that file. The stem
		// stays on Symbol for display; only Defs claim ownership for Go.
		if !strings.HasSuffix(n.Path, ".go") {
			claim(n.Symbol, n.Path)
		}
		for _, d := range n.Defs {
			claim(d, n.Path)
		}
	}

	var out []mapEdge
	seen := map[string]bool{}
	for _, n := range nodes {
		src, ok := sources[n.Path]
		if !ok {
			continue
		}
		for li, line := range strings.Split(src, "\n") {
			for _, raw := range ctxWordish.FindAllString(line, -1) {
				// A written call is `Beacon.Collector.take(f)`; the symbol
				// OWNED is `Beacon.Collector`. Walk the dotted token down to
				// its longest owned prefix — longest first, so a nested module
				// is never credited to its parent.
				tok, to := raw, ""
				for {
					if p, ok := owner[tok]; ok && !ambiguous[tok] {
						to = p
						break
					}
					dot := strings.LastIndex(tok, ".")
					if dot < 0 {
						break
					}
					tok = tok[:dot]
				}
				if to == "" || to == n.Path {
					continue
				}
				key := n.Path + "\x00" + to
				if seen[key] {
					continue
				}
				seen[key] = true
				out = append(out, mapEdge{From: n.Path, To: to, Via: tok, Line: li + 1})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].From != out[j].From {
			return out[i].From < out[j].From
		}
		if out[i].To != out[j].To {
			return out[i].To < out[j].To
		}
		return out[i].Line < out[j].Line
	})
	return out
}

// ctxWordish tokenizes a line into identifier-ish runs, including dotted
// Elixir module names.
var ctxWordish = regexp.MustCompile(`[A-Za-z_][\w.?!]*`)
