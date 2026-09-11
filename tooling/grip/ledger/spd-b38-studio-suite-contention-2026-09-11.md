# Studio suite intermittent red — measured, named, classified (2026-09-11)

Task: `spd-b38-studio-suite-intermittent-red`. Scope measured:
`mix test test/barkpark_web/studio/ test/barkpark_web/live/studio/` (2961 tests),
worktree cut from `origin/main` @ `300c79198`, `MIX_TEST_PARTITION=studio_r8_w5`
(a PRIVATE test DB — the shared `barkpark_test` residue reds are excluded by
construction), every run redirected to a FILE. No pipe, no `tail`. That was the
row's own finding about why the reviewer never caught a name.

## Verdict

**Host contention on OS process scheduling — NOT a sandbox-ownership race, and
NOT the row's leading hypothesis.** Every captured failure is a wall-clock
deadline on a real `fork`/`exec`'d subprocess (a `chmod +x /bin/sh` fake
`claude` binary or the `cloud-sandbox-runner` stub). Not one of the seven is a
`DBConnection` / sandbox-ownership error, and not one is
`{:managed_runtime_capacity, 3}`.

`DataCase.drain_owned_tasks/3` is therefore not implicated in either direction:
it walks `@task_supervisors` matching `$callers`, and there is no `Task` and no
DB error anywhere in the captured reds. The `$callers` question does not arise.

## The run table

| n | rc | seed | load before | load after |
|---|---|---|---|---|
| 1 | 0 | 531989 | 6.31 | 6.52 |
| 2 | **2** | **944888** | 6.52 | 6.16 |
| 3 | 0 | 293866 | 6.16 | 5.80 |
| 4 | 0 | 22724 | 5.80 | 5.89 |
| 5 | **2** | **418667** | 5.89 | 6.94 |
| replay | 0 | 944888 | 8.41 | 7.88 |
| replay | 0 | 418667 | 7.88 | 7.04 |
| b1–b14 | 0 | (14 seeds) | 5.61 → 11.25 | 6.61 → 10.61 |

2 reds in 5 runs, then **16 consecutive green** including two same-seed
full-scope replays and fourteen fresh seeds — at load averages up to **11.25**,
strictly higher than the 5.9–6.9 window in which both reds landed.

**Load average does not predict the red.** The reds clustered inside one
nine-minute window (03:39–03:47Z) and did not recur in the fifty minutes after
it, under heavier load. Whatever competes is a burst of *process-creation*
and I/O (the row names `design/check.mjs` + an authenticated Playwright run),
not steady CPU pressure. A future wave must not read "load was high" as "this
red was contention", nor "load was low" as "this red is real".

## The captured reds, verbatim

Run 2, seed 944888 — `test/barkpark_web/studio/claude_chat_test.exs:1048`:

```
  1) test spawned argv (end-to-end :binary override) a fresh session's real argv carries --session-id and never --resume (BarkparkWeb.Studio.ClaudeChatTest)
     test/barkpark_web/studio/claude_chat_test.exs:1048
     Expected truthy, got false
     code: assert Enum.chunk_every(argv, 2, 1) |> Enum.member?(["--session-id", uuid])
     stacktrace:
       test/barkpark_web/studio/claude_chat_test.exs:1057: (test)
```

Run 5, seed 418667 — six failures, all deadline-shaped:

```
  1) ... ClaudeChatCloudSessionTest, claude_chat_cloud_session_test.exs:170
     recorder for 5faaedf4-949e-4192-8231-3e0d1ccbceed never terminated
     code: assert_recorder_gone(sid)            # 200 tries x 10ms = 2s

  2) ... ClaudeChatCloudSessionTest, claude_chat_cloud_session_test.exs:142
     Assertion failed, no matching message after 2000ms
     code: assert_receive {:DOWN, ^ref, :process, ^session, :normal}

  3) ... ClaudeChatCloudSessionTest, claude_chat_cloud_session_test.exs:53
     recorder for a04b90a2-b9fa-4967-b8e1-896edcd1a50f never terminated

  4) ... ClaudeChatCloudSessionTest, claude_chat_cloud_session_test.exs:264
     recorder for 9ffcef36-ab9b-468b-8ebc-593a70ad0dc4 never terminated

  5) ... ClaudeChatTest, claude_chat_test.exs:1063
     capture file never written: /Volumes/SATECHI/dev-caches/tmp/claude_chat_argv_70996_77890
     code: argv = read_lines(argv_file)         # 400 tries x 20ms = 8s

  6) ... ClaudeChatTest, claude_chat_test.exs:1625
     Assertion failed, no matching message after 2000ms
     code: assert_receive {:claude_chat_event, %{"type" => "result"} = frame}
```

