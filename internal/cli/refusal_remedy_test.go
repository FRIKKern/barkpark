package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestRefuseWithRemedyCarriesTheHintOnBothChannels is the unit half: the machine
// envelope keeps `hint` as a field, and the human shapes get it as the house
// `  hint: …` stderr line. Before this helper, the human shapes got `msg` alone
// — renderErrorEnvelope returns false for table and minimal, and every caller
// stopped there.
func TestRefuseWithRemedyCarriesTheHintOnBothChannels(t *testing.T) {
	t.Run("json keeps it as a field", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "json"
		refuseWithRemedy(out, "unreadable_read", "it broke", "do this instead")

		var env struct {
			OK    bool `json:"ok"`
			Error struct {
				Code    string `json:"code"`
				Message string `json:"message"`
				Hint    string `json:"hint"`
			} `json:"error"`
		}
		if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
			t.Fatalf("stdout is not the error envelope: %v (%s)", err, stdout.String())
		}
		if env.OK || env.Error.Code != "unreadable_read" || env.Error.Hint != "do this instead" {
			t.Errorf("envelope = %+v, want the code and hint intact", env.Error)
		}
		if stderr.Len() != 0 {
			t.Errorf("machine shape must not also write stderr: %q", stderr.String())
		}
	})

	for _, shape := range []string{"table", "minimal"} {
		t.Run(shape+" gets it on stderr", func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = shape
			refuseWithRemedy(out, "unreadable_read", "it broke", "do this instead")
			got := stderr.String()
			if !strings.Contains(got, "it broke") {
				t.Errorf("message missing: %q", got)
			}
			if !strings.Contains(got, "hint: do this instead") {
				t.Errorf("REMEDY missing on the human channel: %q", got)
			}
			if stdout.Len() != 0 {
				t.Errorf("human shape must not write stdout: %q", stdout.String())
			}
		})
	}

	t.Run("no hint means no hint line", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "table"
		refuseWithRemedy(out, "some_code", "it broke", "")
		if strings.Contains(stderr.String(), "hint:") {
			t.Errorf("invented a hint line where there is no remedy: %q", stderr.String())
		}
	})
}

// TestReaderLawRefusalsAllCarryTheirRemedy walks the reader-law fences that fire
// on a single response, in the two HUMAN shapes — the audience that was losing
// the remedy. Wave 27's --all walk has its own suite in paginate_all_test.go.
func TestReaderLawRefusalsAllCarryTheirRemedy(t *testing.T) {
	cases := []struct {
		name     string
		run      func(out *writer) (int, bool)
		wantHint string
	}{
		{
			name: "paginated default page (wave 28)",
			run: func(out *writer) (int, bool) {
				return refuseUnreadableDefaultPage(out, paginatedReadCommand(50), http.StatusOK, []byte(`{}`))
			},
			wantHint: "the transport, not the query",
		},
		{
			name: "write receipt (wave 29)",
			run: func(out *writer) (int, bool) {
				cmd := nonPaginatedReadCommand()
				cmd.Writes = true
				return screenWriteReceipt(out, cmd, http.StatusOK, []byte(`{}`))
			},
			wantHint: "the transport, not the write",
		},
		{
			name: "non-paginated read",
			run: func(out *writer) (int, bool) {
				return screenUnpaginatedRead(out, nonPaginatedReadCommand(), http.StatusOK, []byte(`<html><body>502</body></html>`), "")
			},
			wantHint: "the transport, not the query",
		},
	}

	for _, tc := range cases {
		for _, shape := range []string{"table", "minimal"} {
			t.Run(tc.name+"/"+shape, func(t *testing.T) {
				var stdout, stderr bytes.Buffer
				out := newWriter(&stdout, &stderr)
				out.output = shape
				code, handled := tc.run(out)
				if !handled || code == exitOK {
					t.Fatalf("handled=%v code=%d — the fence did not fire", handled, code)
				}
				if !strings.Contains(stderr.String(), tc.wantHint) {
					t.Errorf("no remedy on the human channel; stderr=%q", stderr.String())
				}
			})
		}
	}
}

// TestNoRefusalDropsItsHint is the structural guard, and the reason this file
// exists rather than three more assertions: it scans the package source for the
// SHAPE of the bug — a renderErrorEnvelope call passing a non-empty hint whose
// else-branch prints the message alone. Every such site silently withholds the
// remedy from table and minimal output, and the wave-27/28/29 refusals did
// exactly that while their `-o json` envelope carried a carefully written one.
//
// A new refusal must either route through refuseWithRemedy or print the hint
// itself. The sites where withholding it IS correct are recorded below with the
// reason, for whoever reads a failure here:
//
//   - errors.go usageErrHintf — the usageHelp block already shows the
//     suggestion on stderr (documented at the function).
//   - scaffy_cmd.go's validation/drift refusals — they print each finding WITH
//     its own hint inline, which is strictly more than the summary hint.
//   - seed_cmd.go, tinker_cmd.go, servers_cmd.go — print the hint by hand.
//
// None of those match the pattern below, so the guard needs no allowlist: the
// pattern IS "computed a remedy, then printed only the message".
func TestNoRefusalDropsItsHint(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("reading the package dir: %v", err)
	}
	// A call passing a hint literal or named constant (i.e. NOT `, "", "")`),
	// immediately followed by a lone userErr and a closing brace.
	bad := regexp.MustCompile(`if !renderErrorEnvelope\(out, [^\n]*?, "", (?:[A-Za-z_][A-Za-z0-9_]*|"[^"]+")\) \{\n\s*out\.userErr\("[^"]*", [^\n]*\)\n\s*\}`)

	scanned := 0
	var offenders []string
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("reading %s: %v", name, err)
		}
		scanned++
		for _, m := range bad.FindAll(src, -1) {
			offenders = append(offenders, name+": "+strings.Join(strings.Fields(string(m)), " "))
		}
	}
	if scanned == 0 {
		t.Fatal("scanned no source files — this guard is measuring nothing")
	}
	if len(offenders) != 0 {
		t.Errorf("these refusals compute a remedy and then withhold it from table/minimal output — route them through refuseWithRemedy, or print the hint yourself (see this test's doc comment for the sites where that is already correct):\n  %s",
			strings.Join(offenders, "\n  "))
	}
}
