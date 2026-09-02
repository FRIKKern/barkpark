# Re-derivation recipe — server canonical block-type census (2026-07-26)

> **SUPERSEDED 2026-09-02 — this record is CORRECT ON ITS DATE and is left standing.**
> The counts below have moved. Today's canonical numbers, their derivation commands, and the
> full exclusions ledger live in `docs/decisions/0006-canonical-block-type-count.md`; the Elixir
> count is pinned by a run-proven test in `api/test/barkpark/portable_doc/tiers_test.exs`.
> Cite that, never a number from this page.

Verifier lane `server-canonical-census`, mobile blocks wave. All commands read
`origin/main` (not the worktree). Run from repo root with `export LC_ALL=C` — the
set-diffs are collation-sensitive (`bulletList` vs `bullet_list` sort differently
under UTF-8).

## 1. compose.ex literal type-keyed clauses = 69

```sh
git show origin/main:api/lib/barkpark/portable_doc/render/compose.ex \
  | grep -oE 'compose_block\(%\{"type" => "[a-z0-9_-]+"' \
  | sed 's/.*"type" => "//;s/"$//' | sort -u > /tmp/compose_types.txt
wc -l < /tmp/compose_types.txt      # 69
```

Total `compose_block(` clause LINES = 132 (`grep -cE '^\s*defp? compose_block\('`);
the 69 is the *literal quoted-head* count the parity extractors see (compose.ex:277-281
documents that alias clauses deliberately use a bound `t` to stay out of those greps).

**Two canonical types are invisible to that grep**: `stats` (compose.ex:1212) and
`tasks` (compose.ex:982) are matched via `when t in ["stats","stat-grid"]` /
`when t in ["tasks","task-list"]`. Canonical compose set = 69 + 2 = **71**.

```sh
{ cat /tmp/compose_types.txt; echo stats; echo tasks; } | sort -u > /tmp/compose_canonical.txt  # 71
```

## 2. tiers.ex known_types = 73, canonical 71 — INDEPENDENT confirmation

```sh
git show origin/main:api/lib/barkpark/portable_doc/tiers.ex > /tmp/tiers.ex
{ sed -n '55,172p' /tmp/tiers.ex | grep -oE '"[a-z0-9-]+"' | tr -d '"'; \
  printf 'section\ncolumns\ntabs\n'; } | sort -u > /tmp/tiers_known.txt   # 73
printf 'stat-grid\ntask-list\n' | sort > /tmp/t_al.txt
comm -13 /tmp/t_al.txt /tmp/tiers_known.txt > /tmp/tiers_canonical.txt    # 71
comm -3 /tmp/compose_canonical.txt /tmp/tiers_canonical.txt               # EMPTY — identical sets
```

`@section ~w(section columns tabs)` is an unquoted sigil — a `grep '"…"'` census
misses it; that is why the three structural types must be appended by hand.

## 3. react registry = 66 keys / 59 canonical (7 function-identity aliases)

```sh
for f in core dataviz forms chat table sheet taskboard math; do
  git show origin/main:js/packages/react/src/blocks/$f.ts > /tmp/rx_$f.ts; done
python3 - <<'EOF'
import re,glob
keys=[]
for f in glob.glob('/tmp/rx_*.ts'):
    m=re.search(r'export const \w+Emitters: Record<string, Emit> = \{(.*?)\n\}', open(f).read(), re.S)
    body=re.sub(r'//[^\n]*','',m.group(1))
    keys+=[i.split(':')[0].strip().strip("'\"") for i in body.split(',') if i.strip()]
print(len(keys), len(set(keys)))    # 66 66
open('/tmp/react_types.txt','w').write('\n'.join(sorted(set(keys)))+'\n')
EOF
```

Aliases (key → a function another key already owns): `bulletList`, `bullet_list`,
`bulleted-list`, `bulleted_list` → `list`; `quote` → `blockquote`; `stat-grid` →
`stats`; `task-list` → `tasks`. **7.** `numbered_list` → `numberedList` is a
DISTINCT function (core.ts:512, `list({...b, ordered:true})`) so it is not a
function-identity alias — matching charter D31, refuting registry.ts:34-39's own
comment which lists it as one.

## 4. The 13 types with no react emitter

```sh
comm -23 /tmp/compose_canonical.txt <(comm -13 <(printf 'bulletList\nbullet_list\nbulleted-list\nbulleted_list\nquote\nstat-grid\ntask-list\n'|sort) /tmp/react_types.txt)
# codelist composite embed field-boolean field-color field-datetime field-image
# field-number field-reference field-select field-slug field-string field-text
```

Same 13 fall out of `tiers_known - react_types` — two independent derivations.
The only react-canonical type with no compose clause of its own is `numbered_list`
(compose.ex:286 normalizes it to `list`+`ordered:true`).

## 5. Go pdrender ⊇ react 66 (strict superset, empty diff)

```sh
git show origin/main:internal/pdrender/pdrender.go \
  | grep -oE 'r\.blocks\["[a-zA-Z0-9_-]+"\] =' | sed 's/.*\["//;s/"\] =//' \
  | sort -u > /tmp/go_types.txt        # 83  (79 if the regex omits `_` and `PdSheet`)
comm -13 /tmp/go_types.txt /tmp/react_types.txt         # EMPTY
comm -13 /tmp/go_types.txt /tmp/compose_canonical.txt   # EMPTY
comm -23 /tmp/go_types.txt <(sort -u /tmp/react_types.txt /tmp/compose_canonical.txt)
# PdSheet arrayOf dashboard localizedText
```

## 6. Mobile registry = 43 (38 literal + 5… no: 37 literal + 6 CHAT_RENDERERS)

`BLOCK_RENDERERS` (blocks.tsx:906) spreads `...CHAT_RENDERERS` (chat.tsx) — a
literal-key census of blocks.tsx alone yields 38 entries one of which is the
spread token. Resolve both files: 37 + 6 = **43**, a strict subset of react's 66,
gap = exactly 23.

## 7. Fence whitelist = 14, and the SECOND chat-block writer

```sh
git show origin/main:api/lib/barkpark/portable_doc/from_markdown.ex | sed -n '25,29p'
grep -rn 'FromMarkdown.blocks' api/lib/
```

`@allowed_fence_types` (from_markdown.ex:25-28) = 14, enforced by the single
`valid_fence_block?/1` at :136. Every `FromMarkdown.blocks/1` caller inherits it —
projection.ex:95, plan_papers.ex:49, chat_live.ex:5734/:5930, chat_controller.ex:1398,
gen_golden_transcript.ex. No non-Elixir markdown→blocks twin exists.

But `chat_controller.ex:1399+` / `render/components.ex:682-777` construct the six
`chat-*` blocks server-side from tool metadata — a second, non-markdown writer of
chat-turn blocks with its own scope. Chat-arrivable set = 14 ∪ 6 = **20**, not 14.
All six chat-* are already in mobile's 43, so this widens the mechanism, not the gap:
gap ∩ chat-arrivable is still `{chart, heatmap}`.
