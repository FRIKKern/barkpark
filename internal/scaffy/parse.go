package scaffy

import (
	"fmt"
	"strconv"
	"strings"
)

// Parse lexes and parses one .scaffy source into a typed AST. It never
// panics and never silently skips: every unparseable construct becomes
// a Finding, and the returned *Command is the best-effort AST (possibly
// partial) so Lint can still run over what parsed.
func Parse(filename string, src []byte) (*Command, []Finding) {
	p := &parser{
		file:  filename,
		lines: splitLines(src),
		cmd: &Command{
			Pos:           Pos{1},
			SourceFile:    filename,
			snippetByName: map[string]*Snippet{},
		},
	}
	p.run()
	p.resolveUses()
	return p.cmd, p.findings
}

// ValidateFile is parse + lint over one source: the full text-level
// validation (D27). Findings are sorted by line, then rule.
func ValidateFile(filename string, src []byte) []Finding {
	cmd, findings := Parse(filename, src)
	findings = append(findings, Lint(cmd)...)
	sortFindings(findings)
	return findings
}

func sortFindings(fs []Finding) {
	// insertion sort — finding lists are small and this keeps the
	// ordering stable without an interface shim.
	for i := 1; i < len(fs); i++ {
		for j := i; j > 0 && lessFinding(fs[j], fs[j-1]); j-- {
			fs[j], fs[j-1] = fs[j-1], fs[j]
		}
	}
}

func lessFinding(a, b Finding) bool {
	if a.Line != b.Line {
		return a.Line < b.Line
	}
	return a.Rule < b.Rule
}

// splitLines splits source bytes into lines without their newlines.
// A trailing final newline does not produce a phantom empty line; CRLF
// is tolerated by stripping the \r.
func splitLines(src []byte) []string {
	s := string(src)
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

// field is one token of a structural line: a bare keyword/word or a
// quoted string. raw preserves the exact bytes between the quotes
// (escapes intact) so Format can re-emit them verbatim.
type field struct {
	text   string
	raw    string
	quoted bool
}

// splitStructural splits a structural line into fields, honoring
// double quotes. Inside quotes, \" escapes a literal quote; all other
// bytes are verbatim. An unterminated quote is an error.
func splitStructural(s string) ([]field, error) {
	var fs []field
	i := 0
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
			i++
		}
		if i >= len(s) {
			break
		}
		if s[i] == '"' {
			var raw, val strings.Builder
			j := i + 1
			closed := false
			for j < len(s) {
				if s[j] == '\\' && j+1 < len(s) && s[j+1] == '"' {
					raw.WriteString(`\"`)
					val.WriteByte('"')
					j += 2
					continue
				}
				if s[j] == '"' {
					closed = true
					break
				}
				raw.WriteByte(s[j])
				val.WriteByte(s[j])
				j++
			}
			if !closed {
				return nil, fmt.Errorf("unterminated quote")
			}
			fs = append(fs, field{text: val.String(), raw: raw.String(), quoted: true})
			i = j + 1
			continue
		}
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != '\t' {
			j++
		}
		fs = append(fs, field{text: s[i:j]})
		i = j
	}
	return fs, nil
}

// Fence lines are flush-left (D26): a line is a fence line iff it
// starts with ::: at column 0. Indented :::-lines inside a fence are
// payload bytes.
func isFenceLine(line string) bool {
	return strings.HasPrefix(line, ":::")
}

// fenceLabelOf extracts and whitespace-normalizes a fence line's label.
func fenceLabelOf(line string) string {
	t := strings.TrimRight(line, " \t")
	t = strings.TrimPrefix(t, ":::")
	t = strings.TrimSuffix(t, ":::")
	return strings.Join(strings.Fields(t), " ")
}

type parser struct {
	file     string
	lines    []string
	i        int // 0-based index of the next line
	cmd      *Command
	findings []Finding
	curIn    *StringArg
	curInPos Pos
	lastOp   Op
}

func (p *parser) add(line int, rule, msg, hint string) {
	p.findings = append(p.findings, Finding{File: p.file, Line: line, Rule: rule, Msg: msg, Hint: hint})
}

