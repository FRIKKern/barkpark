import { redirect } from "next/navigation";

/** The finder is now the frontpage. Keep `/find` as a permanent alias so old
 * links (and bookmarked queries) still work — preserve the query string. */
export default async function FindRedirect({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const sp = await searchParams;
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(sp)) {
    if (typeof v === "string") qs.set(k, v);
    else if (Array.isArray(v) && v[0]) qs.set(k, v[0]);
  }
  const s = qs.toString();
  redirect(s ? `/?${s}` : "/");
}
