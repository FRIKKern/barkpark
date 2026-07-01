package main

import (
	"testing"
	"time"
)

func TestTimeAgo(t *testing.T) {
	now := time.Now()
	tests := []struct {
		name string
		in   time.Time
		want string
	}{
		{"zero", time.Time{}, ""},
		{"minutes", now.Add(-5 * time.Minute), "5m ago"},
		{"hours", now.Add(-3 * time.Hour), "3h ago"},
		{"days", now.Add(-48 * time.Hour), "2d ago"},
		{"future", now.Add(2 * time.Minute), "just now"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := timeAgo(tc.in); got != tc.want {
				t.Errorf("timeAgo(%v) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
