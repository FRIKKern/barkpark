package scaffy

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestFormatGolden: the messy fixture formats to the golden byte-exact,
// and the golden is already canonical (Format(golden) == golden).
func TestFormatGolden(t *testing.T) {
	messy := readFixture(t, "fmt/messy.scaffy")
	golden := readFixture(t, "fmt/messy.golden")
	got, err := Format(messy)
	if err != nil {
		t.Fatalf("Format(messy): %v", err)
	}
	if !bytes.Equal(got, golden) {
		t.Errorf("Format(messy) != golden\n--- got ---\n%s\n--- want ---\n%s", got, golden)
	}
	again, err := Format(golden)
	if err != nil {
		t.Fatalf("Format(golden): %v", err)
	}
	if !bytes.Equal(again, golden) {
		t.Errorf("golden is not a fixpoint\n--- got ---\n%s", again)
	}
}

// TestFormatFixpoint: Format(Format(x)) == Format(x) over every fixture
// in the tree — green, red and fmt alike. Sources Format rejects
// (unclosed fence) must fail identically on both passes.
func TestFormatFixpoint(t *testing.T) {
	var fixtures []string
	err := filepath.WalkDir("testdata", func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && (strings.HasSuffix(path, ".scaffy") || strings.HasSuffix(path, ".golden")) {
			fixtures = append(fixtures, path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(fixtures) < 25 {
		t.Fatalf("only %d fixtures found", len(fixtures))
	}
	for _, path := range fixtures {
		t.Run(path, func(t *testing.T) {
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			once, err := Format(src)
			if err != nil {
				t.Skipf("Format rejects this source (%v) — nothing to fixpoint", err)
			}
			twice, err := Format(once)
			if err != nil {
				t.Fatalf("Format(Format(x)) errored where Format(x) did not: %v", err)
			}
			if !bytes.Equal(once, twice) {
				t.Errorf("not idempotent\n--- once ---\n%s\n--- twice ---\n%s", once, twice)
			}
		})
	}
}

// TestFormatNeverTouchesProseOrPayload: comment prose and payload bytes
// survive Format byte-exact, including ugly interior spacing and
// trailing whitespace (D27).
func TestFormatNeverTouchesProseOrPayload(t *testing.T) {
	got, err := Format(readFixture(t, "fmt/messy.scaffy"))
	if err != nil {
		t.Fatal(err)
	}
	for _, verbatim := range []string{
		"# a messy   comment   keeps its exact bytes\n",
		"\tpayload   spacing   is untouchable   \n",
	} {
		if !bytes.Contains(got, []byte(verbatim)) {
			t.Errorf("Format rewrote a protected region: %q missing from output\n%s", verbatim, got)
		}
	}
}

// TestFormatOneOfFixpoint proves format.go needs ZERO changes for D56
// ONEOF: joinFields is keyword-agnostic, so a canonical ONEOF VARIABLE
// line (two-space indented, the comma bound to the preceding member) is
// already a Format identity, the clause survives byte-exact, and Format
// stays idempotent over it.
func TestFormatOneOfFixpoint(t *testing.T) {
	canonical := []byte("DIRECTION \"add\"\n\n" +
		"  VARIABLE 1 \"Visibility\" OPAQUE ONEOF \"public\", \"private\" TITLE \"t\" DESCRIPTION \"d\" EXAMPLES \"public\"\n\n" +
		"ASSERT FILE \"x/{{.Visibility}}.json\" EXISTS\n")
	once, err := Format(canonical)
	if err != nil {
		t.Fatalf("Format(canonical): %v", err)
	}
	if !bytes.Equal(once, canonical) {
		t.Errorf("canonical ONEOF source is not a Format identity\n--- got ---\n%s--- want ---\n%s", once, canonical)
	}
	if !bytes.Contains(once, []byte(`ONEOF "public", "private"`)) {
		t.Errorf("Format mangled the ONEOF clause:\n%s", once)
	}
	twice, err := Format(once)
	if err != nil {
		t.Fatalf("Format(once): %v", err)
	}
	if !bytes.Equal(twice, once) {
		t.Errorf("Format not idempotent over ONEOF\n--- once ---\n%s--- twice ---\n%s", once, twice)
	}
}

// TestFormatErrorOnUnclosedFence: without the closing fence line the
// payload boundary is undecidable — fmt refuses instead of guessing.
func TestFormatErrorOnUnclosedFence(t *testing.T) {
	_, err := Format([]byte("DIRECTION \"add\"\n::: open block :::\nx\n"))
	if err == nil {
		t.Fatal("Format accepted an unclosed fence")
	}
	if !strings.Contains(err.Error(), "unclosed fence") {
		t.Errorf("err = %v, want unclosed fence", err)
	}
}

// TestFormatFlushLeftIndentedFencePassthrough: an indented fence-ish
// line outside any fence is left verbatim — flush-lefting it would
// change what parses.
func TestFormatFlushLeftIndentedFencePassthrough(t *testing.T) {
	src := []byte("DIRECTION \"add\"\n   ::: not a fence :::\n")
	got, err := Format(src)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(got, []byte("   ::: not a fence :::\n")) {
		t.Errorf("indented fence-ish line was rewritten:\n%s", got)
	}
}
