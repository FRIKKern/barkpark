package pdrender

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// ── Go ⊇ Elixir block-type parity ────────────────────────────────────────────
// The Go registry is supposed to be a strict SUPERSET of the Elixir render
// surface: every block type Elixir can compose must have a Go renderer, or the
// TUI draws the "unknown block" box on a document the web renders fine. That
// premise was never asserted, and it was FALSE — `paper-links` shipped on the
// Elixir and React surfaces and was registered in no Go renderer at all,
// unknown-boxing 151 blocks across 145 of the 1050 published papers.
//
// The Elixir side is derived MECHANICALLY from
// api/lib/barkpark/portable_doc/tiers.ex at test time (its @element / @widget
// lists + the @section ~w sigil are exactly `Tiers.known_types/0`), so this test
// cannot go stale against a committed copy: a new Elixir block type lands in
// tiers.ex in the same change that adds it (tiers_test.exs enforces that against
// compose.ex), and this test reds until Go catches up.
//
// The reverse direction is REPORTED, not enforced: Go legitimately carries
// authoring-drift aliases (h1/h2/h3, the bulletList family, quote) and a couple
// of Go-only types, and deleting them would re-break live corpus content.

var elixirTypeLine = regexp.MustCompile(`"([^"\n]+)"`)

// elixirKnownTypes extracts Tiers.known_types() from the Elixir source.
func elixirKnownTypes(t *testing.T) map[string]bool {
	t.Helper()
	path := filepath.Join("..", "..", "api", "lib", "barkpark", "portable_doc", "tiers.ex")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the Elixir tier classification at %s: %v\n"+
			"This test cross-reads the api/ tree from the repo root; it cannot run against a Go-only checkout.", path, err)
	}
	src := string(raw)

	types := map[string]bool{}
	// @element [ … ] and @widget [ … ]: one quoted entry per line, `#` comments
	// interleaved (the append-friendly shape scaffy's classify-block-type edits).
	for _, attr := range []string{"@element", "@widget"} {
		start := strings.Index(src, attr+" [")
		if start < 0 {
			t.Fatalf("%s list not found in tiers.ex — the module shape changed; update this extractor", attr)
		}
		end := strings.Index(src[start:], "\n  ]")
		if end < 0 {
			t.Fatalf("%s list is unterminated in tiers.ex", attr)
		}
		for _, line := range strings.Split(src[start:start+end], "\n") {
			if i := strings.Index(line, "#"); i >= 0 {
				line = line[:i] // strip the trailing/leading comment
			}
			for _, m := range elixirTypeLine.FindAllStringSubmatch(line, -1) {
				types[m[1]] = true
			}
		}
	}
	// @section ~w(section columns tabs) — the deliberate one-line sigil.
	sec := regexp.MustCompile(`@section\s+~w\(([^)]*)\)`).FindStringSubmatch(src)
	if sec == nil {
		t.Fatal("@section ~w(...) sigil not found in tiers.ex — update this extractor")
	}
	for _, s := range strings.Fields(sec[1]) {
		types[s] = true
	}

	// NON-VACUITY: a regex that silently matched nothing would make every
	// assertion below pass. Pin a floor plus one anchor per tier list.
	if len(types) < 70 {
		t.Fatalf("extracted only %d Elixir block types — the extractor is broken, not the registry", len(types))
	}
	for _, anchor := range []string{"paragraph", "callout", "section", "paper-links"} {
		if !types[anchor] {
			t.Fatalf("extractor missed the known type %q — its regex no longer matches tiers.ex", anchor)
		}
	}
	return types
}

// TestGoRegistryCoversEveryElixirBlockType is the parity gate.
func TestGoRegistryCoversEveryElixirBlockType(t *testing.T) {
	elixir := elixirKnownTypes(t)
	goTypes := DefaultRegistry(DarkTheme()).blocks

	var missing []string
	for typ := range elixir {
		if _, ok := goTypes[typ]; !ok {
			missing = append(missing, typ)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("%d Elixir block type(s) have NO Go renderer — they unknown-box in the TUI: %s\n"+
			"Add a renderer in internal/pdrender and register it in DefaultRegistry.",
			len(missing), strings.Join(missing, ", "))
	}

	var extra []string
	for typ := range goTypes {
		if !elixir[typ] {
			extra = append(extra, typ)
		}
	}
	sort.Strings(extra)
	t.Logf("Elixir known_types: %d · Go registry: %d · Go-only (reported, not enforced — the "+
		"authoring-drift aliases and Go-only types): %s", len(elixir), len(goTypes), strings.Join(extra, ", "))
}
