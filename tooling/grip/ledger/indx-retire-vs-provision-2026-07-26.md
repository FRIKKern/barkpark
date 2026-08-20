# Re-derivation recipes — indx-retire-vs-provision (W10 verifier, 2026-07-26)

Every row is one literal command that re-derives the fact from scratch. No prose stands in for a run.

## 1. Indx is unprovisioned on guerrilla (three independent negatives)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql barkpark_prod -c 'select plugin_name, updated_at from plugin_settings;'; grep -c INDX_ /opt/barkpark/.env; ss -ltnp | grep :5001; ls /opt/indx; systemctl list-units --type=service --all | grep -i indx"
```

Expect: one row `github` only; `0`; no listener on 5001; no `/opt/indx`; no indx unit.
There is no half-populated row — the negative is total.

## 2. `engine=indx` returns HTTP 200 Postgres-with-recovery (never throws)

```
for e in indx postgres bogus_engine; do curl -s "https://guerrilla.barkpark.cloud/v1/data/search/production?q=search&engine=$e&limit=2" | python3 -c "import sys,json;d=json.load(sys.stdin);print('$e',d.get('count'),bool(d.get('facets')),d.get('recovery'),d.get('truncation'))"; done
```

Expect: `indx 691 False typo_widen None` / `postgres 690 True None None` / `bogus_engine 690 True None None`.
`bogus_engine` == `postgres` (Retrievers.resolve falls back); `indx` differs because
`Barkpark.Plugins.Indx.Retriever` IS registered (config/config.exs:228) and degrades to
`{[], 0, %{}}` (retriever.ex moduledoc + `is_nil(dataset) -> {[], 0, %{}}`), which trips
QueryPipeline's zero-hit recovery on Postgres.

## 3. The astro flagship's build-time browse seed is Postgres wearing indx's name

```
curl -s "https://guerrilla.barkpark.cloud/v1/data/search/production?q=%20&engine=indx&types=paper&perspective=published&limit=100&fields=title,name,excerpt,description,bio,slug,publishedAt,status,author,category" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('count'),d.get('facets'),d.get('recovery'))"
```

Expect: `552 None typo_widen`. This is byte-for-byte the URL
`templates/astro-search-starter/src/lib/bp.ts:112-125` builds, and
`src/lib/shape-seed.ts:47-48` stamps `engine:'indx', engineUsed:'indx'` onto its result.

## 4. `indxUnavailable` is identically false in the SHIPPED astro bytes

```
curl -s https://guerrilla.barkpark.cloud/sites/astro-search/ | grep -o '/sites/astro-search/_astro/FinderIsland[^"]*\.js'
curl -s https://guerrilla.barkpark.cloud/sites/astro-search/_astro/FinderIsland.DeN--5Wk.js | grep -o 'indxUnavailable:[^,]*' 
curl -s https://guerrilla.barkpark.cloud/sites/astro-search/_astro/FinderIsland.DeN--5Wk.js | grep -o 'get(`engine`)===`postgres`?`postgres`:`indx`'
```

Expect the derivation `indxUnavailable:t===\`indx\`&&n!==\`indx\`` plus call sites that all
pass `engineUsed:t` (n===t) — the flag can never be true — and the default-engine ternary
proving the deployed flagship defaults to `indx`.

## 5. The deployed astro seed currently carries `initialData: null`

```
curl -s https://guerrilla.barkpark.cloud/sites/astro-search/search-seed.json | python3 -c "import sys,json;d=json.load(sys.stdin);print(sorted(d.keys()), type(d.get('initialData')).__name__)"
```

Expect: `['initialData','initialSeed'] NoneType`. The false `engineUsed:'indx'` literal is in the
shipped JS, not (yet) in the shipped JSON — `shapeSeed` returns null for a null `initialData`.

## 6. `truncation` is Indx-only; `facets` is NOT

```
grep -n '{docs, count, %{facets: facets}}' api/lib/barkpark/search/documents_retriever.ex
grep -n 'maybe_put(:truncation' api/lib/barkpark/plugins/indx/retriever.ex
```

Expect one hit each (documents_retriever.ex:130, indx/retriever.ex:123). Consequence: flipping
`engineUsed` to `postgres` cannot cost the finder.tsx:992 coverage boundary — `data.truncation`
is already null in every degraded response.

## 7. Removing `'indx'` from the core type union is NOT tsc-detectable

```
sed -n '897,898p' js/packages/core/src/types.ts
```

Expect `engine?: 'postgres' | 'indx' | (string & {})`. The `(string & {})` escape hatch keeps any
string assignable, so a missed copy survives typecheck. Only grep proves complete removal.

## 8. Gate reality for the edit set

```
cd templates/search-starter && npx tsc --noEmit -p tsconfig.json; echo "exit=$?"
cd templates/astro-search-starter && npm test
cd web && npx tsc --noEmit -p tsconfig.json 2>&1 | wc -l
```

Expect: search-starter exit 0 / 0 lines (usable gate); astro `# pass 7` (no engineUsed assertion
anywhere — `grep -n engineUsed src/lib/shape-seed.test.ts` is empty); web 1235 error lines from an
EMPTY `web/node_modules` — `ls web/node_modules | wc -l` returns 0, so web's typecheck is not a
usable local gate without an install.
