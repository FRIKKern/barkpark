package cli

// onramp_write.go — the `--write` engine behind `bp onramp <target> --write`.
// It merges ONLY the barkpark server entry into a target's config and
// touches nothing else the user put there: every foreign server and every
// unrelated top-level key survives byte-for-byte (json.RawMessage passthrough
// for JSON; a textual span splice for TOML).
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
//   - toml:       codex's config.toml — a parse-lite SPAN SPLICE, deliberately
//     NO TOML dependency (charter D10: mainstream Go TOML libs don't round-trip
//     comments — a reserialize would clobber the very bytes we must preserve).
//     The owned span is the [mcp_servers.barkpark] header table PLUS every
//     [mcp_servers.barkpark.*] continuation table (charter D11); every byte
//     outside it survives verbatim.
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
	mergeTOML      = "toml"       // codex config.toml — parse-lite span splice (charter D10/D11)
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
// json` emits: the resolved target and the per-file actions. DryRun is true when
// the global --dry-run was set — the actions are computed identically but NOT a
// single byte was written (omitempty so a real write emits no noise).
type onrampWriteResult struct {
	Target  string         `json:"target"`
	Actions []onrampAction `json:"actions"`
	DryRun  bool           `json:"dryRun,omitempty"`
	// Partial is set ONLY when a merge error stopped the run mid-loop: the honest
	// receipt for a partial write — how many of how many files landed, which file
	// failed, and that a re-run heals. nil (omitted) on a clean run.
	Partial *onrampPartial `json:"partial,omitempty"`
}

// onrampPartial is the machine-readable partial-write receipt: on a mid-loop
// failure, earlier files are already committed and NOT rolled back (there is no
// cross-file transaction). Because every per-file merge is idempotent and atomic,
// re-running the same command after fixing the failing file heals the rest —
// already-written files report 'unchanged'. Heals is always true here; it names
// the property so a machine consumer need not infer it.
type onrampPartial struct {
	Written    int    `json:"written"`
	Total      int    `json:"total"`
	FailedPath string `json:"failedPath"`
	Heals      bool   `json:"heals"`
}

