# Re-derivation — the recorder's WRITE-boundary secret scrub, on the MERGED bytes of #17624

Written 2026-09-11 by `deploy-r9-w10`, the INDEPENDENT reviewer for
`dr-bl-recorder-http-read-path` c6. I did not write #17624. Everything below was RUN in a
worktree cut from `origin/main` at `9be195689` (the merge commit under review is
`48b5181a73d146383912730c50be818eef18834b`), on a private test partition
(`MIX_TEST_PARTITION=deployr9w10`). The adversarial inputs in §1 are MINE — none of them is a
fixture vector from the PR, which is the point: a corpus written by the builder measures the
builder's imagination.

**VERDICT: HOLDS WITH RESIDUALS.** Every mechanism claim c2 makes is true of the merged bytes.
The absolute reading of c2's sentence ("contain no secrets") is NOT true, and §5 R1 is a
cleartext leak of a whole `bppat_` token on a shape a PTY can produce.

## the claim under review

> c2 — "The recorded build-log bytes contain no secrets by the time they are durable — proven by
> reading the stored artifact directly, not the rendered response. The scrub runs ONCE, in
> Elixir, sharing the single `@secret_patterns` set; a second pattern set in shell is forbidden."

Four separable claims: ORDER/SHAPE (§1), SINGLE SET (§2), WRITE BOUNDARY (§3), CONTAINER (§4).

## 0. the tree

    git worktree add …/deploy-r9-recorder-review -b deploy/r9-recorder-review origin/main
    git rev-parse HEAD                      # 9be1956892eca6ad3958bec05d2fb101c0157c40
    cd api && MIX_ENV=test mix compile       # Generated barkpark app
    cd cloud && CC=/usr/bin/clang MIX_ENV=test mix compile   # Generated barkpark_cloud app

TRAP: `cloud` will not compile without `CC` set on macOS — it fails inside a NIF's makefile with
`commands "gcc --version" and / or "make --version"`, which reads like a missing dep rather
than a missing compiler, and leaves the dump script's output file absent (the first `cmp` in §2
therefore printed DIFFER for a reason that had nothing to do with drift).

## 1. ORDER AND SHAPE — `BuildLogScrub.raw/1` over inputs the PR never drove

    cd api && MIX_ENV=test mix run --no-start probe.exs     # S.raw/1 per row, `\e` = 0x1B

| # | input (escapes shown) | output | verdict |
|---|---|---|---|
| A1 | `tok bppat_7Kd-Qm2x\e[31mTf9Zb_LpV4nA1sJhR0yWuEcG3iOtXvB\e[0m end` | `tok [redacted] Tf9Zb_LpV4nA1sJhR0yWuEcG3iOtXvB end` | **PARTIAL LEAK** — 31 of the 43 body chars ship raw |
| A2 | `\e]0;build bppat_AAAAbbbbCCCC1111dddd\aline api_key=s3cretValueGoesHere1` | `line api_key=[redacted]` | OK — the OSC arm swallows its whole payload |
| A3 | `BARKPARK_TOKEN=\e[1mbppat_ZZZZ…uuuu` | `BARKPARK_TOKEN=[redacted]` | OK |
| A4 | `run\e[0mapi_key=s3cretValueGoesHere1` | `run api_key=[redacted]` | OK — the weld rule firing |
| A5 | `KEK Zm9vYmFyQmF6MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OTw` (contiguous alnum) | `KEK [redacted]` | OK |
| A5b | `KEK Zm9vYmFy-QmF6…_TU4` (same length, `-`/`_` present) | **unchanged** | **LEAK** — see R2 |
| A6 | `** (DBConnection) ecto://deploy:Pa55w-rd!x@db.internal:5432/bp_prod refused` | `ecto://[redacted]@db.internal:5432/bp_prod refused` | OK |
| A7 | `curl -H 'Authorization: Bearer sk-live-9aBc…345'` | `…Bearer [redacted]` (closing `'` eaten) | OK, minor copy loss |
| A8 | `deployed 3f1a2b7c9d0e4f5a6b8c1d2e3f4a5b6c7d8e9f01 to prod` | **unchanged** | OK — the SHA is NOT redacted, as required |
| A9 | A4's input under the REVERSE order (`scrub \|> strip_ansi`) | `run api_key=s3cretValueGoesHere1` | **CONTROL FIRES** — the order is load-bearing and measured here, not quoted |

