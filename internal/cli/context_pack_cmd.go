package cli

// context_pack_cmd.go — `bp context pack <file…>`: turn any set of files into
// an optical context bundle an agent can read for a fraction of the text-token
// price. A client-side builtin like cmux/mcp/onramp: `context` is not a
// manifest noun, so this intercept shadows nothing and needs no server change.
//
// The bundle is the two-channel posture validated by the optical-compression
// research arc (/papers/optical-compression-research-report):
//
//	├─▶ detector (context_detect.go) — entropy+regex, no model call
//	│     └─▶ verbatim.txt   exact bytes, authoritative
//	└─▶ everything else
//	      └─▶ page_N.png     paginated fixed-glyph render, every page
//	                         under the 2576px cap (context_render.go)
//
// Measured on real repo files: 3.2–4.7× fewer tokens than text at equal
// accuracy (21/21), with gist quote-grade. READ-ONLY BY DESIGN: a bundle is
// for consuming context, never for editing — Edit needs byte-exact strings an
// image cannot provide. Never bundle a file the agent will modify.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// contextBundleManifest is bundle.json: what was packed, at what cost, and the
// exact reading instruction a solver agent should receive.
type contextBundleManifest struct {
	Files         []string      `json:"files"`
	Outdir        string        `json:"outdir"`
	Pages         []contextPage `json:"pages"`
	Sidecar       string        `json:"sidecar,omitempty"`
	VerbatimCount int           `json:"verbatim_count"`
	Scale         float64       `json:"scale"`
	Glyph         string        `json:"glyph"`
	Tokens        struct {
		Bundle       int `json:"bundle"`
		Image        int `json:"image"`
		Sidecar      int `json:"sidecar"`
		TextBaseline int `json:"text_baseline"`
	} `json:"tokens"`
	Multiplier  float64 `json:"multiplier"`
	Instruction string  `json:"instruction"`
}

func runContextPack(out *writer, g globals, args []string) int {
	if g.help {
		printContextPackHelp(out)
		return exitOK
	}

	outdir := ""
	scale := ctxDefaultScale
	cols := ctxDefaultCols
	var files []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--out":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextPackHelp(out) }, "--out needs a directory")
			}
			i++
			outdir = args[i]
		case a == "--scale":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextPackHelp(out) }, "--scale needs a value in (0,1]")
			}
			i++
			v, err := strconv.ParseFloat(args[i], 64)
			if err != nil || v <= 0 || v > 1 {
				return usageErrf(out, func() { printContextPackHelp(out) }, "--scale must be a number in (0,1], got %q", args[i])
			}
			scale = v
		case a == "--cols":
			if i+1 >= len(args) {
				return usageErrf(out, func() { printContextPackHelp(out) }, "--cols needs a positive integer")
			}
			i++
			v, err := strconv.Atoi(args[i])
			if err != nil || v < 20 {
				return usageErrf(out, func() { printContextPackHelp(out) }, "--cols must be an integer >= 20, got %q", args[i])
			}
			cols = v
		case strings.HasPrefix(a, "-"):
			return usageErrf(out, func() { printContextPackHelp(out) },
				"unknown flag %q (context pack accepts --out, --scale, --cols)", a)
		default:
			files = append(files, a)
		}
	}
	if len(files) == 0 {
		return usageErrf(out, func() { printContextPackHelp(out) }, "context pack needs at least one file")
	}

	// Concatenate inputs with FILE separators (multi-file bundles keep
	// provenance visible in the image, like the research tier packs).
	var body strings.Builder
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			out.userErr("context pack: %v", err)
			return exitGeneric
		}
		if len(files) > 1 {
			fmt.Fprintf(&body, "===== FILE: %s =====\n", f)
		}
		body.Write(data)
		if len(data) > 0 && data[len(data)-1] != '\n' {
			body.WriteByte('\n')
		}
	}
	text := body.String()

	if outdir == "" {
		outdir = files[0] + ".bundle"
	}
	if err := os.MkdirAll(outdir, 0o755); err != nil {
		out.userErr("context pack: %v", err)
		return exitGeneric
	}

	lines := wrapContextLines(text, cols)
	verbatim := detectVerbatim(lines)

	pages, err := renderContextBundle(lines, scale, outdir)
	if err != nil {
		out.userErr("context pack: %v", err)
		return exitGeneric
	}

	var man contextBundleManifest
	man.Files = files
	man.Outdir = outdir
	man.Pages = pages
	man.VerbatimCount = len(verbatim)
	man.Scale = scale
	man.Glyph = fmt.Sprintf("7x13@%.2f", scale)
	for _, p := range pages {
		man.Tokens.Image += p.Tokens
	}
	if len(verbatim) > 0 {
		var side strings.Builder
		side.WriteString("EXACT VERBATIM STRINGS (authoritative — use these for any exact value;\n")
		side.WriteString("the image may have blurred them). Line numbers index the packed body:\n")
		for _, v := range verbatim {
			fmt.Fprintf(&side, "[L%d] %s\n", v.Index, v.Line)
		}
		if err := os.WriteFile(filepath.Join(outdir, "verbatim.txt"), []byte(side.String()), 0o644); err != nil {
			out.userErr("context pack: %v", err)
			return exitGeneric
		}
		man.Sidecar = "verbatim.txt"
		man.Tokens.Sidecar = (side.Len() + ctxTextTokenDivisor - 1) / ctxTextTokenDivisor
	}
	man.Tokens.Bundle = man.Tokens.Image + man.Tokens.Sidecar
	man.Tokens.TextBaseline = (len(text) + ctxTextTokenDivisor - 1) / ctxTextTokenDivisor
	if man.Tokens.Bundle > 0 {
		man.Multiplier = float64(man.Tokens.TextBaseline) / float64(man.Tokens.Bundle)
		man.Multiplier = float64(int(man.Multiplier*100+0.5)) / 100
	}
	man.Instruction = contextReadInstruction(man)

	manJSON, err := json.MarshalIndent(man, "", " ")
	if err != nil {
		out.userErr("context pack: %v", err)
		return exitGeneric
	}
	if err := os.WriteFile(filepath.Join(outdir, "bundle.json"), manJSON, 0o644); err != nil {
		out.userErr("context pack: %v", err)
		return exitGeneric
	}

	if out.machineOut() {
		out.renderJSON(man)
		return exitOK
	}
	out.outf("packed %d file(s) → %s\n", len(files), outdir)
	out.outf("  %d page(s), %d verbatim line(s) sidecar-routed, glyph %s\n",
		len(man.Pages), man.VerbatimCount, man.Glyph)
	out.outf("  bundle %d tok vs text %d tok = %.2f× cheaper\n",
		man.Tokens.Bundle, man.Tokens.TextBaseline, man.Multiplier)
	out.outf("\n%s\n", man.Instruction)
	return exitOK
}

