# Re-derivation recipes — felix wave 24, corpus-doctrine-refutation

Every row re-derives one load-bearing fact from scratch. Run from repo root.

| Fact | Command |
|---|---|
| Corpus mentions "sobelow" exactly once, in ch 56's title | `bp paper view phoenix-mastery-corpus \| grep -n -i sobelow` |
| Corpus has ZERO suppression/baseline/linter/static-analysis vocabulary | `bp paper view phoenix-mastery-corpus \| grep -n -i 'suppress\|baseline\|credo\|dialyzer\|static analy\|linter\|CI gate\|regression gate'; echo "RC=$?"` (expect RC=1) |
| Corpus is a complete 92-chapter / 13-part TITLE MAP with no chapter bodies | `bp paper view phoenix-mastery-corpus > /tmp/c.txt; grep -c '^Part ' /tmp/c.txt; grep -c '^Barkpark cases: ' /tmp/c.txt; grep -oE '^[0-9]+\.' /tmp/c.txt \| tr -d '.' \| sort -n \| tail -1` |
| Charter doctrine-bar hook (3) is SCAR-CLASS, not Corpus-gap | `git show origin/main:.claude/workflows/bp-felix-pristine-charter.md \| sed -n '27,34p'` |
| No Corpus reference anywhere in the charter's doctrine bar | `git show origin/main:.claude/workflows/bp-felix-pristine-charter.md \| grep -n -i corpus` (hits at 12/46/92/131/170/212/2078/2094 — none in 27-34) |
| gates-tell-the-truth already publishes the gate-can-report law | `bp paper view gates-tell-the-truth-wave-2026-07-20 \| sed -n '124,136p'` |
| gates-tell-the-truth already names security.yml:55 Sobelow red-under-green | `bp paper view gates-tell-the-truth-wave-2026-07-20 \| sed -n '578,590p'` |
| gates-tell-the-truth already publishes baseline monotonicity (shrink-only ceiling) | `bp paper view gates-tell-the-truth-wave-2026-07-20 \| sed -n '1048,1053p'` |
| honest-gates-2 already publishes waiver-binding (reconcile reverts inline annotations) | `bp paper view honest-gates-wave-2026-07-27 \| sed -n '489,499p'` |
| honest-gates-2 already publishes the run-level lie | `bp paper view honest-gates-wave-2026-07-27 \| sed -n '99,106p'` |
| felix's OWN wave 8 (2026-07-13) already published append-only baseline decay + inline migration + mutation self-test | `bp paper view felix-pristine-wave-8-2026-07-13 \| grep -n -i 'sobelow\|skip'` |
| The migration's parent claim lives in Honest Gates and is OPEN, adopted by felix D144 | `bp task get hg-bl-sobelow-fingerprint-to-inline-migration -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'],d['content']['adopted_by'])"` |
| felix-w23-bl-corpus-gate-integrity is OPEN 0/3 under the epic task | `bp task get felix-w23-bl-corpus-gate-integrity -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'],d['parent_id'])"` |
| Branch protection IS live with enforce_admins true (SR-1 premise dead) | `bp paper view honest-gates-wave-5-2026-07-28 \| sed -n '392,400p'` |
