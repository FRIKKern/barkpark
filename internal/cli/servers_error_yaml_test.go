package cli

import (
	"bytes"
	"strings"
	"testing"
)

// The error helpers must reach -o yaml parity with -o json: a scripting consumer
// that chose yaml should get a parseable `ok: false` envelope on failures, not a
// human `barkpark:`-prefixed stderr line.

func TestUseUnknownYAMLEmitsEnvelope(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "yaml"

	if code := useUnknown(w, &Config{}, "nope"); code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	got := stdout.String()
	if !strings.Contains(got, "ok: false") {
		t.Fatalf("yaml stdout missing `ok: false`:\n%s", got)
	}
	if strings.Contains(stderr.String(), "barkpark:") {
		t.Fatalf("yaml path leaked human stderr line:\n%s", stderr.String())
	}
}

func TestUseErrorYAMLEmitsEnvelope(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "yaml"

	if code := useError(w, "failed", "boom", exitGeneric); code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	got := stdout.String()
	if !strings.Contains(got, "ok: false") {
		t.Fatalf("yaml stdout missing `ok: false`:\n%s", got)
	}
	if strings.Contains(stderr.String(), "barkpark:") {
		t.Fatalf("yaml path leaked human stderr line:\n%s", stderr.String())
	}
}

func TestDoctorNoTargetYAMLEmitsEnvelope(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "yaml"

	doctorNoTarget(w, "no active Barkpark", &Config{})
	got := stdout.String()
	if !strings.Contains(got, "ok: false") {
		t.Fatalf("yaml stdout missing `ok: false`:\n%s", got)
	}
	if strings.Contains(stderr.String(), "barkpark:") {
		t.Fatalf("yaml path leaked human stderr line:\n%s", stderr.String())
	}
}
