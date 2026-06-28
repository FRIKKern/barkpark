<!-- doc-tier: agent | canonical-for: codelists-byo-procedure | budget: 500tok -->
# EDItEUR Codelists — bundled default + Bring-Your-Own

Barkpark ships a bundled EDItEUR **Issue 73** snapshot at `api/priv/codelists/onix-issue-73.xml` (~1.4 MB), seeded on every boot via `Barkpark.Codelists.EDItEUR.seed_bundled/0`. Out of the box, a fresh install has Issue 73 codes available.

**License:** see `api/priv/codelists/README.md` (CANONICAL). Short form: © EDItEUR, DOI `10.4400/nwgj`, internal-use OK, notify-on-redistribute.

## Precedence order

The seeder resolves the XML path by this fixed precedence:

1. `--source PATH` argument to `mix barkpark.codelists.seed`
2. `BARKPARK_ONIX_CODELIST_PATH` env var
3. Plugin settings key `"codelist_path"` for plugin `"onixedit"` (Studio: `/studio/:dataset/_plugins/onixedit/settings`)

**Exit-1 policy:** if none of the three sources are configured, the Mix task exits 1 with a guided message — no silent fallback.

## Seeding

```bash
cd api
mix barkpark.codelists.seed \
    --plugin onixedit \
    --issue  73 \
    --source /var/lib/barkpark/codelists/onix-issue-73.xml
```

Re-running with the same `--issue` is **idempotent** (upserts). A different `--issue` (e.g. 74) inserts alongside the prior issue — `Codelists.lookup/3` resolves to the latest issue by default.

## Thema hierarchy caveat

ONIX list 93 is **Supplier role** (16 entries), not Thema. Thema is registered under the friendly key `onixedit:thema`; the alias resolver in `Barkpark.Content.Codelists` (`@external_scheme_friendlies`) bypasses the `friendly → list_<N>` rewrite that would otherwise mis-route Thema lookups to Supplier role.

If your Thema snapshot encodes hierarchy by code-prefix instead of explicit `<ParentCode>`, run a one-time conversion before seeding — or file an issue for `--derive-thema-hierarchy` support.

## Tests

Synthetic fixture: `api/test/fixtures/codelists/synthetic.xml` (lists 1, 7, 17, 64 — not production codes). CI runs the parser end-to-end:

```bash
cd api
mix test test/barkpark/codelists/editeur_test.exs
```
