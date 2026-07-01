/**
 * Coerce a document `slug` field to renderable text.
 *
 * Slugs arrive in two shapes: a bare string, or the Barkpark object form
 * `{ _type: "slug", current: string }`. Returning the object straight into JSX
 * throws "Objects are not valid as a React child" (React #31), so unknown docs
 * that carry the object form would crash the whole detail pane. This normalises
 * both to a string, or `null` when there's nothing showable.
 */
export function slugText(v: unknown): string | null {
  if (typeof v === "string") return v;
  if (
    v &&
    typeof v === "object" &&
    "current" in v &&
    typeof (v as { current: unknown }).current === "string"
  ) {
    return (v as { current: string }).current;
  }
  return null;
}
