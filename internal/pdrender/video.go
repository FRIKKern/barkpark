package pdrender

import (
	"strings"
)

// ── video ────────────────────────────────────────────────────────────────
//
// Plain <video> file block (B062) — no autoplay-in-terminal illusion, an
// honest labeled box naming the file + an open-in-browser affordance (the
// asciicast/image media precedent: hardblocks.go's asciicastRenderer /
// imageRenderer). Never plays; the terminal cannot decode video.
//
//	video: {src, poster?, captions?: [{lang, src}], loop?}
//
//	- src       required for a real render; absent -> the honest empty box.
//	- captions  count only ("· N caption track(s)"), never fetched/parsed.
//	- poster/loop carry no TUI-visible effect (no image resolver call here —
//	  poster is a browser-only affordance).
type videoRenderer struct{}

func (videoRenderer) Render(b Block, ctx RenderCtx) []string {
	src := sanitizeURL(strings.TrimSpace(attrStr(b.Attrs, "src")))
	if src == "" {
		return nil
	}

	head := "▶ Video"
	if n := len(itemMaps(b.Attrs, "captions")); n > 0 {
		if n == 1 {
			head += " · 1 caption track"
		} else {
			head += " · " + formatBarValue(float64(n)) + " caption tracks"
		}
	}
	head += " · open in browser"

	styled := ctx.Theme.FieldLabel.Render(head)
	if ctx.Profile.supportsHyperlinks() {
		styled = "\x1b]8;;" + src + "\x1b\\" + styled + "\x1b]8;;\x1b\\"
	} else {
		styled += ctx.Theme.Dim.Render(" (" + src + ")")
	}
	return boxLines(styled, ctx)
}
