package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// task-48a556bfbe221dcf: `bp cloud warm-pool` puts the worker's reported pool
// size next to the ready count, and says so in words when the pool is off on
// the worker while boxes stand ready (the 2026-11-19 case).

func runWarmPool(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudWarmPool(w, globals{}, args)
	return sout.String(), serr.String(), code
}

func TestWarmPoolSaysOffWhenWorkerTargetIsZero(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ready":2,"worker_target":0,"worker_pool":"off","worker_seen_at":"2026-11-19T10:00:00Z","worker_seen_ago_s":4}`)
	stdout, stderr, code := runWarmPool(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr: %s", code, stderr)
	}
	assertOperatorCall(t, rec, "GET", "/v1/operator/warm-pool")
	for _, want := range []string{
		"warm pool is OFF on the worker (target 0) — 2 ready boxes will not be used",
		"worker seen 4 s ago",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("missing %q:\n%s", want, stdout)
		}
	}
}

func TestWarmPoolRendersReadyTargetAndAge(t *testing.T) {
	autoupdateServer(t, 200, `{"ready":2,"worker_target":2,"worker_pool":"on","worker_seen_at":"2026-11-19T10:00:00Z","worker_seen_ago_s":4}`)
	stdout, _, code := runWarmPool(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if want := "warm pool: 2 ready · worker target 2 · seen 4 s ago"; !strings.Contains(stdout, want) {
		t.Fatalf("missing %q:\n%s", want, stdout)
	}
	if strings.Contains(stdout, "OFF") {
		t.Fatalf("an on pool rendered as OFF:\n%s", stdout)
	}
}

// An unheard worker must read unknown — never 0, never on — and an older
// control plane (only {ready}) says it cannot tell.
func TestWarmPoolUnknownWorkerSaysUnknown(t *testing.T) {
	for _, body := range []string{
		`{"ready":2,"worker_target":null,"worker_pool":"unknown","worker_seen_at":null,"worker_seen_ago_s":null}`,
		`{"ready":2}`,
	} {
		autoupdateServer(t, 200, body)
		stdout, _, code := runWarmPool(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		if !strings.Contains(stdout, "warm pool: 2 ready · worker target unknown") {
			t.Fatalf("body %s: want unknown target:\n%s", body, stdout)
		}
		if strings.Contains(stdout, "OFF") || strings.Contains(stdout, "target 0") {
			t.Fatalf("body %s: an unknown worker rendered as off:\n%s", body, stdout)
		}
	}
}

func TestWarmPoolJSONPassesFieldsThrough(t *testing.T) {
	autoupdateServer(t, 200, `{"ready":2,"worker_target":0,"worker_pool":"off","worker_seen_at":"2026-11-19T10:00:00Z","worker_seen_ago_s":4}`)
	stdout, _, code := runWarmPool(t, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json out not decodable: %v\n%s", err, stdout)
	}
	if env["ready"] != float64(2) || env["worker_target"] != float64(0) || env["worker_pool"] != "off" || env["worker_seen_ago_s"] != float64(4) {
		t.Fatalf("json passthrough lost a field: %v", env)
	}
}

// A body this client cannot decode (a target too big for an int) still
// passes through -o json; the human view reports the decode failure.
func TestWarmPoolJSONPassesUndecodableBodyThrough(t *testing.T) {
	autoupdateServer(t, 200, `{"ready":2,"worker_target":99999999999999999999999,"worker_pool":"on"}`)
	stdout, stderr, code := runWarmPool(t, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, `"worker_pool"`) {
		t.Fatalf("json passthrough dropped the body:\n%s", stdout)
	}
	if _, stderr, code := runWarmPool(t, "table"); code == exitOK || !strings.Contains(stderr, "decode warm-pool status") {
		t.Fatalf("table view: exit %d, stderr %q; want a decode failure", code, stderr)
	}
}

func TestWarmPoolForbiddenNamesTheAllowlist(t *testing.T) {
	autoupdateServer(t, 403, `{"error":"forbidden","required":"platform_operator","scope":"platform"}`)
	_, stderr, code := runWarmPool(t, "table")
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth\nstderr: %s", code, stderr)
	}
	if !strings.Contains(stderr, "PLATFORM_ADMIN_EMAILS") {
		t.Fatalf("stderr = %q", stderr)
	}
}
