package apiclient

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// FieldType enumerates the supported form field types.
type FieldType int

const (
	FieldString FieldType = iota
	FieldSlug
	FieldText
	FieldRichText
	FieldImage
	FieldSelect
	FieldBoolean
	FieldDatetime
	FieldColor
	FieldReference
	FieldArray
)

// Field defines a single form field inside a document schema.
type Field struct {
	Name    string
	Title   string
	Type    FieldType
	Options []string
	RefType string
	Rows    int
}

// PreviewSpec names one content field a document-list row surfaces, with an
// optional literal prefix (e.g. {Field: "priority", Prefix: "P"} renders "P1").
type PreviewSpec struct {
	Field  string
	Prefix string
}

// ListPreview is a schema's optional list-row preview declaration — which
// content field renders as the row badge and which as the dimmed meta suffix.
// The zero value (both nil) means no declaration: rows render exactly as
// before. Mirrors the Studio's `list_preview` schema column; the SDK schema
// envelope carries it as `listPreview`.
type ListPreview struct {
	Badge *PreviewSpec
	Meta  *PreviewSpec
}

// Schema defines a document type.
type Schema struct {
	Name        string
	Title       string
	Icon        string
	Visibility  string // "public" or "private"
	Fields      []Field
	ListPreview ListPreview
}

// LoadSchemas fetches schema definitions for the Client's current scope. It
// returns the parsed schemas; the caller owns the resulting slice (no
// package-global state).
//
// The HTTP timeout follows the Client's configured timeout — callers that need a
// longer budget set Config.Timeout before New.
func (c *Client) LoadSchemas() ([]Schema, error) {
	return c.LoadSchemasFor(c.Workspace, c.Project, c.Dataset)
}

// LoadSchemasFor fetches schema definitions for an explicit workspace/project/
// dataset scope without mutating the Client's own scope. The scope selector uses
// this to probe a prospective scope before committing to it — exactly the
// behaviour the legacy free function loadSchemas(baseURL, token, ws, pr, ds)
// provided.
func (c *Client) LoadSchemasFor(workspace, project, dataset string) ([]Schema, error) {
	schemasURL := fmt.Sprintf("%s/w/%s/p/%s/v1/schemas/%s", c.baseURL, workspace, project, dataset)
	req, err := http.NewRequest("GET", schemasURL, nil)
	if err != nil {
		return nil, fmt.Errorf("fetch schemas: %w", err)
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch schemas: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch schemas: status %d", resp.StatusCode)
	}

	var result struct {
		Schemas []struct {
			Name       string `json:"name"`
			Title      string `json:"title"`
			Icon       string `json:"icon"`
			Visibility string `json:"visibility"`
			// listPreview values are either a field-name string or
			// {"field": f, "prefix": p} — kept raw here, shaped by
			// parseListPreview below.
			ListPreview map[string]json.RawMessage `json:"listPreview"`
			Fields      []struct {
				Name    string   `json:"name"`
				Title   string   `json:"title"`
				Type    string   `json:"type"`
				Options []string `json:"options,omitempty"`
				RefType string   `json:"refType,omitempty"`
				Rows    int      `json:"rows,omitempty"`
			} `json:"fields"`
		} `json:"schemas"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("parse schemas: %w", err)
	}

	schemas := make([]Schema, 0, len(result.Schemas))
	for _, as := range result.Schemas {
		s := Schema{
			Name:        as.Name,
			Title:       as.Title,
			Icon:        as.Icon,
			Visibility:  as.Visibility,
			ListPreview: parseListPreview(as.ListPreview),
		}
		for _, af := range as.Fields {
			s.Fields = append(s.Fields, Field{
				Name:    af.Name,
				Title:   af.Title,
				Type:    parseFieldType(af.Type),
				Options: af.Options,
				RefType: af.RefType,
				Rows:    af.Rows,
			})
		}
		schemas = append(schemas, s)
	}

	return schemas, nil
}

// parseListPreview shapes a schema's raw listPreview map into ListPreview.
// A nil/empty map (no declaration) yields the zero value.
func parseListPreview(raw map[string]json.RawMessage) ListPreview {
	return ListPreview{
		Badge: parsePreviewSpec(raw["badge"]),
		Meta:  parsePreviewSpec(raw["meta"]),
	}
}

// parsePreviewSpec accepts the two declared spec shapes — a bare field-name
// string or {"field": f, "prefix": p} — and returns nil for anything else
// (absent, empty, or misdeclared specs degrade to "no preview", never an error;
// mirrors the Studio PaneBuilder's permissive read).
func parsePreviewSpec(raw json.RawMessage) *PreviewSpec {
	if len(raw) == 0 {
		return nil
	}
	var field string
	if err := json.Unmarshal(raw, &field); err == nil {
		if field == "" {
			return nil
		}
		return &PreviewSpec{Field: field}
	}
	var spec struct {
		Field  string `json:"field"`
		Prefix string `json:"prefix"`
	}
	if err := json.Unmarshal(raw, &spec); err == nil && spec.Field != "" {
		return &PreviewSpec{Field: spec.Field, Prefix: spec.Prefix}
	}
	return nil
}

func parseFieldType(s string) FieldType {
	switch s {
	case "string":
		return FieldString
	case "slug":
		return FieldSlug
	case "text":
		return FieldText
	case "richText":
		return FieldRichText
	case "image":
		return FieldImage
	case "select":
		return FieldSelect
	case "boolean":
		return FieldBoolean
	case "datetime":
		return FieldDatetime
	case "color":
		return FieldColor
	case "reference":
		return FieldReference
	case "array":
		return FieldArray
	default:
		return FieldString
	}
}
