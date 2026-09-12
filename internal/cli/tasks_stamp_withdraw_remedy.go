package cli

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// THE DEFECT THIS FILE CLOSES (task-57081836b628df35, instance 3).
//
// `--miss` reads as a CORRECTION verb. It is not: it records an honest attempt
// and `met` never moves. So an operator who reaches for `--miss` to lower a
// criterion that was stamped `met` by mistake is silently not doing that — the
// write lands, the receipt says the store holds it, and the board still counts
// the criterion as proven.
//
// The verb that DOES lower it exists and has existed all along: `--withdraw`
// (tasks_stamp_cmd.go — met goes false, the evidence is preserved, and a signed
// withdrawal record lands on the criterion). It was simply never named at the
// point of confusion. That is the shape this row is about: an honest NO that
// describes no reachable next step.
//
// The remedy is exposed at all THREE moments a caller can learn `--miss` did
// not lower `met`:
//
//   - BEFORE the write — the echo line (stampEchoLine) spells out that a miss
//     changes nothing and names --withdraw;
//   - AFTER the write — the read-back verdict prints missLeftMetTrueNote
//     whenever a --miss was stamped on a row whose stored `met` is still TRUE,
//     which is exactly the state the confused operator is in;
//   - IN THE HELP — `bp task stamp --help` renders stampOutcomeHelpLines, so
//     the three outcomes and which one lowers `met` are readable without
//     opening the source.
//
// It is an ADVISORY, never a failure: the miss really did land, so the exit
// code and `confirmed` stay exactly what they were. Turning a correct write
// into a red would trade one lie for another.

// stampWithdrawFlag is the flag name the advisory names. Named once so the
// help block, the echo line and the read-back note cannot drift apart, and so a
// mutation that removes the remedy has a single anchor.
const stampWithdrawFlag = "--withdraw"

// missLeftMetTrueNote is the advisory, as a pure function of the request and
// the row the store handed back. Empty for every case that is not the confusion
// — a --miss on a row that was already false is a miss doing its job, and says
// nothing.
func missLeftMetTrueNote(req stampRequest, stored taskboard.CriterionItem) string {
	if !req.miss || !stored.Met {
		return ""
	}
	worker := req.worker
	if worker == "" {
		worker = "<worker>"
	}
	return fmt.Sprintf(
		"--miss recorded the attempt and met is STILL TRUE — a miss never lowers met. "+
			"The verb that DOES lower it is %s: it sets met=false, KEEPS the evidence, and signs the correction. "+
			"e.g. bp task stamp %s %s <epoch> --criterion %d %s --note \"why the met was wrong\"",
		stampWithdrawFlag, req.docID, worker, req.index, stampWithdrawFlag)
}

// stampOutcomeHelpLines is the `bp task stamp --help` block that names the
// three outcomes and, for each, what happens to `met`. The manifest's own flag
// summaries are SERVER-owned (api/lib/barkpark/plugins/tasks.ex), so the CLI
// cannot edit the `--miss` summary; it can and does render this beside it.
func stampOutcomeHelpLines() []string {
	return []string{
		"outcomes (what each one does to `met`):",
		"  --met        met → TRUE. This CLI's read-back refuses to confirm a met the store holds with no",
		"               evidence — that is a client-side check, not a promise about what the server enforces.",
		"  --miss       met is UNCHANGED. Records an honest attempt with --note. A miss NEVER lowers a met —",
		"               if the criterion is already met and you want it lowered, --miss will not do it.",
		"  " + stampWithdrawFlag + "  met → FALSE. THIS is the verb that lowers a wrong met: the evidence is kept as the",
		"               superseded proof and a signed withdrawal record (--note) says who lowered it and why.",
		"",
		"These are the outcomes of `bp task stamp`. They are NOT an inventory of every way `met` can",
		"move — a close is a different door with its own rules. Do not read this block as a guarantee",
		"that no other path can raise or lower a criterion.",
	}
}
