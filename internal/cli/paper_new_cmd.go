package cli

// paper_new_cmd.go — `bp paper new <slug>`: the LOCAL scaffold half of the ONE
// authoring door (Paper Excellence charter D41). It writes a wall-passing BPML
// starter into the working-copy directory (`.barkpark/papers/<slug>.bpml`, the
// same tree pull/status/diff/push manage) plus a rev-0 anchor, and prints the
// loop: new → edit → `push --check` (the validate dry-run) → push. STRICTLY
// LOCAL — no server call, ever — so a cold agent's first step is hermetic; the
// server is met only at push, where the sync endpoint now CREATES an absent
// slug through the full publish wall (bulldocs_ingest_controller.ex
// sync_create).
//
// The starter's floor is the wall's floor, proven live against the validate
// dry-run (tooling/grip/ledger/pe-w6-scaffold-wall-minimums-2026-08-17.md):
// a title heading at block 0, at least one real paragraph (the Hollow gate),
// a description ≥20 trimmed chars (LabelSpine), and two weighted tags with
// DISTINCT strengths and ≥20-char rationales. The placeholder tags (`scaffold`,
// `article-draft`) are REGISTERED tags today — the scaffold never invents a
// tag, because an unregistered tag 422s `unknown_tag` at the wall (E3, never
// exempted) — and both the file and the printed next-steps tell the author to
// swap them for honest ones via the live registry (`bp doc ls tag`).
//
// NOTE the deliberate absence: the starter's <h1> carries NO role:"title" /
// locked:true stamp, and the create path does not add one. BPML cannot spell
// those attrs, so a locked-title paper cannot round-trip the sync differ
// (Diff.derive would emit a replace-block that strips `locked`, which
// Patch.check_locked_placement rejects) — the one door must produce papers the
// same door can keep editing. The unlocked h1 at block 0 is still the row
// title's truth (BlockOps.paper_title reads the first heading).

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// paperStarterTags are the scaffold's placeholder weighted tags — names that
// exist in the live E3 tag registry today (193 registered tags, 2026-08-17),
// with DISTINCT strengths (a LabelSpine rule) and ≥20-char rationales. They are
// placeholders by declaration: the emitted file and the next-steps both say to
// swap them via `bp doc ls tag` before pushing for real.
var paperStarterTags = []struct {
	Name     string
	Strength int
}{
	{"scaffold", 60},
	{"article-draft", 40},
}

// paperStarterRationale is each placeholder tag's rationale — over the wall's
// 20-char floor, and honest about being a placeholder.
const paperStarterRationale = "Placeholder from bp paper new — swap for an honest registered tag before pushing."

func runPaperNew(out *writer, g globals, args []string) int {
	force := false
	var pos []string
	for _, a := range args {
		switch a {
		case "--force":
			force = true
		case "-h", "--help":
			usagePaperNew(out, true)
			return exitOK
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				out.userErr("unknown paper new flag %q", a)
				usagePaperNew(out, false)
				return exitUsage
			}
			pos = append(pos, a)
		}
	}
	if len(pos) != 1 {
		out.userErr("paper new: exactly one <slug>")
		usagePaperNew(out, false)
		return exitUsage
	}
	slug := pos[0]
	if !validPaperNewSlug(slug) {
		out.userErr("paper new: %q is not a slug — lowercase letters/digits in hyphen-separated words (e.g. my-first-paper)", slug)
		return exitUsage
	}

	dir, err := paperWCDir()
	if err != nil {
		out.userErr("paper new: %v", err)
		return exitGeneric
	}

	path := paperWCFile(dir, slug)
	if _, statErr := os.Stat(path); statErr == nil && !force {
		out.userErr("paper new %s: %s already exists — edit it (or --force to overwrite the file with a fresh starter)", slug, path)
		return exitGeneric
	}

	title := paperTitleFromSlug(slug)
	bpml := paperStarterBPML(slug, title)

	// Working file + pristine snapshot — the same pair pull writes, so diff
	// shows edits against the untouched starter.
	if err := writePaperWCCopy(dir, slug, bpml); err != nil {
		out.userErr("paper new %s: %v", slug, err)
		return exitGeneric
	}

	// The rev-0 anchor: this paper does not exist on any server yet. push sends
	// baseRev "0"; the server's create-on-push arm ignores the anchor for an
	// absent slug, and a slug that ALREADY exists server-side answers 412
	// (pull first) — the honest collision surface. Server stays "" (no server
	// was contacted); the first successful push stamps the one it landed on.
	st, err := loadPaperWCState(dir)
	if err != nil {
		out.userErr("paper new %s: %v", slug, err)
		return exitGeneric
	}
	st.Papers[slug] = paperAnchor{Rev: "0", PulledAt: time.Now().UTC().Format(time.RFC3339)}
	if err := savePaperWCState(dir, st); err != nil {
		out.userErr("paper new %s: %v", slug, err)
		return exitGeneric
	}

	if out.output == "json" || out.output == "yaml" {
		tags := make([]string, len(paperStarterTags))
		for i, t := range paperStarterTags {
			tags[i] = t.Name
		}
		out.renderJSON(map[string]any{
			"ok": true, "slug": slug, "title": title, "path": path, "rev": "0",
			"placeholder_tags": tags,
		})
		return exitOK
	}

	out.outf("scaffolded %s → %s (wall-passing starter; local only — nothing pushed)", slug, path)
	out.outf("")
	out.outf("next:")
	out.outf("  1. edit the file — the <h1> is the paper's title; replace the placeholder paragraph")
	out.outf("  2. swap the placeholder tags (scaffold, article-draft) for honest REGISTERED tags:")
	out.outf("       bp doc ls tag        # the live registry — never invent a tag; an unregistered tag is refused (unknown_tag)")
	out.outf("  3. see every violation before publishing (dry-run, writes nothing):")
	out.outf("       bp paper push %s --check", slug)
	out.outf("  4. publish — push creates the paper through the full publish wall:")
	out.outf("       bp paper push %s", slug)
	return exitOK
}

