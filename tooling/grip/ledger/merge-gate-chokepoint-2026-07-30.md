# merge-gate chokepoint — re-derivation recipes (2026-07-30, PDS wave 25 verify)

Every row below is a single command that re-derives one fact. Nothing here mutates.

## 1. No single server-side acceptance_criteria write path

    grep -n 'Repo.update_all' api/lib/barkpark/tasks/stamp.ex api/lib/barkpark/tasks/close.ex
    grep -n '^  def create_document\|^  def upsert_document' api/lib/barkpark/content/writer.ex
    grep -n 'no mutation (Q2)' api/lib/barkpark/plugins/hooks.ex

Four independent writers: `Writer.create_document/4`, `Writer.upsert_document/4`
(both fire `:before_save`), and `Tasks.Stamp.apply_stamp_update/2` +
`Tasks.Close` (close body, `reconcile_merge_gate/3`) which go straight to
`Repo.update_all` and never fire a hook. `before_save` hooks may only return
`:ok | {:halt, reason}` — they cannot rewrite the doc.

## 2. Stamp is REFUSED on a terminal row

    bp task stamp hgw5-s4-glass-cannot-open-silently verifier-probe 1 --criterion 0 --miss --note probe
    # → bp: not_in_progress:done   (rev unchanged)

Source: `api/lib/barkpark/tasks/stamp.ex` `check_in_progress/1` requires
`lifecycle_status == "in_progress"`.

## 3. A raw criteria-only patch on a done row is LEGAL

    cd api && CC=clang mix run --no-start -e 'IO.inspect Barkpark.Tasks.Transitions.legal?("done","done")'
    grep -n 'now == was or now not in @terminal_lifecycle_statuses' api/lib/barkpark/content/mutations.ex

`legal?("done","done") == true`, and `ensure_task_close_is_cas` short-circuits
`:ok` on `now == was`. So the backfill is a raw `/v1/data/mutate` patch, not a stamp.

## 4. Blast radius (guerrilla, published perspective)

    T=<bp token>; for off in 0 1000 2000 3000; do \
      curl -s -H "Authorization: Bearer $T" \
      "https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=1000&offset=$off" \
      -o tasks_$off.json; done
    # then count docs whose acceptance_criteria contain MERGE-GATED / MERGE GATED

3,810 task docs · 562 carry a MERGE-GATED criterion · 563 gated rows · **9**
carry the machine key `merge_gate:true` · 24 done + 5 cancelled carry an UNMET
gated row · 8 of the 24 done also carry a second, non-gated unmet criterion.

`bp search query '"MERGE-GATED"' --type task --all` reports 500 — a server-side
cap, not the population.

## 5. Studio preserves unknown criteria keys

    cd api && CC=clang mix run --no-start -e 'IO.inspect Plug.Conn.Query.decode("doc[acceptance_criteria][0].criterion=x&doc[title]=T")'
    # → %{"doc" => %{"title" => "T"}, "doc[acceptance_criteria][0].criterion" => "x"}

The composite/array input name never nests under `doc`, so
`Handlers.Fields.autosave(%{"doc" => params}, …)` never sees it; and
`Forms.classic_save_content/4` only drops a base-content key that is PRESENT in
params. `array_op` re-submits the whole `editor_form` list of maps verbatim.
Either way `merge_gate` survives.
