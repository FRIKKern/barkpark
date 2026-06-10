package main

import "github.com/FRIKKern/barkpark/internal/apiclient"

// The schema model types now live in the framework-free apiclient package.
// These aliases keep the existing TUI code (tui.go, structure.go, selector.go)
// compiling unchanged while the HTTP + parsing logic lives in apiclient.
type (
	FieldType = apiclient.FieldType
	Field     = apiclient.Field
	Schema    = apiclient.Schema
)

const (
	FieldString    = apiclient.FieldString
	FieldSlug      = apiclient.FieldSlug
	FieldText      = apiclient.FieldText
	FieldRichText  = apiclient.FieldRichText
	FieldImage     = apiclient.FieldImage
	FieldSelect    = apiclient.FieldSelect
	FieldBoolean   = apiclient.FieldBoolean
	FieldDatetime  = apiclient.FieldDatetime
	FieldColor     = apiclient.FieldColor
	FieldReference = apiclient.FieldReference
	FieldArray     = apiclient.FieldArray
)

// schemas is the TUI's caller-owned schema slice, populated at startup and on
// every scope switch. The apiclient no longer holds global mutable schema state;
// the loaded slice lives here and findSchema reads it.
var schemas []Schema

// findSchema looks up a schema by its machine name in the caller-owned slice.
func findSchema(name string) *Schema {
	for i := range schemas {
		if schemas[i].Name == name {
			return &schemas[i]
		}
	}
	return nil
}

// schemaListPreview returns the named schema's list_preview declaration, or
// the zero ListPreview (no badge, no meta) when the schema is unknown or
// declares none — doc-list rows then render exactly as before.
func schemaListPreview(typeName string) apiclient.ListPreview {
	if s := findSchema(typeName); s != nil {
		return s.ListPreview
	}
	return apiclient.ListPreview{}
}

// previewValue resolves one list_preview spec against a document: the named
// content field's scalar value with the spec's prefix, or "" when the spec is
// absent or the value is missing/non-scalar. Mirrors the Studio PaneBuilder's
// format_preview degradation — a misdeclared field means "no badge", never an
// error row.
func previewValue(doc Doc, spec *apiclient.PreviewSpec) string {
	if spec == nil || spec.Field == "" {
		return ""
	}
	v := doc.ContentString(spec.Field)
	if v == "" {
		return ""
	}
	return spec.Prefix + v
}
