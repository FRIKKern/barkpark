package cli

// scaffy_describe_cmd.go is `bp scaffy describe <cmd> [-o json]` — a command's
// contract read straight off the AST (charter D102). PURE LOCAL like the rest
// of the scaffy surface: scaffy.Parse is the only engine call, no server, no
// auth, no manifest. The implementation lives here (not scaffy_cmd.go) because
// TestScaffyPureLocal scans scaffy_cmd.go for network seams — scaffy_cmd.go
// carries ONLY the dispatch case (the D48 remote-verb precedent).
//
// describe answers "what does this command take, touch, and check?" without
// running it: name/description/direction/domain/tags from the header, one row
// per declared VARIABLE with a SYNTHESIZED kind (no AST Kind field exists —
// it is derived from the Opaque/Shape/OneOf/Successor flags), op counts keyed
// by shape (create_file / delete_file / in.<verb_snake>), and the closing
// asserts as {kind, tier, text}. -o json|yaml emits the machine envelope; the
// human view is a compact sectioned render consistent with the other verbs.

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// runScaffyDescribe is `bp scaffy describe <command.scaffy|name>`. It resolves
// the target (a path, or a bare command name under scaffy/commands/), parses
// it, and emits the contract. AST-only: parse findings never gate describe —
// it reports whatever the grammar recovered. Exactly one positional is
// required; any flag or a second positional is a usage error (exit 2). A
// target that resolves to nothing is exit 4.
func runScaffyDescribe(out *writer, args []string) int {
	var targets []string
	for _, a := range args {
		if strings.HasPrefix(a, "-") && a != "-" {
			return usageErrf(out, func() { printScaffyDescribeHelp(out) }, "unknown describe flag %q", a)
		}
		targets = append(targets, a)
	}
	if len(targets) != 1 {
		return usageErrf(out, func() { printScaffyDescribeHelp(out) }, "scaffy describe needs exactly one <command.scaffy|name> (got %d)", len(targets))
	}

	path, rerr := resolveScaffyDescribeTarget(targets[0])
	if rerr != nil {
		return useError(out, "not_found", "scaffy describe: "+rerr.Error(), exitNotFound)
	}
	src, err := os.ReadFile(path)
	if err != nil {
		return useError(out, "io", "scaffy describe: "+err.Error(), exitNotFound)
	}

	cmd, _ := scaffy.Parse(path, src)
	if out.machineOut() {
		out.emitStructured(scaffyDescribeEnvelope(cmd))
		return exitOK
	}
	renderScaffyDescribe(out, cmd)
	return exitOK
}

// resolveScaffyDescribeTarget maps the argument to a readable .scaffy file. It
// accepts, in order: the path verbatim, the path with a .scaffy suffix, and —
// for a bare name with no separator — scaffy/commands/<name>.scaffy under the
// cwd (the corpus home every other local verb assumes). The first existing
// regular file wins; none found is fs.ErrNotExist-shaped (exit 4).
func resolveScaffyDescribeTarget(arg string) (string, error) {
	var candidates []string
	candidates = append(candidates, arg)
	if !strings.HasSuffix(arg, ".scaffy") {
		candidates = append(candidates, arg+".scaffy")
	}
	if !strings.Contains(arg, "/") && !strings.ContainsRune(arg, os.PathSeparator) {
		base := arg
		if !strings.HasSuffix(base, ".scaffy") {
			base += ".scaffy"
		}
		candidates = append(candidates, filepath.Join("scaffy", "commands", base))
	}
	for _, p := range candidates {
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			return p, nil
		}
	}
	return "", fmt.Errorf("%q not found (tried %s): %w", arg, strings.Join(candidates, ", "), fs.ErrNotExist)
}

