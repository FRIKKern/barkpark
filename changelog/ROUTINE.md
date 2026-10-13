<!-- doc-tier: human | canonical-for: changelog-routine | budget: 4200tok -->
# Changelog routine

Three Claude cloud routines tell what changed in **Barkpark** (this repo) and
**Barkdown** (`FRIKKern/barkdown`): daily, weekly, monthly. Each layer reads the
one below it, so the record stacks:

```
git first-parent log ──► DAILY  paper + changelog/daily/YYYY-MM.md
                              │ 7 days
                              ▼
                         WEEKLY paper + editorial (Barkpark) + README "What's new"
                              │ ~4 weeks
                              ▼
                         MONTHLY paper + changelog/monthly/YYYY.md + README months line
```

| Routine | Oslo time | UTC cron | Runs after |
|---|---|---|---|
| daily | 07:00 every day | `0 5 * * *` | Chronicle script (00:17 UTC) |
| weekly | Monday 09:00 | `0 7 * * 1` | daily + weekly-changelog script (06:17 UTC) |
| monthly | 1st, 10:00 | `0 8 1 * *` | daily + weekly |

The routine prompt names its cadence and says "follow changelog/ROUTINE.md".
Improve a routine by editing this file. Change its schedule at claude.ai/code/routines.

## Rules for the writing

- Git is the source of truth. Every claim cites a PR (`#123`) or a commit. Never
  invent numbers, customers, dates or adoption.
- Plain words. Lead with what a user or operator can now do, or what stopped
  breaking. Name the real theme: 30 "owner ruling" fixes are a security sweep,
  not "api moved forward".
- Pick. A day gets 3–6 bullets, a week 3 highlights, a month 3–5 threads. Skip
  dependency bumps, CI plumbing and test-only commits unless they are the story.
- A quiet day is fine: say so in one line.
- Barkdown's `README.md` "Where we are" section belongs to its build agents.
  Never edit it. Only edit between the highlight markers.

## Setup (every run)

The environment must provide `BARKPARK_API_URL` (`https://guerrilla.barkpark.cloud`),
`BARKPARK_API_TOKEN` (read+write) and `GH_TOKEN` (contents, pull requests and
issues on both repos). If one is missing, stop and print which one.

```sh
make cli-build && export PATH="$PWD/dist:$PATH"   # bp from this checkout
command -v gh || { V=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p'); curl -sL "https://github.com/cli/cli/releases/download/v$V/gh_${V}_linux_amd64.tar.gz" | tar xz -C /tmp && export PATH="/tmp/gh_${V}_linux_amd64/bin:$PATH"; }
gh auth setup-git
git fetch origin main
test -d ../barkdown || gh repo clone FRIKKern/barkdown ../barkdown -- --filter=blob:none
git -C ../barkdown pull --ff-only
date -u    # read the clock; never guess a date
```

Every prod write with `bp` needs `--yes`. Read periods in UTC.

## Papers

Barkpark's papers come from `scripts/chronicle-paper.py`. The agent rewrites
their story blocks; the script keeps navigation, stats and the full ledger.

| Period | Barkpark slug | Barkdown slug |
|---|---|---|
| day | `barkpark-changelog-YYYY-MM-DD` | `barkdown-changelog-YYYY-MM-DD` |
| week | `barkpark-changelog-YYYY-wWW` | `barkdown-changelog-YYYY-wWW` |
| month | `barkpark-changelog-YYYY-MM` | `barkdown-changelog-YYYY-MM` |

**Barkpark: rewrite, don't replace.** `bp doc get paper <slug> -o json`, take
`_rev`, then one `bp bulldocs patch <slug> --if-rev <rev> --file ops.json --yes`
with `patch-block` / `replace-block` ops on these ids only:
`auto:title` (heading `text`), `auto:ingress` and `auto:dek` (inline `content`),
`auto:progress-assessment` (callout or pullquote: keep its type). Then add the
real story with `insert-after` `auto:dek`, block id `agent:story`: a heading
"What happened" and 3–6 short paragraphs or a list, each item linking its PR
(`https://github.com/FRIKKern/barkpark/pull/N`). If `agent:story` exists,
`replace-block` it. Keep every other `auto:` block. If the paper is missing,
the Chronicle run failed: report it and file a task. Don't create it.

