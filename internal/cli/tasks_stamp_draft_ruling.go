package cli

// tasks_stamp_draft_ruling.go — THE RECORDED RULING on a stamp that lands on a
// DRAFT-ONLY row (task-d2006c0afd97746a, ruled 2026-09-13).
//
// THE QUESTION PUT. `GET /v1/tasks/:doc_id` falls back to the `drafts.` twin
// when no published row exists (tasks_controller.ex find_task_by_doc_id), and
// `bp task create --yes` files exactly such a row at rc=0. A stamp against one
// of those rows therefore WRITES — the value really does land in the store —
// on a row no board reads. Should `bp task stamp` REFUSE such a stamp outright,
// before the write, rather than let it land and then report on it?
//
// THE RULING: KEEP THE WRITE, REFUSE THE GREEN. `bp task stamp` does not
// pre-flight the row's publication state and does not withhold the POST. It
// writes, reads back, and — when a draft answered the read-back — refuses to
// report success: exitConflict, a verdict naming the row that answered, and the
// remedy (publish, then stamp again). See renderStampVerdict's first branch.
//
// WHY, in the order the reasons were weighed:
//
//  1. THE BAD OUTCOME IS ALREADY FORECLOSED. The failure this row was filed
//     against is "lands on the draft and reports a truthful green about a row
//     no board reads". Since 46d504424a there is no green on that path at all:
//     the draft branch is checked BEFORE the row's contents are compared, so a
//     draft answer cannot be decorated into a pass. A pre-flight refusal would
//     move the same red earlier and buy no safety.
//
//  2. A PRE-FLIGHT REFUSAL WOULD DESTROY A GOOD WRITE. The draft-landed value
//     is not lost and not wrong — it is INVISIBLE, and publishing the row makes
//     it visible with no re-stamp. Refusing before the POST throws away work the
//     store was willing to keep. `api/lib/barkpark/content/label_spine.ex` states
//     the store's own policy in one line: drafts stay free; publish is the wall.
//     A CLI that refuses what its server accepts is stricter than the store it
//     writes to, and that is the shape of rule this repo has twice declined to
//     ship (`bp task create`'s auto-stub ruling, f8c798e113cd2223; `bp task
//     stamp --expect`, which shipped OPT-IN rather than refuse every existing
//     scripted caller in the same breath as the fix).
//
//  3. A PRE-FLIGHT IS A SECOND READ AND A TOCTOU WINDOW. Refusing before the
//     POST costs an extra GET on EVERY stamp — under LEDGER DIET the task read
//     is the expensive call — and the answer it buys can be stale by the time
//     the POST lands: a row published between the check and the write would be
//     refused a stamp that would have succeeded. The post-write read-back has
//     neither cost (it is the read the verb already performs) nor that window
//     (it describes the row that actually answered).
//
// WHAT THE RULING OWES THE CALLER, and what stampDraftRulingNote discharges: a
// ruling that lives only in a commit message does not fire. The decision is
// therefore PRINTED on the exact path it governs — the draft refusal itself —
// and carried in the machine receipt's `notes`, so a scripted caller reading
// `-o json` learns it too.
//
// DETECTOR: TestStampDraftOnlyRulingRidesTheRefusalAndTheReceipt
// (tasks_stamp_persistence_matrix_test.go). Delete the note, or stop calling it
// from renderStampVerdict/stampReceipt, and that test reds on both shapes.

// stampDraftRulingNote is the ruling as one caller-facing sentence. It states
// the decision, the reason a caller can act on, and the row that owns it, so
// the next person to ask "why did this write happen at all?" gets the answer at
// the moment they ask it rather than in a ledger they will not open.
const stampDraftRulingNote = "RULED (task-d2006c0afd97746a): the write is NOT pre-refused on a draft-only row — " +
	"the value is real and becomes visible the moment the row is published, so refusing it would DISCARD work the store kept. " +
	"Drafts stay free; publish is the wall. What is refused is the GREEN, not the write."
