<!-- doc-tier: cold | canonical-for: spd-w19-owner-report-closeable-rederivation | budget: 4000tok -->

# Re-derivation recipes — what the owner report (task-f559f7c508527010) can honestly close, wave 19

Every row below is a command that re-derives one fact from scratch. Nothing here is a
claim about the code; the commands are the claim.

## The scoreboard, and the divergence

    bp task get task-f559f7c508527010 -o json > /tmp/pub.json
    bp task get drafts.task-f559f7c508527010 -o json > /tmp/drf.json
    python3 -c "import json;p=json.load(open('/tmp/pub.json'))['doc']['content']['acceptance_criteria'];d=json.load(open('/tmp/drf.json'))['doc']['content']['acceptance_criteria'];[print(i,a['met']==b['met'],len(a.get('attempts') or []),len(b.get('attempts') or [])) for i,(a,b) in enumerate(zip(p,d))]"
    # published: 1/6 met; attempts 2 on idx2, 1 on idx4. draft: same met flags, ZERO attempts.

    python3 -c "import json;print(json.load(open('/tmp/pub.json'))['doc']['updated_at'], json.load(open('/tmp/drf.json'))['doc']['updated_at'])"
    # 2026-07-29T17:13:03.160675Z (published)  <  2026-07-29T17:13:45.917600Z (draft)
    # The draft is NEWER and EMPTIER. Publishing it deletes three attempt notes.

    python3 -c "import json;print(json.load(open('/tmp/pub.json'))['doc']['claim']['work_field_digests']['acceptance_criteria'], json.load(open('/tmp/drf.json'))['doc']['claim']['work_field_digests']['acceptance_criteria'])"
    # 753990f590c6aa31  753990f590c6aa31 — IDENTICAL. The work-digest fence is blind
    # to the attempts divergence, so close/stamp will NOT 409 on it.

## The harness, and its mutation half

    # (harness lives on origin/main since b43c0b41e / #7896; a stale local checkout
    #  may not have it — materialise from origin, do not trust the worktree)
    bash scripts/studio-journey-smoke.sh self-test 2>&1 | tail -20
    node tooling/studio-journey/journey.mjs --self-test --self-test-site good   # LEG A 7/7, exit 0
    node tooling/studio-journey/journey.mjs --self-test --self-test-site rot    # LEG A 3/7, exit 1

## LEG A on the CURRENT deployed build

    curl -s https://guerrilla.barkpark.cloud/status.json    # .commit -> 051112568
    bash scripts/studio-journey-smoke.sh report             # served 051112568 -> 051112568
    # LEG A 7/7 beats PASS · 46.7s wall; self-clean deleted 1/1 draft.

## The #7897 notice IS live — and LEG B's oracle cannot see it

    SRV=https://guerrilla.barkpark.cloud
    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    T=$(curl -s -X POST "$SRV/v1/auth/login-tickets" -H "Authorization: Bearer $TOK" -H 'content-type: application/json' -d '{}' | python3 -c "import sys,json;print(json.load(sys.stdin)['ticket'])")
    curl -s -c /tmp/cj.txt -b /tmp/cj.txt -L "$SRV/login/ticket/$T" -o /dev/null
    curl -s -c /tmp/cj.txt -b /tmp/cj.txt "$SRV/w/default/p/default/d/production/studio/paper/drafts.paper-b28358ff271b260e" -o /tmp/fossil.html
    grep -c paper-unrenderable-notice /tmp/fossil.html      # -> 1
    # The notice renders for BOTH id forms (bare + drafts.) and carries
    # role="alert" aria-live="assertive" data-doc-id data-doc-type.
    #
    # It sits inside main.bp-paper-shell.bp-paper-surface — NOT .bp-paper-editor,
    # which is the only region the harness's EDITOR_SHAPE probe measures
    # (journey.mjs:754-767). visible_text_chars is scoped to that absent region,
    # so LEG B prints "shell=0 … visible_text=0 chars — WORDLESSLY BLANK" for a
    # page that carries a role=alert named state. LEG B is VACUOUS post-#7897.

## The way out is a 404

    curl -s -o /dev/null -b /tmp/cj.txt -w '%{http_code}\n' "$SRV/d/production/studio/paper"                        # 404
    curl -s -o /dev/null -b /tmp/cj.txt -w '%{http_code}\n' "$SRV/w/default/p/default/d/production/studio/paper"    # 200
    # The notice's href is the first one (scope_prefix never declared/passed).

## Charter / PR state

    git show origin/main:.claude/workflows/bp-studio-space-priority-charter.md | grep -oE 'D[0-9]+' | sort -t D -k2 -n | tail -1   # D233
    gh pr view 7795 --json state,mergeable,mergeStateStatus    # OPEN MERGEABLE/UNSTABLE
    gh pr view 7899 --json state,mergeable,mergeStateStatus    # OPEN MERGEABLE/UNSTABLE
    for c in b43c0b41e 88ec6fb8b bc05b9168 f1ac08c29; do git merge-base --is-ancestor $c 051112568 && echo "$c LIVE"; done
