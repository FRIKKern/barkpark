package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/mattn/go-isatty"
)

// writer wraps the CLI's stdout/stderr with resolved output settings. It is the
// single place that knows the chosen output shape, the tty-vs-pipe default, and
// the no-color decision. Every command writes through it so the rendering rules
// live in one spot.
type writer struct {
	stdout io.Writer
	stderr io.Writer

	output         string // resolved: table | json | yaml | minimal
	outputExplicit bool   // true when the user passed -o/--output/--json
	color          bool
	quiet          bool
	verbose        bool
	isTTY          bool
}

func newWriter(stdout, stderr io.Writer) *writer {
	tty := false
	if f, ok := stdout.(*os.File); ok {
		tty = isatty.IsTerminal(f.Fd())
	}
	return &writer{
		stdout: stdout,
		stderr: stderr,
		output: "", // resolved in applyGlobals/resolveOutput
		color:  tty,
		isTTY:  tty,
	}
}

// applyGlobals folds the parsed globals into the writer's render settings.
// Output resolution: an explicit -o/--output/--json wins; otherwise the default
// is table on a tty and json when piped (so `barkpark doc ls post | jq` Just
// Works). A per-command default_output can still override later via
// resolveOutputForCommand.
func (w *writer) applyGlobals(g globals) {
	w.quiet = g.quiet
	w.verbose = g.verbose
	if g.noColor {
		w.color = false
	}
	w.outputExplicit = g.outputSet
	if g.outputSet {
		w.output = g.output
	} else if w.isTTY {
		w.output = "table"
	} else {
		w.output = "json"
	}
}

// resolveOutputForCommand lets a command's manifest default_output take effect
// ONLY when the user did not explicitly choose an output. For a write with
// default_output "minimal" and no -o flag, the receipt shape is minimal.
func (w *writer) resolveOutputForCommand(g globals, cmdDefault string) {
	if g.outputSet {
		return
	}
	if g.quiet {
		w.output = "minimal"
		return
	}
	if cmdDefault != "" && !w.isTTY {
		// Piped: still prefer json for machine consumption unless the command is
		// minimal-by-default (writes), where the receipt is the right shape.
		if cmdDefault == "minimal" {
			w.output = "minimal"
		}
		return
	}
	if cmdDefault != "" && w.isTTY {
		w.output = cmdDefault
	}
}

// out writes a line to stdout.
func (w *writer) outf(format string, a ...any) {
	fmt.Fprintf(w.stdout, format+"\n", a...)
}

// errf writes a line to stderr.
func (w *writer) errf(format string, a ...any) {
	fmt.Fprintf(w.stderr, format+"\n", a...)
}

// info writes to stderr only when verbose.
func (w *writer) info(format string, a ...any) {
	if w.verbose {
		fmt.Fprintf(w.stderr, format+"\n", a...)
	}
}

// renderJSON pretty-prints v as stable JSON to stdout.
func (w *writer) renderJSON(v any) {
	enc := json.NewEncoder(w.stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// jsonQuote returns s as a JSON double-quoted string WITHOUT HTML-escaping, so
// content like `<p>` and `a & b` survives verbatim in machine output. It is the
// keyYAML/scalarYAML quoting primitive; json.Marshal cannot be used because it
// always HTML-escapes <, >, and &.
func jsonQuote(s string) string {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	return strings.TrimRight(b.String(), "\n")
}

// emitStructured renders payload in whichever machine-readable shape the user
// asked for — json or yaml — and reports whether it handled the output. It is
// the single seam commands use to honour BOTH -o json and -o yaml from one call
// site: `if out.emitStructured(payload) { return exitOK }` before the human/table
// fallback, so yaml is never silently downgraded to the human view. table/minimal
// return false so the caller falls through to its own rendering.
func (w *writer) emitStructured(payload map[string]any) bool {
	switch w.output {
	case "json":
		w.renderJSON(payload)
		return true
	case "yaml":
		w.renderYAML(toGeneric(payload))
		return true
	}
	return false
}

// renderRaw prints already-serialized JSON bytes, re-indented for stability. If
// the bytes are not valid JSON it prints them verbatim.
func (w *writer) renderRaw(b []byte) {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		fmt.Fprintln(w.stdout, string(b))
		return
	}
	w.renderJSON(v)
}

// renderYAML emits v as YAML. Hand-rolled (no yaml dependency in go.mod): it
// covers the JSON-shaped value space the API returns — maps, slices, scalars.
// Map keys are sorted for stable output.
func (w *writer) renderYAML(v any) {
	var sb strings.Builder
	emitYAML(&sb, v, 0, false)
	fmt.Fprint(w.stdout, sb.String())
}

func emitYAML(sb *strings.Builder, v any, indent int, inline bool) {
	pad := strings.Repeat("  ", indent)
	switch t := v.(type) {
	case map[string]any:
		if len(t) == 0 {
			sb.WriteString("{}\n")
			return
		}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			child := t[k]
			if isScalar(child) {
				fmt.Fprintf(sb, "%s%s: %s\n", pad, keyYAML(k), scalarYAML(child))
			} else if flow := emptyContainerYAML(child); flow != "" {
				// An empty map/slice VALUE must render inline (`key: {}`), not as
				// a `key:\n` header followed by a detached `{}` at column 0 — that
				// parses as `key: null` plus a stray root node (data loss).
				fmt.Fprintf(sb, "%s%s: %s\n", pad, keyYAML(k), flow)
			} else {
				fmt.Fprintf(sb, "%s%s:\n", pad, keyYAML(k))
				emitYAML(sb, child, indent+1, false)
			}
		}
	case []any:
		if len(t) == 0 {
			sb.WriteString("[]\n")
			return
		}
		for _, item := range t {
			if isScalar(item) {
				fmt.Fprintf(sb, "%s- %s\n", pad, scalarYAML(item))
			} else if flow := emptyContainerYAML(item); flow != "" {
				fmt.Fprintf(sb, "%s- %s\n", pad, flow)
			} else {
				fmt.Fprintf(sb, "%s-\n", pad)
				emitYAML(sb, item, indent+1, false)
			}
		}
	default:
		fmt.Fprintf(sb, "%s%s\n", pad, scalarYAML(v))
	}
}

