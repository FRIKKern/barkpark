package scaffy

import (
	"bytes"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var tokenRe = regexp.MustCompile(`\{\{\.([A-Za-z0-9_-]+)\}\}`)

// Lint runs the frozen rule catalog (doc.go) over one parsed command.
// It is pure text-level (D27): no repo access, no anchor-exists checks.
// It tolerates partial ASTs from a red parse — nil nodes are skipped,
// their defects already reported by Parse.
func Lint(cmd *Command) []Finding {
	l := &linter{cmd: cmd}
	l.direction()
	l.variables()
	l.tokens()
	l.ops()
	l.asserts()
	l.warns()
	sortFindings(l.findings)
	return l.findings
}

type linter struct {
	cmd      *Command
	findings []Finding
}

func (l *linter) add(line int, rule, msg, hint string) {
	l.findings = append(l.findings, Finding{File: l.cmd.SourceFile, Line: line, Rule: rule, Msg: msg, Hint: hint})
}

// ---- E-020 ------------------------------------------------------------

func (l *linter) direction() {
	d := l.cmd.Header.Direction
	if d == nil {
		l.add(l.cmd.Pos.Line, RuleDirectionRequired, `missing DIRECTION header`,
			`declare DIRECTION "add" or DIRECTION "remove" — polarity is never inferred from op text (D23)`)
		return
	}
	if d.Value != "add" && d.Value != "remove" {
		l.add(d.Pos.Line, RuleDirectionRequired, fmt.Sprintf("DIRECTION %q is not add|remove", d.Value), "")
	}
}

// ---- E-014 / E-015 ----------------------------------------------------

func (l *linter) variables() {
	byName := map[string]*VariableDecl{}
	for _, v := range l.cmd.Variables {
		byName[v.Name] = v
	}
	for _, v := range l.cmd.Variables {
		if v.Shape != "" {
			l.lintShape(v)
		}
		if len(v.OneOf) > 0 {
			l.lintOneOf(v)
		}
		if v.Successor != "" {
			l.lintSuccessor(v, byName)
		}
	}
}

// lintOneOf reds a declared EXAMPLES value that is not a member of the
// variable's ONEOF set (E-021, D56). The runtime (checkOneOf) owns the
// live --var value; this is the source-text half, mirroring lintShape.
func (l *linter) lintOneOf(v *VariableDecl) {
	set := make(map[string]bool, len(v.OneOf))
	for _, m := range v.OneOf {
		set[m] = true
	}
	for _, ex := range v.Examples {
		if !set[ex] {
			l.add(v.OneOfPos.Line, RuleOneOf,
				fmt.Sprintf("EXAMPLES %q is not one of the variable's ONEOF members", ex),
				"every EXAMPLES value of a ONEOF variable must be a declared member of the set (D56)")
		}
	}
}

func (l *linter) lintShape(v *VariableDecl) {
	if v.Shape != "ts14" {
		l.add(v.ShapePos.Line, RuleShape, fmt.Sprintf("unknown SHAPE %q", v.Shape),
			`the shape catalog knows: "ts14"`)
		return
	}
	for _, val := range v.Examples {
		ok := len(val) == 14
		for _, r := range val {
			if r < '0' || r > '9' {
				ok = false
				break
			}
		}
		if ok {
			if _, err := time.Parse("20060102150405", val); err != nil {
				ok = false
			}
		}
		if !ok {
			l.add(v.ShapePos.Line, RuleShape,
				fmt.Sprintf("EXAMPLES %q does not satisfy SHAPE ts14", val),
				"ts14 = exactly 14 ASCII digits forming a real UTC YYYYMMDDHHMMSS instant (D16)")
		}
	}
}

func (l *linter) lintSuccessor(v *VariableDecl, byName map[string]*VariableDecl) {
	sib, ok := byName[v.Successor]
	if !ok {
		l.add(v.SuccessorPos.Line, RuleSuccessor,
			fmt.Sprintf("SUCCESSOR names undeclared variable %q", v.Successor), "")
		return
	}
	if len(v.Examples) == 0 || len(v.Examples) != len(sib.Examples) {
		l.add(v.SuccessorPos.Line, RuleSuccessor,
			fmt.Sprintf("SUCCESSOR pair %s/%s: EXAMPLES lists must pair up (%d vs %d values)",
				v.Name, sib.Name, len(v.Examples), len(sib.Examples)),
			"a SUCCESSOR variable's EXAMPLES pair index-wise with its sibling's (D22)")
		return
	}
	for i := range v.Examples {
		before, errB := strconv.Atoi(strings.TrimSpace(sib.Examples[i]))
		after, errA := strconv.Atoi(strings.TrimSpace(v.Examples[i]))
		if errB != nil || errA != nil || after != before+1 {
			l.add(v.SuccessorPos.Line, RuleSuccessor,
				fmt.Sprintf("EXAMPLES %q is not %s's EXAMPLES (%q) + 1", v.Examples[i], sib.Name, sib.Examples[i]),
				"a SUCCESSOR variable's value is the named sibling + 1 (D22)")
		}
	}
}

// ---- token rules: E-003 / E-004 / E-009 / E-013 / W-002 ----------------

type tokenSite struct {
	spelling string
	line     int
	inPath   bool
}

// collectSites walks the AST in document order and yields every token
// occurrence outside comments and headers: paths, fence labels, target
// and payload lines, mark names, guards, snippet payloads and asserts.
func (l *linter) collectSites() []tokenSite {
	var sites []tokenSite
	scan := func(s string, line int, inPath bool) {
		for _, m := range tokenRe.FindAllStringSubmatch(s, -1) {
			sites = append(sites, tokenSite{spelling: m[1], line: line, inPath: inPath})
		}
	}
	scanFence := func(f *Fenced) {
		if f == nil {
			return
		}
		scan(f.Label, f.Pos.Line, false)
		for i, ln := range f.Lines {
			scan(ln, f.Pos.Line+1+i, false)
		}
	}
	scanPayload := func(pl *Payload) {
		if pl == nil {
			return
		}
		scanFence(pl.Fenced)
	}
	for _, s := range l.cmd.Snippets {
		scanFence(s.Payload)
	}
	for _, op := range l.cmd.Ops {
		switch o := op.(type) {
		case *CreateFile:
			if o.Path != nil {
				scan(o.Path.Value, o.Path.Pos.Line, true)
			}
			scanPayload(o.Payload)
			for _, g := range o.Guards {
				scan(g.Text, g.Pos.Line, false)
			}
		case *DeleteFile:
			if o.Path != nil {
				scan(o.Path.Value, o.Path.Pos.Line, true)
			}
			for _, g := range o.Guards {
				scan(g.Text, g.Pos.Line, false)
			}
		case *InOp:
			if o.Path != nil {
				scan(o.Path.Value, o.InPos.Line, true)
			}
			scanFence(o.Target)
			scanPayload(o.Payload)
			if o.Mark != nil {
				scan(o.Mark.Name, o.Mark.Pos.Line, false)
			}
			if o.Reanchor != nil {
				scan(o.Reanchor.Prefix, o.Reanchor.Pos.Line, false)
			}
			for _, g := range o.Guards {
				scan(g.Text, g.Pos.Line, false)
			}
		}
	}
	for _, a := range l.cmd.Asserts {
		if a.Path != nil {
			scan(a.Path.Value, a.Pos.Line, true)
		}
		scan(a.Text, a.Pos.Line, false)
	}
	return sites
}

func (l *linter) tokens() {
	sites := l.collectSites()
	type varWords struct {
		decl  *VariableDecl
		words []string
	}
	var vars []varWords
	for _, v := range l.cmd.Variables {
		vars = append(vars, varWords{decl: v, words: splitWords(v.Name)})
	}
	used := map[string]bool{}
	opaqueSpelling := map[string]string{} // var name → first spelling seen
	for _, site := range sites {
		ws := splitWords(site.spelling)
		var match *varWords
		for i := range vars {
			if wordsEqual(ws, vars[i].words) {
				match = &vars[i]
				break
			}
		}
		if match == nil {
			l.add(site.line, RuleUndeclaredToken,
				fmt.Sprintf("token {{.%s}} does not resolve to any declared VARIABLE", site.spelling),
				"declare it with a VARIABLE line, or fix the spelling (D3(d))")
			continue
		}
		v := match.decl
		used[v.Name] = true
		if !isJoinerOutput(site.spelling, match.words) {
			l.add(site.line, RuleMalformedToken,
				fmt.Sprintf("token {{.%s}} matches VARIABLE %q but is not one of its five spellings", site.spelling, v.Name),
				fmt.Sprintf("legal spellings: {{.%s}} {{.%s}} {{.%s}} {{.%s}} {{.%s}} (A1)",
					joinPascal(match.words), joinKebab(match.words), joinCamel(match.words), joinSnake(match.words), joinScreaming(match.words)),
			)
			continue
		}
		if v.Opaque {
			if first, seen := opaqueSpelling[v.Name]; !seen {
				opaqueSpelling[v.Name] = site.spelling
			} else if first != site.spelling {
				l.add(site.line, RuleOpaqueSpelling,
					fmt.Sprintf("OPAQUE variable %q referenced as {{.%s}} after {{.%s}} — one spelling per file", v.Name, site.spelling, first),
					"an OPAQUE value is never re-cased; pick one spelling (D22)")
			}
		} else if site.inPath && !isLowercaseSpelling(site.spelling, match.words) {
			l.add(site.line, RulePathCasing,
				fmt.Sprintf("path-position token {{.%s}} is not a lowercase spelling", site.spelling),
				fmt.Sprintf("paths use kebab or snake: {{.%s}} or {{.%s}} (D28)",
					joinKebab(match.words), joinSnake(match.words)))
		}
	}
	for _, v := range l.cmd.Variables {
		if !used[v.Name] {
			l.add(v.Pos.Line, RuleUnusedVariable,
				fmt.Sprintf("VARIABLE %q is never referenced", v.Name), "drop it or reference it")
		}
	}
}

// ---- op rules ----------------------------------------------------------

// payloadBytes resolves an op payload (fenced or USE) to verbatim bytes.
func (l *linter) payloadBytes(pl *Payload) []byte {
	if pl == nil {
		return nil
	}
	if pl.Fenced != nil {
		return pl.Fenced.Bytes()
	}
	if s := l.cmd.Snippet(pl.Use); s != nil {
		return s.Payload.Bytes()
	}
	return nil
}

func (l *linter) ops() {
	dir := l.cmd.Direction()
	markSeen := map[string]int{} // path\x00name → first line
	for _, op := range l.cmd.Ops {
		switch o := op.(type) {
		case *CreateFile:
			l.lintGuardsCommon(o.Guards, dir)
		case *DeleteFile:
			if len(o.Guards) == 0 {
				l.add(o.Pos.Line, RuleDeleteNeedsGuard,
					"DELETE FILE IF PRESENT without a content-distinguishing ASLONG",
					"guard on content only this command's CREATE wrote, so a foreign file is never deleted (D25)")
			}
			l.lintGuardsCommon(o.Guards, dir)
		case *InOp:
			l.lintInOp(o, dir, markSeen)
		}
	}
}

func (l *linter) lintInOp(o *InOp, dir string, markSeen map[string]int) {
	l.lintGuardsCommon(o.Guards, dir)

	payload := l.payloadBytes(o.Payload)
	target := o.Target.Bytes()

	// E-007: every IN-op carries a MARK.
	if o.Mark == nil {
		l.add(o.Pos.Line, RuleMissingMark,
			fmt.Sprintf("%s carries no MARK", o.Verb),
			"every mutating IN-op plants (or names) a mark — it is the re-run anchor and the remove handle (D3(b))")
	} else {
		l.lintMark(o, payload, target, markSeen)
	}

	// E-006: guards derive from what the op itself touches. A DONT
	// CONTAIN guard (add polarity) matches text the op WRITES — the
	// payload; a positive CONTAIN guard (remove polarity, D23) matches
	// text the op CONSUMES — the fenced target (REMOVE and the
	// un-sweep REPLACE alike).
	for _, g := range o.Guards {
		base := payload
		baseWord := "payload"
		if o.Verb == RemoveVerb || !g.Dont {
			base = target
			baseWord = "fenced target"
		}
		if len(base) == 0 {
			continue
		}
		if !bytes.Contains(base, []byte(g.Text)) {
			l.add(g.Pos.Line, RuleGuardNotDerived,
				fmt.Sprintf("ASLONG text is not a verbatim substring of the op's %s", baseWord),
				"a guard must match text the op itself writes/removes — the quote-mismatch guard is the canonical failure (D3(c))")
		}
	}

	// E-005: self-consuming REPLACE.
	if o.Verb == Replace && len(payload) > 0 {
		trimmed := bytes.TrimRight(target, "\n")
		if len(trimmed) > 0 && bytes.Contains(payload, trimmed) {
			derived := false
			for _, g := range o.Guards {
				if bytes.Contains(payload, []byte(g.Text)) {
					derived = true
					break
				}
			}
			if !derived || o.Reanchor == nil {
				l.add(o.Pos.Line, RuleSelfConsuming,
					"REPLACE target survives as a substring of its own payload — idempotency rests entirely on the guard",
					`add BOTH a payload-derived ASLONG and a REANCHOR "<mark-prefix>" (A4/D21)`)
			}
		}
	}
}

func (l *linter) lintMark(o *InOp, payload, target []byte, markSeen map[string]int) {
	m := o.Mark
	// E-019: kebab + unique within the target file.
	if !kebabMarkName(m.Name) {
		l.add(m.Pos.Line, RuleMarkName,
			fmt.Sprintf("mark name %q is not kebab", m.Name),
			"marks are kebab: lowercase words joined by hyphens; embedded tokens use their kebab spelling (D24)")
	}
	path := ""
	if o.Path != nil {
		path = o.Path.Value
	}
	key := path + "\x00" + m.Name
	if first, dup := markSeen[key]; dup {
		l.add(m.Pos.Line, RuleMarkName,
			fmt.Sprintf("mark name %q duplicates the mark at line %d in the same target file", m.Name, first),
			"marks are unique within a file; cross-file reuse is legal only between DIRECTION-opposed commands (D24)")
	} else {
		markSeen[key] = m.Pos.Line
	}

	planted := "MARK:" + m.Name
	if m.Virtual {
		// E-010: a virtual mark writes zero bytes, so idempotency must
		// rest on a guard.
		if len(o.Guards) == 0 {
			l.add(m.Pos.Line, RuleVirtualNeedsGuard,
				"MARK VIRTUAL without an ASLONG guard",
				"a virtual mark plants no bytes — idempotency must rest on an explicit guard (D24)")
		}
		return
	}
	switch o.Verb {
	case RemoveVerb:
		// E-016: the consumed mark — the block being removed must carry it.
		if !bytes.Contains(target, []byte(planted)) {
			l.add(m.Pos.Line, RuleConsumedMark,
				fmt.Sprintf("REMOVE's fenced block does not contain its consumed mark text %q", planted),
				"a REMOVE keys on the planted mark comment inside the block it removes (D25)")
		}
	default:
		// E-008: the op's own payload must plant the mark.
		if len(payload) > 0 && !bytes.Contains(payload, []byte(planted)) {
			l.add(m.Pos.Line, RuleUnplantedMark,
				fmt.Sprintf("payload never writes the planted mark text %q", planted),
				`plant it in a payload comment, or declare MARK VIRTUAL "…" + ASLONG when no text is plantable (D24)`)
		}
	}
}

// lintGuardsCommon covers the rules every ASLONG obeys regardless of
// its op: polarity (E-011) and hygiene (E-012).
func (l *linter) lintGuardsCommon(gs []*Aslong, dir string) {
	for _, g := range gs {
		if dir == "add" && !g.Dont {
			l.add(g.Pos.Line, RuleGuardPolarity,
				`ASLONG FILE CONTAIN in a DIRECTION "add" command`,
				"add-direction guards read ASLONG FILE DONT CONTAIN — the op runs as long as its text is absent (D23)")
		}
		if dir == "remove" && g.Dont {
			l.add(g.Pos.Line, RuleGuardPolarity,
				`ASLONG FILE DONT CONTAIN in a DIRECTION "remove" command`,
				"remove-direction guards read ASLONG FILE CONTAIN — the op runs as long as its text is still present (D23)")
		}
		l.lintHygiene(g.Text, g.Pos.Line, "guard")
	}
}

func (l *linter) lintHygiene(text string, line int, what string) {
	for i := 0; i < len(text); i++ {
		if text[i] > 127 {
			l.add(line, RuleGuardHygiene,
				fmt.Sprintf("%s text contains a non-ASCII byte", what),
				"guards and asserts are ASCII-only (A5)")
			break
		}
	}
	l.lintBraceRun(text, line, what)
}

func (l *linter) lintBraceRun(text string, line int, what string) {
	if strings.Contains(text, "}}}") {
		l.add(line, RuleGuardHygiene,
			fmt.Sprintf("%s text contains a }}} run", what),
			"a token's }} may never sit adjacent to a literal } — draw the text from a brace-free region (A5)")
	}
}

// kebabMarkName checks a raw mark name: literal characters must be
// [a-z0-9-] and any embedded token must itself be a lowercase, hyphen
// (not underscore) spelling.
func kebabMarkName(name string) bool {
	rest := name
	for {
		loc := tokenRe.FindStringSubmatchIndex(rest)
		if loc == nil {
			break
		}
		spelling := rest[loc[2]:loc[3]]
		if spelling != strings.ToLower(spelling) || strings.Contains(spelling, "_") {
			return false
		}
		rest = rest[:loc[0]] + rest[loc[1]:]
	}
	for _, r := range rest {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' {
			return false
		}
	}
	return true
}

