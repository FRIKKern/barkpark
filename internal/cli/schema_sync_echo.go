package cli

// schema_sync_echo.go is how `bp schema pull|diff|push` reads a dataset's
// schemas, and the two rewrites the server makes to a field list.
//
// The default schema list serves fields for SDK readers: every field gains
// `required?`, and each member of an array field's `of` and of a reference
// field's `to` is cut down to type, to and name (serialize_field in
// api/lib/barkpark/content/schema.ex). A member's own nested fields are not
// served, so a file pulled from that list and pushed back would replace the
// stored members with the cut-down ones.
//
// fetchSyncSchemas therefore asks for `?definition=stored`, which serves each
// field list as stored (api/lib/barkpark/content/schema_stored_fields.ex). A
// server that has that read says `definition: "stored"` in the envelope. One
// that does not ignores the query and sends the served form; the verbs then
// compare in that form, and push refuses a schema it could damage
// (schemaCutMembers).

import (
	"encoding/json"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// fetchSyncSchemas reads every schema of the dataset. stored reports whether
// the field lists are as stored, or in the served form.
func fetchSyncSchemas(ctx manifest.Context, dataset string) (schemas []json.RawMessage, stored bool, err error) {
	schemas, definition, err := fetchSchemaList(ctx, dataset, "?definition=stored")
	return schemas, definition == "stored", err
}

// schemaStoredField is a stored field as compared: `required?` is dropped,
// because the server works it out from `validation` and never reads it.
func schemaStoredField(v any) any {
	f, ok := v.(map[string]any)
	if !ok {
		return v
	}
	out := map[string]any{}
	for k, val := range f {
		if k != "required?" {
			out[k] = val
		}
	}
	return out
}

// schemaScalarMembers are the member types that have no fields of their own.
var schemaScalarMembers = map[string]bool{
	"string": true, "text": true, "number": true, "boolean": true, "date": true, "datetime": true,
	"slug": true, "url": true, "email": true, "color": true, "image": true, "file": true, "reference": true,
}

// schemaCutMembers names the array fields of a changed schema that a push
// could damage when the server sent the served form. A field is named when
// the server lists a member for it that can have fields of its own (a type
// outside schemaScalarMembers) and the file's `of` for that field holds
// nothing beyond type, to and name. The stored member may then have nested
// fields that neither side can see, and the push would replace it. A file
// that writes the members out in full is not named.
func schemaCutMembers(local, server map[string]any) []string {
	localOf := map[string]any{}
	list, _ := local["fields"].([]any)
	for _, f := range list {
		if m, ok := f.(map[string]any); ok {
			if name, _ := m["name"].(string); name != "" {
				localOf[name] = m["of"]
			}
		}
	}
	var out []string
	list, _ = server["fields"].([]any)
	for _, f := range list {
		m, _ := f.(map[string]any)
		name, _ := m["name"].(string)
		members, _ := m["of"].([]any)
		lof, inFile := localOf[name]
		if m["type"] != "array" || !inFile {
			continue // a field the file drops is removed on purpose
		}
		risky := false
		for _, member := range members {
			if spec, ok := member.(map[string]any); ok {
				if t, _ := spec["type"].(string); !schemaScalarMembers[t] {
					risky = true
				}
			}
		}
		if !risky {
			continue
		}
		if l, ok := lof.([]any); ok && schemaCanon(l) != schemaCanon(schemaElementSpecs(l)) {
			continue // the file has the members in full
		}
		out = append(out, name)
	}
	return out
}

// schemaElementSpec is the server's element_spec: a member of an `of` or `to`
// list keeps only type, to and name; a bare string is a type name.
func schemaElementSpec(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for _, k := range []string{"type", "to", "name"} {
			if val, ok := t[k]; ok {
				out[k] = val
			}
		}
		return out
	case string:
		return map[string]any{"type": t}
	}
	return map[string]any{"type": "string"}
}

func schemaElementSpecs(list []any) []any {
	out := make([]any, len(list))
	for i, v := range list {
		out[i] = schemaElementSpec(v)
	}
	return out
}

// schemaCastFields is the rewrite the upsert makes to a field list before it
// stores it (RichTextFormat.normalise_fields): `portableText` is stored as
// richText with that format, and a portableDoc richText field gets the block
// editor. It reaches into nested fields, `of` and the block vocabulary. The
// third rewrite, Sanity's array of blocks, is not mirrored here: a file in
// that shape differs from the server until it is pulled again.
func schemaCastFields(list []any) []any {
	out := make([]any, len(list))
	for i, v := range list {
		out[i] = schemaCastField(v)
	}
	return out
}

func schemaCastField(v any) any {
	f, ok := v.(map[string]any)
	if !ok {
		return v
	}
	out := map[string]any{}
	for k, val := range f {
		out[k] = val
	}
	if out["type"] == "portableText" {
		out["type"], out["format"] = "richText", "portableText"
	}
	if _, has := out["editor"]; !has && out["type"] == "richText" && out["format"] == "portableDoc" {
		out["editor"] = "blocks"
	}
	if fields, ok := out["fields"].([]any); ok {
		out["fields"] = schemaCastFields(fields)
	}
	switch of := out["of"].(type) {
	case []any:
		out["of"] = schemaCastFields(of)
	case map[string]any:
		out["of"] = schemaCastField(of)
	}
	if blocks, ok := out["blocks"].(map[string]any); ok {
		nb := map[string]any{}
		for k, val := range blocks {
			nb[k] = val
		}
		for _, key := range []string{"of", "inline", "annotations"} {
			entries, ok := nb[key].([]any)
			if !ok {
				continue
			}
			ne := make([]any, len(entries))
			for i, e := range entries {
				ne[i] = e
				if m, ok := e.(map[string]any); ok {
					if fields, ok := m["fields"].([]any); ok {
						c := map[string]any{}
						for k, val := range m {
							c[k] = val
						}
						c["fields"] = schemaCastFields(fields)
						ne[i] = c
					}
				}
			}
			nb[key] = ne
		}
		out["blocks"] = nb
	}
	return out
}

// schemaEchoField returns a field as the schema list echoes it, minus
// `required?`. It mirrors serialize_field in schema.ex: an array field gets an
// `of` list and a reference field a `to` list, built from the field's own
// keys. The server derives `required?` from `validation`, which is compared.
func schemaEchoField(v any) any {
	f, ok := v.(map[string]any)
	if !ok {
		return v
	}
	out := map[string]any{}
	for k, val := range f {
		if k != "required?" {
			out[k] = val
		}
	}
	options, _ := f["options"].(map[string]any)
	switch f["type"] {
	case "array":
		if of, ok := f["of"].([]any); ok {
			out["of"] = schemaElementSpecs(of)
		} else if list, ok := options["list"].([]any); ok {
			out["of"] = schemaElementSpecs(list)
		} else {
			out["of"] = []any{map[string]any{"type": "string"}}
		}
	case "reference":
		if to, ok := f["to"].([]any); ok {
			out["to"] = schemaElementSpecs(to)
		} else if refs, ok := options["references"].([]any); ok {
			out["to"] = schemaElementSpecs(refs)
		} else if ref, ok := f["refType"].(string); ok {
			out["to"] = []any{map[string]any{"type": ref}}
		} else {
			out["to"] = []any{}
		}
	}
	return out
}
