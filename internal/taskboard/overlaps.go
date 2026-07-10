package taskboard

// overlaps.go — the claimed-collision report (df-file-edge, wish part 3).
//
// The dispatch frontier answers "which READY tasks are safe to batch". This
// answers the honest complement: of the tasks ALREADY claimed and in flight
// (board.Now), do any two share a surface — a collision the orchestrator should
// see NOW, on `bp task frontier`, rather than discover at merge time. It reuses
// the SAME file/area truth the frontier's interference model reads (FilesOf,
// areasOf), so the report can never drift from the admission decision.

import "sort"

// OverlapPair names two IN-PROGRESS claimed tasks whose declared blast radii
// intersect: the two bareIDs, their claim workers, the shared surface, and the
// kind of collision ("files" — a declared path overlap, authoritative; or
// "area" — an authored `area:` surface overlap). AID < BID always.
type OverlapPair struct {
	AID     string
	BID     string
	AWorker string
	BWorker string
	Shared  string // the shared file path, or "area:<tok>"
	Kind    string // "files" | "area"
}

// ClaimOverlaps reports pairwise collisions across the in_progress claim set
// (board.Now). Two claims collide when their declared `files:` sets intersect
// (authoritative), or — absent a file collision — their AUTHORED `area:`
// surfaces intersect. Undeclared claims never collide: an unproven stranger has
// nothing to surface, mirroring the frontier's abstain rule. Deterministic:
// pairs sorted by (AID, BID); within a pair the file signal wins over area.
func ClaimOverlaps(now []Task) []OverlapPair {
	var pairs []OverlapPair
	for i := 0; i < len(now); i++ {
		for j := i + 1; j < len(now); j++ {
			a, b := now[i], now[j]
			if shared, ok := filesOverlapReason(FilesOf(a), FilesOf(b)); ok {
				pairs = append(pairs, mkOverlapPair(a, b, shared, "files"))
				continue
			}
			ai, bi := areasOf(a), areasOf(b)
			if ai.authored && bi.authored && areasOverlap(ai, bi) {
				pairs = append(pairs, mkOverlapPair(a, b, areaOverlapLabel(ai, bi), "area"))
			}
		}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].AID != pairs[j].AID {
			return pairs[i].AID < pairs[j].AID
		}
		return pairs[i].BID < pairs[j].BID
	})
	return pairs
}

// mkOverlapPair builds a pair with AID < BID, carrying each side's claim worker.
func mkOverlapPair(a, b Task, shared, kind string) OverlapPair {
	aid, bid := bareID(a.DocID), bareID(b.DocID)
	aw, bw := claimWorker(a), claimWorker(b)
	if bid < aid {
		aid, bid = bid, aid
		aw, bw = bw, aw
	}
	return OverlapPair{AID: aid, BID: bid, AWorker: aw, BWorker: bw, Shared: shared, Kind: kind}
}
