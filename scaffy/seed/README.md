<!-- doc-tier: human | canonical-for: scaffy-seed-loop | budget: none -->
# scaffy/seed — corpus → published `command` documents

`go run ./scaffy/seed` derives one flat JSON payload per
`scaffy/commands/*.scaffy` file (validate → parse → derive, refusing the
whole run on ANY `scaffy.ValidateFile` finding) into `scaffy/seed/out/`
(gitignored — payloads are derived; the `.scaffy` files are the truth).

Fields per payload (charter D46/D47): `_id = <domain>--<concept>--<variant>`
(concept alone is NOT unique — the docs-card add/remove pair shares one),
`title`/`description`/`concept`/`variant`/`domain`/`direction` from the
header, `tags` = the TAGS list as weighted entries with distinct descending
strengths (90, 80, 70, …), and `source` = the raw file bytes verbatim.

## The seed loop

Run against the configured server (`~/.config/barkpark/`; needs a token that
may write + publish):

```sh
go run ./scaffy/seed
for f in scaffy/seed/out/*.json; do
  id=$(basename "$f" .json)
  bp doc create-or-replace command --file "$f" --yes
  bp doc publish command "$id" --yes
done
```

Publishing matters: anonymous reads serve the PUBLISHED perspective, so an
unpublished command is invisible to the one-connect pull
(`GET /v1/data/query/production/command`).

The loop is idempotent — `createOrReplace` is an upsert by `_id`, so a
re-run leaves exactly the same document set (revs bump, zero duplicates).

## `unknown_tag` on publish (the E3 wall)

`bp doc publish` 422s with `unknown_tag` when any weighted-tag name does not
resolve to a PUBLISHED `type:tag` document in the dataset. The remediation
is to register the missing tag first — the house pattern is a tag doc whose
`_id` IS the tag name — then retry the publish:

```sh
bp doc create-or-replace tag \
  --set _id=<name> --set title="<Title>" \
  --set description="<one honest sentence>" --yes
bp doc publish tag <name> --yes
```

## Re-seed after amend (the law) + `--check` audit

**Any PR that touches `scaffy/commands/*.scaffy` must re-seed the touched
commands** — the served `command` document's `source` is a byte copy, so an
un-re-seeded edit silently drifts the catalog from the repo. (This happened:
the W7 prose-amendment PR merged without re-seeding, and `add-block-type` +
`classify-block-type` served stale for a tick.) Re-run the seed loop above for
the edited ids, or the whole loop — it is idempotent.

`--check` is the audit that catches the miss:

```sh
go run ./scaffy/seed --check
```

It derives every payload **in memory** (no `out/` writes), fetches the served
catalog tokenless
(`GET <server>/v1/data/query/production/command?limit=100` — `server` from
`~/.config/barkpark/config.json` if present, else `guerrilla.barkpark.cloud`),
and compares `sha256(source)` per command id. It prints a table
(`id · local sha8 · served sha8 · MATCH/DRIFT/MISSING/EXTRA`) and **exits
nonzero on any non-MATCH**:

- **MATCH** — repo byte-identical to served.
- **DRIFT** — both present, bytes differ → the command was edited without a
  re-seed. Re-seed it.
- **MISSING** — in the repo, never seeded → run the seed loop for it.
- **EXTRA** — served with no local corpus file → a stale document to retire.

It fails **loud** on any network error (unreachable host, non-200, bad JSON): a
check that cannot reach the catalog exits nonzero, never a false green. Run it
in seconds from any session; CI runs it as an ACTING post-merge gate
(.github/workflows/scaffy-catalog-drift.yml, charter D100).

### Repairing drift from CI

The gate DETECTS drift on every trigger (push to main, the daily cron, and
dispatch) and reds hard on it. It only WRITES on a manually dispatched run that
opts in: **Actions → scaffy-catalog-drift → Run workflow → repair = true**,
with `BARKPARK_SEED_TOKEN` installed.

The write is deliberately withheld from unattended runs. The repair logic had
executed zero times across the workflow's first twelve runs — every red stopped
at the credential guard and every green skipped the step — so wiring the secret
to a cron would have promoted never-executed shell to an unattended writer
against production content, with its first execution and its first evidence in
the same 06:17 UTC event.

That logic now lives in `repair.sh` rather than inline in the workflow,
precisely so it can be tested: `repair-selftest.sh` drives it against a local
fixture server on every run of the gate and asserts four arms — the happy path
posts one atomic `createOrReplace` + `publish` batch per id, the E3
`unknown_tag` wall is cleared by registering tag docs and the retry succeeds, a
refused write reds instead of being swallowed, and an empty drifted-id list is
an error rather than a silent success. Zero egress, zero credentials, so it
runs anywhere:

```
bash scaffy/seed/repair-selftest.sh
```

## `--impact` — the PR-time preflight, and WHERE IT RENDERS

`--check` is the post-merge verdict. `--impact` is the same comparison asked
one merge earlier: given a PR's changed-file list, does merging it put the
served catalog behind main, and which commands?

```
git diff --name-only origin/main...HEAD > changed.txt
go build -o /tmp/seed ./scaffy/seed && /tmp/seed --impact --changed-files changed.txt
```

**Build the binary; do not `go run` it.** `go run` collapses every nonzero
child status to `1`, so the three-way exit contract below is destroyed on the
way out. Measured: an exit-3 NOTICE arrived at the shell as `EXIT=1`.

