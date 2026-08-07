package main

import "testing"

// realGuerrillaLoadAvg is a VERBATIM /proc/loadavg line captured off the live
// guerrilla box over ssh on 2026-08-06 (`cat /proc/loadavg; nproc` → the line
// below, 2 cores). It is kept real rather than synthesized on purpose: the whole
// point of this slice is that fields[2] was already sitting in memory, and a
// hand-written fixture cannot prove we read the field the kernel actually
// prints. Per core this reads load15 5.44 / 2 = 2.72 — a box the fleet payload
// still calls healthy.
const realGuerrillaLoadAvg = "5.32 5.75 5.44 3/382 67892\n"

// TestParseLoadAvg pins the parse of both averages and the failure path. It is
// the twin of TestParseSwapPercent: the arithmetic is pure so its hazards are
// reachable from a test, which loadProcProbe's inline read never was.
func TestParseLoadAvg(t *testing.T) {
	tests := []struct {
		name       string
		in         string
		wantLoad1  float64
		wantLoad15 float64
		wantErr    bool
		why        string
	}{
		{
			name:       "real captured kernel line",
			in:         realGuerrillaLoadAvg,
			wantLoad1:  5.32,
			wantLoad15: 5.44,
			why:        "fields[0] and fields[2] of a line the kernel actually printed",
		},
		{
			name:       "load15 is field TWO, not field one or three",
			in:         "0.64 1.50 1.89 1/200 4242\n",
			wantLoad1:  0.64,
			wantLoad15: 1.89,
			why: "the live shape this field exists for: quiet in the last minute, " +
				"sustained-busy over fifteen. Reading fields[1] (1.50) would be the " +
				"5-minute average and understate it",
		},
		{
			name:       "an idle box is measured, not an error",
			in:         "0.00 0.00 0.00 1/120 900\n",
			wantLoad1:  0,
			wantLoad15: 0,
			why:        "zero load is a real reading; only the caller's -1 means unmeasured",
		},
		{
			name:       "no trailing newline still parses",
			in:         "1.00 2.00 3.00 2/50 7",
			wantLoad1:  1,
			wantLoad15: 3,
			why:        "strings.Fields does not depend on the terminator",
		},
		{
			name:    "short line (only two averages) errors — never half a measurement",
			in:      "0.64 1.50\n",
			wantErr: true,
			why: "landing load1 beside a fabricated load15 would read as 'busy now, " +
				"quiet for fifteen minutes', the precise inverse of the truth",
		},
		{
			name:    "empty file errors",
			in:      "",
			wantErr: true,
			why:     "an unreadable /proc must reach the caller as an error, not as 0",
		},
		{
			name:    "garbled load15 errors even though load1 parses",
			in:      "0.64 1.50 NaNsense 1/200 4242\n",
			wantErr: true,
			why:     "both fields or neither",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l1, l15, err := parseLoadAvg([]byte(tt.in))
			if tt.wantErr {
				if err == nil {
					t.Fatalf("err = nil, want an error (%s)", tt.why)
				}
				if l1 != 0 || l15 != 0 {
					t.Errorf("(load1, load15) = (%v, %v) on an error path, want (0, 0)", l1, l15)
				}
				return
			}
			if err != nil {
				t.Fatalf("err = %v, want nil (%s)", err, tt.why)
			}
			if l1 != tt.wantLoad1 {
				t.Errorf("load1 = %v, want %v (%s)", l1, tt.wantLoad1, tt.why)
			}
			if l15 != tt.wantLoad15 {
				t.Errorf("load15 = %v, want %v (%s)", l15, tt.wantLoad15, tt.why)
			}
		})
	}
}
