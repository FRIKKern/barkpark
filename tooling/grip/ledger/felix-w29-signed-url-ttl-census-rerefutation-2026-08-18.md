# Felix w29 — signed_url TTL re-refutation (D184/D190 census)

VERDICT: REFUTED (leave the facade, no build). The `:ttl` opt on `SignedUrl.sign/3`
is reachable only from tests; no api/ app caller threads a request-derived TTL.

## Facts (re-derivable)

- Signer default: `api/lib/barkpark/media/storage/signed_url.ex:9` `@default_ttl 60*60*24*7`
  (7 days); `:14` `exp = System.system_time(:second) + Keyword.get(opts, :ttl, @default_ttl)`.
- Facade: `api/lib/barkpark/media/storage.ex:44` `def sign(path, media_file_id, opts \\ [])`
  → `SignedUrl.sign`. ZERO callers anywhere (lib or test).
- Sole prod caller: `api/lib/barkpark/media/delivery/urls.ex:147` `SignedUrl.sign(path, file.id)`
  — no opts arg, so `:ttl` always resolves to compile-time `@default_ttl`.

## Rerun

    grep -rIn --include='*.ex' -E '\bStorage\.sign\b|SignedUrl\.sign\b' api/lib api/test | grep -v 'def sign'
    # => only api/lib/barkpark/media/delivery/urls.ex:147 (no opts)
    cd api && MIX_ENV=test mix test test/barkpark/media/signed_url_test.exs
    # => 3 tests, 0 failures (round-trip / expired / tampered)
