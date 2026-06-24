import Link from "next/link";

export default function NotFound() {
  return (
    <section className="container detail" style={{ textAlign: "center" }}>
      <span className="eyebrow">404</span>
      <h1>Stedet finnes ikke</h1>
      <p className="ingress" style={{ marginInline: "auto" }}>
        Vi fant ikke siden eller stedet du lette etter. Det kan ha flyttet, eller
        så har lenken en skrivefeil.
      </p>
      <Link href="/steder" className="website-link">
        Se alle steder →
      </Link>
    </section>
  );
}
