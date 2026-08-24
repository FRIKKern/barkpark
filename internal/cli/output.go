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

	"github.com/FRIKKern/barkpark/internal/pdrender"
	"github.com/FRIKKern/barkpark/internal/semrole"

	"github.com/charmbracelet/lipgloss"
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

	// colorProfile is the terminal colour capability the status/lifecycle cell
	// painter degrades against (NoColor→ANSI16→ANSI256→TrueColor), resolved once in
	// resolveColorProfile. renderer is a lipgloss renderer bound to that profile so
	// the 256/truecolor rungs downsample deterministically; nil until resolved (and
	// unused on the pinned ANSI16 floor).
	colorProfile pdrender.Profile
	renderer     *lipgloss.Renderer

	// lastErrorCode is the `code` of the most recent API refusal handleResponse
	// classified, "" while nothing has failed. It exists for the client-side
	// wrappers that add a diagnosis on top of a failed manifest dispatch
	// (runTaskClaim): those get only an exit code back, and exit 6 covers SIX
	// distinct task-contention reasons whose explanations are not
	// interchangeable — a resource_conflict says nothing about the target row's
	// own claim, so the claim-state read-back must not speak for it.
	// Per-invocation, never a package global: one writer per bp run.
	lastErrorCode string
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
	if g.noColor || noColorEnv() {
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
	w.resolveColorProfile()
}

