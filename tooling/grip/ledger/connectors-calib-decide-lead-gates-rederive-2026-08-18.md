<!-- doc-tier: cold | canonical-for: connectors-false-done-audit-calib-decide-lead-gates-rerun | budget: 1200tok -->

# Connectors false-done audit — calib-decide-lead-gates re-derivation recipe (2026-08-18)

Verifier lane `calib-decide-lead-gates`. Mutate-checked 5 lead-/decide-closed calibration
rows of the Connectors done set (epic task-e640bb01fca6ea38) by RUNNING their named gates
against origin/main = e21bf409 (local HEAD was 186 behind; connectors JS run from an
`git archive origin/main connectors` extract, Elixir run from the primary checkout whose
tested files are content-identical to origin/main — verified per file with `git diff --quiet origin/main -- <f>`).

Verdict: 5/5 TRUE-DONE, ZERO false-done. The decide-close row (#5762) is real, not a stub.

## Re-run commands

Denominator / ancestry (all cited merge SHAs ancestors of origin/main):

    git rev-parse origin/main   # e21bf409893d9de66542a31b06716e3c33d8f102
    for pr in 5762 3889 3933 11982 3758 5550; do gh pr view $pr --repo FRIKKern/barkpark --json mergeCommit -q .mergeCommit.oid; done
    # each -> git merge-base --is-ancestor <oid> origin/main  == ANCESTOR
    # #3558 is a task ISSUE not a PR (mirrored-number nuance) -> NOT a false-done; code landed via #3889/#3933 + migration file present.

Connectors JS (extract origin/main tree, then):

    WT=<scratchpad>/connectors-om; rm -rf "$WT"; mkdir -p "$WT"
    git archive origin/main connectors | tar -x -C "$WT"
    cd "$WT/connectors" && npm ci
    npx vitest run test/stable-frames.test.ts            # ROW connectors-stable-frames-tolerance-test (#11982): 6 passed
    npx vitest run test/discord-slash-commands.test.ts   # ROW connectors-discord-slash-registration-smoke (#5762, DECIDE-close): 19 passed
    npx tsx scripts/smoke-discord.ts                     # offline: signed PING->200{type:1}, COMMAND->200{type:5}, forged->401; EXIT=1 Missing-var msg; no secret leaked; guild-scoped PUT /applications/<app>/guilds/<guild>/commands present, OPT-IN gated

Elixir (primary checkout /Volumes/SATECHI/github/barkpark/api, files == origin/main):

    CC=clang MIX_ENV=test mix test test/barkpark_web/plugs/require_chat_access_test.exs  # ROW connectors-require-chat-access-plug-unit-test (#3758): 4 tests, 0 failures
    CC=clang MIX_ENV=test mix test test/barkpark/plugins/tickets/keys_test.exs           # ROW connectors-tickets-keys-workspace-blind-idor (#5550): 22 tests, 0 failures
    CC=clang MIX_ENV=test mix test test/barkpark/secrets_workspace_isolation_test.exs    # ROW task-5766dc5ca985ddc8 (#3889/#3933): 10 tests, 0 failures

Structural anchors confirmed on origin/main:
- require_chat_access.ex:58-62 nil-workspace -> 403 deny branch present.
- keys.ex rotate/pause/unpause thread ws_id -> scope_workspace fail-closed (binary=equality, nil=is_nil).
- migration 20260717070000: surrogate id binary_id gen_random_uuid PK, nullable workspace_id FK, partial unique secrets_global_name_index + secrets_workspace_name_index; secrets.ex scope_secrets/2 two-tier gate.

No reopens. No code edits. No commits by verifier.
