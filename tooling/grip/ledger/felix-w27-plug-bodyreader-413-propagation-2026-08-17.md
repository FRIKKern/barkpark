# felix-w27 · body_reader cap → 413 propagation (plug-bodyreader-413)

Re-derivation recipe for: a CacheBodyReader per-route cap must return `{:more, _, conn}`
(NOT `{:error, :too_large}`) to guarantee the canonical 413 `payload_too_large` envelope.

## Re-derive the propagation chain (pinned deps + endpoint)

```
# 1. json parser calls the body_reader ONCE, pipes to decode/3
sed -n '71,116p' api/deps/plug/lib/plug/parsers/json.ex
#   :73  apply(mod,fun,[conn,opts|args]) |> decode(...)        # body_reader = CacheBodyReader
#   :104 decode({:more,_,conn},...)  -> {:error,:too_large,conn}   # <-- the 413 seam
#   :113 decode({:error,:timeout},...) -> raise Plug.TimeoutError  # 408
#   :115 decode({:error,_},...)        -> raise Plug.BadRequestError# 400, NOT enveloped

# 2. parsers.reduce turns :too_large into the 413 exception
sed -n '346,351p' api/deps/plug/lib/plug/parsers.ex
#   :349 {:error,:too_large,_conn} -> raise RequestTooLargeError
sed -n '2,11p' api/deps/plug/lib/plug/parsers.ex        # RequestTooLargeError plug_status: 413

# 3. endpoint rescues it into the canonical envelope
grep -n -B1 -A6 'RequestTooLargeError' api/lib/barkpark_web/endpoint.ex
#   :172 Plug.Parsers.RequestTooLargeError -> parse_error_json(413,%{code:"payload_too_large",...})
#   NOTE: parse_body rescues ONLY ParseError + RequestTooLargeError.

# 4. Plug.BadRequestError plug_status
sed -n '56,62p' api/deps/plug/lib/plug/exceptions.ex     # plug_status: 400

# 5. body_reader contract (2-tuple error!) + Plug.Conn.read_body shapes
sed -n '38,56p' api/lib/barkpark_web/plugs/cache_body_reader.ex
sed -n '1183,1194p' api/deps/plug/lib/plug/conn.ex       # {:ok|:more, data, conn} | {:error, reason}
```

## Verdict

- `{:more, chunk, conn}`  → json.ex → `{:error,:too_large,conn}` → RequestTooLargeError(413) → endpoint envelope. CANONICAL. ✓
- `{:error, :too_large}` (2-tuple) or any `{:error, reason}` → json.ex → **Plug.BadRequestError (400)**, which endpoint's
  parse_body does NOT rescue → escapes as a generic, NON-enveloped 400. Wrong on BOTH status and envelope. ✗
- `{:error, :timeout}` → Plug.TimeoutError (408). ✗

## Recommendation for the webhook 25 MB cap slice

Clean, no envelope shim. In `CacheBodyReader.read_body/2`, on the webhook path, read with a reduced `:length`
(`Plug.Conn.read_body(conn, Keyword.put(opts, :length, @webhook_cap))`); Plug.Conn.read_body returns
`{:more, chunk, conn}` the moment the body exceeds the cap. Return that `{:more, ...}` verbatim. It rides the
EXISTING seam (json → too_large → RequestTooLargeError → the 413 branch already in endpoint.ex:172). The parser
calls the body_reader exactly once (json.ex:73 — a single `apply`, no loop), so `{:more,...}` will not trigger a
re-read; it flows straight to `:too_large`. Do NOT return `{:error, :too_large}` — that is the 400 trap.
