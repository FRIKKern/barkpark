# TLV reconcile wave — movement-4 provability verdict (2026-08-18)

Assignment: settle whether ANY of the 3 offline-buildable TLV candidates is a clean
movement-4 (offline- AND mutation-provable, above-bar) finish this wave. **Verdict: finish-set EMPTY — all three LEAVE.**

## Go suite is green (precondition)

    CC=/usr/bin/clang go build ./...            # BUILD_EXIT=0
    CC=/usr/bin/clang go test ./internal/taskboard/... -count=1
    # -> ok  github.com/FRIKKern/barkpark/internal/taskboard  0.986s

Note: bare `go build` fails with `cc: error: unknown option '-E'` — the `cc` alias
shadows the compiler (memory: cc-alias-shadows-compiler). Always `CC=/usr/bin/clang`.

## tlv-bl-tui-close-drift-resync-guidance (open 0/3) — LEAVE

Criteria (0-based, read from live doc content.acceptance_criteria):
- [0] resyncGuidance leads with observed_rev AND the reopen->close flow passes the fresh rev
- [1] actions_test.go pinned string updated and green
- [2] stale close + refresh + observed_rev retry closes ONLY the exact reread revision, while a
      second concurrent edit still REFUSES rather than being overwritten

Why LEAVE:
- crit[0]'s second clause is FALSE today and needs real board-path wiring. The interactive
  board close path uses DoClose, NOT DoCloseRev:
    internal/taskboard/program.go:1014  m.closeCmd(t.DocID, CmuxWorkerID(), t.Claim.Epoch)
    internal/taskboard/program.go:1085  closeCmd -> m.doClose (= DoClose, 4-arg, no rev)
    internal/taskboard/program.go:201   doClose func(*apiclient.Client, string, string, int) ActionResult
  DoCloseRev's ONLY caller is the cmux Stop hook, not the interactive reopen->close flow:
    grep -rn DoCloseRev internal/ --include=*.go | grep -v _test.go
    -> internal/cli/cmux_hook.go:245   (reads fresh rev via GetPerspective, passes it)
    -> internal/taskboard/actions.go:81 (definition)
- crit[2] is a SERVER CAS guarantee. The unit mock cannot enforce it:
    internal/taskboard/actions_test.go:25  serve() = httptest.NewServer that replays a CANNED
    status+body and captures the request body. It never enforces observed_rev CAS. A test can
    prove the CLIENT sends observed_rev (cap.body["observed_rev"]) and surfaces a 409 refusal,
    but CANNOT prove the server rejects an overwrite of a concurrently-edited rev — the
    load-bearing safety property lives in the Elixir close endpoint. NOT offline-provable.
  => above-bar, real work, but not offline+mutation-provable to convergence this wave.

## tlv-bl-task-board-columns-dead-code (open 0/3) — LEAVE

Criteria: [0] delete (tests rehomed) or real runtime consumer; [1] "PR merged to main (lead
closes)"; [2] import/vocab checks prove no runtime refs OR name+test the revived consumer.
- crit[1] is EXPLICITLY merge-gated -> lead closes. Disqualifies a this-wave close-by-evidence.
- "dead code / orphan" premise is only HALF true: no RUNTIME importer exists
    grep -rn task-board-columns web/ --include=*.ts --include=*.tsx | grep -v node_modules | grep -v __tests__
    -> only a COMMENT in web/lib/component-projections.ts:17
  BUT the file is load-bearing for the cross-surface golden-parity spine — deleting it breaks
  two test files that import it:
    web/__tests__/component-golden-parity.test.ts:51  imports taskBoardColumns/LABELS/GLYPHS
    web/__tests__/task-board-columns.test.ts:18       imports the same
    cd web && node --test __tests__/component-golden-parity.test.ts  -> pass 31 / fail 0
  A bare delete is NOT free; it is a rehome. Not a clean offline finish, and crit[1] is merge-gated.

## tlv-bl-js-vocab-generator (open 0/3) — LEAVE

Criteria: [0] EMIT STATUS_ROLES (react inline.tsx) + STATUS_LADDER (component-projections.ts)
from design/status-manifest.json at build time; [1] retire status-manifest-check.sh Part 5
byte-check, regen idempotent + CI-checked; [2] "PR merged to main (lead closes)".
- crit[2] explicitly merge-gated; crit[1] requires CI. Needs a NEW emitter (design/emit.mjs
  sibling) + Part-5 gate retirement. Offline-buildable but not this-wave close-by-evidence. LEAVE.

## Bottom line

finish-set = EMPTY. Movement 4 has no clean offline+mutation-provable finish. All three are
either merge-gated (columns, js-vocab crit[2]) or hinge on a server CAS guarantee the unit mock
cannot enforce (tui-close-drift crit[2]). Supports the convergence verdict: recommend AGAINST
seal-and-spin (s5/s8 remain the named offline-unbuildable seal-blockers; this backlog holds no
finishable-this-wave defect).
