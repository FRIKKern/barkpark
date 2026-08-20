<!-- doc-tier: cold | canonical-for: v2-media-wrongtype-cast-scope-rederivation | budget: 900tok -->

# V2 — media.ts/search.ts wrong-type cast scope re-derivation (2026-08-18)

VERDICT: truthy-wrong-type hardening on `media.ts` response casts is OUT OF SCOPE
(SAFE-BY-CONTRACT). The `??` already covers every value the server can emit.
No internal SDK loop amplifies a wrong-type `hasMore`. Recommend: do not build;
file only as LOW defensive-depth if desired.

## Re-derivation recipes

Server always emits typed hits/total/hasMore/nextCursor (origin/main):

    git show origin/main:api/lib/barkpark_web/controllers/v1/media_controller.ex | sed -n '28,96p'

Decisive lines:
- `hits = Enum.map(files, fn file -> AssetResponse.render(...) end)` → always a list.
- `has_more = length(files) >= limit and offset + length(files) < total` → always a bool.
- `next_cursor = if has_more, do: ...next_cursor(files), else: nil` → string | nil.
- `total` from `{files, total, facets, meta} = Media.search_files(...)` → integer (nil-safe via `?? 0`).
- The `result:` map hardcodes all four keys → never omitted, never scalar-wrong-typed.

No amplifying loop consumes hasMore/nextCursor in the SDK:

    git grep -n 'hasMore\|nextCursor\|\.hits' js/packages/core/src js/packages/nextjs/src

Only hits: media.ts:308/312/313 (assignment site) + types.ts declarations. No
`for await`/`while` reads hasMore/nextCursor (export.ts/listen.ts loops are NDJSON/SSE
stream iterators, unrelated). list/search return ONE page; the caller loops externally.

## Reasoning

The `(inner.X as T) ?? default` casts defend against undefined/null (omitted field).
The origin/main server structurally cannot omit these keys nor emit a scalar-wrong type
for them. A wrong-type fix would defend only against a NON-CONFORMING server — a
contract violation the counterpart provably cannot produce. No red-first test can
exercise a reachable path without fabricating a rogue server, which the wave charter
excludes ("do NOT manufacture"). Therefore: cite as SAFE, not a finding.
