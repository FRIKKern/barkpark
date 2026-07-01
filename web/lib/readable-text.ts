/**
 * Pick a readable text colour for a cell whose background is an arbitrary
 * API-supplied CSS colour. Sheet cells carry a fixed zinc text class, so a dark
 * fill in light mode (or a light fill in dark mode) renders near-invisible; this
 * derives a high-contrast override from the background's WCAG relative
 * luminance. Parses `#rgb` / `#rrggbb` and `rgb()/rgba()`; anything else (named
 * colours, hsl, gradients) returns undefined so the caller leaves the cell's
 * default text class untouched.
 */
export function readableText(bg: string): string | undefined {
  const rgb = parseColor(bg);
  if (!rgb) return undefined;
  const [r, g, b] = rgb;
  const L = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
  return L > 0.4 ? "#111" : "#f5f5f5";
}

/** Linearise an sRGB channel (0–255) for the WCAG luminance formula. */
function linear(channel: number): number {
  const c = channel / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

/** Parse a hex or rgb()/rgba() string to `[r, g, b]`, or null if unparseable. */
function parseColor(input: string): [number, number, number] | null {
  const s = input.trim();

  const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(s);
  if (hex) {
    const h = hex[1];
    if (h.length === 3) {
      return [
        parseInt(h[0] + h[0], 16),
        parseInt(h[1] + h[1], 16),
        parseInt(h[2] + h[2], 16),
      ];
    }
    return [
      parseInt(h.slice(0, 2), 16),
      parseInt(h.slice(2, 4), 16),
      parseInt(h.slice(4, 6), 16),
    ];
  }

  const rgb = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*[\d.]+\s*)?\)$/i.exec(s);
  if (rgb) {
    const r = Number(rgb[1]);
    const g = Number(rgb[2]);
    const b = Number(rgb[3]);
    if ([r, g, b].every((v) => Number.isFinite(v) && v >= 0 && v <= 255)) {
      return [r, g, b];
    }
  }

  return null;
}
