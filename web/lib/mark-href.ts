/**
 * `markHref` — resolve a link mark's href with ATTRS-FIRST precedence: a
 * non-empty `attrs.href` (ProseMirror shape from ingest) wins, else the
 * top-level `href`. This mirrors the sibling renderers exactly — Go
 * `internal/pdrender/inline.go` `markHref` and Elixir
 * `api/lib/barkpark/portable_doc/render/inline.ex` (`get_in(mark, ["attrs",
 * "href"]) || Map.get(mark, "href")`). Without the attrs branch, ProseMirror
 * marks render as dead spans on web only.
 *
 * Pure and unit-tested via the node --test lib harness.
 */

export function markHref(m: unknown): string | undefined {
  if (typeof m !== "object" || m === null) return undefined;
  const mark = m as { href?: unknown; attrs?: { href?: unknown } };
  const fromAttrs = mark.attrs?.href;
  if (typeof fromAttrs === "string" && fromAttrs !== "") return fromAttrs;
  return typeof mark.href === "string" ? mark.href : undefined;
}
