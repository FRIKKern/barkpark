package cli

// drW22GateProbe exists only to make this PR's changed-path set include
// internal/cli/**, so the verifier can measure which REQUIRED contexts render
// for the wave-22 bp-CLI-reader siting. THROWAWAY — never merges.
func drW22GateProbe() string { return "dr-w22-gate-probe" }

var _ = drW22GateProbe
