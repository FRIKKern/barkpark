# PDS wave 37 — post-merge census baseline at origin/main 501fb9670

Re-derivation recipes. Every number below was produced by these exact commands on
2026-08-01, Elixir 1.19.5 / OTP 28, aarch64-apple-darwin24.6.0.

## 0. The tip

    git -C /Volumes/SATECHI/github/barkpark rev-parse origin/main
    # 501fb9670971998e5e5af05126cabfed3ea425bc  (#8952, 2026-08-01 22:49:28 +0200)

WARNING — the primary checkout is NOT the tip. `git rev-parse HEAD` reads
a31faa52dc7586168cecc7dc2d2324b3732943f6: 292 behind, 48 ahead, 233 files
diverged under api/. Never derive a wave integer from it.

## 1. Census at the tip (build-free, archive into a clean dir)

    W=$(mktemp -d); cd $W
    git -C /Volumes/SATECHI/github/barkpark archive origin/main api/lib scripts | tar -x
    elixir scripts/pds-elixir-receipt-census.exs; echo RC=$?

    # RC=0, "CENSUS OK"
    # PASS CLASSIFICATION-TOTAL  classified 16 + unclassified 75 == emitted 91
    # CATCH-ALL-TO-SUCCESS  1   ·  "CATCH-ALL-TO-SUCCESS FINDINGS  0 undeclared of 1 fired"
    # POST-READ 15 · UNCLASSIFIED 75 · write 54 / read 14 / unrouted 23 at depth 6
    # textual 104 · ast 95 · phantom 9 · consumer 4 · EMITTED 91 · 804 .ex files

16 + 75 is CORRECT at the tip. The direction's 18 + 73 is the PRE-merge reading
(f3e956e92) and is stale.

## 2. Keys at the tip

    elixir scripts/pds-elixir-receipt-census.exs --keys > /tmp/keys_post.tsv
    wc -l < /tmp/keys_post.tsv        # 91
    sort -u /tmp/keys_post.tsv | wc -l # 91
    # stderr header: "keys 91 · emitted 91 · normaliser total-meta-drop/phash2-term/v1"

Field necessity (all cuts over /tmp/keys_post.tsv):

    cut -f1,2     | sort -u | wc -l   # 75  path + mfa
    cut -f1,2,3   | sort -u | wc -l   # 76  + head_hash
    cut -f1,2,4   | sort -u | wc -l   # 91  + expr_fp (head_hash REDUNDANT for uniqueness)
    cut -f1,4     | sort -u | wc -l   # 76  path + expr_fp alone LOSES 15 rows
    cut -f4       | sort -u | wc -l   # 67  expr_fp alone

expr_fp collides within a single file in NINE files, not one:

    cut -f1,4 /tmp/keys_post.tsv | sort | uniq -d
    # auth_controller.ex 17468236 · bulldocs_ingest_controller.ex 124223564, 61088078
    # github_webhook_controller.ex 39153928, 96836141 · plugin_settings_controller.ex 17468236
    # secret_controller.ex 17468236 · tasks_controller.ex 84462998 · tickets_controller.ex 113191402

## 3. Selftest at the tip

    elixir scripts/pds-elixir-receipt-census.exs --selftest; echo RC=$?
    # RC=0 · "SELFTEST OK — 9 cases, 5 of them mutants that went red as required."
    # includes: PASS KEYS-ONE-LINE-PER-SITE  exit 0 · TSV lines == keys == emitted

## 4. Key churn f3e956e92 -> 501fb9670

    D=$(mktemp -d); cd $D
    git -C /Volumes/SATECHI/github/barkpark archive f3e956e9247417823c7de78dc201922da538e57d api/lib scripts | tar -x
    elixir scripts/pds-elixir-receipt-census.exs --keys > /tmp/keys_pre.tsv   # 91 rows, 91 unique
    LC_ALL=C sort /tmp/keys_pre.tsv > /tmp/a; LC_ALL=C sort /tmp/keys_post.tsv > /tmp/b
    comm -23 /tmp/a /tmp/b   # 5 orphaned
    comm -13 /tmp/a /tmp/b   # 5 arrived
    comm -12 /tmp/a /tmp/b | wc -l   # 86 common
    cut -f1,2 /tmp/keys_pre.tsv | LC_ALL=C sort > /tmp/p12
    cut -f1,2 /tmp/keys_post.tsv | LC_ALL=C sort > /tmp/q12
    diff /tmp/p12 /tmp/q12   # EMPTY — identical path+mfa multiset

So the churn is a PURE RE-KEY of five rows, zero site arrivals and zero site
departures. head_hash is unchanged on all five; only expr_fp moved:

    auth_controller.ex  BarkparkWeb.AuthController.reset/2        head 117976982  17468236 -> 93237454
    search_controller.ex SearchController.search_interaction/2    head  79721084 106282520 -> 115364326
    search_controller.ex SearchController.search_interaction/2    head  79721084  17468236 ->  95315838
    v1/media_controller.ex MediaController.search_interaction/2   head  79721084 106282520 -> 115364326
    v1/media_controller.ex MediaController.search_interaction/2   head  79721084  17468236 ->  95315838

## 5. Where the class delta came from

At f3e956e92 the census printed "2 undeclared of 3 fired":

    FINDING search_controller.ex:334  head `_`
    FINDING v1/media_controller.ex:225  head `_`

#8950 replaced those catch-alls with `{:ok, id}` / `{:skipped, :recording_disabled}`
/ `{:skipped, reason}` arms plus a `recorded:` field (search_controller.ex:336-346,
media_controller.ex:227+). Both sites left CATCH-ALL-TO-SUCCESS and returned to
UNCLASSIFIED: classified 18 -> 16, unclassified 73 -> 75, emitted 91 unchanged.

## 6. mix format baseline — READ THIS BEFORE RUNNING IT LOCALLY

At origin/main CONTENT the formatter is CLEAN:

    F=$(mktemp -d); cd $F
    git -C /Volumes/SATECHI/github/barkpark archive origin/main api | tar -x
    ln -s /Volumes/SATECHI/github/barkpark/api/deps $F/api/deps   # .formatter.exs import_deps
    cd $F/api && CC=/usr/bin/clang mix format --check-formatted; echo RC=$?
    # RC=0, no output

In the PRIMARY CHECKOUT the same command exits 1 over 88 files. That is the stale
checkout (a31faa52d), not main. Two independent traps compound here:

  * .github/workflows/elixir.yml:208-217 — the `format` job is
    `continue-on-error: true`, ADVISORY, NOT in elixir-gate's `needs`.
  * elixir.yml:226-227 pins otp 27.0 / elixir 1.18.1; this host runs 1.19.5. The
    workflow's own comment warns that a local `mix format` pass under a different
    Elixir rewrites the tree. Do not run bare `mix format` to "fix" a red here.
