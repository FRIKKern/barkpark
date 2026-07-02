package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
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
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
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
	if k == "" || strings.ContainsAny(k, ":#{}[]&*!|>'\"%@`\n") || strings.TrimSpace(k) != k {
		b, _ := json.Marshal(k)
		return string(b)
	}
	return k
}

func isScalar(v any) bool {
	switch v.(type) {
	case map[string]any, []any:
		return false
	default:
		return true
	}
}

func scalarYAML(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		if t == "" || strings.ContainsAny(t, ":#{}[]&*!|>'\"%@`\n") || strings.TrimSpace(t) != t {
			b, _ := json.Marshal(t)
			return string(b)
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
