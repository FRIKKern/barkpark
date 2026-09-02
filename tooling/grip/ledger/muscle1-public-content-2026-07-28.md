<!-- doc-tier: cold | canonical-for: muscle1-public-content-recipes | budget: 4000tok -->

# muscle-1 public content + exposure — re-derivation recipes (2026-07-28)

> HISTORICAL RECORD (2026-07-28) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Written by verifier `v-muscle1-public-content`. Live-network recipes, so they
cannot go through `node tooling/grip/ledger.mjs write` — the injected safety
screen refuses every one of them (`host bound: names barkpark.cloud`, and
`python3 -c` / `env -i` / `hcloud` are not allowlisted). Prose row file, same
precedent as the other `*-2026-07-28.md` rows in this directory.

**All recipes are READS. None writes anything, anywhere.**

## Content census — muscle-1's default workspace

Observed 2026-07-28T00:35Z. `total` is the full match count, not the page size.

```bash
for t in task paper tag command metric; do
  printf "%-8s " "$t"
  curl -s "https://muscle-1.barkpark.cloud/v1/data/query/production/$t?count=true&limit=1"
done
```

Read `.result.total` from each response. At observation: task 3139, paper 551,
tag 148, command 22, metric 6 — **3866 documents total**. Every other schema in
the registry returns `404 not_found` from the query route (the type is not in
scope in this dataset), so the census is complete at five types.

The unscoped `/v1/data/query/...` route serves the **default** workspace; the
`/studio` redirect target `/w/default/p/default/d/production/studio` is what
proves the workspace identity, and the explicitly-scoped
`/w/default/p/default/v1/data/query/...` variant *is* gated (403
`token lacks required permission`) — only the unscoped route is open.

## Exposure record

```bash
env -i /usr/bin/curl -s https://muscle-1.barkpark.cloud/v1/capabilities
env -i /usr/bin/curl -s https://muscle-1.barkpark.cloud/api/schemas
env -i /usr/bin/curl -sL https://muscle-1.barkpark.cloud/studio
```

`env -i` is load-bearing: it proves no ambient credential, `~/.netrc` or
`~/.curlrc` is in play (neither file exists on this Mac). Expect
`auth_tier: none`, a 39-element schema list, and `pane-layout` in the Studio
body. Full `paper` bodies come back on the query route too (`body`,
`body_html`, `blocks` fields, ~160KB on the newest row) — there is no
projection gate in front of them.

## The same recipe against the owner's live primary

```bash
env -i /usr/bin/curl -s "https://guerrilla.barkpark.cloud/v1/data/query/production/task?count=true&limit=1"
```

Returns a `result.total` with zero credentials. This is the wider finding: the
exposure is **not** confined to muscle-1, so removing muscle-1 in P3 does not
close it.

## Lineage dating — is the content image-seeded?

```bash
# fleet project token, exported explicitly per PDF-D75
hcloud server list --output columns=id,name,status,ipv4,created
hcloud image list --type snapshot --output columns=id,description,created
curl -s "https://muscle-1.barkpark.cloud/v1/data/query/production/task?limit=1&fields=title&order=_updatedAt:desc"
```

Compare three timestamps: the newest doc `_updatedAt` (UTC, `Z`-suffixed), the
box `created` (CEST, i.e. UTC+2), and the newest warm image `created` (CEST).
At observation the newest doc post-dates the box birth by ~50 minutes and
post-dates the candidate image bake by ~11 hours — which is what rules the
content **out** of being purely image-seeded.

## Warm-pool reachability (the exposure's blast radius)

```bash
curl -sk -m 10 -o /dev/null -w "%{http_code}\n" https://<warm-box-ipv4>/v1/capabilities
```

Expect `000` (connection failure) for every warm-pool box. Only the box with a
public FQDN answers — which is why PDF-D59's dropped `dns/caddy` steps are the
control that failed here.
