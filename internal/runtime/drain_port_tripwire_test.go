package runtime

import (
	"os"
	"strings"
	"testing"
)

// TestDrainContainerPortStaysIntegerInterpolation is a SOURCE tripwire, not a
// runtime-behavior test. drainContainer runs the ONLY surviving `sh -c` in
// internal/runtime:
//
//	docker ps -q --filter publish=%d | xargs -r docker stop -t 5
//
// That pipe genuinely needs a shell, so the shell here is not a defect. It is
// safe ONLY because the `publish=` filter value is interpolated with an integer
// verb (%d) and `port` is typed `int` (allocated by portAllocator) — no shell
// metacharacter can ever appear in it.
//
// This test guards the ONE regression that `go vet` cannot catch. A naive
// %d->%s flip while `port` stays `int` is already rejected by `go vet` at build
// time (printf verb / arg-type mismatch). The genuinely dangerous case is a
// COMPILING type-widening: someone changes `port int` to `port string` and
// switches the verb to %s, fixing every caller so the build passes and vet is
// silent. A runtime-behavior test drainpath would also pass. Only reading the
// source string catches it — so we assert the interpolation shape stays %d and
// that neither the injection-prone %s form nor a hand-rolled single-quote
// wrap ("publish='") has crept in.
//
// If this test reds, DO NOT relax it: the drain filter value must stay an
// integer. Reintroducing a string there reopens shell injection at the pipe.
func TestDrainContainerPortStaysIntegerInterpolation(t *testing.T) {
	src, err := os.ReadFile("runtime.go")
	if err != nil {
		t.Fatalf("read runtime.go: %v", err)
	}
	source := string(src)

	// The integer form must be present verbatim.
	if !strings.Contains(source, "publish=%d") {
		t.Errorf("drainContainer's `sh -c` filter no longer uses integer interpolation " +
			"(`publish=%%d` not found in runtime.go) — the port must stay typed int; " +
			"a string filter value reopens shell injection at the pipe")
	}

	// The string-verb form must be absent — that is the compiling type-widening
	// case (port -> string + %s) that go vet lets through.
	if strings.Contains(source, "publish=%s") {
		t.Errorf("drainContainer's `sh -c` filter uses `publish=%%s` (string interpolation) — " +
			"this is the vet-silent type-widening that reintroduces shell injection at the pipe; " +
			"revert to integer `publish=%%d`")
	}

	// A hand-rolled quoted form ("publish='...") is equally forbidden: it signals
	// someone started shell-quoting a non-integer value instead of keeping it int.
	if strings.Contains(source, "publish='") {
		t.Errorf("drainContainer's `sh -c` filter contains a quoted `publish='` value — " +
			"the filter value must stay a bare integer (`publish=%%d`), not a quoted string")
	}
}
