package cli

// onramp_write.go — the `--write` engine behind `bp onramp <target> --write`.
// It merges ONLY the barkpark server entry into a target's JSON config and
// touches nothing else the user put there: every foreign server and every
// unrelated top-level key survives byte-for-byte (json.RawMessage passthrough).
// Re-running is a no-op ('unchanged', exit 0) — that idempotence IS the "one
// step" promise; an emitter that clobbers a user's mcp.json once poisons the
// whole story.
//
// Three shapes, all key-parametrized off the per-file merge metadata stamped in
// buildOnrampSpec (never a hardcoded `mcpServers`):
//   - server-map: the barkpark entry lives at data[TopKey][ServerKey]
//     (mcpServers-map for cursor/claude-code/windsurf/gemini-cli; servers-map
//     for copilot's .vscode/mcp.json once that target lands).
//   - flat:       a top-level scalar/value at data[TopKey] (cursor-cloud's
//     .cursor/environment.json `install` command).
//   - toml:       codex's config.toml — NO write this wave; reported 'skipped'
//     (TOML write is wave 3, and no TOML dependency may enter go.mod).
//
// atomicWriteFile is the shared write seam: the AGENTS.md marker-merge
// (ve-w2-agents-md-onramp) routes its own atomic write + report through it too.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

// Merge kinds a JSON onramp file can carry. Stamped in buildOnrampSpec; read by
// mergeOnrampFile to pick a strategy. Empty ("") means the file has no merge
// strategy and is left untouched by --write (should not happen for a real file).
const (
	mergeServerMap = "server-map" // barkpark entry at data[TopKey][ServerKey]
	mergeFlat      = "flat"       // barkpark value at data[TopKey]
	mergeTOML      = "toml"       // codex config.toml — deferred to wave 3
	mergeMarkdown  = "markdown"   // agents-md marker-managed block in ./AGENTS.md
)

// onrampAction is the per-file outcome of a `--write`: what happened to one
// config file. Action ∈ created | updated | unchanged | skipped (+ the honest
// error row on a mid-run failure). Note carries the human "why" (the --force
// hint, the TOML-deferred reason). It is BOTH the `-o json` report row and the
// seam type ve-w2-agents-md-onramp reuses for its marker-merge report.
type onrampAction struct {
	Path   string `json:"path"`
	Action string `json:"action"`
	Note   string `json:"note,omitempty"`
}

// onrampWriteResult is the single structured document `bp onramp <t> --write -o
// json` emits: the resolved target and the per-file actions.
type onrampWriteResult struct {
	Target  string         `json:"target"`
	Actions []onrampAction `json:"actions"`
}

// runOnrampWrite performs the safe JSON merge for every file in the spec and
// reports per file. It is honest: a merge error stops the run (nothing after it
// is written) with exitGeneric, and the report shows exactly what was done up to
// the failure — never a partial-success lie.
func runOnrampWrite(out *writer, spec onrampSpec, force bool) int {
	var actions []onrampAction
	var failed error
	for _, f := range spec.Files {
		act, err := mergeOnrampFile(f, force)
		if err != nil {
			failed = err
			actions = append(actions, onrampAction{Path: f.Path, Action: "error", Note: err.Error()})
			break
		}
		actions = append(actions, act)
	}

	if out.machineOut() {
		out.renderJSON(onrampWriteResult{Target: spec.Target, Actions: actions})
		if failed != nil {
			return exitGeneric
		}
		return exitOK
	}

	// Human report — one aligned line per file, then the verify pointer.
	out.outf("# bp onramp %s --write", spec.Target)
	out.outf("")
	for _, a := range actions {
		line := fmt.Sprintf("  %-9s %s", a.Action, a.Path)
		if a.Note != "" {
			line += "  — " + a.Note
		}
		out.outf("%s", line)
	}
	if failed != nil {
		out.outf("")
		out.userErr("onramp --write failed: %v", failed)
		return exitGeneric
	}
	if onrampAnySkipped(actions) {
		out.outf("")
		out.outf("# some files were left as-is — re-run with --force to overwrite the existing barkpark entry.")
	}
	out.outf("")
	out.outf("# verify: %s", spec.Verify)
	out.outf("# Full journey (install · auth · create): docs/setup/AGENT-ONRAMPS.md")
	return exitOK
}

