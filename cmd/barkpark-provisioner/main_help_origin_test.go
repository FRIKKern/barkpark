package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// dwb-doc-lag-microfixes: the --control-url examples in this file once named
// a retired .dev control-plane host that Barkpark Cloud never served (the live apex is
// barkpark.cloud). A wrong example in operator help is copied into unit files,
// so this pins every --control-url example to the canonical origin and refuses
// the retired domain anywhere in the source.
func TestControlURLExamplesUseTheCanonicalOrigin(t *testing.T) {
	raw, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	src := string(raw)

	if strings.Contains(src, "barkpark.dev") {
		t.Fatalf("main.go names the retired barkpark.dev domain; the control plane lives at https://barkpark.cloud")
	}

	url := regexp.MustCompile(`https?://[A-Za-z0-9.\-]+`)
	examples := 0
	for i, line := range strings.Split(src, "\n") {
		if !strings.Contains(line, "control-url") {
			continue
		}
		for _, u := range url.FindAllString(line, -1) {
			examples++
			if u != "https://barkpark.cloud" {
				t.Errorf("main.go:%d: --control-url example %q, want https://barkpark.cloud", i+1, u)
			}
		}
	}
	// Anti-vacuity: the usage block and the flag help each carry one example.
	// Zero would mean the scan matched nothing, not that the help is correct.
	if examples < 2 {
		t.Fatalf("found %d --control-url example URL(s) in main.go, want at least 2 (usage block + flag help); the scan is not reading what it guards", examples)
	}
}
