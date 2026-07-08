package pdrender

import (
	"regexp"
	"strings"
)

// ── Mermaid subset parser — dependency-free ──────────────────────────────────
//
// A tiny hand-rolled parser for the 20%-of-Mermaid-that-covers-80%-of-diagrams:
// `flowchart`/`graph` (nodes + directed edges) and `sequenceDiagram`
// (participants + messages). It is deliberately NOT a full Mermaid grammar — no
// external dependency, stdlib + regexp only, honoring the package's import
// discipline (render_test.go's go-list-deps invariant). Anything the parser does
// not understand degrades to the honest folded-source box in hardblocks.go — a
// reader never sees a half-drawn diagram.
//
// The parser produces a neutral model (mmGraph / mmSequence) that the layout
// renderers (mermaidflow.go, mermaidseq.go) turn into rectangular, width-aware
// terminal art. Parsing is line-based and forgiving: an unparseable line is
// skipped, not fatal, so a mostly-valid diagram still draws.

// mmShape is a flowchart node's shape, read from its bracket delimiters.
type mmShape int

const (
	shapeRect      mmShape = iota // A[Label]
	shapeRound                    // A(Label)
	shapeStadium                  // A([Label])
	shapeCircle                   // A((Label))
	shapeDiamond                  // A{Label}
	shapeHexagon                  // A{{Label}}
	shapeSubroutine               // A[[Label]]
	shapeCylinder                 // A[(Label)]
	shapeBare                     // A  (no brackets — id is the label)
)

// mmLinkStyle is an edge's line style, read from its operator.
type mmLinkStyle int

const (
	linkSolid  mmLinkStyle = iota // --> or ---
	linkDotted                    // -.-> or -.-
	linkThick                     // ==> or ===
)

// mmNode is one flowchart node. Nodes are kept in first-seen order so the render
// is stable and source-order-faithful.
type mmNode struct {
	id    string
	label string
	shape mmShape
}

// mmEdge is one directed flowchart edge. head=false is an open link (--- / -.- /
// ===) with no arrowhead.
type mmEdge struct {
	from, to string
	label    string
	style    mmLinkStyle
	head     bool
}

// mmGraph is a parsed flowchart/graph: a direction, first-seen-ordered nodes
// (deduped by id), and directed edges.
type mmGraph struct {
	dir   string // TD | TB | LR | BT | RL  (TB is Mermaid's alias for TD)
	nodes []*mmNode
	byID  map[string]*mmNode
	edges []mmEdge
}

// mmMsgStyle is a sequence-diagram message's arrow style.
type mmMsgStyle int

const (
	msgSolid  mmMsgStyle = iota // ->> or ->
	msgDashed                   // -->> or -->
	msgCross                    // -x / --x  (lost message / end)
)

// mmMessage is one sequence-diagram message from → to with a text label.
type mmMessage struct {
	from, to string
	text     string
	style    mmMsgStyle
	head     bool // solid arrowhead (->>) vs open (->)
}

// mmSequence is a parsed sequenceDiagram: participants in declared/first-seen
// order and the ordered message list.
type mmSequence struct {
	actors   []string // display order
	isActor  map[string]bool
	label    map[string]string // id → display label (participant X as "Label")
	messages []mmMessage
}

// mmDoc is the parse result: exactly one of graph / seq is non-nil (kind names
// which). kind == "" means the source did not parse into a drawable kind and the
// caller must fall back to the honest folded-source box.
type mmDoc struct {
	kind  string // "flowchart" | "sequence" | ""
	graph *mmGraph
	seq   *mmSequence
}

// parseMermaid dispatches on the detected kind (via mermaidKind) and parses the
// source into a drawable model, or returns kind=="" for anything unsupported so
// the caller keeps the honest folded-source box.
func parseMermaid(source string) mmDoc {
	switch strings.ToLower(mermaidKind(source)) {
	case "flowchart", "graph":
		if g := parseFlowchart(source); g != nil && len(g.nodes) > 0 {
			return mmDoc{kind: "flowchart", graph: g}
		}
	case "sequencediagram":
		if s := parseSequence(source); s != nil && len(s.actors) > 0 {
			return mmDoc{kind: "sequence", seq: s}
		}
	}
	return mmDoc{}
}