// onrampAnySkipped reports whether any file was left as-is because a different
// barkpark entry was already present (the --force hint is worth showing).
func onrampAnySkipped(actions []onrampAction) bool {
	for _, a := range actions {
		if a.Action == "skipped" && strings.Contains(a.Note, "--force") {
			return true
		}
	}
	return false
}

// mergeOnrampFile dispatches one file by its stamped merge kind.
func mergeOnrampFile(f onrampFile, force bool) (onrampAction, error) {
	switch f.MergeKind {
	case mergeServerMap:
		return mergeServerMapFile(f, force)
	case mergeFlat:
		return mergeFlatFile(f, force)
	case mergeMarkdown:
		return mergeMarkdownFile(f, force)
	case mergeTOML:
		return onrampAction{
			Path:   f.Path,
			Action: "skipped",
			Note:   "TOML write is wave 3 — paste the [mcp_servers.barkpark] block by hand (`bp onramp codex`)",
		}, nil
	default:
		return onrampAction{
			Path:   f.Path,
			Action: "skipped",
			Note:   "no merge strategy for this file — paste it by hand",
		}, nil
	}
}

// mergeServerMapFile inserts/updates ONLY data[TopKey][ServerKey], preserving
// every other server and top-level key verbatim.
func mergeServerMapFile(f onrampFile, force bool) (onrampAction, error) {
	path, err := expandOnrampPath(f.Path)
	if err != nil {
		return onrampAction{}, err
	}
	desired, err := desiredServerEntry(f)
	if err != nil {
		return onrampAction{}, err
	}

	existing, readErr := os.ReadFile(path)
	if os.IsNotExist(readErr) {
		// Fresh file — write the doc-shaped stanza verbatim (byte-identical to what
		// `bp onramp <target>` prints), which round-trips cleanly to 'unchanged'.
		if err := atomicWriteFile(path, withTrailingNewline([]byte(f.Content))); err != nil {
			return onrampAction{}, err
		}
		return onrampAction{Path: f.Path, Action: "created"}, nil
	}
	if readErr != nil {
		return onrampAction{}, fmt.Errorf("read %s: %w", path, readErr)
	}

	top, err := unmarshalObject(existing, path)
	if err != nil {
		return onrampAction{}, err
	}
	servers := map[string]json.RawMessage{}
	if raw, ok := top[f.TopKey]; ok {
		if servers, err = unmarshalObject(raw, path+" ."+f.TopKey); err != nil {
			return onrampAction{}, err
		}
	}

	if cur, ok := servers[f.ServerKey]; ok {
		if jsonSemanticEqual(cur, desired) {
			return onrampAction{Path: f.Path, Action: "unchanged"}, nil
		}
		if !force {
			return onrampAction{
				Path:   f.Path,
				Action: "skipped",
				Note:   fmt.Sprintf("a different %q entry is already here — re-run with --force to overwrite it", f.ServerKey),
			}, nil
		}
	}

	servers[f.ServerKey] = desired
	serversRaw, err := marshalOnrampJSON(servers)
	if err != nil {
		return onrampAction{}, err
	}
	top[f.TopKey] = serversRaw
	merged, err := marshalOnrampJSON(top)
	if err != nil {
		return onrampAction{}, err
	}
	if err := atomicWriteFile(path, withTrailingNewline(merged)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// mergeFlatFile inserts/updates ONLY the top-level data[TopKey], preserving every
// other top-level key verbatim (cursor-cloud's .cursor/environment.json install).
func mergeFlatFile(f onrampFile, force bool) (onrampAction, error) {
	path, err := expandOnrampPath(f.Path)
	if err != nil {
		return onrampAction{}, err
	}
	desiredTop, err := unmarshalObject([]byte(f.Content), "desired content")
	if err != nil {
		return onrampAction{}, err
	}
	desired, ok := desiredTop[f.TopKey]
	if !ok {
		return onrampAction{}, fmt.Errorf("desired content missing top-level %q", f.TopKey)
	}

	existing, readErr := os.ReadFile(path)
	if os.IsNotExist(readErr) {
		if err := atomicWriteFile(path, withTrailingNewline([]byte(f.Content))); err != nil {
			return onrampAction{}, err
		}
		return onrampAction{Path: f.Path, Action: "created"}, nil
	}
	if readErr != nil {
		return onrampAction{}, fmt.Errorf("read %s: %w", path, readErr)
	}

	top, err := unmarshalObject(existing, path)
	if err != nil {
		return onrampAction{}, err
	}
	if cur, ok := top[f.TopKey]; ok {
		if jsonSemanticEqual(cur, desired) {
			return onrampAction{Path: f.Path, Action: "unchanged"}, nil
		}
		if !force {
			return onrampAction{
				Path:   f.Path,
				Action: "skipped",
				Note:   fmt.Sprintf("a different %q value is already here — re-run with --force to overwrite it", f.TopKey),
			}, nil
		}
	}

	top[f.TopKey] = desired
	merged, err := marshalOnrampJSON(top)
	if err != nil {
		return onrampAction{}, err
	}
	if err := atomicWriteFile(path, withTrailingNewline(merged)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// mergeMarkdownFile is the markdown analogue of the JSON mergers: it lands the
// canonical AGENTS.md teach block (f.Content — begin marker, heading, body, end
// marker) into a consumer's ./AGENTS.md WITHOUT rewriting anything else the file
// holds, expressed the only way markdown allows — managed markers (charter D6 as
// amended by D13):
//   - no file           → created  (write the block verbatim, one trailing NL).
//   - file, no markers   → updated  (APPEND after a blank-line separator; every
//     existing byte is preserved — a consumer's AGENTS.md is their content).
//   - markers, identical → unchanged (exit 0, file byte-untouched — no write).
//   - markers, differing → skipped + "--force" hint (D13 aligns markdown with the
//     JSON/TOML deny-path law); with --force, replace ONLY the begin→end span,
//     leaving every byte outside it verbatim.
//   - one marker only / end-before-begin → skipped as a malformed managed block,
//     fix by hand (a textual splice cannot own a half-open block safely; --force
//     does NOT auto-repair it, so its note carries no --force hint).
func mergeMarkdownFile(f onrampFile, force bool) (onrampAction, error) {
	path, err := expandOnrampPath(f.Path)
	if err != nil {
		return onrampAction{}, err
	}
	block := f.Content

	existing, readErr := os.ReadFile(path)
	if os.IsNotExist(readErr) {
		if err := atomicWriteFile(path, withTrailingNewline([]byte(block))); err != nil {
			return onrampAction{}, err
		}
		return onrampAction{Path: f.Path, Action: "created"}, nil
	}
	if readErr != nil {
		return onrampAction{}, fmt.Errorf("read %s: %w", path, readErr)
	}

	text := string(existing)
	beginIdx := strings.Index(text, agentsMDMarkerBegin)
	endIdx := strings.Index(text, agentsMDMarkerEnd)

	// Managed block present and well-formed: replace only its begin→end span.
	if beginIdx >= 0 && endIdx > beginIdx {
		spanEnd := endIdx + len(agentsMDMarkerEnd)
		if text[beginIdx:spanEnd] == block {
			return onrampAction{Path: f.Path, Action: "unchanged"}, nil
		}
		if !force {
			return onrampAction{
				Path:   f.Path,
				Action: "skipped",
				Note:   "a different barkpark:onramp block is already here — re-run with --force to refresh it",
			}, nil
		}
		merged := text[:beginIdx] + block + text[spanEnd:]
		if err := atomicWriteFile(path, withTrailingNewline([]byte(merged))); err != nil {
			return onrampAction{}, err
		}
		return onrampAction{Path: f.Path, Action: "updated"}, nil
	}

	// A lone marker (or end-before-begin) is a broken managed block — a textual
	// splice cannot own it safely, and --force cannot guess the intended span.
	if beginIdx >= 0 || endIdx >= 0 {
		return onrampAction{
			Path:   f.Path,
			Action: "skipped",
			Note:   "malformed barkpark:onramp markers (only one of begin/end, or out of order) — fix them by hand",
		}, nil
	}

	// No markers at all: append the block after a blank-line separator, preserving
	// every existing byte verbatim (a consumer's own AGENTS.md content).
	buf := append([]byte{}, existing...)
	if len(buf) > 0 && buf[len(buf)-1] != '\n' {
		buf = append(buf, '\n')
	}
	buf = append(buf, '\n')
	buf = append(buf, block...)
	if err := atomicWriteFile(path, withTrailingNewline(buf)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// desiredServerEntry extracts the barkpark server entry (data[TopKey][ServerKey])
// from a server-map file's rendered Content — the one entry --write is allowed to
// write.
func desiredServerEntry(f onrampFile) (json.RawMessage, error) {
	top, err := unmarshalObject([]byte(f.Content), "desired content")
	if err != nil {
		return nil, err
	}
	raw, ok := top[f.TopKey]
	if !ok {
		return nil, fmt.Errorf("desired content missing %q", f.TopKey)
	}
	servers, err := unmarshalObject(raw, "desired content ."+f.TopKey)
	if err != nil {
		return nil, err
	}
	entry, ok := servers[f.ServerKey]
	if !ok {
		return nil, fmt.Errorf("desired content missing %q.%q", f.TopKey, f.ServerKey)
	}
	return entry, nil
}

// unmarshalObject parses raw JSON into an ordered-agnostic key→RawMessage map,
// giving a clear error tied to what was being parsed. A nil map (from `null`) is
// normalised to an empty map so callers can insert into it.
func unmarshalObject(raw []byte, what string) (map[string]json.RawMessage, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("parse %s as a JSON object: %w", what, err)
	}
	if m == nil {
		m = map[string]json.RawMessage{}
	}
	return m, nil
}

// jsonSemanticEqual reports whether two JSON values are equal ignoring key order
// and whitespace — so a hand-formatted existing barkpark entry that MEANS the
// same thing reads as 'unchanged', not a spurious diff.
func jsonSemanticEqual(a, b json.RawMessage) bool {
	var av, bv any
	if err := json.Unmarshal(a, &av); err != nil {
		return false
	}
	if err := json.Unmarshal(b, &bv); err != nil {
		return false
	}
	return reflect.DeepEqual(av, bv)
}

// marshalOnrampJSON renders v as 2-space-indented JSON WITHOUT HTML escaping and
// WITHOUT a trailing newline — the same canonical shape renderJSON prints, so a
// merged file reads like a hand-authored config. HTML escaping is off so a `<`,
// `>` or `&` inside a foreign value (or a URL query) survives verbatim rather
// than turning into a < escape.
func marshalOnrampJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

// expandOnrampPath resolves a leading ~ to the user's home directory. A relative
// path (a project-local config like .cursor/mcp.json) is returned as-is, so the
// write lands under the current working directory — exactly where the agent runs.
func expandOnrampPath(p string) (string, error) {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home for %s: %w", p, err)
		}
		if p == "~" {
			return home, nil
		}
		return filepath.Join(home, p[2:]), nil
	}
	return p, nil
}

// withTrailingNewline ensures data ends in exactly one newline (POSIX text-file
// convention; matches SaveConfig).
func withTrailingNewline(b []byte) []byte {
	if len(b) == 0 || b[len(b)-1] != '\n' {
		return append(b, '\n')
	}
	return b
}

// atomicWriteFile writes data to path via a same-directory temp file + rename, so
// a crash or a concurrent reader never observes a half-written config. The parent
// directory is created 0755 and the file lands 0644 — these are project-committed
// configs holding a ${env:} placeholder, NOT secrets, so they are deliberately
// world-readable (contrast SaveConfig's 0700/0600 token store; cf. the 0644
// cmux renew-stamp). It is the shared write seam --write and the AGENTS.md
// marker-merge (ve-w2-agents-md-onramp) both route through.
func atomicWriteFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".onramp-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp in %s: %w", dir, err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("write temp %s: %w", tmp.Name(), err)
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("chmod temp %s: %w", tmp.Name(), err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("close temp %s: %w", tmp.Name(), err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("rename to %s: %w", path, err)
	}
	return nil
}
