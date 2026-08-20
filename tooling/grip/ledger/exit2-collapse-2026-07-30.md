# exit-2 collapse across the aggregator boundary — re-derivation recipe (2026-07-30)

Cloud Console Hardening wave 9, verifier lane `exit2-collapse`. Every command below is
read-only and replayable. All repo facts come from `git show origin/main:` — the primary
checkout was measured 86 commits behind origin/main at the time of this run
(`git rev-list --count HEAD..origin/main` -> `86`), and two published wave-9 digest
claims are artefacts of that staleness (see §5).

## 1. The three guards, in CI's exact configuration

```bash
cd cloud/priv/static/__preview__
CHROME=/nonexistent/chrome node cssom-parity.mjs   >/dev/null 2>/tmp/a.err; echo $?   # 1
HEADS_BASELINE=/nonexistent  node cssom-parity.mjs >/dev/null 2>/tmp/b.err; echo $?   # 2
CHROME=/nonexistent/chrome node modal-oracle.mjs   >/dev/null 2>/tmp/c.err; echo $?   # 1
CHROME=/nonexistent/chrome node overflow-guard.mjs >/dev/null 2>/tmp/d.err; echo $?   # 1
head -5 /tmp/a.err   # raw node "Unhandled 'error' event" + spawn ENOENT stack, NO guard line
head -2 /tmp/b.err   # "!! GUARD (exit 2): no authored-head baseline sidecar at /nonexistent"
```

Root cause, one line per file — `findChrome()` returns `process.env.CHROME` **unchecked**,
so the `accessSync(c, X_OK)` guard below it is unreachable whenever CHROME is set:

```bash
grep -n 'process.env.CHROME' cloud/priv/static/__preview__/{cssom-parity,modal-oracle,overflow-guard}.mjs
# cssom-parity.mjs:386  modal-oracle.mjs:187  overflow-guard.mjs:125
```

and console-harness.yml pins CHROME while its own comment asserts the opposite:

```bash
git show origin/main:.github/workflows/console-harness.yml | sed -n '127,136p'
```

## 2. Only ONE of the three runs in CI at all

```bash
for w in $(git ls-tree --name-only origin/main .github/workflows/); do
  git show origin/main:$w | grep -q 'modal-oracle\|overflow-guard\|cssom-parity' && echo "$w"
done
# -> .github/workflows/console-harness.yml   (cssom-parity only)
```

## 3. The boundary collapses 1 and 2

```bash
git show origin/main:.github/workflows/elixir.yml | sed -n '630,662p'
```

`decide()` branches on `needs.<job>.result` only — `success | skipped | failure | cancelled |
''`. No exit code crosses. And no workflow in the repo captures one today:

```bash
for w in $(git ls-tree --name-only origin/main .github/workflows/); do
  git show origin/main:$w | grep -c 'rc=\$?\|\$? -eq 2'; done | sort -u   # -> 0
```

elixir.yml's own precedent: every refusal is `::error::` + `exit 1` (lines 132/143/153/173/180),
i.e. REFUSED is encoded in the ANNOTATION TEXT, never in the exit code.

## 4. M1 alone reds the seal predicate (four entries, not three)

```bash
git show origin/main:.github/workflows/cloud.yml | sed '8,24d' > /tmp/shim.yml
node -e "console.log(require('fs').readFileSync('/tmp/shim.yml','utf8').includes('cloud/**'))"  # false
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | sed -n '477,479p'
# if (!src.includes(d.measured_in_ci.paths)) problems.push(...)
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | grep -c 'measured_in_ci: {'  # 4
```

## 5. Two wave-9 digest claims are stale-worktree artefacts

```bash
git show HEAD:cloud/priv/static/__preview__/seal-predicate.mjs        | grep -c 'measured_in_ci: {'  # 3
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | grep -c 'measured_in_ci: {'  # 4
git diff HEAD origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs | grep -E '^[+-].*(measured_in_ci|unmeasured)'
```

CCH-D5 was promoted to rung 2 on origin/main. Any live-predicate run from a stale checkout
prints `b=FAIL` and lists CCH-D5 as unmeasured; that is the checkout, not main.

## 6. The foreign row that already owns half of M2

```bash
bp task get hg-overflow-guard-refusal-exits-1 -o json   # lifecycle open, parent auth-totp-tests-are-time-boundary-flaky, 0/3
git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs | grep -n 'const die\|die('
# 227 const die = async (msg, code = 1) ; six environmental call sites all default to 1 — unfixed
```

Its ordering constraint ("do not touch seal-predicate.mjs until cloud-gui-remake takes its
terminal verdict") is DISCHARGED: charter line 3 records the Remake epic SEALED 2026-07-21
(PR #5226), and origin/main's seal-predicate.mjs is already retargeted to
`cloud-console-hardening-epic` (`:105`) with the exit-2→REFUSED leg shipped at `:448`.
