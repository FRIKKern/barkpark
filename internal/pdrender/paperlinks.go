package pdrender

import (
	"strings"
)

// ── paper-links ──────────────────────────────────────────────────────────────
// Mirrors compose_block(%{"type" => "paper-links"}) → paper_links_html/2
// (api/lib/barkpark/portable_doc/render/compose.ex) and its canonical JS twin
// (@barkpark/react, src/blocks/core.ts §paper-links): a curated set of related
// Papers — a section title, an optional intro line, then ONE entry per
// referenced paper.
//
// This type shipped on the Elixir and React surfaces but was registered in NO
// Go renderer, so 151 blocks across 145 of the 1050 published papers drew the
// "unknown block" box on the TUI (census re-run 2026-09-02, see
// paperlinks_test.go). It is among the most-used custom block types in the
// corpus.
//
// Resolution mirrors paper_link_ref/3 exactly. A ref is a slug string or a map
// `{slug, title?, description?, reason?, eyebrow?, meta?, prefer_authored_copy?}`.
// The public reader injects fresh published metadata under the transient
// `_paper_links` key (slug → {title, description, event_type, rev, updated_at});
// LIVE copy wins over authored copy unless the ref sets `prefer_authored_copy`,
// in which case the authored copy leads. A ref with no slug is dropped; a block
// whose refs all drop renders nothing (honest empty state, matching the
// `if cards == ""` guard).
//
// Terminal presentation of the three layouts (the HTML arms differ only in CSS
// plus WHICH metadata each shows, so only the metadata line varies here):
//
//	default    title link / description / "Why it matters: …" / event · rev · updated
//	chapters   eyebrow / title link / description / "Live edition|Edition · meta"
//	timeline   eyebrow (default "Edition") / title link / description /
//	           "Live edition|Edition · updated_at"
//
// The href is the paper's reader path (`/papers/<slug>`), rendered through the
// shared inline link presentation — an OSC 8 hyperlink where the profile
// supports it, else a dim " (/papers/<slug>)" suffix so the destination stays
// reachable on a dumb terminal.
type paperLinksRenderer struct{ ir InlineRenderer }

// paperLinkRef is the resolved view of one entry — the Go twin of the map
// paper_link_ref/3 returns.
type paperLinkRef struct {
	slug        string
	title       string
	description string
	reason      string
	eyebrow     string
	meta        string
	live        bool
	eventType   string
	rev         string
	updatedAt   string
}

// nonblankStr trims and returns "" for an all-whitespace value (Elixir nonblank/1).
func nonblankStr(m map[string]any, key string) string {
	return strings.TrimSpace(attrStr(m, key))
}

// firstNonEmpty returns the first non-empty argument, else "".
func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// joinNonEmpty joins the non-empty parts with sep (Elixir's reject-nil + join).
func joinNonEmpty(sep string, parts ...string) string {
	kept := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, sep)
}

// normalizedCopy mirrors compose.ex normalized_copy/1: trim, drop trailing
// periods, downcase — the comparison that suppresses a `reason` which merely
// restates the description.
func normalizedCopy(s string) string {
	return strings.ToLower(strings.TrimRight(strings.TrimSpace(s), "."))
}

// paperLinkRefOf resolves one raw ref against the injected live metadata and the
// block-level `reasons` map. Returns ok=false for a ref with no usable slug.
func paperLinkRefOf(raw any, resolved, reasons map[string]any) (paperLinkRef, bool) {
	var m map[string]any
	switch v := raw.(type) {
	case string:
		m = map[string]any{"slug": v}
	case map[string]any:
		m = v
	default:
		return paperLinkRef{}, false
	}

	slug := nonblankStr(m, "slug")
	if slug == "" {
		return paperLinkRef{}, false
	}

	live, _ := resolved[slug].(map[string]any)
	authoredTitle := nonblankStr(m, "title")
	authoredDesc := nonblankStr(m, "description")
	liveTitle := nonblankStr(live, "title")
	liveDesc := nonblankStr(live, "description")

	title, desc := firstNonEmpty(liveTitle, authoredTitle, slug), firstNonEmpty(liveDesc, authoredDesc)
	if attrBool(m, "prefer_authored_copy") {
		title, desc = firstNonEmpty(authoredTitle, liveTitle, slug), firstNonEmpty(authoredDesc, liveDesc)
	}

	return paperLinkRef{
		slug:        slug,
		title:       sanitizeText(title),
		description: sanitizeText(desc),
		reason:      sanitizeText(firstNonEmpty(nonblankStr(m, "reason"), nonblankStr(reasons, slug))),
		eyebrow:     sanitizeText(nonblankStr(m, "eyebrow")),
		meta:        sanitizeText(nonblankStr(m, "meta")),
		live:        len(live) > 0,
		eventType:   sanitizeText(nonblankStr(live, "event_type")),
		rev:         sanitizeText(nonblankStr(live, "rev")),
		updatedAt:   sanitizeText(nonblankStr(live, "updated_at")),
	}, true
}

