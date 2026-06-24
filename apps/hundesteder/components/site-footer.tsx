import Link from "next/link";

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="container site-footer__inner">
        <div className="stack-sm">
          <div className="site-footer__brand">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/icons/pawtrails-mark.svg" alt="" aria-hidden />
            <span>Hundesteder</span>
          </div>
          <p className="site-footer__note">
            En redaksjonell guide til hundevennlige steder i Norge — kafeer,
            parker, strender og severdigheter der hunden er velkommen.
          </p>
        </div>
        <nav className="site-footer__links" aria-label="Bunnmeny">
          <Link href="/">Forsiden</Link>
          <Link href="/steder">Alle steder</Link>
        </nav>
      </div>
    </footer>
  );
}
