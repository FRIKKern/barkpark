//go:build js && wasm

package main

import "testing"

// xterm256 is the ANSI-to-HTML boundary parser on pdrender-wasm's declared-
// untrusted entrypoint. It must never panic, regardless of what string it is
// handed, even though document content cannot reach it today (sanitizeText/
// sanitizeURL strip ESC upstream) — a boundary parser must be safe on its own
// terms, not on a caller's promise.
func TestXterm256_Safety(t *testing.T) {
	cases := []struct {
		name string
		in   string
	}{
		{"negative", "-1"},
		{"out-of-range-high", "256"},
		{"way-out-of-range-high", "99999"},
		{"non-numeric", "not-a-number"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("xterm256(%q) panicked: %v", tc.in, r)
				}
			}()
			got := xterm256(tc.in)
			if got != xterm256Fallback {
				t.Fatalf("xterm256(%q) = %q, want fallback %q", tc.in, got, xterm256Fallback)
			}
		})
	}
}

// TestXterm256_ValidInputsUnchanged pins the exact hex strings the
// pre-existing implementation returns for valid input, so the guard added
// for out-of-range/non-numeric input never perturbs in-range behaviour.
func TestXterm256_ValidInputsUnchanged(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"0", "#1c1c1c"},   // basic16[0]
		{"15", "#eaf3ee"},  // basic16[15]
		{"16", "#000000"},  // cube, first entry (0,0,0)
		{"231", "#ffffff"}, // cube, last entry (5,5,5)
		{"232", "#080808"}, // greyscale ramp, first entry
		{"255", "#eeeeee"}, // greyscale ramp, last entry
	}

	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			got := xterm256(tc.in)
			if got != tc.want {
				t.Errorf("xterm256(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
