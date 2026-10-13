package cli

import (
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp media delete` accepts the id `bp media upload` hands back.
//
// THE TWO IDS. An upload stores a blob row in media_files and the media plugin
// then creates a companion `mediaAsset` document for it
// (api/lib/barkpark/plugins/media/assets.ex create_draft/1). The document's id
// is `asset-<media file id>`, it starts as a draft (`drafts.asset-<id>`), and
// its content carries the blob id under `mediaFileId`. The upload receipt
// carries both: `id` / `mediaFileId` is the blob, `assetDocId` is the
// document.
//
// DELETE /v1/media/:dataset/:id takes the BLOB id (Media.get_file/2). Handed
// the document id it answers not_found, so a caller that kept `assetDocId` from
// the receipt, or copied an id out of Studio or `bp doc ls mediaAsset`, could
// not delete what it had just uploaded (task-33e5b203e987650c).
//
// THE FIX IS CLIENT-SIDE. When the id names an asset document, bp reads that
// document (`doc get mediaAsset <id> --perspective drafts`, which finds the
// draft or the published row) and sends the delete for its `mediaFileId`. If
// the read does not answer with one, bp falls back to the id the server itself
// derives: `asset-<id>` and `drafts.asset-<id>` map to `<id>`, the same rule
// api/lib/barkpark/media/image_metadata.ex file_id/1 applies. A media file id
// is passed through untouched, so nothing that worked before changes.

const (
	mediaDeleteCommandID = "media.delete"
	mediaAssetDocType    = "mediaAsset"
	mediaAssetIDPrefix   = "asset-"
)

// mediaAssetDocID reports whether id names a media asset document, and returns
// the id with any `drafts.` prefix removed.
func mediaAssetDocID(id string) (string, bool) {
	bare := strings.TrimPrefix(id, draftIDPrefix)
	if !strings.HasPrefix(bare, mediaAssetIDPrefix) || len(bare) == len(mediaAssetIDPrefix) {
		return "", false
	}
	return bare, true
}

// resolveMediaDeleteID rewrites the `id` positional of `bp media delete` from
// an asset document id to its media file id. It returns tail unchanged for any
// other command, for an id that is already a media file id, and when the
// positionals do not bind (buildManifestRequest then reports that itself).
func resolveMediaDeleteID(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) []string {
	if cmd.ID != mediaDeleteCommandID {
		return tail
	}
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return tail
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		return tail
	}
	id := args["id"]
	docID, ok := mediaAssetDocID(id)
	if !ok {
		return tail
	}

	fileID, how := readMediaFileID(g, ctx, m, docID)
	if fileID == "" {
		fileID = strings.TrimPrefix(docID, mediaAssetIDPrefix)
		how = "the asset document could not be read, so the id after `asset-` is used"
	}

	rewritten := make([]string, len(tail))
	copy(rewritten, tail)
	for i, tok := range rewritten {
		if tok == id {
			rewritten[i] = fileID
			break
		}
	}
	out.errf("note: %s is a media asset document id; deleting its media file %s (%s)", id, fileID, how)
	return rewritten
}

// readMediaFileID reads the asset document's `mediaFileId` through the
// server's own `doc get`, with the same credentials and scope as the delete.
// It returns "" when the read fails or the document carries no file id.
func readMediaFileID(g globals, ctx manifest.Context, m *manifest.Manifest, docID string) (string, string) {
	get, ok := m.Tree().Lookup("doc", "get")
	if !ok {
		return "", ""
	}
	tail := []string{mediaAssetDocType, docID}
	if commandDeclaresFlag(*get, "perspective") {
		tail = append(tail, "--perspective", "drafts")
	}
	lg := g
	lg.yes = true
	lg.dryRun = false
	lg.all = false
	lg.limitSet, lg.offsetSet = false, false

	status, body, err := execManifestCommand(lg, ctx, m, *get, tail)
	if err != nil || status/100 != 2 {
		return "", ""
	}
	var doc struct {
		MediaFileID string `json:"mediaFileId"`
		Content     struct {
			MediaFileID string `json:"mediaFileId"`
		} `json:"content"`
	}
	if json.Unmarshal(unwrapResult(body), &doc) != nil {
		return "", ""
	}
	fileID := doc.MediaFileID
	if fileID == "" {
		fileID = doc.Content.MediaFileID
	}
	if fileID == "" {
		return "", ""
	}
	return fileID, "read from the asset document's mediaFileId"
}
