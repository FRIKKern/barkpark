/**
 * The address BLOCK the detail page draws, as an ordered list of lines.
 *
 * WHY THIS IS A MODULE AND NOT A HELPER IN THE PAGE. It used to be a helper in
 * `app/sted/[slug]/page.tsx`, and it had two defects that only its CALLER could
 * see — which is precisely the kind nobody catches, because this app has no
 * render tests and `page.tsx` cannot be loaded under `node --test` (it imports
 * `server-only` through the data layer, and JSX is not stripped by the node
 * loader). `lib/paginate.ts` and `lib/normalize.ts` already exist for the same
 * reason and say so: the pure decision moves here so the SHIPPED code is the
 * code under test.
 *
 * THE TWO DEFECTS IT RETIRES.
 *
 * 1. `country` WAS PARSED AND NEVER RENDERED. The data layer reads
 *    `address.country` off every upstream document and carries it into `Place`;
 *    the old helper destructured it and returned it; no JSX ever read it.
 *    `git grep country -- apps/hundesteder` hit the parse and the destructure
 *    and zero render sites. Worse, `hasAddress` in the normaliser is truthy on
 *    `country` ALONE — so a document carrying only a country produced a truthy
 *    `place.address`, the page drew an "Adresse" LABEL with a completely empty
 *    value, and because `address` was truthy it also SKIPPED the `place.city`
 *    "Sted" fallback arm. The one fact the document carried was dropped and an
 *    empty labelled row was drawn in its place.
 *
 * 2. A FALLBACK THAT COULD NEVER FIRE. The page rendered
 *    `address.lineTwo ?? place.city`, but `lineTwo` was BUILT from `place.city`
 *    (`[postalCode, place.city].filter(Boolean).join(" ")`), so it was
 *    undefined only when `place.city` was undefined too. The right-hand branch
 *    was unreachable in exactly the case it existed to cover.
 *
 * THE SHAPE. Returning an ordered `lines` array rather than named slots is the
 * fix for both: a line is present or it is not, the caller cannot draw a label
 * for a value that does not exist, and adding a line later cannot silently go
 * unrendered the way `country` did.
 *
 * ON RENDERING `country` AT ALL. Every place in the corpus is Norwegian, so the
 * line is usually redundant. Suppressing it by comparing against a hardcoded
 * list of spellings of "Norway" was considered and rejected: it trades a
 * visible redundancy for a silent data-loss rule that would need maintaining in
 * two languages. An editor who does not want the line stops entering the field.
 */

/** The address as it appears on `Place` — structurally what `normalize.ts`
 * builds, restated here so this module imports nothing. */
export interface PlaceAddress {
  street?: string;
  postalCode?: string;
  country?: string;
}

/** Just the parts of a Place this module reads. */
export interface AddressablePlace {
  address?: PlaceAddress;
  city?: string;
}

/** A non-empty, non-blank string, or undefined. */
function line(v: string | undefined): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return t.length > 0 ? t : undefined;
}

/**
 * The lines of the "Adresse" block, in reading order:
 *   street
 *   postalCode + city
 *   country
 *
 * Returns `null` when there is NOTHING to draw — which is the signal the caller
 * needs in order to fall back to a bare "Sted" row instead of drawing an
 * "Adresse" label over an empty value. A place whose only address field is
 * `country` now yields `["Norge"]` rather than that empty row.
 */
export function addressLines(place: AddressablePlace | null | undefined): string[] | null {
  if (!place) return null;
  const a = place.address ?? {};
  const cityLine = [line(a.postalCode), line(place.city)].filter(Boolean).join(" ");
  const lines = [line(a.street), cityLine.length > 0 ? cityLine : undefined, line(a.country)].filter(
    (l): l is string => l !== undefined,
  );
  return lines.length > 0 ? lines : null;
}
