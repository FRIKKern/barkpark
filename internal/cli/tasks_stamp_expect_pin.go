package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ─── THE CONFIRMATION THE ROW CANNOT SUPPLY (task-f7b781a0bcd7f70b) ─────────
//
// `--criterion-text` is the stamp's off-by-one guard and it is DEFEATED BY
// CONSTRUCTION by the only shape that ever gets typed at scale: a script walks
// the row it is stamping and passes `crit[i]["criterion"]` READ BACK FROM THAT
// ROW. Whatever index rides beside it, the text matches — so on a row whose
// criteria are all distinct, an off-by-one stamp is WIRE-IDENTICAL to a correct
// one. TestTaskStampExecute_RotatedIndicesOnDistinctCriteriaStillSilent proves
// it: all four rotations of a four-criterion row exit 0, one POST each, no
// diagnostic. The pre-check shipped in PR #18072 cannot close that — it can only
// refuse a text that matches MORE THAN ONE index, which is a different defect.
//
// No (index, text) validation can close it, because both values come from the
// row. The confirmation has to be a value THE ROW CANNOT SUPPLY: an expectation
// the AUTHOR types BEFORE the row is read.
//
//	--expect '<index>:<the first words of the criterion>'
//
// The pin is authored from the plan ("I am stamping criterion 2, the read-back
// one"), not from the JSON the script is about to walk. Then:
//
//  1. BEFORE the POST — the pin's index must be the index being stamped (a
//     rotated script disagrees with its own author's pin and is refused with NO
//     store read at all), and the stored criterion at that index must START WITH
//     the pinned prefix (a re-ordered or re-worded row is refused, with both
//     texts printed).
//
//  2. AFTER the POST — the read-back asserts the evidence sits on a criterion
//     that still starts with the pin (stampMismatches). A row whose criteria
//     MOVED between the pre-check and the write lands the evidence somewhere the
//     author never named, and only a read-back keyed on the pin can see it: a
//     read-back that merely confirms "the write happened" confirms the wrong
//     row just as happily.
//
// OPT-IN, deliberately. Making the pin mandatory would break every existing
// scripted caller in the same breath as the fix and would ship a worse defect
// than the one it closes (a verb nobody can call). What is NOT optional is
// honesty about it: a `--met` with no pin gets one stderr line naming the pin as
// the only confirmation the row cannot supply, and the surviving-defect test
// keeps asserting that the unpinned rotation is still silent.
//
// CLIENT-SIDE AND UNDECLARABLE, like --criterion-text-file and `task ls
// --match`: the server cannot hold an expectation authored before the row was
// read, so parseStampArgs strips the flag (and its value) from the forwarded
// tail and usageCommand carries its help (stampExpectPinHelpLines).

const (
	// stampExpectFlag is the pin's spelling, written once so the parser, the
	// refusals and the help can never drift.
	stampExpectFlag = "--expect"

	// stampExpectPinCode is the named error code for every pin refusal that is
	// about the INVOCATION or the row's wording — the caller's own expectation
	// did not hold, and nothing was sent.
	stampExpectPinCode = "stamp_expectation_unmet"

	// stampExpectUnreadableCode is the refusal when the store cannot be reached
	// to CHECK the pin. Distinct from the above because the pin is not known to
	// be wrong — it is known to be unchecked, and this caller asked for it to be
	// checked. Unlike the discrimination pre-check (which is advisory on a failed
	// read, because it is layered on a server guard that still runs), an
	// unchecked pin is refused: "we could not ask" is not "it aligned", and the
	// refusal can only ever reach a caller who opted in by typing the flag.
	stampExpectUnreadableCode = "stamp_expectation_unchecked"

	// stampPinMinPrefix is the shortest pin the guard will accept, in
	// normalized characters. A two-character pin matches half the row and
	// confirms nothing; requiring a real phrase is what makes the value one the
	// author had to have known BEFORE reading the row.
	stampPinMinPrefix = 8
)

// stampPin is an author-typed expectation: "index N starts with this wording".
// `raw` is kept verbatim for the refusals, which must quote what was TYPED and
// not a normalization of it.
type stampPin struct {
	index  int
	prefix string
	raw    string
}

