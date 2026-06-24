/**
 * Category → icon + Norwegian label mapping. Icons live in `public/icons/`
 * as stroke SVGs that use `currentColor`, so we render them via <img> when the
 * monochrome stroke is acceptable, or inline (recolourable) where we want the
 * accent. The brief's mapping:
 *
 *   Café → cafe, Food hall → bowl, Restaurant → restaurant, Bar → bar,
 *   Park/Beach → trail, Sight → pin, default → paw.
 */

export type IconName =
  | "cafe"
  | "bowl"
  | "restaurant"
  | "bar"
  | "trail"
  | "pin"
  | "paw";

const CATEGORY_ICON: Record<string, IconName> = {
  Café: "cafe",
  Cafe: "cafe",
  "Food hall": "bowl",
  Restaurant: "restaurant",
  Bar: "bar",
  Park: "trail",
  Beach: "trail",
  Sight: "pin",
};

/** Light Norwegianisation of the English category values in the data. The raw
 * value is kept as the canonical filter key; this is display-only. */
const CATEGORY_LABEL_NO: Record<string, string> = {
  Café: "Kafé",
  Cafe: "Kafé",
  "Food hall": "Mathall",
  Restaurant: "Restaurant",
  Bar: "Bar",
  Park: "Park",
  Beach: "Strand",
  Sight: "Severdighet",
};

export function iconForCategory(category?: string): IconName {
  if (!category) return "paw";
  return CATEGORY_ICON[category] ?? "paw";
}

export function iconPath(category?: string): string {
  return `/icons/${iconForCategory(category)}.svg`;
}

export function categoryLabel(category?: string): string {
  if (!category) return "Sted";
  return CATEGORY_LABEL_NO[category] ?? category;
}
