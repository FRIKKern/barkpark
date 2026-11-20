package main

import (
	"bytes"
	"io"
	"strings"
	"testing"
	"time"
)

// TestEnrollSaysWhatItWaitsForOnASilentPipe: a stdin pipe that never sends a
// line (ssh host … enroll with nothing piped) prints what it is waiting for,
// then gives up with an error that says how to pass the code.
func TestEnrollSaysWhatItWaitsForOnASilentPipe(t *testing.T) {
	silent, w := io.Pipe()
	defer w.Close()
	var stderr bytes.Buffer

	_, err := awaitEnrollCode(silent, &stderr, 10*time.Millisecond, 80*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "pipe it in") {
		t.Fatalf("err = %v, want a give-up error that says how to pass the code", err)
	}
	if !strings.Contains(stderr.String(), "Waiting for the one-time code on stdin") {
		t.Fatalf("stderr = %q, want the waiting hint", stderr.String())
	}
}

// TestEnrollPipedCodeNeedsNoHint: a code that arrives at once is read with no
// hint printed.
func TestEnrollPipedCodeNeedsNoHint(t *testing.T) {
	var stderr bytes.Buffer
	code, err := awaitEnrollCode(strings.NewReader("abc\n"), &stderr, time.Second, time.Minute)
	if err != nil || code != "abc" {
		t.Fatalf("code = %q, err = %v", code, err)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want nothing", stderr.String())
	}
}
