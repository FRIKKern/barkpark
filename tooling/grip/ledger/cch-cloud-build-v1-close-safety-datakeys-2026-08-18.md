<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# V1-close-safety — task-b8d628996d3c8363 close is evidence-safe

Wave: bp-cloud-build-wave-2026-08-18 · verifier V1-close-safety · 2026-08-18
Verdict: **CLOSE-SAFE** — all 3 acceptance criteria backed by landed code on origin/main (41b16d78); suites GREEN.

## Re-derivation recipe (authoritative reads are git-show against origin/main; local HEAD a6535504 is 179 commits BEHIND)

    git fetch origin main
    git rev-parse origin/main            # 41b16d78… (authority tip)
    git merge-base --is-ancestor HEAD origin/main && echo "local behind"   # true; 179 behind, 0 ahead

    # code-under-test is byte-identical local↔origin/main (so a LOCAL green run is authoritative for these):
    git diff --stat HEAD origin/main -- api/lib/barkpark/crypto \
      api/test/barkpark/crypto \
      api/test/barkpark/tenancy_delete_workspace_test.exs \
      api/priv/repo/migrations/20260714010000_data_keys_workspace_attribution.exs   # EMPTY = identical
    # ONLY workspace_bundle_test.exs differs: +204 lines on origin/main = UNRELATED felix-w25/w27 import-security tests (not a criterion)

    # RUN (green proof):
    cd api && CC=clang mix test test/barkpark/crypto/ \
      test/barkpark/tenancy/workspace_bundle_test.exs \
      test/barkpark/tenancy_delete_workspace_test.exs   # -> 81 tests, 0 failures

## Criterion → landed evidence (origin/main)

- **Criterion 0** (re-key global (scope,version) → (workspace_id,scope,version); safe legacy NULL-ws; reversible):
  priv/repo/migrations/20260714010000_data_keys_workspace_attribution.exs
  L68 `drop unique_index(:data_keys,[:scope,:version], name: :data_keys_scope_version_index)`
  L70 `create unique_index(:data_keys,[:workspace_id,:scope,:version])`. `def change` (Ecto-reversible).
  NULL-distinct handled by split partial indexes L57/L62. Table empty at migrate time → duplicate-preflight vacuous.
- **Criterion 1** (audit active_dek/get-or-create/rotation/export/import/deletion scope by workspace_id; negative test one-ws-can-never-select-another's):
  crypto_test.exs:311 "neither workspace can decrypt the other's ciphertext" (cross-ws + NULL-ws decrypt → `:error`, fail-closed);
  :247 both ws mint v1 no unique_violation; :285 one-active-per-(ws,scope) ConstraintError. GREEN.
- **Criterion 2** (two siblings SAME scope+version, rotate independently, round-trip bundles, delete one w/o affecting other; cite merge SHA):
  crypto_test.exs:247 (same scope, both v1, independent) + workspace_bundle_test.exs:407/418 byte-identical DEK round-trip + tenancy_delete_workspace_test.exs:431 "deleting A leaves B intact" (+ :607 B's same-'production'-scope config survives A teardown). GREEN.
  Merge SHA 458331a52 (#3169) `git merge-base --is-ancestor 458331a52 origin/main` → **ancestor: yes**.

## Nuance (not a blocker)
Criterion 0's literal "duplicate preflight" has no runtime SELECT — the migration comment documents the table is empty (no write-path yet), so it is vacuously satisfied. Criterion 2's "rotate them independently" is proven at the mint/index level (both mint v1, per-ws keying, cross-ws fail-closed) rather than an explicit ws_a→v2/ws_b-stays-v1 rotation test; the schema+behavior that ENABLE independent rotation are green. Both are adequate for the close.
