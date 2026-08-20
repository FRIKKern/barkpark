<!-- doc-tier: cold | canonical-for: stw12-v1-ledger-honesty-reproof | budget: 1500tok -->
# stw12 V1 — ledger-honesty pay re-derivation (2026-08-18)

Re-derives every fact the stw11-ledger-honesty pay rests on. Run from repo root.

## 0-based --criterion (the highest-risk axis)
    grep -n "ZERO-BASED\|0-based" internal/cli/tasks_stamp_cmd.go internal/cli/mcp_tasks.go
Proves: `--criterion N` is a ZERO-BASED index (tasks_stamp_cmd.go:14, :193, :351; mcp_tasks.go:576; cli.go:611 translates it to the 1-based board position). D82 board crit 3/4/8 (1-based) => CLI --criterion 2/3/7 (0-based).

## the three W10 squash SHAs are on main
    for s in 4028efbef 07e85d917 608ca1cb7; do git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done
All three ANCESTOR.

## offline pays that are actually green
    node cloud/priv/static/__app.test.mjs 2>&1 | tail -3        # 1075 pass, 0 fail
    (cd api && mix test test/barkpark_web/controllers/graph_controller_test.exs:471)  # edge-filter, 1 test 0 failures
- doctype console-rail (doctype-readback idx 3): the real assertion is __app.test.mjs:14016 "stw9: siteDetailHtml — the rail reads doc_type back" (asserts Content type row = value / em-dash, never invented "post"). Green inside the 1075.
- graph edge-filter (graph-server-honesty idx 2): the real test is graph_controller_test.exs **L#471** "node budget: edges filtered to the surviving set". Green.

## CORRECTION — D82's :469 citation is off by two
    (cd api && mix test .../graph_controller_test.exs:469 --trace 2>&1 | grep -iE "cap-many|edges filtered")
`:469` selects **L#459** "EXACTLY cap-many docs" (an ADJACENT test), NOT the edge-filter test. The edge-filter proof is at **:471**. Both pass, so the pay stays safe, but the builder must cite :471 (or the test name) — :469 proves the wrong test.

## CORRECTION — the offline pays are TWO, not three
- graph-server-honesty: 5/7 met; unmet idx 2 (edge-filter, PAY offline) + idx 6 (MERGE-GATED live, REFUSE).
- doctype-readback: unmet idx 3 (console-rail, PAY offline) + idx 5 (MERGE-GATED live, REFUSE).
- bpgraph-identity-tripwire: 7/8 met; the ONLY unmet is idx 7 = "MERGE-GATED (lead closes)". D82 board-crit-8 => idx 7 is the MERGE-GATED row, NOT an offline pay. bpgraph's offline drift work (mutation test, idx 2 "appending one byte reds the check") is ALREADY MET. So there is NOTHING to pay offline on bpgraph; idx 7 must be REFUSED as a live/merge-gated level-skip.
- Net: pay 2 offline criteria (graph idx 2, doctype idx 3); refuse 3 live/merge-gated (graph idx 6, doctype idx 5, bpgraph idx 7). The stamp verb itself refuses a --met whose criterion-text carries the MERGE-GATED marker unless --merge-gated (tasks_stamp_cmd.go:59) — defense in depth.

## claims are all lapsed — re-claim before close
    for t in stw9-backlog-graph-server-honesty stw9-backlog-doctype-readback stw9-backlog-bpgraph-identity-tripwire; do bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc']['claim'];print(d.get('worker'),d.get('epoch'),d.get('expired_at'))"; done
graph: worker null, epoch 6, expired 2026-07-26T19:06; doctype: epoch 5, expired 2026-07-26T19:01; bpgraph: epoch 5, expired 2026-07-26T19:06. All expired — read CURRENT holder+epoch immediately before any close.
