<!-- doc-tier: cold | canonical-for: pds-wave-25-charter-currency-rederivation | budget: 3000tok -->

# PDS wave 25 — charter-currency re-derivation recipe

Every claim below re-derives from `origin/main` with one command. Run `git fetch origin -q` first.

## 0. Pin the charter (all line numbers below are against this file)

    git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter.md && wc -c /tmp/charter.md
    # 445283 /tmp/charter.md   (main charter commit 18addd9de, 2026-07-30 18:52:53 +0200)

## 1. All fourteen cited D-numbers EXIST

    grep -n 'PDS-D296\|PDS-D298\|PDS-D306\|PDS-D309\|PDS-D332\|PDS-D333\|PDS-D336\|PDS-D337\|PDS-D338\|PDS-D341\|PDS-D342\|PDS-D343\|PDS-D344\|PDS-D345' /tmp/charter.md

Anchors: D296:4265 · D298:4298 · D306:4481 · D309:4531 · D332:4898 · D333:4907 · D336:4940 ·
D337:4951 · D338:4962 · D341:4998 · D342:5007 · D343:5016 · D344:5032 · D345:5044.

## 2. D298 on main is ALREADY amended — the hollowing recipe is gone

    sed -n '4298,4345p' /tmp/charter.md

Main's D298 carries (a) an inline parenthetical "REFUTED AND SUPERSEDED by PDS-D309", and
(b) a "**VOCABULARY … REWRITTEN in wave 24**" block routing PARKED to
`bp task stage … --disposition parked --note --reopen-trigger`. The pre-amendment form
(`--note` → `content.engagement.note`; OPEN → hand-patch `content.disposition`) survives only on
the STALE unmerged branch `origin/docs/pds-wave-23-charter`:

    git diff origin/main origin/docs/pds-wave-23-charter -- .claude/workflows/bp-pds-charter.md | head -60

That diff runs main → branch, i.e. it shows main's newer text being DELETED. The branch's
charter commit is `99640c8c7` (2026-07-28); main's is `18addd9de` (2026-07-30). Nothing to fold in.

## 3. No unmerged branch holds charter edits newer than main

    MAINC=$(git log -1 --format=%ct origin/main -- .claude/workflows/bp-pds-charter.md)
    for b in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v HEAD); do
      h=$(git rev-parse -q --verify "$b:.claude/workflows/bp-pds-charter.md" 2>/dev/null) || continue
      [ "$h" = "$(git rev-parse origin/main:.claude/workflows/bp-pds-charter.md)" ] && continue
      ct=$(git log -1 --format=%ct "$b" -- .claude/workflows/bp-pds-charter.md)
      [ "$ct" -gt "$MAINC" ] && echo "NEWER $b"
    done
    # (no output — 45 branches differ, all OLDER)

## 4. Both "unmerged prior art" artifacts are content-identical to main

    git rev-parse origin/main:tooling/grip/ledger/pds-w22-remaining-rows-triage-2026-07-27.md
    git rev-parse origin/loop-epic/every-remaining-open-pds-row-is-adjudica-5:tooling/grip/ledger/pds-w22-remaining-rows-triage-2026-07-27.md
    # both 11072e97b4e60aa70e5e78fee93bdc5f8985f605

    B=origin/loop-epic/the-pds-harnesses-stop-lying-armed-prove-5
    for f in scripts/pds-crown-launch.sh scripts/pds-scratch-target.sh scripts/pds-scratch-target_test.sh; do
      echo "$f $(git rev-parse origin/main:$f) $(git rev-parse $B:$f)"; done
    # 8c54c3d77… / 8ce2b31bb… / 2a6daa23f… — identical on both sides

Both branch TIPS are `NOT_ANCESTOR` of main (squash-merged), but their content landed.

## 5. D344 undercounts: NINE verbs, not six

    git show origin/main:internal/cli/hetzner_cmd.go | grep -c 'runHetznerServerAction(out, g, verb'
    # 9  — poweron, poweroff, reboot, reset, shutdown, disable-rescue,
    #      enable-backup, disable-backup, detach-iso
    git show origin/main:internal/cli/hetzner_cmd.go | sed -n '888,893p'
    # ends: return hzDone(out, verb, srv, nil)   — srv resolved BEFORE act(), never re-read

## 6. The census canon is `open` (lowercase); the round task still says `OPEN`

    git show origin/main:scripts/pds-ledger-census.sh | sed -n '142,160p'
    # CANONICAL_OPEN = "open"   (":146 WAVE-24 REVIEW CORRECTION")
    git show origin/main:api/lib/barkpark/tasks/stage.ex | grep -n '@dispositions'
    # 155:  @dispositions ~w(open parked closed)   — trimmed + downcased

    bp task get pds-w23-triage-round -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["doc"]["content"]["description"])' | grep -n 'ratify'
    # "TWO CASES OF ONE WORD - ratify `OPEN` as canonical and normalise"  ← STALE

## 7. The exemplar-park conflict, and its legal escape hatch

    git show origin/main:api/lib/barkpark/tasks/stage.ex | sed -n '378,392p'
    # check_reopen_trigger reads ONLY content.reopen_trigger — a REACTIVATE inside
    # disposition_reason does NOT satisfy it.
    git show origin/main:api/lib/barkpark/content/mutations.ex | grep -n 'reopen_trigger'
    # :713 trigger_erased?(...) — only ERASING raw is refused; ADDING raw is allowed.

So the 8 exemplar parks can gain `content.reopen_trigger` through `/v1/data/mutate` without
re-writing `disposition_reason`, keeping their md5s byte-identical.