// parseStampPin reads the `<index>:<prefix>` spelling. It is pure and total:
// every rejection names the shape to type instead.
func parseStampPin(raw string) (stampPin, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return stampPin{}, fmt.Errorf("%s takes '<index>:<the first words of the criterion>' — it was empty", stampExpectFlag)
	}
	cut := strings.Index(s, ":")
	if cut < 0 {
		return stampPin{}, fmt.Errorf("%s %q has no ':' — the shape is '<index>:<the first words of the criterion>', e.g. %s '2:THE READ-BACK CHECKS ALIGNMENT'", stampExpectFlag, raw, stampExpectFlag)
	}
	idx, err := strconv.Atoi(strings.TrimSpace(s[:cut]))
	if err != nil {
		return stampPin{}, fmt.Errorf("%s %q does not start with a criterion INDEX (0-based) before the ':'", stampExpectFlag, raw)
	}
	if idx < 0 {
		return stampPin{}, fmt.Errorf("%s %q names a negative index; --criterion is 0-based and the first criterion is 0", stampExpectFlag, raw)
	}
	prefix := strings.TrimSpace(s[cut+1:])
	if n := len(pinNormalize(prefix)); n < stampPinMinPrefix {
		return stampPin{}, fmt.Errorf("%s %q carries a %d-character expectation; the pin must be at least %d characters of the criterion's own wording, or it matches too much of the row to confirm anything", stampExpectFlag, raw, n, stampPinMinPrefix)
	}
	return stampPin{index: idx, prefix: prefix, raw: raw}, nil
}

// pinNormalize is the comparison form: whitespace runs (including newlines, the
// shape a criterion copied out of a plan carries) collapse to one space, the
// ends are trimmed and case is folded. A pin is typed by a human from a plan,
// so it must survive re-wrapping and capitalization — it must NOT survive
// naming a different criterion, which is why nothing else is folded away.
func pinNormalize(s string) string {
	return strings.ToUpper(strings.Join(strings.Fields(s), " "))
}

// pinMatchesCriterion reports whether the stored criterion STARTS WITH the
// pinned wording, compared in normalized form.
func pinMatchesCriterion(prefix, criterion string) bool {
	p := pinNormalize(prefix)
	if p == "" {
		return false
	}
	return strings.HasPrefix(pinNormalize(criterion), p)
}

// stampPinIndexProblem is the half of the check that needs NO store read: the
// author pinned one index and the invocation is stamping another. This is the
// rotated-script case — the script's index came from its own loop, the pin came
// from the author — and it is refused before a single byte is sent.
// Returns "" when the two agree.
func stampPinIndexProblem(pin stampPin, requested int) string {
	if pin.index == requested {
		return ""
	}
	return fmt.Sprintf(
		"the pin names index %d (#%d as boards number them) and this stamp targets index %d (#%d) — the expectation you typed BEFORE reading the row and the index the invocation carries are not the same criterion. That is the off-by-one this flag exists to catch: nothing was sent. Re-pin if the index is right (%s '%d:<the first words of that criterion>'), or fix --criterion if the pin is right.",
		pin.index, pin.index+1, requested, requested+1, stampExpectFlag, requested)
}

// stampPinTextProblem is the half that reads the store: the criterion at the
// pinned index must start with the pinned wording. Returns "" when it does.
// `criteria` is the row's wording, positionally, as storedCriterionTexts reads it.
func stampPinTextProblem(pin stampPin, criteria []string) string {
	if pin.index >= len(criteria) {
		return fmt.Sprintf(
			"the pin names index %d (#%d as boards number them) but the row holds %s — the criteria list is shorter than the expectation you typed, so the row is not the one you planned against: nothing was sent.",
			pin.index, pin.index+1, pluralCount(len(criteria), "criterion", "criteria"))
	}
	stored := criteria[pin.index]
	if pinMatchesCriterion(pin.prefix, stored) {
		return ""
	}
	return fmt.Sprintf(
		"the criterion at index %d (#%d as boards number them) does NOT start with the wording you pinned — nothing was sent.\n  you pinned:      %q\n  the store holds: %q\nEither the list MOVED since you wrote the pin (re-read it and re-pin) or the pin was written for a different row.",
		pin.index, pin.index+1, truncateCell(pin.prefix, 72), truncateCell(strings.TrimSpace(stored), 72))
}

