<!-- doc-tier: human | canonical-for: daily-news-routine | budget: 3000tok -->
# Daily news run

Every morning, one agent writes yesterday's News for each Barkpark repo. Hand it this line:

    Run the daily news for <DATE> (yesterday, Oslo time): follow tooling/news/DAILY.md in FRIKKern/barkpark.

It needs a clone of this repo, `git`, `python3` (3.9+) and `gh auth login`. Nothing else, and no state on any one machine: each repo keeps its own days in `docs/news/`.

```
tooling/news/run-daily <DATE>                      clone the repos into a temp dir, list each repo's merges
   ↓ agent writes docs/news/<DATE>.md in each clone that had merges
tooling/news/run-daily <DATE> --workdir <dir> --publish [--task <id>]
   ↓ render.py writes the README block, the repo's doc checks run, one PR per repo
fresh reviewer PASS on the head + every check green → merge (barkdown --merge, others --squash)
```

## 1. Prepare

    tooling/news/run-daily <DATE>

It prints, per repo: how many PRs merged that day (Oslo time), whether `docs/news/<DATE>.md` exists, the merge convention and doc checks, and which days the README would show. Each repo's merged PRs are in `<workdir>/<repo>.merges.json`. A repo with no merges gets no PR that day.

## 2. Write each day page

Read every merged PR: `gh pr view <n> -R FRIKKern/<repo> --json title,body`. Write `<workdir>/<repo>/docs/news/<DATE>.md`:

- Line 1 is the doc-tier header, where `repos.json` gives a `page_header` (barkpark). Next comes the news-day line. Then the page.
- The news-day line is one line of JSON:
  `<!-- news-day: {"summary": "...", "groups": [{"label": "...", "text": "...", "prs": [1, 2]}]} -->`
  - `summary`: 2 to 4 plain sentences that tell the day as a whole. Say what a person can now do, what got better, and what was found and fixed, with real numbers.
  - `groups`: at most 3, by meaning (e.g. "Desk: …"), with the important PRs linked.
  - The README block is rendered from this line only. Never edit the block by hand.
- The page itself:
  1. **What a person can now do**, step by step, so a reader can try it.
  2. **Where it is slow or rough**, with counts from the PRs. File new snags as bp tasks.
  3. **Across the projects**: how the day fits the repo's milestone and the other repos. Barkpark is the core. Link other repos' PRs, not their unmerged pages.
- Explain insider words (oracle, gate, rail, desk) in a few words where they appear.
- Every number and claim traces to a PR body. Never invent a quote, a user, a number or a picture.
- "Merged" is never "released" or "in your hands". Barkdown counts as shipped only after a green nightly; until then, "merged, not yet in a build".
- These repos are public. No person's name or email, no account names, no local paths, no hostnames, no task ids in the text.
- Pictures go in only if they are real and checked frame by frame, under 300 KB each, in `docs/news/img/`. BarkBot keeps pictures out of git.
- If the README still shows a day page with no news-day line (the 2026-11-15 pages from before this tool), add that line too. Its text is in the README block as it stands.

## 3. Publish

    tooling/news/run-daily <DATE> --workdir <dir> --publish --task <bp task id>

For each repo whose page is ready, it:

1. renders the README;
2. checks every local Markdown link;
3. runs the repo's doc checks from `repos.json`;
4. opens one PR on branch `docs/news-<DATE>`.

The barkpark PR needs `--task` for its `Task:` line. Caps are never raised and lines are never reflowed to fit: cut something honestly and say so in the PR.

## 4. Review and merge

- A fresh agent that did not write the page reviews each PR. It checks every sentence against the PR bodies and that nothing private shows, and returns `PASS <head>` or `FAIL <head>`. A new commit needs a new PASS.
- Merge only when the PASS is on the current head and every check is green:
  - barkdown: `gh pr merge <n> --merge -R FRIKKern/barkdown`. Never squash; it breaks the `concept` check.
  - Every other repo: `gh pr merge <n> --squash -R FRIKKern/<repo> --match-head-commit <sha>`.
- fluid-editor: never force push; if main moved, merge origin/main.
- A CONFLICTING PR starts no checks: merge origin/main, rerun `render.py`, push, and ask for a new review.
- Confirm `gh pr view <n> -R FRIKKern/<repo> --json state` says MERGED.

## 5. Report

Report each repo's PR and state, the rendered README block, repos skipped and why, what did not run, and the snags you filed.

## Files

| File | What |
|---|---|
| `run-daily` | prepare and publish, as above |
| `render.py` | the README block from `docs/news/YYYY-MM-DD.md` news-day lines: finished days that had merges, newest `days` |
| `repos.json` | per repo: days shown, merge convention, doc checks, page header, PR body head |
| `render.test.sh` | a fixture day renders the expected block, finished days only |
