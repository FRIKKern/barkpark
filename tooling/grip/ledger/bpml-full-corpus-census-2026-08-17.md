# BPML full-corpus census — re-derivation recipe (2026-08-17)

Replaces the ±8pp 120-paper sample with all 776 published papers on guerrilla.

## 1. The slug list (776, type is `paper`, NOT `bulldoc` — bulldoc has 1 doc)

```bash
S=/tmp/bpmlcensus && mkdir -p $S/json
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -s -H "Authorization: Bearer $TOK" \
  "https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=2000&fields=_id" \
  | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r['count']);open('$S/slugs.txt','w').write('\n'.join(sorted(x['_id'] for x in r['documents']))+'\n')"
# => 776
```

## 2. The census (anonymous — the reader route is published-only either way; ~12s at -P16)

```bash
cat > $S/fetch.sh <<'EOF'
#!/bin/bash
S="$1"; slug="$2"
body=$(curl -s -m 60 -w "\n__STATUS__%{http_code}" "https://guerrilla.barkpark.cloud/papers/$slug/source?format=bpml")
code="${body##*__STATUS__}"; payload="${body%$'\n'__STATUS__*}"
if [ "$code" = 200 ]; then printf '%s\t200\t\n' "$slug"; else
  msg=$(printf '%s' "$payload" | python3 -c "
import sys,json
t=sys.stdin.read()
try:
  e=json.loads(t).get('error',{}); print((e.get('code','?')+'|'+(e.get('message','') or '')).replace(chr(9),' ')[:300])
except Exception: print('nonjson|'+t.replace(chr(10),' ')[:120])")
  printf '%s\t%s\t%s\n' "$slug" "$code" "$msg"; fi
EOF
chmod +x $S/fetch.sh
xargs -P 16 -I{} $S/fetch.sh $S {} < $S/slugs.txt > $S/census.tsv
cut -f2 $S/census.tsv | sort | uniq -c        # 349 422 / 285-286 200 / 141 500
grep -P '\t422\tbpml_unprintable' $S/census.tsv | cut -f3 | sort | uniq -c | sort -rn
```

NOTE: expect ~1 transient curl `000` per run (a 60s timeout under -P16); retry those slugs
individually — the two that appeared retried 200. Do not count `000` as a class.

## 3. The ranked ADDITIONS list (first-blocker frequency is biased; use true prevalence)

The 422 message names only the FIRST offending type per paper. For the kernel-addition order,
pull the block truth and count against the printer's 14-type vocabulary:

```bash
cat > $S/fj.sh <<'EOF'
#!/bin/bash
curl -s -m 60 "https://guerrilla.barkpark.cloud/papers/$2/source" -o "$1/json/$2.json" -w "$2 %{http_code}\n"
EOF
chmod +x $S/fj.sh; xargs -P 16 -I{} $S/fj.sh $S {} < $S/slugs.txt > $S/json_status.txt
# 672 x 200 + 104 x 422 — the 104 are exactly the non-printer 422 classes minus the 31
# bpml_unavailable (html-kind papers, which DO serve format=json).
```

Kernel vocabulary (`api/lib/barkpark/portable_doc/bpml/printer.ex:45-125`):
eyebrow, heading(level ∈ 1..3 as an INTEGER), paragraph, pullquote, ingress, byline, callout,
list, code, diagram, stats, steps, table, section. Inline: `inline_node/1` handles only
`text` and `link`; `mark_tag/1` only strong|em|code|underline|strike; `head_cell/1` only
list|map. Everything else in those three functions raises FunctionClauseError — and
`send_bpml/2` rescues ONLY ArgumentError (`bulldocs_source_controller.ex:104`), so those
become HTTP 500 with an opaque HTML error page.

Walk each paper's blocks recursively (children live under `blocks`, `items`, `steps[].blocks`,
`content`, table `head`/`rows`), then run a greedy set-cover over the non-kernel types to get
the unlock curve. 68 distinct non-kernel block types exist in the corpus.

## 4. Numbers this run produced (2026-08-17, guerrilla)

| class | n | % |
|---|---|---|
| 200 | 286 | 36.9 |
| 422 bpml_unprintable | 214 | 27.6 |
| 500 | 141 | 18.2 |
| 422 ambiguous_source | 59 | 7.6 |
| 422 semantic_empty | 42 | 5.4 |
| 422 bpml_unavailable | 31 | 4.0 |
| 422 invalid_blocks | 3 | 0.4 |

500 cause attribution: 113 unknown inline node type (`code` 87, `strong` 84, `em` 34,
`paragraph` 20, `valueref` 12 papers), 18 raw-string inline child, 16 `inline/1` called on a
non-list (string table cell / string list item), 6 bare-string table head cell; 0 unexplained.
79 of the 141 have NO non-kernel block type — the inline fix alone turns those into 200.

Greedy unlock curve (papers with ≥1 non-kernel block type = 272):
divider 38 → expandable 103 → notes 138 → cards 146 → heading(level) 169 → toc 176 →
pipeline 178 → terminal 183 → stat-grid 193 → quote 206 → task-list 209 → action 218 →
image 223 → chart 226 → columns 227(45 left) … 68 additions to reach 0.

`heading` level is a STRING in 220 occurrences ('3' 102, '2' 109, '1' 9) and an id-like string
in 12 — a `level` coercion is worth 23 papers on its own.

eight-minute-erasure (the authoring guide's worked example) returns **500**, not 422: its first
offender in document order is an inline `code` node inside a table cell (block 3, row 0, col 0).
After a fail-honest fix it will 422 `bpml_unprintable` on figure/asciicast/columns/expandable.
