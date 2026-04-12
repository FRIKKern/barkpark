package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// FieldType enumerates the supported form field types.
type FieldType int

const (
	FieldString    FieldType = iota
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

// schemas is populated at startup by loadSchemas().
var schemas []Schema

// findSchema looks up a schema by its machine name.
func findSchema(name string) *Schema {
	for i := range schemas {
		if schemas[i].Name == name {
			return &schemas[i]
		}
	}
	return nil
}

// loadSchemas fetches schema definitions from the Phoenix API.
func loadSchemas(baseURL, token string) error {
	client := &http.Client{Timeout: 5 * time.Second}

	req, err := http.NewRequest("GET", baseURL+"/v1/schemas/production", nil)
	if err != nil {
		return fmt.Errorf("fetch schemas: %w", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch schemas: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch schemas: status %d", resp.StatusCode)
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
		return fmt.Errorf("parse schemas: %w", err)
	}

	schemas = make([]Schema, 0, len(result.Schemas))
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
