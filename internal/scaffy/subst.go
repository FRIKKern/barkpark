package scaffy

// subst.go — the D37 runtime contract for --var values and the token
// substituter (engine forward path, W3). Every declared VARIABLE must
// be supplied; unknown, missing or newline-bearing values are usage
// errors (D33a — a multi-line value breaks the static-K extent rule
// for every future REANCHOR of the family). OPAQUE values substitute
// verbatim, never re-cased; SHAPE "ts14" is re-validated against the
// actual supplied value; SUCCESSOR pairs are CHECKED (after == before
// + 1, mirroring E-014), never computed. Transform variables resolve
// through words.go's package-private joiners — zero new exports.

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// VarError is a usage-class defect in the supplied --var set (missing,
// unknown, newline-bearing, shape or successor violations). The CLI
// maps it to exit 2 (D39).
type VarError struct {
	Msg string
}

func (e *VarError) Error() string { return e.Msg }

func varErrorf(format string, args ...any) *VarError {
	return &VarError{Msg: fmt.Sprintf(format, args...)}
}

// substituter resolves {{.Token}} occurrences to their replacement
// text. The map is keyed by token spelling: for a transform variable
// each of the four joiner spellings of the NAME maps to the same
// joiner's output over the VALUE's word list; for an OPAQUE variable
// every legal spelling maps to the verbatim value (D22/D37).
type substituter struct {
	repl map[string]string
}

// newSubstituter validates the supplied vars against the command's
// declarations (the full D37 contract) and builds the replacement map.
func newSubstituter(cmd *Command, vars map[string]string) (*substituter, error) {
	declared := map[string]*VariableDecl{}
	for _, v := range cmd.Variables {
		declared[v.Name] = v
	}

	// Unknown keys are usage errors — a silently ignored --var is a
	// typo that poisons the receipt key.
	for k := range vars {
		if _, ok := declared[k]; !ok {
			return nil, varErrorf("unknown --var %q: the command declares no such VARIABLE", k)
		}
	}

	s := &substituter{repl: map[string]string{}}
	for _, v := range cmd.Variables {
		value, ok := vars[v.Name]
		if !ok {
			return nil, varErrorf("missing --var %s: every declared VARIABLE is required", v.Name)
		}
		if strings.ContainsAny(value, "\r\n") {
			return nil, varErrorf("--var %s: value contains a newline — values must be single-line (D33a)", v.Name)
		}
		if v.Shape != "" {
			if err := checkShape(v, value); err != nil {
				return nil, err
			}
		}
		if len(v.OneOf) > 0 {
			if err := checkOneOf(v, value); err != nil {
				return nil, err
			}
		}
		if v.Successor != "" {
			if err := checkSuccessor(v, vars); err != nil {
				return nil, err
			}
		}

		ws := splitWords(v.Name)
		if v.Opaque {
			// OPAQUE: verbatim, never re-cased — whatever spelling the
			// file uses (it uses exactly one, E-013).
			for _, sp := range spellingsOf(ws) {
				if _, dup := s.repl[sp]; !dup {
					s.repl[sp] = value
				}
			}
			continue
		}
		vws := splitWords(value)
		// Deterministic joiner precedence for collapsed duplicates (a
		// one-word lowercase name has kebab == camel == snake): the
		// spellingsOf order — Pascal, kebab, camel, snake, SCREAMING —
		// first wins.
		type pair struct{ spelling, out string }
		for _, p := range []pair{
			{joinPascal(ws), joinPascal(vws)},
			{joinKebab(ws), joinKebab(vws)},
			{joinCamel(ws), joinCamel(vws)},
			{joinSnake(ws), joinSnake(vws)},
			{joinScreaming(ws), joinScreaming(vws)},
		} {
			if _, dup := s.repl[p.spelling]; !dup {
				s.repl[p.spelling] = p.out
			}
		}
	}
	return s, nil
}

// checkShape re-validates a SHAPE-annotated value at run time (D37 —
// E-013/014/015 lint declared EXAMPLES only; the engine owns the live
// value). The catalog knows one shape: ts14.
func checkShape(v *VariableDecl, value string) error {
	if v.Shape != "ts14" {
		return varErrorf("--var %s: unknown SHAPE %q", v.Name, v.Shape)
	}
	ok := len(value) == 14
	if ok {
		for i := 0; i < len(value); i++ {
			if value[i] < '0' || value[i] > '9' {
				ok = false
				break
			}
		}
	}
	if ok {
		if _, err := time.Parse("20060102150405", value); err != nil {
			ok = false
		}
	}
	if !ok {
		return varErrorf("--var %s: %q does not satisfy SHAPE ts14 — exactly 14 ASCII digits forming a real UTC YYYYMMDDHHMMSS instant (D22)", v.Name, value)
	}
	return nil
}

