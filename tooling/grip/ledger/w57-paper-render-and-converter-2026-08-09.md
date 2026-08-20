# W57 — the hollow paper body, and the converter's real population (2026-08-09)

Re-derivation recipes for the wave-57 verifier lane `paper-render-and-converter`.
Every row is a command that reproduces the finding from scratch on a clean
checkout of `origin/main`.

## 1. The hollow body is an INLINE LEAF KEY defect, not a patch/type/count defect

PortableDoc's text leaf is `{"type":"text","value":"…"}`. The renderer reads
**only** `value`; there is no `text` fallback anywhere:

```bash
git show origin/main:api/lib/barkpark/portable_doc/render/inline.ex | sed -n '29,45p'
git show origin/main:api/lib/barkpark/portable_doc/render/inline.ex | grep -n '"text"'   # → one hit: the TYPE match, never a key read
git show origin/main:docs/contracts/portable-doc-inline.md | sed -n '11p'                # → {"type": "text", "value": "12 weeks"}
```

Census of wave 57's own Paper — 306 of 306 leaves carry `text`, zero carry `value`:

```bash
bp doc get paper cloud-console-hardening-wave-57-2026-08-09 -o json > /tmp/w57.json
python3 -c '
import json
from collections import Counter
d=json.load(open("/tmp/w57.json")); c=Counter()
def walk(n):
    if isinstance(n,dict):
        if n.get("type")=="text": c[("value" if "value" in n else "")+("+text" if "text" in n else "")]+=1
        for v in n.values(): walk(v)
    elif isinstance(n,list):
        for v in n: walk(v)
walk(d["blocks"]); print(dict(c))'
```

### The A/B probe (throwaway paper, both dialects in ONE publish)

Create a paper whose blocks mix `value`-keyed and `text`-keyed leaves across
paragraph / list / callout / table, publish, then read `body_html` back. Every
`value` leaf renders; every `text` leaf renders as an empty `<span>` (and a
paragraph whose only leaf is `text`-keyed is dropped entirely). Patched-in
blocks behave identically to created ones — the PATCH path is innocent.

```bash
# create (note: the publish wall needs a real description + REGISTERED weighted tags)
bp doc mutate --file /tmp/probe_create.json --yes
# patch more blocks in
bp doc patch paper <slug> --set "blocks:=$(cat /tmp/probe_blocks2.json)"   # NB: --set has NO @file support
bp doc publish paper <slug>
bp doc get paper <slug> -o json --perspective published | python3 -c 'import sys,json;print(json.load(sys.stdin)["body_html"])'
bp doc delete paper <slug> --yes
```

Observed `body_html` (10 blocks, 5 dialect pairs):

```
<h2>W57 render probe — throwaway</h2><p>PARA_VALUE_DIALECT_SENTINEL …</p><h2>Patched-in section</h2><p>PATCHED_VALUE_SENTINEL …</p><ul><li><span>LIST_VALUE_SENTINEL one</span></li><li><span></span></li></ul><div class="bp-callout bp-callout--info"><span>CALLOUT_VALUE_SENTINEL</span></div><div class="bp-callout bp-callout--info"><span></span></div><table …><tr><td …><span>TBL_VALUE_SENTINEL</span></td><td …><span></span></td></tr></table>
```

### The producer

`.claude/workflows/bp-epic-cycle.workflow.js:149` is the ONLY block-authoring
instruction the wave-Paper author receives, and its single example is
`{"type":"paragraph","content":[]}` — an EMPTY content array. The prompt teaches
the block dialect and is silent on the inline leaf key, so the author reaches for
TipTap's near-universal `text`.

```bash
grep -n 'MECHANICAL SPACING' .claude/workflows/bp-epic-cycle.workflow.js
```

## 2. The 422 population is 38 (+1), not "21 convertible"

```bash
bp doc query paper --fields blocks,body,body_html --perspective published --all -o json > /tmp/all.json
python3 -c '
import json
d=json.load(open("/tmp/all.json"))["documents"]
nb=[x for x in d if not isinstance(x.get("blocks"),list)]
print("published",len(d),"| no blocks",len(nb),
      "| html_only",len([x for x in nb if x.get("body_html")]),
      "| candidates",len([x for x in nb if not x.get("body_html")]))'
```

→ `published 735 | no blocks 66 | html_only 28 | candidates 38`

Plus `cloud-console-hardening-wave-46-2026-08-07`, which is html_only AND 422:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/papers/cloud-console-hardening-wave-46-2026-08-07
```

## 3. Running the converter outside a repo checkout

`prosemirror-to-blocks.mjs:26` imports `../../api/assets/paper-editor/src/convert.js`.
Copying the tool to a flat scratch dir makes it `ERR_MODULE_NOT_FOUND`. Mirror the
repo shape instead:

```bash
mkdir -p /tmp/mirror/tooling && cp -R <src>/paper-repair /tmp/mirror/tooling/
ln -sfn /Volumes/SATECHI/github/barkpark/api /tmp/mirror/api
node /tmp/mirror/tooling/paper-repair/repair-paper-blocks.mjs $(cat /tmp/cand_slugs.txt | tr '\n' ' ')
```

## 4. The deltas are load-bearing — mutation proof against `paper-repair-orig`

Same 38 slugs, pre-delta tool:

```bash
node /tmp/mirror-orig/tooling/paper-repair/repair-paper-blocks.mjs $(cat /tmp/cand_slugs.txt | tr '\n' ' ') > /tmp/orig.txt; echo $?
grep -c "SKIP body is not a ProseMirror doc" /tmp/orig.txt   # → 16
grep -c "dry-run (pass --apply" /tmp/orig.txt                # → 22
```

Patched: 38/38 convert, all `IDENTICAL`, exit 0.

## 5. THE GUARD THAT CANNOT LOSE (both tool versions)

`repair-paper-blocks.mjs` `continue`s on SKIP and on REFUSE **without**
`failures++`. The pre-delta run above skipped 16 papers and still `exit 0`.
A run that skips its entire population is indistinguishable from a run that
repaired it.

And the original's refusal prints a sentence that is false about
`cloud-console-hardening-wave-46-2026-08-07`:

```
  REFUSE html_only paper — it renders today; writing blocks would arm its divergence 422
```

…about a paper that answers **422**. The PROBE-C delta replaces the assertion
with a measurement (`readerStatus(slug)`), which is the shape the guard should
have had from the start.
