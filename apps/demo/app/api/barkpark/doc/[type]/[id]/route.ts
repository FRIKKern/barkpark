import { NextResponse } from "next/server";
import { barkparkFetch, type BarkparkDoc } from "@/lib/barkpark";

export const dynamic = "force-dynamic";

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ type: string; id: string }> },
) {
  const { type, id } = await params;
  try {
    const data = await barkparkFetch<{ document: BarkparkDoc } | BarkparkDoc>(
      `/v1/data/doc/production/${encodeURIComponent(type)}/${encodeURIComponent(id)}?perspective=published`,
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
