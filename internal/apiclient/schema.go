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
	// FieldNumber is a numeric scalar — edited as text in the TUI but
	// validated on commit and saved as a real JSON number (several schema
	// validators, e.g. task.priority's integer 0..4, hard-reject strings).
	FieldNumber
	// FieldRaw marks non-scalar / v2 plugin field types (object, composite,
	// arrayOf, codelist, localizedText): READ-ONLY in the TUI (D12). Before
	// this, parseFieldType's default mapped them to FieldString — an EDITABLE
	// text box over structured data, where one careless enter+save would
	// overwrite a task's claim object with a typed scalar.
	FieldRaw
)

// Field defines a single form field inside a document schema.
type Field struct {
	Name    string
	Title   string
	Type    FieldType
	Options []string
	RefType string
	Rows    int
	// Required mirrors the schema's validation.required — the editor
	// renders Sanity's asterisk marker and a "(required)" hint when empty.
	// Enforcement stays server-side (drafts save with warnings; publish
	// blocks); the marker is the affordance.
	Required bool
	// Pattern mirrors validation.pattern (a regex source) — the editor
	// validates on commit so a violating value never even reaches the
	// server's warning pass.
	Pattern string
	// Group mirrors the schema's field "group" — the editor renders a dim
	// section header when consecutive fields cross a group boundary
	// (Studio renders the same groups as tab bars).
	Group string
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
				Group   string   `json:"group,omitempty"`
				// Validation values are mixed types ({"required": bool},
				// {"pattern": string} both ship in live schemas) — decode
				// raw and pick fields tolerantly so an unknown shape can
				// never fail the whole schema fetch.
				Validation map[string]json.RawMessage `json:"validation,omitempty"`
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
				Name:     af.Name,
				Title:    af.Title,
				Type:     parseFieldType(af.Type),
				Options:  af.Options,
				RefType:  af.RefType,
				Required: rawBool(af.Validation["required"]),
				Pattern:  rawString(af.Validation["pattern"]),
				Group:    af.Group,
				Rows:     af.Rows,
			})
		}
		schemas = append(schemas, s)
	}

	return schemas, nil
}

// parseListPreview shapes a schema's raw listPreview map into ListPreview.
// A nil/empty map (no declaration) yields the zero value.
// DeskNode is one node of the server's canonical desk structure
// (GET /v1/structure/:dataset — what Studio renders, host groups + plugin
// desk items). The TUI converts this into its own pane tree; clients on old
// servers fall back to building a desk from raw schemas.
type DeskNode struct {
	ID       string `json:"id,omitempty"`
	Title    string `json:"title,omitempty"`
	Icon     string `json:"icon,omitempty"`
	Type     string `json:"type"`
	TypeName string `json:"typeName,omitempty"`
	// Filter arrives as EITHER a "field=value" string or a filter-map
	// object ({"status":"draft"}) — the server's tree carries both shapes.
	// FilterString() normalizes; raw keeps the decode tolerant.
	Filter json.RawMessage `json:"filter,omitempty"`
	Items  []DeskNode      `json:"items,omitempty"`
	Child  *DeskNode       `json:"child,omitempty"`
}

// FilterString renders the node's filter as the TUI's "field=value" form.
// A single-pair map normalizes to "key=value"; a multi-pair map (or any
// shape the simple filter language can't express) returns "" — an
// UNfiltered list is honest, a wrongly-filtered one is not.
func (n DeskNode) FilterString() string {
	if len(n.Filter) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(n.Filter, &s) == nil {
		return s
	}
	var m map[string]any
	if json.Unmarshal(n.Filter, &m) == nil && len(m) == 1 {
		for k, v := range m {
			if val, ok := scalarString(jsonRaw(v)); ok {
				return k + "=" + val
			}
		}
	}
	return ""
}

// jsonRaw re-encodes a decoded scalar so scalarString can normalize it.
func jsonRaw(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// LoadStructure fetches the canonical desk tree for the client's scope.
// A non-200 (old server without the endpoint) returns an error — callers
// fall back to client-side desk building.
func (c *Client) LoadStructure() (*DeskNode, error) {
	url := c.scopedURL("/v1/structure/" + c.Dataset)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("structure endpoint: status %d", resp.StatusCode)
	}

	var out struct {
		Structure DeskNode `json:"structure"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("parse structure: %w", err)
	}
	return &out.Structure, nil
}

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

// rawBool / rawString decode a tolerant scalar from a raw validation value —
// absent, null, or mistyped values yield the zero value, never an error.
func rawBool(raw json.RawMessage) bool {
	var b bool
	_ = json.Unmarshal(raw, &b)
	return b
}

func rawString(raw json.RawMessage) string {
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
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
	case "number":
		return FieldNumber
	case "object", "composite", "arrayOf", "codelist", "localizedText":
		// The v2 / non-scalar types: read-only render, never an editable box.
		return FieldRaw
	default:
		// Unknown-but-scalar types (e.g. a future "number" alias) keep the
		// permissive string-box fallback.
		return FieldString
	}
}
