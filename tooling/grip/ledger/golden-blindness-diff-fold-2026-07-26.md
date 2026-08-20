# Re-derivation recipes — golden blindness: diff-fold + list-item fixtures (2026-07-26)

Verifier phase, closing wave of `task-c31a4f0a6c5be3ea`. Every row is a literal
command that re-derives one load-bearing fact from a clean checkout of main.
Run from the repo root.

## R1 — mobile is NOT a third byte-mirror; it IMPORTS the Go mirror

    grep -n 'chat_golden_toolrows' apps/mobile/__tests__/chatRenderers.test.tsx

Expect: `import goldenToolrows from '../../../internal/pdrender/testdata/chat_golden_toolrows.json'`.
Mirror set is exactly two files (`GenGoldenToolrows.mirror_paths/0`):

    grep -n 'mirror_paths() ==' -B4 api/test/barkpark/chat_golden_toolrows_parity_test.exs

## R2 — the Elixir parity test's assertion style is WORD-PRESENCE, never a literal overflow string

    grep -n 'String.split(v\["projection"\]\["text"\]' -A6 api/test/barkpark/chat_golden_toolrows_parity_test.exs
    grep -rn 'more lines' api/test/ | grep -v _build

Expect exactly ONE literal-number overflow assertion repo-wide in tests:
`api/test/barkpark_web/live/studio/chat_live_test.exs:3786: assert html =~ "+100 more lines"`,
driven by a 120-line **gapless** `Write` — blind to drawable-vs-all-lines.

## R3 — the fixture cannot reach the 20-row budget

    python3 -c "
    import json
    d=json.load(open('internal/pdrender/testdata/chat_golden_toolrows.json'))
    for v in d['variants']:
        L=v['block'].get('lines') or []
        ops=[l.get('op') for l in L if isinstance(l,dict)]
        print(v['name'], 'lines',len(L), 'gaps',ops.count('gap'))
    "

Expect max 5 lines (`multi_edit_diff`, 1 gap) — never > 20.

## R4 — the 5-site fold split (3 all-lines vs 2 drawable-only)

    grep -n '@chat_diff_budget' api/lib/barkpark/portable_doc/render/components.ex
    grep -n '@collapsed_budget' api/lib/barkpark_web/live/studio/chat_tool_renderer.ex
    grep -n 'CHAT_DIFF_BUDGET' js/packages/react/src/blocks/chat.ts
    grep -n 'chatDiffBudget\|diffOverflow' internal/pdrender/chat_blocks.go
    grep -n 'CHAT_DIFF_BUDGET\|drawableCount' apps/mobile/src/papers/portabledoc/chat.tsx

## R5 — the `diff` block does NOT diverge (no gap rows exist there)

    grep -n 'parseUnifiedDiff emits no "gap" rows' -B4 internal/pdrender/diff.go

## R6 — blast radius on committed goldens is ZERO

    grep -rn 'more lines' --include='*.json' api/test/support/fixtures internal/pdrender/testdata js/packages/react/tests/fixtures
    grep -rln '<details>' api/test/support/fixtures/pd-parity js/packages/react/tests/fixtures/pd-golden

Expect: no hits.

## R7 — no committed golden carries a map-shape LIST item (Go `itemNodes` default arm is a vacuous green)

    python3 -c "
    import json,glob
    LIST={'list','bullet_list','numbered_list','ordered_list','check_list','checklist'}
    def w(o,out):
        if isinstance(o,dict):
            if (o.get('type') or o.get('kind')) in LIST:
                for it in (o.get('items') or (o.get('attrs') or {}).get('items') or []):
                    out.append(type(it).__name__)
            for v in o.values(): w(v,out)
        elif isinstance(o,list):
            for v in o: w(v,out)
    out=[]
    for f in glob.glob('internal/pdrender/testdata/**/*.json',recursive=True)+glob.glob('api/test/support/fixtures/**/*.json',recursive=True)+glob.glob('js/packages/react/tests/fixtures/**/*.json',recursive=True):
        try: d=json.load(open(f))
        except Exception: continue
        w(d,out)
    from collections import Counter; print(Counter(out))
    "

Expect `Counter({'list': 25})` — zero `dict`, zero `str`.

## R8 — the pdrender Go gate CANNOT be run whole in the main checkout (standing local vacuous-RED)

    CC=clang go test ./internal/pdrender/ -count=1 -run TestNoInlineDivideFormulaOutsideSolver -timeout 45s

Expect `panic: test timed out`. Cause: `internal/pdrender/joincols_test.go:169` shells
`grep -rn --include=*.go '…' .` from the **module root**, which recursively scans
every registered worktree (`git worktree list | wc -l` → 1446; `ls .claude/worktrees | wc -l` → 1334).
Green baseline must be taken either inside a worktree or with `-run`:

    CC=clang go test ./internal/pdrender/ -count=1 -run 'ChatGoldenToolrows|Diff|List' -v | tail -3