A9 is the control on the whole table: the same input the shipped order redacts ships in
cleartext under the reverse order, so §1 is measuring the fold and not the alphabet.

A second probe pushed on A1's shape, because A1 is a residual and a residual has to be bounded:

| # | input | output | verdict |
|---|---|---|---|
| B1 | CSI 3 chars into the PAT body (`bppat_7Kd\e[31m-Qm2x…`) | `tok [redacted]` | OK |
| B2 | CSI inside the PREFIX (`bp\e[31mpat_7Kd-Qm2x…`) | `tok bp pat_7Kd-Qm2xTf9Zb_LpV4nA1sJhR0yWuEcG3iOtXvB` | **FULL CLEARTEXT LEAK** |
| B3 | control: the same PAT, no colour | `tok [redacted]` | OK — B2 is the colour, not the token |
| B10 | idempotence: `raw(raw("BARKPARK_TOKEN=<pat>"))` | `equal = true` | OK |

B2/B3 together are the finding: the token is redacted, the SAME token split by a control
sequence is not. Cause, read off `build_log_scrub.ex`: `strip_ansi/1` replaces an alnum↔alnum
run with `@escape_delimiter " "`, which is exactly what makes A4 work — and exactly what tears a
credential in two when the run lands inside it. Neither arm then matches: the head is under the
prefix arm's `{8,}` floor and the tail has no prefix and carries `-`/`_`, so the bare-token
clause (contiguous `[A-Za-z0-9]{32,}`) cannot see it either. The moduledoc scopes out a secret
that spans a NEWLINE; it does not mention one that spans an ANSI RUN, and on PTY output that is
the likelier of the two.

## 2. SINGLE SET — both apps compile the same bytes

Not "both read the file" (that is a grep) — the two COMPILED tables, term for term:

    # per app: Enum.map(compiled_secret_patterns(), &{Regex.source, Regex.opts, replacement})
    #          plus compiled_ansi_run(), :erlang.term_to_binary, sha256
    api   patterns: 6  sha=e0b349cc26e7ce250534489302ec6dd7e03644a1e6230423360cf11ea78df90f
    cloud patterns: 6  sha=e0b349cc26e7ce250534489302ec6dd7e03644a1e6230423360cf11ea78df90f
    cmp api-set.bin cloud-set.bin  ->  IDENTICAL term-for-term

There is no shell pattern set: `git grep -n 'redacted' deploy/` finds none, and the only
redaction tables in the tree are these two module reads of one file.

Lock tests, baseline:

    api   mix test test/barkpark/sites/build_log_scrub_lock_test.exs        9 tests, 0 failures
    cloud mix test test/barkpark_cloud/failure_copy_scrub_lock_test.exs     4 tests, 0 failures

MUTATION 1 — delete the prefix arm (`(?:bppat|bpcs)_|bp_[a-z]+_` and its vendor siblings) from
`cloud/priv/secret-scrub.exs`, one occurrence, verified by diff:

    api   9 tests, 2 failures   1) every shared vector folds to the shared expected bytes
                               2) the fixture is not empty — the control on every assertion below
    cloud 4 tests, 2 failures   (the same two)

BOTH SIDES RED off ONE file edit. Note honestly WHICH tests fire: the vector test (behaviour)
and a `length(patterns) >= 6` ratchet. The "no second table in this app" test stays GREEN here,
correctly — a fixture edit is not drift, both sides moved together. That test is mutation 2's:

MUTATION 2 — inline a second arm in `BuildLogScrub` only
(`@secret_patterns @secret_scrub.patterns ++ [{~r/\bnpm_[A-Za-z0-9]{20,}\b/, "[redacted]"}]`):

    api   9 tests, 1 failure    1) the compiled set IS the file's set — no second table in this app

Restored from byte copies after each; `git status --porcelain` EMPTY, api lock back to 9/0.

The set is also DISPATCHED ON, which is what keeps the lock tests reachable when the fixture is
the only file a PR touches: `scripts/elixir-path-escape-check.sh` declares
`cloud/priv/secret-scrub.exs` in `ELIXIR_COMPILE_PATHS` as an exact file, `--list-escapes`
resolves it from both `build_log_scrub.ex` and the lock test, and elixir.yml reads its path sets
out of that script rather than its own `paths:` key. `bash scripts/elixir-path-escape-check.sh`
→ `OK: every repo-root read from api/lib + api/test is dispatched on.`

## 3. WRITE BOUNDARY — the test that reads the FILE, and what reds it

