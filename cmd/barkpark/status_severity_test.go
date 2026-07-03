package main

import (
	"strings"
	"testing"
)

// The status line has three severities: green ✓ success, red ✕ error, and a
// neutral dim · notice/confirm prompt. A non-error notice must NOT render as a
// red ✕ (the bug this severity split fixes).
func TestStatusSeverityGlyphs(t *testing.T) {
	cases := []struct {
		name    string
		set     func(m *model)
		want    string // glyph that must appear
		notWant string // glyph that must NOT appear
	}{
		{
			name:    "error renders red cross",
			set:     func(m *model) { m.setStatus("save failed: boom", true) },
			want:    "✕",
			notWant: "·",
		},
		{
			name:    "success renders green check",
			set:     func(m *model) { m.setStatus("saved", false) },
			want:    "✓",
			notWant: "✕",
		},
		{
			name:    "info notice renders neutral dot, never a cross",
			set:     func(m *model) { m.setStatusInfo("no matches for \"zzz\"") },
			want:    "·",
			notWant: "✕",
		},
		{
			name:    "confirm prompt renders neutral dot, never a cross",
			set:     func(m *model) { m.setStatusInfo("delete \"Hello\"? press D again to confirm · esc cancel") },
			want:    "·",
			notWant: "✕",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := model{width: 120}
			tc.set(&m)
			bar := m.renderHelpBar()
			if !strings.Contains(bar, tc.want) {
				t.Errorf("status bar %q missing glyph %q", bar, tc.want)
			}
			if strings.Contains(bar, tc.notWant) {
				t.Errorf("status bar %q must not contain glyph %q", bar, tc.notWant)
			}
		})
	}
}

// setStatusInfo and setStatus keep the two severity flags mutually exclusive,
// and clearStatus resets all three fields.
func TestStatusSeverityFlags(t *testing.T) {
	var m model

	m.setStatus("boom", true)
	if !m.statusErr || m.statusInfo {
		t.Errorf("error: want statusErr=true statusInfo=false, got err=%v info=%v", m.statusErr, m.statusInfo)
	}

	m.setStatusInfo("heads up")
	if m.statusErr || !m.statusInfo {
		t.Errorf("info: want statusErr=false statusInfo=true, got err=%v info=%v", m.statusErr, m.statusInfo)
	}

	m.setStatus("saved", false)
	if m.statusErr || m.statusInfo {
		t.Errorf("ok: want both flags false, got err=%v info=%v", m.statusErr, m.statusInfo)
	}

	m.setStatusInfo("notice")
	m.clearStatus()
	if m.status != "" || m.statusErr || m.statusInfo {
		t.Errorf("clearStatus should reset all fields, got status=%q err=%v info=%v", m.status, m.statusErr, m.statusInfo)
	}
}
