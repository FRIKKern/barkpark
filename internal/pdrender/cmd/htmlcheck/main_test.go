package main

import (
	"strings"
	"testing"

	"golang.org/x/net/html"
)

func TestPaperBodyEvidence(t *testing.T) {
	tests := []struct {
		name         string
		mode         string
		source       string
		found        bool
		text         string
		headingCount int
	}{
		{
			name:         "GUI uses the authored article and ignores page chrome",
			mode:         "gui",
			source:       `<html><body>Chrome<article id="paper-body"><h1>Paper</h1><p>Readable</p><script>hidden</script></article></body></html>`,
			found:        true,
			text:         "Paper Readable",
			headingCount: 1,
		},
		{
			name:   "email includes visible text and image alternatives",
			mode:   "email",
			source: `<html><body class="bp-paper-surface"><p>Mail</p><img alt="Diagram"><span aria-hidden="true">hidden</span><span hidden>also hidden</span></body></html>`,
			found:  true,
			text:   "Mail Diagram",
		},
		{
			name:   "empty authored GUI body remains empty",
			mode:   "gui",
			source: `<html><body>Chrome<article id="paper-body"></article></body></html>`,
			found:  true,
			text:   "",
		},
		{
			name:   "missing GUI body marker fails closed",
			mode:   "gui",
			source: `<html><body><main>Shell only</main></body></html>`,
			found:  false,
			text:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			doc, err := html.Parse(strings.NewReader(tt.source))
			if err != nil {
				t.Fatal(err)
			}
			target := findTarget(doc, tt.mode)
			if (target != nil) != tt.found {
				t.Fatalf("target found = %v, want %v", target != nil, tt.found)
			}
			if target == nil {
				return
			}
			var parts []string
			headings := 0
			collectVisible(target, false, &parts, &headings)
			got := strings.Join(strings.Fields(strings.Join(parts, " ")), " ")
			if got != tt.text {
				t.Fatalf("visible text = %q, want %q", got, tt.text)
			}
			if headings != tt.headingCount {
				t.Fatalf("heading count = %d, want %d", headings, tt.headingCount)
			}
		})
	}
}

func TestHasSemanticText(t *testing.T) {
	tests := map[string]bool{
		"":          false,
		" / — ":     false,
		"I":         true,
		"version 2": true,
		"å":         true,
		"∑":         true,
		"🐕":         true,
	}
	for input, want := range tests {
		if got := hasSemanticText(input); got != want {
			t.Errorf("hasSemanticText(%q) = %v, want %v", input, got, want)
		}
	}
}
