import { NextResponse } from "next/server";
import { PUBLIC_SCHEMAS } from "@/lib/public-schemas";

export const dynamic = "force-dynamic";

export async function GET() {
  return NextResponse.json({
    schemas: PUBLIC_SCHEMAS.map((type) => ({ type })),
    source: "fallback",
  });
}
