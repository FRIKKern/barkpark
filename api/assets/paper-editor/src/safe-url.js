// The reader's URL allowlist for the canvas (Render.Util.safe_url/1; twins:
// @barkpark/react inline.tsx safeUrl, web/lib/safe-href.ts, pdrender sanitizeURL).
// A canvas node view that paints a stored href/src into a live attribute runs it
// through this first, so Edit never carries a javascript:, data: or protocol-
// relative URL the reader would have refused. Returns the cleaned URL or "#".
// DOM setAttribute does the escaping, so unlike the string twins nothing is escaped here.
const ALLOWED_SCHEME = /^(?:https?|mailto|tel):/i;
const IN_DOC = /^(#|\?|\.\/|\.\.\/)/;
// The whole C0/DEL/C1 set the Elixir twin strips, anywhere in the string: the WHATWG URL
// parser deletes tab/LF/CR from anywhere, so the checked string must be the resolved one.
const CONTROLS = /[\u0000-\u001f\u007f-\u009f]/g;

export function safeUrl(href) {
  if (typeof href !== "string") return "#";
  const trimmed = href.replace(CONTROLS, "").replace(/^\s+/, "");
  if (trimmed.startsWith("/")) return /^\/[/\\]/.test(trimmed) ? "#" : trimmed;
  if (ALLOWED_SCHEME.test(trimmed) || IN_DOC.test(trimmed)) return trimmed;
  return "#";
}
