package main

import (
	"testing"
	"unicode/utf8"
)

// capitalize must upper-case the first *rune*, not the first byte — a byte
// slice corrupts leading multi-byte runes (localized status labels) into
// U+FFFD garbage in the desk tree.
func TestCapitalizeRuneAware(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"draft", "Draft"},
		{"übersetzt", "Übersetzt"},
		{"已发布", "已发布"},
		{"", ""},
	}
	for _, tc := range cases {
		got := capitalize(tc.in)
		if got != tc.want {
			t.Errorf("capitalize(%q) = %q, want %q", tc.in, got, tc.want)
		}
		if !utf8.ValidString(got) {
			t.Errorf("capitalize(%q) = %q produced invalid UTF-8", tc.in, got)
		}
	}
}
