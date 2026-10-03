package cli

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// doc_ls_drafts_only.go — an empty published page of a type whose documents
// are all still drafts.
//
// Found on the lane-b dogfood walk (2026-10-03, a fresh local instance):
//
//	bp schema apply --file recipe.json   → id: recipe
//	bp seed recipe --count 3             → {"count":3,…,"published":false}
//	bp doc ls recipe                     → (no rows)  count: 0      exit 0, stderr silent
//
// Every new document starts as a DRAFT (doc create, seed, the TUI's `n`, the
// MCP create tool), and `doc ls` reads the PUBLISHED perspective by default.
// So the first list after writing content was an empty page that read as "my
// writes were lost". This adds ONE stderr line, never a refusal and never a
// changed exit code: after a 2xx `doc ls` whose page came back EMPTY under the
// default/published perspective, it asks the drafts perspective once (limit 1)
// through the manifest's own route, and says drafts exist when they do. A
// caller that already chose drafts or raw is left alone. `-o json` stdout is
// untouched. Sibling notes: doc_unknown_type.go (no such type) and
// doc_unpublish_draft_only.go (unpublish of a never-published draft).
func emitDocLsDraftsOnly(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, status int, respBody []byte) {
	if cmd.ID != "doc.ls" || status < 200 || status >= 300 || m == nil || !commandDeclaresFlag(cmd, "perspective") {
		return
	}
	rows, key := extractListRows(unwrapResult(respBody))
	if key == "" || len(rows) != 0 {
		return
	}
	pos, flags, err := splitArgs(cmd, tail)
	if err != nil {
		return
	}
	if p := flags["perspective"]; len(p) > 0 && !strings.EqualFold(p[len(p)-1], "published") {
		return
	}
	args, err := bindArgs(cmd, pos)
	if err != nil || strings.TrimSpace(args["type"]) == "" {
		return
	}
	typeName := strings.TrimSpace(args["type"])
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false
	lg.limit = 1
	lg.limitSet = true
	probeStatus, probeBody, err := execManifestCommand(lg, ctx, m, cmd, []string{typeName, "--perspective", docGetDraftProbePerspective})
	if err != nil || probeStatus < 200 || probeStatus >= 300 {
		return
	}
	if drafts, _ := extractListRows(unwrapResult(probeBody)); len(drafts) == 0 {
		return
	}
	out.errf("bp: no PUBLISHED %s documents, but drafts exist — new documents start as drafts. List them with `bp doc ls %s --perspective drafts`; publish one with `bp doc publish %s <id>`.",
		typeName, typeName, typeName)
}
