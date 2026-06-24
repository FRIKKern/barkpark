import { fetchPlaces } from "@/lib/places";
import { PlaceCard } from "@/components/place-card";
import { PlacesMap } from "@/components/places-map";

export default async function HomePage() {
  const places = await fetchPlaces();
  const cities = Array.from(new Set(places.map((p) => p.city).filter(Boolean)));

  return (
    <>
      <section className="hero">
        <div className="container">
          <div className="hero__inner">
            <span className="eyebrow">Hundesteder</span>
            <h1>Hundevennlige steder, fra Oslo til Tromsø.</h1>
            <p className="ingress">
              En redaksjonell guide til kafeer, parker, strender og
              severdigheter rundt om i Norge der hunden er like velkommen som
              deg. Utvalgt for hånd, med vannskål ved døra.
            </p>
            <div className="hero__meta">
              <span>
                <b>{places.length}</b> steder
              </span>
              <span>
                <b>{cities.length}</b> byer
              </span>
              <span>Oppdatert løpende</span>
            </div>
          </div>
        </div>
      </section>

      <section className="container map-block">
        <div className="map-frame">
          <PlacesMap places={places} />
        </div>
        <div className="map-hint" role="note">
          <svg
            width="22"
            height="22"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden
          >
            <path d="M12 2 C8 2, 5 5, 5 9 C5 14, 12 22, 12 22 C12 22, 19 14, 19 9 C19 5, 16 2, 12 2 Z" />
            <circle cx="12" cy="9" r="2.5" />
          </svg>
          <span>
            Kartet vises på større skjermer. Bla ned for å se alle stedene som
            kort.
          </span>
        </div>
      </section>

      <section className="container section">
        <div className="section-head">
          <h2>Utvalgte steder</h2>
          <span className="section-head__count">
            {places.length} steder i {cities.length} byer
          </span>
        </div>

        {places.length === 0 ? (
          <p className="empty-state">
            Ingen steder å vise akkurat nå. Prøv igjen om litt.
          </p>
        ) : (
          <div className="card-grid">
            {places.map((place) => (
              <PlaceCard key={place.id} place={place} />
            ))}
          </div>
        )}
      </section>
    </>
  );
}
