<!-- doc-tier: cold | canonical-for: mobile-bucketB-18row-disposition-rerun | budget: 4000tok -->

# Re-derivation recipe — the 18 bucket-B executable rows of the mobile epic

> HISTORICAL RECORD (2026-07-29) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Baseline: `origin/main` @ `ab396959c77b01f87800e7399d5616ed8fd99a7b` (2026-07-28).
Epic root: `task-c31a4f0a6c5be3ea` (child_count 90, 67 done, 23 open).
The 23 open = 3 human gates + GOAL + `mob-w3-rich-tail` (crown) + **these 18**.

## The row census (re-derive)

```bash
bp task get task-c31a4f0a6c5be3ea -o json | python3 -c "import json,sys;d=json.load(sys.stdin);[print(c['doc_id'],c['lifecycle_status'],c['title'][:70]) for c in d['children'] if c['lifecycle_status']!='done']"
```

`bp task get <id> -o json` nests the row under `.doc` (NOT top level) — `.doc.content.description`,
`.doc.content.acceptance_criteria`, `.doc.lifecycle_status`. A top-level `.title` read returns None
and looks like an empty row.

## Falsifier re-derivation, one command per row

| doc_id | command | expected (still-failing) output |
|---|---|---|
| bl-frommarkdown-fence-language | `git show origin/main:api/lib/barkpark/portable_doc/from_markdown.ex \| grep -n 'defp code_block'` | `217:  defp code_block(value), do: %{"type" => "code", "value" => value}` — no language key |
| mob-rt-bl-list-start | `git show origin/main:api/lib/barkpark/portable_doc/from_markdown.ex \| grep -c '"start"'` | `0` |
| mob-bl-go-tail-cap-parity | `git show origin/main:internal/chat/reduce.go \| grep -n '262144\|st.Tail +='` | `454:/527: st.Tail +=` only, no cap; mobile has `MAX_TAIL_BYTES = 262_144` at reducer.ts:43 |
| mob-bl-runtime-gen-advance-2 | `git show origin/main:internal/chat/reduce.go \| sed -n '520,540p'` | the residual comment is verbatim on main: "Gen advances only on a claude system/init frame" |
| mob-rt-bl-seed-gen-sentinel | `git show origin/main:apps/mobile/src/chat/sessionStore.ts \| grep -n "gen: 0"` | `248:        this.dispatch({ type: 'tailFetched', gen: 0, session })` (row cites :232 — line drift) |
| mob-bl-streamtail-blank-line-law | `git show origin/main:api/lib/barkpark/studio_chat/stream_tail.ex \| sed -n '291,300p'` | `line == "" ->` strict equality; `defp blank?(s), do: String.trim(s) == ""` already exists at :352 |
| mob-rt-s2-followup-fixture-generator | `git show origin/main:internal/pdrender/testdata/chat_stable_frames.json \| head -c 200` | `"_comment": "HAND-AUTHORED …"`; no `barkpark.chat.gen_stable_frames` mix task exists |
| mob-zb-bl-canonical-anchor | `git show origin/main:api/test/barkpark/portable_doc/tiers_test.exs \| grep -n 'length('` | `:64 length(known) == length(Enum.uniq(known))` and `:112 > 30` — no `== 73` pin. `video.go:16` promises "the honest empty box", `:24-26` returns `nil` |
| mob-zb-bl-island-churn-offline | `git show origin/main:apps/mobile/src/papers/portabledoc/MermaidIsland.tsx \| grep -n 'INITIAL_HEIGHT\|useState'` | `50: const INITIAL_HEIGHT = 220`, `126: useState(INITIAL_HEIGHT)`; stale comment "there is no offline cache yet, that's wave 3" at :13-15. NOTE the path is `portabledoc/MermaidIsland.tsx`, not `portabledoc/blocks/` |
| mob-zb-bl-react-mrow-parity | `git show origin/main:js/packages/react/src/blocks/math.ts \| sed -n '174,178p'` | both branches `return parseAtom(c)`. Equation input still brace-free: `barkpark.portable_doc.gen_pd_parity.ex:140 "tex" => "E = mc^2"` |
| mob-zb-bl-tui-board-thought-lanes | `git show origin/main:internal/pdrender/taskblocks.go \| grep -n boardColumns` | `647: var boardColumns = []string{"open","ready","progress","blocked","done"}` (5); `gridblocks.go:386 statusLadder` has 8 |
| task-31a773375d22f39e | `git show origin/main:apps/mobile/src/papers/portabledoc/model.ts \| sed -n '32,39p'` | `num()` returns undefined for **any** value ≤ 0 — clause (a) holds, clause (b) is REFUTED |
| task-579c54dbd1df1dbd | `git show origin/main:apps/mobile/src/papers/portabledoc/blocks/core-doc.tsx \| sed -n '81p'` | blocklist `.filter((r) => r.role !== 'unknown')` vs react `js/packages/react/src/inline.tsx:212` `MANIFEST_LADDER.has(r.role)`. Larger truth: `scripts/status-manifest-check.sh` names only react + web (`:51`, `:283`) — apps/mobile absent entirely |
| task-63a68469fac91624 | `git show origin/main:apps/mobile/src/ui/theme.ts \| grep -n 'accent:\|success:'` | `45: accent: '#1f6f4a'` / `48: success: '#1f6f4a'` (light) and `65: '#3fa374'` / `68: '#3fa374'` (dark) — identical in BOTH |
| task-79551ef7cdadfa21 | `git show origin/main:apps/mobile/src/papers/portabledoc/registry.tsx \| sed -n '112p'` | `export const DEGRADE_ONLY: ReadonlySet<string> = new Set(['video', 'asciicast'])` |
| task-ce0b4827a6bff147 | `git show origin/main:apps/mobile/__tests__/tailBlocks.test.tsx \| sed -n '273p'` | `const stripRows = (s: string): string => s.replace(/<\/?mrow>/g, '')` |
| task-3be0dde8e0c75b07 | `git show origin/main:apps/mobile/src/screens/ChatSessionScreen.tsx \| sed -n '1204p'` | `listContent: { …, gap: 18, flexGrow: 1 }` |
| mob-bl-react-server-export | `git show origin/main:js/packages/react/package.json \| python3 -c "import json,sys;print(json.load(sys.stdin)['exports'].keys())"` | `'.', './client', './paper-surface.css', './package.json'` — no `./server`; the `.` entry already carries a `react-server` condition (charter D53) |

## LegendList gap ownership — the spacing row's decisive fact

```bash
cd apps/mobile/node_modules/@legendapp/list && python3 -c "
s=open('react-native.mjs').read(); i=s.find('createColumnWrapperStyle(contentContainerStyle'); print(s[i-120:i+300])"
```

v3.3.3 `createColumnWrapperStyle` **unconditionally** hoists `gap`/`rowGap`/`columnGap` OUT of
`contentContainerStyle` (`contentContainerStyle.gap = void 0`) into `ctx.columnWrapperStyle`, then
derives `scrollAxisGap` from it. The 18px is therefore LIST-OWNED and uniform across every row —
it cannot be tightened for intra-turn rows via `contentContainerStyle`, and it feeds LegendList's
own size estimates. Any fix is per-row or on the cold path, never a container-style tweak.

## Not one of the 18

`task-0bce1f978d8f4cbc` (settle/2 superlinear knee) has `parent_id: null` — a parentless orphan,
outside the epic tree and outside the D34 seal predicate entirely.