func (p *parser) run() {
	for p.i < len(p.lines) {
		raw := p.lines[p.i]
		ln := p.i + 1
		t := strings.TrimSpace(raw)
		if t == "" || strings.HasPrefix(t, "#") {
			p.i++
			continue
		}
		if isFenceLine(raw) {
			p.add(ln, RuleUnknownStatement, "stray fenced block outside any op",
				"a fence only follows CREATE / INSERT … / REPLACE / REMOVE / WITH / SNIPPET")
			p.skipFence()
			continue
		}
		fs, err := splitStructural(t)
		if err != nil {
			p.add(ln, RuleMalformedStatement, err.Error(), `close the " quote`)
			p.i++
			continue
		}
		if len(fs) == 0 || fs[0].quoted {
			p.add(ln, RuleUnknownStatement, "expected a statement keyword", "")
			p.i++
			continue
		}
		switch fs[0].text {
		case "COMMAND", "DESCRIPTION", "LAST_UPDATED", "DOMAIN", "TAGS", "CONCEPT", "VARIANT", "DIRECTION":
			p.parseHeader(fs, ln)
		case "VARIABLES":
			// optional declared-count line; the declarations themselves
			// are the source of truth.
			p.i++
		case "VARIABLE":
			p.parseVariable(fs, ln)
		case "SNIPPET":
			p.parseSnippet(fs, ln)
		case "IN":
			p.parseIn(fs, ln)
		case "CREATE":
			p.parseCreate(fs, ln)
		case "DELETE":
			p.parseDelete(fs, ln)
		case "INSERT":
			p.parseInsert(fs, ln)
		case "REPLACE":
			p.parseInVerb(fs, ln, Replace, 1)
		case "REMOVE":
			p.parseInVerb(fs, ln, RemoveVerb, 1)
		case "MARK":
			p.parseMark(fs, ln)
		case "REANCHOR":
			p.parseReanchor(fs, ln)
		case "ASLONG":
			p.parseAslong(fs, ln)
		case "ASSERT":
			p.parseAssert(fs, ln)
		case "WITH", "USE":
			p.add(ln, RuleDanglingClause,
				fmt.Sprintf("%s without a preceding op", fs[0].text),
				"WITH/USE belong to an INSERT/REPLACE/CREATE payload")
			p.i++
			p.skipFenceIfNext()
		default:
			p.add(ln, RuleUnknownStatement, fmt.Sprintf("unknown statement %q", fs[0].text),
				"see the grammar reference in scaffy/README.md")
			p.i++
		}
	}
}

// parseHeader parses one header line. The corpus spells the whole
// header as ONE line — a sequence of KEY "value" groups ending in the
// bare VARIABLES keyword, with TAGS taking a comma-separated quoted
// list — but each KEY "value" on its own line parses too:
//
//	COMMAND "…" DESCRIPTION "…" … TAGS "a", "b" … DIRECTION "add" VARIABLES
func (p *parser) parseHeader(fs []field, ln int) {
	p.i++
	i := 0
	for i < len(fs) {
		f := fs[i]
		if f.quoted || f.text == "," {
			p.add(ln, RuleMalformedStatement, "header: expected a KEY before its quoted value",
				`header fields read: KEY "value"`)
			return
		}
		key := f.text
		if key == "VARIABLES" {
			// the header's trailing keyword — the VARIABLE declarations
			// themselves are the source of truth.
			if i != len(fs)-1 {
				p.add(ln, RuleMalformedStatement, "VARIABLES must end the header line", "")
			}
			return
		}
		switch key {
		case "COMMAND", "DESCRIPTION", "LAST_UPDATED", "DOMAIN", "TAGS", "CONCEPT", "VARIANT", "DIRECTION":
		default:
			p.add(ln, RuleMalformedStatement, fmt.Sprintf("unknown header key %q", key),
				"legal keys: COMMAND, DESCRIPTION, LAST_UPDATED, DOMAIN, TAGS, CONCEPT, VARIANT, DIRECTION")
			return
		}
		if i+1 >= len(fs) || !fs[i+1].quoted {
			p.add(ln, RuleMalformedStatement, fmt.Sprintf(`malformed header — expected: %s "<value>"`, key),
				"header values are quoted strings")
			return
		}
		value := fs[i+1].text
		i += 2
		if key == "TAGS" {
			vals := []string{value}
			for i+1 < len(fs) && !fs[i].quoted && fs[i].text == "," && fs[i+1].quoted {
				vals = append(vals, fs[i+1].text)
				i += 2
			}
			value = strings.Join(vals, ", ")
		}
		hf := &HeaderField{Pos: Pos{ln}, Key: key, Value: value}
		switch key {
		case "COMMAND":
			p.cmd.Header.Command = hf
		case "DESCRIPTION":
			p.cmd.Header.Description = hf
		case "LAST_UPDATED":
			p.cmd.Header.LastUpdated = hf
		case "DOMAIN":
			p.cmd.Header.Domain = hf
		case "TAGS":
			p.cmd.Header.Tags = hf
		case "CONCEPT":
			p.cmd.Header.Concept = hf
		case "VARIANT":
			p.cmd.Header.Variant = hf
		case "DIRECTION":
			p.cmd.Header.Direction = hf
		}
	}
}