// ── flowchart parsing ────────────────────────────────────────────────────────

// flowEdgeRe finds a link operator and its optional |label|. Operators are
// ordered longest/most-specific first so `-.->` wins over `-->` wins over `---`.
// The optional trailing `|text|` is Mermaid's most common edge-label form.
var flowEdgeRe = regexp.MustCompile(`\s*(-\.->|-\.-|==>|===|-->|---|--x|--o)\s*(?:\|([^|]*)\|\s*)?`)

// idHeadRe pulls the leading node id (letters/digits/_/-) off a node spec; the
// remainder (if any) carries the shape brackets + label.
var idHeadRe = regexp.MustCompile(`^([A-Za-z0-9_.-]+)`)

// parseFlowchart parses `flowchart`/`graph` source into an mmGraph. Each
// statement line is split on link operators into a chain of node specs; every
// adjacent pair becomes an edge. Node-only lines register a node (and may set
// its shape/label). Unparseable lines are skipped. Returns nil if no header.
func parseFlowchart(source string) *mmGraph {
	lines := strings.Split(source, "\n")
	g := &mmGraph{dir: "TD", byID: map[string]*mmNode{}}

	sawHeader := false
	for _, raw := range lines {
		line := strings.TrimSpace(stripInlineComment(raw))
		if line == "" || strings.HasPrefix(line, "%%") {
			continue
		}
		// Header: `flowchart TD` / `graph LR`. Capture direction, then continue.
		if !sawHeader {
			if kw, rest, ok := splitFirstWord(line); ok {
				lk := strings.ToLower(kw)
				if lk == "flowchart" || lk == "graph" {
					if d := normalizeDir(rest); d != "" {
						g.dir = d
					}
					sawHeader = true
					continue
				}
			}
		}
		// subgraph / end / direction / style / classDef / click — grouping and
		// styling directives are flattened (nodes/edges still register). Full
		// subgraph boxes are a later wave; ignoring them draws an honest,
		// ungrouped graph rather than nothing.
		lw := strings.ToLower(line)
		if strings.HasPrefix(lw, "subgraph") || lw == "end" ||
			strings.HasPrefix(lw, "direction ") || strings.HasPrefix(lw, "style ") ||
			strings.HasPrefix(lw, "classdef ") || strings.HasPrefix(lw, "class ") ||
			strings.HasPrefix(lw, "click ") || strings.HasPrefix(lw, "linkstyle ") {
			continue
		}
		g.parseFlowStatement(line)
	}
	if !sawHeader && len(g.nodes) == 0 {
		return nil
	}
	return g
}

// parseFlowStatement parses one statement line — a chain of node specs joined by
// link operators (A --> B -->|x| C) or a lone node spec (A[Label]).
func (g *mmGraph) parseFlowStatement(line string) {
	// Find all link operators in order; between them lie node specs.
	locs := flowEdgeRe.FindAllStringSubmatchIndex(line, -1)
	if len(locs) == 0 {
		// Node-only line.
		if n := g.parseNodeSpec(line); n != nil {
			g.upsert(n)
		}
		return
	}

	// Walk the chain: specN <op> specN+1 <op> …
	prevEnd := 0
	var prevID string
	for k, loc := range locs {
		specStr := strings.TrimSpace(line[prevEnd:loc[0]])
		op := line[loc[2]:loc[3]]
		var label string
		if loc[4] >= 0 {
			label = strings.TrimSpace(line[loc[4]:loc[5]])
		}
		if n := g.parseNodeSpec(specStr); n != nil {
			g.upsert(n)
			if prevID != "" {
				g.addEdge(prevID, n.id, label, op)
			}
			prevID = n.id
		}
		prevEnd = loc[1]
		// Trailing node spec after the last operator.
		if k == len(locs)-1 {
			tail := strings.TrimSpace(line[prevEnd:])
			if n := g.parseNodeSpec(tail); n != nil {
				g.upsert(n)
				if prevID != "" {
					g.addEdge(prevID, n.id, label, op)
				}
			}
		}
	}
}

