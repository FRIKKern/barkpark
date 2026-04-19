import { NextResponse } from "next/server";

export function GET() {
  return NextResponse.redirect("https://github.com/FRIKKern/barkpark#readme", 307);
}
