// Constants and helpers shared by the Markdown serializer and parser.
export const SENTINEL_OPEN = "<!--bp:block ";
export const SENTINEL_CLOSE = "-->";
export const EMPTY_PARAGRAPH_MARKER = "<!--bp:empty-->";

export function unescapeSentinelPayload(payload) {
  return payload.replace(/-\u0000-/g, "--");
}

export function clampLevel(level) {
  const n = Number(level);
  if (!Number.isFinite(n)) return 1;
  if (n < 1) return 1;
  if (n > 6) return 6;
  return Math.trunc(n);
}

// Mint an id for a block the user typed in source mode (no carried id). Unique
// within a process run; high-entropy so it never collides with a server id. The
// "m-" prefix marks a markdown-minted id (parallels run-convert.js's "c-").
let mintCounter = 0;
export function mintId() {
  mintCounter += 1;
  return "m-" + mintCounter.toString(36) + "-" + randomNonce();
}

function randomNonce() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID().slice(0, 8);
  }
  return Math.random().toString(36).slice(2, 10);
}
