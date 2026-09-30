package cli

import (
	"encoding/json"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// schema_readonly_field_note.go — a Sanity-shaped list or object field applies
// cleanly and then cannot be edited in Studio.
//
// Found on the stranger walk (2026-09-30): a post schema declaring
// `{"name":"tags","type":"array","of":[{"type":"string"}]}` — Sanity's
// spelling — applied with exit 0, and Studio then rendered TAGS as a dashed
// JSON box, "read-only — managed via API". `array` and `object` are v1
// structured types Studio deliberately never edits (FieldInputs, the
// "array"/"object" clause: a text input would round-trip the value as a
// string); the editable spellings are `arrayOf` and `composite`. Nothing on
// the way in said so.
//
// This adds ONE stderr line per such field after a 2xx `schema apply`, naming
// the field and the editable spelling. Never a refusal, never a changed exit
// code; `-o json` stdout is untouched. Read from the stored schema the server
// echoes, so it names what was actually saved.
func emitSchemaReadonlyFieldNote(out *writer, cmd manifest.Command, status int, respBody []byte) {
	if cmd.ID != "schema.apply" || status < 200 || status >= 300 {
		return
	}
	var body struct {
		Fields []map[string]any `json:"fields"`
		Schema *struct {
			Fields []map[string]any `json:"fields"`
		} `json:"schema"`
	}
	if json.Unmarshal(unwrapResult(respBody), &body) != nil {
		return
	}
	fields := body.Fields
	if len(fields) == 0 && body.Schema != nil {
		fields = body.Schema.Fields
	}
	for _, f := range fields {
		name, _ := f["name"].(string)
		switch f["type"] {
		case "array":
			out.errf("bp: field %q is type \"array\", which Studio shows read-only (API-managed). For a list editors can edit in Studio, declare it as %s.", name, arrayOfSpelling(f["of"]))
		case "object":
			out.errf("bp: field %q is type \"object\", which Studio shows read-only (API-managed). For a group of fields editors can edit in Studio, declare it as {\"type\":\"composite\",\"fields\":[…]}.", name)
		}
	}
}

// arrayOfSpelling renders the editable `arrayOf` declaration for an `array`
// field's `of`: Sanity writes a LIST of member types, `arrayOf` takes ONE
// member type as an object. A single-member list converts exactly; anything
// else gets the shape with a placeholder.
func arrayOfSpelling(of any) string {
	if list, ok := of.([]any); ok && len(list) == 1 {
		if member, ok := list[0].(map[string]any); ok {
			if t, ok := member["type"].(string); ok && t != "" {
				return `{"type":"arrayOf","of":{"type":"` + t + `"}}`
			}
		}
	}
	return `{"type":"arrayOf","of":{"type":"<member type>"}}`
}
