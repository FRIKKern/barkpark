import Link from "next/link";
import type { Place } from "@/lib/places";
import { categoryLabel, iconPath } from "@/lib/categories";

export function PlaceCard({ place }: { place: Place }) {
  return (
    <Link href={`/sted/${place.slug}`} className="place-card">
      <div className="place-card__top">
        <span className="place-card__cat">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={iconPath(place.category)} alt="" aria-hidden />
          {categoryLabel(place.category)}
        </span>
        {place.city ? (
          <span className="place-card__city">{place.city}</span>
        ) : null}
      </div>
      <h3 className="place-card__title">{place.title}</h3>
      {place.description ? (
        <p className="place-card__desc">{place.description}</p>
      ) : null}
      <div className="place-card__foot">
        {place.priceRange ? <span>{place.priceRange}</span> : <span />}
        <span className="place-card__cta">Se stedet →</span>
      </div>
    </Link>
  );
}
