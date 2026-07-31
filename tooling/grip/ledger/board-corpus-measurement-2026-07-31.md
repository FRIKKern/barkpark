# Re-derivation recipes — board-corpus-measurement (platform-followups wave, 2026-07-31)

Verifier lane: turn the EdgeProjector arithmetic from carried estimate into measurement.
Real corpus numbers off guerrilla (admin tier) + the exact code constants the ~16k-query
and limit-1000-truncation claims rest on.

Server: `https://guerrilla.barkpark.cloud`, dataset **production** (the only populated
dataset — `staging` is `total_documents: 0`). Token from `~/.config/barkpark/config.json`.
Code rows read `origin/main` so they never quote a dirty worktree.

Shell prelude for the curl rows:

    TOK=$(jq -r '.token' ~/.config/barkpark/config.json)
    SRV=$(jq -r '.server' ~/.config/barkpark/config.json)

| # | Claim | Command |
|---|---|---|
| 1 | Production corpus is **5130 documents**, 4709 published / 421 drafts, 17 types | `bp dataset stats -o json \| jq 'del(.recent_activity) \| {total_documents, pub:([.types[].published]\|add), drafts:([.types[].drafts]\|add), ntypes:(.types\|length)}'` |
| 2 | **task = 4238 total (3902 published, 336 drafts)** — the wave's "4k tasks" is right; **paper = 631 total (613 published)** | `bp dataset stats -o json \| jq -c '.types[] \| select(.type=="task" or .type=="paper")'` |
| 3 | Bundled published-only counts agree: `{"task":3902,"paper":613,"tag":154,"command":22,"session":6,"metric":6,"document":4,"bulldoc":1,"listener":1}` | `bp data counts -o json` |
| 4 | `bp doc ls <type> --count` / `bp doc query <type> --count` DO NOT WORK — `count` is declared in the capabilities manifest but the CLI ignores it and streams full documents (761 KB for one call). No operator path to a filtered count. | `bp doc ls task --count -o json \| head -c 200` (→ `{"count":100,"documents":[…]}`) · `bp capabilities \| jq -r '.commands[] \| select(.[0]=="doc" and .[1]=="ls")'` (→ `["count","bool"]` declared) |
| 5 | `limit: 1000` in the projector is NOT a projector choice — `list_documents` HARD-CAPS at 1000 (`\|> min(1000)`), default order `:updated_at_desc`. The rebuild window is "the 1000 most-recently-updated published docs of that type". | `git show origin/main:api/lib/barkpark/content/query.ex \| sed -n '56,62p'` |
| 6 | Truncation bites **exactly one type**: task (3902 published > 1000). **2902 of 3902 published tasks (74.4%) sit outside any single rebuild corpus.** Every other type is under the cap (paper 613 is the largest). | rows 3 + 5 compared |
| 7 | Live proof the cap fires: the whole-dataset graph returns `truncated: true, truncation_reason: "per_type_cap"`, with **task nodes = exactly 1000** and paper = 613 (uncapped) | `curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph?dataset=production" \| jq '{truncated,truncation_reason,nodes:(.nodes\|length),edges:(.edges\|length)}'` · `… \| jq '[.nodes[].type]\|group_by(.)\|map({type:.[0],n:length})\|sort_by(-.n)'` |
| 8 | The live corpus extract yields **970 core reference edges** over 1811 nodes, kinds `parent_id 953 / sessions 12 / transcript 3 / related 2` — core fan-out is ≈0.95 edges per task and essentially nothing else | `curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph?dataset=production" \| jq '[.edges[].kind]\|group_by(.)\|map({kind:.[0],n:length})\|sort_by(-.n)'` |
| 9 | **947 orphans** (zero inbound + zero outbound in the materialised `content_edges`) out of 4709 published docs. `Graph.orphans/1` is UNBOUNDED (no limit, whole published corpus), so this is a true global number. | `curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph/orphans?dataset=production" \| jq '.orphans\|length'` · `git show origin/main:api/lib/barkpark/content/graph.ex \| sed -n '807,820p'` |
| 10 | Orphan split refutes "limit-1000 starves the graph": **paper 531 / 613 = 86.6% orphan even though papers are NOT truncated**, while task is only **234 / 3902 = 6.0% orphan** despite being the one truncated type | `curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph/orphans?dataset=production" \| jq '[.orphans[].type]\|group_by(.)\|map({type:.[0],n:length})\|sort_by(-.n)'` |
| 11 | Sampled materialised depth-1 fan-out: **1.92 edges/task** (39/40 connected) on a spread sample (every 25th task node); the naive "first 40" sample gives 11.4 and is hot-hub biased — do not quote it | see `spread sample` recipe below |
| 12 | **64 dangling references** (targets unresolvable under the published lens — unstorable, so they never reach `content_edges`) | `curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph/dangling?dataset=production" \| jq '.dangling\|length'` |
| 13 | The projector's per-doc N+1 is the **exact pathology `/v1/graph` already fixed and the projector did not**: `extract_edges/2` re-reads `list_schemas` per document unless the caller passes `:schemas`; `Projector.edges_for_doc/2` passes only `dataset/workspace_id/project_id/require_workspace` — no prefetch | `git show origin/main:api/lib/barkpark/content/edges.ex \| sed -n '266,280p'` · `git show origin/main:api/lib/barkpark/edge_projector/projector.ex \| grep -n 'defp edges_for_doc' -A 10` |
| 14 | In-tree MEASURED query numbers (the only ones that exist): **4096 identical schema queries → a measured 34s first paint**, and **"one derivation already costs ~9.6k queries"** for the capped corpus. The wave's "~16k" appears in NO code comment and NOT in the incident record. | `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| sed -n '1020,1024p'` · `… \| sed -n '992,997p'` |
| 15 | `add_edges/2` is `Enum.map` → `add_edge/4` per edge; each edge costs **4 queries** (2× `resolve_doc_pk` + insert + `fetch_content_edge!`). No batching. | `git show origin/main:api/lib/barkpark/content/edges.ex \| sed -n '578,607p'` · `… \| sed -n '427,462p'` |
| 16 | `hydrate_task_edges/1` adds another per-doc query (`Tasks.edges`) PLUS one `Repo.get(Document, to_pk)` per task_edge row — DB work inside what the moduledoc calls the pure projection's feeder | `git show origin/main:api/lib/barkpark/plugins/tasks.ex \| sed -n '1307,1341p'` |
| 17 | Derived query budget for ONE `rebuild types:["task"]` job, using rows 8/11/13/15/16 with a 1000-doc corpus: 1 list + 1000 hydrate + ~1900 hydrate `Repo.get` + 1000 `list_schemas` + ~950 `resolve_target_existence` + 4 × ~2850 edges ≈ **~16k queries** — the carried figure is CORRECT, but only now measured | rows 8, 11, 13, 15, 16 |
| 18 | That job runs at `edge_projector: 2` concurrency against a Repo pool of **`POOL_SIZE` default 10**, shared with 9 declared Oban queues totalling 29 slots | `git show origin/main:api/config/config.exs \| sed -n '271,281p'` · `git show origin/main:api/config/runtime.exs \| grep -n POOL_SIZE` |
| 19 | The incident record itself claims **20s** rebuild jobs and 15000ms DBConnection checkout kills — it never states a query count | `bp task get guerrilla-task-mutate-pool-saturation -o json \| jq -r '.doc.content.description'` |
| 20 | `production` is the only populated dataset on guerrilla — `staging` reports `total_documents: 0`; the workspace lists 10+ datasets but content lives in `production` | `bp -d staging dataset stats -o json \| jq 'del(.recent_activity)'` · `bp workspace dataset-ls -o json` |

Spread-sample recipe for row 11 (row 7's corpus JSON saved as `/tmp/graph_corpus.json`):

    curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph?dataset=production" -o /tmp/graph_corpus.json
    jq -r '[.nodes[]|select(.type=="task")|.id]|to_entries|map(select(.key % 25 == 7))|map(.value)[]' \
      /tmp/graph_corpus.json > /tmp/task_ids2.txt
    tot=0;n=0;nz=0
    while read id; do
      r=$(curl -s -H "Authorization: Bearer $TOK" "$SRV/v1/graph/$id?dataset=production&depth=1" | jq '.edges|length')
      tot=$((tot+r)); n=$((n+1)); [ "$r" -gt 0 ] && nz=$((nz+1))
    done < /tmp/task_ids2.txt
    echo "tasks=$n edges=$tot connected=$nz avg=$(echo "scale=2;$tot/$n"|bc)"
    # measured 2026-07-31: tasks=40 edges=77 connected=39 avg=1.92