// scaffyDescribeEnvelope is the machine shape: name/description/direction plus
// optional domain/tags, a variable row per declaration, op counts keyed by
// shape, and the asserts. Empty header fields are omitted so the JSON stays
// tight — the "contract in 50 tokens" (D102).
func scaffyDescribeEnvelope(cmd *scaffy.Command) map[string]any {
	env := map[string]any{
		"name":      headerValue(cmd.Header.Command),
		"direction": cmd.Direction(),
		"variables": scaffyDescribeVariables(cmd.Variables),
		"ops":       scaffyDescribeOpCounts(cmd.Ops),
		"asserts":   scaffyDescribeAsserts(cmd.Asserts),
	}
	if d := headerValue(cmd.Header.Description); d != "" {
		env["description"] = d
	}
	if d := headerValue(cmd.Header.Domain); d != "" {
		env["domain"] = d
	}
	if t := headerValue(cmd.Header.Tags); t != "" {
		env["tags"] = t
	}
	return env
}

// headerValue is the value of a header field, or "" when the field is absent.
func headerValue(f *scaffy.HeaderField) string {
	if f == nil {
		return ""
	}
	return f.Value
}

// scaffyDescribeVariables renders one row per VARIABLE: {name, kind, title,
// description, oneof, examples}. title/description/oneof/examples are omitted
// when empty. kind is SYNTHESIZED from the declaration flags (scaffyVarKind).
func scaffyDescribeVariables(vars []*scaffy.VariableDecl) []any {
	rows := make([]any, 0, len(vars))
	for _, v := range vars {
		row := map[string]any{
			"name": v.Name,
			"kind": scaffyVarKind(v),
		}
		if v.Title != "" {
			row["title"] = v.Title
		}
		if v.Description != "" {
			row["description"] = v.Description
		}
		if len(v.OneOf) > 0 {
			row["oneof"] = scaffyStringSlice(v.OneOf)
		}
		if len(v.Examples) > 0 {
			row["examples"] = scaffyStringSlice(v.Examples)
		}
		rows = append(rows, row)
	}
	return rows
}

// scaffyVarKind synthesizes a variable's kind — there is NO Kind field on the
// AST (D102), so it is derived from the declaration flags in a fixed
// precedence: OPAQUE wins (and appends its SHAPE when both are present), then
// a bare SHAPE, then ONEOF (enum), then SUCCESSOR, else plain.
func scaffyVarKind(v *scaffy.VariableDecl) string {
	switch {
	case v.Opaque && v.Shape != "":
		return "opaque shape:" + v.Shape
	case v.Opaque:
		return "opaque"
	case v.Shape != "":
		return "shape:" + v.Shape
	case len(v.OneOf) > 0:
		return "enum"
	case v.Successor != "":
		return "successor"
	default:
		return "plain"
	}
}

// scaffyDescribeOpCounts tallies the ops keyed by SHAPE: create_file,
// delete_file, and in.<verb_snake> for each IN-scoped op (e.g.
// in.insert_after_first, in.replace, in.remove) — the verb comes from
// InOpVerb.String() lowercased with spaces folded to underscores.
func scaffyDescribeOpCounts(ops []scaffy.Op) map[string]any {
	counts := map[string]int{}
	for _, op := range ops {
		switch o := op.(type) {
		case *scaffy.CreateFile:
			counts["create_file"]++
		case *scaffy.DeleteFile:
			counts["delete_file"]++
		case *scaffy.InOp:
			counts["in."+snakeKeyword(o.Verb.String())]++
		}
	}
	out := make(map[string]any, len(counts))
	for k, v := range counts {
		out[k] = v
	}
	return out
}

// scaffyDescribeAsserts renders the closing asserts as {kind, tier, text}. kind
// is the AssertKind.String() with its "ASSERT " prefix stripped and folded to
// snake_case (file_contains, file_dont_contain, file_exists, file_absent,
// cmd); tier is the declared tier or "local" when none was declared.
func scaffyDescribeAsserts(asserts []*scaffy.Assert) []any {
	rows := make([]any, 0, len(asserts))
	for _, a := range asserts {
		tier := a.Tier
		if tier == "" {
			tier = "local"
		}
		rows = append(rows, map[string]any{
			"kind": scaffyAssertKindKey(a.Kind),
			"tier": tier,
			"text": a.Text,
		})
	}
	return rows
}

// scaffyAssertKindKey is AssertKind.String() minus the "ASSERT " prefix, folded
// to snake_case: "ASSERT FILE CONTAINS" -> "file_contains", "ASSERT CMD" ->
// "cmd".
func scaffyAssertKindKey(k scaffy.AssertKind) string {
	return snakeKeyword(strings.TrimPrefix(k.String(), "ASSERT "))
}

