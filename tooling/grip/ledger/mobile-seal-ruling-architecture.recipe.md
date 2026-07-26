# mobile-seal-ruling-architecture — re-derivation recipes (seal wave verifier, 2026-07-26)

Facts behind the D34–D40 ruling draft. All read-only; ledger reads via bp against guerrilla.

## Mobile charter's highest D-number is D33 → D34 is the next free slot
    git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md | grep -oE '\*\*D[0-9]+' | sort -t D -k2 -n | tail -1
# → **D33

## Epic root: 45 children, 7 criteria all met=false, GOAL task is a CHILD of the root
    bp task get task-c31a4f0a6c5be3ea -o json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['child_count'], d['doc']['criteria_progress'])"
# → 45 {'met': 0, 'total': 7}; children[] contains task-08b05ad1e792a850 (GOAL, open, 0/4)

## GOAL C1 is structurally circular; C2 names a done task + a non-child orphan
    bp task get task-08b05ad1e792a850 -o json
# C1 "All executable children of task-c31a4f0a6c5be3ea are lifecycle_status done (16 open at filing)" — the GOAL is itself such a child
# C2 names task-e8ca8c5b9f99e9f8 (done in root children list) and task-993d136b0fbf2fd1 (parent_id null, not a child)

## Orphan task-993d136b0fbf2fd1: parent null, AC null, Elixir compose.ex + Go pdrender twin (not mobile)
    bp task get task-993d136b0fbf2fd1 -o json
# → PARENT None, AC None, desc "SPUN OUT OF mob-bl-react-list-emitter… ELIXIR compose.ex normalize_list_item… map falls to passthrough"

## Human-gate rows: member-seat EXISTS; push-creds and device-boot DO NOT
    bp task get mob-hg-member-seat -o json   # ok:true, open, 0/2
    bp task get mob-hg-push-creds -o json    # error code not_found
    bp task get mob-hg-device-boot -o json   # error code not_found

## Criterion 6 is doubly stale: APNs/FCM adapters + credential gate test ARE on main (#6122)
    git ls-tree -r origin/main --name-only | grep -E 'push/adapters|credential_gate'
# → cloud/lib/barkpark_cloud/push/adapters/{apns,fcm,not_configured}.ex + cloud/test/barkpark_cloud/push/credential_gate_test.exs
    git log origin/main --oneline --grep=6122   # 95740b88a feat(push-relay): wave-2 BUILD … (#6122)

## Criterion 3's cited falsifier is gone: TasksScreen header no longer says "Read-only"
    git show origin/main:apps/mobile/src/screens/TasksScreen.tsx | sed -n 1,7p
# → "Tapping a row opens TaskDetailScreen — the full dossier plus FENCE-FREE …"; task-dc540e00b27f9ea7 done 5/5

## Archive reconcile truth: ALL THREE read funnels filter the shelf → optimistic-only self-heals
    git grep -n 'archived_filter(false)' origin/main -- api/lib/barkpark/studio_chat.ex
# → :159 (rollup), :261 (list_sessions default), :322 (fleet_snapshot)

## Rich-tail shared leg: ct-bl-stream-rich is OPEN in the OTHER epic under D75/D76 law
    bp task get ct-bl-stream-rich -o json   # open, parent bp-chat-tui-epic
    git show origin/main:.claude/workflows/bp-chat-tui-charter.md | grep -n 'D75\|D76\|ct-bl-stream-rich' | head
# wave-8 plan: round-2 FABLE HIGH-FLIP-RISK, after ct-bl-tail-settle-gen (merged as #6024 per mobile charter)

## Haptic dup: task-4e10b15dc6cdb71f and drafts.task-a3722cb3acd7c8f1 share one title, both open children
    bp task get task-c31a4f0a6c5be3ea -o json | python3 -c "import json,sys; [print(c['doc_id'],c['lifecycle_status'],c['title'][:60]) for c in json.load(sys.stdin)['children'] if 'a3722cb3' in c['doc_id'] or '4e10b15d' in c['doc_id']]"
# → identical titles "Haptic registry has no archive/option-pick event (t3w2-s7 miss)"; kill verb = bp doc discard-draft

## flake-claude-chat-stderr-cleanup is parent-null (non-child, non-gating)
    bp task get flake-claude-chat-stderr-cleanup -o json   # PARENT None, open
