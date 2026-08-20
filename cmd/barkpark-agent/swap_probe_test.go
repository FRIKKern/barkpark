package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// meminfo builds a realistic /proc/meminfo body. SwapCached is included BEFORE
// the swap sizing lines because that is where the kernel prints it and because
// it is the field a sloppy prefix match steals.
func meminfo(swapCached, swapTotal, swapFree string) []byte {
	return []byte(strings.Join([]string{
		"MemTotal:        3911580 kB",
		"MemFree:          120000 kB",
		"MemAvailable:    1641988 kB",
		"Cached:           900000 kB",
		"SwapCached:      " + swapCached + " kB",
		"SwapTotal:       " + swapTotal + " kB",
		"SwapFree:        " + swapFree + " kB",
		"Dirty:               128 kB",
		"",
	}, "\n"))
}

// TestParseSwapPercent is the repo's first /proc parser harness. cpuProcProbe,
// memProcProbe, loadProcProbe and readCPUStat all read their files inline and
// are unreachable from a test to this day; parseSwapPercent is pure so its
// arithmetic and its hazards can actually be pinned.
func TestParseSwapPercent(t *testing.T) {
	tests := []struct {
		name      string
		in        []byte
		wantPct   int
		wantBytes int64
		wantErr   bool
		why       string
	}{
		{
			name:      "guerrilla under real pressure",
			in:        meminfo("512", "2097148", "2328"),
			wantPct:   100, // 99.889% rounds to 100
			wantBytes: 2097148 * 1024,
			why:       "the measured live reading: 2 GiB of swap all but exhausted",
		},
		{
			name:      "configured but idle",
			in:        meminfo("0", "2097148", "2097148"),
			wantPct:   0,
			wantBytes: 2097148 * 1024,
			why:       "0% of a real 2 GiB is a DIFFERENT fact from a swapless box; the total is what distinguishes them",
		},
		{
			name:      "swapless box",
			in:        meminfo("0", "0", "0"),
			wantPct:   0,
			wantBytes: 0,
			why:       "no swap configured is a measurement, not a failure",
		},
		{
			name:      "SwapCached must not be read as swap sizing",
			in:        meminfo("999999", "1000", "250"),
			wantPct:   75,
			wantBytes: 1000 * 1024,
			why:       "fields are matched by equality; a prefix match would read SwapCached's 999999 as the total",
		},
		{
			name:      "free exceeds total is clamped, never negative",
			in:        meminfo("0", "1000", "4000"),
			wantPct:   0,
			wantBytes: 1000 * 1024,
			why:       "a torn read must clamp to 0%, not report a negative percent",
		},
		{
			name:    "swap lines absent entirely",
			in:      []byte("MemTotal:        3911580 kB\nMemFree:  120000 kB\n"),
			wantErr: true,
			why:     "a meminfo with no swap fields is unmeasurable, which is the -1 sentinel's job",
		},
		{
			name:    "unparseable swap total",
			in:      meminfo("0", "notanumber", "10"),
			wantErr: true,
			why:     "garbage must error rather than silently become 0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pct, total, err := parseSwapPercent(tt.in)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("err = nil, want an error — %s (got pct=%d total=%d)", tt.why, pct, total)
				}
				if pct != -1 || total != -1 {
					t.Errorf("on error got (%d, %d), want both -1 sentinels", pct, total)
				}
				return
			}
			if err != nil {
				t.Fatalf("err = %v, want nil — %s", err, tt.why)
			}
			if pct != tt.wantPct {
				t.Errorf("pct = %d, want %d — %s", pct, tt.wantPct, tt.why)
			}
			if total != tt.wantBytes {
				t.Errorf("totalBytes = %d, want %d — %s", total, tt.wantBytes, tt.why)
			}
		})
	}
}

