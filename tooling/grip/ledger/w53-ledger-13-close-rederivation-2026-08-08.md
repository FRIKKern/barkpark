# w53 v-ledger-13-close — re-derivation recipes (2026-08-08)

Verified against `origin/main` = `b402c0083225816a5be1b5b65d012e87e3a93532`.

## R1 — the per-sha check-runs endpoint TRUNCATES at 30 (the instrument that lies)

```bash
h=877bcb3edb0d7126e1097f2b579a57a604fbbd51   # PR #9920 head
gh api repos/:owner/:repo/commits/$h/check-runs --jq '.check_runs|length'          # -> 30
gh api repos/:owner/:repo/commits/$h/check-runs --jq '.total_count'                # -> 32
gh api --paginate "repos/:owner/:repo/commits/$h/check-runs?per_page=100" \
  --jq '.check_runs[].name' | wc -l                                                # -> 32
```

The default page dropped `PR references an active task` on #9920 — a REQUIRED context — and the
unpaginated read therefore manufactures a false "a required context never rendered" finding.
Always `--paginate` + `per_page=100`, or read `.total_count` and compare.

## R2 — required-context census over a PR head (the deciding sha)

```bash
for p in 9917 9918 9920 9922 10005 10008 10508 10509 10510 10511 10512 10557 10559 \
         10560 10561 10613 10614 10615 10646 10647 10648 10649 10650; do
  h=$(gh pr view $p --json headRefOid -q .headRefOid)
  gh api --paginate "repos/:owner/:repo/commits/$h/check-runs?per_page=100" \
    --jq '.check_runs[]|[.name,(.conclusion//"PENDING")]|@tsv' \
  | awk -F'\t' '$1=="Elixir gate"||$1=="Cloud gate"||$1=="Console gate"||$1=="PR references an active task"'
done
```

The MERGE commit is the wrong sha: every one of these PRs merged with a SINGLE-parent
(squash/rebase) commit, so the merge sha is new and mostly carries 0-30 push-triggered runs.
`gh api repos/:owner/:repo/commits/<merge>/check-runs` returned **0 runs** for 5 of 13.

## R3 — stale-green window (strict:false) per PR

```bash
h=<head>; m=<mergeCommit>; p1=$(gh api repos/:owner/:repo/commits/$m --jq '.parents[0].sha')
git merge-base --is-ancestor $p1 $h && echo FRESH || \
  echo "STALE by $(git rev-list --count $(git merge-base $h $p1)..$p1) commits"
```

## R4 — non-search-ranked enumeration of merged-and-unclosed epic rows

```bash
bp task get cloud-console-hardening-epic -o json > roster.json      # children[] is TOP-LEVEL
gh pr list --state merged --limit 3000 \
  --json number,title,body,mergedAt,headRefName,headRefOid,mergeCommit > merged.json
# then: for every child with lifecycle_status==open, substring-match its doc_id
# against every merged PR's title+body. Do NOT use `gh pr list --search "<slug>"`:
# it returns zero hits for these long hyphenated slugs (and returns zero SILENTLY
# when gh is run outside a git repo).
```

## R5 — `bp task claim` returns the new epoch at `doc.claim.epoch` (live, settled)

```bash
bp task claim <slug> <worker> -o json      # stdout: "help: ..." LINES FIRST, THEN the JSON
bp task release <slug> <worker> <epoch>    # reverses it
```

Live probe on `cch-w51-s3-site-rolled-back-becomes-storable`: stored epoch 9 →
claim returned `doc.claim.epoch = 10` → release bumped to 11, `claim.worker` back to null.
**Two traps for a close script:** (a) `-o json` still prints `help:` lines before the JSON, so
`bp task claim ... | jq` fails — slice from the first `{`; (b) a fresh claim WIPES the previous
`claim.now` note (the probe erased w51-s3's "DONE, unpushed" line).

## R6 — `bp` reads stdin

`while read s; do bp task get "$s"; done < list` silently drains the loop's stdin and yields
empty output for every row after the first. Use `bp ... < /dev/null` or `for s in $(cat list)`.