// editionLabel is the "Live edition" / "Edition" cue the chapters and timeline
// arms print — it tells the reader whether the reader resolved fresh metadata
// for this slug or the entry is showing authored copy only.
func (r paperLinkRef) editionLabel() string {
	if r.live {
		return "Live edition"
	}
	return "Edition"
}

// metaLine is the trailing dim line for one entry, per layout.
func (r paperLinkRef) metaLine(layout string) string {
	switch layout {
	case "chapters":
		return joinNonEmpty(" · ", r.editionLabel(), r.meta)
	case "timeline":
		return joinNonEmpty(" · ", r.editionLabel(), r.updatedAt)
	default:
		rev := ""
		if r.rev != "" {
			rev = "rev " + r.rev
		}
		return joinNonEmpty(" · ", r.eventType, rev, r.updatedAt)
	}
}

func (p paperLinksRenderer) Render(b Block, ctx RenderCtx) []string {
	rawRefs := attrSlice(b.Attrs, "refs")
	if len(rawRefs) == 0 {
		return nil
	}
	resolved, _ := b.Attrs["_paper_links"].(map[string]any)
	reasons, _ := b.Attrs["reasons"].(map[string]any)
	layout := nonblankStr(b.Attrs, "layout")

	refs := make([]paperLinkRef, 0, len(rawRefs))
	for _, raw := range rawRefs {
		if ref, ok := paperLinkRefOf(raw, resolved, reasons); ok {
			refs = append(refs, ref)
		}
	}
	if len(refs) == 0 {
		return nil
	}

	w := clampWidth(ctx.Width)
	const indent = "  "
	bodyW := clampWidth(w - len(indent))
	dim := ctx.Theme.Dim
	bold := ctx.Theme.Body.Bold(true)

	title := sanitizeText(nonblankStr(b.Attrs, "title"))
	if title == "" {
		title = "Explore the work" // compose.ex's default section heading
	}
	out := wrapLines(bold.Render(title), w)
	if desc := sanitizeText(nonblankStr(b.Attrs, "description")); desc != "" {
		out = append(out, wrapLines(dim.Render(desc), w)...)
	}

	for _, ref := range refs {
		out = append(out, "")
		if layout == "chapters" || layout == "timeline" {
			eyebrow := ref.eyebrow
			if eyebrow == "" && layout == "timeline" {
				eyebrow = "Edition" // compose.ex's timeline eyebrow default
			}
			if eyebrow != "" {
				out = append(out, wrapLines(dim.Render(eyebrow), w)...)
			}
		}
		link := p.ir.renderLink("/papers/"+ref.slug, ref.title, ctx)
		out = append(out, wrapLines(dim.Render("▸ ")+link, w)...)
		if ref.description != "" {
			out = append(out, indented(wrapLines(ref.description, bodyW), indent)...)
		}
		// A reason that merely restates the description is suppressed, exactly
		// as paper_link_reason/2 does.
		if ref.reason != "" && normalizedCopy(ref.reason) != normalizedCopy(ref.description) {
			out = append(out, indented(wrapLines(bold.Render("Why it matters: ")+ref.reason, bodyW), indent)...)
		}
		if meta := ref.metaLine(layout); meta != "" {
			out = append(out, indented(wrapLines(dim.Render(meta), bodyW), indent)...)
		}
	}
	return out
}

// indented prefixes every line with indent.
func indented(lines []string, indent string) []string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, indent+line)
	}
	return out
}