// contextReadInstruction is the exact prompt block a consumer pastes in front
// of a solver agent so both channels are read correctly.
func contextReadInstruction(man contextBundleManifest) string {
	var b strings.Builder
	b.WriteString("READING INSTRUCTION (paste before the agent's question):\n")
	fmt.Fprintf(&b, "The context is a packed bundle with %d image page(s) picturing the full text. Read EACH page in order with the Read tool:\n", len(man.Pages))
	for _, p := range man.Pages {
		fmt.Fprintf(&b, "  %s\n", filepath.Join(man.Outdir, p.Name))
	}
	if man.Sidecar != "" {
		b.WriteString("Exact strings (secrets, hashes, ids, URLs) are in a TEXT sidecar — for ANY exact value trust it over the image:\n")
		fmt.Fprintf(&b, "  %s\n", filepath.Join(man.Outdir, man.Sidecar))
	}
	b.WriteString("This bundle is READ-ONLY context: to edit any packed file, open the original file as text.")
	return b.String()
}

func printContextPackHelp(out *writer) {
	out.outf(`usage: bp context pack <file…> [--out <dir>] [--scale <0-1>] [--cols <n>]

Pack files into an optical context bundle: paginated PNG pages (each under the
provider's 2576px image cap) plus a text sidecar carrying every line the
deterministic detector flags as verbatim-critical (secrets, hashes, ids, URLs,
sign-off codes). Agents Read the pages + sidecar instead of the raw text, at
3.2-4.7x fewer input tokens on real repo files at equal measured accuracy
(research: /papers/optical-compression-research-report).

  --out <dir>    output directory (default: <first-file>.bundle)
  --scale <f>    glyph scale in (0,1] (default %.2f — the validated operating
                 point; smaller is cheaper but 0.30-equivalent starts to flicker)
  --cols <n>     hard-wrap width for long lines (default %d)

The bundle directory holds page_N.png, verbatim.txt (when anything was
flagged), and bundle.json (token ledger + the reading instruction, also
printed on stdout; -o json emits the manifest).

READ-ONLY BY DESIGN: never bundle a file the agent will edit — editing needs
byte-exact text the image cannot provide. Bundle for reading; open originals
for writing. Not yet suited to: log triage (exact-string-dense) or unanchored
large counts.
`, ctxDefaultScale, ctxDefaultCols)
}
