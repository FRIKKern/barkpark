# PDS w37 — webhook family row schema, re-derivation recipes (sha 501fb9670)

All commands assume a clean export of origin/main; nothing here reads a worktree.

```sh
cd $(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main api/lib scripts | tar -x
```

## R1 — the family is 14 emitted rows (header-anchored), not 18 (grep), not 13 (wish)

```sh
elixir scripts/pds-elixir-receipt-census.exs --keys | grep -c github_webhook   # 14
elixir scripts/pds-elixir-receipt-census.exs --sites | grep -c github_webhook  # 18
```

18 - 14 decomposes exactly: 1 prose line (`:39`), 1 `SUPPRESSED` echo of `:87`,
2 declared-register rows (`:86`, `:87`).

## R2 — two expr_fp values repeat across handle_inbound/2 and handle_intake/2

```sh
elixir scripts/pds-elixir-receipt-census.exs --keys | grep github_webhook > /tmp/wh.tsv
cut -f4 /tmp/wh.tsv | sort | uniq -c | sort -rn | head -3   # `2 96836141`, `2 39153928`
cut -f1,4 /tmp/wh.tsv | sort -u | wc -l                     # 12  <- expr_fp alone collapses 14 -> 12
sort -u /tmp/wh.tsv | wc -l                                 # 14  <- full 4-tuple is faithful
```

## R3 — key-field carrying power, corpus-wide

```sh
elixir scripts/pds-elixir-receipt-census.exs --keys > /tmp/k.tsv
wc -l /tmp/k.tsv; sort -u /tmp/k.tsv | wc -l          # 91 / 91
cut -f1,2   /tmp/k.tsv | sort -u | wc -l              # 75
cut -f1,2,3 /tmp/k.tsv | sort -u | wc -l              # 76
cut -f1,4   /tmp/k.tsv | sort -u | wc -l              # 76
cut -f4     /tmp/k.tsv | sort -u | wc -l              # 67
```

## R4 — :194 is one site rendering three tags; only one is proven end-to-end

```sh
git -C /Volumes/SATECHI/github/barkpark show origin/main:api/lib/barkpark_web/controllers/github_webhook_controller.ex | sed -n '191,195p'
git -C /Volumes/SATECHI/github/barkpark grep -c 'no_guardable_marker' origin/main -- api/test
# -> only api/test/barkpark/tasks/reconcile_merge_gate_test.exs:2  (Tasks layer, two hops below the receipt)
git -C /Volumes/SATECHI/github/barkpark show origin/main:api/test/barkpark_web/controllers/github_webhook_controller_test.exs | grep -c 'no_marker\|no_guardable_marker'          # 0
git -C /Volumes/SATECHI/github/barkpark show origin/main:api/test/barkpark_web/controllers/github_webhook_integration_test.exs | grep -c 'no_marker\|no_guardable_marker'         # 0
```

## R5 — the stub/readback split

```sh
for f in api/test/barkpark_web/controllers/github_webhook_controller_test.exs \
         api/test/barkpark_web/controllers/github_webhook_integration_test.exs \
         api/test/barkpark/plugins/github/merge_events_test.exs; do
  printf "%s lines=%s Repo=%s\n" "$f" \
    "$(git -C /Volumes/SATECHI/github/barkpark show origin/main:$f | wc -l)" \
    "$(git -C /Volumes/SATECHI/github/barkpark show origin/main:$f | grep -c 'Repo\.')"
done
# 360/0, 268/4, 171/2
```

## R6 — PDS-D500's own text

```sh
git -C /Volumes/SATECHI/github/barkpark show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '9495,9520p'
```
Its 14 is stated as header-anchored and explicitly contrasted with the grep's 18.
