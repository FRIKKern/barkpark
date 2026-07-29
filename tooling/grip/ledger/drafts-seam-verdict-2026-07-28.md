# Re-derivation recipes — drafts-seam verdict, public-read token, 2026-07-28

Verifier lane: `drafts-seam-verdict` (search-template W11 verify). Every row is one literal
command that re-derives the fact. Tree: `origin/main @ ab396959c`. Target: live guerrilla.

**The credential.** The assignment's `TOK=site-read-search-ember` is a token **LABEL**, not a
secret — `/v1/capabilities` answers `auth_tier: "none"` with it, so every probe run with that
string is an ANONYMOUS probe wearing a token's name. The real secret is
`UXOvtfPOUiJF7Bw4kAz3jVW3IDyHGoLBz6Ygj7NcpnE` (label `site-read-search-ember`,
permissions `{public-read}`), recorded in `tooling/grip/ledger/indx-flat-truth-2026-07-26.md:4`.
Every row below uses `TOK=UXOvtfPOUiJF7Bw4kAz3jVW3IDyHGoLBz6Ygj7NcpnE`.

| # | Fact | Rerun |
|---|---|---|
| 1 | The label is not a token: `auth_tier` is `none` | `curl -s -H 'Authorization: Bearer site-read-search-ember' https://guerrilla.barkpark.cloud/v1/capabilities \| python3 -c "import sys,json;print(json.load(sys.stdin)['auth_tier'])"` |
| 2 | `?perspective=drafts` on BOTH query route shapes is **403 `perspective not allowed`** for the public-read token — refused, not silently downgraded | `for u in /v1/data/query/production/paper /w/default/p/default/v1/data/query/production/paper; do curl -s -o /dev/null -w "$u %{http_code}\n" -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud$u?perspective=drafts&limit=3"; done` |
| 3 | A `drafts.`-prefixed id is **404** on the doc route for public-read token, scoped token AND anon | `for h in "Authorization: Bearer $TOK" "X-None: 1"; do curl -s -o /dev/null -w "%{http_code}\n" -H "$h" https://guerrilla.barkpark.cloud/v1/data/doc/production/task/drafts.lvw-t1; done` |
| 4 | `/v1/preview/doc` rejects the public-read token — **401**, preview needs a preview JWT | `curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" https://guerrilla.barkpark.cloud/v1/preview/doc/production/post/drafts.foo` |
| 5 | `/v1/graph?perspective=drafts` is **200 but byte-identical** to published and raw (480,699 B, 1796 nodes, 941 edges) — the corpus action hard-pins `:published` | `for p in '' '&perspective=drafts' '&perspective=raw'; do curl -s -o /dev/null -w "$p %{http_code} %{size_download}\n" -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud/v1/graph?dataset=production$p"; done` |
| 6 | Mechanism for row 5: `graph_corpus/2` sets `list_opts = Keyword.put(opts, :perspective, :published)`, never reading `params["perspective"]` | `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| sed -n '954,975p'` |
| 7 | **LEAK (live)**: `/v1/graph/:id` at the DEFAULT perspective returns a draft-only document's real title + doc_id to the public-read token | `curl -s -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/graph/lvw-t1?dataset=production&depth=2' \| python3 -m json.tool \| head -12` |
| 8 | Mechanism for row 7: `resolve_graph_root/2` matches `doc_id == pub_id OR doc_id == draft` and only PREFERS published — with no published twin the draft row wins | `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| sed -n '1104,1128p'` |
| 9 | Blast radius of row 7: **131** draft-only doc ids (no published twin) exist in `production` | see row 11's export, then `python3 -c "…drafts-minus-published set difference…"` |
| 10 | `?perspective=drafts` on `/v1/graph/:id` does NOT leak — it returns a bare untyped phantom node (`type: null`) | `curl -s -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/graph/lvw-t1?dataset=production&perspective=drafts&depth=2'` |
| 11 | **LEAK (live, larger than D83 recorded)**: the browser-shipped public-read token downloads the FULL corpus export — 64,589,544 B NDJSON, **3,000 documents, 132 drafts**, private types (`task` 2382, `ticket`, `sheet`, `metric`) | `curl -s --max-time 300 -H "Authorization: Bearer $TOK" https://guerrilla.barkpark.cloud/v1/data/export/production -o /tmp/exp.json -w '%{http_code} %{size_download}\n'; python3 -c "import json,collections;t=collections.Counter();n=0;d=0;\nimport io\nfor l in open('/tmp/exp.json'):\n l=l.strip()\n if not l: continue\n x=json.loads(l);n+=1;t[x.get('_type')]+=1\n if str(x.get('_id','')).startswith('drafts.'): d+=1\nprint(n,d,dict(t))"` |
| 12 | Why row 11 is possible: `PublicRead` only allowlists `query`/`doc`, and it is NOT mounted on the `[:api, :require_token]` scope that carries `export`/`graph` | `git show origin/main:api/lib/barkpark_web/plugs/public_read.ex \| sed -n '68,80p'; git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '1697,1712p'` |
| 13 | `/v1/graph` reports `truncated: true, truncation_reason: "per_type_cap"` on the live corpus (D67 capped-count case is LIVE, not hypothetical) | `curl -s -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/graph?dataset=production' \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['truncated'],d['truncation_reason'],len(d['nodes']))"` |
| 14 | `/v1/graph` latency measured warm on an otherwise-idle host: **4.41 / 4.57 / 4.80 s** (three consecutive calls) — refutes both the 2.5–3.6 s and the 28–36 s survey readings | `for i in 1 2 3; do curl -s -o /dev/null -w '%{time_total}\n' -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/graph?dataset=production'; done` |
| 15 | The `stw7` search clamp HOLDS: scoped search returns count 298 and ZERO draftish docs at published, drafts AND raw | `for p in published drafts raw; do curl -s -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud/w/default/p/default/v1/data/search/production?q=deploy&engine=postgres&limit=100&types=paper&perspective=$p" \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['count'],sum(1 for x in d['documents'] if x.get('_draft')))"; done` |