// snakeKeyword folds a grammar keyword phrase to a snake_case key: lowercase,
// spaces to single underscores.
func snakeKeyword(s string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), " ", "_")
}

// scaffyStringSlice copies a []string into a []any for the machine envelope.
func scaffyStringSlice(ss []string) []any {
	arr := make([]any, 0, len(ss))
	for _, s := range ss {
		arr = append(arr, s)
	}
	return arr
}

// renderScaffyDescribe prints the human view: a header line, the description,
// then variables / ops / asserts sections in the house voice (lowercase
// labels, two-space indent) consistent with the other scaffy verbs.
func renderScaffyDescribe(out *writer, cmd *scaffy.Command) {
	name := headerValue(cmd.Header.Command)
	if name == "" {
		name = "(unnamed)"
	}
	dir := cmd.Direction()
	if dir == "" {
		dir = "?"
	}
	out.outf("%s — direction %s", name, dir)
	if d := headerValue(cmd.Header.Domain); d != "" {
		line := "domain " + d
		if t := headerValue(cmd.Header.Tags); t != "" {
			line += " · tags " + t
		}
		out.outf("%s", line)
	}
	if d := headerValue(cmd.Header.Description); d != "" {
		out.outf("%s", d)
	}

	out.outf("")
	out.outf("variables:")
	if len(cmd.Variables) == 0 {
		out.outf("  (none)")
	}
	for _, v := range cmd.Variables {
		line := fmt.Sprintf("  %s  %s", v.Name, scaffyVarKind(v))
		if v.Title != "" {
			line += "  " + v.Title
		}
		out.outf("%s", line)
		if len(v.OneOf) > 0 {
			out.outf("    oneof: %s", strings.Join(v.OneOf, ", "))
		}
		if len(v.Examples) > 0 {
			out.outf("    e.g. %s", strings.Join(v.Examples, ", "))
		}
	}

	out.outf("")
	out.outf("ops:")
	counts := scaffyDescribeOpCounts(cmd.Ops)
	if len(counts) == 0 {
		out.outf("  (none)")
	} else {
		keys := make([]string, 0, len(counts))
		for k := range counts {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			out.outf("  %s  %v", k, counts[k])
		}
	}

	out.outf("")
	out.outf("asserts:")
	if len(cmd.Asserts) == 0 {
		out.outf("  (none)")
	}
	for _, a := range cmd.Asserts {
		tier := a.Tier
		if tier == "" {
			tier = "local"
		}
		out.outf("  %s  %s  %q", scaffyAssertKindKey(a.Kind), tier, a.Text)
	}
}

func printScaffyDescribeHelp(out *writer) {
	out.outf(`usage: bp scaffy describe <command.scaffy|name>

Read a command's CONTRACT straight off the parsed AST — no run, no repo, no
server. Answers "what does this command take, touch, and check?": the header
(name, description, direction, domain, tags), one row per declared VARIABLE
with a synthesized kind, the op counts keyed by shape, and the closing
asserts.

The <command> is a path to a .scaffy file OR a bare command name resolved
under scaffy/commands/ in the current working directory (like run/remove).

Variable kind is SYNTHESIZED from the declaration (there is no Kind keyword):
  opaque | opaque shape:<name> | shape:<name> | enum | successor | plain

Op counts are keyed create_file / delete_file / in.<verb_snake> (e.g.
in.insert_after_first, in.replace). Asserts render as {kind, tier, text}
with tier "local" when no TIER was declared.

-o json|-o yaml emits {name, description, direction, domain, tags,
variables:[{name,kind,title,description,oneof,examples}], ops:{<key>:N},
asserts:[{kind,tier,text}]} — empty header fields are omitted.

examples:
  bp scaffy describe scaffy/commands/add-migration.scaffy
  bp scaffy describe add-migration                       # bare name
  bp scaffy describe classify-block-type -o json | jq '.variables'

exit codes:
  0  described
  2  usage error (no command, extra positional, or unknown flag)
  4  command file not found`)
}
