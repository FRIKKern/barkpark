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
//   - Body ({"blocks":[…]}) and BodyHTML (pre-rendered HTML) are the two
//     alternate paper shapes live on guerrilla: some papers project their block
//     tree under "body", others carry only "body_html". PaperBlocks falls back
//     through body.blocks; BodyHTML is the render source when no block tree exists.
//
// All block-related additions use json.RawMessage/omitempty (BodyHTML is a
// string with omitempty), so an ordinary document (no _type/blocks/content/
// body/body_html keys, or a non-paper type) decodes exactly as before — the
// string-flat path is untouched.
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
	// Body is a second nested envelope shape ({"blocks":[…]}) some papers use
	// instead of top-level "blocks" (e.g. block-editor docs projected under
	// "body" — verified against enterprise-ready-auth-wave-2026-07-11, whose 58
	// blocks live at body.blocks). PaperBlocks falls back to it after Content.
	Body json.RawMessage `json:"body,omitempty"`
	// BodyHTML is the pre-rendered HTML some papers carry INSTEAD of a block tree
	// (e.g. soc2-controls-mapping, a 7.7 KB body_html with no blocks). It is the
	// last-resort render source: a paper with body_html but no blocks is NOT
	// empty. Callers strip it to plain text when no block tree is present.
	BodyHTML string `json:"body_html,omitempty"`
	// Extra holds every top-level key of the decoded envelope, raw. The v1
	// envelope flattens a document's content fields to the top level (verified
	// against /v1/data/query — e.g. a task's "lifecycle_status" / "priority"
	// ride beside "_id"), and the typed fields above only capture a fixed
	// subset. list_preview rendering reads arbitrary schema-named fields via
	// ContentString. Never serialized back (json:"-"); nil for hand-built docs.
	Extra map[string]json.RawMessage `json:"-"`
}

// UnmarshalJSON decodes a document TOLERANTLY: one mis-shaped field costs that
// FIELD, never the document, and never the document's whole page.
//
// Go's encoding/json fails the ENTIRE Unmarshal when ONE field's shape does not
// match the struct — you do not lose that field, you lose the whole value, and
// inside a []Doc (QueryResult, Search) you lose every OTHER document too. That
// is reachable here, not theoretical: the v1 envelope flattens EVERY unreserved
// content field to the top level under its own name (Barkpark.Content.Envelope),
// and a reference field's value is "either a plain id string or a Sanity-style
// %{"_ref" => id} object" (Barkpark.Content.Expand) — same field, same schema,
// two shapes. The live `post` schema declares a reference field literally named
// "author", so an expanded or object-shaped reference used to hand a JSON object
// to Doc.Author string and blank an entire list pane SILENTLY: QueryResult
// returns (nil, DocReadUnreachable) and Query discards the outcome, so the pane
// spells "the read failed" exactly like "this type holds nothing".
//
// The SEVEN fields whose json names are also reachable content-field names —
// id, status, category, author, updatedAt, values, body_html — are therefore
// held as raw JSON during the struct decode (the shadow fields below) and
// coerced afterwards in normalizeEnvelope, through the same tolerant
// scalarString the file already used to derive Values. A well-shaped document
// decodes to exactly the values it decoded to before, pinned field-by-field
// against a captured baseline in doc_tolerant_decode_test.go.
//
// "id" is the worst of the seven and the least obvious: @reserved in
// Barkpark.Content.Envelope is only _id/_type/_rev/_draft/_publishedId/
// _createdAt/_updatedAt, so a content field named plain "id" flattens onto
// Doc.ID — the document's IDENTITY, which saveDocument patches against and
// Get-by-id reads. A collision there does not merely blank a field, it makes
// the document unaddressable. Shadowing it changes NO precedence: "id" is the
// only wire tag ID carries ("_id" is not a struct tag, it is the Extra gap-fill
// below), and the coerced fill runs BEFORE that gap-fill, so a legacy "id"
// still beats "_id" exactly as it did — see TestLegacyEnvelopeKeysWin.
//
// The exported fields and their json tags are unchanged — this is a DECODE
// change, not an API change.
func (d *Doc) UnmarshalJSON(b []byte) error {
	type docAlias Doc
	// The shadow fields sit at depth 0 and therefore WIN over the embedded
	// alias's same-named fields (encoding/json resolves a json-name conflict by
	// the shallowest depth), which is what keeps the typed counterparts out of
	// the wire decode. json.RawMessage accepts any shape, so an object-, array-
	// or number-valued "author" can no longer fail the Unmarshal. Embedding the
	// alias (rather than restating the safe fields) means a field added to Doc
	// later is picked up automatically.
	var a struct {
		docAlias
		ID        json.RawMessage `json:"id"`
		Status    json.RawMessage `json:"status"`
		Category  json.RawMessage `json:"category"`
		Author    json.RawMessage `json:"author"`
		UpdatedAt json.RawMessage `json:"updatedAt"`
		Values    json.RawMessage `json:"values"`
		BodyHTML  json.RawMessage `json:"body_html"`
	}
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	*d = Doc(a.docAlias)
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err == nil {
		d.Extra = raw
	}
	// Unconditional: the seven shadowed fields are filled HERE now, so skipping
	// this call would drop them rather than merely skip the gap-fills.
	d.normalizeEnvelope()
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
	"body": true, "body_html": true,
}

