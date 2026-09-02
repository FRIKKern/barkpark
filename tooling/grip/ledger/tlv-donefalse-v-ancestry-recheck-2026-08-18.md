<!-- doc-tier: cold | canonical-for: tlv-donefalse-audit-ancestry-recheck-recipe | budget: 900tok -->
# TLV done-false audit — v-ancestry-recheck re-derivation recipe (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Snapshot pin: origin/main == e21bf409893d9de66542a31b06716e3c33d8f102 (verified: e21bf IS ancestor of origin/main; they are identical HEAD at audit time).

## SWEEP A independent re-run — highest-vacuity cohort (tlv-s1..s4 + 2 foreign-generic)

```
cd /Volumes/SATECHI/github/barkpark
git fetch origin --quiet
for s in f08c48ec7f aeefae4153 89f151c210 db14edc98c 84ec7aef 997efb440a; do \
  git merge-base --is-ancestor $s e21bf409893d9de66542a31b06716e3c33d8f102 \
  && echo "$s ANCESTOR" || echo "$s NOT"; done
```
Result: ALL SIX ANCESTOR.
- f08c48ec7f = tlv-s1 (#4392) · aeefae4153 = tlv-s2 (#4393)
- 89f151c210 = tlv-s3 (#4394) · db14edc98c = tlv-s4 (#4395)
- 84ec7aef = task-d1f7357 foreign (#1381) · 997efb440a = task-9d7fd16 foreign

## Substance-present checks (not message-match)

```
git show origin/main:api/lib/barkpark/tasks/validation.ex | grep -n 'considering\|researching'
#  -> @lifecycle_statuses ~w(open in_progress blocked done cancelled considering researching)  [line 24]
git show origin/main:api/priv/repo/migrations/20260719030000_widen_task_lifecycle_status_check_to_7.exs | grep -n considering
#  -> IN ('open','in_progress','blocked','done','cancelled','considering','researching')  [line 43]
git show origin/main:design/emit.mjs | grep -n 'LIFE_ORDER\|considering'
#  -> LIFE_ORDER = [ ... "considering", "researching", ]  [lines 185/192]
git ls-tree -r origin/main --name-only | grep -E 'status-vocab.test|widen_task_lifecycle'
#  -> js/packages/react/tests/status-vocab.test.ts  +  both 20260719030000/030100 migrations present
git show origin/main:js/packages/react/tests/status-vocab.test.ts | grep -n 'considering\|researching'
#  -> roleOf('considering')/roleOf('researching') asserted with glyphs U+25CC / U+25CE
```

VERDICT: cohort clean. 6/6 ancestor, all claimed substance PRESENT at e21bf40. Zero false-done in this cohort. Survey brief's "#5529-5533" range premise stays refuted — the real landed group is #4392-#4395.
