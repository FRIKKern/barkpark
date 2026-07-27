# Re-derivation recipes — mobile seal wave, charter-full-read verify

Scope: the two charters + the capstone ratification + search-template D4, for the
2026-07-26 closing wave of `task-c31a4f0a6c5be3ea`. Every row is a literal command
whose output is the fact. Read from `origin/main`, never the working tree (D20).

| # | Fact | Command |
|---|---|---|
| 1 | Mobile charter own D-entries are D1–D33, contiguous, **no D34** — D34 is the next free number | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -oE '^- \*\*D[0-9]+[a-z]* ' \| sort -V \| uniq` |
| 2 | D21 wording is serialize-only ("territory-serialized … exactly ONE owner per round"); no merge clause | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -n 'D21 —'` |
| 3 | Absorption precedent (criteria of one task stamped by a slice) exists twice | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -n 'absorbed-by-S6\|absorbing slices'` |
| 4 | D18 re-scopes `mob-bl-react-server-export` to **v1.5, filed not built** | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -n 'D18 —'` |
| 5 | D28 already rules **no fleet frame on archive**; the lifecycle frame is "a filed follow-up, never smuggled in" | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -n 'No fleet frame on archive'` |
| 6 | The offline cache is charter-declared **Wave 3** scope, not v1/wave-2 | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -n '^\*\*Wave 3:'` |
| 7 | `mob-w3-rich-tail` was filed as wave-3 at birth (Decide entry) and re-affirmed in the seal entry | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -n 'rich-tail\|rich tail S3'` |
| 8 | `#6122` / `mob-w2-push-relay-build` has **no wave-log merge entry** (charter gap) and `task-17f14a4557cf7fe2` is charter-invisible | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -c '6122\|17f14a4557cf7fe2'` (⇒ 0) then `git log origin/main --oneline \| grep 6122` |
| 9 | chat-TUI stream-rich (D75–D80) is **ratified but UNBUILT** — no `stream_rich.go`; `renderTail` still flat | `git ls-tree origin/main internal/chat/ --name-only \| grep stream_rich; git show origin/main:internal/chat/render.go \| sed -n '285,291p'` |
| 10 | Server `stable_boundary`/`advance_streaming` are **private `defp` inside a LiveView**, on no wire | `git grep -n 'defp stable_boundary\|defp advance_streaming' origin/main -- api/lib` |
| 11 | Capstone R5: rich tail is **wave 3, leaning server-emitted, "it is a wire change"**, flippable | `bp paper view t3code-upgrade-capstone --no-color \| grep -n 'R5 ' -A 10` |
| 12 | Capstone ratifies cache kinds v1 = tasks-prime, chat-sessions, paper-list, paper; chat-transcript gated on a privacy ruling; expo-sqlite ~57.0.1, amend D14's stale ~56.0.4 | `bp paper view t3code-upgrade-capstone --no-color \| grep -n 'Kinds v1\|~56.0.4\|WITHOUT ROWID'` |
| 13 | expo-sqlite installed `~57.0.1`, imported **nowhere** (one comment in storage.ts) | `git show origin/main:apps/mobile/package.json \| grep expo-sqlite; git grep -rn 'expo-sqlite' origin/main -- apps/mobile/src` |
| 14 | `@barkpark/react` has **no `./server` subpath** — the root `.` carries a `react-server` *condition* instead | `git show origin/main:js/packages/react/package.json \| python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['exports'],indent=1))"` |
| 15 | search-template D4's `@barkpark/react/server` prescription has **zero code consumers** (prose-stale only) | `git grep -n '@barkpark/react/server' origin/main` (⇒ the charter line only) |
| 16 | 45 children / 17 open / 14 executable residuals (minus GOAL, human gate, draft) | `bp task get task-c31a4f0a6c5be3ea -o json \| python3 -c "import json,sys;d=json.load(sys.stdin);[print(c.get('lifecycle_status'),c.get('doc_id')) for c in d['children'] if c.get('lifecycle_status')!='done']"` |