// parseNodeSpec parses "A[Label]" / "A(Label)" / "A{Label}" / bare "A" into an
// mmNode. Returns nil for an empty spec. A bare id reuses the id as its label.
func parseNodeSpec(spec string) *mmNode { return (&mmGraph{}).parseNodeSpec(spec) }

func (g *mmGraph) parseNodeSpec(spec string) *mmNode {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil
	}
	m := idHeadRe.FindStringSubmatch(spec)
	if m == nil {
		return nil
	}
	id := m[1]
	rest := strings.TrimSpace(spec[len(id):])
	if rest == "" {
		return &mmNode{id: id, label: id, shape: shapeBare}
	}
	shape, inner, ok := readShape(rest)
	if !ok {
		return &mmNode{id: id, label: id, shape: shapeBare}
	}
	label := strings.TrimSpace(stripQuotes(inner))
	if label == "" {
		label = id
	}
	return &mmNode{id: id, label: label, shape: shape}
}

// shapeDelims are the bracket pairs, most-specific (longest open) first so that
// `((` beats `(` and `[[` / `[(` beat `[`.
var shapeDelims = []struct {
	open, close string
	shape       mmShape
}{
	{"([", "])", shapeStadium},
	{"((", "))", shapeCircle},
	{"[[", "]]", shapeSubroutine},
	{"[(", ")]", shapeCylinder},
	{"{{", "}}", shapeHexagon},
	{"[", "]", shapeRect},
	{"(", ")", shapeRound},
	{"{", "}", shapeDiamond},
}

// readShape reads the shape brackets off a node-spec remainder ("[Label]" →
// rect, "Label"). ok=false if `rest` doesn't start with a known open bracket or
// its matching close is absent.
func readShape(rest string) (mmShape, string, bool) {
	for _, d := range shapeDelims {
		if strings.HasPrefix(rest, d.open) && strings.HasSuffix(rest, d.close) &&
			len(rest) >= len(d.open)+len(d.close) {
			inner := rest[len(d.open) : len(rest)-len(d.close)]
			return d.shape, inner, true
		}
	}
	return shapeRect, "", false
}

// upsert registers a node in first-seen order, deduping by id. A later spec that
// carries a real shape/label upgrades a bare placeholder created by an edge.
func (g *mmGraph) upsert(n *mmNode) {
	if existing, ok := g.byID[n.id]; ok {
		if existing.shape == shapeBare && n.shape != shapeBare {
			existing.shape = n.shape
			existing.label = n.label
		}
		return
	}
	g.byID[n.id] = n
	g.nodes = append(g.nodes, n)
}

// addEdge appends a directed edge, decoding the operator's style + arrowhead.
func (g *mmGraph) addEdge(from, to, label, op string) {
	e := mmEdge{from: from, to: to, label: label, head: true}
	switch {
	case strings.HasPrefix(op, "-."):
		e.style = linkDotted
	case strings.HasPrefix(op, "=="):
		e.style = linkThick
	default:
		e.style = linkSolid
	}
	// Open links (no arrowhead): --- / -.- / === .
	if op == "---" || op == "-.-" || op == "===" {
		e.head = false
	}
	g.edges = append(g.edges, e)
}

// ── sequence parsing ─────────────────────────────────────────────────────────

// seqMsgRe matches `A ->> B : text` and its arrow variants. Operators, longest
// first: -->> (dashed solid-head), --> (dashed open), ->> (solid), -> (open),
// -x / --x (cross). Labels after the colon are optional.
var seqMsgRe = regexp.MustCompile(`^(\S+)\s*(--?>>?|--?x|-->|->)\s*(\S+?)\s*(?::\s*(.*))?$`)