| 16 | **FAIL-BROKEN ORACLE** — the row-3 404 is the CLAMP, not absence: the same id under an admin token is **200 / 9,838 B with `"_draft": true`** | `curl -s -H "Authorization: Bearer $(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")" https://guerrilla.barkpark.cloud/v1/data/doc/production/task/drafts.lvw-t1 \| head -c 200` |
| 17 | Both commits the assignment names ARE ancestors of `origin/main` | `for s in 450fa68f2 9a92d85a3; do git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done` |
| 18 | `stw10-backlog-drafts-id-seam` is still `published`/p0/unclaimed with 3 criteria at `met:false` | `bp task get stw10-backlog-drafts-id-seam -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['status'],d['priority']);[print(c['met'],c['criterion'][:80]) for c in d['content']['acceptance_criteria']]"` |

## Verdict for `stw10-backlog-drafts-id-seam` (p0)

**CLOSE IT — the premise is false against main.** Criterion 1 ("a public-read token cannot
retrieve a draft document by `drafts.`-prefixed id on the scoped doc route, the flat doc route…")
is SATISFIED on the live flagship: rows 3 + 16 show 404 for the public-read token and 200 for
admin on the identical id. Mechanism: `9a92d85a3` (#6270) made `AnonPerspective.anon_pinned?/1`
true for public-read tokens, which arms the first `cond` clause of `QueryController.show/2`
(landed `450fa68f2`, 2026-06-09 — seven weeks BEFORE the row was filed). Criteria 2 and 3 are
test/parity obligations, not defects; they are payable by a regression test, not a fix.

## The seam that is REAL, and it is not the one filed

`/v1/graph/:id` discloses draft-only documents to the browser-shipped token — **not** via
`?perspective=drafts` (row 10: that path yields a bare untyped phantom), but via
`resolve_graph_root/2`'s published-preferred-else-draft fallback at the DEFAULT perspective
(rows 7 + 8). 131 draft-only doc ids are reachable this way (row 9). `/v1/graph` is behind
`[:api, :require_token]` with no `PublicRead` mount (row 12), and anon gets 401 — so the ONLY
credential that reaches it is the one the flagship inlines into every visitor's bundle.

`task-d223068f55efbf47`'s criterion 1 as written ("`/v1/graph/:id?perspective=drafts` returns
draft rows BEFORE the fix") is UNREPRODUCIBLE and must be rewritten to the root-fallback
mechanism, or the slice will be built against a live repro that does not exist.

## Bigger than both: the export leak is live and has grown

Row 11. The same browser-shipped token downloads **3,000 documents / 132 drafts / 64.6 MB**,
including `task` (2,382), `ticket`, `sheet` and `metric`. Charter D83 recorded this at 49,819,823 B
/ 2,400 docs / 129 drafts; it is now larger. This outranks both graph findings on the
"starter hands out the key" axis.

## Note for the ledger-honesty beat

Row 15 REFUTES `indx-flat-truth-2026-07-26.md` row 7 ("the public-read site token reads a DRAFT
via `perspective=drafts` on the scoped search route"). That row was true on 2026-07-26 and is
false today: `AnonPerspective.public_read_token?/1` membership-pins the token to `:published`.
The 2026-07-26 row should be marked SUPERSEDED, not deleted.