| exit | verdict | stdout |
|---|---|---|
| 0 | QUIET — the diff touches nothing the deriver reads, **or** it does and the head tree still matches the served catalog | **empty** |
| 2 | CANNOT READ — catalog unreachable, catalog served zero commands, deriver produced zero commands, or the read-path predicate itself could not be computed | the CANNOT READ block |
| 3 | NOTICE — merging puts the named commands behind the catalog | the notice |

`0` and `2` are separate codes on purpose. A failed reachability check that
renders as a clean bill of health is the defect this whole area exists to
refuse — "a check that cannot check never reports clean" applies to the
pre-merge half exactly as it applies to the post-merge gate.

### The read-path set is derived, not listed

The notice stays silent unless the diff touches what the deriver **actually
reads**, and that set is computed from this program's own source every run:

1. the corpus glob — the same `defaultCommandsDir` + `corpusGlobPattern`
   identifiers `deriveAll` globs, so moving the corpus moves the predicate;
2. the **transitive first-party import closure** of `scaffy/seed`, walked from
   `go.mod`'s module path with `go/parser`. Today: `scaffy/seed` +
   `internal/scaffy`. Import `internal/foo` tomorrow and `internal/foo` joins
   the read set with no edit here.

Contrast `.github/workflows/scaffy-catalog-drift.yml`'s `on: push: paths:`
block, which is the hand-written snapshot of this same set. An enumeration is a
snapshot; a predicate is a rule. `TestClosureIsAPredicateNotASnapshot` proves
the difference against a synthetic module importing a package this repo has
never named.

Attribution is narrowed twice more, because a notice that hands an author
commands they did not touch dies the same death as one that fires on every PR:

- a touched **corpus file** accounts for its own command only;
- a touched **deriver file** accounts only for rows whose divergence is in
  DERIVED METADATA. It is never billed a `source`-only divergence: `derive`
  copies the raw file bytes verbatim, so no derivation change can move that
  field. (Found by running it: main's catalog carries source-only drift, and
  the first version billed all of it to a PR that touched only `scaffy/seed/`.)

### WHERE THIS RENDERS, AND WHO IS FORCED TO LOOK — the honest answer

**UPDATE 2026-09-25 — the renderer is now wired.** `scaffy-catalog-drift.yml`
gained a `pull_request` arm on the same paths as its push arm (task
`dr-w31-bl-served-catalog-drift-is-red-and-unowned`). On a PR its last step
runs `--impact` over `git diff --name-only HEAD^1 HEAD` of the merge commit:
QUIET greens, NOTICE and CANNOT READ red that check, and drift the notice does
not bill to the PR is a `::warning::`, never a red. That check is still **not
required** and must never be (a paths-filtered name deadlocks PRs that miss
the paths), so "nothing forces a look" below remains true of the merge button;
what changed is that the author now sees a red check instead of nothing. The
rest of this section is the record of why it shipped unwired.

**Nothing forces a look. This is advisory, and it is advisory for a structural
reason, not an oversight.**

Rendering a signal at review time means a check run, a PR comment, or a job
summary, and every one of those is produced by a file under `.github/`. That is
a different ownership fence from this one. `--impact` is therefore shipped as
the *computation* — correct, tested both directions, exit-code addressable —
with the *rendering* left unwired. Today the only way to see it is to run it.

This is stated plainly because the area's own history punishes the alternative.
`scaffy-catalog-drift.yml`'s header records that under `continue-on-error` it
fired on the merge that introduced it and on every daily run for ~8 days, all
rolled up green, until charter D100 flipped it to an acting gate on the finding
that **"an alarm nobody can hear is not advisory, it is silent."** Claiming
review-time enforcement that no mechanism provides would repeat exactly that,
one layer up. So: no such claim is made here, in the notice's own footer, or in
the PR that introduced it.

**What it is still worth without a renderer.** Three things, all real today:

1. It is runnable by hand and by any future wiring, and it answers the question
   a reviewer currently cannot answer at all — the post-merge watcher
   structurally *cannot* see a pre-merge diff, and its header says so.
2. The predicate and the CANNOT-READ/QUIET/NOTICE trichotomy are the parts that
   are hard to get right and easy to get subtly wrong; they are now proven by
   mutation rather than deferred until somebody wires a surface.
3. Wiring it is then a ~10-line job for whoever owns `.github/`, with no
   design left to redo.

**What wiring it would take** (for the `.github/` owner — a suggestion, not a
registered context; note that a REQUIRED check which never emits deadlocks a
branch, so this must stay off the required set unless it renders on *every* PR):

```yaml
# in an always-running pull_request job — NO workflow-level paths: filter
- run: git diff --name-only ${{ github.event.pull_request.base.sha }}...HEAD > /tmp/changed.txt
- run: go build -o /tmp/seed ./scaffy/seed
- id: impact
  run: |
    set +e
    out="$(/tmp/seed --impact --changed-files /tmp/changed.txt)"; code=$?
    printf '%s\n' "$out"
    case "$code" in
      0) exit 0 ;;                                  # silent by design
      3) { echo '## scaffy catalog impact'; echo '```'; printf '%s\n' "$out"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"; exit 0 ;;
      *) { echo '## scaffy catalog impact — CANNOT READ'; echo '```'; printf '%s\n' "$out"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"; exit 0 ;;
    esac
```

A step summary is seen only by someone who opens the run. A PR comment is the
only surface a reviewer meets without choosing to; whether that trade is worth
the comment noise is the `.github/` owner's call, not this program's.
