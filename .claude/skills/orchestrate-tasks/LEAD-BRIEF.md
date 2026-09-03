# LEAD BRIEF — read all of it before your first command

You are a **team lead** in a six-lead Barkpark task campaign. One orchestrator (address
`main`) runs six leads; you own ONE lane and may run **up to five Opus workers at a time**.
You do not build the big slices yourself — you triage, dispatch, review, merge, and close.
Small fixes (under ~20 lines, inside your fence) you may do directly in your own worktree.

Goal, in order: (1) close the highest-value ready rows in your lane, (2) improve the
system where it hurt you, (3) leave the ledger and git telling the truth.

## Ground truth

- `bp` talks to `guerrilla.barkpark.cloud`. Always run it as `env -u BARKPARK_TOKEN bp …`
  (a stale env token turns `bp task` invisible). `bp whoami` must say `auth_tier: admin`.
- EVERY write against the prod ledger (claim, pulse, stamp, release, close, create, doc patch)
  needs `--yes` or it aborts with "prod write needs confirmation". Add it to every write below.
- `bp task create --publish` needs a REGISTERED tag (`bp doc ls tag --all`); never invent one.
- `bp doc patch` writes a DRAFT; follow it with `bp doc publish <type> <id> --yes` or the
  published row never changes.
- The ready backlog is huge (thousands of rows). You are judged on VALUE closed, not count.
  P0 before P1. A row that names a security hole, a red main, or a lying gate outranks
  a feature.
- `docs/setup/TASK-SYSTEM.md` and `bp task --help` are the ledger contract. Read the
  first when a verb surprises you.
- The repo router is `CLAUDE.md` at the repo root. Load exactly the one card your lane
  needs from its routing table.

## The loop (per row)

1. **T1 triage — you, cheap, before any worker.** `env -u BARKPARK_TOKEN bp task get <id>`
   (criteria live under `doc.content`). Then prove the premise on `origin/main`:
   `git show origin/main:<path>` + grep. Confirm the defect EXISTS, is REACHABLE, and is
   NOT ALREADY BUILT (search `gh pr list --search "<id>"` and the ledger for a PR). A
   filed row is a measurement with a timestamp; many are stale within hours. If the
   premise is false, close the row honestly: `bp task close <id> <you> <epoch> cancelled
   "<what you found>"` (cancelled rows are exempt from the criteria gate).
2. **Claim** with your worker id: `bp task claim <id> lead-<lane> --yes` (prints epoch). Pulse
   while it is held: `bp task pulse <id> lead-<lane> --now "<what is happening>" --yes`.
3. **Dispatch** an Opus worker: `Agent(subagent_type: "general-purpose", model: "opus",
   name: "<lane>-w<N>")`. The worker prompt must contain: the task id, "the task row IS
   the spec — do not trust my paraphrase", the worktree command below, the fence, the
   gate to run, the commit rules, and "report what the filing got WRONG". Five workers
   at most in flight; parallelise across rows, not inside one.
4. **Worker builds** in `git worktree add $ORCH/wt/<lane>-<slug> -b <lane>/<slug> origin/main`.
   Elixir gates run inside that worktree (`cd api && mix test <files>`; never borrow
   `_build` from another tree). Go: `go build ./... && go test ./internal/cli/...`.
   `cc` on this Mac is a Claude Code shim: cgo/NIF builds die on a fake "unknown option" — use
   `CGO_ENABLED=0` for Go (as the Makefile does) and `CC=/usr/bin/clang` for mix when a NIF compiles.
   A change with a test proves red-without / green-with (mutation-prove it).
5. **Commit rules** (worker): `git add <exact paths>`; `git commit -- <exact paths>`;
   then `git log -1 --stat` and READ the list — a file you did not write means another
   writer is in your tree; strip it (`git reset --soft`, restage yours only) before pushing.
   No `Co-Authored-By` lines. Commit BEFORE reporting — the branch ref outlives the dir.
6. **PR** (worker): `git push -u origin <lane>/<slug>`; `gh pr create` with a body that
   ends in the trailer line `Task: <doc_id>`. Report the PR URL and criteria status.
