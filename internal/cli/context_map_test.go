package cli

// context_map_test.go — unit + end-to-end coverage for `bp context map`.
//
// Three properties carry the command, and each has a detector here:
//
//	extractPolarity   every trust-boundary sentence survives VERBATIM
//	gistWithin        compression drops whole sentences, never cuts one
//	mineEdges         a relation is emitted only where it was OBSERVED
//
// Plus the artifact contract (page_N.png + <kw>.laws.txt + map.json, with
// every law word-for-word from its source sentence — normalizeWS is the only
// transform — and every edge re-derivable at the file:line it names) and the
// empty-read refusal.

import (
	"encoding/json"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testPolarityDoc = `The beacon relays heartbeats to the collector.
A caller MUST NOT invoke flush/1 from inside a transaction.
It is tuned for throughput.
This module never retries a rejected frame.
Only the supervisor may restart the relay.`

// TestExtractPolarityCapturesEveryBoundarySentenceVerbatim is the detector for
// the laws channel: a MUST NOT / never / only sentence must come back whole and
// unabridged, and an ordinary sentence must not come back at all. (The
// wrapped-sentence shape lives in TestLawsAreVerbatimModuloWhitespace.)
func TestExtractPolarityCapturesEveryBoundarySentenceVerbatim(t *testing.T) {
	got := extractPolarity(testPolarityDoc)
	want := []string{
		"A caller MUST NOT invoke flush/1 from inside a transaction.",
		"This module never retries a rejected frame.",
		"Only the supervisor may restart the relay.",
	}
	if len(got) != len(want) {
		t.Fatalf("extractPolarity returned %d sentence(s), want %d: %q", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("law %d:\n got %q\nwant %q", i, got[i], want[i])
		}
	}
	for _, g := range got {
		if !strings.Contains(testPolarityDoc, g) {
			t.Errorf("law %q is not a verbatim substring of the source doc", g)
		}
		if strings.Contains(g, "tuned for throughput") {
			t.Errorf("neutral prose leaked into the laws: %q", g)
		}
	}
}

// TestGistWithinCutsOnlyAtSentenceBoundaries is the detector for law (1): a
// gist that ends mid-clause inverts the rule it was compressing, so the
// compressor may only drop WHOLE trailing sentences.
func TestGistWithinCutsOnlyAtSentenceBoundaries(t *testing.T) {
	doc := "One. Two is a little longer. Three is longer again and pushes past. Four."
	sents := splitSentences(doc)
	for budget := 1; budget <= len(doc)+10; budget++ {
		gist, truncated := gistWithin(doc, budget)
		if gist == "" {
			t.Fatalf("budget %d: empty gist from a non-empty doc", budget)
		}
		// The gist must be exactly the join of a non-empty PREFIX of sentences.
		n := 0
		for n < len(sents) && strings.Join(sents[:n+1], " ") != gist {
			n++
		}
		if n >= len(sents) {
			t.Fatalf("budget %d: gist %q is not a whole-sentence prefix of %q", budget, gist, sents)
		}
		if wantTrunc := n+1 < len(sents); truncated != wantTrunc {
			t.Errorf("budget %d: truncated=%v, want %v", budget, truncated, wantTrunc)
		}
	}
	// The one sentence that cannot fit ships whole and over budget rather than
	// cut: a long correct gist beats a short wrong one.
	long := "A caller MUST NOT invoke flush/1 from inside a transaction."
	gist, _ := gistWithin(long, 10)
	if gist != long {
		t.Errorf("an over-budget first sentence must ship whole, got %q", gist)
	}
}

// TestMineEdgesEmitsOnlyObservedReferences is the detector for the zero-
// invention property: every edge names a file and a 1-based line, the symbol
// is actually on that line, and no edge appears in the direction nobody wrote.
func TestMineEdgesEmitsOnlyObservedReferences(t *testing.T) {
	sources := map[string]string{
		"lib/relay.ex": "defmodule Beacon.Relay do\n  @moduledoc \"\"\"\n  Relay.\n  \"\"\"\n  def send(f), do: Beacon.Collector.take(f)\nend\n",
		"lib/coll.ex":  "defmodule Beacon.Collector do\n  def take(f), do: f\nend\n",
	}
	nodes := []mapNode{
		mineNode("lib/relay.ex", sources["lib/relay.ex"]),
		mineNode("lib/coll.ex", sources["lib/coll.ex"]),
	}
	edges := mineEdges(nodes, sources)
	if len(edges) != 1 {
		t.Fatalf("want exactly the one written reference, got %d: %+v", len(edges), edges)
	}
	e := edges[0]
	if e.From != "lib/relay.ex" || e.To != "lib/coll.ex" {
		t.Fatalf("edge direction is invented: %+v", e)
	}
	if e.Via != "Beacon.Collector" {
		t.Errorf("via %q, want the symbol actually written", e.Via)
	}
	lines := strings.Split(sources[e.From], "\n")
	if e.Line < 1 || e.Line > len(lines) || !strings.Contains(lines[e.Line-1], e.Via) {
		t.Errorf("edge cites %s:%d but %q is not on that line", e.From, e.Line, e.Via)
	}

	// A symbol two nodes both own is AMBIGUOUS and must be dropped, not
	// guessed at — a mis-bound edge is the invented relation this command
	// exists to avoid.
	amb := map[string]string{
		"a.ex": "defmodule A do\n  def shared(x), do: x\nend\n",
		"b.ex": "defmodule B do\n  def shared(x), do: x\nend\n",
		"c.ex": "defmodule C do\n  def go(x), do: shared(x)\nend\n",
	}
	var ambNodes []mapNode
	for _, p := range []string{"a.ex", "b.ex", "c.ex"} {
		ambNodes = append(ambNodes, mineNode(p, amb[p]))
	}
	for _, e := range mineEdges(ambNodes, amb) {
		if e.Via == "shared" {
			t.Errorf("an ambiguous symbol produced an edge: %+v", e)
		}
	}
}

// beaconTree writes a small two-module epic and returns its root.
func beaconTree(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	lib := filepath.Join(dir, "lib")
	if err := os.MkdirAll(lib, 0o755); err != nil {
		t.Fatal(err)
	}
	relay := "defmodule Beacon.Relay do\n  @moduledoc \"\"\"\n" +
		"  Relays heartbeat frames from edge nodes to the collector.\n" +
		"  A caller MUST NOT invoke flush/1 from inside a transaction.\n" +
		"  It buffers up to one second of frames so a slow collector does not stall the edge, which is the whole reason this module exists at all rather than a direct call.\n" +
		"  Only the supervisor may restart the relay.\n" +
		"  \"\"\"\n  def send(f), do: Beacon.Collector.take(f)\n  def flush, do: :ok\nend\n"
	coll := "defmodule Beacon.Collector do\n  @moduledoc \"\"\"\n" +
		"  Accepts frames and writes them to the store.\n" +
		"  This module never retries a rejected frame.\n" +
		"  \"\"\"\n  def take(f), do: f\nend\n"
	if err := os.WriteFile(filepath.Join(lib, "beacon_relay.ex"), []byte(relay), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(lib, "beacon_collector.ex"), []byte(coll), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// TestContextMapEndToEnd is the artifact-contract detector: the three files
// exist, every law is a verbatim sentence of its source, every gist is a
// whole-sentence prefix of its moduledoc, and every edge is re-derivable at
// the line it cites.
func TestContextMapEndToEnd(t *testing.T) {
	root := beaconTree(t)
	outdir := filepath.Join(t.TempDir(), "atlas")

	out, _, _ := newTestWriter()
	if code := runContextMap(out, globals{}, []string{"beacon", "--root", root, "--out", outdir}); code != exitOK {
		t.Fatalf("exit %d, want %d", code, exitOK)
	}

	raw, err := os.ReadFile(filepath.Join(outdir, "map.json"))
	if err != nil {
		t.Fatalf("map.json missing: %v", err)
	}
	var man contextMapManifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatalf("map.json not valid JSON: %v", err)
	}
	if len(man.Pages) == 0 {
		t.Fatal("no page emitted")
	}
	for _, p := range man.Pages {
		f, err := os.Open(filepath.Join(outdir, p.Name))
		if err != nil {
			t.Fatalf("%s missing: %v", p.Name, err)
		}
		cfg, err := png.DecodeConfig(f)
		f.Close()
		if err != nil {
			t.Fatalf("%s is not a decodable PNG: %v", p.Name, err)
		}
		if cfg.Width != p.Width || cfg.Height != p.Height {
			t.Errorf("%s: manifest says %dx%d, file is %dx%d", p.Name, p.Width, p.Height, cfg.Width, cfg.Height)
		}
	}

	lawsPath := filepath.Join(outdir, "beacon.laws.txt")
	lawsRaw, err := os.ReadFile(lawsPath)
	if err != nil {
		t.Fatalf("beacon.laws.txt missing: %v", err)
	}
	laws := string(lawsRaw)
	// EVERY polarity sentence of EVERY mined moduledoc, verbatim.
	for _, want := range []string{
		"A caller MUST NOT invoke flush/1 from inside a transaction.",
		"Only the supervisor may restart the relay.",
		"This module never retries a rejected frame.",
	} {
		if !strings.Contains(laws, want) {
			t.Errorf("laws sidecar is missing the verbatim sentence %q", want)
		}
	}
	if man.Laws.Count != 3 {
		t.Errorf("map.json says %d laws, want 3", man.Laws.Count)
	}
	if !strings.Contains(laws, "THIS FILE WINS") {
		t.Error("laws sidecar does not state that it wins over the image")
	}

	// Gists cut at sentence boundaries only: the gist is exactly the join of a
	// whole-sentence PREFIX of the mined doc. (Not "ends with a period" — a
	// source sentence that carries no terminator is still a whole unit, and
	// asserting the terminator would red on real files that end in a colon.)
	for _, n := range man.Nodes {
		if n.Gist == "" {
			continue
		}
		src, err := os.ReadFile(n.Path)
		if err != nil {
			t.Fatal(err)
		}
		sents := splitSentences(mineModuleDoc(n.Path, string(src)))
		ok := false
		for i := 1; i <= len(sents); i++ {
			if strings.Join(sents[:i], " ") == n.Gist {
				ok = true
				break
			}
		}
		if !ok {
			t.Errorf("%s: gist is not a whole-sentence prefix of the moduledoc — something was cut mid-sentence: %q", n.Path, n.Gist)
		}
	}
	if man.Nodes[0].GistTruncated == man.Nodes[1].GistTruncated {
		// One doc is deliberately over budget and one under; if both agree the
		// fixture stopped exercising the truncation path.
		t.Errorf("fixture no longer exercises both truncation outcomes: %v/%v",
			man.Nodes[0].GistTruncated, man.Nodes[1].GistTruncated)
	}

	// Every edge is re-derivable at the file:line it names.
	if len(man.Edges) == 0 {
		t.Fatal("no edges observed between two modules that reference each other")
	}
	for _, e := range man.Edges {
		src, err := os.ReadFile(e.From)
		if err != nil {
			t.Fatalf("edge cites unreadable file %s: %v", e.From, err)
		}
		lines := strings.Split(string(src), "\n")
		if e.Line < 1 || e.Line > len(lines) || !strings.Contains(lines[e.Line-1], e.Via) {
			t.Errorf("INVENTED EDGE: %s -> %s claims %q at %s:%d, not there",
				e.From, e.To, e.Via, e.From, e.Line)
		}
	}

	if !strings.Contains(man.Instruction, "VERIFY BEFORE YOU ASSERT") {
		t.Error("reading instruction omits the verify-before-assert line")
	}
	if !strings.Contains(man.Instruction, "beacon.laws.txt") {
		t.Error("reading instruction does not point at the laws sidecar")
	}
}

// TestContextMapRefusesEmptyMatch is the detector for the confident zero: a
// keyword nothing mentions must ERROR, because an atlas of 0 nodes reads
// exactly like a scan that failed to read anything.
func TestContextMapRefusesEmptyMatch(t *testing.T) {
	root := beaconTree(t)
	outdir := filepath.Join(t.TempDir(), "atlas")

	out, _, errBuf := newTestWriter()
	code := runContextMap(out, globals{}, []string{"quasarhydrant", "--root", root, "--out", outdir})
	if code == exitOK {
		t.Fatal("a keyword matching nothing exited OK — an empty atlas was emitted as if it were a result")
	}
	if !strings.Contains(errBuf.String(), "refusing to emit an empty atlas") {
		t.Errorf("refusal does not say why: %q", errBuf.String())
	}
	if _, err := os.Stat(filepath.Join(outdir, "map.json")); err == nil {
		t.Error("a refused map still wrote map.json")
	}
}

// TestContextMapIsDeterministic pins the property every golden that quotes
// this output depends on: two runs of the same tree produce byte-identical
// ledgers and laws.
func TestContextMapIsDeterministic(t *testing.T) {
	root := beaconTree(t)
	read := func() (string, string) {
		outdir := filepath.Join(t.TempDir(), "atlas")
		out, _, _ := newTestWriter()
		if code := runContextMap(out, globals{}, []string{"beacon", "--root", root, "--out", outdir}); code != exitOK {
			t.Fatalf("exit %d", code)
		}
		m, err := os.ReadFile(filepath.Join(outdir, "map.json"))
		if err != nil {
			t.Fatal(err)
		}
		l, err := os.ReadFile(filepath.Join(outdir, "beacon.laws.txt"))
		if err != nil {
			t.Fatal(err)
		}
		// outdir differs per run by construction; normalise it away.
		return strings.ReplaceAll(string(m), outdir, "<OUT>"), string(l)
	}
	m1, l1 := read()
	m2, l2 := read()
	if m1 != m2 {
		t.Error("map.json is not stable across runs — any golden quoting it would flap")
	}
	if l1 != l2 {
		t.Error("laws sidecar is not stable across runs")
	}
}

// TestContextMapIsRegisteredAsABuiltin — a verb that runs must be a verb the
// help prints (the nounBuiltins contract).
func TestContextMapIsRegisteredAsABuiltin(t *testing.T) {
	if _, ok := lookupNounBuiltin("context", "map", globals{}, nil); !ok {
		t.Fatal("`context map` is not in nounBuiltins — it would run without ever being printed")
	}
}

// TestLawsAreVerbatimModuloWhitespace pins what "verbatim" means on the shape
// that actually dominates the repo: a polarity sentence wrapped across several
// indented moduledoc lines. Every word, in order, nothing dropped — only the
// line breaks are collapsed. A live `cmux` atlas has 102 of its 137 laws in
// this shape, so a fixture of single-line sentences alone would prove nothing.
func TestLawsAreVerbatimModuloWhitespace(t *testing.T) {
	src := "defmodule Wrapped do\n  @moduledoc \"\"\"\n" +
		"  A caller MUST NOT invoke flush/1 from inside a\n" +
		"  transaction, because the collector takes the same\n" +
		"  lock and the pair deadlocks.\n" +
		"  \"\"\"\n  def flush, do: :ok\nend\n"
	laws := extractPolarity(mineModuleDoc("w.ex", src))
	if len(laws) != 1 {
		t.Fatalf("want 1 law from the wrapped sentence, got %d: %q", len(laws), laws)
	}
	want := "A caller MUST NOT invoke flush/1 from inside a transaction, because the collector takes the same lock and the pair deadlocks."
	if laws[0] != want {
		t.Errorf("wrapped law was not reassembled whole:\n got %q\nwant %q", laws[0], want)
	}
	if !strings.Contains(normalizeWS(src), normalizeWS(laws[0])) {
		t.Error("law is not a whitespace-normalised substring of its source — it was reworded, not copied")
	}
	// Non-vacuity: the assertion must be able to fail. A law with one word
	// dropped is NOT a normalised substring.
	tampered := strings.Replace(laws[0], "MUST NOT ", "MUST ", 1)
	if strings.Contains(normalizeWS(src), normalizeWS(tampered)) {
		t.Fatal("the verbatim check accepts a sentence with a word removed — it proves nothing")
	}
}

// TestContextMapOnLiveRepoInventsNothing is the end-to-end proof run against
// REAL source instead of a fixture: it maps the `cmux` area of internal/ and
// re-derives every claim the atlas makes.
//
// A fixture cannot prove this. The fixture's moduledocs are single-line
// sentences; the repo's are wrapped across indented `//` and heredoc lines,
// and the FIRST live run of this command produced 102 "laws" that were not
// substrings of their own files — the reassembly was fine, the CLAIM
// ("verbatim" meaning byte-identical to the file) was wrong. The property that
// actually holds, and the one a consumer can re-derive, is stated against the
// MINED MODULEDOC: extract it, collapse whitespace, and the law is in there.
//
// Three assertions, all re-derivations rather than restatements:
//   - every edge: open From at Line and Via is on it (zero invented relations)
//   - every law: word-for-word inside its own moduledoc
//   - every gist: a whole-sentence PREFIX of that moduledoc (nothing cut)
func TestContextMapOnLiveRepoInventsNothing(t *testing.T) {
	root := ".." // the internal/ tree, from this package's directory
	if _, err := os.Stat(filepath.Join(root, "cli", "cmux_cmd.go")); err != nil {
		t.Skipf("live tree not present (%v)", err)
	}
	outdir := filepath.Join(t.TempDir(), "atlas")
	out, _, _ := newTestWriter()
	if code := runContextMap(out, globals{}, []string{"cmux", "--root", root, "--out", outdir}); code != exitOK {
		t.Fatalf("exit %d, want %d", code, exitOK)
	}
	raw, err := os.ReadFile(filepath.Join(outdir, "map.json"))
	if err != nil {
		t.Fatal(err)
	}
	var man contextMapManifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatal(err)
	}
	// Non-vacuity: a green over an empty atlas would prove nothing at all.
	if len(man.Nodes) < 3 || len(man.Edges) < 3 || man.Laws.Count < 3 {
		t.Fatalf("live atlas is too thin to prove anything: %d nodes, %d edges, %d laws",
			len(man.Nodes), len(man.Edges), man.Laws.Count)
	}

	invented := 0
	for _, e := range man.Edges {
		src, err := os.ReadFile(e.From)
		if err != nil {
			t.Fatalf("edge cites unreadable file %s: %v", e.From, err)
		}
		lines := strings.Split(string(src), "\n")
		if e.Line < 1 || e.Line > len(lines) || !strings.Contains(lines[e.Line-1], e.Via) {
			invented++
			if invented <= 5 {
				t.Errorf("INVENTED RELATION: %s -> %s claims %q at %s:%d, not there",
					e.From, e.To, e.Via, e.From, e.Line)
			}
		}
	}
	if invented > 0 {
		t.Errorf("%d of %d edges are not re-derivable at the line they cite", invented, len(man.Edges))
	}

	sidecar, err := os.ReadFile(filepath.Join(outdir, man.Laws.File))
	if err != nil {
		t.Fatal(err)
	}
	flatSidecar := normalizeWS(string(sidecar))
	lawsSeen := 0
	for _, n := range man.Nodes {
		if len(n.Laws) == 0 && n.Gist == "" {
			continue
		}
		src, err := os.ReadFile(n.Path)
		if err != nil {
			t.Fatal(err)
		}
		doc := mineModuleDoc(n.Path, string(src))
		flatDoc := normalizeWS(doc)
		for _, l := range n.Laws {
			lawsSeen++
			if !strings.Contains(flatDoc, normalizeWS(l)) {
				t.Errorf("%s: law is not word-for-word in its own moduledoc: %q", n.Path, l)
			}
			if !strings.Contains(flatSidecar, normalizeWS(l)) {
				t.Errorf("%s: law never reached the sidecar: %q", n.Path, l)
			}
		}
		if n.Gist != "" {
			sents := splitSentences(doc)
			ok := false
			for i := 1; i <= len(sents); i++ {
				if strings.Join(sents[:i], " ") == n.Gist {
					ok = true
					break
				}
			}
			if !ok {
				t.Errorf("%s: gist is not a whole-sentence prefix of the moduledoc — cut mid-sentence: %q", n.Path, n.Gist)
			}
		}
	}
	if lawsSeen != man.Laws.Count {
		t.Errorf("map.json counts %d laws, the nodes carry %d", man.Laws.Count, lawsSeen)
	}
	t.Logf("live atlas: %d/%d nodes, %d edges (0 invented), %d laws, %d page(s), %d tok vs %d tok text",
		man.Included, man.Matched, len(man.Edges), man.Laws.Count, len(man.Pages),
		man.Tokens.Bundle, man.Tokens.TextBaseline)
}

// TestGoNodesAreReachedByDeclarationNotByFileStem pins the distinction a live
// probe surfaced: `errors.go` was the target of every `errors.New` call and
// `cli.go` the target of its own `package cli` line. Both edges were
// re-derivable at the cited line — the token IS there — and both were noise,
// because in Go that token names a PACKAGE, not the file. Go files are reached
// through their declarations; the stem is display only.
func TestGoNodesAreReachedByDeclarationNotByFileStem(t *testing.T) {
	sources := map[string]string{
		"pkg/errors.go": "package pkg\n\n// errors.go — helpers.\nfunc WrapFailure(e error) error { return e }\n",
		"pkg/user.go":   "package pkg\n\nimport \"errors\"\n\n// user.go — uses the stdlib.\nfunc Load() error { return WrapFailure(errors.New(\"x\")) }\n",
	}
	var nodes []mapNode
	for _, p := range []string{"pkg/errors.go", "pkg/user.go"} {
		nodes = append(nodes, mineNode(p, sources[p]))
	}
	edges := mineEdges(nodes, sources)
	sawDecl := false
	for _, e := range edges {
		if e.Via == "errors" {
			t.Errorf("a Go file stem colliding with a package name produced an edge: %+v", e)
		}
		if e.From == "pkg/user.go" && e.To == "pkg/errors.go" && e.Via == "WrapFailure" {
			sawDecl = true
			lines := strings.Split(sources[e.From], "\n")
			if !strings.Contains(lines[e.Line-1], e.Via) {
				t.Errorf("declaration edge cites %s:%d but %q is not there", e.From, e.Line, e.Via)
			}
		}
	}
	// Non-vacuity: the real reference must still be found, or this test would
	// pass by finding no edges at all.
	if !sawDecl {
		t.Fatal("the declared-function reference was lost — suppressing stems must not suppress real edges")
	}
}
