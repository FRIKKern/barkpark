package cli

import (
	"os"
	"strconv"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Every pre-auth "not logged in — run `bp login` …" refusal in this package must
// also name BARKPARK_CLOUD_TOKEN, the non-interactive credential (row
// ssw11-cloud-token-source-receipt c1): a CI job that hits the refusal is told
// how to authenticate instead of being told to open a browser. The set is
// DERIVED from the source, not listed — the first cut of this fix covered the
// shared spawner preamble (7 callers) and missed 16 sibling sites spelled the
// same way one file over. A new refusal that forgets the hint reds here BY
// FILE:LINE.
func TestEveryNotLoggedInRefusalNamesTheEnvCredential(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	refusal := regexp.MustCompile("not logged in — run [`']bp login[`']")
	var missing []string
	seen := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(src), "\n") {
			if !refusal.MatchString(line) {
				continue
			}
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "//") {
				continue // prose about the refusal, not a refusal
			}
			seen++
			if !strings.Contains(line, "BARKPARK_CLOUD_TOKEN") && !strings.Contains(line, "CloudTokenEnv") {
				missing = append(missing, f+":"+strconv.Itoa(i+1)+"  "+trimmed)
			}
		}
	}
	if seen < 10 {
		t.Fatalf("the refusal scan found only %d site(s) — the pattern or the glob is broken; a census that sees nothing proves nothing", seen)
	}
	if len(missing) > 0 {
		t.Fatalf("%d of %d not-logged-in refusal(s) do not name BARKPARK_CLOUD_TOKEN, so a CI job hitting them is told to open a browser:\n  %s",
			len(missing), seen, strings.Join(missing, "\n  "))
	}
}

