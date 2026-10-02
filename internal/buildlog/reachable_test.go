package buildlog

import "testing"

// TestReaderFetchableIsAShapeRule. The point of the predicate is that a scheme
// NOBODY enumerated fails by construction — so the table deliberately carries
// shapes that were never on anyone's list (ftp, s3, journal, a bare path, a
// scheme-relative URL) alongside the file:// case that motivated it.
func TestReaderFetchableIsAShapeRule(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want bool
	}{
		// Fetchable: the reader's own transport speaks these.
		{"https://logs.example.com/dep-1.log", true},
		{"http://10.0.0.4:4000/v1/sites/s/deployments/d/build-log", true},
		{"HTTPS://logs.example.com/dep-1.log", true}, // scheme is case-insensitive
		{"  https://logs.example.com/dep-1.log  ", true},

		// The motivating case.
		{"file:///var/lib/barkpark-builder/logs/dep-1.log", false},

		// Shapes nobody listed — these must fail WITHOUT the predicate naming them.
		{"ftp://logs.example.com/dep-1.log", false},
		{"s3://barkpark-logs/dep-1.log", false},
		{"journal:barkpark-builder", false},
		{"/var/lib/barkpark-builder/logs/dep-1.log", false},
		{"logs/dep-1.log", false},
		{"//logs.example.com/dep-1.log", false}, // scheme-relative: no scheme at all
		{"", false},
		{"   ", false},

		// An http(s) URL with no host names no machine the reader could reach.
		{"http:///var/log/x", false},
		{"https://", false},
	} {
		if got := ReaderFetchable(tc.raw); got != tc.want {
			t.Errorf("ReaderFetchable(%q) = %v, want %v", tc.raw, got, tc.want)
		}
	}
}

// TestWhereItActuallyLivesNeverInventsAShape: file:// degrades to its path
// (the only part with meaning); an unfamiliar shape is echoed, not rewritten.
func TestWhereItActuallyLivesNeverInventsAShape(t *testing.T) {
	for _, tc := range []struct{ raw, want string }{
		{"file:///var/lib/x/dep-1.log", "/var/lib/x/dep-1.log"},
		{"/var/lib/x/dep-1.log", "/var/lib/x/dep-1.log"},
		{"s3://bucket/dep-1.log", "s3://bucket/dep-1.log"},
		{"journal:barkpark-builder", "journal:barkpark-builder"},
		{"file://", "file://"},
	} {
		if got := WhereItActuallyLives(tc.raw); got != tc.want {
			t.Errorf("WhereItActuallyLives(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}
}