func (p *parser) parseVariable(fs []field, ln int) {
	p.i++
	if len(fs) < 3 || fs[1].quoted || !fs[2].quoted {
		p.add(ln, RuleMalformedStatement,
			`malformed VARIABLE — expected: VARIABLE <n> "Name" [OPAQUE] [SHAPE "…"] [SUCCESSOR "…"] [ONEOF "…", "…"] TITLE "…" DESCRIPTION "…" EXAMPLES "…"`,
			"")
		return
	}
	idx, err := strconv.Atoi(fs[1].text)
	if err != nil {
		p.add(ln, RuleMalformedStatement, fmt.Sprintf("VARIABLE index %q is not a number", fs[1].text), "")
		return
	}
	v := &VariableDecl{Pos: Pos{ln}, Index: idx, Name: fs[2].text}
	i := 3
	for i < len(fs) {
		f := fs[i]
		if f.quoted {
			p.add(ln, RuleMalformedStatement, "unexpected quoted value in VARIABLE declaration",
				"quoted values follow SHAPE/SUCCESSOR/TITLE/DESCRIPTION/EXAMPLES keywords")
			return
		}
		takeQuoted := func(kw string) (string, bool) {
			if i+1 >= len(fs) || !fs[i+1].quoted {
				p.add(ln, RuleMalformedStatement, fmt.Sprintf("%s needs a quoted value", kw), "")
				return "", false
			}
			val := fs[i+1].text
			i += 2
			return val, true
		}
		switch f.text {
		case "OPAQUE":
			v.Opaque = true
			i++
		case "SHAPE":
			val, ok := takeQuoted("SHAPE")
			if !ok {
				return
			}
			v.Shape = val
			v.ShapePos = Pos{ln}
		case "SUCCESSOR":
			val, ok := takeQuoted("SUCCESSOR")
			if !ok {
				return
			}
			v.Successor = val
			v.SuccessorPos = Pos{ln}
		case "TITLE":
			val, ok := takeQuoted("TITLE")
			if !ok {
				return
			}
			v.Title = val
		case "DESCRIPTION":
			val, ok := takeQuoted("DESCRIPTION")
			if !ok {
				return
			}
			v.Description = val
		case "ONEOF":
			// ONEOF takes a comma-separated quoted enum set: "a", "b", …
			// (D56 — cloning the EXAMPLES list loop below).
			val, ok := takeQuoted("ONEOF")
			if !ok {
				return
			}
			v.OneOf = append(v.OneOf, val)
			for i+1 < len(fs) && !fs[i].quoted && fs[i].text == "," && fs[i+1].quoted {
				v.OneOf = append(v.OneOf, fs[i+1].text)
				i += 2
			}
			v.OneOfPos = Pos{ln}
		case "EXAMPLES":
			// EXAMPLES takes a comma-separated quoted list: "a", "b", …
			val, ok := takeQuoted("EXAMPLES")
			if !ok {
				return
			}
			v.Examples = append(v.Examples, val)
			for i+1 < len(fs) && !fs[i].quoted && fs[i].text == "," && fs[i+1].quoted {
				v.Examples = append(v.Examples, fs[i+1].text)
				i += 2
			}
		default:
			p.add(ln, RuleMalformedStatement, fmt.Sprintf("unknown VARIABLE keyword %q", f.text),
				"legal keywords: OPAQUE, SHAPE, SUCCESSOR, ONEOF, TITLE, DESCRIPTION, EXAMPLES")
			return
		}
	}
	p.cmd.Variables = append(p.cmd.Variables, v)
}

