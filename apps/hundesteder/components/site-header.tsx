import Link from "next/link";

export function SiteHeader() {
  return (
    <header className="site-header">
      <div className="container site-header__inner">
        <Link href="/" className="brand" aria-label="Hundesteder — til forsiden">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/icons/pawtrails-mark.svg"
            alt=""
            className="brand__mark"
            aria-hidden
          />
          <span className="brand__name">
            Hunde<b>steder</b>
          </span>
        </Link>
        <nav className="nav" aria-label="Hovedmeny">
          <Link href="/" className="nav__link">
            Forsiden
          </Link>
          <Link href="/steder" className="nav__link">
            Alle steder
          </Link>
        </nav>
      </div>
    </header>
  );
}
