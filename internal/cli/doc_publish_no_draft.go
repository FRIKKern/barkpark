package cli

import (
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// doc_publish_no_draft.go — `bp doc publish` on a document with NOTHING TO
// PUBLISH.
//
// Found on the stranger walk (2026-09-30, a fresh local instance): publish a
// post, then publish it again. The second publish has no draft to promote, and
// the server answers 404 `not_found: document not found` with the hint "Check
// the document _id, type, and dataset in the URL — the resource does not exist
// in this scope." Every clause of that is false for this caller: the id, type
// and dataset are right and the document exists — it just has no pending
// draft. A first-time user reads it as "my post is gone".
//
// The server's sentence is api/'s (the mutate publish op). This file does not
// touch the refusal or the exit code: after the render, on doc.publish's own
// 404 only, it asks the published lens once through the manifest's own
// `doc get` route with the caller's own credentials. If the document is there,
// it says so and names the step that makes a publish meaningful. If the probe
// also misses, the 404 was a real absence and nothing is added. stderr only,
// so `-o json` stays byte-identical.
func emitDocPublishNothingToPublish(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, status int) {
	if cmd.ID != docPublishCommandID || status != 404 || m == nil {
		return
	}
	typeName, bareID, ok := docPublishArgs(cmd, tail)
	if !ok {
		return
	}
	get, ok := m.Tree().Lookup("doc", "get")
	if !ok || get == nil {
		return
	}
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false
	probeStatus, _, err := execManifestCommand(lg, ctx, m, *get, []string{typeName, bareID})
	if err != nil || probeStatus < 200 || probeStatus >= 300 {
		return
	}
	out.errf("bp: nothing to publish — %s `%s` EXISTS and its published version is already current; there is no pending draft (`drafts.%s`) for publish to promote. Edit it first (`bp doc patch %s %s --set <field>=<value>` writes a draft), then publish. `bp doc get %s %s` shows what is live.",
		typeName, bareID, bareID, typeName, bareID, typeName, bareID)
}