// resolveColorProfile picks the terminal colour profile the status/lifecycle cell
// painter degrades against — truecolor → 256 → 16 → none — REUSING the paper
// command's termenv machinery (paperResolveProfile/paperTermenvProfile) rather than
// standing up a second detection switch (charter Decision 3). Precedence: NO_COLOR
// and --no-color have already forced w.color off upstream and always win; otherwise
// BP_COLOR is the escape hatch, accepting the SAME alias vocabulary as `bp paper
// --profile` (truecolor/24bit/rgb, ansi256/256, ansi16/16, none/nocolor/plain,
// auto); with no BP_COLOR, auto keys off the tty exactly like paper — a tty ⇒ a
// SAFE ANSI256 (truecolor only when explicitly asked). BP_COLOR=none/plain is a
// valid off switch too. On any coloured profile it binds a lipgloss renderer to
// w.stdout at that profile so the 256/truecolor paint downsamples deterministically
// (termenv owns the 24-bit→256 step and adaptive light/dark selection).
func (w *writer) resolveColorProfile() {
	w.colorProfile = pdrender.NoColor
	if !w.color {
		return
	}
	profile := "auto"
	if bp := strings.TrimSpace(os.Getenv("BP_COLOR")); bp != "" {
		profile = bp
	}
	p := paperResolveProfile(profile, w.isTTY)
	if p == pdrender.NoColor {
		// BP_COLOR=none/plain (or auto over a non-tty) ⇒ colour off entirely.
		w.color = false
		return
	}
	w.colorProfile = p
	r := lipgloss.NewRenderer(w.stdout)
	r.SetColorProfile(paperTermenvProfile(p))
	w.renderer = r
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

// noColorEnv reports whether the NO_COLOR convention (https://no-color.org)
// disables color: the env var suppresses color whenever it is PRESENT, regardless
// of its value (an empty string still counts). This complements --no-color (the
// explicit flag) and the non-tty default (newWriter sets color from isatty), so a
// `NO_COLOR=1 bp cloud status` on a real terminal still emits plain text. Consulted
// once in applyGlobals — the single color-resolution seam.
func noColorEnv() bool {
	_, set := os.LookupEnv("NO_COLOR")
	return set
}

// paintCell wraps an already-padded table cell in the semantic colour of its
// status/lifecycle token, but ONLY when colour is enabled (a tty, not --no-color,
// not NO_COLOR) AND the bare value resolves to a token. The token is resolved from
// bare (the un-padded value, so a cell's trailing alignment spaces never defeat the
// match) through semrole.Color, which owns the Decision-4 precedence: a LIFECYCLE
// state paints its lifecycle hue FIRST — so `done`/`closed` are TEAL, not ok-green —
// and any other value routes to its ok/info/warn/danger status tone. The colour
// wraps the padded string so the column widths — measured on bare strings upstream —
// are untouched. With colour off it returns padded unchanged, keeping piped and
// --no-color output byte-for-byte identical to an uncoloured build (Decision 12). It
// is the one seam table.go and every cloud-status view share.
//
// The paint degrades down the resolved colour ladder (w.colorProfile): at
// TrueColor/ANSI256 the token's adaptive hex renders through the writer's bound
// lipgloss renderer, so termenv owns light/dark selection and the 24-bit→256
// downsample; at the ANSI16 floor it emits the PINNED semrole.GenANSI16 SGR for the
// value's status role (info=blue 34 — the deliberate cross-surface retint) rather
// than a lossy termenv downsample of the hex. Lifecycle states degrade to their
// status role at the floor (done→ok→green): 16 colours can't carry the teal hue.
func (w *writer) paintCell(padded, bare string) string {
	if !w.color {
		return padded
	}
	light, dark, colored := semrole.Color(bare)
	if !colored {
		return padded
	}
	// The ANSI16 floor — and the safe fallback when no higher-profile renderer is
	// bound — emits the PINNED role-keyed semrole.GenANSI16 codes directly, never a
	// termenv downsample of the hex. In production a coloured writer always binds a
	// renderer (resolveColorProfile); a nil renderer means an un-resolved writer, for
	// which the universally-safe basic-16 rung is the right default.
	if w.colorProfile == pdrender.ANSI16 || w.renderer == nil {
		if role := statusRole(bare); role != "" {
			if code, ok := semrole.GenANSI16[role]; ok {
				return fmt.Sprintf("\033[%dm%s%s", code, padded, ansiReset)
			}
		}
		return padded
	}
	return w.cellStyler().
		Foreground(lipgloss.AdaptiveColor{Light: light, Dark: dark}).
		Render(padded)
}

// cellStyler returns a lipgloss style bound to the writer's resolved colour
// profile (set in resolveColorProfile). A nil renderer — a writer that never
// resolved a profile — falls back to the package default so a bare style still
// renders; tests that exercise the 256/truecolor paint set w.renderer explicitly
// for byte-determinism.
func (w *writer) cellStyler() lipgloss.Style {
	if w.renderer != nil {
		return w.renderer.NewStyle()
	}
	return lipgloss.NewStyle()
}

// out writes a line to stdout.
func (w *writer) outf(format string, a ...any) {
	fmt.Fprintf(w.stdout, format+"\n", a...)
}

// errf writes a line to stderr.
func (w *writer) errf(format string, a ...any) {
	fmt.Fprintf(w.stderr, format+"\n", a...)
}

// userErr is the ONE seam for a human-facing CLI error line. It writes to stderr
// prefixed with the canonical `bp:` brand tag (the binary is `bp`), so the prefix
// literal lives in exactly one place — a rebrand is a one-line change and the
// whole CLI stays consistent. Continuation lines (hints, "  code:") deliberately
// carry NO prefix and stay on plain errf. Commands that carry an error `code` and
// want -o json|yaml parity route through useError / usageErrf / renderError
// instead, which emit the structured {ok:false,error:{…}} envelope on stdout;
// userErr is the human-mode fallback those helpers, and every prefix-only site,
// funnel through.
func (w *writer) userErr(format string, a ...any) {
	w.errf("bp: "+format, a...)
}

// machineOut reports whether the resolved output shape is a machine-readable one
// (json or yaml). Commands that interleave human progress with a final result —
// e.g. the multi-step `vercel quick-setup` provision — use it to decide between
// human chatter on stdout and a single structured envelope.
func (w *writer) machineOut() bool {
	return w.output == "json" || w.output == "yaml"
}

// progressf writes a human progress line. In machine-output mode (json/yaml) it
// routes to stderr so stdout stays a single parseable document that a scripted
// caller can consume; otherwise it writes to stdout exactly like outf, keeping
// the human view byte-identical.
func (w *writer) progressf(format string, a ...any) {
	if w.machineOut() {
		fmt.Fprintf(w.stderr, format+"\n", a...)
		return
	}
	fmt.Fprintf(w.stdout, format+"\n", a...)
}

// info writes to stderr only when verbose.
func (w *writer) info(format string, a ...any) {
	if w.verbose {
		fmt.Fprintf(w.stderr, format+"\n", a...)
	}
}

// renderJSON emits v as compact single-line JSON to stdout. Machine output
// carries no indentation — a 23-25% pure-whitespace tax every scripted consumer
// paid for nothing (AXI wave 2, charter decision 14). json.Encoder.Encode still
// appends a trailing newline, so the stream stays line-delimited.
func (w *writer) renderJSON(v any) {
	enc := json.NewEncoder(w.stdout)
	enc.SetEscapeHTML(false)
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

// renderRaw prints already-serialized JSON bytes, re-serialized compact for
// stability. Under an -o json contract stdout MUST always be valid JSON: a
// scripted caller piping to `jq`/`json.loads` breaks the moment a single invalid
// escape reaches the stream. So the not-JSON branch never dumps the bytes
// verbatim (the old behaviour, which handed jq an "Invalid escape" on any payload
// carrying an unescaped backslash sequence — bp-json-escape-emit-bug). Instead it
// re-encodes the raw payload as a JSON string — valid JSON, byte-for-byte
// recoverable — and flags the anomaly on stderr so the human still sees it while
// stdout stays parseable. renderJSON owns the escaping, so this round-trips every
// backslash/quote/control char into a legal document.
func (w *writer) renderRaw(b []byte) {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		w.errf("warning: response body was not valid JSON (%v); emitting it as a JSON string so -o json stays parseable", err)
		w.renderJSON(string(b))
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
