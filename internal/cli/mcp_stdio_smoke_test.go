package cli_test

// Real-stdio smoke gate for `bp mcp serve` (charter decision 4: the sacred-stdout
// invariant). The MCP SDK's StdioTransport hardcodes os.Stdin/os.Stdout, so the
// in-memory transport tests in mcp-w1-core never touch the REAL process channel.
// Only an exec'd binary proves it — this file builds bp, drives a scripted
// JSON-RPC session over actual pipes, and asserts the stdout stream is BYTE-PURE
// newline-delimited JSON-RPC with exactly the eight curated task tools.
//
// Framing note: verified against github.com/modelcontextprotocol/go-sdk@v1.6.1
// mcp/transport.go — stdio is newline-delimited JSON (ndjson: one JSON value per
// line, each terminated by '\n'; see transport.go's ioConn and the trailing
// `data = append(data, '\n')` writes). So a json.Decoder consuming the whole
// stdout stream is the correct purity check: it tolerates the inter-message
// whitespace/newlines and rejects any non-JSON byte a rogue print would inject.
//
// Dependency ordering: this slice (mcp-w1-smoke) depends on mcp-w1-core (#1781),
// which adds the `mcp` case-arm + runMCPServe. Built in a parallel worktree, that
// code is not present in this branch in isolation, so the exec test detects the
// dispatcher's `unknown command "mcp"` envelope and t.Skip's with a loud reason —
// it runs its full assertions the moment the lead stacks this on core. The
// always-run TestMCPStdoutBytePurityHarness proves the purity/tripwire/extraction
// logic itself now, so the gate is never vacuously green.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// mcpSmokeSink captures every byte the server writes to stdout (for the exact
// byte-purity assertion) and signals `done` the instant the tools/list response
// (JSON-RPC id 2) lands — so the driver can close stdin at the right moment
// instead of racing the server into an empty shutdown with an arbitrary sleep.
// The MCP stdio read loop tears down on stdin EOF; closing stdin too early (before
// the server has processed initialize -> tools/list) yields ZERO stdout, so the
// close MUST wait for the response we're asserting on.
type mcpSmokeSink struct {
	mu       sync.Mutex
	buf      bytes.Buffer
	sentinel []byte
	seen     bool
	done     chan struct{}
}

func (s *mcpSmokeSink) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, _ := s.buf.Write(p)
	if !s.seen && bytes.Contains(s.buf.Bytes(), s.sentinel) {
		s.seen = true
		close(s.done)
	}
	return n, nil
}

func (s *mcpSmokeSink) Bytes() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]byte(nil), s.buf.Bytes()...)
}

// mcpSmokeCuratedTools is the exact tool set `bp mcp serve` exposes under the
// default --tools tasks (charter decision 5 — the curated eight, hand-mapped, not
// 1:1 verb aliases) plus the four curated chat session tools (herd charter D74h,
// hardcoded /v1/chat wrappers). Sorted for set comparison.
var mcpSmokeCuratedTools = []string{
	"chat_read_tail", "chat_send", "chat_spawn_session", "chat_wait_for_state",
	"task_close", "task_create", "task_next", "task_prime", "task_pulse", "task_ready", "task_show", "task_stamp",
}

// mcpSmokeRPCMsg is the sliver of a JSON-RPC frame the smoke gate inspects.
type mcpSmokeRPCMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"`
}

// mcpSmokeDecodeStream is THE byte-purity assertion. It decodes data as a
// sequence of JSON values (ndjson framing) until EOF. Because json.Decoder only
// returns io.EOF when nothing but whitespace remains after the last value, ANY
// stray byte — a leading, mid-stream, or trailing non-JSON print — surfaces as a
// decode error here. A clean return means every emitted byte belonged to a
// JSON-RPC message. This is the regression tripwire for a rogue fmt.Print sneaking
// onto stdout (renderers, notices, guards) that would corrupt the transport.
func mcpSmokeDecodeStream(data []byte) ([]mcpSmokeRPCMsg, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	var msgs []mcpSmokeRPCMsg
	for {
		var m mcpSmokeRPCMsg
		err := dec.Decode(&m)
		if errors.Is(err, io.EOF) {
			return msgs, nil
		}
		if err != nil {
			return msgs, fmt.Errorf("stdout is not byte-pure JSON-RPC: decode failed after %d clean message(s), at byte offset %d: %w", len(msgs), dec.InputOffset(), err)
		}
		msgs = append(msgs, m)
	}
}

// mcpSmokeToolNames finds the tools/list result in a decoded stream and returns
// its tool names, sorted. ok is false if no message carried a "tools" array.
func mcpSmokeToolNames(msgs []mcpSmokeRPCMsg) (names []string, ok bool) {
	for _, m := range msgs {
		if len(m.Result) == 0 {
			continue
		}
		var r struct {
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
		}
		if err := json.Unmarshal(m.Result, &r); err != nil {
			continue
		}
		if r.Tools == nil {
			continue // a result without a tools array (e.g. initialize)
		}
		names = make([]string, 0, len(r.Tools))
		for _, t := range r.Tools {
			names = append(names, t.Name)
		}
		sort.Strings(names)
		return names, true
	}
	return nil, false
}