func (p *parser) parseSnippet(fs []field, ln int) {
	p.i++
	if len(fs) != 2 {
		p.add(ln, RuleMalformedStatement, "malformed SNIPPET — expected: SNIPPET <name>", "")
		return
	}
	s := &Snippet{Pos: Pos{ln}, Name: fs[1].text}
	s.Payload = p.expectFence("SNIPPET payload")
	p.cmd.Snippets = append(p.cmd.Snippets, s)
	if _, dup := p.cmd.snippetByName[s.Name]; !dup {
		p.cmd.snippetByName[s.Name] = s
	}
}

func (p *parser) parseIn(fs []field, ln int) {
	p.i++
	if len(fs) != 2 || !fs[1].quoted {
		p.add(ln, RuleMalformedStatement, `malformed IN — expected: IN "<path>"`, "")
		return
	}
	p.curIn = &StringArg{Pos: Pos{ln}, Value: fs[1].text}
	p.curInPos = Pos{ln}
}

func (p *parser) parseCreate(fs []field, ln int) {
	p.i++
	if len(fs) != 5 || fs[1].text != "FILE" || fs[2].text != "IF" || fs[3].text != "ABSENT" || !fs[4].quoted {
		p.add(ln, RuleMalformedStatement, `malformed CREATE — expected: CREATE FILE IF ABSENT "<path>"`, "")
		return
	}
	op := &CreateFile{Pos: Pos{ln}, Path: &StringArg{Pos: Pos{ln}, Value: fs[4].text}}
	op.Payload = p.expectPayload("CREATE")
	p.cmd.Ops = append(p.cmd.Ops, op)
	p.lastOp = op
}

func (p *parser) parseDelete(fs []field, ln int) {
	p.i++
	if len(fs) != 5 || fs[1].text != "FILE" || fs[2].text != "IF" || fs[3].text != "PRESENT" || !fs[4].quoted {
		p.add(ln, RuleMalformedStatement, `malformed DELETE — expected: DELETE FILE IF PRESENT "<path>"`, "")
		return
	}
	op := &DeleteFile{Pos: Pos{ln}, Path: &StringArg{Pos: Pos{ln}, Value: fs[4].text}}
	p.cmd.Ops = append(p.cmd.Ops, op)
	p.lastOp = op
}

func (p *parser) parseInsert(fs []field, ln int) {
	if len(fs) != 3 || (fs[1].text != "AFTER" && fs[1].text != "BEFORE") || (fs[2].text != "FIRST" && fs[2].text != "LAST") {
		p.add(ln, RuleMalformedStatement, "malformed INSERT — expected: INSERT AFTER|BEFORE FIRST|LAST",
			"the occurrence pin is mandatory (D7/A3); bare ABOVE/AFTER/BEFORE are retired")
		p.i++
		return
	}
	var verb InOpVerb
	switch {
	case fs[1].text == "AFTER" && fs[2].text == "FIRST":
		verb = InsertAfterFirst
	case fs[1].text == "AFTER" && fs[2].text == "LAST":
		verb = InsertAfterLast
	case fs[1].text == "BEFORE" && fs[2].text == "FIRST":
		verb = InsertBeforeFirst
	default:
		verb = InsertBeforeLast
	}
	p.parseInVerb(fs, ln, verb, 3)
}

// parseInVerb parses the body shared by all IN-scoped verbs: a fenced
// target, then (for INSERT/REPLACE) WITH + payload.
func (p *parser) parseInVerb(fs []field, ln int, verb InOpVerb, wantFields int) {
	if len(fs) != wantFields {
		p.add(ln, RuleMalformedStatement, fmt.Sprintf("malformed %s", verb), "")
		p.i++
		return
	}
	p.i++
	op := &InOp{Pos: Pos{ln}, Verb: verb}
	if p.curIn == nil {
		p.add(ln, RuleMalformedStatement, fmt.Sprintf(`%s outside any IN "<path>" scope`, verb),
			"open the target file with an IN line first")
	} else {
		op.Path = p.curIn
		op.InPos = p.curInPos
	}
	op.Target = p.expectFence(fmt.Sprintf("%s target", verb))
	if verb != RemoveVerb {
		op.Payload = p.expectWith(verb)
	}
	p.cmd.Ops = append(p.cmd.Ops, op)
	p.lastOp = op
}

