package wasmimages

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

func pngB64(t *testing.T, w, h int) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 7), G: uint8(y * 11), B: 0x80, A: 0xff})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png encode: %v", err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func build(t *testing.T, kv ...string) *Map {
	t.Helper()
	if len(kv)%2 != 0 {
		t.Fatalf("odd kv")
	}
	order := make([]string, 0, len(kv)/2)
	entries := map[string]string{}
	for i := 0; i < len(kv); i += 2 {
		order = append(order, kv[i])
		entries[kv[i]] = kv[i+1]
	}
	return Build(order, entries)
}

func reasonFor(m *Map, src string) string {
	for _, r := range m.Rejections {
		if r.Src == src {
			return r.Reason
		}
	}
	return ""
}

// TestBuild_AcceptsSameOriginPNG is the QUIET arm: a well-formed, in-bounds,
// same-origin entry must survive every bound and resolve to its bytes.
func TestBuild_AcceptsSameOriginPNG(t *testing.T) {
	b64 := pngB64(t, 8, 6)
	m := build(t, "/media/ok.png", b64)

	if got := m.Resolve("/media/ok.png"); len(got) == 0 {
		t.Fatalf("Resolve returned no bytes; rejections=%v", m.Rejections)
	}
	if m.Len() != 1 {
		t.Fatalf("Len = %d, want 1", m.Len())
	}
	if len(m.Rejections) != 0 {
		t.Fatalf("unexpected rejections: %v", m.Rejections)
	}
}

func TestBuild_AcceptsJPEGAndGIF(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	var jb, gb bytes.Buffer
	if err := jpeg.Encode(&jb, img, nil); err != nil {
		t.Fatalf("jpeg: %v", err)
	}
	if err := gif.Encode(&gb, img, nil); err != nil {
		t.Fatalf("gif: %v", err)
	}
	m := build(t,
		"/media/a.jpg", base64.StdEncoding.EncodeToString(jb.Bytes()),
		"/media/a.gif", base64.StdEncoding.EncodeToString(gb.Bytes()),
	)
	if m.Len() != 2 {
		t.Fatalf("Len = %d, want 2 (rejections %v)", m.Len(), m.Rejections)
	}
}

// TestBuild_RejectsCrossOrigin is criterion [1]/[2]'s same-origin arm: an
// absolute or protocol-relative src never enters the map, so the renderer
// keeps the honest box for it.
func TestBuild_RejectsCrossOrigin(t *testing.T) {
	b64 := pngB64(t, 4, 4)
	for _, src := range []string{
		"https://evil.example/x.png",
		"http://evil.example/x.png",
		"//evil.example/x.png",
		"data:image/png;base64,AAAA",
		"media/relative.png",
		"/media/back\\slash.png",
		"",
	} {
		m := build(t, src, b64)
		if got := m.Resolve(src); got != nil {
			t.Errorf("src %q was accepted, want rejected", src)
		}
		if m.Len() != 0 {
			t.Errorf("src %q: Len = %d, want 0", src, m.Len())
		}
	}
}

func TestBuild_RejectsUnsupportedMIME(t *testing.T) {
	// A valid base64 payload whose magic bytes are not PNG/JPEG/GIF — e.g. a
	// WebP RIFF header, which image.Decode in pdrender cannot handle either.
	webpish := base64.StdEncoding.EncodeToString([]byte("RIFF\x00\x00\x00\x00WEBPVP8 junkjunkjunk"))
	m := build(t, "/media/x.webp", webpish)
	if m.Resolve("/media/x.webp") != nil {
		t.Fatal("unsupported MIME accepted")
	}
	if r := reasonFor(m, "/media/x.webp"); r != "unsupported-mime" {
		t.Fatalf("reason = %q, want unsupported-mime", r)
	}
}

func TestBuild_RejectsBadBase64(t *testing.T) {
	m := build(t, "/media/x.png", "!!!! not base64 !!!!")
	if m.Resolve("/media/x.png") != nil {
		t.Fatal("malformed base64 accepted")
	}
	if r := reasonFor(m, "/media/x.png"); r != "bad-base64" {
		t.Fatalf("reason = %q, want bad-base64", r)
	}
}

func TestBuild_RejectsOversizedEntry(t *testing.T) {
	// Longer than the encoded form of MaxEntryBytes: refused on the string
	// length, before any decode allocates.
	huge := strings.Repeat("A", base64.StdEncoding.EncodedLen(MaxEntryBytes)+4)
	m := build(t, "/media/huge.png", huge)
	if m.Resolve("/media/huge.png") != nil {
		t.Fatal("oversized entry accepted")
	}
	if r := reasonFor(m, "/media/huge.png"); r != "too-large" {
		t.Fatalf("reason = %q, want too-large", r)
	}
}

