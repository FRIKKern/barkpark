"use client";

import { useMemo, useState } from "react";
import type { Place } from "@/lib/places";
import { categoryLabel, iconPath } from "@/lib/categories";
import { PlaceCard } from "@/components/place-card";

export function PlacesBrowser({ places }: { places: Place[] }) {
  const [city, setCity] = useState<string | null>(null);
  const [category, setCategory] = useState<string | null>(null);

  const cities = useMemo(
    () =>
      Array.from(new Set(places.map((p) => p.city).filter(Boolean))).sort(
        (a, b) => (a as string).localeCompare(b as string, "nb"),
      ) as string[],
    [places],
  );

  const categories = useMemo(
    () =>
      Array.from(
        new Set(places.map((p) => p.category).filter(Boolean)),
      ) as string[],
    [places],
  );

  const filtered = useMemo(
    () =>
      places.filter(
        (p) =>
          (city === null || p.city === city) &&
          (category === null || p.category === category),
      ),
    [places, city, category],
  );

  return (
    <>
      <div className="filters">
        <div className="filter-group">
          <span className="filter-group__label">By</span>
          <div className="chip-row">
            <button
              type="button"
              className="chip"
              aria-pressed={city === null}
              onClick={() => setCity(null)}
            >
              Alle byer
            </button>
            {cities.map((c) => (
              <button
                key={c}
                type="button"
                className="chip"
                aria-pressed={city === c}
                onClick={() => setCity((cur) => (cur === c ? null : c))}
              >
                {c}
              </button>
            ))}
          </div>
        </div>

        <div className="filter-group">
          <span className="filter-group__label">Kategori</span>
          <div className="chip-row">
            <button
              type="button"
              className="chip"
              aria-pressed={category === null}
              onClick={() => setCategory(null)}
            >
              Alle kategorier
            </button>
            {categories.map((c) => (
              <button
                key={c}
                type="button"
                className="chip"
                aria-pressed={category === c}
                onClick={() => setCategory((cur) => (cur === c ? null : c))}
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={iconPath(c)} alt="" aria-hidden />
                {categoryLabel(c)}
              </button>
            ))}
          </div>
        </div>
      </div>

      <p className="results-meta" aria-live="polite">
        Viser <b>{filtered.length}</b> av {places.length} steder
        {city ? ` i ${city}` : ""}
        {category ? ` · ${categoryLabel(category)}` : ""}
      </p>

      {filtered.length === 0 ? (
        <p className="empty-state">
          Ingen steder passer filteret. Prøv en annen by eller kategori.
        </p>
      ) : (
        <div className="card-grid">
          {filtered.map((place) => (
            <PlaceCard key={place.id} place={place} />
          ))}
        </div>
      )}
    </>
  );
}