// checkOneOf enforces the D56 ONEOF constraint at run time: the supplied
// value must be a member of the declared set (mirroring checkShape — the
// lint reds declared EXAMPLES, the engine owns the live --var value). A
// non-member is a VarError, mapped to exit 2 like a SHAPE violation.
func checkOneOf(v *VariableDecl, value string) error {
	for _, m := range v.OneOf {
		if value == m {
			return nil
		}
	}
	members := `"` + strings.Join(v.OneOf, `", "`) + `"`
	return varErrorf("--var %s: %q is not one of ONEOF %s (D56)", v.Name, value, members)
}

// checkSuccessor enforces the D37 SUCCESSOR law: the caller supplies
// BOTH values and the engine CHECKS after == before + 1 — it never
// computes the successor silently.
func checkSuccessor(v *VariableDecl, vars map[string]string) error {
	sibValue, ok := vars[v.Successor]
	if !ok {
		return varErrorf("missing --var %s: SUCCESSOR pairs are supplied together, never computed (D37)", v.Successor)
	}
	after, errA := strconv.Atoi(strings.TrimSpace(vars[v.Name]))
	before, errB := strconv.Atoi(strings.TrimSpace(sibValue))
	if errA != nil || errB != nil {
		return varErrorf("--var %s/%s: SUCCESSOR pair values must be integers", v.Name, v.Successor)
	}
	if after != before+1 {
		return varErrorf("--var %s=%d is not --var %s=%d + 1 — the engine checks the pair, it never computes it (D37)", v.Name, after, v.Successor, before)
	}
	return nil
}

// text substitutes every token in one string. An unresolved token is a
// hard error carrying the source position — the validator pre-gate
// catches undeclared tokens, so hitting this means a spelling the
// declared variables cannot produce.
func (s *substituter) text(str, file string, line int) (string, error) {
	var bad string
	out := tokenRe.ReplaceAllStringFunc(str, func(m string) string {
		spelling := m[3 : len(m)-2] // {{.spelling}}
		if r, ok := s.repl[spelling]; ok {
			return r
		}
		if bad == "" {
			bad = spelling
		}
		return m
	})
	if bad != "" {
		return "", fmt.Errorf("%s:%d: token {{.%s}} does not resolve against the supplied vars", file, line, bad)
	}
	return out, nil
}

// fencedLines substitutes a fenced block line-by-line. Substitution is
// line-count-invariant (values are single-line, D33a) — the property
// the REANCHOR static-K extent rule rests on (D33).
func (s *substituter) fencedLines(f *Fenced, file string) ([]string, error) {
	if f == nil {
		return nil, nil
	}
	out := make([]string, len(f.Lines))
	for i, ln := range f.Lines {
		sub, err := s.text(ln, file, f.Pos.Line+1+i)
		if err != nil {
			return nil, err
		}
		out[i] = sub
	}
	return out, nil
}

// fencedBytes substitutes a fenced block and joins it to verbatim
// payload bytes (each line contributing its trailing newline, D26).
func (s *substituter) fencedBytes(f *Fenced, file string) ([]byte, error) {
	lines, err := s.fencedLines(f, file)
	if err != nil {
		return nil, err
	}
	return joinLines(lines), nil
}

// payloadTemplate resolves an op payload to its UNSUBSTITUTED fenced
// block — a direct fence, or the SNIPPET a USE names (D3(e)). The
// template's line count is the REANCHOR extent authority (D33).
func payloadTemplate(cmd *Command, pl *Payload) *Fenced {
	if pl == nil {
		return nil
	}
	if pl.Fenced != nil {
		return pl.Fenced
	}
	if sn := cmd.Snippet(pl.Use); sn != nil {
		return sn.Payload
	}
	return nil
}

// payloadBytes resolves an op payload (fenced or USE) to substituted
// verbatim bytes. An empty fence yields nil — the 0-byte file (D26).
func (s *substituter) payloadBytes(cmd *Command, pl *Payload, file string) ([]byte, error) {
	return s.fencedBytes(payloadTemplate(cmd, pl), file)
}

// joinLines joins payload lines to bytes, each line contributing its
// trailing newline (D26). Zero lines yield nil.
func joinLines(lines []string) []byte {
	if len(lines) == 0 {
		return nil
	}
	n := 0
	for _, l := range lines {
		n += len(l) + 1
	}
	b := make([]byte, 0, n)
	for _, l := range lines {
		b = append(b, l...)
		b = append(b, '\n')
	}
	return b
}
