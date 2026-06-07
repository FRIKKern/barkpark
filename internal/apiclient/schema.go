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

// Schema defines a document type.
type Schema struct {
	Name       string
	Title      string
	Icon       string
	Visibility string // "public" or "private"
	Fields     []Field
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
			Fields     []struct {
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
			Name:       as.Name,
			Title:      as.Title,
			Icon:       as.Icon,
			Visibility: as.Visibility,
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
