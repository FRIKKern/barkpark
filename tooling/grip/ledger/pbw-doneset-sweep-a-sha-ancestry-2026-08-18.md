<!-- doc-tier: cold | canonical-for: pbw-doneset-sweep-a-ancestry-rederive | budget: 600tok -->
# PD Block-Wishlist done-set audit — Sweep A (SHA-ancestry) re-derivation

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Wave: pd-block-wishlist-doneset-audit-2026-08-18. Assignment [sha-ancestry-100].
Origin/main head at run: `f8d63a9805279f16f1f22e83071c5b1337195ea8` (2026-08-18 10:36 +0200).

## Claim proved

All 8 PRs cited by the 17 done children merged and their merge commits are
ancestors of origin/main. The 2 review branch-tips are non-ancestor but their
content landed via squash (the Connectors trap) → ZERO genuinely-absent rows.

## Re-derive (paste verbatim)

```
git fetch origin main -q
for pr in 4049 4050 4051 4052 4081 4126 4140 4192; do
  s=$(gh api repos/FRIKKern/barkpark/pulls/$pr --jq .merge_commit_sha)
  git merge-base --is-ancestor "$s" origin/main && echo "#$pr $s ANCESTOR" || echo "#$pr $s NOT"
done
for tip in 2de33355b c5a458c90 a85be9dc1; do
  git merge-base --is-ancestor "$tip" origin/main && echo "$tip ANC" || echo "$tip NOT"
done
```

## Result (this run)

| PR | merge_commit_sha | verdict |
|---|---|---|
| #4049 | d9d62e3d3ba3ba238e7a0ff386c74d5310f01031 | ANCESTOR |
| #4050 | 0233d39a30323255f9c6cc0bb8fff3640b08cb81 | ANCESTOR |
| #4051 | de776334525a27dc92155f5780d6e9a06947b8e3 | ANCESTOR |
| #4052 | 0aa6dfdcb8b2d3931663aed2c7ee50b54e30df4b | ANCESTOR |
| #4081 | a85be9dc1caa8cb8287837b787d8cf51574f1b6f | ANCESTOR |
| #4126 | e01564e890486e68a24dcf2f78d9a81723c84612 | ANCESTOR |
| #4140 | 72d5f8ae2f978b62c99806697f2c2493c59a7bb5 | ANCESTOR |
| #4192 | fa7025077524ac7e9e1c0117c2aa2698398237da | ANCESTOR |

Tips: 2de33355b NOT · c5a458c90 NOT · a85be9dc1 ANC (== #4081 merge commit; squash landing).

Tally: 8/8 cited PR merge commits ANCESTOR; 2/2 branch-tips non-ancestor-but-squash-landed; 0 genuinely-absent. Sweep A CLEAN — no reopen from ancestry.