// mcpSmokeIsUnknownCommand reports whether the stream is the CLI dispatcher's
// `unknown command "mcp"` envelope — i.e. `bp mcp serve` is not wired into this
// build yet (mcp-w1-core not integrated). Distinct from a genuine MCP error.
func mcpSmokeIsUnknownCommand(msgs []mcpSmokeRPCMsg) bool {
	for _, m := range msgs {
		if len(m.Error) == 0 {
			continue
		}
		var e struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(m.Error, &e)
		if strings.Contains(e.Message, `unknown command "mcp"`) {
			return true
		}
	}
	return false
}

// mcpSmokeSession is the scripted client half of the handshake, in order:
// initialize (request) -> notifications/initialized (notification) -> tools/list
// (request). The caller writes each line '\n'-terminated then closes stdin, whose
// EOF ends the server's read loop for a clean exit. The protocolVersion is a
// supported value; even an unknown one negotiates down to the SDK's latest
// (shared.go supportedProtocolVersions), so the handshake is robust.
func mcpSmokeSession() [][]byte {
	return [][]byte{
		[]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bp-mcp-smoke","version":"0.0.0"}}}`),
		[]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`),
		[]byte(`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`),
	}
}

// mcpSmokeRepoRoot walks up from the package dir to the module root (the dir with
// go.mod), so the test builds and locates the fixture regardless of cwd.
func mcpSmokeRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not locate module root (go.mod) above the test dir")
		}
		dir = parent
	}
}

// mcpSmokeExitCode extracts a process exit code from a *exec.ExitError, or 0 for
// a nil error.
func mcpSmokeExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// TestMCPServeStdioSmoke builds the real bp binary and drives `mcp serve` over
// actual process stdio, asserting byte-pure JSON-RPC stdout and exactly the eight
// curated tools. No network: the manifest comes from the committed fixture via
// the BARKPARK_MANIFEST file-override seam (load.go), the API URL/token are
// stubs, and the driven session stops at tools/list (which never dials the API).
func TestMCPServeStdioSmoke(t *testing.T) {
	if testing.Short() {
		t.Skip("skips the go-build-and-exec mcp serve smoke in -short mode")
	}

	root := mcpSmokeRepoRoot(t)
	bin := filepath.Join(t.TempDir(), "bp")

	build := exec.Command("go", "build", "-o", bin, "github.com/FRIKKern/barkpark/cmd/barkpark")
	build.Dir = root
	build.Env = append(os.Environ(), "CC=clang") // native deps need real clang, not the cc wrapper
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build bp: %v\n%s", err, out)
	}

	manifest := filepath.Join(root, "docs", "cli", "fixtures", "full-manifest.json")
	if _, err := os.Stat(manifest); err != nil {
		t.Fatalf("fixture manifest missing: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, "mcp", "serve")
	cmd.Env = append(os.Environ(),
		"BARKPARK_MANIFEST="+manifest,         // offline manifest (load.go override seam)
		"BARKPARK_API_URL=http://127.0.0.1:0", // stub; tools/list does not dial it
		"BARKPARK_API_TOKEN=smoke-stub-token",
	)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	// sentinel `"id":2` marks the tools/list response (the SDK marshals compact
	// JSON — verified: `{"jsonrpc":"2.0","id":2,...}` — so no interior space).
	sink := &mcpSmokeSink{sentinel: []byte(`"id":2`), done: make(chan struct{})}

	if err := cmd.Start(); err != nil {
		t.Fatalf("start bp mcp serve: %v", err)
	}

	copyDone := make(chan struct{})
	go func() { _, _ = io.Copy(sink, stdoutPipe); close(copyDone) }()
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	// Feed the scripted session but DO NOT close stdin here — the server must
	// process initialize -> tools/list before it sees EOF.
	go func() {
		for _, line := range mcpSmokeSession() {
			if _, err := stdin.Write(append(line, '\n')); err != nil {
				return // server already gone (e.g. unimplemented path)
			}
		}
	}()

	// Close stdin only once the response we assert on has arrived, or the process
	// has exited on its own (the unimplemented `unknown command` path exits fast),
	// or the deadline trips.
	var waitErr error
	reaped := false
	select {
	case <-sink.done:
	case waitErr = <-waitCh:
		reaped = true
	case <-ctx.Done():
	}
	_ = stdin.Close() // EOF -> server read loop ends -> clean exit
	if !reaped {
		waitErr = <-waitCh
	}
	<-copyDone // all stdout drained

	stdoutStr := string(sink.Bytes())
	msgs, purityErr := mcpSmokeDecodeStream(sink.Bytes())

	// Dependency gate: `bp mcp serve` not present in this build yet.
	if mcpSmokeIsUnknownCommand(msgs) {
		t.Skipf("`bp mcp serve` is not wired into this build — depends on mcp-w1-core (#1781); "+
			"the full exec assertions run live once the lead stacks this slice on core. stderr=%q", stderr.String())
	}

	// From here the subcommand exists: enforce the real contract.
	if ctx.Err() != nil {
		t.Fatalf("server did not exit on stdin EOF within the deadline (%v)\n--- stdout ---\n%s\n--- stderr ---\n%s",
			ctx.Err(), stdoutStr, stderr.String())
	}
	if purityErr != nil {
		t.Fatalf("STDOUT BYTE-PURITY VIOLATED: %v\n--- raw stdout ---\n%q\n--- stderr ---\n%s",
			purityErr, stdoutStr, stderr.String())
	}
	if ec := mcpSmokeExitCode(waitErr); ec != 0 {
		t.Fatalf("bp mcp serve exited %d (want 0 on stdin EOF)\n--- stderr ---\n%s", ec, stderr.String())
	}

	names, ok := mcpSmokeToolNames(msgs)
	if !ok {
		t.Fatalf("no tools/list result in the stdout stream (%d messages decoded)\n--- stdout ---\n%s",
			len(msgs), stdoutStr)
	}
	if !mcpSmokeEqualSets(names, mcpSmokeCuratedTools) {
		t.Fatalf("tools/list names mismatch:\n got: %v\nwant: %v", names, mcpSmokeCuratedTools)
	}
	// stderr MAY carry chrome (update notices, log lines) — that is allowed; only
	// stdout must stay byte-pure, which the purity assertion above guarantees.
}

// TestMCPStdoutBytePurityHarness proves the purity assertion, the stray-print
// tripwire, and tool-name extraction WITHOUT the built server — so these
// invariants are covered even while TestMCPServeStdioSmoke is dependency-skipped,
// and the gate is never vacuously green. It is the in-code form of the
// "deliberately print a stray line and confirm the test would fail" experiment.
func TestMCPStdoutBytePurityHarness(t *testing.T) {
	initResult := `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"barkpark","version":"0"},"capabilities":{"tools":{}}}}`
	toolsResult := `{"jsonrpc":"2.0","id":2,"result":{"tools":[` +
		`{"name":"task_ready"},{"name":"task_next"},{"name":"task_show"},{"name":"task_close"},{"name":"task_create"},{"name":"task_prime"},{"name":"task_stamp"},{"name":"task_pulse"},` +
		`{"name":"chat_spawn_session"},{"name":"chat_send"},{"name":"chat_read_tail"},{"name":"chat_wait_for_state"}]}}`
	cleanStr := initResult + "\n" + toolsResult + "\n"
	clean := []byte(cleanStr)

	// A clean ndjson JSON-RPC stream decodes with zero leftover bytes...
	msgs, err := mcpSmokeDecodeStream(clean)
	if err != nil {
		t.Fatalf("clean ndjson stream rejected by the purity check: %v", err)
	}
	// ...and yields exactly the curated tool names (eight task + four chat).
	names, ok := mcpSmokeToolNames(msgs)
	if !ok {
		t.Fatal("tool-name extraction found no tools/list result in a clean stream")
	}
	if !mcpSmokeEqualSets(names, mcpSmokeCuratedTools) {
		t.Fatalf("extracted tool names mismatch:\n got: %v\nwant: %v", names, mcpSmokeCuratedTools)
	}

	// TRIPWIRE: a single stray non-JSON line — exactly what a rogue fmt.Println on
	// stdout would inject — MUST break byte-purity, wherever it lands.
	polluted := map[string][]byte{
		"leading stray print": []byte("hello from a stray fmt.Println\n" + cleanStr),
		"mid-stream log line": []byte(initResult + "\n" + "oops: a log line snuck onto stdout\n" + toolsResult + "\n"),
		"trailing garbage":    []byte(cleanStr + "not-json trailing bytes\n"),
		"bare word":           []byte("DEBUG\n"),
	}
	for name, bad := range polluted {
		if _, err := mcpSmokeDecodeStream(bad); err == nil {
			t.Fatalf("tripwire FAILED to fire for %q — a polluted stdout stream passed the purity check", name)
		}
	}
}

// mcpSmokeEqualSets reports whether two already-sorted string slices are equal as
// sets (same length, same members).
func mcpSmokeEqualSets(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	as := append([]string(nil), a...)
	bs := append([]string(nil), b...)
	sort.Strings(as)
	sort.Strings(bs)
	for i := range as {
		if as[i] != bs[i] {
			return false
		}
	}
	return true
}
