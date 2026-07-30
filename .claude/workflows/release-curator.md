# Release-curation agent (isu-w3)

The self-update initiative's **release curator**. Its job: turn "newest commit
on main" into a **blessed release with human-readable notes**, so that
`SelfUpdate.Checker` (W1) advertises real releases and the Studio bar (W2)
shows real notes — not raw commit subjects.

It runs on a schedule (or on demand). Every deterministic fact comes from
`scripts/release-scan.sh`; the agent spends its judgment only on what a parser
can't decide — *is this worth releasing, and how do you say what changed*.

Design paper: `/papers/self-update-from-nag-to-product`. Task: `isu-w3-curation-agent`.

---

## Modes (default is the safe one)

| Mode | `RELEASE_CURATOR_MODE` | What it does |
|---|---|---|
| **propose** (default) | unset / `propose` | Drafts notes and opens a **draft** GitHub Release. No tag is pushed — publishing the draft (a human click) creates the tag and lights up W1/W2. Fully reversible. |
| **autonomous** | `autonomous` | Only when CI is green: creates the annotated tag AND publishes the Release. Arm this deliberately — it ships to every instance polling for updates. |

Autonomous is the "update everyone" trigger's upstream: a published release is
what W4's fleet rollout acts on. Do not enable it until the bless policy is
ratified (see the paper's open decisions).

---

## The loop

1. **Scan.** `scripts/release-scan.sh origin/main` → JSON: `last_tag`,
   `head_sha`, `commit_count`, `commits[]` (subject + PR), `ci` (rollup, with
   advisory checks flagged), `suggested_bump`, `suggested_version`.

2. **Gate — do nothing unless it's real and green.**
   - `commit_count == 0` → nothing since the last release. Stop.
   - `ci.status == "failure"` → main is red on a **required** check. Do NOT
     propose. Report the failing checks — `ci.failures` where `advisory` is
     `"blocking"` **or** `"cannot_tell"`. `advisory` is a three-valued STRING,
     never a boolean: `"advisory"` (its check suite rolled up green, so GitHub
     itself excluded it — `continue-on-error`), `"blocking"` (sole red in a red
     suite, which a `continue-on-error` job could not have caused), and
     `"cannot_tell"` (a red suite with several reds — GitHub does not expose
     which of them were advisory). Each entry carries `advisory_basis` in
     words; quote it rather than paraphrasing. `ci.advisory_certainty` is
     `"known"` only when no entry is `"cannot_tell"` — when it is
     `"cannot_tell"`, say so in the run log instead of implying a clean read.
     Advisory reds never block, per the project's always-merge rule.
   - `ci.status == "pending"` → checks still running. Re-run next tick; don't
     propose a half-verified build.
   - `ci.status == "unknown"` → the reader could not decide (no referenced
     suites, or this sha's suites were cancelled/stale — `status_reason` says
     which). **Cancelled is not failure**: `ci.cancelled_runs[]` classifies each
     one `superseded` / `cancelled` / `unknown` with its `basis`. Do not report
     a superseded run as a failure, and do not call main jammed on one.

3. **Judge worthiness.** Is there user-facing substance (features, fixes), or
   only chore/docs/test churn? A pile of `chore:`/`docs:` commits is not a
   release — hold and wait for something worth shipping. Say so in the run log.

4. **Draft the notes.** Human prose, not commit subjects:
   - Title: `Barkpark <suggested_version>`.
   - Open with the one-line headline — the most significant thing that changed.
   - Group the rest by theme (Features / Fixes / Under the hood), each a short
     sentence a Studio admin understands, linking its PR (`#NNNN`).
   - Trust `suggested_bump` but override it in the notes if the changes are
     bigger/smaller than the commit types imply (a `fix:` that's actually a
     breaking change is a real judgment call — that's why an agent does this).

5. **Propose** (default) — write the notes to a file and:
   ```bash
   gh release create "v<version>" --draft --target "<head_sha>" \
     --title "Barkpark <version>" --notes-file <notes.md>
   ```
   `--draft` means **no tag is created** until a human publishes it. Report the
   draft's URL for review. If annotated tags are preferred (the existing
   `vA.B.C` tags are annotated), print this for the human to run instead of
   clicking Publish:
   ```bash
   git tag -a v<version> -m "Barkpark <version> — <headline>" <head_sha>
   git push origin v<version>
   gh release edit v<version> --draft=false --verify-tag
   ```

   **Autonomous** — only if `ci.status == "success"`:
   ```bash
   git tag -a v<version> -m "Barkpark <version> — <headline>" <head_sha>
   git push origin v<version>
   gh release create v<version> --verify-tag \
     --title "Barkpark <version>" --notes-file <notes.md>
   ```

6. **Log** what it did (proposed / held / blocked-on-red) and why, so the run
   is auditable.

---

## Hard rules

- **Never** touch the `cli-v*` tag space — that's the separate `bp` CLI release
  line (`.github/workflows/cli-release.yml` owns it).
- **Never** delete, retag, or overwrite an existing release/tag.
- **Never** publish on red required checks. Advisory reds are fine.
- Draft-only in propose mode. The human publishes.

## Running it

- **On demand:** point an agent at this file with the scan output.
- **Scheduled:** arm a routine with the `/schedule` skill (suggested cadence:
  once a day, or after a batch of merges). Keep it in **propose** mode until the
  bless policy is decided — a daily draft Release for a human to publish is the
  low-risk default.
- **Scope guard:** the agent needs `gh` auth with `contents:write` on the repo
  to create releases; the scan itself is read-only.
