# v5 — malformed-shape census of the live paper corpus (2026-08-12)

Re-derivation recipes for the refuse-vs-normalize decision on the wall arm
(Paper Excellence wave 1, verifier v5).

## 0. Pull the corpus (756 published papers, ~129 MB)

```bash
S=$(mktemp -d)
TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
curl -s -H "Authorization: Bearer $TOK" \
  'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=1000' -o "$S/papers.json"
python3 -c "import json;d=json.load(open('$S/papers.json'))['result'];print(d['count'],d['perspective'])"
# -> 756 published
```

RENDER SOURCE IS `blocks` (top-level), not `body`. `Barkpark.Content.Papers`
renders `content["blocks"]` (api/lib/barkpark/content/papers.ex:106, :190).
A census that walks `body` double-counts and reports shapes nothing renders.

## 1. Non-map items in map-requiring blocks

```bash
python3 - "$S/papers.json" <<'PY'
import json,sys,collections
D=json.load(open(sys.argv[1]))['result']['documents']
REQ={'notes':['items'],'cards':['items'],'pipeline':['nodes'],'stats':['items'],
     'timeline':['items'],'checklist':['items'],'lineage':['items','nodes'],
     'filetree':['items','files'],'byline':['items']}
nm=collections.Counter(); nmd=collections.defaultdict(set)
def w(n,d):
    if isinstance(n,dict):
        t=n.get('type')
        if isinstance(t,str):
            for k in REQ.get(t,[]):
                v=n.get(k)
                if isinstance(v,list):
                    for it in v:
                        if not isinstance(it,dict):
                            key=(t,k,type(it).__name__); nm[key]+=1; nmd[key].add(d)
        for v in n.values(): w(v,d)
    elif isinstance(n,list):
        for v in n: w(v,d)
for p in D:
    if isinstance(p.get('blocks'),list): w(p['blocks'],p['_id'])
for k,c in sorted(nm.items(),key=lambda x:-x[1]):
    print(k,'n=%d papers=%d'%(c,len(nmd[k])),sorted(nmd[k])[:4])
PY
```

Expected 2026-08-12: `byline/items/str n=771 papers=215` (CANONICAL — see §3),
`notes/items/str n=5 papers=1` (heggemsnes-act),
`notes/items/list n=2 papers=1` (epic-paper-beauty-reference-wave-2026-07-31).
`cards` and `pipeline`: ZERO.

## 2. Inline `type:"text"` leaves without `"value"`

```bash
python3 - "$S/papers.json" <<'PY'
import json,sys,collections
D=json.load(open(sys.argv[1]))['result']['documents']
tk=collections.Counter(); vl=collections.Counter(); other=set()
def w(n,d):
    if isinstance(n,dict):
        if n.get('type')=='text':
            if 'value' in n: vl[d]+=1
            elif 'text' in n: tk[d]+=1
            else: other.add(d)
        for v in n.values(): w(v,d)
    elif isinstance(n,list):
        for v in n: w(v,d)
for p in D:
    if isinstance(p.get('blocks'),list): w(p['blocks'],p['_id'])
for k,v in sorted(tk.items(),key=lambda x:-x[1]): print('%-45s text=%-5d value=%d'%(k,v,vl.get(k,0)))
print('non-inline type:text (quiz questions, benign):',sorted(other))
PY
```

Expected 2026-08-12: TEN papers, four of them 100% hollow. The four in `other`
are quiz `questions[]` nodes (`{"id","prompt","type":"text"}`) — a question
FORMAT marker, never routed through `Render.Inline`; do not repair them.

## 3. Prove which shapes the renderer honours (mutation, not reading)

```bash
cd api && cat > /tmp/probe.exs <<'EOF'
alias Barkpark.PortableDoc.Render
o = %{style: :article, embeds: %{}}
IO.puts Render.render_blocks([%{"type"=>"list","items"=>[%{"text"=>"ITEMTEXT"}]}], o)
IO.puts Render.render_blocks([%{"type"=>"paragraph","content"=>[%{"type"=>"text","text"=>"LEAFTEXT"}]}], o)
IO.puts Render.render_blocks([%{"type"=>"paragraph","content"=>[%{"type"=>"text","value"=>"LEAFTEXT"}]}], o)
IO.puts Barkpark.PortableDoc.Render.Components.notes_html(%{"type"=>"notes","items"=>["A","B"]})
IO.puts Barkpark.PortableDoc.Render.CardsEmail.notes_email_html(%{"type"=>"notes","items"=>["A","B"]})
IO.puts Barkpark.PortableDoc.Render.CardsEmail.notes_email_html(%{"type"=>"notes","items"=>[]})
IO.inspect Barkpark.Content.Papers.BlockOps.validate_render_shapes(
  [%{"type"=>"byline","items"=>["a","b"]}])
EOF
MIX_ENV=dev mix run --no-start /tmp/probe.exs
```

Verdicts: `"text"` renders at LIST-ITEM and TABLE-CELL level but is DROPPED at
inline-leaf level (`render/inline.ex:36` reads `Map.get(n,"value","")`, no
fallback). `notes` string items emit STRUCTURALLY PRESENT, TEXTUALLY EMPTY rows
on BOTH web and email — `notes_email_html` never reaches `empty_email/2`, which
fires only on `items == []`. The wall returns `:ok` for all three shapes and
`normalize_render_shapes/1` leaves them byte-unchanged.

## 4. Live confirmation of a hollow paper

```bash
curl -s https://guerrilla.barkpark.cloud/papers/deploy-reliability-wave-4-2026-08-06 | grep -c '<h2></h2>'
# -> 22 empty headings on a 200-answering page
```

## 5. Email-variant blast radius

```bash
grep -rn 'CardsEmail\|FleetEmail\|PanelsEmail' api/lib cloud 2>/dev/null | grep -v '/render/'
# -> ZERO hits outside api/lib/barkpark/portable_doc/render/; cloud has none.
```
The email emitters are reached only from `Render.Compose` when `style != :article`
(`compose.ex:95-190`), i.e. for a PAPER BODY whose stored style is not "article"
(`content/labels.ex:164-167`; `Render` default style is `:email`, render.ex:148).
32 published papers are non-article, and NONE of them contains a
notes/note/cards/card/pipeline/stage/tasks/task-board/terminal block — so today
the email arm renders ZERO live paper bytes.

## 6. Prior art

`bp task get cch-w57-bl-eleven-papers-render-200-with-prose-the-reader-drops`
— lifecycle_status `open`, priority 1, parent `cloud-console-hardening-epic`,
measured ELEVEN papers over 735. One (cloud-console-hardening-wave-57-2026-08-09)
has since been repaired (0 text / 473 value); the other ten are unrepaired.
