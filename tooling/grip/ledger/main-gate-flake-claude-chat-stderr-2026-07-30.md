# main-gate-flake — claude_chat_test.exs:808 — INTERMITTENT RACE (confirmed) 2026-07-30

Claim under test: is `test/barkpark_web/studio/claude_chat_test.exs:808`
("removes the stderr capture file on close") an intermittent race, or newly
deterministic on the current runner image?

VERDICT: intermittent, load-dependent race. AND the test's *green* is vacuous —
the file it claims was removed is created 6/6 times right after the assertion.

Tree: origin/main @ 453ee749a. Local Elixir 1.19.5/OTP 28 (CI: 1.18.1/OTP 27).

## 1. Repeat runs on a quiet host — 13/13 green

    cd api && for i in $(seq 1 12); do CC=clang mix test \
      test/barkpark_web/studio/claude_chat_test.exs 2>&1 \
      | grep -E "^(Running ExUnit|[0-9]+ tests|Finished)"; done
    # => every run: "129 tests, 0 failures"

    cd api && for i in $(seq 1 40); do CC=clang mix test \
      test/barkpark_web/studio/claude_chat_test.exs:808; done
    # => single-test PASS=40 FAIL=0

## 2. Reproduced under CPU load — 5 failures in ~30 runs

    cd api && for j in $(seq 1 24); do (while :; do :; done) & done
    for i in $(seq 1 30); do CC=clang mix test \
      test/barkpark_web/studio/claude_chat_test.exs:808 2>&1 | tail -4; done
    # => FAIL at iterations 5, 15, 16, 18, 28 ("1 test, 1 failure")
    # host: 10 cores, load avg 6.7 before the spinners

## 3. CI: the same commit reruns GREEN

    gh run rerun --failed 30487249488            # commit 453ee749a
    gh run view 30487249488 --json jobs -q '.jobs[]|"\(.conclusion)\t\(.name)"'
    # => success  Test (Elixir 1.18.1 / OTP 27.0)
    # => success  Elixir gate      <-- required context, main now GREEN
    # Original failure text (run 30487249488, seed 533019, max_cases: 8):
    #   1) test session subprocess removes the stderr capture file on close
    #      Expected false or nil, got true
    #      code: refute File.exists?(path)
    #      "/tmp/barkpark-claude-0c1cfb13-...-3c28655342cb.stderr"

    gh run list --workflow=elixir.yml --branch main --limit 30
    # => exactly 1 failure among 30 (453ee749a); every other completed run success

## 4. MECHANISM — TOCTOU between cleanup_stderr and the child shell's `2>>`

`claude_chat.ex:1345` spawns `sh -c 'exec "$0" "$@" 2>>"<path>"'`; the SHELL
creates the file (O_CREAT via `2>>`) asynchronously after `Port.open`.
`terminate/2` (:1553) calls `cleanup_stderr` → `File.rm(path)` (:1569).
The test closes the session immediately after start, so `File.rm` can win the
race against the shell's open — after which the shell creates the file again.

Measured: 6/6 GREEN runs each leaked exactly one 0-byte file.

    cd api && for i in 1 2 3 4 5 6; do \
      b=$(ls $TMPDIR/barkpark-claude-*.stderr | wc -l); \
      CC=clang mix test test/barkpark_web/studio/claude_chat_test.exs:808 | grep "^1 test"; \
      a=$(ls $TMPDIR/barkpark-claude-*.stderr | wc -l); echo "delta=$((a-b))"; done
    # => "1 test, 0 failures" + delta=1, six times in a row

    ls $TMPDIR/barkpark-claude-*.stderr | wc -l     # => 582
    find $TMPDIR -maxdepth 1 -name 'barkpark-claude-*.stderr' -size 0 | wc -l   # => 385

So charter-D54's "the stderr capture file must not outlive the session" is
violated on EVERY run of this shape; whether ExUnit sees it is sub-millisecond
luck. Red = the shell won; green = the shell was a hair late.

## 5. Escape hatch exists

`api/test/test_helper.exs:60` lists `:flaky` in the default `exclude:` set, so
`@tag :flaky` removes a test from plain `mix test` (and therefore from CI).
Precedent is in the same file's header comment (:24-27).

## 6. Side finding — the advisory Format check is DETERMINISTIC red on main,
and the two formatters DISAGREE

    gh api repos/FRIKKern/barkpark/actions/jobs/90734017831/logs | grep -oE 'api/test/[^ ]*\.exs' | sort -u | wc -l
    # => 63 files unformatted per CI's Elixir 1.18.1 (reran, failed again)
    cd api && CC=clang mix format --check-formatted
    # => local 1.19.5 flags exactly ONE: test/barkpark_web/controllers/tasks_controller_test.exs
    # 3 of CI's 63 are inside the studio fence:
    #   studio/editor_panel_containment_test.exs, studio/wide_geometry_lock_test.exs,
    #   components/studio_components/presence_nav_test.exs
    # Consequence: running `mix format` locally (1.19) does NOT satisfy CI (1.18)
    # and can lengthen CI's list. Advisory only — not a required context:
    gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.contexts'
    # => ["Elixir gate","PR references an active task"]   enforce_admins: true
