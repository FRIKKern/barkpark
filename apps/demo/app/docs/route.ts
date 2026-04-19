import { NextResponse } from "next/server";

export function GET() {
  return NextResponse.redirect("https://docs.barkpark.cloud/", 308);
}
