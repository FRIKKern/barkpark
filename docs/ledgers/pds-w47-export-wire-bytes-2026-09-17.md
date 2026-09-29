<!-- doc-tier: agent | canonical-for: pds-export-wire-bytes-and-vary | budget: 3500tok -->

# PDS-D204 aftermath — the export's WIRE BYTES, and the missing `vary: accept-encoding`

**What this is.** The paired wire-byte measurement the PDS-D204 transport move
(`send_resp/3` → `send_file/3` on `GET /api/workspaces/:slug/export`) owes, plus the
Vary decision, measured 2026-09-17 against the deployed guerrilla stack. Row:
`pds-bl-export-wire-bytes-and-vary-after-send-file`.

**Why it exists.** After the move the CLI transfers the tar UNCOMPRESSED. Anyone
benchmarking `bp cloud workspace export` wall-clock before vs after sees a regression
that is BANDWIDTH, not the spill engine. This record is so nobody re-derives it as an
engine defect.

---

## 1. What was measured, and how

ONE live `GET /api/workspaces/default/export?profile=dev` against
`https://guerrilla.barkpark.cloud`, 2026-09-17T16:31Z, offering `Accept-Encoding: gzip`
exactly as the Go CLI's transport does. Wire bytes read from curl's `%{size_download}`
(bytes off the socket, NOT a request count, NOT a decompressed payload size).

The BEFORE arm cannot be re-run — the transport it measures no longer exists — so it is
computed from the SAME bytes: `gzip -6` over the very tar the AFTER arm received.
`gzip -6` is zlib's default level, which is exactly what Bandit's `send_resp` path runs
(`Bandit.Compression.compress_chunk/2`, `:zlib.gzip(chunk)` — api/deps/bandit 1.12.0,
lib/bandit/compression.ex). Same corpus by construction: both arms are the identical
310,917,632 bytes, `sha256 6ecadf6812b850821063fdbff76e38389d9bfc3ac8380bf7cf38a45ad059b9ec`.
That is how the corpus was controlled while five lanes were writing the ledger — the two
arms are not two acquisitions, they are one acquisition measured twice.

| Arm | Transport | WIRE bytes | | Wall clock |
|---|---|---|---|---|
| AFTER (today) | `send_file/3`, identity | **310,917,632 B** | 296.51 MiB | 37.157 s total · 11.046 s TTFB (server-side tar build) · 26.11 s transfer @ 8.37 MB/s |
| BEFORE (PDS-D204 ancestor) | `send_resp/3` + Bandit gzip | **83,323,612 B** | 79.46 MiB | ~9.96 s transfer at the SAME measured 8.37 MB/s, plus ~7.2 s of server CPU to gzip (`gzip -6` user time, x86/arm64 laptop — the ARM64 box is slower) |

**Delta: +227,594,020 B (+217.05 MiB) on the wire, 3.731× more bytes, a 73.2 % saving
given up.** The receipt byte count on disk is UNCHANGED in both arms — Go decompresses
transparently — so only the wire moved.

**What this figure does NOT license.** `profile=dev` is DB tables only (16 `tables/*` +
`manifest.json`; `tar tf` census). The ~941 MB full bundle carries MEDIA BLOBS, which are
already-compressed bytes, so its ratio will be far below 3.731× and this number must not
be extrapolated onto it. Wall clock likewise: 8.37 MB/s is one link on one afternoon.

## 2. The mechanism, read from source — and the false explanation it replaces

`Bandit.Compression` (1.12.0) has **NO content-type filter**. It compresses ANY
`send_resp` body when the client offers gzip/x-gzip/deflate and the response is not
204/304, not already `content-encoding`-tagged, not strong-ETag'd, not `no-transform`,
and not empty. So the claim that "the stack refuses to gzip `application/x-tar`" —
which `internal/cli/cloud_workspace_cmd.go` carried until this record — is FALSE. The
tar arrives uncompressed for exactly one reason: `Bandit.Adapter.send_file/6` never
calls `Bandit.Compression.new/5` at all (`lib/bandit/adapter.ex`; `send_resp/4` and
`send_chunked/3` both do). Move the route back to `send_resp` and the tar WILL gzip,
and Go will strip `Content-Length` to -1 when it does.

