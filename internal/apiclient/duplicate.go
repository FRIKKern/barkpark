package apiclient

import (
	"bytes"
	"fmt"
)

// DuplicateOptions are the two things a caller may choose for a copy. Both
// are optional.
type DuplicateOptions struct {
	// ID is the id of the copy. Empty lets the server assign one.
	ID string
	// Title is the title of the copy. Empty gives "<source title> (copy)".
	Title string
}

// duplicateEnvelopeKeys are the keys the server adds to every document it
// sends (Barkpark.Content.Envelope @reserved). They describe the source row,
// so a copy never carries them. `title` is set by the copy itself, and
// `blocks` is handled apart: a stored tree is refused, a synthesized one is a
// view of fields the copy already has.
var duplicateEnvelopeKeys = map[string]bool{
	"_id": true, "_type": true, "_rev": true, "_draft": true,
	"_publishedId": true, "_createdAt": true, "_updatedAt": true,
	"title": true, "blocks": true,
}

// duplicateFlatUnsafe are field names the flat create shape cannot carry: the
// create route reads them as part of the request, not as content
// (Barkpark.Content.Writer @reserved_in and @collide_exempt). A source that
// has one is sent with its fields inside a `content` map, where every name is
// a plain field. `content` is on the list only when it holds an object; any
// other value rides the flat shape.
var duplicateFlatUnsafe = map[string]bool{
	"status": true, "id": true, "doc_id": true, "type": true, "dataset": true, "rev": true,
	"ifMatch": true, "ifRevisionID": true,
	"workspace_id": true, "project_id": true, "dataset_id": true, "owner_id": true,
}

// DuplicateCreate builds the `create` mutation that copies doc into a new
// document of typeName. It is the one copy rule the TUI's `y` key
// (Client.Duplicate) and `bp doc duplicate` share.
//
// Every field of the source is copied as raw JSON. Only the server's own
// envelope keys are left out, and the title gets " (copy)" unless opts.Title
// names one. Until 2026-11-15 the copy also left out fields named body,
// body_html, content, values, createdAt, updatedAt, id and status, without a
// word; a post lost its body.
//
// The create is flat ({"_type", "title", <fields>}) when every field name can
// ride that shape, and nested ({"_type", "title", "content": {<fields>}})
// when one cannot. The server makes a create a draft. A paper is refused: its
// block tree cannot ride the generic mutate path, and a copy without its
// blocks would lose them without saying so.
func DuplicateCreate(typeName string, doc Doc, opts DuplicateOptions) (map[string]interface{}, error) {
	if hasPersistedBlocks(doc.Blocks) {
		return nil, fmt.Errorf("papers cannot be duplicated here — use Studio")
	}

	title := opts.Title
	if title == "" {
		title = doc.Title
		if title == "" {
			title = "Untitled"
		}
		title += " (copy)"
	}
	create := map[string]interface{}{
		"_type": typeName,
		"title": title,
	}
	if opts.ID != "" {
		create["_id"] = opts.ID
	}

	fields := map[string]interface{}{}
	nested := false
	for k, raw := range doc.Extra {
		if duplicateEnvelopeKeys[k] {
			continue
		}
		fields[k] = raw
		if duplicateFlatUnsafe[k] || (k == "content" && bytes.HasPrefix(bytes.TrimSpace(raw), []byte("{"))) {
			nested = true
		}
	}
	if nested {
		create["content"] = fields
		return create, nil
	}
	for k, v := range fields {
		create[k] = v
	}
	return create, nil
}
