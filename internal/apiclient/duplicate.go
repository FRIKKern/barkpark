package apiclient

import "fmt"

// DuplicateOptions are the two things a caller may choose for a copy. Both
// are optional.
type DuplicateOptions struct {
	// ID is the id of the copy. Empty lets the server assign one.
	ID string
	// Title is the title of the copy. Empty gives "<source title> (copy)".
	Title string
}

// DuplicateCreate builds the `create` mutation that copies doc into a new
// document of typeName. It is the one copy rule the TUI's `y` key
// (Client.Duplicate) and `bp doc duplicate` share: the title gets " (copy)"
// unless opts.Title names one, every content field is copied as raw JSON, and
// the document's own metadata is left out. The server makes a create a draft.
// A paper is refused: its block tree cannot ride the generic mutate path, and
// a copy without its blocks would lose them without saying so.
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
	for k, raw := range doc.Extra {
		if envelopeMetaKeys[k] || duplicateSkipKeys[k] {
			continue
		}
		create[k] = raw
	}
	return create, nil
}