The compression is Bandit's, not Caddy's, and that was proven rather than assumed: the
generated Caddyfile (`internal/caddyfile/caddyfile.go`) carries no `encode` directive,
and `Accept-Encoding: deflate` on `/api/schemas` returns `content-encoding: deflate` —
Caddy's `encode` speaks gzip/zstd only, so a deflate answer can only be Bandit's.

## 3. Vary — DELIBERATELY ABSENT, with the reason

Measured live on the same request. The `send_file` 200 carries **no**
`vary: accept-encoding` (full header set: `content-disposition`, `content-type:
application/x-tar`, `cache-control: max-age=0, private, must-revalidate`, `content-length`,
`via`, `x-request-id`, …). Every `send_resp` response on the same server carries it,
including under `Accept-Encoding: identity`, because `maybe_add_vary_header/3` adds it
unconditionally whenever `compress` is on.

**Decision: leave it absent.** Not restored, and not an oversight:

1. Vary declares which request headers the SELECTED REPRESENTATION depends on
   (RFC 9110 §12.5.5). The `send_file` representation depends on `Accept-Encoding`
   for nothing — it is byte-identical for every value of that header. A Vary here would
   describe a negotiation the route does not perform.
2. The response is `cache-control: max-age=0, private, must-revalidate`, so no shared
   cache stores it and the cache-poisoning failure Vary exists to prevent cannot arise.
3. Nothing in the tree reads it (census: no `vary` consumer on this route in
   `internal/` or `api/`).
4. Restoring it is an `api/` change on a route whose whole point is to avoid touching
   the response pipeline. If the route ever returns to `send_resp`, Bandit re-adds Vary
   by itself — there is nothing to remember.

FAILURE DIRECTION: if a shared cache is ever put in front of this route, or the route
starts genuinely varying its bytes by a request header, this decision is void and Vary
must be set explicitly.

## 4. The floor harness is still uncontaminated (re-confirmed 2026-09-17)

The 2235.43 MiB figure is an **RSS memory** delta, not a wire-byte figure, so it is not
what section 1 measures — but its acquisition must not have requested compression, or
the gzip CPU and buffering would sit inside the peak. Re-confirmed by census, not by
memory:

- `grep -in 'accept-encoding' scripts/pds-pull-proof.sh` → **no matches**.
- `grep -n compressed scripts/pds-pull-proof.sh` → **one** hit, line 1096, inside prose
  ("values inside compressed members"); `curl_src()` (line 472) passes neither.
- `scripts/pds-export-peak-measure.sh` does better than a promise: lines 252-253 `die`
  if the acquisition path smuggles `--compressed` or any `accept-encoding`. The control
  is MECHANICAL, so this re-confirmation cannot go stale silently.

So the floor re-derivation compares like with like against 2235.43 MiB, and section 1's
wire-byte delta is a separate, bandwidth-class quantity that must never be added to it
(the unit-mixing PDS-D232 already rejected once).

## 5. Re-run it

```
curl -sS -D headers.txt -o export.tar -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/x-tar, application/json" -H "Accept-Encoding: gzip" \
  -w 'wire=%{size_download} total=%{time_total} ttfb=%{time_starttransfer}\n' \
  "$SERVER/api/workspaces/default/export?profile=dev"
gzip -6 -c export.tar | wc -c        # the bytes the send_resp ancestor would have sent
grep -i vary headers.txt             # empty = the Vary decision above still holds
```

The CLI-side invariant has a Go arm that reds on reversion:
`go test ./internal/cli/ -run TestCloudWorkspaceExportWireByte`.
