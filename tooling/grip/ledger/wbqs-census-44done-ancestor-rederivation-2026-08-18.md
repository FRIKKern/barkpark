<!-- doc-tier: cold | canonical-for: wbqs-census-44done-ancestor-rederivation | budget: 900tok -->

# WBQS 44-done census: task_id -> PR# -> SHA -> ancestor re-derivation (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Epic: `wild-bulk-quality-sweep-2026-07-16-epic`. Verifier assignment [census-reproof].
Anchor: origin/main = `710c38f06a7e21441f3993ef3ebff01c1317a8ae`.

## Result

- Children split (from live L1, NOT child_count 48): **44 done / 3 open / 1 cancelled**.
- All 44 done rows join 1:1 to a merge commit; **44/44 are ancestors of origin/main, 0 non-ancestor, 0 NOSHA**.
- PR band exactly **#3759-#3793** (35, contiguous) **+ #3812-#3820** (9) = 44. min 3759, max 3820.
- 3 open survivors all `claim: None` (no re-claim needed): wbq-cloud-billing-reason-leak-backlog (0/4), wbqs-go-dead-exports-coordination-gated-backlog (0/5), wild-bulk-cycle-v2-revisions (0/3 — live task carries 3 criteria).
- Cancelled: wbqs-api-sobelow-rebaseline (3/3, claim None) — terminal.

## Rerun recipe

```bash
cd /Volumes/SATECHI/github/barkpark
origin=$(git rev-parse origin/main)
bp task get wild-bulk-quality-sweep-2026-07-16-epic -o json > /tmp/wbqs.json
# done ids:
python3 -c "import json;d=json.load(open('/tmp/wbqs.json'));[print(c['doc_id']) for c in d['children'] if c['lifecycle_status']=='done']" > /tmp/done_ids.txt
# match each id to its merge commit in origin/main history (already ancestor-scoped by git log origin/main):
git log $origin --grep="Task:" --format="%H%x09%s%x09%b%x1e" > /tmp/alltasklog.txt
# then per-id regex match 'Task:\s*<id>\b' over subject+body; per-sha:
git merge-base --is-ancestor <sha> $origin && echo YES || echo NO   # macOS has no `timeout`; run direct
# PR band:
git log $origin --grep='Task: wbq' --format=%s | grep -oE '#[0-9]+' | tr -d '#' | sort -n | uniq
```

Note: commits are matched via `git log origin/main --grep`, which is itself ancestor-scoped, so ancestry is true by construction; the explicit `merge-base --is-ancestor` pass re-confirms all 44 independently (YES x44).

## Canonical table (task_id  PR#  short_sha)

```
wbq-astro-starter-vendor-tarballs        3776  6313e6916d35
wbq-cloud-archive-store-log-flood        3785  6a22ce70d176
wbq-cloud-auth-onboarding-500            3783  e5ef99525a10
wbq-cloud-billing-reconcile-isolation    3784  46981cd2c352
wbq-connectors-sse-stream-leak           3775  98be5562a20f
wbq-hundesteder-weighted-tags            3777  b4474a985ded
wbq-js-lint-hygiene                      3774  35791d6f3e95
wbq-nextjs-server-decoder-drift          3773  f0e6919b2542
wbq-packages-client-dead-note            3782  72132f488efb
wbq-sdk-search-event-id                  3772  1fd8545a9079
wbq-web-bench-error-state                3778  348b172d7141
wbq-web-bpfetch-error-code               3780  8e5a4989db11
wbq-web-dark-variant-databind            3781  eeaf5a59484f
wbq-web-prefix-seed-encode               3779  fc7f22c2f96a
wbqs-api-capabilities-manifest           3818  227619ba9d0a
wbqs-api-changeset-controllers           3819  132e55b0e491
wbqs-api-changeset-plugin-settings       3820  83dc828a715b
wbqs-api-compactor-uuid-guard            3790  54c3ec08c4ba
wbqs-api-dead-accessors                  3792  16a7a026ddc5
wbqs-api-double-submit-guards            3787  1408f1564aec
wbqs-api-legacy-filter-failopen          3817  fad31490fc1a
wbqs-api-pulse-config-crash              3814  cb45ccc9f90e
wbqs-api-query-param-coercion            3812  d25ab6bb4472
wbqs-api-render-errors-json              3815  449416d46b9f
wbqs-api-schema-upsert-echo              3816  e918da746d6e
wbqs-api-scim-param-coercion             3786  ce103ac6d09a
wbqs-api-stale-todo-cleanup              3793  306937ba1f87
wbqs-api-studio-mobile-overflow          3789  81fa6a38bd34
wbqs-api-studio-modal-a11y               3788  38a5fac5cf5b
wbqs-api-vacuous-tests                   3791  dfc3ab27f00b
wbqs-api-webhook-param-coercion          3813  296a372faca9
wbqs-go-apiclient-flaturl-normalize      3759  a16c5fa0c75a
wbqs-go-board-fetch-error-envelope       3761  a454f846fdb5
wbqs-go-cloud12-flag-value-guard         3762  44abbe8a6148
wbqs-go-cloudclient-routeerror-nested    3769  6d8a94680ca0
wbqs-go-daemon-http-timeout              3767  8c16085ad8d4
wbqs-go-dead-exports-cleanup             3766  ea69d8d83dcc
wbqs-go-execrunner-deadline              3768  4adadf0e0f64
wbqs-go-parseglobals-flag-value-guard    3764  6607dd068d68
wbqs-go-servers-cmd-emitstructured       3765  6ecdab2fbe6e
wbqs-go-splitargs-flag-value-guard       3763  ce1c2c71cc6e
wbqs-go-sse-context-cancel               3760  340203ad8762
wbqs-go-tui-timeout-vs-notfound          3771  cc9cebd3335b
wbqs-go-wasm-arg-guard                   3770  8f9c313588c6
```