// ---- asserts: E-012 / E-018 --------------------------------------------

func (l *linter) asserts() {
	for _, a := range l.cmd.Asserts {
		if a.Text != "" {
			if a.Kind == AssertCmd {
				// A CMD string is shell text, not match text: A5's
				// ASCII rule does not bind it (the corpus carries
				// prose caveats in CMD comments) — only the }}}
				// adjacency rule applies.
				l.lintBraceRun(a.Text, a.Pos.Line, "assert command")
			} else {
				l.lintHygiene(a.Text, a.Pos.Line, "assert")
			}
		}
		if a.Kind == AssertCmd && a.Tier != "" && a.Tier != "ci" {
			l.add(a.TierPos.Line, RuleTier,
				fmt.Sprintf("TIER %q is not a known tier", a.Tier),
				"the only tier is ci — LOCAL gates carry no TIER suffix (A2)")
		}
	}
}

// ---- warns: W-001 / W-003 ------------------------------------------------

func (l *linter) warns() {
	// W-001: byte-identical fenced payloads.
	seen := map[string]int{} // payload bytes → first line
	notePayload := func(f *Fenced) {
		if f == nil || len(f.Lines) == 0 {
			return
		}
		key := string(f.Bytes())
		if first, dup := seen[key]; dup {
			l.add(f.Pos.Line, RuleDuplicatePayload,
				fmt.Sprintf("payload duplicates the one at line %d", first),
				"define it once as a SNIPPET and reference it with USE (D3(e))")
		} else {
			seen[key] = f.Pos.Line
		}
	}
	for _, op := range l.cmd.Ops {
		switch o := op.(type) {
		case *CreateFile:
			if o.Payload != nil {
				notePayload(o.Payload.Fenced)
			}
		case *InOp:
			if o.Payload != nil {
				notePayload(o.Payload.Fenced)
			}
		}
	}

	// W-003: generic fence labels.
	noteLabel := func(f *Fenced) {
		if f == nil {
			return
		}
		if f.Label == "target" || f.Label == "payload" {
			l.add(f.Pos.Line, RuleGenericFenceLabel,
				fmt.Sprintf("generic fence label %q", f.Label),
				"name the block after what it holds (D27)")
		}
	}
	for _, s := range l.cmd.Snippets {
		noteLabel(s.Payload)
	}
	for _, op := range l.cmd.Ops {
		switch o := op.(type) {
		case *CreateFile:
			if o.Payload != nil {
				noteLabel(o.Payload.Fenced)
			}
		case *InOp:
			noteLabel(o.Target)
			if o.Payload != nil {
				noteLabel(o.Payload.Fenced)
			}
		}
	}
}
