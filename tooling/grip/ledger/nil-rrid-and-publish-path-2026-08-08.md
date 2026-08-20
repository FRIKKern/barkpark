# nil released_revision_id + the ordinary paper publish path (2026-08-08)

Verifier `nil-rrid-and-publish-path`, http-edge-truth wave 1. All rows re-derivable.

## Verdict

The 16% nil-`released_revision_id` hole is an **ongoing leak, not a closed era**.
`Papers.BlockOps.upsert_paper/2` — the ordinary paper create/save path — writes the
document with `Repo.insert/update` and emits **neither a revision row nor a mutation
event**, so the `revisions_bind_document` trigger never fires and
`released_revision_id`/`current_revision_id` stay NULL forever.

## Re-derivation

Prod host: `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121`, then
`sudo -u postgres psql -d barkpark_prod -At -F'|' -c "<SQL>"`.

| Row | SQL / command | Result 2026-08-08 |
|---|---|---|
| nil-set revisions by FK | `select coalesce(r.action,'NONE'), coalesce(r.status,'NONE'), count(distinct d.id) from documents d left join revisions r on r.document_id=d.id where d.type='paper' and d.status='published' and d.dataset='production' and d.released_revision_id is null group by 1,2;` | `NONE|NONE|115` |
| no event AND no revision anywhere | `select count(*) from documents d where d.type='paper' and d.status='published' and d.dataset='production' and d.released_revision_id is null and not exists (select 1 from mutation_events e where e.doc_id=d.doc_id or e.doc_id='drafts.'||d.doc_id);` | `91` |
| month histogram (nil) | `select to_char(date_trunc('month',inserted_at),'YYYY-MM'), count(*) from documents where type='paper' and status='published' and dataset='production' and released_revision_id is null group by 1;` | `2026-06|1`, `2026-07|106`, `2026-08|8` |
| inserted after trigger migration | same + `and inserted_at > '2026-07-19'` | `13` |
| live-task-block papers | `select count(*) from documents where type='paper' and status='published' and dataset='production' and jsonb_path_exists(content, '$.**?((@.type == "tasks" \|\| @.type == "task-list" \|\| @.type == "task-board" \|\| @.type == "roadmap" \|\| @.type == "task-detail") && exists(@.query))');` | `15` of `722` (2.1%); 3 of them in the nil set |
| bind trigger body | `select prosrc from pg_proc where proname='barkpark_bind_document_revision';` | returns NEW when `NEW.document_id IS NULL` |
| revisions are undeletable | `select tgname from pg_trigger where tgrelid='revisions'::regclass and not tgisinternal;` | `revisions_bind_document`, `revisions_immutable` (BEFORE DELETE OR UPDATE) — rules out pruning |

Code (quote from origin/main, never the local checkout — it is ~671 commits behind):

- `git show origin/main:api/lib/barkpark/content/papers/block_ops.ex | sed -n '298p;443,480p'` — `upsert_paper/2` → `persist_blocks_doc/8`, `Repo.insert/update` then only `broadcast_paper_update(doc)`.
- `git grep -n "save_revision" origin/main -- 'api/lib/**'` — three call sites; block_ops' is gated on `opts[:revision_action]`.
- `git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '150,215p'` — the *mutate* publish path, which does `tap_broadcast(..., "publish", ...)`.
- `git show origin/main:api/lib/barkpark_web/live/bulldocs_live.ex | sed -n '764,775p'` — `@task_block_types ~w(tasks task-list task-board roadmap task-detail)`, gate also requires a map `query`.
