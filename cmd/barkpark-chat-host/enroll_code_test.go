package main

import (
	"strings"
	"testing"
)

// TestEnrollReadsCodeFromStdin: with no --token, enroll takes the code from
// the first line of stdin, so `printf '%s\n' CODE | barkpark-chat-host enroll`
// and bp chat-host add over ssh never put it in argv.
func TestEnrollReadsCodeFromStdin(t *testing.T) {
	code, err := readEnrollCode(strings.NewReader("  abc-DEF_123  \nsecond line\n"))
	if err != nil || code != "abc-DEF_123" {
		t.Fatalf("readEnrollCode = %q, %v; want the trimmed first line", code, err)
	}
	code, err = readEnrollCode(strings.NewReader("no-newline"))
	if err != nil || code != "no-newline" {
		t.Fatalf("a code without a trailing newline = %q, %v", code, err)
	}
}

func TestEnrollFlagStillWins(t *testing.T) {
	code, err := enrollCode(" from-flag ")
	if err != nil || code != "from-flag" {
		t.Fatalf("enrollCode(--token) = %q, %v", code, err)
	}
}

func TestEnrollRefusesAnEmptyStdin(t *testing.T) {
	_, err := readEnrollCode(strings.NewReader("\n"))
	if err == nil || !strings.Contains(err.Error(), "no enrollment code") {
		t.Fatalf("an empty stdin must be refused with a hint, got %v", err)
	}
}