// expectFence requires the next significant line to open a fence
// (D3(a)). A bare content line instead is the unfenced-block error
// (E-002); the line is left for the dispatch loop.
func (p *parser) expectFence(what string) *Fenced {
	p.skipBlank()
	if p.i >= len(p.lines) {
		p.add(len(p.lines), RuleUnfenced, fmt.Sprintf("missing %s — file ends where a fenced block was expected", what),
			"fence the block: ::: <label> ::: … ::: <label> :::")
		return nil
	}
	if !isFenceLine(p.lines[p.i]) {
		p.add(p.i+1, RuleUnfenced, fmt.Sprintf("unfenced %s", what),
			"every multi-line target/payload is fenced (D3(a)): ::: <label> ::: … ::: <label> :::")
		return nil
	}
	return p.readFence()
}

// readFence consumes an open fence line and everything through its
// close. The first flush-left fence line ends the block; a label
// mismatch there is E-001. EOF without a close is E-001 at the opener.
func (p *parser) readFence() *Fenced {
	openLn := p.i + 1
	label := fenceLabelOf(p.lines[p.i])
	f := &Fenced{Pos: Pos{openLn}, Label: label}
	p.i++
	for p.i < len(p.lines) {
		line := p.lines[p.i]
		if isFenceLine(line) {
			if got := fenceLabelOf(line); got != label {
				p.add(p.i+1, RuleFencePair,
					fmt.Sprintf("fence label mismatch: opened %q at line %d, closed %q", label, openLn, got),
					"opening and closing fence labels must be identical")
			}
			p.i++
			return f
		}
		f.Lines = append(f.Lines, line)
		p.i++
	}
	p.add(openLn, RuleFencePair, fmt.Sprintf("unclosed fence %q", label),
		"close the block with an identical ::: <label> ::: line")
	return f
}

// skipFence consumes a stray fenced block without further findings.
func (p *parser) skipFence() {
	label := fenceLabelOf(p.lines[p.i])
	p.i++
	for p.i < len(p.lines) {
		line := p.lines[p.i]
		if isFenceLine(line) && fenceLabelOf(line) == label {
			p.i++
			return
		}
		p.i++
	}
}

func (p *parser) skipFenceIfNext() {
	p.skipBlank()
	if p.i < len(p.lines) && isFenceLine(p.lines[p.i]) {
		p.skipFence()
	}
}

// expectWith parses the WITH half of INSERT/REPLACE: either WITH + a
// fenced payload, or WITH USE <snippet-name> on one line.
func (p *parser) expectWith(verb InOpVerb) *Payload {
	p.skipBlank()
	if p.i >= len(p.lines) {
		p.add(len(p.lines), RuleMalformedStatement, fmt.Sprintf("%s is missing its WITH payload", verb), "")
		return nil
	}
	ln := p.i + 1
	t := strings.TrimSpace(p.lines[p.i])
	fs, err := splitStructural(t)
	if err != nil || len(fs) == 0 || fs[0].quoted || fs[0].text != "WITH" {
		p.add(ln, RuleMalformedStatement, fmt.Sprintf("expected WITH after the %s target", verb),
			`INSERT/REPLACE read: <verb> <fenced target> WITH <fenced payload | USE name>`)
		return nil
	}
	if len(fs) == 3 && fs[1].text == "USE" && !fs[2].quoted {
		p.i++
		return &Payload{Pos: Pos{ln}, Use: fs[2].text}
	}
	if len(fs) != 1 {
		p.add(ln, RuleMalformedStatement, "malformed WITH — expected bare WITH or WITH USE <name>", "")
		p.i++
		return nil
	}
	p.i++
	f := p.expectFence(fmt.Sprintf("%s payload", verb))
	if f == nil {
		return nil
	}
	return &Payload{Pos: f.Pos, Fenced: f}
}

