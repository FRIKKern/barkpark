import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  title: "Barkpark Demo",
  description: "Read-only hosted demo",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body
        style={{
          fontFamily: "system-ui",
          padding: "2rem",
          maxWidth: "60rem",
          margin: "0 auto",
          lineHeight: 1.5,
          color: "#111",
        }}
      >
        <header style={{ marginBottom: "2rem" }}>
          <h1 style={{ margin: 0, fontSize: "1.5rem" }}>
            <a href="/" style={{ color: "inherit", textDecoration: "none" }}>
              Barkpark Demo
            </a>
          </h1>
          <p style={{ color: "#666", margin: "0.25rem 0 0" }}>
            Read-only public snapshot
          </p>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