// normalizeEnvelope does two jobs, in this order.
//
// FIRST it fills the seven fields UnmarshalJSON deliberately does NOT decode
// from the wire (id / status / category / author / updatedAt / values /
// body_html), coercing each from its raw Extra value. This is the same work the
// typed struct decode used to do, minus the failure mode: scalarString and
// rfc3339Time report failure instead of erroring, so a reference-shaped
// "author" leaves Author empty rather than discarding the document and its
// page. The "id" fill runs here, AHEAD of the "_id" gap-fill below, which is
// what preserves the legacy-wins precedence.
//
// THEN it maps the v1 flat envelope onto the legacy-shaped typed fields. The
// legacy keys ("id", "updatedAt", "values") never appear on the live wire — the
// envelope emits "_id" / "_updatedAt" and flattens content to the top level
// (verified against /v1/data/query) — so the plain typed decode left ID empty,
// UpdatedAt zero and Values nil, latently breaking every consumer
// (saveDocument's patch target, Get-by-id, the editor's field values, timeAgo
// subtitles). Each gap-fill is guarded so a legacy envelope that DOES carry the
// old keys still wins.
func (d *Doc) normalizeEnvelope() {
	// ── the wire fields, coerced instead of typed ────────────────────────────
	// Order matters for ID ONLY: this fill must precede the "_id" gap-fill
	// below, so a legacy top-level "id" still wins over the envelope's "_id"
	// exactly as the typed decode made it win.
	if v, ok := scalarString(d.Extra["id"]); ok {
		d.ID = v
	}
	if v, ok := scalarString(d.Extra["status"]); ok {
		d.Status = v
	}
	if v, ok := scalarString(d.Extra["category"]); ok {
		d.Category = v
	}
	if v, ok := scalarString(d.Extra["author"]); ok {
		d.Author = v
	}
	if t, ok := rfc3339Time(d.Extra["updatedAt"]); ok {
		d.UpdatedAt = t
	}
	// A "values" that is not a flat string map (a reference object, an expanded
	// document, a numeric map) leaves Values empty and falls through to the
	// Extra-derived synthesis below — the document survives either way.
	var wireValues map[string]string
	if json.Unmarshal(d.Extra["values"], &wireValues) == nil {
		d.Values = wireValues
	}
	if v, ok := scalarString(d.Extra["body_html"]); ok {
		d.BodyHTML = v
	}

	// ── the v1 envelope gap-fills ────────────────────────────────────────────
	if d.ID == "" {
		var id string
		if json.Unmarshal(d.Extra["_id"], &id) == nil {
			d.ID = id
		}
	}
	if d.UpdatedAt.IsZero() {
		if t, ok := rfc3339Time(d.Extra["_updatedAt"]); ok {
			d.UpdatedAt = t
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

// rfc3339Time coerces a raw JSON value to a timestamp exactly the way
// encoding/json's time.Time decode does — an RFC 3339 string and nothing else
// — but REPORTS failure instead of returning an error. That difference is the
// whole point: a "updatedAt" that is an object, an array, or a string the
// server did not format as RFC 3339 costs the field, not the document.
func rfc3339Time(raw json.RawMessage) (time.Time, bool) {
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
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

// ClaimInfo is the flattened content.claim object read back RAW — unlike
// ClaimEpoch (which only answers "is there a currently-fenceable claim"), this
// exposes worker/released_at/expired_at even on a claim object a caller would
// otherwise call "no live claim". It exists so a refusal like `bp task claim`'s
// `not_ready` can be diagnosed honestly: the claim predicate is server-side and
// this struct does not re-implement it, but it lets a caller tell "no claim
// object at all" apart from "a claim object whose worker field is still set to
// someone else" — which a bare bool collapses (task-eb2b6170e19f1611: `bp task
// stage` is a third writer that can move lifecycle_status while leaving
// claim.worker in place, so a RELEASED claim can still name a stale holder).
type ClaimInfo struct {
	Present    bool // false when content.claim is absent or JSON null
	Worker     string
	Epoch      int
	ReleasedAt string
	ExpiredAt  string
}

// ClaimInfo decodes this document's claim object. Absent, null, or
// unparseable all report Present:false; a present-but-empty worker field
// decodes to Worker:"" (a genuinely vacant claim), which callers must tell
// apart from Present:false (no claim object was ever written).
func (d Doc) ClaimInfo() ClaimInfo {
	raw, ok := d.Extra["claim"]
	if !ok {
		return ClaimInfo{}
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return ClaimInfo{}
	}
	var c struct {
		Worker     *string `json:"worker"`
		Epoch      int     `json:"epoch"`
		ReleasedAt string  `json:"released_at"`
		ExpiredAt  string  `json:"expired_at"`
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return ClaimInfo{}
	}
	info := ClaimInfo{Present: true, Epoch: c.Epoch, ReleasedAt: c.ReleasedAt, ExpiredAt: c.ExpiredAt}
	if c.Worker != nil {
		info.Worker = *c.Worker
	}
	return info
}

// PaperBlocks returns the raw JSON for this document's portable-doc block tree,
// preferring the top-level "blocks" the live API emits and falling back through
// a nested "content":{"blocks":[…]} envelope and then a "body":{"blocks":[…]}
// envelope (the two alternate paper shapes on guerrilla). A present canonical
// empty array is authoritative and is returned as `[]`; it does not fall
// through to stale legacy content. It returns nil when
// the document carries no block tree (every non-paper doc, and body_html-only
// papers — see Doc.BodyHTML for the last-resort render source), so callers can
// branch on "is this a paper with renderable blocks?" off a single nil check.
func (d Doc) PaperBlocks() json.RawMessage {
	// Presence, not length, defines authority: `blocks: []` intentionally means
	// an empty Paper and must not resurrect a stale body/body_html fallback.
	if blocks := blocksFromEnvelope(d.Blocks); blocks != nil {
		return blocks
	}
	if blocks := blocksFromEnvelope(d.Content); blocks != nil {
		return blocks
	}
	// Some papers project their block tree under "body" ({"blocks":[…]}) rather
	// than top-level "blocks" — e.g. enterprise-ready-auth-wave-2026-07-11, whose
	// 58 blocks live at body.blocks. Mirror the content-envelope fallback so those
	// papers render instead of reporting "no renderable blocks".
	if blocks := blocksFromEnvelope(d.Body); blocks != nil {
		return blocks
	}
	return nil
}

// blocksFromEnvelope pulls a block tree out of a RawMessage, accepting either a
// bare block array ([…]) or the object envelope form ({"blocks":[…]}). It
// returns nil only when the value is absent or is not one of those shapes.
func blocksFromEnvelope(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	// A bare block array (top-level "blocks", or a content/body value that is
	// itself the array).
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err == nil {
		return raw
	}
	// The object envelope {"blocks":[…]}.
	var env struct {
		Blocks json.RawMessage `json:"blocks"`
	}
	if err := json.Unmarshal(raw, &env); err == nil && len(env.Blocks) > 0 {
		var inner []json.RawMessage
		if json.Unmarshal(env.Blocks, &inner) == nil {
			return env.Blocks
		}
	}
	return nil
}
