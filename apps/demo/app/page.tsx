import Link from "next/link";

export const metadata = {
  title: "Barkpark — Headless CMS for Next.js",
  description:
    "Apache-2.0 headless CMS for the Next.js App Router. Self-host in one command.",
};

const heroStyle: React.CSSProperties = {
  textAlign: "center",
  padding: "3rem 1rem 2rem",
};

const titleStyle: React.CSSProperties = {
  fontSize: "2.25rem",
  lineHeight: 1.15,
  margin: "0 0 0.75rem",
  letterSpacing: "-0.02em",
};

const subtitleStyle: React.CSSProperties = {
  fontSize: "1.125rem",
  color: "#444",
  margin: "0 auto 1.75rem",
  maxWidth: "36rem",
};

const ctaRowStyle: React.CSSProperties = {
  display: "flex",
  gap: "0.75rem",
  justifyContent: "center",
  flexWrap: "wrap",
  marginBottom: "0.5rem",
};

const primaryCtaStyle: React.CSSProperties = {
  display: "inline-block",
  padding: "0.75rem 1.5rem",
  background: "#111",
  color: "#fff",
  borderRadius: "0.375rem",
  textDecoration: "none",
  fontWeight: 600,
  border: "1px solid #111",
};

const secondaryCtaStyle: React.CSSProperties = {
  display: "inline-block",
  padding: "0.75rem 1.5rem",
  background: "#fff",
  color: "#111",
  borderRadius: "0.375rem",
  textDecoration: "none",
  fontWeight: 600,
  border: "1px solid #d0d0d0",
};

const featureGridStyle: React.CSSProperties = {
  display: "grid",
  gridTemplateColumns: "repeat(auto-fit, minmax(15rem, 1fr))",
  gap: "1rem",
  margin: "2.5rem 0",
};

const cardStyle: React.CSSProperties = {
  border: "1px solid #e5e5e5",
  borderRadius: "0.5rem",
  padding: "1.25rem",
  background: "#fafafa",
};

const cardTitleStyle: React.CSSProperties = {
  margin: "0 0 0.5rem",
  fontSize: "1.0625rem",
};

const cardBodyStyle: React.CSSProperties = {
  margin: 0,
  color: "#555",
  fontSize: "0.95rem",
};

const features = [
  {
    title: "TypeScript-first",
    body: "Generated types from your schemas. End-to-end type-safe queries from RSC to client.",
  },
  {
    title: "Real-time Studio",
    body: "Multi-pane editor with live presence. Draft → publish workflow with SSE updates.",
  },
  {
    title: "Zero vendor lock-in",
    body: "Apache-2.0. Self-host on any VPS. Postgres + Phoenix backend you fully control.",
  },
];

export default function HomePage() {
  return (
    <>
      <section style={heroStyle}>
        <h2 style={titleStyle}>
          Headless CMS for Next.js. Apache-2.0. Self-host in one command.
        </h2>
        <p style={subtitleStyle}>
          Barkpark is the open-source alternative to hosted CMSes — built for
          the Next.js App Router, with a real Studio, real-time updates, and
          no per-seat pricing.
        </p>
        <div style={ctaRowStyle}>
          <Link href="/docs" style={primaryCtaStyle}>
            Get Started
          </Link>
          <Link href="/post" style={secondaryCtaStyle}>
            View Live Demo
          </Link>
        </div>
      </section>

      <section style={featureGridStyle}>
        {features.map((feature) => (
          <article key={feature.title} style={cardStyle}>
            <h3 style={cardTitleStyle}>{feature.title}</h3>
            <p style={cardBodyStyle}>{feature.body}</p>
          </article>
        ))}
      </section>
    </>
  );
}