// expectPayload parses a CREATE payload: a fenced block or USE <name>,
// optionally introduced by a bare WITH line (the corpus spelling:
// CREATE FILE IF ABSENT "path" / WITH / fenced payload).
func (p *parser) expectPayload(what string) *Payload {
	p.skipBlank()
	if p.i < len(p.lines) {
		if fs, err := splitStructural(strings.TrimSpace(p.lines[p.i])); err == nil && len(fs) == 1 && !fs[0].quoted && fs[0].text == "WITH" {
			p.i++
			p.skipBlank()
		}
	}
	if p.i >= len(p.lines) {
		p.add(len(p.lines), RuleUnfenced, fmt.Sprintf("missing %s payload — file ends where one was expected", what),
			"an empty fenced block spells a 0-byte file (D26)")
		return nil
	}
	ln := p.i + 1
	line := p.lines[p.i]
	if isFenceLine(line) {
		f := p.readFence()
		return &Payload{Pos: f.Pos, Fenced: f}
	}
	t := strings.TrimSpace(line)
	if fs, err := splitStructural(t); err == nil && len(fs) == 2 && !fs[0].quoted && fs[0].text == "USE" && !fs[1].quoted {
		p.i++
		return &Payload{Pos: Pos{ln}, Use: fs[1].text}
	}
	p.add(ln, RuleUnfenced, fmt.Sprintf("unfenced %s payload", what),
		"every payload is fenced (D3(a)); an empty fence spells a 0-byte file (D26)")
	return nil
}

func (p *parser) skipBlank() {
	for p.i < len(p.lines) {
		t := strings.TrimSpace(p.lines[p.i])
		if t == "" || strings.HasPrefix(t, "#") {
			p.i++
			continue
		}
		return
	}
}

func (p *parser) parseMark(fs []field, ln int) {
	p.i++
	var name string
	virtual := false
	switch {
	case len(fs) == 2 && fs[1].quoted:
		name = fs[1].text
	case len(fs) == 3 && fs[1].text == "VIRTUAL" && fs[2].quoted:
		virtual = true
		name = fs[2].text
	default:
		p.add(ln, RuleMalformedStatement, `malformed MARK — expected: MARK "name" or MARK VIRTUAL "name"`, "")
		return
	}
	in, ok := p.lastOp.(*InOp)
	if !ok || in == nil {
		p.add(ln, RuleDanglingClause, "MARK without a preceding IN-op",
			"MARK attaches to the INSERT/REPLACE/REMOVE directly above it")
		return
	}
	if in.Mark != nil {
		p.add(ln, RuleDanglingClause, "op already carries a MARK", "one MARK per op")
		return
	}
	in.Mark = &Mark{Pos: Pos{ln}, Name: name, Virtual: virtual}
}

func (p *parser) parseReanchor(fs []field, ln int) {
	p.i++
	if len(fs) != 2 || !fs[1].quoted {
		p.add(ln, RuleMalformedStatement, `malformed REANCHOR — expected: REANCHOR "<mark-name-prefix>"`, "")
		return
	}
	in, ok := p.lastOp.(*InOp)
	if !ok || in == nil || in.Verb != Replace || in.Mark == nil || in.Reanchor != nil {
		p.add(ln, RuleReanchorMisplaced, "REANCHOR is only legal directly after MARK on a REPLACE (D21)",
			"order: REPLACE … WITH … MARK \"name\" REANCHOR \"prefix\"")
		return
	}
	in.Reanchor = &Reanchor{Pos: Pos{ln}, Prefix: fs[1].text}
}