Five of those six say, in five different words, *a `/bin/sh` we spawned did not
finish inside two to eight seconds*. Number 5 is the bluntest: the fake binary's
only job is `printf "$@" > file`, and 8,000 ms of polling did not see a byte.

## Order-dependence: NO

Both red seeds were replayed three ways. All green:

* `mix test …/claude_chat_test.exs:1048 --seed 944888` (the single test) — 1 test, 0 failures
* `mix test …/claude_chat_test.exs --seed 944888` (the whole file) — 131 tests, 0 failures
* `mix test …/claude_chat_cloud_session_test.exs --seed 418667` — 4 tests, 0 failures
* full scope `--seed 944888` — 2961 tests, 0 failures
* full scope `--seed 418667` — 2961 tests, 0 failures

The seed carries the ordering and the ordering is not the cause. A seed in a
Studio-suite red report is therefore **not** a reproduction recipe, and a
reviewer should not read "I re-ran the seed and it passed" as "the red was
spurious" — the seed was never going to reproduce it either way.

## The one red that is NOT a deadline, and what was ruled out

Run 2 is the exception: `read_lines/1` returned a **non-empty** argv that
lacked the `["--session-id", uuid]` pair. It did not time out.

`wait_for_file/2` accepts the capture file as soon as it exists and is
non-empty, so the obvious suspect was a **partially flushed write**: the argv
payload is 1814 bytes with `--session-id <uuid>` as the LAST pair (ending at
byte 1813), and macOS `stdio` `BUFSIZ` is 1024 — so a first flush that stopped
at 1024 bytes would produce exactly this failure.

**That hypothesis is refuted by control.** `/bin/sh` on this box is
GNU bash 3.2.57; its `printf` builtin was run 18 times (8 of them with a
120,030-byte payload) against a busy-spinning reader recording the first
non-empty size observed. Every observation, 18/18, was the FULL final size.
No partial state was ever visible. The write is effectively atomic and the
1024-byte flush story is wrong.

The surviving hypothesis — untested, stated as a hypothesis — is a **foreign
writer**: `put_chat_config(binary: …)` installs the fake binary into GLOBAL
application env, so a Session that outlived its own test and respawns would
run the CURRENT test's fake binary and overwrite the CURRENT test's capture
file with somebody else's argv. That is state surviving its owner, the same
family the row is about, but it is NOT proven here.

To settle it the next time it fires, this branch arms the diagnostic rather
than guessing (`api/test/barkpark_web/studio/claude_chat_test.exs`):

* both argv assertions now carry a message printing the argv actually read;
* the fake binary appends its pid to `<capture_file>.writers` on every
  invocation, and the failure message reports how many invocations wrote the
  file. **More than one writer proves the foreign-spawn hypothesis; exactly
  one refutes it.**

Armed, the suite ran 14 more times (fresh seeds, load to 11.25) without
reproducing it. The diagnostic is a trap set, not a fix.

## What was deliberately NOT done

No deadline was raised. `assert_recorder_gone` (2s), the two `assert_receive`
calls (2s) and `wait_for_file` (8s) are all left as they are. `wait_for_file`
was already raised from 3s to 8s for this exact reason and it blew anyway;
raising a wall-clock ceiling a second time buys silence, not signal, and would
destroy the only instrument that currently distinguishes a contended box from a
real regression. If the Studio suite must be green on a loaded dev box, the
answer is to stop racing real subprocesses against wall-clock deadlines (a
deterministic spawn seam), not to move the clock.

## For the next reviewer meeting a Studio red

1. Was it `ClaudeChatTest` or `ClaudeChatCloudSessionTest`, and did the message
   mention a timeout, a "never terminated", or a "capture file never written"?
   If yes, it is this. It is not your slice.
2. Re-running the seed proves nothing here (see above). Re-run the scope a few
   times instead; 2-in-5 was the observed rate inside the bad window and 0-in-16
   outside it.
3. A `managed_runtime_capacity` red or a `DBConnection` owner-exited red is a
   DIFFERENT failure from the one measured here, and remains open — see the
   task row's CI evidence for `chat_live_test.exs`. Twenty-one full-scope runs
   on this branch (21 x 2961 = 62,181 test executions) produced neither.

Postgrex `disconnected: ... client/owner exited` lines appear ~13 times per run
in GREEN runs too. They are noise, not a verdict.