**Barkdown: there is no script.** Write the whole paper with
`bp bulldocs publish <slug> --file paper.json --yes` (upsert). Copy the shape of
the matching Barkpark paper: eyebrow `BARKDOWN CHRONICLE · DAY · <date>`, title
heading, ingress, the story, a `paper-links` block to the parent and child
periods. Link commits as `https://github.com/FRIKKern/barkdown/commit/<sha>`.
Barkdown is private: link commits in papers, don't paste diffs. The guide is
`/papers/paper-authoring-excellence`. Use `bp paper export <slug>` on a Barkpark
chronicle paper to see a valid payload.

## Repo files

| Repo | Daily | Weekly | Monthly |
|---|---|---|---|
| Barkpark | `changelog/daily/YYYY-MM.md` | `changelog/editorial.json` + `README.md` | `changelog/monthly/YYYY.md` + `README.md` |
| Barkdown | `docs/changelog/daily/YYYY-MM.md` | `docs/changelog/weekly/YYYY.md` + `README.md` | `docs/changelog/monthly/YYYY.md` + `README.md` |

Newest entry on top. A new Barkpark file starts with
`<!-- doc-tier: human | canonical-for: changelog-<daily|monthly>-<period> | budget: 9000tok -->`.
A day entry:

```md
## 2026-10-04 · Sunday
**Sign-in and sharing got stricter.** One sentence on why it matters.
- Preview tokens read only the documents they name (#21512)
- …
[Paper](https://guerrilla.barkpark.cloud/papers/barkpark-changelog-2026-10-04) · 87 merges
```

**README block.** Both READMEs carry the block between
`<!-- highlights:start -->` and `<!-- highlights:end -->`. Barkdown gets it
right after its "Where we are" section, under a `## This week` heading; add the
markers on the first weekly run. Content, at most ~1,500 bytes:

1. `**Where we are · <date>**`: one or two sentences, Barkdown style.
2. `**This week (<range>)**`: three bullets with links, then `[Weekly edition](…) · [Paper](…)`.
3. `**Earlier weeks**`: the last four weeks, one line each, newest first.
4. `**Months**`: the last three months, one line each.

The weekly run rewrites 1–3 and shifts 3; the monthly run rewrites 4. Barkpark's
README has a hard 7,400-byte cap (`scripts/check-doc-budgets.sh`).

## Weekly editorial (Barkpark)

`changelog/editorial.json` drives the GitHub "Barkpark Weekly" issue. Keys are
ISO-week Mondays, and the file must have **no gaps**: `edition` is the 1-based
position. If weeks are missing since the last key, write them all, oldest
first. Each entry: `kicker`, `title`, `dek` (≥70 chars), `opener` (≥180),
three `highlights` (`title`, `summary` ≥80, `changes`: 1–3 commit-sha prefixes
inside that week, none repeated), `closing` (≥100). Check before committing:

```sh
python3 scripts/weekly-changelog.py --validate-editorial --ref HEAD
python3 scripts/weekly-changelog.py --week <monday> --ref HEAD | head -40
```

On merge, `weekly-changelog.yml` republishes exactly the weeks the push changed.

## Landing changes

**Barkpark** (`main` is protected; every PR needs a claimed task):

```sh
bp task create "Changelog <cadence> <period>" --publish --yes \
  --description "<cadence> changelog routine for <period>: papers, repo files." \
  --set 'tags:=[{"tag":"docs","strength":90,"rationale":"changelog"}]' \
  --set 'acceptance_criteria:=[{"criterion":"the <period> changelog files are on origin/main","met":false,"evidence":""}]'
bp task claim <id> changelog-routine --yes          # note the epoch
git switch -c changelog/<cadence>-<period> origin/main
# edit, commit (no Co-Authored-By line), push
gh pr create --title "docs(changelog): <cadence> <period>" --body "…

Task: <id>"
bash scripts/bp-merge.sh                            # waits for the four required checks, then squashes
bp task close <id> changelog-routine <epoch> done "<PR url>"
```

If a check fails on something you didn't touch, leave the PR open, say so in
the summary, and don't retry it more than once. Claims lapse after 45 minutes,
so `bp task pulse` during a long wait (it changes the epoch).

**Barkdown**: commit only the changelog files and README block. Push to `main`
(it's unprotected and its docs commits go straight there). Run
`node scripts/check.cjs`. If it fails on your files, fix them. If it fails on
something else, note it and push anyway.

## Finish

Print a summary: papers written (links), commits/PRs landed, anything that failed
and why. If something broke, file a `bp task` with the error. Don't report
success you didn't check: re-read one paper and `git log origin/main -1` on each
repo after landing.
