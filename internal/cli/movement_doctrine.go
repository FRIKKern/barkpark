package cli

// movement_doctrine.go — the ONE canonical movement-ledger doctrine: every unit
// of work registers as a bp task. It exists as a single Go string so the copies
// on the priming surfaces cannot drift, and so a surface that renders it is
// wired to a value rather than to a paraphrase someone retyped.
//
// WHY IT IS WRITTEN AS MECHANISM, NOT EXHORTATION. "Always file a task" already
// appears in several places and it did not hold — an agent that believes it
// registered its work behaves exactly like one that did. So the doctrine names
// the three ways a registration you THINK you made never lands, each verified
// against this repo rather than recalled:
//
//   - the piped-stdin refusal: run.go buildBody's `cmd.Writes` arm refuses a
//     mutation write (MutationOp != "") whose stdin is redirected, with
//     "piped stdin is unused and <noun> <verb> does not accept --file" at exit 2.
//     Observed live on `bp task claim` and `bp task close`; a read verb
//     (`bp task ready`) with the same pipe returns 0, which is exactly why the
//     failure reads as "the script ran fine".
//   - the prod-write confirmation: the same claim with no pipe and no --yes
//     aborts with "prod write to <server> needs confirmation — re-run with
//     --yes" / "aborted: prod write not confirmed", exit 2. --yes does NOT
//     rescue the stdin refusal: the stdin arm fires first.
//   - read-back: docs/setup/TASK-SYSTEM.md already carries the published-row
//     caveat ("trust the read-back, not the exit code") for stamps; the doctrine
//     generalizes it, because a receipt is a claim about a request, not about a
//     row.
//
// Deliberately NOT in this text: anything true only of the Barkpark repo. The
// block ships into OTHER people's repositories via `bp onramp agents-md`, so PR
// trailers, merge gates and this repo's CI belong in docs/setup/TASK-SYSTEM.md,
// never here.

import "github.com/FRIKKern/barkpark/internal/manifest"

// movementLedgerDoctrine is the canonical agent-facing doctrine block. It is
// rendered VERBATIM into: the `bp onramp agents-md` teach block (and, through
// renderAgentsMDBody, the .cursor / .claude / CODEX.md wrappers the parity gate
// pins), and the `bp mcp serve` MCP server instructions so an MCP-only client is
// primed without reading a doc. Keep it short — it is quoted in full on every
// one of those surfaces, and docs/setup/CODEX.md's budget-exempt onramp span is
// itself byte-capped (scripts/check-doc-budgets.sh).
const movementLedgerDoctrine = "**Register the movement.** Every unit of work — build, research, plan, audit, spike — runs under a claimed task: if no row names it, create one and claim it FIRST, then work. Unregistered work is unrecoverable — a lost session is rebuilt only from the ledger, and \"what has been going on lately\" is answerable only from task events.\n" +
	"\n" +
	"Three ways a registration you think you made never landed:\n" +
	"- A redirected or piped stdin makes `bp` REFUSE a mutating write (exit 2, `piped stdin is unused`) — in a heredoc-fed script every claim/create/stamp aborts while the reads around them succeed. Pass arguments, never a pipe.\n" +
	"- A write to a remote server without `--yes` aborts (exit 2, `prod write not confirmed`). It fires AFTER the stdin refusal, so fixing one can reveal the other.\n" +
	"- A printed receipt is not persistence. Read the row back and match a string you wrote."

// movementLedgerDoctrineLine is the one-line rendering `bp task prime` leads
// with — the rehydration call is where an agent decides what to do next, and
// that is the moment the doctrine has to be in front of it. It is a POINTER to
// the full block (which is what the onramps and MCP instructions carry), not a
// second copy of it: a paraphrase on a third surface is the drift this file
// exists to prevent.
const movementLedgerDoctrineLine = "doctrine: every unit of work runs under a claimed task — claim before you work, stamp evidence as you prove it, close on the claim epoch. Read the row back; a printed receipt is not persistence."

// emitMovementDoctrine prints the one-line doctrine to STDERR ahead of a
// `bp task prime` payload. STDERR, and never stdout, for the same reason
// emitHelpHints uses it: stdout must stay one parseable document in the json /
// yaml arms. It is called from runCommand's post-2xx hook BEFORE emitHelpHints
// so the doctrine leads the queue snapshot rather than trailing it.
//
// Scoped to task.prime alone. Stamping it on every task verb would train the
// reader to skip it, and prime is the one call whose whole purpose is "you are
// starting or resuming — here is your state".
func emitMovementDoctrine(out *writer, cmd manifest.Command) {
	if cmd.Noun != "task" || cmd.Verb != "prime" {
		return
	}
	out.errf("%s", movementLedgerDoctrineLine)
}
