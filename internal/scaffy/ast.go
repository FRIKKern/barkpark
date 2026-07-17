package scaffy

import "fmt"

// Pos locates a node in its source file. Line is 1-based.
type Pos struct {
	Line int
}

// Finding is one validator result: a rule violation at File:Line.
// It renders compiler-style as "file:line: RULE-ID message".
type Finding struct {
	File string
	Line int
	Rule string
	Msg  string
	Hint string
}

func (f Finding) String() string {
	return fmt.Sprintf("%s:%d: %s %s", f.File, f.Line, f.Rule, f.Msg)
}

// Command is one parsed .scaffy document.
type Command struct {
	Pos        Pos
	SourceFile string
	Header     Header
	Variables  []*VariableDecl
	Snippets   []*Snippet
	Ops        []Op
	Asserts    []*Assert

	snippetByName map[string]*Snippet
}

// Snippet returns the SNIPPET declared under name, or nil.
func (c *Command) Snippet(name string) *Snippet {
	return c.snippetByName[name]
}

// Direction returns the declared DIRECTION header value ("add" or
// "remove"), or "" when the header is missing or invalid.
func (c *Command) Direction() string {
	if c.Header.Direction == nil {
		return ""
	}
	switch c.Header.Direction.Value {
	case "add", "remove":
		return c.Header.Direction.Value
	}
	return ""
}

// Header carries the quoted-string header fields. A field the source
// never declared is nil. DIRECTION is the only lint-required field
// (E-020) — polarity rules derive from it, never from op text (D23).
type Header struct {
	Command     *HeaderField
	Description *HeaderField
	LastUpdated *HeaderField
	Domain      *HeaderField
	Tags        *HeaderField
	Concept     *HeaderField
	Variant     *HeaderField
	Direction   *HeaderField
}

// HeaderField is one KEY "value" header line.
type HeaderField struct {
	Pos   Pos
	Key   string
	Value string
}

// VariableDecl is one VARIABLE line:
//
//	VARIABLE <n> "Name" [OPAQUE] [SHAPE "ts14"] [SUCCESSOR "Sibling"]
//	         TITLE "…" DESCRIPTION "…" EXAMPLES "…"
//
// OPAQUE: the value is never re-cased; references use exactly one
// spelling per file and are exempt from path-casing lints (D22).
// SHAPE names a value-shape from the shape catalog ("ts14" = exactly
// 14 ASCII digits forming a real UTC YYYYMMDDHHMMSS instant, D16/D22).
// SUCCESSOR declares the value to be the named sibling variable + 1;
// the validator lints the EXAMPLES pair (D22).
// ONEOF constrains the value to a closed set of quoted members; the
// runtime rejects a non-member --var value (VarError, exit 2) and the
// validator reds a declared EXAMPLES value outside the set (E-021, D56).
type VariableDecl struct {
	Pos          Pos
	Index        int
	Name         string
	Opaque       bool
	Shape        string
	ShapePos     Pos
	Successor    string
	SuccessorPos Pos
	OneOf        []string // ONEOF "a", "b", … — a comma-separated quoted enum set (D56)
	OneOfPos     Pos
	Title        string
	Description  string
	Examples     []string // EXAMPLES "a", "b", … — a comma-separated quoted list
}

// Snippet is a named shared payload (D3(e)): SNIPPET <name> + fence.
type Snippet struct {
	Pos     Pos
	Name    string
	Payload *Fenced
}

// Fenced is one ::: <label> ::: … ::: <label> ::: block. Lines are the
// raw payload lines, verbatim — tabs, leading blanks and load-bearing
// blank lines included (D26). Fence lines are never part of the payload.
type Fenced struct {
	Pos   Pos // the opening fence line
	Label string
	Lines []string
}

// Bytes returns the verbatim payload: each line contributing its
// trailing newline. An empty fence yields 0 bytes (D26, the .gitkeep
// case).
func (f *Fenced) Bytes() []byte {
	if f == nil || len(f.Lines) == 0 {
		return nil
	}
	n := 0
	for _, l := range f.Lines {
		n += len(l) + 1
	}
	b := make([]byte, 0, n)
	for _, l := range f.Lines {
		b = append(b, l...)
		b = append(b, '\n')
	}
	return b
}

// Payload is an op's write half: either a fenced block or a USE
// reference to a SNIPPET (never both).
type Payload struct {
	Pos    Pos
	Fenced *Fenced
	Use    string // snippet name when the payload is USE <name>
}

// StringArg is a quoted argument (a path, a guard text, …) with its
// source position.
type StringArg struct {
	Pos   Pos
	Value string
}

