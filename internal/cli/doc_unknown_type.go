package cli

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// doc_unknown_type.go — a typo'd document TYPE answers like an empty one.
//
// Found on the stranger walk (2026-09-30, a fresh local instance):
//
//	bp doc ls nosuchtype                 → {"count":0,…} at exit 0, nothing on stderr
//	bp doc create nosuchtype --set …     → "DRAFT created (drafts.nosuchtype-…)" at exit 0
//
// The content store accepts a document of any _type, and a list of a type
// nobody declared is simply empty — so `bp doc ls Post` (capital P) reads as
// "I have no posts", and `bp doc create psot …` quietly founds a schemaless
// type. Neither answer is wrong at the store; both mislead the person typing.
//
// This adds ONE stderr line, never a refusal and never a changed exit code:
// after a 2xx `doc create`, or a `doc ls`/`doc query` whose page came back
// EMPTY, it asks `schema get <type>` once through the manifest's own route.
// A 404 means no schema of that name exists, and the line says so and names
// `bp schema ls`. The probe runs only when the caller's tier carries
// `schema get` (it is admin-tier on the live manifest); below that the check is
// skipped rather than guessed. `-o json` stdout is untouched.

var unknownTypeCommands = map[string]bool{"doc.ls": true, "doc.query": true, "doc.create": true}

func emitDocUnknownType(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, status int, respBody []byte) {
	if !unknownTypeCommands[cmd.ID] || status < 200 || status >= 300 || m == nil {
		return
	}
	if cmd.ID != "doc.create" {
		// A read that returned rows proves the type is in use; only an EMPTY
		// page is ambiguous between "no documents yet" and "no such type".
		rows, key := extractListRows(unwrapResult(respBody))
		if key == "" || len(rows) != 0 {
			return
		}
	}
	typeName := boundArg(cmd, tail, "type")
	if typeName == "" {
		return
	}
	get, ok := m.Tree().Lookup("schema", "get")
	if !ok || get == nil {
		return
	}
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false
	probeStatus, _, err := execManifestCommand(lg, ctx, m, *get, []string{typeName})
	if err != nil || probeStatus != 404 {
		return
	}
	what := "this empty page is not evidence that it simply has no documents yet"
	if cmd.ID == "doc.create" {
		what = "the document was stored anyway, under a type no schema describes — Studio has no form for it"
	}
	out.errf("bp: no schema named %q exists on this server — %s. Check the spelling (types are case-sensitive); `bp schema ls` lists the declared types.", typeName, what)
}

// boundArg re-binds cmd's positionals and returns the named one ("" when absent
// or unbindable) — the same pure splitArgs/bindArgs pair the request builder
// used, so a flag value can never be mistaken for the type.
func boundArg(cmd manifest.Command, tail []string, name string) string {
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return ""
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(args[name])
}
