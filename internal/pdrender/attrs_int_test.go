package pdrender

import (
	"math"
	"testing"
)

func TestAttrIntFloat64(t *testing.T) {
	const def = 7

	cases := []struct {
		name string
		in   float64
		want int
	}{
		// Whole floats within int64 range still coerce.
		{"whole", 42.0, 42},
		// Values outside int64 range must fall through to the default rather
		// than overflowing int(v) — which is implementation-defined in Go.
		{"overflow positive", 1e19, def},
		{"overflow negative", -1e19, def},
		{"NaN", math.NaN(), def},
		{"+Inf", math.Inf(1), def},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := map[string]any{"n": tc.in}
			if got := attrInt(m, "n", def); got != tc.want {
				t.Errorf("attrInt(%v) = %d, want %d", tc.in, got, tc.want)
			}
		})
	}
}