// TestBuild_RejectsDimensionBomb uses a PNG whose HEADER claims a pixel count
// past MaxPixels while the file itself is tiny — the decompression-bomb shape.
// DecodeConfig reads headers only, so this must be refused without allocating
// the image.
func TestBuild_RejectsDimensionBomb(t *testing.T) {
	raw := bombPNGHeader(60000, 60000)
	m := build(t, "/media/bomb.png", base64.StdEncoding.EncodeToString(raw))
	if m.Resolve("/media/bomb.png") != nil {
		t.Fatal("dimension bomb accepted")
	}
	if r := reasonFor(m, "/media/bomb.png"); r != "dimensions" {
		t.Fatalf("reason = %q, want dimensions", r)
	}
}

func TestBuild_EnforcesTotalMemory(t *testing.T) {
	// Two entries whose sum exceeds the budget: the first fits, the second is
	// dropped for total-memory rather than being let through.
	big := pngB64(t, 900, 900) // incompressible-ish noise, ~MBs
	m := &Map{bytes: map[string][]byte{}}
	m.TotalBytes = MaxTotalBytes - 16 // pre-load the budget
	if reason := m.accept("/media/second.png", big); reason != "total-memory" {
		t.Fatalf("reason = %q, want total-memory", reason)
	}
	if m.Resolve("/media/second.png") != nil {
		t.Fatal("entry accepted past the total-memory budget")
	}
}

func TestBuild_EnforcesEntryCount(t *testing.T) {
	b64 := pngB64(t, 2, 2)
	order := make([]string, 0, MaxEntries+5)
	entries := map[string]string{}
	for i := 0; i < MaxEntries+5; i++ {
		src := "/media/" + string(rune('a'+i%26)) + "-" + itoa(i) + ".png"
		order = append(order, src)
		entries[src] = b64
	}
	m := Build(order, entries)
	if m.Len() > MaxEntries {
		t.Fatalf("Len = %d, want <= %d", m.Len(), MaxEntries)
	}
	if reasonFor(m, order[len(order)-1]) != "too-many-entries" {
		t.Fatalf("last entry not refused for count: %v", m.Rejections[len(m.Rejections)-1:])
	}
}

func TestResolve_NilMapIsSafe(t *testing.T) {
	var m *Map
	if m.Resolve("/media/x.png") != nil || m.Len() != 0 {
		t.Fatal("nil Map must resolve to nil")
	}
}

// TestImageMosaic_EndToEnd is the arm that reds when the wiring is reverted:
// the SAME image block renders as the honest "(view in Studio)" box with no
// resolver, and as a truecolor half-block mosaic when the validated map is
// wired into pdrender's ImageResolver seam.
func TestImageMosaic_EndToEnd(t *testing.T) {
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })

	const src = "/media/photo.png"
	blocksJSON := `{"blocks":[{"id":"i1","type":"image","src":"` + src + `","alt":"Photo"}]}`
	blocks, err := pdrender.Decode([]byte(blocksJSON))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	theme := pdrender.ThemeFor(pdrender.DefaultTheme, "dark")
	reg := pdrender.DefaultRegistry(theme)

	base := pdrender.RenderCtx{Width: 80, Theme: theme, Profile: pdrender.TrueColor}
	boxed := reg.RenderDoc(blocks, base)
	if !strings.Contains(boxed, "view in Studio") {
		t.Fatalf("no-resolver render lost the honest box:\n%s", boxed)
	}

	m := build(t, src, pngB64(t, 40, 24))
	if m.Len() != 1 {
		t.Fatalf("map did not accept the fixture: %v", m.Rejections)
	}
	withImages := base
	withImages.ImageResolver = m.Resolve
	mosaic := reg.RenderDoc(blocks, withImages)
	if strings.Contains(mosaic, "view in Studio") {
		t.Fatalf("resolver wired but the box survived:\n%s", mosaic)
	}
	if !strings.Contains(mosaic, "▀") {
		t.Fatalf("mosaic missing half-block cells:\n%s", mosaic)
	}

	// Criterion [1]: a src the map REFUSED (cross-origin here) keeps the box
	// even with the resolver wired.
	thirdParty := `{"blocks":[{"id":"i2","type":"image","src":"https://evil.example/x.png","alt":"Photo"}]}`
	tp, err := pdrender.Decode([]byte(thirdParty))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out := reg.RenderDoc(tp, withImages); !strings.Contains(out, "view in Studio") {
		t.Fatalf("third-party src lost the honest box:\n%s", out)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
