package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// THE DECISION UNDER TEST (pds-w28-named-codes-invisible-in-human-shapes):
// the HUMAN shapes name the code. renderErrorEnvelopeDetailed still switches on
// out.output and still emits the machine envelope for json/yaml ONLY; the
// table/minimal branch now prints `  code: <code>` on stderr after the message,
// the details and the hint.
//
// These tests are the ratchet for that decision, and they are RED under BOTH
// rejected alternatives — each assertion below is annotated with which:
//
//	REJECTED 1 "minimal joins the machine shapes": add `case "minimal":` to
//	renderErrorEnvelopeDetailed. Every TestNamedCodeReachesHumanShapes case for shape=minimal
//	goes red twice — the code line never reaches stderr AND stdout stops being
//	empty (TestNamedCodeHumanShapesKeepStdoutEmpty).
//
//	REJECTED 2 "record that codes are json/yaml-only": delete the humanErrorCode
//	calls (or its body). Every TestNamedCodeReachesHumanShapes case goes red for
//	table AND minimal.
//
// humanShapes is the pair the decision is about; machineShapes is what must NOT
// move.
var (
	humanShapes   = []string{"table", "minimal"}
	machineShapes = []string{"json", "yaml"}
)

// namedCodeSeams is one entry per SHARED refusal seam that a coded error can
// leave the CLI through. The four codes the filing measured — unreadable_list_page,
// pagination_stalled, request_failed and usage — each reach a reader through one
// of these.
var namedCodeSeams = []struct {
	name string
	code string
	emit func(out *writer)
}{
	{
		"renderError/classified",
		"validation_failed",
		func(out *writer) {
			renderError(out, classifyError(422, []byte(`{"error":{"code":"validation_failed","message":"invalid label","hint":"fix the tags","details":{"rule":"label_spine"}}}`)))
		},
	},
	{
		"useError",
		"request_failed",
		func(out *writer) { useError(out, "request_failed", "request failed: dial tcp: refused", exitGeneric) },
	},
	{
		"useErrorDetailed",
		"unknown_tag",
		func(out *writer) {
			useErrorDetailed(out, "unknown_tag", "unknown tag", exitValidation, json.RawMessage(`{"unknown":["frontent"]}`))
		},
	},
	{
		"refuseWithRemedy",
		"unreadable_list_page",
		func(out *writer) {
			refuseWithRemedy(out, "unreadable_list_page", "unreadable list page: HTTP 200 with a non-JSON body", unreadableListPageHint)
		},
	},
	{
		"usageErrf",
		"usage",
		func(out *writer) { usageErrf(out, nil, "unknown flag --nope") },
	},
	{
		"fetchSnapshotErr",
		"fetch_failed",
		func(out *writer) { fetchSnapshotErr(out, "task frontier", fmt.Errorf("dial tcp: refused")) },
	},
}

// The named code must reach the reader on table AND minimal.
//
// RED under REJECTED 2 (no humanErrorCode) for both shapes; RED under
// REJECTED 1 (minimal is a machine shape) for minimal.
func TestNamedCodeReachesHumanShapes(t *testing.T) {
	for _, seam := range namedCodeSeams {
		for _, shape := range humanShapes {
			t.Run(seam.name+"/"+shape, func(t *testing.T) {
				var stdout, stderr bytes.Buffer
				w := newWriter(&stdout, &stderr)
				w.output = shape
				seam.emit(w)

				want := "  code: " + seam.code + "\n"
				if !strings.Contains(stderr.String(), want) {
					t.Fatalf("stderr missing %q — an agent grepping for the code sees silence:\nstderr=%q\nstdout=%q", want, stderr.String(), stdout.String())
				}
			})
		}
	}
}

// The human shapes keep their channel: nothing goes to stdout. This is the
// assertion REJECTED 1 breaks — under it, -o minimal writes the JSON envelope
// to stdout, which is a different shape from its own SUCCESS output (a terse
// receipt line; --quiet resolves to minimal, see resolveOutputForCommand).
func TestNamedCodeHumanShapesKeepStdoutEmpty(t *testing.T) {
	for _, seam := range namedCodeSeams {
		for _, shape := range humanShapes {
			t.Run(seam.name+"/"+shape, func(t *testing.T) {
				var stdout, stderr bytes.Buffer
				w := newWriter(&stdout, &stderr)
				w.output = shape
				seam.emit(w)

				if stdout.Len() != 0 {
					t.Fatalf("%s wrote to stdout on shape %q — the human shapes refuse on stderr:\n%s", seam.name, shape, stdout.String())
				}
			})
		}
	}
}

// The machine shapes do not move: the envelope is still the ONLY thing on
// stdout, it still carries the code, and the human `  code:` line is NOT
// duplicated onto stderr.
func TestNamedCodeMachineShapesUnchanged(t *testing.T) {
	for _, seam := range namedCodeSeams {
		for _, shape := range machineShapes {
			t.Run(seam.name+"/"+shape, func(t *testing.T) {
				var stdout, stderr bytes.Buffer
				w := newWriter(&stdout, &stderr)
				w.output = shape
				seam.emit(w)

				if !strings.Contains(stdout.String(), seam.code) {
					t.Fatalf("%s envelope lost its code on %q:\n%s", seam.name, shape, stdout.String())
				}
				if strings.Contains(stderr.String(), "  code: ") {
					t.Fatalf("%s duplicated the human code line onto stderr under %q:\n%s", seam.name, shape, stderr.String())
				}
				if shape == "json" {
					var env struct {
						OK    bool `json:"ok"`
						Error struct {
							Code string `json:"code"`
						} `json:"error"`
					}
					if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
						t.Fatalf("%s stdout is not a parseable envelope (%v):\n%s", seam.name, err, stdout.String())
					}
					if env.OK || env.Error.Code != seam.code {
						t.Fatalf("%s envelope = %+v, want ok:false code:%s", seam.name, env, seam.code)
					}
				}
			})
		}
	}
}

// A code-less refusal is byte-identical to before: humanErrorCode("") prints
// nothing, so the ~60 code-less human lines are untouched.
func TestEmptyCodePrintsNoLine(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	renderError(w, apiError{exit: exitGeneric, message: "opaque failure"})

	if strings.Contains(stderr.String(), "code:") {
		t.Fatalf("a code-less refusal grew a code line:\n%s", stderr.String())
	}
}
