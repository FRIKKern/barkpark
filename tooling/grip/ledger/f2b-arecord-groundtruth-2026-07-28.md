# F2b A-record leak — design-pack ground truth — 2026-07-28 (wave verifier: v-arecord-groundtruth)

**VERDICT: option A (CLI-only fix) is SAFE on caller-count, but the wound-task's premise is
half wrong and the naive fix UNDER-CLEANS.** Four corrections:

1. **The route has three callers, not one** — `internal/cli/cloud_support_cmd.go:1150` plus
   `scripts/pdf-mvp0-journey-proof.sh:408` (crash-trap) and `:1499` (R5 teardown). Both script
   sites are *raw CP-row* deletes that run only AFTER `bp cloud support remove` (`:402`, `:1435`),
   so a CLI-side DNS delete does cover them. **The deployed SPA is NOT a caller**: the single
   `fleet/supports` hit in the live `app.js` is a **POST** (`:6066`, `mode:"provision"`), and the
   deployed bundle is byte-identical to `origin/main` (sha256 `b16967f2b99d4891…`).
2. **The task says "fix both surfaces" — the CP surface cannot be fixed cheaply.** The Elixir CP
   has NO Hetzner DNS client (`git grep -i 'rrset\|dns.hetzner'` over `cloud/**` → zero hits);
   its only DNS client is **Cloudflare** (`cloud/lib/barkpark_cloud/cloudflare/real.ex`, for
   customer custom domains). A CP-side fix means building a Hetzner DNS client in Elixir or
   enqueueing a job for the Go provisioner (which already has one) — Layer construction this wave
   forbids. **Option A is the only lean route.**
3. **Two credentials, and the teardown credential is the WRONG one.** The zone lives in the
   GUERRILLA project; the FLEET project (`hcloud` context `barkpark`, the default
   `PDFJP_TEARDOWN_HCLOUD_CONTEXT`) sees **zero zones** (`GET /v1/zones` → `total_entries: 0`)
   while it owns every box. A CLI fix that reuses `HCLOUD_TOKEN` will fail the DNS leg in the
   journey-proof's own R5. The seam already exists and MUST be reused:
   `instDNSClient` (`internal/cli/hetzner_instance_cmd.go:161`) — `--dns-token >
   BARKPARK_DNS_HCLOUD_TOKEN > compute token`, mirroring
   `cmd/barkpark-provisioner/main.go:151`.
4. **`muscle-1-506f035e` is a PURE LEAK — and label-from-`row.URL` will MISS it.** TTL is the
   forensic discriminator. `muscle-1` has **ttl=60**, the signature of the *only* TTL-60 DNS
   writer in the repo, `internal/provisioner/support.go:385` (`supportRecordTTLSeconds = 60`) →
   muscle-1's box really was born on the CP support-provision chain, which reached the `secure`
   step. `muscle-1-506f035e` has **ttl=null**, the signature of the MAIN go-live writer
   `internal/cli/cloud/warmpool.go:1299` (`Record{…}` with no TTL, `Name` = the CP-allocated
   `provisioning_subdomain` = `<slug>-<team_short_id>`; `506f035e` is the Guerrilla team's short
   id — the same suffix appears on `gyldendal-506f035e`). **No CP `/v1/barkparks` row carries
   `muscle-1-506f035e` as its url** (muscle-1's url is the bare `https://muscle-1.barkpark.cloud`),
   so it is reserved by nothing. Both records point at the same live box `46.224.19.120`
   (`warm-eabbf4cc`). A fix deriving the label from `row.URL` deletes `muscle-1` and leaves
   `muscle-1-506f035e` behind. **P3's census needs a by-VALUE sweep (the box IP is already in
   hand at census leg 1 as `box.IP`), not a by-name delete.**

**Insertion points (all confirmed on `origin/main`):** `census()` at
`cloud_support_cmd.go:1176-1266` — exactly four legs (server / roster / control plane / token),
zero DNS; the dry-run banner at `:906-913` lists six steps, none DNS; `hostOf`
(`internal/cli/config.go:650`) and `supportCPRow.URL` (`:1275`) both exist. `row.URL` is read
today only at `:337` (parent resolution) and `:1303` (display) — the label seam is unused by the
remove path. Note `hostOf` returns the full host (`muscle-1.barkpark.cloud`); the DNS *label* is
its first component and there is no existing helper for that split.

| Claim | Result | Re-derivation command |
|---|---|---|
| Deployed SPA has zero DELETEs to the route | count 0; the one hit is a POST | `curl -s https://barkpark.cloud/app.js \| grep -n 'fleet/supports'` |
| Deployed bundle == origin/main | sha256 match | `curl -s https://barkpark.cloud/app.js \| shasum -a256; git show origin/main:cloud/priv/static/app.js \| shasum -a256` |
| Three code callers of the DELETE | CLI:1150, script:408, script:1499 | `git grep -n 'fleet/supports' origin/main -- ':!.claude/worktrees'` |
| census() has four legs, zero DNS | quoted | `git show origin/main:internal/cli/cloud_support_cmd.go \| sed -n '1176,1266p'` |
| Remove path has zero DNS code | only doc-string hits | `git show origin/main:internal/cli/cloud_support_cmd.go \| grep -in 'dns\|DeleteRecord\|rrset\|zone'` |
| Elixir CP has no Hetzner DNS client | zero hits | `git grep -in 'rrset\|dns\.hetzner' origin/main -- 'cloud/lib/**'` |
| hostOf + supportCPRow.URL exist | quoted | `git show origin/main:internal/cli/config.go \| sed -n '648,655p'`; `… cloud_support_cmd.go \| sed -n '1268,1282p'` |
| Fleet token sees no DNS zone | `total_entries: 0` | `FTOK=<hcloud ctx barkpark token>; curl -s -H "Authorization: Bearer $FTOK" https://api.hetzner.cloud/v1/zones` |
| Both muscle-1 records live, TTL 60 vs null | quoted | `MAIN_TOK=<hcloud ctx main token>; curl -s -H "Authorization: Bearer $MAIN_TOK" https://api.hetzner.cloud/v1/zones/1422829/rrsets?type=A` |
| No CP row reserves muscle-1-506f035e | only Gyldendal carries the suffix | `TOK=<cloud_token>; curl -s -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/barkparks` |
| TTL 60 is support.go's signature | sole `TTL:` literal path | `git grep -n 'TTL:' origin/main -- '*.go' \| grep -v _test` |
| CLI already has a two-token DNS resolver | `instDNSClient` | `git show origin/main:internal/cli/hetzner_instance_cmd.go \| sed -n '156,178p'` |
