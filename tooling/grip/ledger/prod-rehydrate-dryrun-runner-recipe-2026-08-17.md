# prod-rehydrate-dryrun — runner recipe + stamp census (2026-08-17)

Wave: Paper Excellence w3 · lane: prod-rehydrate-dryrun · box: guerrilla `157.180.90.121` (`guerrilla.barkpark.cloud`)

## Verdict

The lead's live-proof recipe as written **cannot run on the box right now**. Two independent
findings:

1. **Runner is source-`mix`, but the on-disk build is half-reconciled.** `mix
   barkpark.rehydrate_body_html` dies at the dependency check — installed `_build/prod`
   artifacts are stale (`decimal 2.3.0`, `phoenix 1.8.5`, `req 0.5.17`, `mint 1.7.1`,
   `postgrex 0.22.0`) while `deps/` source and `mix.lock` on disk are the newer pins
   (`decimal 3.1.1`, `phoenix 1.8.9`, `req 0.6.3`, `mint 1.9.3`, `postgrex 0.22.3`). A fresh
   `mix` task refuses. The live `barkpark-slot@blue.service` beam (PID 2463892, started 11:14
   UTC) loaded the OLD artifacts into memory and keeps serving, so the site is up while any
   new `mix` invocation fails. `_build/prod/lib` mtime = 2026-07-09; `mix.lock` mtime =
   2026-07-31 — deps.get ran, a clean rebuild did not.
2. **The 422/before-after headline is stale** (confirms the digest). Reader self-heal (#11757)
   already lit most dark papers; the honest live metric is the int_3 stamp census.

## The runner (what actually exists)

- `ExecStart` of both `barkpark.service` and `barkpark-slot@blue.service` = `/opt/barkpark/api/start.sh`.
- `start.sh` provides a `mix` subcommand: `./start.sh mix <task>` → `exec mix "$@"` under
  ASDF + sourced `../.env` + `MIX_ENV=prod`. THIS is the sanctioned runner (not bare `mix`).
- Both `./start.sh mix barkpark.rehydrate_body_html ...` and a hand-rolled
  `MIX_ENV=prod mix ...` (ASDF sourced, `.env` sourced) hit the SAME dependency-check wall.

## Recipe the lead must use (after reconcile)

```
# 1. Reconcile the build FIRST (golden rule 1 — never partial-clean):
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121
cd /opt/barkpark && make rebuild        # nuke _build/prod, deps.compile --force, restart
# 2. THEN the dry-run (default is dry-run; NEVER pass --write here — that is the lead's op):
cd /opt/barkpark/api && ./start.sh mix barkpark.rehydrate_body_html --type paper --published-only
```

`--write` was NOT run by this lane (dry-run only, per assignment). The task's own dry-run
tally line to quote is: `rehydrate_body_html: scanned N doc(s) — P to rewrite, ...` — not
obtained this run because the dep check aborts before `app.start`.

## Stamp census (the honest live metric)

`bp doc query paper --limit 2000 --fields body_html_sv -o json` — note the projected field
lands at ROW TOP-LEVEL (`row["body_html_sv"]`), NOT under `content`.

- Total papers: **781**
- `body_html_sv == 3` (integer sentinel = "int_3", the dark/stale class): **60**
  (drifted down from the wave-2 baseline of **119** as readers self-heal on read)
- Absent stamp (`<absent>`): 116
- Current-renderer hex stamps: 188 (`c18f5333…`) + 173 (`a0d3e8bd…`) lead the rest.

A `--write` run's before/after delta should be quoted as this int_3 census (119→60→…→0),
NOT as a 422 count (which reads 0→0 because the reader already self-heals).

## Re-derivation

```
# runner failure (dep check):
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'cd /opt/barkpark/api && ./start.sh mix barkpark.rehydrate_body_html --type paper --published-only'
  # → "Unchecked dependencies for environment prod: * decimal ... got 2.3.0 ..."

# build-state mismatch:
ssh ... 'grep -m1 version /opt/barkpark/api/deps/decimal/mix.exs'          # @version "3.1.1"
ssh ... 'find /opt/barkpark/api/_build -name decimal.app | head -1 | xargs grep -o "vsn.*"' # vsn,"2.3.0"

# census:
bp doc query paper --limit 2000 --fields body_html_sv -o json \
  | python3 -c 'import sys,json,collections;d=json.load(sys.stdin);\
c=collections.Counter(str(r.get("body_html_sv")) for r in d["documents"]);print(c.most_common())'
  # → ("3", 60) among 781 total
```