THE TEST, by name:
`api/test/barkpark/sites/deploy_runner_test.exs`, describe *"the recorded log is SCRUBBED AT
WRITE (dr-bl-recorder-http-read-path c2)"*, test **"THE STORED BYTES carry no token and no
colour once the record is durable"** — it runs a real build whose stub emits a live-shape
`bppat_` PAT and real 0x1B bytes, copies that output to `<log>.unfolded` (a path nothing folds)
and ASSERTS THE PRECONDITION on it, then reads `File.read!(log)`. A response is never touched.

    mix test test/barkpark/sites/deploy_runner_test.exs        111 tests, 0 failures

MUTATION 3 — in `write_terminal_record/2`, stamp without folding:

    -    scrub_version = scrub_recorded_log(log_file)
    +    scrub_version = if is_binary(log_file), do: BuildLogScrub.version(), else: nil

    111 tests, 2 failures
      1) … THE STORED BYTES carry no token and no colour once the record is durable
      2) … log_bytes describes the SCRUBBED file, not the raw one it replaced

Restored; tree clean. The fold is therefore load-bearing, and `log_bytes` is measured AFTER it
(`write_terminal_record/2` calls `scrub_recorded_log/1` above the `payload` map).

THE CRASH-BEFORE-FINALIZE STATE, read off the code path: the terminal record is written ONLY at
finalize, so a box that dies mid-build leaves a RAW `<slug>-<tag>.log` and NO record at all. It
is closed two ways. (a) the manifest is left on disk, so the run finalizes — and folds — on the
next `status/1`. (b) `build_record/2` pipes through `heal_unscrubbed_log/1`
(`deploy_runner.ex:530`): `log_scrub != version` AND the log still `File.regular?` → fold,
re-measure, rewrite the record. Both are TESTED, not merely written: *"an UNSTAMPED record whose
log is still on disk heals on the next read"* asserts its precondition (raw bytes present,
`log_scrub` key absent) before healing and then asserts the heal is DURABLE on disk; *"an
unstamped record whose log is GONE stays unstamped — no phantom claim"* pins `log_scrub == nil`
+ `log_state == :missing`. `build_records/0` deliberately does not heal.

## 4. CONTAINER — asserted by READING, docker daemon unavailable

`docker info` → DOCKER_DOWN on this host, so no image was built. Stated as asserted, not proven.
What was MEASURED rather than eyeballed is the path arithmetic, which is the part a reader gets
wrong:

    elixir -e 'IO.puts(Path.expand("../../../../cloud/priv/secret-scrub.exs", "/app/lib/barkpark/sites"))'
    /cloud/priv/secret-scrub.exs

`api/Dockerfile`: `WORKDIR /app`, `COPY api/lib lib` → the module compiles at
`/app/lib/barkpark/sites/build_log_scrub.ex`, and line 98 is
`COPY cloud/priv/secret-scrub.exs /cloud/priv/secret-scrub.exs`. Destination == resolution.
`api/Dockerfile.dockerignore` excludes `cloud` at line 25 and negates at 31/32 (`!cloud/priv`,
`!cloud/priv/secret-scrub.exs`) — AFTER the exclusion, which is the order that matters. And the
Dockerfile's own `RUN set -e; for f in … [ -f "$f" ]` loop at line 112 lists
`/cloud/priv/secret-scrub.exs` by name, so a missing COPY fails the image build with a named
error instead of compiling a module with no patterns — the failure mode `tooling/pds` cost 15h.
`BuildLogScrub` has no absent-file fallback (`Code.eval_file` at compile), so the build cannot
silently ship a scrub that redacts nothing.

## 5. RESIDUALS — input classes a build log plausibly carries that the set does not cover

