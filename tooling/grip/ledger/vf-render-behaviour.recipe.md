# Re-derivation recipes — vf-render-behaviour (jarl dogfood wave, 2026-07-31)

Canonical `@barkpark/react` render behaviour proven by EXECUTION against the
source package (`js/packages/react/src`, worktree byte-identical to `origin/main`
for `src/toPlainText.ts` and `src/blocks/core.ts`), plus the live jarl paper.

`npx --no-install tsx` resolves from the pnpm workspace root — no install needed.

## R0 — the worktree really is main for the two load-bearing files

```bash
cd /Users/frikkjarl/Documents/GitHub/barkpark
git diff origin/main -- js/packages/react/src/toPlainText.ts js/packages/react/src/blocks/core.ts | wc -l
```
Expect `0`.

## R1 — the three mandated behaviours (spacing-law gap + dual-shape callout)

```bash
cd /Users/frikkjarl/Documents/GitHub/barkpark/js/packages/react
npx --no-install tsx -e "import {renderPortableDocument,toPlainText} from './src/index'; console.log(JSON.stringify(renderPortableDocument([{type:'paragraph',content:[]}]))); console.log(renderPortableDocument([{type:'callout',tone:'info',title:'T',text:'plain string'}])); console.log(renderPortableDocument([{type:'callout',tone:'info',title:'T',content:[{type:'text',value:'array shape'}]}]))"
```
Expect verbatim:
```
"<p></p>"
<div class="bp-callout bp-callout--info"><strong>T</strong> <span>plain string</span></div>
<div class="bp-callout bp-callout--info"><strong>T</strong> <span>array shape</span></div>
```
Source of the empty `<p>`: `js/packages/react/src/blocks/core.ts:470`
`const paragraph: Emit = (b) => `<p>${renderInlines(paragraphInline(b))}</p>`` —
unconditional, no `:empty` suppression anywhere.

## R2 — fetch the live jarl paper (read token from the site repo's .env.local)

```bash
cd /Users/frikkjarl/Documents/GitHub/jarl-website
set -a && . ./.env.local && set +a
curl -s -H "Authorization: Bearer $BARKPARK_READ_TOKEN" \
  "$BARKPARK_URL/v1/data/doc/production/paper/velkommen-til-jarl-no" -o /tmp/paper-doc.json \
  -w "HTTP %{http_code} bytes=%{size_download}\n"
```
Expect `HTTP 200 bytes=11849` (list twin: `.../v1/data/query/production/paper`,
`HTTP 200 bytes=11924`, 1 document).

## R3 — blocks-field truth (settles the two-surveyor contradiction)

```bash
node -e "
const d=require('/tmp/paper-doc.json').result;
console.log('top blocks:',Array.isArray(d.blocks)?'array len '+d.blocks.length:JSON.stringify(d.blocks));
console.log('body.blocks:',d.body&&Array.isArray(d.body.blocks)?'array len '+d.body.blocks.length:'n/a');
console.log('byteEqual:',JSON.stringify(d.blocks)===JSON.stringify(d.body&&d.body.blocks));
console.log('types:',d.blocks.map(b=>b.type).join(','));
console.log('empty paragraphs:',d.blocks.filter(b=>b.type==='paragraph'&&!(b.content||[]).length).length);
console.log('slug:',JSON.stringify(d.slug),'publishedAt:',JSON.stringify(d.publishedAt));"
```
Expect:
```
top blocks: array len 11
body.blocks: array len 11
byteEqual: true
types: eyebrow,heading,paragraph,paragraph,heading,paragraph,list,paragraph,table,paragraph,callout
empty paragraphs: 3
slug: undefined publishedAt: undefined
```
Top-level `blocks` is POPULATED and byte-equal to `body.blocks` on BOTH the doc
and the query endpoint. The "top-level blocks empty" survey claim is refuted.

## R4 — toPlainText over the real live blocks (excerpt viability)

```bash
cd /Users/frikkjarl/Documents/GitHub/barkpark/js/packages/react
npx --no-install tsx -e "
import {renderPortableDocument,toPlainText} from './src/index';
import fs from 'node:fs';
const b=JSON.parse(fs.readFileSync('/tmp/paper-doc.json','utf8')).result.blocks;
console.log('PLAINTEXT_LEN='+toPlainText(b).length);
console.log('EXCERPT160='+JSON.stringify(toPlainText(b).slice(0,160)));
const h=renderPortableDocument(b);
console.log('EMPTY_P_COUNT='+(h.match(/<p><\/p>/g)||[]).length);"
```
Expect `PLAINTEXT_LEN=904`, `EMPTY_P_COUNT=3`, and an excerpt beginning
`"Jarl · papers · første publisering\n\nDette er et Bulldocs-paper, …"` —
usable, but the eyebrow leads it. Filter `eyebrow` before slicing for feeds.

## R5 — the toPlainText content[]-shape drop (NEW finding, unpinned by tests)

```bash
cd /Users/frikkjarl/Documents/GitHub/barkpark/js/packages/react
npx --no-install tsx -e "
import {renderPortableDocument as R, toPlainText as T} from './src/index';
for (const t of ['eyebrow','heading','paragraph','pullquote','ingress','blockquote','callout']) {
  const b:any={type:t,level:2,content:[{type:'text',value:'CONTENT-SHAPE'}]};
  console.log(t.padEnd(11),'render='+JSON.stringify(R([b])).slice(0,60).padEnd(62),'plain='+JSON.stringify(T([b])));
}"
```
`heading` and `eyebrow` render their `content[]` fine but yield `""` from
`toPlainText` — the renderer was swept for the content[] defect (core.ts:44-49,
PR #6009) and `toPlainText` was NOT: `src/toPlainText.ts:200-202`
`case 'heading': case 'eyebrow': return str(b.text)`. Every other prose type uses
the dual-shape `proseContent`.

Why the 60-type golden suite stays green:
```bash
cat tests/fixtures/pd-golden/*heading*.golden.json | head -20   # input uses flat "text"
grep -n heading tests/fixtures/pd-plaintext-golden.ts            # heading: 'The render path'
```
The fixture pins the FLAT shape only. jarl's live headings are the content[]
shape → both headings vanish from any excerpt/meta-description built on
`toPlainText`. Fix is a one-word change (`str(b.text)` → `proseContent(b)`) plus
a content[]-shape golden case.
