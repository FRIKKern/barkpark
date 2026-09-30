package cli

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// doc_unpublish_draft_only.go — `bp doc unpublish` on a document that has
// NEVER BEEN PUBLISHED.
//
// Found on the stranger walk (2026-09-30, a fresh local instance): unpublish a
// document that exists only as `drafts.<id>`. The server answers 404
// `not_found: document not found` with the hint "Check the document _id, type,
// and dataset in the URL — the resource does not exist in this scope." The id,
// type and dataset are right and the document exists; it simply has no
// published version to take down. The twin of doc_publish_no_draft.go (a
// publish with nothing to publish) and doc_get_draft_perspective.go.
//
// Same shape as those: on doc.unpublish's own 404 only, ONE drafts-lens read
// through the manifest's `doc get` route with the caller's own credentials. The
// published row is what just answered 404, and `drafts` falls back to it, so a
// 2xx can only be the draft twin. stderr only, after the render: the exit code
// and every byte of `-o json` stay unchanged. Silence means "not established".
const docUnpublishCommandID = "doc.unpublish"

func emitDocUnpublishDraftOnly(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, status int) {
	if cmd.ID != docUnpublishCommandID || status != 404 || m == nil {
		return
	}
	typeName, bareID, ok := docUnpublishArgs(cmd, tail)
	if !ok {
		return
	}
	get, ok := m.Tree().Lookup("doc", "get")
	if !ok || get == nil || !commandDeclaresFlag(*get, "perspective") {
		return
	}
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false
	probe := []string{typeName, bareID, "--perspective", docGetDraftProbePerspective}
	probeStatus, _, err := execManifestCommand(lg, ctx, m, *get, probe)
	if err != nil || probeStatus < 200 || probeStatus >= 300 {
		return
	}
	out.errf("bp: nothing to unpublish — %s `%s` EXISTS only as a draft (`drafts.%s`) and has never been published, so there is no published version to take down. To remove the draft itself: `bp doc discard-draft %s %s --delete-unpublished`.",
		typeName, bareID, bareID, typeName, bareID)
}

// docUnpublishArgs recovers the (type, id) positionals doc.unpublish bound,
// through the same bindArgs the request builder used.
func docUnpublishArgs(cmd manifest.Command, tail []string) (string, string, bool) {
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return "", "", false
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return "", "", false
	}
	typeName := args["type"]
	id := args["id"]
	if id == "" {
		id = args["doc_id"]
	}
	bare := strings.TrimPrefix(id, draftIDPrefix)
	if typeName == "" || bare == "" {
		return "", "", false
	}
	return typeName, bare, true
}
