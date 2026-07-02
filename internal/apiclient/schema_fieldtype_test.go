package apiclient

import "testing"

// parseFieldType is the string↔FieldType contract the TUI editor + codegen rely
// on: scalar types get an editable box, the v2/non-scalar group renders
// read-only (FieldRaw), and an unknown type falls back to a permissive string
// box. A dropped/renamed case would silently mis-render a field, so pin it.
func TestParseFieldType(t *testing.T) {
	scalar := map[string]FieldType{
		"string":    FieldString,
		"slug":      FieldSlug,
		"text":      FieldText,
		"richText":  FieldRichText,
		"image":     FieldImage,
		"select":    FieldSelect,
		"boolean":   FieldBoolean,
		"datetime":  FieldDatetime,
		"color":     FieldColor,
		"reference": FieldReference,
		"array":     FieldArray,
		"number":    FieldNumber,
	}
	for in, want := range scalar {
		if got := parseFieldType(in); got != want {
			t.Errorf("parseFieldType(%q) = %v, want %v", in, got, want)
		}
	}

	// The v2 / non-scalar types all collapse to the read-only raw render.
	for _, in := range []string{"object", "composite", "arrayOf", "codelist", "localizedText"} {
		if got := parseFieldType(in); got != FieldRaw {
			t.Errorf("parseFieldType(%q) = %v, want FieldRaw", in, got)
		}
	}

	// Unknown / empty → permissive string-box fallback.
	for _, in := range []string{"", "somethingNew", "STRING"} {
		if got := parseFieldType(in); got != FieldString {
			t.Errorf("parseFieldType(%q) = %v, want FieldString (fallback)", in, got)
		}
	}
}
