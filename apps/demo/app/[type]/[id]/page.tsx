import Link from "next/link";
import { notFound } from "next/navigation";
import { headers } from "next/headers";
import type { BarkparkDoc } from "@/lib/barkpark";

export const dynamic = "force-dynamic";

async function originFromHeaders(): Promise<string> {
  const h = await headers();
  const host = h.get("host") ?? "localhost:3000";
  const proto = h.get("x-forwarded-proto") ?? "http";
  return `${proto}://${host}`;
}

export default async function DocPage({
  params,
}: {
  params: Promise<{ type: string; id: string }>;
}) {
  const { type, id } = await params;
  const origin = await originFromHeaders();
  const res = await fetch(
    `${origin}/api/barkpark/doc/${encodeURIComponent(type)}/${encodeURIComponent(id)}`,
    { next: { revalidate: 60 } },
  );
  if (!res.ok) {
    if (res.status === 404) notFound();
    return (
      <section>
        <p>
          <Link href={`/${type}`}>&larr; Back</Link>
        </p>
        <h2>
          {type} / {id}
        </h2>
        <p style={{ color: "#a00" }}>
          Upstream error ({res.status}). Confirm env vars are set.
        </p>
      </section>
    );
  }
  const payload = (await res.json()) as
    | { document: BarkparkDoc }
    | BarkparkDoc;
  const doc: BarkparkDoc =
    (payload as { document?: BarkparkDoc }).document ??
    (payload as BarkparkDoc);
  const title =
    (doc.title as string | undefined) ??
    (doc.name as string | undefined) ??
    doc._id;
  return (
    <section>
      <p>
        <Link href={`/${type}`}>&larr; Back to {type}</Link>
      </p>
      <h2>{title}</h2>
      <dl style={{ fontSize: "0.9rem", color: "#666" }}>
        <div>
          <strong>_id:</strong> {doc._id}
        </div>
        <div>
          <strong>_type:</strong> {doc._type}
        </div>
        {doc._updatedAt && (
          <div>
            <strong>updated:</strong> {String(doc._updatedAt)}
          </div>
        )}
      </dl>
      <pre
        style={{
          background: "#f6f6f6",
          padding: "1rem",
          borderRadius: "4px",
          overflow: "auto",
          fontSize: "0.85rem",
        }}
      >
        {JSON.stringify(doc, null, 2)}
      </pre>
    </section>
  );
}
