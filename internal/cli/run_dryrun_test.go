package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestDryRunJSONIsParseable asserts that a `--dry-run -o json` preview emits
// valid JSON carrying method/url/headers (with the body parsed when it is JSON),
// so a `bp ... --dry-run -o json | jq` pipe stays machine-readable.
func TestDryRunJSONIsParseable(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	cmd := manifest.Command{}
	cmd.HTTP.Method = "POST"
	headers := map[string]string{
		"Authorization": "Bearer sk-secret-123",
		"Content-Type":  "application/json",
	}
	body := []byte(`{"title":"hi"}`)

	if code := dryRun(w, cmd, "https://example.test/v1/docs", headers, body); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}

	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("stdout is not valid JSON: %v\n%s", err, stdout.String())
	}
	if payload["method"] != "POST" {
		t.Errorf("method = %v, want POST", payload["method"])
	}
	if payload["url"] != "https://example.test/v1/docs" {
		t.Errorf("url = %v", payload["url"])
	}
	hdrs, ok := payload["headers"].(map[string]any)
	if !ok {
		t.Fatalf("headers not an object: %v", payload["headers"])
	}
	if got := hdrs["Authorization"]; got != "Bearer ****" {
		t.Errorf("Authorization not redacted: %v", got)
	}
	// A JSON body round-trips as structured JSON, not a string.
	parsedBody, ok := payload["body"].(map[string]any)
	if !ok {
		t.Fatalf("body not parsed as object: %v", payload["body"])
	}
	if parsedBody["title"] != "hi" {
		t.Errorf("body.title = %v, want hi", parsedBody["title"])
	}

	// The degradation notice must be on stderr, never polluting stdout.
	if !strings.Contains(stderr.String(), "dry-run") {
		t.Errorf("missing stderr notice: %q", stderr.String())
	}
}

// TestDryRunJSONNonJSONBody keeps a non-JSON body as a plain string rather than
// failing the render.
func TestDryRunJSONNonJSONBody(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	cmd := manifest.Command{}
	cmd.HTTP.Method = "PUT"

	if code := dryRun(w, cmd, "https://example.test/x", nil, []byte("not-json")); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("stdout is not valid JSON: %v\n%s", err, stdout.String())
	}
	if payload["body"] != "not-json" {
		t.Errorf("body = %v, want plain string", payload["body"])
	}
}

// TestDryRunYAMLNestsHeaders asserts the YAML preview nests headers as a mapping
// (not a Go map literal) so the document stays well-formed.
func TestDryRunYAMLNestsHeaders(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "yaml"

	cmd := manifest.Command{}
	cmd.HTTP.Method = "POST"
	headers := map[string]string{"Authorization": "Bearer sk-secret"}

	if code := dryRun(w, cmd, "https://example.test/x", headers, nil); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	out := stdout.String()
	if strings.Contains(out, "map[") {
		t.Errorf("headers rendered as a Go map literal, not YAML:\n%s", out)
	}
	if !strings.Contains(out, "headers:\n") || !strings.Contains(out, "Authorization:") || !strings.Contains(out, "Bearer ****") {
		t.Errorf("headers not nested as a YAML mapping:\n%s", out)
	}
}

// TestDryRunHumanUnchanged pins the human (table) shape: method+url line, sorted
// redacted header lines, and the raw body after a blank line.
func TestDryRunHumanUnchanged(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	cmd := manifest.Command{}
	cmd.HTTP.Method = "POST"
	headers := map[string]string{
		"Authorization": "Bearer sk-secret-123",
		"Content-Type":  "application/json",
	}
	body := []byte(`{"title":"hi"}`)

	if code := dryRun(w, cmd, "https://example.test/v1/docs", headers, body); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	want := "POST https://example.test/v1/docs\n" +
		"Authorization: Bearer ****\n" +
		"Content-Type: application/json\n" +
		"\n" +
		`{"title":"hi"}` + "\n"
	if stdout.String() != want {
		t.Errorf("human output drift:\n got: %q\nwant: %q", stdout.String(), want)
	}
}
