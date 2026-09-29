package taskboard

// claimforward.go — the claim-forward CONTRACT as a checkable predicate
// (task p-claim-forward, criterion 3: "verified against the live guerrilla
// ready overlay").
//
// The claim-forward behaviour itself already ships: resolveNext (board.go)
// builds the NEXT intent strip and `c` claims the highlighted row. What did
// NOT ship was a way to ASK a board whether it kept the promise — so the only
// proof available was a hand-picked fixture. A fixture cannot speak for the
// live guerrilla corpus, where the ready set is not authored but OVERLAID onto
// the task list from prime's ready head (fetch.go composeSnapshot), clamped at
// primeReadyLimit, and raced against claims landing between the two fetches.
//
// ClaimForwardViolations turns the three shipped criteria into ONE pure
// predicate over (Snapshot, Board) so the same words can be checked against a
// fixture in CI and against the live server in the liveprobe run:
//
//	C0  ready work exists  =>  the strip surfaces at least one next move.
//	C1  every surfaced ready row is REAL — it is in the snapshot's ready
//	    overlay and is not already pinned in NOW (no dead/fabricated target).
//	C2  no ready work  =>  no ready row is surfaced (honest empty, not a
//	    fake control). Resumables are follow-up, not "ready", and stay legal.
//
// It reports STRINGS, not a bool, because a live failure has to name the row
// it failed on — an empty slice is the pass.
//
// It is deliberately NOT a re-implementation of resolveNext's ranking: it
// asserts the PROMISE (a next move exists, and it is claimable), never the
// pick. A checker that recomputed the pick would only prove resolveNext equals
// itself.

// ClaimForwardViolations reports every way `b` breaks the claim-forward
// contract against the snapshot it was built from. Empty slice == the contract
// holds. `s` must be the snapshot handed to BuildBoard; twins are collapsed
// here exactly as BuildBoard collapses them, so both sides measure the same
// population.
func ClaimForwardViolations(s Snapshot, b Board) []string {
	tasks := collapseDraftTwins(s.Tasks)

	nowSet := make(map[string]bool, len(b.Now))
	for _, t := range b.Now {
		nowSet[bareID(t.DocID)] = true
	}

	readySet := make(map[string]bool, len(tasks))
	readyOutsideNow := 0
	for _, t := range tasks {
		if t.Lifecycle != lifeReady {
			continue
		}
		bare := bareID(t.DocID)
		readySet[bare] = true
		if !nowSet[bare] {
			readyOutsideNow++
		}
	}

	var out []string

	// C0 — ready work exists, so a next move must be surfaced.
	if readyOutsideNow > 0 && len(b.Next) == 0 {
		out = append(out, "C0: ready overlay holds "+itoa(readyOutsideNow)+
			" claimable task(s) outside NOW but the NEXT strip is empty — no claim-forward")
	}

	surfacedReady := 0
	for _, ni := range b.Next {
		bare := bareID(ni.Task.DocID)
		switch ni.Kind {
		case nextReady:
			surfacedReady++
			// C1 — the surfaced row must be a real, claimable ready row.
			if !readySet[bare] {
				out = append(out, "C1: NEXT surfaces "+ni.Task.DocID+
					" as ready but it is not in the snapshot's ready overlay — dead claim target")
			}
			if nowSet[bare] {
				out = append(out, "C1: NEXT surfaces "+ni.Task.DocID+
					" which is already pinned in NOW — claiming it is not a next move")
			}
		case nextResume:
			// A resumable is follow-up, not ready. It must still be claimable:
			// non-terminal and not currently held by a live worker.
			if isTerminal(ni.Task.Lifecycle) {
				out = append(out, "C1: NEXT surfaces terminal row "+ni.Task.DocID+
					" (lifecycle "+ni.Task.Lifecycle+") as a resumable — dead claim target")
			}
			if ni.Task.Claim != nil && ni.Task.Claim.Worker != "" {
				out = append(out, "C1: NEXT surfaces "+ni.Task.DocID+
					" as a resumable while worker "+ni.Task.Claim.Worker+" still holds it")
			}
		}
	}

	// C2 — nothing ready, so nothing may be surfaced AS ready.
	if readyOutsideNow == 0 && surfacedReady > 0 {
		out = append(out, "C2: the ready overlay is empty outside NOW yet the NEXT strip "+
			"surfaces "+itoa(surfacedReady)+" ready row(s) — a fabricated claim control")
	}

	return out
}

// itoa is the tiny local int formatter (no strconv import for one call site).
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