// keyYAML quotes a map key that would otherwise produce malformed YAML. A key
// carrying an indicator char (a colon, comment #, flow punctuation, etc.) or
// leading/trailing whitespace is emitted as a JSON-marshalled (double-quoted)
// string — the same escaping scalarYAML applies to values.
func keyYAML(k string) string {
	if k == "" || strings.ContainsAny(k, ":#{}[]&*!|>'\"%@`\n") || strings.TrimSpace(k) != k || looksLikeYAMLScalar(k) {
		return jsonQuote(k)
	}
	return k
}

// looksLikeYAMLScalar reports whether the string s, emitted BARE, would be
// re-typed by a YAML consumer (yq, PyYAML) as a NON-string scalar — a bool,
// null, or number — rather than the string it is. This is the classic "Norway
// problem": the string "no" reads back as the boolean false, "0755" as an
// integer, "123" as a number — silent data corruption in machine output.
// scalarYAML/keyYAML double-quote any such string so it round-trips as a string;
// genuine bool/float64 values (their own scalarYAML branches) stay bare.
func looksLikeYAMLScalar(s string) bool {
	switch strings.ToLower(s) {
	case "true", "false", "yes", "no", "on", "off", "null", "~":
		return true
	}
	if _, err := strconv.ParseFloat(s, 64); err == nil {
		return true
	}
	// A leading-zero all-digit run (0755) parses as decimal via ParseFloat above,
	// but be explicit: a YAML 1.1 reader may treat it as octal, so quote it.
	if len(s) > 1 && s[0] == '0' {
		allDigit := true
		for _, r := range s {
			if r < '0' || r > '9' {
				allDigit = false
				break
			}
		}
		if allDigit {
			return true
		}
	}
	return false
}

func isScalar(v any) bool {
	switch v.(type) {
	case map[string]any, []any:
		return false
	default:
		return true
	}
}

// emptyContainerYAML returns the YAML flow scalar ("{}" or "[]") for an empty
// map/slice, or "" for anything else. An empty container as a nested value must
// be emitted inline next to its key/dash — writing `key:` then recursing emits a
// detached `{}` at column 0, which reparses as `key: null` + a stray root node.
func emptyContainerYAML(v any) string {
	switch t := v.(type) {
	case map[string]any:
		if len(t) == 0 {
			return "{}"
		}
	case []any:
		if len(t) == 0 {
			return "[]"
		}
	}
	return ""
}

func scalarYAML(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		if t == "" || strings.ContainsAny(t, ":#{}[]&*!|>'\"%@`\n") || strings.TrimSpace(t) != t || looksLikeYAMLScalar(t) {
			return jsonQuote(t)
		}
		return t
	case float64:
		// JSON numbers decode to float64; print ints without a trailing .0.
		// Guard the int64 conversion against overflow (mirrors pdrender toStr).
		if t == math.Trunc(t) && t >= math.MinInt64 && t < math.MaxInt64 {
			return fmt.Sprintf("%d", int64(t))
		}
		return fmt.Sprintf("%g", t)
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", t)
	}
}
