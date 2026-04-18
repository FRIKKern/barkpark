import { NextResponse } from "next/server";
import { barkparkFetch, type BarkparkQueryResult } from "@/lib/barkpark";

export const dynamic = "force-dynamic";

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ type: string }> },
) {
  const { type } = await params;
  try {
    const data = await barkparkFetch<BarkparkQueryResult>(
      `/v1/data/query/production/${encodeURIComponent(type)}?perspective=published`,
      { revalidate: 60 },
    );
    return NextResponse.json(data);
  } catch (err) {
    return NextResponse.json(
      { error: (err as Error).message },
      { status: 502 },
    );
  }
}