// TestSwaplessBoxIsZeroNotSentinel is the named guard for the ONE place this
// parser deliberately diverges from memProcProbe. Its failure message states
// the consequence so a future "harmonize the /proc parsers" refactor goes red
// with the reason attached, not just red.
func TestSwaplessBoxIsZeroNotSentinel(t *testing.T) {
	pct, total, err := parseSwapPercent(meminfo("0", "0", "0"))
	if err != nil {
		t.Fatalf("parseSwapPercent errored on a swapless box (err = %v).\n"+
			"CONSEQUENCE: copying memProcProbe's `total <= 0 -> error` guard turns EVERY swapless box\n"+
			"into swap_used_percent = -1 (\"could not measure\"), when the truth is \"measured: no swap\".\n"+
			"SwapTotal: 0 is an ordinary state; MemTotal: 0 is a bad read. They are not the same guard.", err)
	}
	if pct != 0 || total != 0 {
		t.Fatalf("swapless box returned (%d, %d), want (0, 0).\n"+
			"CONSEQUENCE: the -1 sentinel means \"unmeasurable\". A swapless box IS measurable and the\n"+
			"answer is none; swap_total_bytes = 0 is exactly what tells a consumer \"none configured\"\n"+
			"apart from \"0%% used of 2 GiB\".", pct, total)
	}
}

// TestParseSmapsRollup pins the BEAM footprint arithmetic, including that
// SwapPss is NOT folded into Swap.
func TestParseSmapsRollup(t *testing.T) {
	rollup := []byte(strings.Join([]string{
		"55e0d2a00000-ffffffffff601000 ---p 00000000 00:00 0 [rollup]",
		"Rss:             1600000 kB",
		"Pss:             1564672 kB",
		"Shared_Clean:       2048 kB",
		"Private_Dirty:   1500000 kB",
		"Swap:            1204224 kB",
		"SwapPss:          900000 kB",
		"Locked:                0 kB",
		"",
	}, "\n"))

	pss, swap, err := parseSmapsRollup(rollup)
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if pss != 1564672*1024 {
		t.Errorf("pss = %d, want %d bytes", pss, int64(1564672)*1024)
	}
	if swap != 1204224*1024 {
		t.Errorf("swap = %d, want %d bytes — SwapPss must not be folded in", swap, int64(1204224)*1024)
	}

	if _, _, err := parseSmapsRollup([]byte("Rss: 100 kB\n")); err == nil {
		t.Error("a rollup missing Pss/Swap must error, not report zeros")
	}
}

// TestBeamProbeNotFound proves the not-found path: a /proc with no beam.smp
// errors, so BeamPSSBytes/BeamSwapBytes keep their -1 sentinels. An un-run BEAM
// is not a zero-footprint BEAM.
func TestBeamProbeNotFound(t *testing.T) {
	procRoot := t.TempDir()
	writeFakeProc(t, procRoot, "1", "systemd", "")
	writeFakeProc(t, procRoot, "42", "postgres", "")

	pss, swap, err := beamSmapsProbeIn(procRoot)
	if err == nil {
		t.Fatal("err = nil, want an error when no beam.smp process exists")
	}
	if pss != -1 || swap != -1 {
		t.Errorf("got (%d, %d), want both -1 sentinels when the BEAM is not found", pss, swap)
	}

	// An unreadable /proc is likewise an error, not zeros.
	if _, _, err := beamSmapsProbeIn(filepath.Join(procRoot, "does-not-exist")); err == nil {
		t.Error("an unreadable proc root must error")
	}
}

// TestBeamProbeFindsBeamAmongProcesses proves the happy path end-to-end
// (scan → rollup read → parse) without a live BEAM.
func TestBeamProbeFindsBeamAmongProcesses(t *testing.T) {
	procRoot := t.TempDir()
	writeFakeProc(t, procRoot, "1", "systemd", "")
	writeFakeProc(t, procRoot, "7", beamComm, "Pss:   1024 kB\nSwap:   512 kB\n")
	// A non-pid directory must not confuse the scan.
	if err := os.MkdirAll(filepath.Join(procRoot, "self"), 0o755); err != nil {
		t.Fatal(err)
	}

	pss, swap, err := beamSmapsProbeIn(procRoot)
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if pss != 1024*1024 || swap != 512*1024 {
		t.Errorf("got (%d, %d), want (%d, %d)", pss, swap, 1024*1024, 512*1024)
	}
}

// writeFakeProc lays down procRoot/<pid>/comm and, when rollup is non-empty,
// procRoot/<pid>/smaps_rollup.
func writeFakeProc(t *testing.T, procRoot, pid, comm, rollup string) {
	t.Helper()
	dir := filepath.Join(procRoot, pid)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "comm"), []byte(comm+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rollup != "" {
		if err := os.WriteFile(filepath.Join(dir, "smaps_rollup"), []byte(rollup), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
