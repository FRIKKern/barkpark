import { NextResponse } from "next/server";
import { revalidateTag } from "next/cache";
import { FIND_TAG } from "@/lib/find-search";

// Bust the find Data Cache on demand — next cached query pays a cold miss again
// (makes the cold-vs-warm benchmark repeatable). No upstream call; pure Next.
export const runtime = "nodejs";

export async function POST(): Promise<NextResponse> {
  // Next 16: revalidateTag(tag, profile). `{ expire: 0 }` purges immediately.
  revalidateTag(FIND_TAG, { expire: 0 });
  return NextResponse.json({ ok: true, revalidated: FIND_TAG });
}
