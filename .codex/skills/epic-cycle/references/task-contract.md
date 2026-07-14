# Epic Cycle task contract

The Barkpark Task is the execution spine. Paper prose, a local plan, and a git branch never substitute for a published claimable task.

## Before work

1. Create and publish the task under the epic with `proj:`, `phase:`, and exact `files:` labels.
2. Link the wave with flat `wave_paper` and add evidence-bearing acceptance criteria.
3. Claim with a stable worker id: `bp task claim <task> <worker>`.
4. Read back with `bp task get <task> -o json`; trust the returned claim epoch, not a cached value.
5. Stamp `code_refs.branch`, `code_refs.worktree`, and `last_worked_at` when the worktree exists. Build preflight rejects any missing value; Review accepts an authoritative `code_refs.commits` entry after the worktree is cleared.
6. Run `python3 .codex/skills/epic-cycle/scripts/validate_epic_cycle.py --task <task> --paper <paper> --worker <worker> --phase build`.

No edit begins until this gate passes.

## While working

- Pulse immediately after claim and at every phase boundary: `bp task pulse <task> <worker> --now "…" --criterion N`.
- A pulse renews the claim and bumps its epoch. Reread before each `stamp` or `close`.
- Stamp a criterion the moment proof exists. Use the current epoch, zero-based index, exact criterion text, and non-empty evidence.
- Record failed attempts with `--miss`; never convert a failed gate into prose-only success.
- Strategic phases alone mutate the wave Paper. Surveyors, verifiers, and builders report through their task or parent result.

## Pull request and merge

1. Write the PR body to a file with an actual newline-delimited `Task: <task-id>` trailer. Do not construct it in an interpolated shell argument.
2. Validate it before `gh pr create` or `gh pr edit`: `python3 .codex/skills/epic-cycle/scripts/validate_epic_cycle.py --task <task> --paper <paper> --worker <worker> --phase build --pr-body <path>`.
3. After PR creation, append its number to `code_refs.prs` and publish the task update.
4. Builders leave merge-gated criteria open and lifecycle `in_progress`.
5. The lead follows `.claude/workflows/bp-loop-ledger.md`, waits for required CI, and merges from a dedicated integration worktree or the GitHub authority.
6. After merge, append the authoritative SHA to `code_refs.commits`, clear `code_refs.worktree`, update `last_worked_at`, reread the epoch, stamp the merge criterion, and close only when every criterion is proven.

## Recovery

- `fenced_off`: reread and renew the same-worker claim; never guess the epoch.
- `doc_changed_since_claim`: reread the task brief, reconcile the change, then retry.
- `rail_changed`: reread parent/blocks and confirm the task is still ready.
- Task trailer gate failure: inspect the body file with line numbers, correct it, validate locally, then retrigger the check.