// runOnrampWrite performs the safe JSON merge for every file in the spec and
// reports per file. It is honest: a merge error stops the run (nothing after it
// is written) with exitGeneric, and the report shows exactly what was done up to
// the failure — never a partial-success lie. When dryRun is set (the global
// --dry-run), every action is computed exactly as a real run would but NOT a
// single byte reaches disk — the report is byte-identical apart from the dry-run
// marker.
func runOnrampWrite(out *writer, spec onrampSpec, force, dryRun bool) int {
	var actions []onrampAction
	var failed error
	var failedPath string
	for _, f := range spec.Files {
		act, err := mergeOnrampFile(f, force, dryRun)
		if err != nil {
			failed = err
			failedPath = f.Path
			actions = append(actions, onrampAction{Path: f.Path, Action: "error", Note: err.Error()})
			break
		}
		actions = append(actions, act)
	}

	// On a mid-loop failure the earlier files are already committed (no cross-file
	// transaction). The receipt must not lie about that: it names how many of how
	// many landed, which file failed, and that a re-run heals the rest.
	var partial *onrampPartial
	if failed != nil {
		partial = &onrampPartial{
			Written:    onrampWrittenCount(actions),
			Total:      len(spec.Files),
			FailedPath: failedPath,
			Heals:      true,
		}
	}

	if out.machineOut() {
		out.renderJSON(onrampWriteResult{Target: spec.Target, Actions: actions, DryRun: dryRun, Partial: partial})
		if failed != nil {
			return exitGeneric
		}
		return exitOK
	}

	// Human report — one aligned line per file, then the verify pointer.
	out.outf("# bp onramp %s --write", spec.Target)
	if dryRun {
		out.outf("# DRY RUN — nothing was written; this is exactly what --write would do.")
	}
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
		// Honest partial-write receipt: name N of M written + the failing file +
		// that a re-run heals (per-file merges are idempotent + atomic).
		out.outf("")
		out.outf("# partial write: %d of %d files written before %s failed.", partial.Written, partial.Total, failedPath)
		out.outf("# the writes above are committed and NOT rolled back; per-file merges are idempotent and atomic,")
		out.outf("# so once %s is fixed, re-running `bp onramp %s --write` heals the rest (already-written files report 'unchanged').", failedPath, spec.Target)
		return exitGeneric
	}
	if onrampAnySkipped(actions) {
		out.outf("")
		out.outf("# some files were left as-is — re-run with --force to overwrite the existing barkpark entry.")
	}
	if dryRun {
		out.outf("")
		out.outf("# dry run — re-run without --dry-run to apply these changes.")
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

// onrampWrittenCount reports how many files actually reached disk — 'created' or
// 'updated' actions. 'unchanged' and 'skipped' touched no bytes, and the 'error'
// row is the failure itself, so none of those count toward a partial-write total.
func onrampWrittenCount(actions []onrampAction) int {
	n := 0
	for _, a := range actions {
		if a.Action == "created" || a.Action == "updated" {
			n++
		}
	}
	return n
}

// mergeOnrampFile dispatches one file by its stamped merge kind. dryRun (the
// global --dry-run) is threaded to every merge function so the actions are
// computed identically while no byte reaches disk.
func mergeOnrampFile(f onrampFile, force, dryRun bool) (onrampAction, error) {
	switch f.MergeKind {
	case mergeServerMap:
		return mergeServerMapFile(f, force, dryRun)
	case mergeFlat:
		return mergeFlatFile(f, force, dryRun)
	case mergeMarkdown:
		return mergeMarkdownFile(f, force, dryRun)
	case mergeTOML:
		return mergeTOMLFile(f, force, dryRun)
	default:
		return onrampAction{
			Path:   f.Path,
			Action: "skipped",
			Note:   "no merge strategy for this file — paste it by hand",
		}, nil
	}
}

// mergeServerMapFile inserts/updates ONLY data[TopKey][ServerKey], preserving
// every other server and top-level key verbatim. dryRun computes the same action
// without touching disk.
func mergeServerMapFile(f onrampFile, force, dryRun bool) (onrampAction, error) {
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
		if err := writeOnrampFile(dryRun, path, withTrailingNewline([]byte(f.Content))); err != nil {
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
	if err := writeOnrampFile(dryRun, path, withTrailingNewline(merged)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// mergeFlatFile inserts/updates ONLY the top-level data[TopKey], preserving every
// other top-level key verbatim (cursor-cloud's .cursor/environment.json install).
// dryRun computes the same action without touching disk.
func mergeFlatFile(f onrampFile, force, dryRun bool) (onrampAction, error) {
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
		if err := writeOnrampFile(dryRun, path, withTrailingNewline([]byte(f.Content))); err != nil {
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
	if err := writeOnrampFile(dryRun, path, withTrailingNewline(merged)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// mergeTOMLFile merges ONLY the [TopKey.ServerKey] span into a TOML config via a
// parse-lite textual span splice — deliberately NO TOML dependency (charter D10;
// go TOML libs don't round-trip comments, and comments are exactly the user
// bytes this merger must preserve). Provenance: behavior pinned against
// codex-cli 0.144.1 (live capture: `codex mcp add` writes env as a NESTED
// [mcp_servers.barkpark.env] sub-table, alpha-sorted keys, LF-only, single
// trailing newline) and openai/codex@5c19155c (upstream itself edits config.toml
// with a decor-preserving toml_edit editor; profiles are inline [profiles.NAME]
// tables in the same file).
//
// Span law (charter D11): the owned span = the [mcp_servers.barkpark] header
// table PLUS every [mcp_servers.barkpark.*] continuation table, ending at the
// first header NOT sharing the dotted prefix (or EOF); trailing blank and
// comment-only lines before that header stay OUTSIDE the span. Header match is
// on the header TOKEN (a trailing # comment after `]` must not break
// detection). The honest contract: every byte outside the owned span survives
// verbatim; --force replaces the WHOLE owned span (sub-tables, and any user key
// or comment inside it) with the canonical flat stanza. A sub-table-shaped
// stanza (real `codex mcp add` output) is a DIFFERING stanza — skipped without
// --force, replaced on --force, never an error. Root dotted-key / inline-table
// forms error loudly with the file untouched: a textual splice cannot own them
// safely. CRLF files and files without a final newline round-trip.
func mergeTOMLFile(f onrampFile, force, dryRun bool) (onrampAction, error) {
	path, err := expandOnrampPath(f.Path)
	if err != nil {
		return onrampAction{}, err
	}
	ownedKey := f.TopKey + "." + f.ServerKey // e.g. mcp_servers.barkpark

	existing, readErr := os.ReadFile(path)
	if os.IsNotExist(readErr) {
		// Fresh file — the doc-shaped stanza verbatim (byte-identical to what
		// `bp onramp codex` prints), which round-trips cleanly to 'unchanged'.
		if err := writeOnrampFile(dryRun, path, withTrailingNewline([]byte(f.Content))); err != nil {
			return onrampAction{}, err
		}
		return onrampAction{Path: f.Path, Action: "created"}, nil
	}
	if readErr != nil {
		return onrampAction{}, fmt.Errorf("read %s: %w", path, readErr)
	}

	// Scan and splice on LF; restore the file's own newline convention on write.
	crlf := bytes.Contains(existing, []byte("\r\n"))
	work := string(existing)
	if crlf {
		work = strings.ReplaceAll(work, "\r\n", "\n")
	}
	lines := strings.Split(work, "\n")

	if err := tomlDenyUnsafeForms(lines, f.TopKey, f.ServerKey); err != nil {
		return onrampAction{}, fmt.Errorf("%s: %w — fix the file by hand (`bp onramp codex` prints the canonical block); nothing was written", path, err)
	}

	start, end, found := tomlOwnedSpan(lines, ownedKey)
	if !found {
		// No barkpark span — append the canonical stanza with a blank-line
		// separator, preserving every existing byte (a missing final newline is
		// completed so the appended header starts on its own line).
		out := work
		if strings.TrimSpace(out) == "" {
			out = f.Content + "\n"
		} else {
			if !strings.HasSuffix(out, "\n") {
				out += "\n"
			}
			out += "\n" + f.Content + "\n"
		}
		if crlf {
			out = strings.ReplaceAll(out, "\n", "\r\n")
		}
		if err := writeOnrampFile(dryRun, path, []byte(out)); err != nil {
			return onrampAction{}, err
		}
		return onrampAction{Path: f.Path, Action: "updated"}, nil
	}

	// Byte-compare the owned span against the canonical stanza (parse-lite
	// honesty: a reordered or reformatted stanza is a DIFFERING stanza).
	if strings.Join(lines[start:end], "\n") == f.Content {
		return onrampAction{Path: f.Path, Action: "unchanged"}, nil
	}
	if !force {
		return onrampAction{
			Path:   f.Path,
			Action: "skipped",
			Note:   fmt.Sprintf("a different %q stanza is already here — re-run with --force to replace the whole [%s] span (sub-tables included) with the canonical block; bytes outside the span are never touched", f.ServerKey, ownedKey),
		}, nil
	}

	merged := make([]string, 0, len(lines))
	merged = append(merged, lines[:start]...)
	merged = append(merged, strings.Split(f.Content, "\n")...)
	merged = append(merged, lines[end:]...)
	out := strings.Join(merged, "\n")
	if crlf {
		out = strings.ReplaceAll(out, "\n", "\r\n")
	}
	if err := writeOnrampFile(dryRun, path, []byte(out)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// tomlOwnedSpan locates the owned span in lines: from the first header whose
// token is ownedKey (or a dotted continuation ownedKey.*) up to — exclusive —
// the first following header that is NOT ours, or EOF. Trailing blank and
// comment-only lines are excluded from the span (they read as the next
// section's preamble and must survive a --force replace).
func tomlOwnedSpan(lines []string, ownedKey string) (start, end int, found bool) {
	start = -1
	end = -1
	for i, ln := range lines {
		tok, isHeader := tomlHeaderToken(ln)
		if !isHeader {
			continue
		}
		match := tok == ownedKey || strings.HasPrefix(tok, ownedKey+".")
		if start == -1 {
			if match {
				start = i
			}
			continue
		}
		if !match {
			end = i
			break
		}
	}
	if start == -1 {
		return 0, 0, false
	}
	if end == -1 {
		end = len(lines)
	}
	for end > start+1 {
		t := strings.TrimSpace(lines[end-1])
		if t == "" || strings.HasPrefix(t, "#") {
			end--
			continue
		}
		break
	}
	return start, end, true
}

// tomlHeaderToken reports whether line is a TOML table header ([a.b] or
// [[a.b]]) and returns its normalized dotted key. A trailing `# comment` after
// the closing bracket is allowed and ignored (charter D11: header match on the
// TOKEN). A malformed header still counts as a header with an empty token, so a
// span scan treats it conservatively as foreign.
func tomlHeaderToken(line string) (string, bool) {
	s := strings.TrimSpace(line)
	if !strings.HasPrefix(s, "[") {
		return "", false
	}
	open, closing := 1, "]"
	if strings.HasPrefix(s, "[[") { // array-of-tables header
		open, closing = 2, "]]"
	}
	rest := s[open:]
	idx := strings.Index(rest, closing)
	if idx < 0 {
		return "", true
	}
	after := strings.TrimSpace(rest[idx+len(closing):])
	if after != "" && !strings.HasPrefix(after, "#") {
		return "", true
	}
	return tomlNormalizeKey(rest[:idx]), true
}

// tomlNormalizeKey canonicalizes a dotted TOML key for comparison: whitespace
// around dots is dropped and each part's surrounding quotes are stripped, so
// [ mcp_servers . "barkpark" ] matches mcp_servers.barkpark. (Parse-lite: a
// quoted key containing a literal dot would mis-split — the keys this merger
// owns never do.)
func tomlNormalizeKey(k string) string {
	parts := strings.Split(k, ".")
	for i, p := range parts {
		p = strings.TrimSpace(p)
		if len(p) >= 2 && ((p[0] == '"' && p[len(p)-1] == '"') || (p[0] == '\'' && p[len(p)-1] == '\'')) {
			p = p[1 : len(p)-1]
		}
		parts[i] = p
	}
	return strings.Join(parts, ".")
}

// tomlDenyUnsafeForms errors on the stanza forms a textual span splice cannot
// own safely (charter D11 — loud error, file untouched): a root-level dotted or
// inline-table key (`mcp_servers.barkpark.command = …`, `mcp_servers = {…}`)
// and the inline form under a bare [mcp_servers] header (`barkpark = {…}`,
// `barkpark.command = …`). These have no header-delimited span to replace, and
// appending a [mcp_servers.barkpark] table alongside them would redefine the
// key — invalid TOML that breaks the user's whole config.
func tomlDenyUnsafeForms(lines []string, topKey, serverKey string) error {
	section := "" // "" = the root table
	for _, ln := range lines {
		if tok, isHeader := tomlHeaderToken(ln); isHeader {
			section = tok
			continue
		}
		s := strings.TrimSpace(ln)
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		eq := strings.Index(s, "=")
		if eq <= 0 {
			continue
		}
		key := tomlNormalizeKey(strings.TrimSpace(s[:eq]))
		switch {
		case section == "" && (key == topKey || strings.HasPrefix(key, topKey+".")):
			return fmt.Errorf("%q is declared as a root-level dotted/inline key (%q) — a textual span merge cannot own that form safely", topKey, s)
		case section == topKey && (key == serverKey || strings.HasPrefix(key, serverKey+".")):
			return fmt.Errorf("%q is declared inline under [%s] (%q) — a textual span merge cannot own that form safely", serverKey, topKey, s)
		}
	}
	return nil
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

// onrampUTF8BOM is the UTF-8 byte-order mark (EF BB BF). Windows editors (Notepad, some
// VS Code / Cursor configurations) prepend it to files they save; Go's json
// decoder does NOT skip it and rejects the otherwise-valid file with "invalid
// character 'ï'". Stripping it at the parse boundary (BP-ONB-12) is what lets a
// Windows-edited Cursor/VS Code mcp.json merge instead of bricking onboarding.
var onrampUTF8BOM = []byte{0xEF, 0xBB, 0xBF}

// unmarshalObject parses raw JSON into an ordered-agnostic key→RawMessage map,
// giving a clear error tied to what was being parsed. A nil map (from `null`) is
// normalised to an empty map so callers can insert into it. A leading UTF-8 BOM
// is tolerated (stripped before decode) so Windows-edited config files parse.
func unmarshalObject(raw []byte, what string) (map[string]json.RawMessage, error) {
	raw = bytes.TrimPrefix(raw, onrampUTF8BOM)
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

// writeOnrampFile is the single dry-run seam every merge function writes through:
// with dryRun set (the global --dry-run) it is a no-op — the caller has already
// computed the honest action, and NOT one byte reaches disk — otherwise it
// performs the real atomic write. Guarding here (not at each call site) keeps the
// merge functions readable and guarantees no atomicWriteFile path can slip the
// dry-run contract. The AGENTS.md/codex mergers landing this same wave route
// their atomic writes through here too, so the lead's union guard is this one
// function (charter D15/D7).
func writeOnrampFile(dryRun bool, path string, data []byte) error {
	if dryRun {
		return nil
	}
	return atomicWriteFile(path, data)
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
func mergeMarkdownFile(f onrampFile, force, dryRun bool) (onrampAction, error) {
	path, err := expandOnrampPath(f.Path)
	if err != nil {
		return onrampAction{}, err
	}
	block := f.Content

	existing, readErr := os.ReadFile(path)
	if os.IsNotExist(readErr) {
		if err := writeOnrampFile(dryRun, path, withTrailingNewline([]byte(block))); err != nil {
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
		if err := writeOnrampFile(dryRun, path, withTrailingNewline([]byte(merged))); err != nil {
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

	// No markers at all: this is the APPEND path. Before stacking Barkpark's
	// "all task tracking uses Barkpark" block onto the file, guard against an
	// existing competing tracker mandate (BP-ONB-14) — appending under a "log
	// every task in Jira" line would leave the agent with two mutually exclusive
	// authoritative policies. Warn (skip, --force hint) instead of silently
	// creating that contradiction; --force appends anyway.
	if tracker := competingTrackerMandate(text); tracker != "" && !force {
		return onrampAction{
			Path:   f.Path,
			Action: "skipped",
			Note:   fmt.Sprintf("this file already mandates %q for task tracking — appending Barkpark's block would leave two competing tracker mandates; re-run with --force to append anyway", tracker),
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
	if err := writeOnrampFile(dryRun, path, withTrailingNewline(buf)); err != nil {
		return onrampAction{}, err
	}
	return onrampAction{Path: f.Path, Action: "updated"}, nil
}

// competingTrackerNames are third-party task/issue trackers whose appearance in a
// mandate line means the file already declares an authoritative task-tracking
// policy. "beads" is included deliberately: it is Barkpark's own RETIRED
// predecessor, so a stale "track everything in beads" line is exactly the kind of
// contradiction BP-ONB-14 exists to catch.
var competingTrackerNames = []string{
	"jira", "linear", "asana", "trello", "clickup", "shortcut",
	"todoist", "basecamp", "youtrack", "pivotal tracker",
	"github issues", "gh issues", "beads",
}

// trackerMandateWords are the imperative / universal words that turn a line
// merely MENTIONING a tracker into a MANDATE to use it. Requiring one on the SAME
// line as the tracker name keeps the heuristic tight enough that prose which only
// name-drops a tool without an obligation is far less likely to trip it. The
// trailing spaces avoid matching inside longer words ("usual", "wall").
var trackerMandateWords = []string{
	"all ", "must ", "always ", "only ", "every ", "use ", "track",
}

// competingTrackerMandate scans prose for a single line that BOTH names a
// competing tracker AND reads as a mandate to use it, returning that tracker's
// name ("" when none). It is the guard mergeMarkdownFile consults on the
// no-markers APPEND path: silently stacking Barkpark's tracker block under a "log
// every task in Jira" line makes an agent's instructions self-contradictory, so
// the merge warns (skips with a --force hint) instead of appending blind.
// Detection is line-scoped and case-insensitive; it fails toward WARNING (a rare
// false positive is a skip the user clears with --force, never lost data).
func competingTrackerMandate(text string) string {
	for _, raw := range strings.Split(text, "\n") {
		line := strings.ToLower(raw)
		mandate := false
		for _, w := range trackerMandateWords {
			if strings.Contains(line, w) {
				mandate = true
				break
			}
		}
		if !mandate {
			continue
		}
		for _, name := range competingTrackerNames {
			if strings.Contains(line, name) {
				return name
			}
		}
	}
	return ""
}
