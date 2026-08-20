# PDS w33 — is the POST-READ bucket empty in api/lib? (re-derivation recipe)

Verdict: **NO — it is not empty.** 8 genuine DB-truth-after-write sites of 80
`Repo.update_all` call sites across 37 files. But the two most consequential of
them **discard** the read in the receipt.

## Lens warning

`returning:` is the WRONG lens for `update_all`. Ecto silently ignores the
`:returning` option on `update_all` and yields `{count, nil}` — the repo says so
itself in `api/lib/barkpark/auth.ex:139-141`. The honest idiom in this codebase is
`select:` **inside the query**, which compiles to `UPDATE … RETURNING`.
A census keyed on `returning:` finds 3 hits (all `insert_all`) and reports the
bucket empty. `Repo.reload` = 0 occurrences repo-wide; also the wrong lens.

## Rerun

```sh
cd /Volumes/SATECHI/github/barkpark && python3 - <<'PY'
import subprocess,re
from collections import Counter
files=[f.replace('origin/main:','') for f in subprocess.run(
    ['git','grep','-ln','Repo.update_all','origin/main','--','api/lib'],
    capture_output=True,text=True).stdout.split()]
rows=[]
for f in files:
    src=subprocess.run(['git','show','origin/main:'+f],capture_output=True,text=True).stdout.splitlines()
    for i,l in enumerate(src):
        if 'Repo.update_all' in l and not l.strip().startswith('#'):
            win_before='\n'.join(src[max(0,i-14):i]); win_after='\n'.join(src[i+1:i+16])
            cls=('RETURNING' if re.search(r'select:',win_before+win_after)
                 else 'GET-AFTER' if re.search(r'Repo\.(get!?|one)\(',win_after)
                 else 'no-readback')
            rows.append((cls,f,i+1))
print(Counter(r[0] for r in rows)); print('sites',len(rows))
[print(r) for r in rows if r[0]!='no-readback']
PY
```

Expected on origin/main @ 2026-08-01: `{'no-readback': 69, 'GET-AFTER': 6, 'RETURNING': 5}`, 80 sites.
Three of those 11 are FALSE POSITIVES the window cannot exclude and must be
hand-read (the recipe is a candidate generator, not a verdict):

| site | verdict |
|---|---|
| `content/writer.ex:1063` | RETURNING — real (`select: d`, `{1,[doc]} -> {:ok, doc}`) |
| `content/papers/block_ops.ex:958` | RETURNING — real (`{1,[saved]} -> {:ok, saved}`) |
| `auth.ex:148` | RETURNING — real, consume_login_ticket |
| `webhooks.ex:487` | RETURNING — real, `select: w.consecutive_failures` |
| `access.ex:206` | GET-AFTER — real, `Repo.get(Grant, id)` in the `{1,_}` branch |
| `cycle_fleet.ex:652 / 2359 / 2379` | GET-AFTER — real, `Repo.get!` in the success branch |
| `webhooks/retry_worker.ex:75` | GET-AFTER — cross-function re-read in `drive/2`; internal worker, no receipt |
| `sso.ex:186` | FALSE POSITIVE — `select:` belongs to a preceding `Repo.all` |
| `preview_token.ex:116` | FALSE POSITIVE — `Repo.one` is in a different function (`revoked?/1`) |

## The two teeth

1. **Honesty is opt-in on the client.** `writer.ex` and `block_ops.ex` only take
   the RETURNING path when the caller sent `ifRev`; without it,
   `fenced_or_plain_update/3` falls through to `Repo.update(changeset)` — a
   reconstruction. Same verb, two honesty levels, chosen by the request.
2. **The read is obtained and then thrown away.** `block_ops.ex:747-770`: the
   fenced write yields `{:ok, saved}` (the row Postgres actually holds), `saved`
   is spent on side effects only, and the receipt returns `rev: rev` — the
   in-memory `paper_next_rev(doc)` computed BEFORE the write. That value reaches
   the wire at `bulldocs_ingest_controller.ex:613-624` as `ok: true, rev: …`.
   A post-read that does not reach the receipt is not a post-read.

Task ledger (`tasks/close.ex:600-605`, `stamp.ex`, `claim.ex`) has NO `select:` —
confirmed no-readback, as the wave direction states.

## Render path

`tasks_controller/params.ex` `render_doc/2` and `seal/3` perform **no storage
lookup** — pure struct/map projection; `Envelope` has zero `Repo.` calls. The
`Repo.all` sites in params.ex (469/480/527) are `batch_edge_counts/1` and
`batch_child_counts/2`, separate list-decoration helpers reading OTHER tables
(`task_edges`, child `documents`); they never re-read the written row, so no part
of a write receipt is incidentally post-read.
