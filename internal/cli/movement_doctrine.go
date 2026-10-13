package cli

// movement_doctrine.go — the ONE canonical movement-ledger doctrine: every unit
// of work registers as a bp task. It exists as a single Go string so the copies
// on the priming surfaces cannot drift, and so a surface that renders it is
// wired to a value rather than to a paraphrase someone retyped.
//
// WHY IT IS WRITTEN AS MECHANISM, NOT EXHORTATION. "Always file a task" already
// appears in several places and it did not hold — an agent that believes it
// registered its work behaves exactly like one that did. So the doctrine names
// what to check before trusting a write, each verified
// against this repo rather than recalled:
//
//   - the prod-write confirmation: a write to a remote server with no --yes
//     aborts with "prod write to <server> needs confirmation — re-run with
//     --yes" / "aborted: prod write not confirmed", exit 2.
//   - the unread stdin: since #14994 a write that does not take its body from
//     stdin does not abort on a pipe; it proceeds without it. run.go
//     unusedStdinNotice prints "piped stdin is unused …" on stderr only for a
//     verb that takes --file, so data piped into a claim or stamp is dropped
//     with no message. It used to
//     refuse at exit 2; the doctrine said so until task-b3c1a6806f182604.
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
	"Before you trust a write:\n" +
	"- A write to a remote server without `--yes` aborts (exit 2, `prod write not confirmed`).\n" +
	"- A write never reads a piped stdin unless you pass `--file -`. `bp` ignores the pipe and proceeds (with a `piped stdin is unused` warning where the verb takes `--file`), so pass data as arguments.\n" +
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
