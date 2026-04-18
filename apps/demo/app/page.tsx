import Link from "next/link";
import { PUBLIC_SCHEMAS } from "@/lib/public-schemas";

export const dynamic = "force-dynamic";

export default function HomePage() {
  return (
    <section>
      <h2>Content types</h2>
      <ul>
        {PUBLIC_SCHEMAS.map((type) => (
          <li key={type}>
            <Link href={`/${type}`}>{type}</Link>
          </li>
        ))}
      </ul>
      <p style={{ color: "#666", marginTop: "2rem", fontSize: "0.9rem" }}>
        Read-only view of published documents. All API calls are server-side —
        the browser never talks to the Barkpark API directly.
      </p>
    </section>
  );
}
