package taskboard

// WIRING STUB — lead deletes at integration.
//
// This detail slice owns the REAL MarkdownBlocks (mdlite.go). It still builds
// in parallel with the wave-5 SUBSTRATE slice, which owns TaskDetail.PaperRefs
// (charter §wave-5 slice ownership). This single stand-in honors the frozen
// wave-5 signature exactly, so deleting this file at merge IS the integration.
// Detail fixtures deliberately keep design_doc/papers[] populated so the
// PAPERS rail exercises the same semantics the substrate slice will land.

// PaperRefs — STUB with the frozen contract's exact semantics: design_doc
// first, ∪ papers[], deduped, dropping empties.
func (d TaskDetail) PaperRefs() []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		if s == "" || seen[s] {
			return
		}
		seen[s] = true
		out = append(out, s)
	}
	add(d.DesignDoc)
	for _, p := range d.Papers {
		add(p)
	}
	return out
}
