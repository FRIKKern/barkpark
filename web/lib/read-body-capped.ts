/**
 * Read a request body as text, refusing past `max` bytes WITHOUT buffering the
 * rest. A declared Content-Length over the cap is refused before a byte is read;
 * an undeclared (streamed) body is counted chunk by chunk and cancelled at the
 * cap. Returns `null` when the body is too large.
 *
 * Used by the webhook route: the HMAC covers the whole body, so the body is read
 * before the sender is authenticated, and this cap is what keeps an unsigned
 * request from making the handler hold an arbitrary amount of memory.
 */
export const WEBHOOK_MAX_BODY_BYTES = 4 * 1024 * 1024;

export async function readBodyCapped(
  req: Request,
  max: number,
): Promise<string | null> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return null;
  if (req.body === null) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
