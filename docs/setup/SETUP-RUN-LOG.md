<!-- doc-tier: human | canonical-for: setup-run-log | budget: 700tok -->
# Setup run log template

Copy this file for each test run of [SELF-HOST.md](SELF-HOST.md) or [ENTRA.md](ENTRA.md). Write each line when it happens, with UTC times. Keep secrets, tokens and passwords out of it.

```markdown
# Run <n> log: <what>, Path <A|B>

Docs: FRIKKern/barkpark main at <sha>. bp <version>. Start <time>. End <time>.
Names: resource group <rg>, host <host>, org <slug>, Entra app <name>.

## Steps
| Time UTC | Step or command | Result |
|---|---|---|
| 08:35:01 | Read SELF-HOST.md | ok |

## Clicks
- <time> <portal or browser page>: <what was clicked>, <why no command did it>

## Errors
- E<n> <time> <command>: <exact message>. <what it cost>

## Questions
- Q<n> <time> <question you would have asked a person>. <how it was answered>

## Frictions
- F<n> (<journey>, blocker|slow|annoying) <doc and section>: <what went wrong>

## Result
Minutes to sign-in: <n>. Commands typed: <n>. Portal clicks: <n>. Errors: <n>. Questions: <n>. Code reads: <n>.
Cleanup: `scripts/setup-guide/azure.sh down <rg>` output.
```

`scripts/run-setup-guide.sh` writes `<run dir>/steps.tsv` with the seconds per step. Copy those times into the steps table.

When the run is done, store the log as one task row under the goal's run-log row, so the goal links every run:

```bash
bp task create "Run <n> log: <what>" --publish --description "$(cat run-<n>-log.md)" \
  --set parent_id=<run-log row> --set 'labels:=["run-log"]'
```