// Mark is the MARK "name" / MARK VIRTUAL "name" clause. A plain mark's
// planted text MARK:<name> must be written by the op's own payload
// (E-008); a VIRTUAL mark is a nominal handle with zero in-file bytes
// and requires an ASLONG guard (D24, E-010).
type Mark struct {
	Pos     Pos
	Name    string
	Virtual bool
}

// Reanchor is the optional REANCHOR "<mark-name-prefix>" clause on
// REPLACE (D21): run ≥2 re-anchors at the LAST planted block of the
// mark family instead of the mutated structural target.
type Reanchor struct {
	Pos    Pos
	Prefix string
}

// Aslong is one ASLONG FILE [DONT] CONTAIN "text" idempotency guard.
type Aslong struct {
	Pos  Pos
	Dont bool
	Text string
}

// Op is one mutating operation. Concrete types: *CreateFile,
// *DeleteFile, *InOp.
type Op interface {
	OpPos() Pos
	opNode()
}

// CreateFile is CREATE FILE IF ABSENT "path" + payload. CREATE implies
// mkdir -p at apply time (D26 — engine prose, not a lint).
type CreateFile struct {
	Pos     Pos
	Path    *StringArg
	Payload *Payload
	Guards  []*Aslong
}

func (o *CreateFile) OpPos() Pos { return o.Pos }
func (o *CreateFile) opNode()    {}

// DeleteFile is DELETE FILE IF PRESENT "path". It must carry a
// content-distinguishing ASLONG guard (D25, E-017).
type DeleteFile struct {
	Pos    Pos
	Path   *StringArg
	Guards []*Aslong
}

func (o *DeleteFile) OpPos() Pos { return o.Pos }
func (o *DeleteFile) opNode()    {}

// InOpVerb is the verb of an IN-scoped op.
type InOpVerb int

const (
	InsertAfterFirst InOpVerb = iota
	InsertAfterLast
	Replace
	// RemoveVerb is the REMOVE op verb — suffixed because the bare name
	// belongs to the D40 seam scaffy.Remove (the receipt-replay entry
	// point, remove.go).
	RemoveVerb
	// InsertBeforeFirst/Last splice the payload directly BEFORE the
	// pinned anchor occurrence (ratified from the D55 deferral — the
	// prepend-above-a-surviving-head idiom; add-canonical-marker is the
	// motivating fixture). Same fencing, MARK and guard laws as AFTER;
	// REANCHOR stays REPLACE-only (P-005).
	InsertBeforeFirst
	InsertBeforeLast
)

func (v InOpVerb) String() string {
	switch v {
	case InsertAfterFirst:
		return "INSERT AFTER FIRST"
	case InsertAfterLast:
		return "INSERT AFTER LAST"
	case InsertBeforeFirst:
		return "INSERT BEFORE FIRST"
	case InsertBeforeLast:
		return "INSERT BEFORE LAST"
	case Replace:
		return "REPLACE"
	case RemoveVerb:
		return "REMOVE"
	}
	return "?"
}

// InOp is one op inside an IN "path" scope: INSERT AFTER|BEFORE
// FIRST|LAST, REPLACE (+ optional REANCHOR) or REMOVE. Target and
// Payload are always fenced (D3(a)); Payload is nil for REMOVE.
type InOp struct {
	Pos      Pos // the verb line
	InPos    Pos // the IN line
	Path     *StringArg
	Verb     InOpVerb
	Target   *Fenced
	Payload  *Payload
	Mark     *Mark
	Reanchor *Reanchor
	Guards   []*Aslong
}

func (o *InOp) OpPos() Pos { return o.Pos }
func (o *InOp) opNode()    {}

// AssertKind is the kind of a closing assertion.
type AssertKind int

const (
	AssertFileContains AssertKind = iota
	AssertFileDontContain
	AssertFileExists
	AssertFileAbsent
	AssertCmd
)

func (k AssertKind) String() string {
	switch k {
	case AssertFileContains:
		return "ASSERT FILE CONTAINS"
	case AssertFileDontContain:
		return "ASSERT FILE DONT CONTAIN"
	case AssertFileExists:
		return "ASSERT FILE EXISTS"
	case AssertFileAbsent:
		return "ASSERT FILE ABSENT"
	case AssertCmd:
		return "ASSERT CMD"
	}
	return "?"
}

// Assert is one ASSERT FILE …/ASSERT CMD postcondition. Tier is "" for
// LOCAL gates or "ci" (the only legal tier, A2/E-018).
type Assert struct {
	Pos     Pos
	Kind    AssertKind
	Path    *StringArg // file asserts only
	Text    string     // CONTAINS/DONT CONTAIN text, or the CMD string
	TextPos Pos
	Tier    string
	TierPos Pos
}