// validPaperNewSlug accepts hyphen-separated lowercase words ([a-z0-9]) — the
// shape every paper slug in the corpus follows and the shape that is safe as a
// file name under .barkpark/papers/ on every platform.
func validPaperNewSlug(slug string) bool {
	if slug == "" || strings.HasPrefix(slug, "-") || strings.HasSuffix(slug, "-") || strings.Contains(slug, "--") {
		return false
	}
	for _, r := range slug {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
		default:
			return false
		}
	}
	return true
}

// paperTitleFromSlug derives the starter title from the slug's words — so
// every scaffold's title varies with its slug (the E4 dedup wall scores
// title similarity; identical boilerplate titles would collide immediately).
func paperTitleFromSlug(slug string) string {
	words := strings.Split(slug, "-")
	for i, w := range words {
		if w == "" {
			continue
		}
		words[i] = strings.ToUpper(w[:1]) + w[1:]
	}
	return strings.Join(words, " ")
}

// paperStarterBPML is the wall-passing starter document. Every line exists to
// clear a named gate (see the file comment); the placeholder prose says so, so
// nothing here masquerades as content.
func paperStarterBPML(slug, title string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "<paper slug=%q title=%q>\n", slug, title)
	b.WriteString("  <meta>\n")
	fmt.Fprintf(&b, "    <description>%s: a scaffolded draft — replace this with one or two sentences saying what the paper actually claims.</description>\n", title)
	for _, t := range paperStarterTags {
		fmt.Fprintf(&b, "    <tag tag=%q strength=\"%d\">%s</tag>\n", t.Name, t.Strength, paperStarterRationale)
	}
	b.WriteString("  </meta>\n")
	fmt.Fprintf(&b, "  <h1 id=\"tpl-title\">%s</h1>\n", title)
	b.WriteString("  <p>Replace this paragraph with the paper's first real claim — the publish wall refuses a hollow paper (a title with no content blocks).</p>\n")
	b.WriteString("</paper>\n")
	return b.String()
}

// usagePaperNew prints the `bp paper new` command signature. An explicit
// `--help` request routes to stdout (toStdout); error paths keep it on stderr.
func usagePaperNew(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp paper new <slug> [--force]")
	p("  scaffold a wall-passing BPML starter under .barkpark/papers/ (LOCAL —")
	p("  no server call) and seed its rev-0 anchor. The loop:")
	p("")
	p("    bp paper new my-paper        # scaffold")
	p("    $EDITOR .barkpark/papers/my-paper.bpml")
	p("    bp paper push my-paper --check   # validate dry-run — every violation, nothing written")
	p("    bp paper push my-paper       # CREATES the paper through the full publish wall")
	p("")
	p("flags:")
	p("  --force    overwrite an existing working copy with a fresh starter")
}
