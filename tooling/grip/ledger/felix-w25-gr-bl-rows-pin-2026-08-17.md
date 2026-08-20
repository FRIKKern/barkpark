<!-- doc-tier: cold | canonical-for: felix-w25-gr-bl-rows-pin re-derivation | budget: 1200tok -->
# Felix W25 — the four gr-bl rows, pinned against origin/main (2026-08-17)

Verifier: gr-bl-rows-pin. Re-derivation recipes for the four gr-bl backlog rows. No mutations, no commits.

## Row 1 — gr-bl-tasks-route-parent-filter-ignored  → STILL-LIVE (unpaid)

Names **GET /v1/tasks** (the Tasks index), NOT the data-query path.

Re-derive the row text:
    bp task get gr-bl-tasks-route-parent-filter-ignored -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["doc"]["content"]["description"])'

Re-derive the defect on main (index reads only `parent` + `phase_id`, never `parent_id`/`filter[parent_id]`):
    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '248,300p'
      # line 270: parent = params["parent"]
      # line 296: |> Params.maybe_filter_parent(params["phase_id"])
      # line 297: |> Params.maybe_filter_parent_id(parent)
      # NO read of params["parent_id"] and NO read of params["filter"]["parent_id"]

Both filter helpers hit the SAME jsonb field content.parent_id:
    git show origin/main:api/lib/barkpark/tasks/query.ex | sed -n '60,90p'

Phoenix parses `?filter[parent_id]=X` into params["filter"]["parent_id"] — the index never touches it → unfiltered LIMIT-1000 page. Data-query path (different controller) DOES honor filter[parent_id]; that is why the row says the only filtering reads are /v1/data/query/production/task and `bp task get <parent>` .children.

CLI does NOT trip it — `task ls`/`task ready` expose no parent flag:
    bp capabilities -o json | python3 -c 'import json,sys;[print(c) for c in json.load(sys.stdin)["commands"] if c[0]=="task" and c[1] in ("ls","ready")]'
      # ["task","ls",...,[["limit","int"],["offset","int"]]]  — no parent flag
Victim is a raw HTTP caller (Cloud GUI charter GR126 prescribes "bracket-encoded filter[parent_id] always" → does not work here). Fix per AC: honor the filter OR 422 unknown filters. Felix scar-class: silent filter drop = false confirmation. FENCE: touches tasks_controller.ex (a controller — not a security-wave file; Decide confirm no collision).

## Row 2 — gr-bl-close-time-audit-vacuous-green  → STILL-LIVE (root shared with Row 1)

    bp task get gr-bl-close-time-audit-vacuous-green -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["doc"]["content"]["description"])'
Confirmed: closes RELEASE doc.claim (closed_at null); children payload carries inserted_at not updated_at; `bp task ls` has no --parent flag (manifest above). Real vacuous-green trap; ergonomics/observability, not a guard.

## Row 3 — gr-bl-task-move-noop-help-drift  → STILL-LIVE (help-text/CLI fix)

    git show origin/main:api/lib/barkpark/tasks/move.ex | sed -n '80,150p'
      # 86-88: same_parent?(...) -> {:noop, doc}
      # 104:   {:ok, {:noop, doc}} -> doc   (no emit_broadcasts / insert_mutation_event!)
      # 138-140: insert_mutation_event!(... @event_task_reparented ...) ONLY inside do_move
Server does NOT emit task.reparented on a same-parent no-op → CLI `bp task move --help` "always emits" is wrong. No-op still burns a rate-limit slot (RateLimit plug bills by HTTP method before the controller). Fix = correct CLI help (internal/cli). Small, correct.

## Row 4 — gr-bl-task-write-cap-breaks-briefs  → STILL-LIVE (measured, not re-measured here)

    bp task get gr-bl-task-write-cap-breaks-briefs -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["doc"]["content"]["description"])'
Row is a round-12 live binary-probe measurement (succeeds 8000B, fails 16000B on /v1/data/mutate; silent) — same class as pds-bl-large-task-write-500. NOT re-measured (would require a mutating write). Verdict rests on the row's own measurement + the concrete scar (gr-p5r11-terminal-act stale render-mirror). Distinct from Row 1-3.