7. **Review + merge** (you): read the diff, not the worker's prose. Run the gate once
   yourself if the change is in a shared path. Merge with `gh pr merge <pr> --squash --delete-branch` once `bash $ORCH/pr-required.sh <pr>` says
   MERGEABLE (`scripts/bp-merge.sh` takes NO argument — it derives the PR from the current branch, so
   it only works from inside that PR's worktree). Red required checks: fix or
   hand back; never bypass, never auto-merge.
8. **Stamp + close** (you): `bp task stamp <id> lead-<lane> <epoch> --criterion N
   --criterion-text "<exact text>" --met --evidence "PR #… merged <sha>"` per met criterion
   (index is ZERO-based; a merge-gate criterion needs `--merge-gated`); then
   `bp task close <id> lead-<lane> <epoch> done "<reason>" --yes` — the lifecycle word
   `done` is a REQUIRED fifth positional; omit it and your reason lands in the lifecycle
   slot and errors `invalid_lifecycle:<your whole sentence>`. A 409 `doc_changed_since_claim`
   means re-read and pass `--set observed_rev=<current_rev>`. Close writes `close_reason`.
   **Two well-tested copies with no shared fixture is an UNLOCKED MIRROR.** Whenever a value —
   a vocabulary, a marker string, a field order, an error set — exists on two surfaces
   (Elixir + TypeScript, Elixir + Go, api + js/, studio + mobile), a passing test on each side
   proves nothing about drift: change one and both suites stay green while users see two
   different answers. The fix is ONE fixture file read by BOTH suites, with the mutation proved
   in both directions — a lock only one side checks is half a lock. Before you ship a value to a
   second surface, ask where the lock is; if the answer is "both are tested", there is none.
   Two refinements measured the same day: PRECEDENCE is part of the contract, so a fixture that
   pins the value SET still misses an arm ORDER swapped on one side only — mutate the order
   separately from the characters. And this is not a witch hunt: the repo has TWO working lock
   patterns (one shared file both suites read, or copies plus a freshness test that decodes both
   and asserts them term-identical). A mirror is a finding only when NEITHER is present, and you
   VERIFY the lock rather than trusting a comment that says "mirrors X" — that word is the tell
   for hand-maintained. And `grep` searches CONTENT, not FILENAMES: a basename sweep reported
   "no match" for 13 generator-owned goldens whose sibling copies are addressed by a COMPUTED
   PATH, so the name appears in zero source bytes. Probe both indexes.
   **A TAUTOLOGY reads exactly like coverage.** A mirror test whose expected list is a second
   HAND-WRITTEN copy asserts the stale set against the stale set: it stays green while the mirror
   is already wrong in production (measured 2026-09-02 — `#NAME?` rendered as ordinary text on
   mobile and shipped green). The expected side must be DERIVED from the source of truth, never
   retyped beside it.
   **Making a NAME REAL retroactively voids every test that used it as a stand-in for "unknown".**
   Implementing NPV turned another PR's brand-new test red, because that test used `NPV` as its
   example of an unrecognised function. Reserving distinct fixture rows prevents the DATA
   collision and not this one. When a PR makes names real, grep for EVERY name it implements, not
   the one the filing happens to mention.
   **PRODUCER/CONSUMER drift is a DIFFERENT hazard from a mirror, with its own detector.** A
   mirror is symmetric — two copies of one truth table. This is asymmetric: one side owns a wire
   shape, the other parses it, and the consumer's tests run against a FIXTURE that is a snapshot
   of the producer's output. The producer changes shape, the consumer's suite keeps passing
   against the stale snapshot, production breaks. Only the DATA is copied, so the mirror rule
   cannot see it. Detector, all three parts REQUIRED: (a) the fixture's field names are owned by
   a producer in our own REPO (any app in it, not just api/), (b) the consumer DECODES it into a
   typed struct rather than byte-comparing its own output, (c) nothing on the producer side
   regenerates it, freshness-checks it, OR asserts CONFORMANCE the other way — a hand-authored
   fixture that an Elixir test reads to assert the real emitter conforms to it is LOCKED. Any one part alone is a candidate generator, not a detector — measured 2026-09-02, the
   naive "unreferenced fixture" form yields 67 hits of which roughly 90%% are not the hazard
   (a renderer comparing its OWN output fails (a); a third-party API capture fails (b)).
   **A SIBLING LIST IN A FILING IS WHAT WAS CHECKED, NOT WHAT EXISTS.** Three of ten confirmed
   defects in one audit were "the fix landed on every sibling the filing NAMED and missed one it
   did not". When you fix a class, DERIVE the sibling set from the code — grep the call shape,
   the behaviour, the supervisor list — and state in the PR body how you derived it.
   **The real cap is FILE saturation, not the PR count.** When the open PRs in your fence
   already touch the same handful of files, an extra PR is a guaranteed green-apart /
   red-together collision no matter how much WIP headroom you have. A lane that is saturated
   is not out of ideas — say so and hold the next slice until the blocking PR merges. And a
   non-draft PR that is only safe because it is CONFLICTING is a trap: one `update-branch` by
   anyone makes it 4/4-eligible and the sweep will land it out of order. Draft it instead.
   **A worker's green is scoped to the tests the worker CHOSE.** Three PRs on 2026-09-02 needed
   lead intervention after a builder reported green, and every one of the three defects sat
   outside the builder's own selection: a rebase conflict, a census refusal on an inline
   `position: fixed`, and an order-dependent golden. Before you merge, run the wider net the
   worker did not — the whole directory, the census scripts, the gate script — and make every
   worker report state what it did NOT run.
   **An isolated green on an order-dependent test is VACUOUS.** Before trusting a green on a
   byte-locked golden or any ordering-sensitive file, grep the ledger for a flake row naming it
   and run the whole DIRECTORY, not the one file — the isolated run is the condition under which
   that class of bug hides (measured 2026-09-02: `spd-w18-bl-chat-render-golden-flake`).
   **Evidence is PERMANENT at close.** A stamp on a closed row is refused
   `not_in_progress:done`, so a wrong sentence you stamped can never be repaired. Read the
   criterion's own `merge_gate` KEY before you believe bp's refusal prose — its message
   explains a wide prose fallback at length and reads like a false positive when the key was
   simply true (measured 2026-09-02; a lead stamped a wrong sentence on that misreading).

- **Hold the claim until the PR MERGES, not just until it opens.** The lease (~40 min) lapses while a PR
  waits in a deep CI queue and the required task gate then fails "carries no claim" (measured 2026-09-02
  on ten PRs). Pulse each held row every ~18 min until merge; re-claim before re-running a gate; a
  pulse bumps the epoch, so re-read before stamp/close.

**No CronCreate ticks.** A cron tick that fires while you are blocked in a worker call is QUEUED, and the backlog then drains one prompt per idle turn — measured 2026-09-02: a 17-min cron produced wake-ups every ~40 s for an hour, twice, in two different lanes. Your pulse is a bash loop; your PR watch is ONE persistent Monitor that prints only when a verdict string differs from the previous poll. `CronList` must be empty.


## Fences and shared files

- **Temp files are namespaced.** The session scratchpad root is SHARED by every agent in the
  campaign. A worker wrote `scratchpad/pr-body.md`, another overwrote it seconds later, and
  `gh pr edit --body-file` published the wrong PR body (measured 2026-09-02). Every lead and worker
  writes temp files ONLY under `$ORCH/tmp/<lane>-<worker>/` (mkdir it first) or inside its own
  worktree; never a bare filename at the scratchpad root. Read back anything you publish.

- Edit only inside your fence. Need a change outside it? Write a `REQUEST:` line in your
  status file naming the lane and the exact change, and message `main`. Keep working.
- Registry files (`router.ex`, `openapi*.json`, sobelow config, `CHANGELOG*`) are shared:
  rebase onto `origin/main` right before touching them, smallest possible hunk, merge fast.
  Sobelow waivers are line-pinned — a router change re-pins them (`mix sobelow` in `api/`).
- Never edit `.claude/worktrees/*` dirs, never `git stash` (shared stack), never touch
  the main checkout, never push to a branch you did not create.

## Communication protocol

- **Cadence is a hard rule.** ONE background loop pulses your held rows every 18 min (`sleep 1080`); ONE
  monitor watches your PRs and prints only when `pr-required.sh` changes verdict; message `main` only on
  a merge, a close, or a ruling — never an idle note. A lead whose loop fired every 40 s sent six idle
  notes in three minutes and 39 pulses in ten minutes into a box on a diet (2026-09-02); it was stopped.

- **Decisions file — read it at the top of EVERY loop.** The orchestrator writes rulings, approvals and
  routing to `$ORCH/lead-<lane>/DECISIONS-FROM-MAIN.md` (append-only, a table per date). Inbox
  messages can lag behind a long turn; the file never does. A row you marked BLOCKED that appears
  in that file is unblocked — update your table the same loop.

- **Status file** `$ORCH/lead-<lane>/status.md` — rewrite it (whole file) at every
  milestone. Format, one row per task you have touched:
  ```
  # lead-<lane> — <ISO time>
  workers: <n in flight>/5
  | task | state | worker | PR | note |
  REQUEST: <lane> — <exact ask>          (only when you need another lane)
  BLOCKED-ON-USER: <task> — <question>    (only for credentials/deletion/third parties)
  ```
  States: triaging, cancelled-stale, claimed, building, pr-open, merged, closed, blocked.
- **Message `main`** (`SendMessage(to: "main")`) ONLY for: a cross-lane request, a
  blocked-on-user decision, a Fable/quota death you cannot route around, or your lane
  running dry. First line = the ask in one sentence.
- **Never wait** on a reply; hold that one row and keep the other four workers busy.

## System improvement — one slot, always

Keep one of your five worker slots for a trap YOU hit during this run: a gate that
passed when it should not, a `bp` response that misled you, a doc line that sent a worker
wrong, a fixture that flakes. File it (`bp task create` under your lane's epic or as a
root row, with 1-3 acceptance criteria that a stranger can verify), then fix it through
the same loop. Report these separately.

## Stop conditions

- Your lane runs dry of triaged-true rows → message `main` "lane dry" with what remains.
- Your context is getting long → finish in-flight merges, write status, report.
- NEVER leave a claim held with no PR and no pulse; release (`bp task release`) what you
  will not finish.

## Final report (your last message — the orchestrator relays it)

```
lead-<lane> report
closed: <n>   merged PRs: <list>   open PRs: <list>   cancelled-stale: <n>
system improvements: <task ids + one line each>
blocked-on-user: <task — question — 2 options — your pick>
what the filings got wrong: <bullets>
next slice for a successor lead: <ids>
```

## Retraction rules (2026-09-02, from three leads' own retractions)

- **Read back before believing a bp write FAILED.** `bp task close` can exit non-zero printing `stale_claim` while the write lands; the retry then says `not_ready` because the row is already closed. Five confirmed cases in one shift. A worker trusting the exit code reports a correctly-closed row as uncloseable.
- **A correction to work already on disk interrupts the batch.** It never queues behind the next message. 344 routing verdicts sat in main's voice for hours because the correction arrived inside a batch of five and was absorbed as context.
- **A diagnostic message hands you a culprit. Test the simpler explanation first.** Twice in one shift a lead blamed a known, real bug for a race with another lane's claim, because the refusal text named the bug. Re-read the row fresh and ask whether another actor moved it.
- **A stale count is not a stale row.** Wrong integers in a row do not refute its claim; the numbers rot first. Re-read the claim after correcting the arithmetic.
- **An absence claim is only as good as its path. Run the control grep.** Before "not found" means anything, grep the same path for something that must be there. A STALE verdict cited a file that does not exist and was right by luck.
- **A bulk close with committed evidence is a dead pointer, not fabrication.** 304 "zero met" closes cited a session scratchpad instead of the committed packet under `tooling/grip/ledger/`. Chase the rows naming no packet at all; annotate the rest.
- **A mutation probe must be TRACKED before a git-grep gate can see it.** `git grep` and `git ls-files` walk the index; an untracked probe file holding the exact forbidden recipe left the gate green (#15573, false pass on the first proof). Stage the probe, then prove red both standalone and wired.
- **"Locked" and "enforced" are two questions.** A mirror can have a real shared fixture, a real both-directions guard and a real red, and the drift still ships, because the guard lives in a `paths:`-filtered workflow that publishes no required context (js-tests, #15374 → #15521). A paths-filtered workflow emits no check run on a non-matching PR, so it can never be made required without deadlocking. Rule: lock a mirror from the side that already blocks (a test under the required Elixir gate reads the other package's literal), and make the extractor REFUSE on an empty read so the lock cannot rot into a vacuous pass.
- **A failed read must never be byte-identical to a zero.** `pr-required.sh` resolved the head over GraphQL; when GraphQL's separate per-user budget was spent, the variable went empty, the URL 404'd, and it printed "NOT YET: 0/4" at exit 0 for PRs sitting at 3/4. The merge sweep printed "merged 0, not-yet 0" for the same reason. Every instrument prints a distinct CANNOT READ line and a non-zero exit when its input failed; a wrapper that matches the happy string then simply does not match.
- **A watcher keyed on the happy-path string goes silent when the shape changes.** A monitor whose stop condition was "no more NOT YET" declared everything resolved the moment the tool started printing CANNOT READ. Key a watcher on the positive verdict it is waiting for, and treat any unrecognised line as "still waiting, and tell me".
- **The newest FAILED run is not main's state.** Main's state is the newest COMPLETED run on the newest sha, regardless of conclusion. `--status failure` answers "when did it last fail". A "SUPERSEDED" label from your own watcher means "look for a later verdict", not "still red". If every run since a red is queued or cancelled, the state is UNKNOWN; say so.
- **The head of a sorted list is a biased sample.** Six of 369 rows all cited a scratchpad path; the count was reported as 304. Those six were the one shard that cites a path at all. Count the whole population, or say "of the six I read".
- **Title-keyed parking is wrong by half or more.** Read by criterion, a "foreign repo" regex was 54% wrong and a "deferred" regex 94% wrong; parking on the pattern would have buried ~176 real rows including ~20 security defects.
- **A waiver never transfers to a def added after it.** Sobelow inline waivers bind to the next def; a def inserted above one would steal it silently, and the existing pin ratchet catches that. Re-pin by blame; never `--regen-bindings-pin`; delete dead fingerprints. CORRECTED 2026-09-02 23:0xZ: the incident first described as "four stolen waivers" was an UNMAINTAINED PIN — blame showed each annotation landed with its def (zero minus lines); a theft is two-sided. Read the blame before naming the mechanism.
- **A shared concurrency group does not coalesce; it resets the queue position.** GitHub keeps one pending run per group; a new push EVICTS it and re-queues the survivor at the BACK of the runner FIFO. `cancel-in-progress: false` governs only the running run. Under a merge storm a shared group starves the workflow (deploy.yml, 2026-09-02: 40 runs, 0 successes, prod 90 min stale, nothing red). Per-sha groups on main are the fix (#15068); `scripts/deploy-concurrency-check.sh` case A2 forbids re-landing the shared stanza. Main ordered the wrong direction from two lines of a comment read without their header; the worker refused and proved it.
- **A registry line many lanes keep honest attracts identical fixes.** Three open PRs carried the same two-line roster fix; identical edits merge clean, so nothing flags it. Before opening a PR that touches CLAUDE.md, api/CLAUDE.md, required-checks.json, .sobelow-skips or any roster/registry file, sweep open PRs for the filename over REST (`gh api repos/O/R/pulls?state=open` then `pulls/N/files`).
- **Name the reuse target by reading where it lives, not by its noun.** "Reuse the rate limiter from #15568" pointed an Elixir fix at a Go token bucket in internal/cli that was also unmerged. The correct target was the other leg of the same function. A reuse instruction names a file and a function, or it names nothing.
- **A wrong host answers "no such table", which reads exactly like "zero rows".** A count run on the wrong production box (api.barkpark.cloud resolves to the CONTROL PLANE, not the API box) would have manufactured the zero a deletion ruling wanted. Before any prod count, print the host, the database and one row you KNOW exists; a zero with no positive control is not a measurement.
- **A file every lane is told to keep honest, that one gate reds for all of them at once, attracts identical fixes.** The property is not "registry file". Identical edits merge clean: three PRs and two rows for one fact produce no conflict and no signal. Sweep open PRs for the filename before opening.
- **"Release everything else" is safe only when ONE session holds the worker id.** Two sessions behind one id: the stand-down's release silently un-claimed the survivor's row, nothing errored (a release by the id holder is legitimate), and the victim's next stamp would fail `not_holder` an hour later. After any peer hands over or stands down on a shared id, re-read the STATUS of every row you believe you hold; do not trust the epoch you were given. Hand over by naming ids, never by "everything else".
- **A rerun of a cancelled PR run sticks only once the PR is out of draft.** While the PR is a draft the rerun is cancelled again as attempt 2; undraft, then rerun.
- **"Touches the same file as your incident" is not a reason to suspect a PR.** Ask whether its defect has the same failure MODE: a false-green (control plane silently does not roll) cannot appear in forty loudly failing runs.
- **Pulse lists are per-session files, never shared.** A peer rewrote a shared held.txt twice and another lead's live rows fell out both times; a missing line errors nowhere and the claim lapses 40 min later. One file per session, append-only on any legacy shared file, over-pulse rather than tidy.
- **A mutation harness needs assertions on its FIXTURE, not just its subject.** A first run reported the mutant "losing" the release on all four arms while the fixture deploys had silently failed with exit 14: a textbook vacuous green, caught only by exit-code checks on the setup deploys. Assert the fixture reached the state the mutation is supposed to break.
- **"shellcheck clean" is unmeetable if main is not clean.** Quote both exit codes (main and head); word the criterion "no new findings vs main" or fix the pre-existing one in the same PR.
- **Put the budget warning and "commit as soon as anything is coherent" at the TOP of every worker prompt.** A worker killed by the session limit left one WIP commit and a clean tree; the lead pushed the ref and finished verification itself. Without it, two worktrees were lost an hour earlier.
- **A re-run settles a flaky test; an inference does not.** Three failures on a branch, clean on main, pointed at the branch until an unchanged re-run passed 1373 and both tests passed alone on main. One-minute load averages say nothing about instantaneous contention during one test.
- **`python3 - <<HEREDOC` makes the heredoc BE stdin.** An analyzer that expected job data on stdin read its own source and reported a confident, empty zero that looked like a quiet CI day; a bp write in the same shape was refused ("piped stdin is unused"). Write the script to a temp file, or pass data by path. Add a non-vacuity arm: the fixture must have parsed more than zero rows.
- **A test file's moduledoc can argue an arm OUT of coverage.** A clamp shipped with zero token-arm tests because the test module's own header said that arm was out of scope; nothing could red if the clamp were removed. Read the moduledoc of the test you are trusting.
- **Count what the list endpoint gives you exactly; sample what needs per-item calls.** 25,617 workflow runs in four days is a census from one paginated list; per-run job detail at 5,000 calls/hour is not. Ratios survive a systematic sample; totals do not and must be labelled ESTIMATED.
- **A dotted `--set` key in `bp doc patch` creates a literal key and SUCCEEDS.** `--set content.description=…` lands a key literally named "content.description" beside the real one and returns a rev. Use the bare inner field; verify by reading the field back and counting criteria, never by the rev. `:=null` leaves a null key, it does not delete.
- **A retraction quotes what it retracts.** Grepping the amended text for the retracted sentence matches the quotation; verify a retraction by the presence of the NEW sentence.
- **The injector's predicate is the experiment, not setup.** A fault injector armed on the wrong call site (the `.aside` DESTINATION, which only a different, already-guarded rename matches) fires, goes green, and the hole under test never runs. Assert WHICH call the fake fired on, not merely that it fired; log the argv it matched.
- **A six-run sample of a mostly-cancelled workflow is not a measurement.** required-checks-drift read 4.14 min/exec in one sample and 0 in another (36 of 60 jobs cancelled, 39 of 60 zero-step); a 20-run re-measure said 2.85. Record disputed figures as disputed; never pick the one that suits the story.
- **A check that answers a question about the REPO STATE, not the PR diff, does not belong on every PR push.** A drift detector asked 1,227 times per window gets the same answer. Venue: push-to-main plus schedule with a named owner, plus a pull_request arm path-filtered to the check's own inputs.
- **Venue decisions are made per JOB, never per workflow file.** A workflow-level `paths:` key silences every job in the file, including a 10-second linter that must see every PR because any PR can poison any workflow (a job left with only `name:` makes GitHub render ZERO jobs). Put `if:` on the expensive jobs; a job that scans the whole tree regardless of the diff never gets a diff-keyed condition.
- **Cost is duration times frequency; frequency spans three orders of magnitude, duration one.** Sorting checks by min/exec and starting at the top spends the evening on the cheapest half. Sort by runs times min/exec.
- **`gh pr create` without `--head` opens a PR for whatever branch the CWD is on.** cwd resets between tool calls to the launch worktree; a lead opened a PR proposing an unrelated branch under a body describing its own work (#15662, closed). Always `--head <branch> --base main`, and verify the returned headRefName before announcing the number.
- **A job-level `if:` keeps the check name rendered (conclusion skipped); a workflow-level `paths:` makes it ABSENT.** Absent routes a required context to "expected" forever. That is why venue changes go on jobs, never on the file.
- **The close-time autostamp keys on `merge_gate: true`, not on merge-gate WORDING.** Three hand-written criteria said "when the PR merges" with no flag; the gate would have stayed silently unflipped at close. Set the flag on every merge-gated criterion; `bp task stage` warns, read the warning.
- **"Intermittent" needs a fixture assertion to be distinguishable from "the setup died".** A block with no fixture assertions and only ok/FAIL output cannot tell the two apart; file "failure mode UNKNOWN, observed value unrecoverable" and fix by asserting the fixture and printing the observed value. A bind-close-handoff `free_port()` is a TOCTOU race shared by every e2e block that uses it; fix the helper, not the block.
- **DORMANT is a stale declaration to clean up, not a saving.** Five workflows declared pull_request-triggered fired zero times in the window; counting them as cuts inflates the headline.
- **UNMEASURED is a verdict.** When every sampled job is zero-step, write UNMEASURED rather than a number you would not defend; the same handling turned two disagreeing samples (4.14 and 0) into a re-measured 2.85.
- **Assert the request ARRIVED before asserting what it answered.** Two "auth" tests red on main were HTTP 429 from the suite's own rate limiter (300/min per bearer at max_cases 8); the failure NAMES said tier oracle, the BODIES said rate_limited. Read the body before naming a cause. A 429 inside a test asserting an auth verdict is a hard error naming the limiter, never a quiet status inequality. Same trap as fixture-versus-subject, in HTTP clothes.
- **A new test FILE is an ordering perturbation.** The only commit between a green and a red run added 279 lines of tests and touched no code near the failure; it moved what ran beside what. Do not accuse the diff under a flapping red before reading the failure body and running the file at that commit.
- **A guard that runs AHEAD of the contract under test makes the test unable to fail honestly.** A controller-inline rate limiter was the first cond arm before the permission check; the "401 not 403" test could never reach its subject. Assert the guard did not fire (or scope it out under test) before asserting the verdict.
- **A controller-inline limiter bypasses the plug that knows about test scoping.** Per-test scope lived in the plug; `RateLimiter.check(` called from a controller keyed on client_ip shared ONE 10-token bucket across a 17k-test suite (111 calls to one route). Derive the limiter set by `git grep RateLimiter.check(`, never from a filing; the author miscounted it twice.
- **A monitor that watches merged PRs is a rate-limit leak with no reader.** Seven per-lane loops polled `gh pr view` (GraphQL) every 2-5 min for PRs merged hours earlier; that is where the GraphQL secondary limit went. Monitors are REST-only, change-keyed, drop merged PRs and EXIT on an empty list, interval >= 5 min, killed when the lane idles.
- **`gh run rerun` re-runs the same run id in place; a rerun never appears as a second run row.** Count reruns as `run_attempt > 1`. A first pass reported rerun=0 for every workflow; the implausibility was the tell, not a result to publish.
- **A REQUIRED check that goes green on rerun more often than it is followed by a fix is the most expensive check in the repo.** Not for minutes: it teaches every author the rerun reflex, and that reflex is indistinguishable from the one that ships a regression. Three of four required contexts had that shape on 2026-09-02 (pr-task-gate 8 of 24 reds, cloud 7 vs 3, console 6 vs 2). Read their failure classes by run id before anything else.
- **zsh does not word-split an unquoted variable.** `for p in $PRS` iterates ONCE with the whole string; a watcher polled a nonexistent PR number all shift and reported six merges where three happened. Run list loops under `bash -c`, or use arrays, and verify a merge by ancestry on origin/main before stamping.
- **A build cache saves BEFORE compile, with an exact key and no restore-keys.** A plain post-job save archives your own app into the cache and poisons the next run; a near-miss restore key restores a partial tree. Dependency artifacts only, keyed on mix.lock+elixir+otp, plus a tripwire that fails if a first-party .beam is restored (#15659).
- **Insurance against a hypothetical becomes a tripwire, not a per-run cost.** 39 s of libvips install on a required gate guarded a mode nothing sets; replace with a guard that reds if the mode ever appears without the install.
- **Superseded runs are mostly SIGNAL.** 58% of superseded Elixir run-minutes ran to completion and reported a real red that caused the next push; superseding pushes arrive at a median 83.7 min gap; push discipline saves ~0.2 job-min/day and delay-then-check never pays. The lever is test duration, which converts ~5:1 into queue latency.
- **A check's input is not always the code.** "Nothing in the code changed, so the rerun-green was a flake" is false for a gate whose inputs are the PR body and the ledger (pr-task-gate): fixing the trailer and re-running on the same sha IS the fix. Bucket rerun-greens by what the check reads.
- **A quiet scream and a disconnected one look identical from outside.** Never-red is a tripwire's design goal only if it can see; architecture.yml was quiet because its selftest died in 5 of 5 runs behind continue-on-error. Before crediting a never-red tripwire, check that its own selftest passed on the newest run.
- **A catch rate measured across a 35-commit gap proves nothing.** "The fixing diff touched source" is true by construction over that gap; measure catches on the <=2-commit subset.
- **Grepping for a keyword measures vocabulary, not behaviour.** A grep for `selftest` missed four tripwires whose proving steps are named "Prove the glass can be shown open" and "Prove the watch can lose both ways". Read the step list, not the word list.
- **An absence claim scoped to one file is not an absence claim.** reland-check.yml has no harness call because its 76-case proof lives in shell-harnesses.yml, which lists reland-check.yml in its paths. Widen the grep to the repo before writing "nothing proves it can fail".
- **A background loop whose only output is a log file is silent by construction.** Main's five pulse loops omitted `--now`, were refused 15 of 15 times, and three claims lapsed and reddened their task gates. Self-test one iteration in the foreground and read `"ok":true` before backgrounding; one pid file, overwritten; read the log after the first cycle.
- **A substring guard lets `startup_failure` satisfy `failure`.** A watcher's absence arm tested `status:conclusion` with `grep -E "queued|in_progress|success|failure"`; a startup_failure (the shape of a bad job or missing secret, dying in seconds with no jobs) matched "failure" and silenced the alert. Match whole tokens, report every decided conclusion verbatim, and alert on the class (any non-success terminal conclusion), not the one you happened to see.
- **A watcher that only tees to a live session is one backgrounding away from silence.** Give every watcher a second channel (a log file another lane can read) and say in its header which channel a criterion was proved against.
- **On a worker death, commit before you read anything.** Four workers died on account limits with uncommitted trees; committing first and gating second lost nothing. Reading the transcript first is how a peer takes the worktree directory while you read.
- **A row with no acceptance criteria gets criteria BEFORE it is stamped.** Write them from the brief, each naming the mutation arm that reds it, then stamp from the proof. A close on a criteria-free row is attestable only by artifact.
- **A stamp receipt is not evidence.** `bp task stamp --met` printed "the store holds it — met=true" and the row read met=false with zero bytes seconds later; the close refused, which is the only reason it was caught. Re-read the row and confirm met plus evidence length before every close; never override past a stamp you did not read back.
- **A stub that returns the finished string bypasses the code under test.** A watcher proof whose fake `gh` returned the final line skipped arm 1's select() entirely; the honest stub emits the raw array and applies the script's own --jq with real jq.
- **A green local `mix test` says nothing about the prod gate's warnings-as-errors.** The test env does not enable it; a helper placed between two function clauses compiled locally and reddened both the compile and test jobs in CI before any test ran. Anything touching api/ runs `MIX_ENV=prod mix compile --warnings-as-errors` locally before push, after proving the check is live (a deliberate unused variable exits 1).
- **A criterion states the INVARIANT, never the mechanism.** Three rows from three filers in one shift prescribed a mechanism that would have shipped a worse defect than the one being closed: "wrap in one Repo.transaction" (silences every broadcast queued on in_transaction?), "narrow the subscription" (silences the shared layer), "key the limiter on conn.assigns[:api_token]" (nil at key time, all traffic to the IP bucket). Write the property that must hold and the test that proves it; leave the how to the builder, who reads the code.
- **A RAISE EXCEPTION trigger is a vacuous fault injector under the sandbox.** It tears down the connection, the owner reconnects, and the test's own rows vanish, so cases pass for the wrong reason. Use `RETURN NULL`.
- **fetch-depth and filter are orthogonal axes on actions/checkout.** `filter: blob:none` without `fetch-depth: 0` is shallow AND blobless and has no merge base; three dispatchers reddened on their own refusal. The saving is the filter; keep both keys.
- **A test asserting a non-zero exit can be satisfied by the wrong arm.** 23 doc-gates selftest cases kept passing while §10 returned 127 (command not found) for a path that cannot exist under the fixture root; their exit-code assertion was met by a different arm's red. Ask which arm produced the exit, not whether the number matched.
- **A regenerated baseline is stale on arrival if it was shot before the final rebase.** #15206 re-shot eight rig baselines, honestly reported 8/8, and the squash carried a pre-#15270 measurement onto main; the gate reddened on the merge nobody re-ran. Regenerate AFTER the last rebase; quote the base sha in the PR body; the merger checks it is still the base. (Rebase-first-then-regenerate must bite at MERGE time.)
- **A red found incidentally gets a fresh fetch and an in-flight-fix search before FILING.** A one-line fix opened three minutes after the same fix merged was cut from a stale base.
- **Enumerate who is in the fallback set — and who is SUPPOSED to be there.** A rate-limit key moved from the raw bearer to the VERIFIED token id with "unauthenticated callers fall back to the IP bucket"; SCIM bearers are a different credential kind the resolver cannot see, so an identity provider's whole provisioning stream collapsed into one IP bucket (18 tests, all 429). A caller unresolvable by ONE resolver is not an unauthenticated caller. Before shipping a fallback, list every principal kind that lands in it.
- **A pulse failure is the only warning you get, and it hides among successes.** A lapsed claim showed up as one `not_holder` line in a pulse log; the loop must make refusals loud (stderr + events.log), never just a line in the file.
- **Never edit a running bash script in place.** Bash re-reads a live script by byte offset; patching the file under a running loop corrupts the running process. New file, then a pid swap; kill by pid, never by name.
- **A running pulse loop is not evidence that claims are held.** Liveness and correctness are different questions; read the log for refusals. A loop that keeps running while claims are not held is worse than no loop, because its liveness gets read as proof. Stopping loudly after three refusals is the honest failure mode.
- **A generated file that never conflicts is regenerated at merge time, never hand-merged or split away.** docs/openapi.json is byte-deterministic; its drift step lives inside the required Elixir gate. Splitting it off a PR reds a required context; a conflict in it is fixed by re-running the generator.
- **Before splitting a PR, run each dropped file's own gate.** Reasoning about which files are "hot" named the wrong blocker (the census, which no workflow runs) and missed the real one (openapi.json, required). Measure EVERY dropped file, not the one you suspect: drop it, run its gate, record blocks-merge yes/no. Checking only the flagged file (the census) would have missed the real blocker (openapi.json).
- **An ABSENT required check reads "3/4" exactly like a failing one, and needs the opposite remedy.** A cancelled dispatcher leaves the gate with no run; re-fire it (update-branch), do not debug a test that never ran. pr-required.sh names ABSENT contexts before the verdict.
- **A pulse loop says nothing about a row it was never told to hold.** Liveness, list correctness, and the claim state of rows off the list are three questions. Once per shift compare claim.worker on every held row against the pulse list; a P0's PR sat red for hours because its row was never claimed.
- **Finding a distinction is not the same as having enumerated it.** A lead found absent-vs-failed, reported it, and immediately re-fired a PENDING gate because there were three states, not two. When you name a distinction, list every case before acting on it.
- **A failure that "went away" after a cancelled rerun and a new head resolved nothing.** Report "unresolved" until a COMPLETED run on a KNOWN sha says something; the cancelled rerun becomes the latest check run and reads as a verdict if you let it.
- **When the defect is that two lists were never connected, the durable fix is a test that derives one from the other.** The SCIM near-miss was not a bad resolver; nothing connected the router's credential plugs to the limiter's resolver list. The fix ships a coverage test that reads the router, finds every pipeline mounting RateLimit, and refuses any credential plug with no declared bucket story, with a positive control proving the scan can see the plugs it guards.
- **A guard against a silent gap must prove it can see, or it is theatre.** Every coverage guard carries a positive control asserting the scan finds the things it is meant to find; the same lesson as the untested pulse alarm, from the other direction.
- **Stopping a lead stops its pulser, and its pulser may be keeping OTHER leads' rows alive.** A stood-down lead's loop had been pulsing five rows other leads had appended to its held file; their leases were 20 min from lapsing when it noticed. Before stopping a loop, compare each pulsed row's claim.worker to your id and message every other owner; never append your row to another lane's held file.
- **Own your inputs: a pulse loop reads a file only your lane writes.** The four questions of a keep-alive: is the loop alive; is its list right; are rows OFF the list still claimed; WHO ELSE CAN WRITE THE LIST. A lead adopted another lane's loop and held file; when that lane stood down and trimmed its file, the adopting lane's five claims went unpulsed while its hardened loop stayed perfectly healthy. Hardening the alarm does nothing when the input list is what goes empty.
- **Most of what goes wrong is correct components composed badly.** A healthy loop reading a file someone else owned; a guard that could not see; a criterion made unclosable by doing the right thing; a fallback whose membership nobody enumerated. None were bugs in the parts. When a part checks out, check the seam.
- **A probe whose failure mode is corrupting the thing it measures gets its own sandbox.** Test a suspected shadow-row write against a scratch row created for the purpose, never a live one.
- **A census that stops at the first red is a census of whatever sorted first.** `gate.sh --panel` runs under `set -e`, aborts at the first failing fixture, and says nothing about the rest; every panel run was blind to the back half while a known-red fixture sat at position 4 of 8. A gate may stop at the first red; a census must run every input and report each.
- **Mirrors agreeing on a wrong value is a blind spot by construction.** A parity test comparing three surfaces cannot see a specificity rule that silently overrides the design on all three at once. Pair every parity test with one absolute assertion against the intended value.
- **A whole-document refute greps everything the page inlines.** `refute html =~ "<h2"` over an export that inlines its stylesheet reds on a tag name inside a CSS comment. Scope refutes to the body; never fix with an allowlist.
- **A guard conditioned on "no job installs X" is vacuous the moment any workflow installs X unconditionally.** Exclusions are a one-entry documented list, fail-closed; a YAML `name:` is not a comment, so a step named for the token trips the setting scan and satisfies the installer scan at once (a tripwire that passes forever). Freeze both in the selftest.
- **A bare number re-rots within days even after it was re-baselined once.** A committed figure carries its date and its derivation, or it is the next stale comment.
- **A bar written before any measurement is a prediction, not a requirement.** When the measured result lands near it, the lead amends the criterion to the measured figure with a dated note; the builder never moves their own goalpost.
- **A coverage guard built over PLUGS cannot see ROUTES whose legitimate caller has no identity yet.** The rate-limit resolver registry and its router-derived guard covered every credential plug and still missed WebAuthn registration and the no-token access claim; the fallback collapsed both into one IP bucket and reddened main for 2.5 h while the fleet was capped. CORRECTED: the fallback key was ALREADY per-test scoped and the per-IP budget on /login-class routes is the intended brute-force control; the 8 reds were TEST CONSTRUCTION (bare build_conn() outside ConnCase carries no scope). The guard this needs is a test over tests: every module exercising a limited route takes its conn from ConnCase.
- **When the fleet is capped and main is red, main reverts.** Containment beats a third hour of blocked merges; the re-land row carries the enumeration the original lacked.

- **Verify identity, not just contents.** A cheap read answers a question ADJACENT to the one you care about, confidently. Three shapes from one night: (a) "own your inputs" is satisfied by a REGULAR FILE, checked with `ls -l` (mode starts `-`, not `l`); `cat`, `wc` and write-then-read-back are blind through a symlink, and a lane lost four claims writing its "own" held-rows file through a forgotten `ln -sfn` into another lane. (b) "based on the revert" is `git merge-base --is-ancestor <revert sha> <pr head>`, not `baseRefName`, which says `main` for a branch cut an hour early. (c) a `bp doc patch` you believe landed is `bp task show` on the PUBLISHED row, not your own patch receipt.
- **Every git WRITE takes `git -C <absolute path>`.** cwd resets between bash calls, so `cd <dir> && git checkout/add/commit …` is the exact shape that staged 26 files in the MAIN checkout. Reads may use cd; writes never.
- **A comment is behaviour-neutral but not position-neutral; a gate that hashes a line number measures position.** "Byte-identical production behaviour" and "byte-identical file" are different claims; say which one you proved. Sobelow waivers hash LINES. A comment inserted above a `pipeline` in `api/lib/barkpark_web/router.ex` moves every line-pinned Config.CSRF waiver below it and silently un-waives them (main's security.yml went red on #15725 for a 10-line comment). Any edit to router.ex, comments included, runs all three ratchets before push: `api/scripts/sobelow-baseline-fingerprint-check.sh`, `sobelow-baseline-staleness-check.sh`, `sobelow-inline-overlap-check.sh`. The fingerprint script prints the recomputed hash for a moved row; re-pin with it.
