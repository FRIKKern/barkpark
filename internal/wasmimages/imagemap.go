// Package wasmimages validates the browser reader's image map — the {src:
// base64} object the TUI toggle hands pdrender-wasm so `internal/pdrender`
// can paint half-block mosaics (imagemosaic.go) instead of the labeled
// "(view in Studio)" box.
//
// The map arrives from page JS, which pre-fetches each image block's src. JS
// is NOT the trust boundary: a paper's blocks are document content, so the
// srcs are attacker-influenced and the page could be coaxed into handing us
// junk, a 200MB blob, or a 30000×30000 decompression bomb. Every bound the
// reader relies on is therefore enforced HERE, in Go, on the wasm side:
//
//	same-origin  — only a rooted absolute path ("/media/…"); never an absolute
//	               URL, never a protocol-relative "//host/…", never "data:".
//	MIME         — magic-byte sniff restricted to the three formats
//	               internal/pdrender registers decoders for (PNG/JPEG/GIF).
//	bytes        — MaxEntryBytes per entry.
//	dimensions   — MaxPixels total pixels, via image.DecodeConfig (headers
//	               only: a bomb is rejected before any pixel is allocated).
//	total memory — MaxTotalBytes across all accepted entries.
//
// A violating entry is DROPPED, never fatal: Resolve returns nil for it and
// the image renderer falls through to its honest labeled box. A malformed or
// oversized map can therefore never block or fail the render — it can only
// cost you the picture.
//
// This package is deliberately GOOS-agnostic (no js/wasm build tag) so the
// bounds are unit-testable on the host toolchain; cmd/pdrender-wasm is the
// only caller.
package wasmimages

import (
	"bytes"
	"encoding/base64"
	"image"
	"strings"

	// Header-only decoders, matching internal/pdrender/imagemosaic.go's
	// registration set exactly. A format pdrender cannot decode must not
	// pass validation here either.
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
)

const (
	// MaxEntryBytes caps one decoded image. Comfortably above a reader-sized
	// photo, far below anything that could wedge a browser tab.
	MaxEntryBytes = 4 << 20

	// MaxTotalBytes caps the whole map. A paper with fifty images gets the
	// first entries that fit and honest boxes for the rest.
	MaxTotalBytes = 24 << 20

	// MaxPixels caps width*height. The mosaic downsamples to at most
	// ctx.Width columns × 44 pixel rows, so a huge source buys nothing while
	// costing a full-resolution decode.
	MaxPixels = 40_000_000

	// MaxEntries caps the key count so a map with a million tiny entries
	// cannot burn the render budget in validation alone.
	MaxEntries = 256
)

// Rejection explains why one entry was dropped. It is diagnostic only — the
// render never surfaces it — but it makes the bounds directly assertable.
type Rejection struct {
	Src    string
	Reason string
}

// Map is a validated src → bytes lookup.
type Map struct {
	bytes      map[string][]byte
	Rejections []Rejection
	TotalBytes int
}

// Resolve is the pdrender.RenderCtx.ImageResolver seam: bytes for an accepted
// src, nil for everything else (→ the honest labeled box).
func (m *Map) Resolve(src string) []byte {
	if m == nil {
		return nil
	}
	return m.bytes[strings.TrimSpace(src)]
}

// Len reports how many entries were accepted.
func (m *Map) Len() int {
	if m == nil {
		return 0
	}
	return len(m.bytes)
}

// sameOrigin accepts only the rooted-path shape a same-origin /media fetch
// produces. "//evil.example/x" is a protocol-relative URL, not a path, and is
// rejected even though it starts with "/".
func sameOrigin(src string) bool {
	if src == "" || !strings.HasPrefix(src, "/") || strings.HasPrefix(src, "//") {
		return false
	}
	// A rooted path cannot carry a scheme; reject any colon before the first
	// "/" boundary shenanigans (e.g. "/\evil" backslash tricks) outright.
	if strings.ContainsAny(src, "\\\x00") {
		return false
	}
	return true
}

// sniff returns the detected format for the three registered decoders, or ""
// when the magic bytes match none of them.
func sniff(b []byte) string {
	switch {
	case len(b) >= 8 && string(b[:8]) == "\x89PNG\r\n\x1a\n":
		return "png"
	case len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF:
		return "jpeg"
	case len(b) >= 6 && (string(b[:6]) == "GIF87a" || string(b[:6]) == "GIF89a"):
		return "gif"
	}
	return ""
}

// Build validates a {src: base64} map. Entries are considered in the given
// order; the total-memory budget is spent first-come. It never returns an
// error: the whole point is that a bad map degrades to boxes.
func Build(order []string, entries map[string]string) *Map {
	m := &Map{bytes: map[string][]byte{}}
	seen := 0
	for _, src := range order {
		raw, ok := entries[src]
		if !ok {
			continue
		}
		if seen >= MaxEntries {
			m.Rejections = append(m.Rejections, Rejection{src, "too-many-entries"})
			continue
		}
		seen++
		if reason := m.accept(src, raw); reason != "" {
			m.Rejections = append(m.Rejections, Rejection{src, reason})
		}
	}
	return m
}

func (m *Map) accept(src, b64 string) string {
	key := strings.TrimSpace(src)
	if !sameOrigin(key) {
		return "not-same-origin"
	}
	if _, dup := m.bytes[key]; dup {
		return "duplicate"
	}
	// Reject on the ENCODED length first: 4MiB of bytes is ~5.33MiB of
	// base64, so a 200MB string never reaches the decoder's allocation.
	if len(b64) == 0 || len(b64) > base64.StdEncoding.EncodedLen(MaxEntryBytes) {
		return "too-large"
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return "bad-base64"
	}
	if len(raw) == 0 || len(raw) > MaxEntryBytes {
		return "too-large"
	}
	if sniff(raw) == "" {
		return "unsupported-mime"
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return "undecodable"
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > MaxPixels {
		return "dimensions"
	}
	if m.TotalBytes+len(raw) > MaxTotalBytes {
		return "total-memory"
	}
	m.TotalBytes += len(raw)
	m.bytes[key] = raw
	return ""
}

// probe: throwaway, do not merge (task-519d5ea68ddca27f dispatch proof)
