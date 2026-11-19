// A label is read as a person sees it: the picture in its box against the same
// words drawn alone. installMatch runs in the check's isolated world after
// installHelpers and before installDrawn (it is serialised, so it may not reach
// anything outside its own body) and adds its readers to the helper object.
//
// Each line a text node is laid out in is one label. Its picture is every pixel
// in the line's box (padded by PAD) that differs from the same capture with all
// glyphs unpainted (decorations, boxes and graphics stay painted there, so a bar
// or a cover laid over the letters is a loss, and another word or a ghost copy
// is extra ink). Its reference is the same string drawn alone, in the same font,
// colours, ground and place within a device pixel. A pixel counts in each when
// it moved at least half as far as the most any pixel there moved (the outline
// at half cover). The score is the pixels in both over the pixels in either:
// missing ink lowers it (cut, clipped, covered, shrunk, mirrored) and so does
// extra ink.
export function installMatch() {
  const h = window.__barkCheck
  const PAD = 1

  /** The lines a text node is laid out in, each as the string it draws (collapsed spaces left out) and its box. */
  const lines = (node) => {
    const text = node.textContent
    const range = document.createRange()
    const out = []
    let line = null
    for (let i = 0; i < text.length; i++) {
      range.setStart(node, i)
      range.setEnd(node, i + 1)
      const r = [...range.getClientRects()].find((x) => x.width > 0 && x.height > 0)
      if (!r) continue
      if (!line || Math.abs(r.top - line.top) > r.height / 2) out.push((line = { left: r.left, top: r.top, right: r.right, bottom: r.bottom, str: '' }))
      line.left = Math.min(line.left, r.left)
      line.right = Math.max(line.right, r.right)
      line.bottom = Math.max(line.bottom, r.bottom)
      line.str += /\s/.test(text[i]) ? ' ' : text[i]
    }
    return out.filter((l) => l.str.trim()).map((l) => ({ str: l.str, left: l.left, top: l.top, width: l.right - l.left, height: l.bottom - l.top }))
  }

  const moved = (a, i, under) => Math.max(Math.abs(a[i] - under[0]), Math.abs(a[i + 1] - under[1]), Math.abs(a[i + 2] - under[2]))

  /** The reference: how far each pixel of a cell of the alone sheet moved from its ground, cropped to the cell. */
  const reference = (img, cellBox, textBox, clip, scale, ground) => {
    const x0 = Math.round((cellBox.x - clip.x) * scale)
    const y0 = Math.round((cellBox.y - clip.y) * scale)
    const w = Math.round(cellBox.w * scale)
    const ht = Math.round(cellBox.h * scale)
    const d = new Uint8Array(w * ht)
    let top = 0
    for (let y = 0; y < ht; y++)
      for (let x = 0; x < w; x++) {
        const px = x0 + x
        const py = y0 + y
        if (px < 0 || py < 0 || px >= img.w || py >= img.h) continue
        const v = moved(img.data, (py * img.w + px) * 4, ground)
        d[y * w + x] = v
        top = Math.max(top, v)
      }
    return { d, w, h: ht, top, tx: (textBox.x - cellBox.x) * scale, ty: (textBox.y - cellBox.y) * scale, tw: textBox.w, th: textBox.h }
  }

  /** How much of a label's picture is its reference: pixels in both over pixels in either, in the line's box
      (`line`, document CSS px) padded by PAD. `a` is the drawn capture, `b` the one with glyphs unpainted;
      `holes` are other labels' boxes, left out where they reach into this one. */
  const match = (a, b, clip, scale, line, ref, holes) => {
    const left = (line.x - clip.x) * scale
    const top = (line.y - clip.y) * scale
    const dx = Math.round(ref.tx - left)
    const dy = Math.round(ref.ty - top)
    const x0 = Math.floor(left - PAD * scale)
    const y0 = Math.floor(top - PAD * scale)
    const x1 = Math.ceil(left + (Math.max(line.w, ref.tw) + PAD) * scale)
    const y1 = Math.ceil(top + (Math.max(line.h, ref.th) + PAD) * scale)
    const near = holes.filter((r) => r.x < clip.x + x1 / scale && r.x + r.w > clip.x + x0 / scale && r.y < clip.y + y1 / scale && r.y + r.h > clip.y + y0 / scale)
    const own = (x, y) => x >= line.x && x < line.x + line.w && y >= line.y && y < line.y + line.h
    const page = []
    const mine = []
    let pageTop = 0
    for (let y = y0; y < y1; y++)
      for (let x = x0; x < x1; x++) {
        const cx = clip.x + (x + 0.5) / scale
        const cy = clip.y + (y + 0.5) / scale
        if (near.length && !own(cx, cy) && near.some((r) => cx >= r.x && cx < r.x + r.w && cy >= r.y && cy < r.y + r.h)) continue
        let p = 0
        if (x >= 0 && y >= 0 && x < a.w && y < a.h) {
          const i = (y * a.w + x) * 4
          p = moved(a.data, i, [b.data[i], b.data[i + 1], b.data[i + 2]])
        }
        const u = x + dx
        const v = y + dy
        page.push(p)
        mine.push(u >= 0 && v >= 0 && u < ref.w && v < ref.h ? ref.d[v * ref.w + u] : 0)
        pageTop = Math.max(pageTop, p)
      }
    let both = 0
    let either = 0
    for (let i = 0; i < page.length; i++) {
      const p = pageTop > 2 && page[i] >= pageTop / 2
      const r = ref.top > 2 && mine[i] >= ref.top / 2
      if (p && r) both++
      if (p || r) either++
    }
    return either ? both / either : 0
  }

  Object.assign(h, { lines, reference, match })
}