// stampPinReadbackProblem is the AFTER half (criterion 2 of the row): the
// evidence has been written, and the row the store hands back must still carry a
// criterion that starts with the pin AT THE STAMPED INDEX. The pre-check cannot
// stand in for this — the criteria list can move between the check and the write
// (a concurrent `bp doc patch`, a re-ordering, a row swapped under a long run),
// and a read-back that only asks "did a write happen" says yes to the wrong row
// just as fast. Returns "" when the stamp is aligned.
func stampPinReadbackProblem(pin stampPin, index int, storedCriterion string) string {
	if pinMatchesCriterion(pin.prefix, storedCriterion) {
		return ""
	}
	return fmt.Sprintf(
		"the evidence landed on a criterion that does NOT start with the wording you pinned — pinned %q, the store holds %q at index %d (#%d as boards number them). The write happened; it happened on a row you never named.",
		truncateCell(pin.prefix, 72), truncateCell(strings.TrimSpace(storedCriterion), 72), index, index+1)
}

// refuseMisalignedExpectPin runs the BEFORE half and returns the parsed pin for
// the read-back to reuse. A nil pin with exitOK means no pin was typed and the
// verb behaves exactly as it did before this change.
func refuseMisalignedExpectPin(out *writer, ctx manifest.Context, sa stampArgs, cmd manifest.Command, forward []string) (*stampPin, int) {
	if strings.TrimSpace(sa.expect) == "" {
		return nil, exitOK
	}
	pin, err := parseStampPin(sa.expect)
	if err != nil {
		return nil, useError(out, stampExpectPinCode, err.Error(), exitValidation)
	}
	if sa.criterion == nil {
		// No index to compare against; the dispatch's own usage error owns this
		// invocation, and claiming a pin verdict about it would be noise.
		return nil, exitOK
	}
	if p := stampPinIndexProblem(pin, *sa.criterion); p != "" {
		return nil, useError(out, stampExpectPinCode, "refusing this stamp: "+p, exitValidation)
	}
	req, ok := stampRequestOf(cmd, forward)
	if !ok {
		return &pin, exitOK
	}
	texts, err := storedCriterionTexts(taskReadbackClient(ctx), req.docID)
	if err != nil {
		return nil, useError(out, stampExpectUnreadableCode,
			fmt.Sprintf("refusing this stamp: you asked for the pin %q to be checked and %s could not be read to check it: %v. Nothing was sent — an unchecked expectation is not a met one. Retry, or drop %s to stamp under the server's guard alone.",
				pin.raw, req.docID, err, stampExpectFlag),
			exitGeneric)
	}
	if p := stampPinTextProblem(pin, texts); p != "" {
		return nil, useError(out, stampExpectPinCode, "refusing this stamp: "+p, exitValidation)
	}
	return &pin, exitOK
}

// stampExpectAdvisory is the one line a `--met` with no pin gets: the guard it
// IS using is defeated by the shape every script uses, and a flag nobody can
// discover is a flag nobody types. Empty for every other invocation.
func stampExpectAdvisory(sa stampArgs) string {
	if !sa.met || strings.TrimSpace(sa.expect) != "" || sa.criterion == nil {
		return ""
	}
	return fmt.Sprintf("  (no %s pin: --criterion-text read FROM the row confirms whatever index it rides beside. %s '%d:<the first words you meant>' is the one confirmation the row cannot supply.)",
		stampExpectFlag, stampExpectFlag, *sa.criterion)
}

// stampExpectPinHelpLines documents the flag in `bp task stamp --help`. The
// manifest cannot declare it (see the header), so this block is the ONLY place a
// reader can discover it.
func stampExpectPinHelpLines() []string {
	return []string{
		"out-of-row confirmation (client-side, authored BEFORE the row is read):",
		"  " + stampExpectFlag + " '<index>:<first words>'   refuse the stamp unless the criterion at <index> STARTS WITH",
		"                              that wording — checked before the POST and AGAIN on the read-back.",
		"  WHY: --criterion-text is read FROM the row being stamped, so it matches whatever index rides beside",
		"  it — an off-by-one stamp is wire-identical to a correct one. The pin is the one value the row cannot",
		"  supply: you type it from your plan, and an index the script rotated no longer agrees with it.",
		"  e.g. bp task stamp <id> <worker> <epoch> --criterion 2 " + stampExpectFlag + " '2:THE READ-BACK CHECKS' --met --evidence \"…\"",
		"  At least " + strconv.Itoa(stampPinMinPrefix) + " characters of the criterion's own wording; whitespace and case are folded, nothing else.",
	}
}