func (p *parser) parseAslong(fs []field, ln int) {
	p.i++
	var dont bool
	var text string
	switch {
	case len(fs) == 4 && fs[1].text == "FILE" && fs[2].text == "CONTAIN" && fs[3].quoted:
		text = fs[3].text
	case len(fs) == 5 && fs[1].text == "FILE" && fs[2].text == "DONT" && fs[3].text == "CONTAIN" && fs[4].quoted:
		dont = true
		text = fs[4].text
	default:
		p.add(ln, RuleMalformedStatement, `malformed ASLONG — expected: ASLONG FILE [DONT] CONTAIN "<text>"`, "")
		return
	}
	g := &Aslong{Pos: Pos{ln}, Dont: dont, Text: text}
	switch op := p.lastOp.(type) {
	case *InOp:
		op.Guards = append(op.Guards, g)
	case *CreateFile:
		op.Guards = append(op.Guards, g)
	case *DeleteFile:
		op.Guards = append(op.Guards, g)
	default:
		p.add(ln, RuleDanglingClause, "ASLONG without a preceding op",
			"ASLONG attaches to the op directly above it")
	}
}

func (p *parser) parseAssert(fs []field, ln int) {
	p.i++
	if len(fs) < 2 {
		p.add(ln, RuleMalformedStatement, "malformed ASSERT", "")
		return
	}
	switch fs[1].text {
	case "FILE":
		p.parseAssertFile(fs, ln)
	case "CMD":
		p.parseAssertCmd(fs, ln)
	default:
		p.add(ln, RuleMalformedStatement, "malformed ASSERT — expected ASSERT FILE … or ASSERT CMD …", "")
	}
}

func (p *parser) parseAssertFile(fs []field, ln int) {
	if len(fs) < 4 || !fs[2].quoted {
		p.add(ln, RuleMalformedStatement,
			`malformed ASSERT FILE — expected: ASSERT FILE "<path>" CONTAINS|DONT CONTAIN "<text>" | EXISTS | ABSENT`, "")
		return
	}
	a := &Assert{Pos: Pos{ln}, Path: &StringArg{Pos: Pos{ln}, Value: fs[2].text}}
	rest := fs[3:]
	switch {
	case len(rest) == 2 && rest[0].text == "CONTAINS" && rest[1].quoted:
		a.Kind = AssertFileContains
		a.Text = rest[1].text
		a.TextPos = Pos{ln}
	case len(rest) == 3 && rest[0].text == "DONT" && rest[1].text == "CONTAIN" && rest[2].quoted:
		a.Kind = AssertFileDontContain
		a.Text = rest[2].text
		a.TextPos = Pos{ln}
	case len(rest) == 1 && rest[0].text == "EXISTS":
		a.Kind = AssertFileExists
	case len(rest) == 1 && rest[0].text == "ABSENT":
		a.Kind = AssertFileAbsent
	default:
		p.add(ln, RuleMalformedStatement,
			`malformed ASSERT FILE — expected: ASSERT FILE "<path>" CONTAINS|DONT CONTAIN "<text>" | EXISTS | ABSENT`, "")
		return
	}
	p.cmd.Asserts = append(p.cmd.Asserts, a)
}

func (p *parser) parseAssertCmd(fs []field, ln int) {
	if len(fs) < 3 || !fs[2].quoted {
		p.add(ln, RuleMalformedStatement, `malformed ASSERT CMD — expected: ASSERT CMD "<command>" [TIER ci]`, "")
		return
	}
	a := &Assert{Pos: Pos{ln}, Kind: AssertCmd, Text: fs[2].text, TextPos: Pos{ln}}
	rest := fs[3:]
	switch {
	case len(rest) == 0:
	case len(rest) == 2 && rest[0].text == "TIER":
		a.Tier = rest[1].text
		a.TierPos = Pos{ln}
	default:
		p.add(ln, RuleMalformedStatement, `malformed ASSERT CMD — trailing fields (only TIER <tier> is legal)`, "")
		return
	}
	p.cmd.Asserts = append(p.cmd.Asserts, a)
}

// resolveUses checks every USE payload against the declared snippets
// (P-004).
func (p *parser) resolveUses() {
	check := func(pl *Payload) {
		if pl == nil || pl.Use == "" {
			return
		}
		if p.cmd.Snippet(pl.Use) == nil {
			p.add(pl.Pos.Line, RuleUndefinedSnippet,
				fmt.Sprintf("USE references undefined SNIPPET %q", pl.Use),
				"declare the SNIPPET before the ops that USE it")
		}
	}
	for _, op := range p.cmd.Ops {
		switch o := op.(type) {
		case *CreateFile:
			check(o.Payload)
		case *InOp:
			check(o.Payload)
		}
	}
}
