# Notes grammar freeze — re-derivation recipe (pe wave 6, 2026-08-17)

Verifier: notes-grammar-freeze-dossier. All anchors from origin/main (local checkout is behind).

## 1. Corpus shape census (re-derive)

```bash
S=$(mktemp -d)/notes && mkdir -p $S/json
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -s -H "Authorization: Bearer $TOK" \
  "https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=2000&fields=_id" \
  | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r['count']);open('$S/slugs.txt','w').write('\n'.join(sorted(x['_id'] for x in r['documents']))+'\n')"
# => 780 (2026-08-17; the denominator MOVES — pin at fetch time, D37)
# fetch: xargs -P 16 over "https://guerrilla.barkpark.cloud/papers/$slug/source" -o $S/json/$slug.json
# JSON route this run: 707x200 43x422 30x500 (the 500s include pds-wave-* — census misses those papers)
```

Walk every fetched `source.blocks` recursively (children under blocks/steps/children/nodes).
Measured this run (687 blocks-kind papers parsed):

- `notes` (grid): 100 papers, 447 blocks, 2665 items = 2658 dict + 5 str + 2 list + 0 other.
- Every dict item keyset is EXACTLY {label, lead, text} (2658/2658). Body key is `text`, never `body`.
- PLAINNESS: 0 items carry `slots`; 0 note widgets carry `slots`; 0 non-string label/lead/text values.
  (No separate plainness-census ledger row existed at fly time — this run IS the measurement.)
- Empty fields: text=="" 79, label=="" 0, lead=="" 2.
- 5 str items: heggemsnes-act block `hga-remedies` (the testimony remedies). 2 list items
  (ProseMirror inline arrays): epic-paper-beauty-reference-wave-2026-07-31 block `local-suite-note`.
- Singular `note` widget: 9 papers, 34 blocks — 33 x {id,label,lead,text}, 1 x {content,id,type}
  (barkpark-tasks-mobile-wave-2026-07-23 block w1-223 — a content-keyed note; accessors read it as "").
- Nesting: 292/447 notes blocks inside `expandable`, 139 top-level, 16 inside `section`.

## 2. Unlock simulation (origin/main printer semantics, NOT the live server)

Static python twin of printer.ex@origin/main (kernel 16 JSON types + heading level int 1..3,
marks {strong,em,code,underline,strike}, inline {text,link,code,strong,em,str} + smuggling guards,
head-cell list|{text}|str) over the 687 fetched papers:

| variant | printable | delta over kernel(422) |
|---|---|---|
| kernel today | 422 | — |
| + notes, str items REFUSE | 470 | +48 |
| + notes, str items escape-verbatim | 471 | +49 (adds heggemsnes-act exactly) |
| + notes + singular note | 473 | +51 (adds barkpark-tasks-mobile-state, -chat-third-client) |

The charter's "+35" (L99) and the digest's "notes-marginal=5" are both superseded: 5 was measured
against the LIVE server, which serves 0ff6fae — and `git merge-base --is-ancestor 23b08c1211 0ff6fae`
FAILS: the deployed slot PREDATES #11814, still refuses `strong` inline nodes (proven live:
personal-agent-provider-bridge 422 "inline node type \"strong\""), so live rechecks undercount until a
post-#11814 deploy. D37's provenance guard (serving sha must contain #11814) is UNSATISFIABLE against
today's live slot.

## 3. Anchors (all `git show origin/main:<path>`)

- parser.ex: @block_attrs L11-42; aside hint L48; @known_block_tags L61 (18 tags);
  build_block("stats") L257-274 (the precedent: attrs on child + tag_text body + empty-body drop);
  insert notes AFTER L274 / before "steps" L276; put_attr L838 (present-only); tag_text L368-370.
- printer.ex: stats clause L85-92 (insert notes after); attr_str L271-278 (nil→omit, ""→prints k="");
  bare-string precedents: inline_node/1 str L~224, inline/1 str, head_cell/1 str L177-179;
  catchall raise L156.
- slots.ex: slot_decls note L128-134 (label/body required, lead {:max,1}); field_vocab L213
  (consumed: label lead text slots); legacy_slot note L252-262 (body→flat `text`); catch-all
  legacy_slot(_,_)→[] ; note_flat non-map→"" ; normalize_widget note L501-517 (flat⇄slots
  idempotent dual-write — flat keys ALWAYS mirror slots for widgets).
- bpml.ex vocabulary() L73-90: known_block_tags ++ explicit child list — a known-tag `note` flows
  automatically; a child-only `note` must be added to the explicit list.
- bpml_test.exs: iso test L478-495 asserts `parsed == blocks` (JSON equality — generator must not
  emit text:"" since parse drops the empty body key); gen_blocks L498 (1..10);
  section nest L562 (1..9). hr/expandable NEVER entered the generator (#11814 debt).
- Web leg: compose.ex notes L1099 / note L1135; components.ex notes_html/note_item_html L462-506
  (total; non-map item → empty row bytes). TUI leg: pdrender.go L394 note + gridblocks.go L53
  notesRenderer; itemMaps DROPS non-object items.
- Contention: PR #11770 (OPEN) touches parser.ex, printer.ex, bpml.ex, tiers.ex, compose.ex,
  pdrender.go — notes tier lands serially with it.
