package cli

// context_pack_test.go — unit + end-to-end coverage for `bp context pack`.
// The detector cases mirror the research harness's validated behavior
// (/papers/optical-compression-research-report §6): every string class the
// benchmark proved image-unsafe must flag; prose and low-entropy config must
// not. The render tests pin the pagination/cap math the invariant depends on.

import (
	"encoding/json"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClassifyContextLineFlagsVerbatimClasses(t *testing.T) {
	cases := []struct {
		line   string
		reason string
	}{
		// The exact classes the benchmark proved silently corrupt in images.
		{"search = cf25ec84d8dbc74254770f58904dba41ecccc3fc", "hex-run"},
		{"DATABASE_URL=postgres://svc_app:u8jzPde0IgxLd6GncfBA@db.internal:5432/app", "cred-url"},
		{"id: 550e8400-e29b-41d4-a716-446655440000", "uuid"},
		// The confusable token that scored 0% at EVERY glyph size (report §7).
		{"OPAQUE_TOKEN=Il1O0OBB00llolIBll0oOIII", "token-run"},
		// The sign-off code the v1 harness missed until the CODE rule landed.
		{"changes require sign-off code CAPTAIN-7731", "code-token"},
		{"SETTLEMENT_ACCT=8277196540542260", "digit-run"},
		{"see https://guerrilla.barkpark.cloud/papers/x for the writeup", "url"},
	}
	for _, c := range cases {
		ok, reasons := classifyContextLine(c.line)
		if !ok {
			t.Errorf("expected %q to flag (%s), got clean", c.line, c.reason)
			continue
		}
		found := false
		for _, r := range reasons {
			if r == c.reason {
				found = true
			}
		}
		if !found {
			t.Errorf("%q: expected reason %q among %v", c.line, c.reason, reasons)
		}
	}
}

func TestClassifyContextLineLeavesProseAndConfigAlone(t *testing.T) {
	clean := []string{
		"The ingestion pipeline is validator-bound: every batch passes the validator.",
		"# retry_transient replays only transient failures from the dead-letter topic",
		"feature_012=on  # gate owner=team-3",
		"POOL_SIZE=24",
		"REGION=eu-central",
		"", // blank
		"func (p *APIProvider) resolveSSHKey(ctx context.Context) {",
	}
	for _, l := range clean {
		if ok, reasons := classifyContextLine(l); ok {
			t.Errorf("expected %q to stay image-safe, flagged as %v", l, reasons)
		}
	}
}

func TestImageTokensForAppliesCapThenFormula(t *testing.T) {
	// Under the cap: plain ceil(w*h/750).
	if got := imageTokensFor(300, 750); got != 300 {
		t.Errorf("300x750: want 300 tokens, got %d", got)
	}
	// Over the cap: the provider resize applies FIRST. 400x5152 halves to
	// 200x2576 → ceil(515200/750) = 687.
	if got := imageTokensFor(400, 5152); got != 687 {
		t.Errorf("400x5152: want 687 tokens (post-cap), got %d", got)
	}
}

func TestWrapContextLinesBoundsWidth(t *testing.T) {
	long := strings.Repeat("x", 325)
	lines := wrapContextLines("short\n"+long, 150)
	if len(lines) != 4 { // "short", 150, 150, 25
		t.Fatalf("want 4 lines, got %d", len(lines))
	}
	for i, l := range lines {
		if len(l) > 150 {
			t.Errorf("line %d is %d chars, over the 150 wrap", i, len(l))
		}
	}
}

func TestRenderContextBundlePaginatesUnderCap(t *testing.T) {
	// Enough lines that a single page at 0.4 scale would blow the cap:
	// linesPerPage at 0.4 = (2576/0.4 - 16)/13 = 494 → 600 lines = 2 pages.
	lines := make([]string, 600)
	for i := range lines {
		lines[i] = "line of ordinary config text with a bit of width to it"
	}
	dir := t.TempDir()
	pages, err := renderContextBundle(lines, 0.4, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(pages) != 2 {
		t.Fatalf("want 2 pages for 600 lines at 0.4, got %d", len(pages))
	}
	for _, p := range pages {
		if p.Width > ctxImgLongEdgeCap || p.Height > ctxImgLongEdgeCap {
			t.Errorf("%s is %dx%d — over the %dpx cap the invariant forbids",
				p.Name, p.Width, p.Height, ctxImgLongEdgeCap)
		}
		f, err := os.Open(filepath.Join(dir, p.Name))
		if err != nil {
			t.Fatalf("page not written: %v", err)
		}
		cfg, err := png.DecodeConfig(f)
		f.Close()
		if err != nil {
			t.Fatalf("%s is not a decodable PNG: %v", p.Name, err)
		}
		if cfg.Width != p.Width || cfg.Height != p.Height {
			t.Errorf("%s: manifest says %dx%d, file is %dx%d",
				p.Name, p.Width, p.Height, cfg.Width, cfg.Height)
		}
	}
}

func TestRenderContextPageDrawsInk(t *testing.T) {
	img := renderContextPage([]string{"HELLO barkpark 123"})
	dark := 0
	for _, px := range img.Pix {
		if px < 0x80 {
			dark++
		}
	}
	if dark == 0 {
		t.Fatal("rendered page has no dark pixels — glyphs were not drawn")
	}
}

func TestContextPackEndToEnd(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "sample.md")
	content := "# sample\n\nSome prose about the system design and its tradeoffs.\n" +
		"api_key=sk-Ab3dEf6hIj9kLm2nOp5qRs8t\n" + // token-run → sidecar
		"plain_flag=on\n"
	if err := os.WriteFile(src, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	outdir := filepath.Join(dir, "out.bundle")

	out, _, _ := newTestWriter()
	code := runContextPack(out, globals{}, []string{src, "--out", outdir})
	if code != exitOK {
		t.Fatalf("exit %d, want %d", code, exitOK)
	}

	raw, err := os.ReadFile(filepath.Join(outdir, "bundle.json"))
	if err != nil {
		t.Fatalf("bundle.json missing: %v", err)
	}
	var man contextBundleManifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatalf("bundle.json not valid JSON: %v", err)
	}
	if len(man.Pages) == 0 {
		t.Fatal("no pages emitted")
	}
	if man.VerbatimCount != 1 || man.Sidecar != "verbatim.txt" {
		t.Fatalf("want exactly the api_key line sidecar-routed, got count=%d sidecar=%q",
			man.VerbatimCount, man.Sidecar)
	}
	side, err := os.ReadFile(filepath.Join(outdir, "verbatim.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(side), "sk-Ab3dEf6hIj9kLm2nOp5qRs8t") {
		t.Error("sidecar does not carry the exact api_key line")
	}
	if man.Tokens.Bundle <= 0 || man.Tokens.TextBaseline <= 0 {
		t.Errorf("token ledger not populated: %+v", man.Tokens)
	}
	if !strings.Contains(man.Instruction, "READ-ONLY") {
		t.Error("instruction must carry the read-only warning")
	}
}

func TestContextPackUsageErrors(t *testing.T) {
	out, _, _ := newTestWriter()
	if code := runContextPack(out, globals{}, nil); code != exitUsage {
		t.Errorf("no files: want exitUsage, got %d", code)
	}
	if code := runContextPack(out, globals{}, []string{"--bogus"}); code != exitUsage {
		t.Errorf("unknown flag: want exitUsage, got %d", code)
	}
	if code := runContextPack(out, globals{}, []string{"f.txt", "--scale", "1.5"}); code != exitUsage {
		t.Errorf("bad scale: want exitUsage, got %d", code)
	}
}
