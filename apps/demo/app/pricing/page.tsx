export const dynamic = "force-static";

export const metadata = {
  title: "Pricing — Barkpark",
  description:
    "Self-host Barkpark for free forever. Apache-2.0 licensed. Hosted tier coming after 1.0.",
};

export default function PricingPage() {
  return (
    <section>
      <h1 style={{ marginBottom: "0.5rem" }}>Pricing</h1>
      <p style={{ color: "#555", marginBottom: "2.5rem", fontSize: "1.05rem" }}>
        Self-host for free forever. Apache-2.0 licensed.
      </p>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))",
          gap: "1.5rem",
          marginTop: "1rem",
        }}
      >
        <article
          style={{
            border: "1px solid #ddd",
            borderRadius: "8px",
            padding: "1.5rem",
            background: "#fafafa",
          }}
        >
          <h2 style={{ marginTop: 0 }}>Open Source</h2>
          <p style={{ fontSize: "1.25rem", fontWeight: 600, margin: "0.5rem 0 1rem" }}>
            Free
          </p>
          <ul style={{ paddingLeft: "1.25rem", lineHeight: 1.7 }}>
            <li>Unlimited documents, schemas, and projects.</li>
            <li>Apache-2.0 licensed — run it anywhere you can run Elixir.</li>
            <li>Community support via GitHub issues and discussions.</li>
            <li>All 1.0 features — GROQ and cross-type queries land in 1.1.</li>
          </ul>
        </article>

        <article
          style={{
            border: "1px dashed #bbb",
            borderRadius: "8px",
            padding: "1.5rem",
            background: "#fff",
          }}
        >
          <h2 style={{ marginTop: 0 }}>Coming later: Hosted</h2>
          <p style={{ fontSize: "1.05rem", color: "#555", margin: "0.5rem 0 1rem" }}>
            We will offer a hosted tier after 1.0. Sign up via email to know
            when.
          </p>
          <p style={{ color: "#777", fontSize: "0.9rem", margin: 0 }}>
            No ETA. No waitlist priority. Just an email when it ships.
          </p>
        </article>
      </div>
    </section>
  );
}
