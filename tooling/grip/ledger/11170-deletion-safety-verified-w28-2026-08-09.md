# #11170 deletion safety — VERIFIED (dr-w28, v7-11170-deletion-safety, 2026-08-09)

Verdict: **the deletion is safe to land**, the PR's "never had a reader" claim is **TRUE** and machine-checkable,
the `@build_slot_capacity` fence is **untouched**, and all **four** required contexts are green **at the head sha
`5ac40411550efd7a54a7134c4bba18f4346edceb`** (not an older commit). One residual cost is real and already filed.

## Re-derivation recipes

Zero readers, whole tree, three casings (D453's own definition — a reader is a code path that NAMES the key):

    git grep -n 'build_slots\|runner_queue_len\|buildSlots\|runnerQueueLen' origin/main \
      -- cloud internal js web docs scripts deploy .github api/priv/static
    # -> EMPTY. Every hit repo-wide is in api/ (the producer + its own tests)
    #    or tooling/grip/ledger + the charter (historical prose).

No non-test caller of the route either:

    git grep -n 'v1/instance/site-deploy' origin/main
    # -> charter prose, deploy_runner.ex comment, the route's own test, one ledger curl (401)

The fence is not touched — `deploy_runner.ex` is byte-identical on both refs and is not in the PR's file set:

    git diff --stat origin/main pr-branch -- api/lib/barkpark/sites/deploy_runner.ex   # -> empty
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '301p;736,737p'
    #   @build_slot_capacity 1
    #   @spec build_slot_capacity() :: pos_integer()
    #   def build_slot_capacity, do: @build_slot_capacity

`router.ex` is COMMENT-ONLY (the `get("/instance/site-deploy", …)` line and its `pipe_through` are context):

    git diff origin/main...pr-branch -- api/lib/barkpark_web/router.ex \
      | grep -E '^[+-]' | grep -v '^[+-][+-]' | grep -vE '^[+-]\s*#'
    # -> EMPTY (rc=1). Deleting a READOUT is not touching the CAPACITY constant.

Required contexts at the head sha (not the PR's rollup):

    gh api repos/FRIKKern/barkpark/commits/5ac40411550efd7a54a7134c4bba18f4346edceb/check-runs \
      --paginate --jq '.check_runs[]|"\(.conclusion)\t\(.name)\t\(.head_sha[0:9])"' | sort
    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '.required_status_checks.contexts, .required_status_checks.strict'
    # required = ["Elixir gate","PR references an active task","Cloud gate","Console gate"] — all `success` at 5ac404115
    # strict = false  (so the 9-commit staleness is checked separately, below)

The one red (`Sobelow static analysis`) is **main's own**, not this PR's — same job, byte-identical scan output
apart from the artifact ID, same 2845-byte baseline artifact:

    for s in 5ac40411550efd7a54a7134c4bba18f4346edceb a95bc7ca9747cb3d90a361c4d54eb2c068a24e32; do
      jid=$(gh api repos/FRIKKern/barkpark/commits/$s/check-runs --paginate \
            --jq '.check_runs[]|select(.name|startswith("Sobelow static"))|.id')
      gh api repos/FRIKKern/barkpark/actions/jobs/$jid/logs | grep -iE 'Finding|baseline|Total' \
        | sed 's/^[0-9T:.Z-]*[[:space:]]*//' | sort -u > /tmp/sob-$s.txt
    done; diff /tmp/sob-*.txt   # -> only the two Artifact ID lines differ

Staleness (strict:false, so this is the real merge risk and it is nil):

    git merge-base origin/main pr-branch                        # 48a200aa7583cf7613424e94adca9edf7c224ea8
    git rev-list --count 48a200aa7..origin/main                 # 9
    git diff 48a200aa7..origin/main | grep -niE '^\+.*(build_slots|runner_queue_len)'   # -> no NEW reader
    git diff --stat 48a200aa7..origin/main -- <the PR's 3 files>                        # -> empty, no overlap
    git merge-tree $(git merge-base origin/main pr-branch) pr-branch origin/main | grep -c '<<<<<<<'  # 0

Go gate, run locally on this tree (`CC=clang` — the `cc` alias shadows the compiler and `go vet` dies with
`error: unknown option '-E'` without it):

    CC=clang go build ./...            # rc 0
    CC=clang go vet ./internal/cli/... # rc 0
    CC=clang go test ./internal/cli/...
    # ok github.com/FRIKKern/barkpark/internal/cli · /cloud · /cloud/azure · /setup   rc 0

## What the deletion actually costs, said plainly

* `build_slots` costs **nothing**: it was `DeployRunner.build_slot_capacity/0`, a compile-time constant, and
  `door.capacity` carries the same number. The PR RE-ANCHORS the surviving assertion from
  `door["capacity"] == body["build_slots"]` (wire vs. wire, satisfied by identity) to
  `door["capacity"] == DeployRunner.build_slot_capacity()` (ETS census vs. the attribute it admits BY) —
  a genuine cross-check where there was a tautology.
* `runner_queue_len` costs the route's **only mailbox observable**, and with it the wedged-Runner positive
  control. The no-`GenServer.call` property of `show/2` is now **UNPINNED**. The PR says so in three places
  and the replacement is filed and EXISTS on the ledger — verified, not cited:
  `dr-w27-s7-restore-a-wedge-control-that-does-not-need-runner-queue-len`, open, 0/N, whose criteria demand
  `Process.info(wedged, :message_queue_len) >= 6` on the wedged pid directly plus a MUTATION red.
* D470's **VACUOUS SURVIVOR** is closed, not inherited: `assert is_nil(body["runner_queue_len"])` (which passed
  unchanged after the key was deleted) is replaced by `refute Map.has_key?(body, "build_slots")` /
  `refute Map.has_key?(body, "runner_queue_len")` plus four-key set equality.
* D470's **C7 inversion** is honoured: `cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs` is
  NOT in the PR's file set, so the seven-row register stays on `@register_floor 7`.
* D470's **C4** is honoured: `defp message_queue_len/1` is deleted with its call sites, so
  `--warnings-as-errors` has no orphan to trip on — and the green `Prod compile gate` at 5ac404115 confirms it.

## What a later reader should NOT conclude

`api/test/barkpark/sites/deploy_runner_door_census_test.exs` still names `build_slots` at `:9` and `:119`.
Both are PROSE (moduledoc + comment) explaining what the constant could not do. There is no assertion there,
the PR correctly leaves the file alone, and a future scoped grep must not read those two lines as a surviving
reader.
