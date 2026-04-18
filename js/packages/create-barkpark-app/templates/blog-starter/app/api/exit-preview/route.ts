import { draftMode } from 'next/headers'
import { NextResponse } from 'next/server'

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const redirectPath = url.searchParams.get('path') ?? '/'
  const dm = await draftMode()
  dm.disable()
  return NextResponse.redirect(new URL(redirectPath, url.origin), { status: 307 })
}

export async function POST(req: Request): Promise<Response> {
  return GET(req)
}
