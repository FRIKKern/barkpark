// Package apiclient — Doc is the framework-free document model decoded from
// the Barkpark v1 query envelope. This file holds the Doc type, its envelope
// normalization, and the pure scalar/block helpers — none of which touch HTTP
// or the Client. Split out of client.go to keep that file under budget; this is
// a same-package, behaviour-preserving relocation (Go compiles the package as a
// unit, so no API changes).
package apiclient

import (
	"bytes"
	"encoding/json"
	"strconv"
	"time"
)

// Doc represents a single document from the API.
//
// The flat string fields below mirror the Sanity-style document the query API
// emits at the top level. Two RawMessage fields carry the portable-doc block
// tree for paper documents WITHOUT disturbing that flat decode:
//
//   - Type holds the document's "_type" discriminator (e.g. "paper"), so the
//     TUI can detect a paper without a schema lookup.
//   - Blocks holds the paper's block tree. The live API returns "blocks" at the
//     TOP LEVEL of each document (verified against
//     /v1/data/query/<ds>/paper?perspective=raw), so it is decoded from "blocks".
//   - Content is a forward-compat slot for a nested "content" envelope
//     (content.blocks). The current API never populates it; PaperBlocks prefers
//     top-level Blocks and falls back to content.blocks if a future shape uses it.
//
// All four block-related additions use json.RawMessage / omitempty, so an
// ordinary document (no _type/blocks/content keys, or a non-paper type) decodes
// exactly as before — the string-flat path is untouched.
type Doc struct {
	ID        string            `json:"id"`
	Type      string            `json:"_type,omitempty"`
	Title     string            `json:"title"`
	Status    string            `json:"status"`
	Category  string            `json:"category,omitempty"`
	Author    string            `json:"author,omitempty"`
	UpdatedAt time.Time         `json:"updatedAt"`
	Values    map[string]string `json:"values,omitempty"`
	// Blocks is the paper block tree as emitted at the document top level.
	Blocks json.RawMessage `json:"blocks,omitempty"`
	// Content is the forward-compat nested envelope ({"blocks":[…]}). Unused by
	// the current API; PaperBlocks falls back to it when top-level Blocks is empty.
	Content json.RawMessage `json:"content,omitempty"`
	// Extra holds every top-level key of the decoded envelope, raw. The v1
	// envelope flattens a document's content fields to the top level (verified
	// against /v1/data/query — e.g. a task's "lifecycle_status" / "priority"
	// ride beside "_id"), and the typed fields above only capture a fixed
	// subset. list_preview rendering reads arbitrary schema-named fields via
	// ContentString. Never serialized back (json:"-"); nil for hand-built docs.
	Extra map[string]json.RawMessage `json:"-"`
}

// UnmarshalJSON decodes the typed fields exactly as before (alias type — no
// behaviour change), captures the raw top-level key set into Extra so
// schema-named content fields are reachable without a struct change per field,
// then normalizes the v1 flat envelope onto the legacy-shaped typed fields
// (ID / UpdatedAt / Values) the TUI consumes.
func (d *Doc) UnmarshalJSON(b []byte) error {
	type docAlias Doc
	var a docAlias
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	*d = Doc(a)
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err == nil {
		d.Extra = raw
		d.normalizeEnvelope()
	}
	return nil
}

// envelopeMetaKeys are the v1 envelope's reserved/structural top-level keys.
// Everything else at the top level is a flattened content field (the envelope
// merges doc.content into the root — see Barkpark.Content.Envelope) and
// belongs in Values for the field editor.
var envelopeMetaKeys = map[string]bool{
	"_id": true, "_type": true, "_rev": true, "_draft": true,
	"_publishedId": true, "_createdAt": true, "_updatedAt": true,
	"title": true, "blocks": true, "content": true,
}