// parseSequence parses `sequenceDiagram` source. Explicit `participant X` /
// `actor X` (optionally `as "Label"`) declarations seed the actor order;
// messages both add edges and lazily register any actor not yet declared.
func parseSequence(source string) *mmSequence {
	s := &mmSequence{isActor: map[string]bool{}, label: map[string]string{}}
	seen := map[string]bool{}
	add := func(id string) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
		s.actors = append(s.actors, id)
	}

	for _, raw := range strings.Split(source, "\n") {
		line := strings.TrimSpace(stripInlineComment(raw))
		if line == "" || strings.HasPrefix(line, "%%") {
			continue
		}
		lw := strings.ToLower(line)
		if lw == "sequencediagram" {
			continue
		}
		// participant / actor declaration.
		if strings.HasPrefix(lw, "participant ") || strings.HasPrefix(lw, "actor ") {
			isActor := strings.HasPrefix(lw, "actor ")
			rest := strings.TrimSpace(line[strings.IndexByte(line, ' ')+1:])
			id, label := splitAs(rest)
			add(id)
			s.isActor[id] = isActor
			if label != "" {
				s.label[id] = label
			}
			continue
		}
		// Block keywords (loop/alt/opt/par/note/activate/…) are flattened for
		// wave 1 — messages still draw; framing boxes are a later wave.
		if isSeqBlockKeyword(lw) {
			continue
		}
		// Message line.
		if m := seqMsgRe.FindStringSubmatch(line); m != nil {
			from, op, to, text := m[1], m[2], m[3], strings.TrimSpace(m[4])
			add(from)
			add(to)
			msg := mmMessage{from: from, to: to, text: text, head: true}
			switch {
			case strings.Contains(op, "x"):
				msg.style = msgCross
			case strings.HasPrefix(op, "--"):
				msg.style = msgDashed
				msg.head = strings.HasSuffix(op, ">>")
			default:
				msg.style = msgSolid
				msg.head = strings.HasSuffix(op, ">>")
			}
			s.messages = append(s.messages, msg)
		}
	}
	return s
}

// isSeqBlockKeyword reports whether a lowercased line opens/closes a sequence
// framing block we flatten in wave 1 (loop/alt/opt/par/rect/note/activate/…).
func isSeqBlockKeyword(lw string) bool {
	for _, kw := range []string{"loop", "alt", "opt", "par", "rect", "critical",
		"break", "note ", "activate ", "deactivate ", "end", "autonumber",
		"and ", "else"} {
		if lw == strings.TrimSpace(kw) || strings.HasPrefix(lw, kw) {
			return true
		}
	}
	return false
}

// splitAs splits `X as "Label"` / `X as Label` into (id, label). No `as` → the
// whole string is the id and label is "".
func splitAs(s string) (id, label string) {
	if i := regexp.MustCompile(`(?i)\s+as\s+`).FindStringIndex(s); i != nil {
		return strings.TrimSpace(s[:i[0]]), strings.TrimSpace(stripQuotes(s[i[1]:]))
	}
	return strings.TrimSpace(s), ""
}

// ── shared helpers ───────────────────────────────────────────────────────────

// normalizeDir maps a header's direction token to a canonical TD/LR/BT/RL. TB is
// Mermaid's alias for TD. Unknown/empty → "" (caller keeps its default).
func normalizeDir(s string) string {
	switch strings.ToUpper(strings.TrimSpace(s)) {
	case "TD", "TB":
		return "TD"
	case "LR":
		return "LR"
	case "BT":
		return "BT"
	case "RL":
		return "RL"
	}
	return ""
}

// splitFirstWord splits "flowchart TD" → ("flowchart", "TD", true).
func splitFirstWord(s string) (first, rest string, ok bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", "", false
	}
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		return s[:i], strings.TrimSpace(s[i+1:]), true
	}
	return s, "", true
}

// stripInlineComment drops a `%% …` trailing comment (Mermaid's comment form).
func stripInlineComment(s string) string {
	if i := strings.Index(s, "%%"); i >= 0 {
		return s[:i]
	}
	return s
}

// stripQuotes removes a single pair of wrapping double quotes.
func stripQuotes(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	return s
}
