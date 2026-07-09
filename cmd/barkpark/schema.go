package main

import (
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

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
	FieldNumber    = apiclient.FieldNumber
	FieldRaw       = apiclient.FieldRaw
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

// rowMeta resolves the dimmed meta suffix for a doc-list row (Preview Contract
// D17). list_preview WINS: when the schema declares a meta spec — the FIELDFUL
// task/ticket path — its scalar value renders unchanged, so those rows never
// regress. Only when NO list_preview meta is declared does the row fall back to
// the write-time preview manifest's OG description (the BLOCK docs — paper /
// sheet / form — which carry no list_preview spec but DO gain a stamped
// content["preview"], hoisted onto the envelope top level as Extra["preview"]).
// Spec-less AND manifest-less docs → "" (the pre-manifest render, unchanged).
func rowMeta(doc Doc, preview apiclient.ListPreview) string {
	if preview.Meta != nil {
		return previewValue(doc, preview.Meta)
	}
	return manifestDescription(doc)
}

// manifestDescription pulls the OG description out of the write-time preview
// manifest. Unlike the scalar list_preview fields, the manifest is a JSON
// OBJECT the envelope hoists to Extra["preview"] (Barkpark.Preview.project).
// "" when absent, unparseable, or blank — the row then renders without a meta
// suffix, byte-identical to a manifest-less doc.
func manifestDescription(doc Doc) string {
	raw, ok := doc.Extra["preview"]
	if !ok {
		return ""
	}
	var m struct {
		Description string `json:"description"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return ""
	}
	return strings.TrimSpace(m.Description)
}
