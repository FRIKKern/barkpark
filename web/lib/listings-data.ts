/**
 * The listing-directory template's content shape + a bundled sample dataset.
 *
 * This is a PLAIN module (no `server-only`) on purpose: the `Listing` type and
 * the sample rows are imported by BOTH the server data layer (`lib/listings.ts`,
 * which may fetch real rows from an API) AND the client map component
 * (`components/listings-map.tsx`, which only ever needs the type + data shape).
 * Keeping it dependency-free is what lets the template render a real map of
 * pins out of the box, before anyone wires a backend.
 *
 * `Listing` is deliberately generic — a directory of cafés, trailheads, shops,
 * offices, anything with a coordinate. It is NOT tied to any one CMS: the only
 * load-bearing fields are `id`, `title`, `lat`, `lng`. Everything else is
 * presentation the map/popover renders when present and skips when absent.
 */

export interface Listing {
  /** Stable id. When wired to a real backend, set this to the same value the
   * left-rail finder uses as a result `slug`/`doc_id` — that is the key the
   * search→map highlight bridge matches on (see `components/map-landing.tsx`). */
  id: string;
  /** Content type, used only to build a detail href (`/d/<type>/<slug>`).
   * Generic listings can leave this as the default `"listing"`. */
  type: string;
  /** URL slug for the detail link; falls back to `id` when absent. */
  slug: string;
  title: string;
  /** WGS84 latitude / longitude. The two fields the map cannot render without. */
  lat: number;
  lng: number;
  category?: string;
  city?: string;
  description?: string;
  address?: string;
  /** External website (opened from the marker popover when no detail page). */
  url?: string;
  priceRange?: string;
  /** Free-form flags the popover renders as chips, e.g. ["dog_friendly"]. */
  tags?: string[];
}

/**
 * Sample locations so the template is demonstrable with zero setup — a spread
 * of dog-friendly spots across Norway's biggest cities. Coordinates are real
 * city-centre points nudged a little so markers don't stack. Swap this out (or
 * point `lib/listings.ts` at a live source) for your own directory.
 */
export const SAMPLE_LISTINGS: Listing[] = [
  // ── Oslo ────────────────────────────────────────────────────────────────
  {
    id: "mocca-oslo",
    type: "listing",
    slug: "mocca-oslo",
    title: "Mocca",
    category: "Café",
    city: "Oslo",
    lat: 59.9252,
    lng: 10.7164,
    address: "Niels Juels gate 70",
    url: "https://example.com/mocca",
    priceRange: "$$",
    description: "Briard-friendly neighbourhood café with a water bowl by the door.",
    tags: ["dog_friendly", "outdoor_seating"],
  },
  {
    id: "tim-wendelboe-oslo",
    type: "listing",
    slug: "tim-wendelboe-oslo",
    title: "Tim Wendelboe",
    category: "Café",
    city: "Oslo",
    lat: 59.9215,
    lng: 10.7589,
    address: "Grüners gate 1",
    priceRange: "$$",
    description: "Tiny roastery and espresso bar in Grünerløkka.",
    tags: ["dog_friendly"],
  },
  {
    id: "vippa-oslo",
    type: "listing",
    slug: "vippa-oslo",
    title: "Vippa",
    category: "Food hall",
    city: "Oslo",
    lat: 59.9016,
    lng: 10.7361,
    address: "Akershusstranda 25",
    priceRange: "$$",
    description: "Waterfront street-food hall — dogs welcome on the benches.",
    tags: ["dog_friendly", "outdoor_seating"],
  },
  {
    id: "frognerparken-oslo",
    type: "listing",
    slug: "frognerparken-oslo",
    title: "Frognerparken",
    category: "Park",
    city: "Oslo",
    lat: 59.9269,
    lng: 10.7035,
    description: "Big open park, leashed dogs welcome on the lawns.",
    tags: ["dog_friendly", "off_leash_area"],
  },
  // ── Bergen ──────────────────────────────────────────────────────────────
  {
    id: "kaffemisjonen-bergen",
    type: "listing",
    slug: "kaffemisjonen-bergen",
    title: "Kaffemisjonen",
    category: "Café",
    city: "Bergen",
    lat: 60.3905,
    lng: 5.3266,
    address: "Øvre Korskirkeallmenningen 5",
    priceRange: "$$",
    description: "Long-running specialty café a few minutes from Bryggen.",
    tags: ["dog_friendly"],
  },
  {
    id: "bryggen-bergen",
    type: "listing",
    slug: "bryggen-bergen",
    title: "Bryggen",
    category: "Sight",
    city: "Bergen",
    lat: 60.3975,
    lng: 5.3242,
    description: "The old Hanseatic wharf — wander the boardwalks with your dog.",
    tags: ["dog_friendly", "outdoor_seating"],
  },
  // ── Trondheim ───────────────────────────────────────────────────────────
  {
    id: "dromedar-trondheim",
    type: "listing",
    slug: "dromedar-trondheim",
    title: "Dromedar Kaffebar",
    category: "Café",
    city: "Trondheim",
    lat: 63.4297,
    lng: 10.3933,
    address: "Nedre Bakklandet 3",
    priceRange: "$$",
    description: "Bakklandet café on the river, heaters and blankets outside.",
    tags: ["dog_friendly", "outdoor_seating"],
  },
  {
    id: "marinen-trondheim",
    type: "listing",
    slug: "marinen-trondheim",
    title: "Marinen",
    category: "Park",
    city: "Trondheim",
    lat: 63.4282,
    lng: 10.3974,
    description: "Riverside green by Nidaros — a favourite morning dog walk.",
    tags: ["dog_friendly", "off_leash_area"],
  },
  // ── Stavanger ───────────────────────────────────────────────────────────
  {
    id: "ostehuset-stavanger",
    type: "listing",
    slug: "ostehuset-stavanger",
    title: "Østhuset",
    category: "Café",
    city: "Stavanger",
    lat: 58.9696,
    lng: 5.7331,
    address: "Klubbgata 3",
    priceRange: "$$",
    description: "All-day café and bakery in the centre.",
    tags: ["dog_friendly"],
  },
  {
    id: "gamle-stavanger",
    type: "listing",
    slug: "gamle-stavanger",
    title: "Gamle Stavanger",
    category: "Sight",
    city: "Stavanger",
    lat: 58.9710,
    lng: 5.7280,
    description: "White wooden lanes of old Stavanger — easy, leashed strolling.",
    tags: ["dog_friendly"],
  },
  // ── Tromsø ──────────────────────────────────────────────────────────────
  {
    id: "risoe-tromso",
    type: "listing",
    slug: "risoe-tromso",
    title: "Risøe Mathus",
    category: "Café",
    city: "Tromsø",
    lat: 69.6489,
    lng: 18.9560,
    address: "Strandgata 32",
    priceRange: "$$",
    description: "Cosy harbour-side café above the Arctic Circle.",
    tags: ["dog_friendly"],
  },
  {
    id: "telegrafbukta-tromso",
    type: "listing",
    slug: "telegrafbukta-tromso",
    title: "Telegrafbukta",
    category: "Beach",
    city: "Tromsø",
    lat: 69.6356,
    lng: 18.9226,
    description: "Pebble beach park at the island's south tip — big open dog runs.",
    tags: ["dog_friendly", "off_leash_area"],
  },
];
