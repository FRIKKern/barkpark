package pdrender

import (
	"strconv"
	"testing"
)

func TestToStrFloat64(t *testing.T) {
	// Small integers still render clean, without a ".0".
	if got := toStr(float64(42)); got != "42" {
		t.Errorf("toStr(42.0) = %q, want %q", got, "42")
	}

	// Values too large for int64 must fall through to FormatFloat rather than
	// overflowing int64(x) — which is implementation-defined in Go.
	want := strconv.FormatFloat(1e19, 'g', -1, 64)
	if got := toStr(float64(1e19)); got != want {
		t.Errorf("toStr(1e19) = %q, want %q", got, want)
	}
}