// normalizeEnvelope maps the v1 flat envelope onto the legacy-shaped typed
// fields. The legacy keys ("id", "updatedAt", "values") never appear on the
// live wire — the envelope emits "_id" / "_updatedAt" and flattens content to
// the top level (verified against /v1/data/query) — so the plain typed decode
// left ID empty, UpdatedAt zero and Values nil, latently breaking every
// consumer (saveDocument's patch target, Get-by-id, the editor's field
// values, timeAgo subtitles). Each fill is guarded so a legacy envelope that
// DOES carry the old keys still wins.
func (d *Doc) normalizeEnvelope() {
	if d.ID == "" {
		var id string
		if json.Unmarshal(d.Extra["_id"], &id) == nil {
			d.ID = id
		}
	}
	if d.UpdatedAt.IsZero() {
		var ts string
		if json.Unmarshal(d.Extra["_updatedAt"], &ts) == nil {
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				d.UpdatedAt = t
			}
		}
	}
	if d.Status == "" {
		// The envelope carries publish state as the "_draft" boolean, not the
		// legacy "status" string the TUI's header/icons key off.
		var draft bool
		if json.Unmarshal(d.Extra["_draft"], &draft) == nil {
			if draft {
				d.Status = "draft"
			} else {
				d.Status = "published"
			}
		}
	}
	if len(d.Values) == 0 {
		values := make(map[string]string)
		for k, raw := range d.Extra {
			if envelopeMetaKeys[k] {
				continue
			}
			if v, ok := scalarString(raw); ok {
				values[k] = v
			}
		}
		if len(values) > 0 {
			d.Values = values
		}
	}
}

// scalarString renders a raw JSON scalar as the editor's string value:
// strings verbatim, numbers via their literal representation, booleans as
// "true"/"false" (the editor's boolean-toggle convention writes the same
// strings into dirtyValues). null, objects and arrays return ok=false — they
// have no flat-editor rendering.
func scalarString(raw json.RawMessage) (string, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s, true
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String(), true
	}
	var bv bool
	if err := json.Unmarshal(raw, &bv); err == nil {
		return strconv.FormatBool(bv), true
	}
	return "", false
}

// ContentString returns the scalar string rendering of a top-level envelope
// field: a JSON string verbatim, a JSON number via its literal representation
// ("1", "1.5"), and "" for anything else (missing, bool, null, object, array)
// — mirroring the Studio PaneBuilder's format_preview, where a misdeclared
// field degrades to "no badge", never a crash.
func (d Doc) ContentString(field string) string {
	raw, ok := d.Extra[field]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String()
	}
	return ""
}

// ClaimEpoch returns the fencing epoch of this task document's claim object
// (content.claim.epoch, flattened to the envelope top level as "claim") and
// whether a live claim is present. Epochs start at 1 on first claim, so 0
// never names a real claim — absent / unparseable / zero all report ok=false.
func (d Doc) ClaimEpoch() (int, bool) {
	raw, ok := d.Extra["claim"]
	if !ok {
		return 0, false
	}
	var c struct {
		Epoch int `json:"epoch"`
	}
	if err := json.Unmarshal(raw, &c); err != nil || c.Epoch <= 0 {
		return 0, false
	}
	return c.Epoch, true
}

// PaperBlocks returns the raw JSON for this document's portable-doc block tree,
// preferring the top-level "blocks" the live API emits and falling back to a
// nested "content":{"blocks":[…]} envelope if one is ever present. It returns
// nil when the document carries no block tree (every non-paper doc), so callers
// can branch on "is this a paper with renderable content?" off a single nil check.
func (d Doc) PaperBlocks() json.RawMessage {
	if len(d.Blocks) > 0 {
		return d.Blocks
	}
	if len(d.Content) > 0 {
		var env struct {
			Blocks json.RawMessage `json:"blocks"`
		}
		if err := json.Unmarshal(d.Content, &env); err == nil && len(env.Blocks) > 0 {
			return env.Blocks
		}
		// A bare content array (no envelope) is also acceptable.
		var arr []json.RawMessage
		if err := json.Unmarshal(d.Content, &arr); err == nil && len(arr) > 0 {
			return d.Content
		}
	}
	return nil
}
