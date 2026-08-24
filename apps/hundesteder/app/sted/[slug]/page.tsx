import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { fetchPlaces, fetchPlaceBySlug } from "@/lib/places";
import { addressLines } from "@/lib/address";
import { categoryLabel, iconPath } from "@/lib/categories";
import { PlacesMap } from "@/components/places-map";

/** Pre-render every place at build time (the dataset is tiny). */
export async function generateStaticParams() {
  const places = await fetchPlaces();
  return places.map((p) => ({ slug: p.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const place = await fetchPlaceBySlug(slug);
  if (!place) return { title: "Stedet finnes ikke" };
  return {
    title: place.title,
    description:
      place.description ??
      `${place.title} — et hundevennlig sted i ${place.city ?? "Norge"}.`,
  };
}

export default async function PlaceDetailPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const place = await fetchPlaceBySlug(slug);
  if (!place) notFound();

  const address = addressLines(place);

  return (
    <article className="container detail">
      <Link href="/steder" className="back-link">
        ← Tilbake til alle steder
      </Link>

      <div className="detail__head">
        <span className="cat-pill">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={iconPath(place.category)} alt="" aria-hidden />
          {categoryLabel(place.category)}
        </span>
        {place.city ? (
          <span className="detail__city">{place.city}</span>
        ) : null}
        {place.priceRange ? (
          <span className="detail__price">{place.priceRange}</span>
        ) : null}
      </div>

      <h1>{place.title}</h1>

      {place.description ? (
        <p className="ingress">{place.description}</p>
      ) : null}

      {place.tags.length > 0 ? (
        <div className="tag-row">
          {place.tags.map((t) => (
            <span key={t} className="tag">
              {t.replace(/_/g, " ")}
            </span>
          ))}
        </div>
      ) : null}

      <div className="detail-grid">
        <div className="map-frame map-frame--detail">
          <PlacesMap
            places={[place]}
            initialView={{ lng: place.lng, lat: place.lat, zoom: 14 }}
          />
        </div>

        <div className="info-block">
          <h2>Praktisk</h2>

          {address ? (
            <div className="info-row">
              <span className="info-row__label">Adresse</span>
              <span className="info-row__value">
                {address.map((l, i) => (
                  <span key={l}>
                    {i > 0 ? <br /> : null}
                    {l}
                  </span>
                ))}
              </span>
            </div>
          ) : place.city ? (
            <div className="info-row">
              <span className="info-row__label">Sted</span>
              <span className="info-row__value">{place.city}</span>
            </div>
          ) : null}

          <div className="info-row">
            <span className="info-row__label">Kategori</span>
            <span className="info-row__value">
              {categoryLabel(place.category)}
            </span>
          </div>

          <div className="info-row">
            <span className="info-row__label">Veibeskrivelse</span>
            <span className="info-row__value">
              <a
                href={`https://www.openstreetmap.org/?mlat=${place.lat}&mlon=${place.lng}#map=16/${place.lat}/${place.lng}`}
                target="_blank"
                rel="noreferrer"
              >
                Åpne i kart ↗
              </a>
            </span>
          </div>

          {place.websiteUrl ? (
            <a
              href={place.websiteUrl}
              target="_blank"
              rel="noreferrer"
              className="website-link"
            >
              Besøk nettsiden ↗
            </a>
          ) : null}
        </div>
      </div>
    </article>
  );
}
