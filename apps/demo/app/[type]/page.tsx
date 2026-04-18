import Link from "next/link";
import { notFound } from "next/navigation";
import { headers } from "next/headers";
import type { BarkparkQueryResult } from "@/lib/barkpark";

export const dynamic = "force-dynamic";

async function originFromHeaders(): Promise<string> {
  const h = await headers();
  const host = h.get("host") ?? "localhost:3000";
  const proto = h.get("x-forwarded-proto") ?? "http";
  return `${proto}://${host}`;
}

export default async function TypePage({
  params,
}: {
  params: Promise<{ type: string }>;
}) {
  const { type } = await params;
  const origin = await originFromHeaders();
  const res = await fetch(
    `${origin}/api/barkpark/query/${encodeURIComponent(type)}`,
    { next: { revalidate: 60 } },
  );
  if (!res.ok) {
    if (res.status === 404) notFound();
    return (
      <section>
        <p>
          <Link href="/">&larr; Back</Link>
        </p>
        <h2>{type}</h2>
        <p style={{ color: "#a00" }}>
          Upstream error ({res.status}). Confirm BARKPARK_API_URL and
          BARKPARK_PUBLIC_READ_TOKEN are set.
        </p>
      </section>
    );
  }
  const result = (await res.json()) as BarkparkQueryResult;
  const docs = result.documents ?? [];
  return (
    <section>
      <p>
        <Link href="/">&larr; Back</Link>
      </p>
      <h2>{type}</h2>
      <p style={{ color: "#666" }}>{result.count} published document(s)</p>
      {docs.length === 0 ? (
        <p>No published documents of this type.</p>
      ) : (
        <ul>
          {docs.map((doc) => {
            const title =
              (doc.title as string | undefined) ??
              (doc.name as string | undefined) ??
              doc._id;
            return (
              <li key={doc._id}>
                <Link href={`/${type}/${encodeURIComponent(doc._id)}`}>
                  {title}
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
