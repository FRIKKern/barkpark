import "server-only";
import { createClient, type BarkparkClient } from "@barkpark/core";

// TODO(Task #32): remove this shim when @barkpark/nextjs >= 1.0.0-preview.3 is installed.
// SDK 1.0.0-preview.2 expects a flat `{documents:[...]}` response from
// /v1/data/query/..., but Phoenix returns `{result:{documents:[...]}}`. We unwrap
// the `result` envelope before the SDK parses it. Tracked as Doey Task #32.

const projectUrl = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";

const shimmedFetch: typeof fetch = async (input, init) => {
  const res = await globalThis.fetch(input as RequestInfo | URL, init);
  const contentType = res.headers.get("content-type") ?? "";
  // Phoenix uses `application/vnd.barkpark+json` for envelope responses; also
  // accept plain `application/json` for forward-compat.
  const isJson = /\bjson\b/i.test(contentType);
  if (!res.ok || !isJson) return res;

  const body = await res.text();
  if (body.length === 0) return res;

  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return new Response(body, { status: res.status, headers: stripEncoding(res.headers) });
  }

  const unwrapped =
    parsed !== null &&
    typeof parsed === "object" &&
    "result" in parsed &&
    (parsed as Record<string, unknown>).result !== undefined
      ? (parsed as { result: unknown }).result
      : parsed;

  return new Response(JSON.stringify(unwrapped), {
    status: res.status,
    headers: stripEncoding(res.headers),
  });
};

function stripEncoding(headers: Headers): Headers {
  const out = new Headers();
  headers.forEach((value, key) => {
    const lk = key.toLowerCase();
    if (lk === "content-encoding" || lk === "content-length") return;
    out.set(key, value);
  });
  return out;
}

export const client: BarkparkClient = createClient({
  projectUrl,
  dataset: "production",
  apiVersion: "2026-04-01",
  perspective: "published",
  fetch: shimmedFetch,
});
