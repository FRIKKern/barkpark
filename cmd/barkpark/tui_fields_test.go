package main

import (
	"math"
	"strconv"
	"testing"
)

// numberFieldAccepts mirrors the finite-number guard in commitFieldEdit's
// FieldNumber branch: a value is accepted only if it parses as a float AND is
// finite (ParseFloat returns +Inf/NaN with a nil error for "inf"/"nan"/"1e999",
// which json.Marshal later rejects — so the guard must reject them at input).
func numberFieldAccepts(t string) bool {
	f, err := strconv.ParseFloat(t, 64)
	return err == nil && !math.IsInf(f, 0) && !math.IsNaN(f)
}

func TestNumberFieldFiniteGuard(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"inf", false},
		{"nan", false},
		{"1e999", false},
		{"Inf", false},
		{"NaN", false},
		{"42", true},
		{"3.14", true},
		{"-1", true},
	}
	for _, c := range cases {
		if got := numberFieldAccepts(c.in); got != c.want {
			t.Errorf("numberFieldAccepts(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
