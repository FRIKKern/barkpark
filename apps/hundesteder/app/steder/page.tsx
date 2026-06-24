import type { Metadata } from "next";
import { fetchPlaces } from "@/lib/places";
import { PlacesBrowser } from "@/components/places-browser";

export const metadata: Metadata = {
  title: "Alle steder",
  description:
    "Bla gjennom alle hundevennlige steder i Norge. Filtrer på by og kategori.",
};

export default async function StederPage() {
  const places = await fetchPlaces();

  return (
    <section className="container section-tight">
      <span className="eyebrow">Katalog</span>
      <h1>Alle steder</h1>
      <p className="ingress" style={{ maxWidth: "var(--measure-base)" }}>
        Hele utvalget av hundevennlige steder, samlet på ett sted. Filtrer på by
        og kategori for å finne fram.
      </p>

      {places.length === 0 ? (
        <p className="empty-state">
          Ingen steder å vise akkurat nå. Prøv igjen om litt.
        </p>
      ) : (
        <PlacesBrowser places={places} />
      )}
    </section>
  );
}