| id | class | measured | severity |
|---|---|---|---|
| R1 | **a credential split by an ANSI run.** Run inside the `bppat_` prefix → the WHOLE token cleartext (B2); run past body char 8 → the 31-char tail cleartext (A1). Caused by `strip_ansi/1`'s weld space, which A4 requires. Not scoped out by any doc: the moduledoc excludes newline-spanning shapes only. | B2, A1 | **HIGH** — full-token leak, on PTY output, which is this artifact's normal shape |
| R2 | **a bare base64url secret with `-`/`_` and no known prefix**, and any env fold whose KEY is outside the clause's word list (`*_KEK=`, `SIGNING_KEY=`, `SALT=`, `DSN=`). ~94% of 32-byte url-safe bodies carry a `-`/`_` (the fixture's own figure for `bppat_`). | A5b, B4 vs B5 | **MEDIUM** |
| R3 | **JWTs** — `eyJ…` in three dot-separated runs; no arm sees them (the dots break the bare clause, `eyJ` is not a prefix). | B7 | **MEDIUM** |
| R4 | **PEM private-key blocks** — multi-line; structurally out of reach of a line-oriented fold, which the moduledoc does scope out for newlines. | B8 | MEDIUM (bounded by disclosure) |
| R5 | **vendor prefixes not in the arm** bare in prose: `npm_`, `glpat-`, `dop_v1_`, `SG.`, `AIza`. Covered only when they ride a known KEY (`NPM_TOKEN=` redacts — B6). | B6 | LOW |
| R6 | **the tee→finalize window.** The shell's `tee` writes verbatim; the fold is at finalize, not per line. A raw log exists on disk for the whole build, and survives a box death until the next `status/1` or the next single-record read. NAMED in the moduledoc and in the PR body; closing it means a second scrubber in bash, which c2 forbids outright. | code + §3 | ACCEPTED, disclosed |
| R7 | **the `log_scrub` stamp is an unverified assertion.** Mutation 3 produced a record stamped `v1` over RAW bytes, and `heal_unscrubbed_log/1` skipped it *because* the stamp was there. Nothing re-reads bytes to confirm a stamp. One writer today, so LOW — but a byte door must not read the stamp as evidence ABOUT BYTES; it is evidence about which code ran. | mutation 3 | LOW |
| R8 | copy loss, not a leak: the bearer arm's `\S+` eats a trailing quote/paren (A7). | A7 | TRIVIAL |

`URL?token=…` is COVERED (B9 → `?token=[redacted]`), contra the obvious guess.

## 6. what the PR's prose claims that the bytes do not support

1. The PR body's headline — *"the densest secret artifact on the box"* now scrubbed — is true of
   its own shapes and NOT of R1. **No surface in #17624 mentions an ANSI run INSIDE a
   credential**, while the moduledoc explicitly disclaims the newline case; a reader finishes
   `build_log_scrub.ex` believing the colour case is the one that was solved (A4/A9), when the
   colour case is also the one that is open (B2).
2. c2's sentence read absolutely — "contain no secrets" — is REFUTED by R1/R2/R3. Read as the
   mechanism claim it spends its own words on (scrub once, in Elixir, one set, no shell copy,
   proven off the stored artifact), it HOLDS in full.
3. Everything else checked out verbatim: 111/0, 2 failures under the write mutation, 9+4 lock
   tests, both lock sides red on one fixture arm, the `.dockerignore` negation, the `COPY`
   destination, and the heal path.

## 7. a gate #17624 left red on main — found while running the doc gates here

`bash scripts/check-doc-budgets.sh` → PASS (it exempts `tooling/grip/ledger/*.md` by design, so
this packet needs no budget row). `bash scripts/docs-anchors-check.sh` → **FAIL**, and it is NOT
this packet: removing the file and re-running reproduces it byte for byte.

    FAIL: §8b a @canonical marker now names a DIFFERENT symbol than the pin records.
          < pinned (the impl the marker was written for)   > current
          +build-log-write-scrub	raw

`# @canonical capability:build-log-write-scrub aka:scrub-at-write,recorder-scrub,redacted` was
added by #17624 above `BuildLogScrub.raw/1` and never entered the §8b pin. The gate is ADVISORY
(an explicit S4 exclusion in `.github/required-checks.json`), which is why the PR merged over it
— it is a one-line pin addition, outside this review's fence, and it is filed here rather than
fixed here so it does not ride in on a review commit.

## the sentence for c6

> An independent reviewer (`deploy-r9-w10`, not the author) re-derived c2 on the merged bytes of
> 48b5181a73 in a worktree off origin/main 9be195689, with its own adversarial corpus and four
> mutations: ORDER, SINGLE SET, WRITE BOUNDARY and CONTAINER all HOLD — api and cloud compile a
> byte-identical 6-pattern table (sha e0b349cc…), deleting one fixture arm reds BOTH lock suites,
> inlining a second table reds the api lock, skipping the fold reds the two file-reading
> deploy_runner tests (111/0 → 111/2), and the image's `Path.expand` resolves to exactly the
> Dockerfile's COPY destination — with EIGHT residuals recorded, of which R1 is a live cleartext
> leak of a whole `bppat_` token when an ANSI run lands inside it (B2), a class no surface in
> #17624 names.
