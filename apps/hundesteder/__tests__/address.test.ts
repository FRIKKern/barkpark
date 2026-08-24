/**
 * The address block's line list — the SHIPPED `addressLines`, not a mirror.
 *
 * These pin the two defects the module retires, both of which were invisible
 * because this app has no render tests and `app/sted/[slug]/page.tsx` cannot be
 * loaded under `node --test` (JSX is not stripped by the node loader, and the
 * page reaches `server-only` through the data layer). Moving the decision into
 * `lib/address.ts` is what makes them testable at all — the same move
 * `lib/paginate.ts` and `lib/normalize.ts` already document.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { addressLines } from "../lib/address.ts";

/* ── defect 1: country was parsed and never rendered ─────────────────────── */

test("DEFECT 1: a country-only address yields a LINE, not an empty block", () => {
  // `hasAddress` in the normaliser is truthy on `country` alone, so this shape
  // reaches the page. It used to draw an "Adresse" label over nothing AND skip
  // the "Sted" fallback, because `address` was truthy.
  assert.deepEqual(addressLines({ address: { country: "Norge" } }), ["Norge"]);
});

test("DEFECT 1: a full address carries the country as its last line", () => {
  assert.deepEqual(
    addressLines({
      address: { street: "Karl Johans gate 1", postalCode: "0154", country: "Norge" },
      city: "Oslo",
    }),
    ["Karl Johans gate 1", "0154 Oslo", "Norge"],
  );
});

/* ── defect 2: the unreachable `?? place.city` fallback ──────────────────── */

test("DEFECT 2: the city still appears when there is no postal code", () => {
  // The old page read `address.lineTwo ?? place.city`, where lineTwo was BUILT
  // from place.city — so the right-hand branch could never fire. The city has
  // to survive on its own, which is what this asserts.
  assert.deepEqual(addressLines({ address: { street: "Bryggen 1" }, city: "Bergen" }), [
    "Bryggen 1",
    "Bergen",
  ]);
});

test("a place with a city and NO address at all still yields that city", () => {
  // The caller's `: place.city ?` arm exists for a null return; this shape is
  // NOT null, because a city is an address line even with no address object.
  assert.deepEqual(addressLines({ city: "Tromsø" }), ["Tromsø"]);
});

/* ── the null contract — what tells the caller to draw "Sted" instead ────── */

test("NOTHING to draw returns null, so the caller never labels an empty value", () => {
  assert.equal(addressLines({}), null);
  assert.equal(addressLines({ address: {} }), null);
  assert.equal(addressLines(null), null);
  assert.equal(addressLines(undefined), null);
});

test("blank and whitespace-only fields are ABSENT, not empty lines", () => {
  // An upstream document with `street: "   "` must not push a blank line into
  // the block — that is the empty-row defect in miniature.
  assert.equal(addressLines({ address: { street: "  ", country: "\t" } }), null);
  assert.deepEqual(addressLines({ address: { street: " Torget 3 " } }), ["Torget 3"]);
});

/* ── ordering + composition ─────────────────────────────────────────────── */

test("lines are in reading order: street, postal+city, country", () => {
  const lines = addressLines({
    address: { street: "S", postalCode: "1", country: "C" },
    city: "B",
  });
  assert.deepEqual(lines, ["S", "1 B", "C"]);
});

test("a postal code with no city renders alone rather than with a trailing space", () => {
  assert.deepEqual(addressLines({ address: { postalCode: "0154" } }), ["0154"]);
});
