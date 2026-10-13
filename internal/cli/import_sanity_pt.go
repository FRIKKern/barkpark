package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Sanity Portable Text → PortableDoc at import (task-5412419a2e931805).
//
// A Sanity body is a Portable Text array: `_type: "block"` items with
// `children` spans and `markDefs`, plus custom object blocks. A Barkpark
// richText field that declares the block editor (`"editor": "blocks"`) holds
// PortableDoc instead: `{"blocks": [{"id", "type", …}]}`. `bp import` converts
// the one into the other for exactly those fields; a plain richText field keeps
// Portable Text, which is what it stores (owner ruling #44).
//
// The mapping is FieldVocabulary's: normal → paragraph, h1–h6 → heading,
// blockquote → pullquote, bullet/number list items → one list block per run,
// decorators → nested inline marks, a link markDef → an inline link. A block's
// Sanity `_key` becomes its `id`. A custom object block the field declares in
// `blocks.of` (`{"name": "callout", …}`) is kept as `{id, type, …fields}`. A
// body holding anything else (an undeclared object, a Sanity image, whose
// shape is not PortableDoc's) is left as it was and reported, never half
// converted.

// sanityBlocksField is one block-editor richText field of the target schema.
type sanityBlocksField struct {
	// objects names the custom object blocks the field declares in blocks.of.
	objects map[string]bool
}

// sanityBlocksFields maps type → field name → field for every richText field
// that declares the block editor.
type sanityBlocksFields map[string]map[string]sanityBlocksField

// sanityConversion tallies what the conversion did, for the import report.
type sanityConversion struct {
	fields    int      // bodies converted to PortableDoc
	kept      []string // "<doc id>.<field>: <reason>" for bodies left as Portable Text
	flattened int      // list items below level 1, put in their list's top level
	dropped   int      // marks and styles PortableDoc has no node for (their text is kept)
}

// sanityFetchBlocksFields reads the target's schemas (GET /v1/schemas/:dataset)
// and returns its block-editor richText fields.
func sanityFetchBlocksFields(ctx manifest.Context, dataset string) (sanityBlocksFields, error) {
	u := ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset))
	status, body, err := doRequest("GET", u, ctxAuthHeaders(ctx), nil)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("%s", classifyError(status, body).errorMessage())
	}
	var env struct {
		Schemas []struct {
			Name   string `json:"name"`
			Fields []struct {
				Name   string `json:"name"`
				Type   string `json:"type"`
				Editor string `json:"editor"`
				Blocks struct {
					Of []json.RawMessage `json:"of"`
				} `json:"blocks"`
			} `json:"fields"`
		} `json:"schemas"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("unreadable schemas: %v", err)
	}
	out := sanityBlocksFields{}
	for _, s := range env.Schemas {
		for _, f := range s.Fields {
			if f.Type != "richText" || f.Editor != "blocks" {
				continue
			}
			objects := map[string]bool{}
			for _, raw := range f.Blocks.Of {
				var obj struct {
					Name string `json:"name"`
				}
				// A bare string names a built-in (image, divider, …), whose
				// PortableDoc shape a Sanity object does not have.
				if json.Unmarshal(raw, &obj) == nil && obj.Name != "" {
					objects[obj.Name] = true
				}
			}
			if out[s.Name] == nil {
				out[s.Name] = map[string]sanityBlocksField{}
			}
			out[s.Name][f.Name] = sanityBlocksField{objects: objects}
		}
	}
	return out, nil
}

// sanityConvertDoc converts every Portable Text value of doc's block-editor
// fields in place and reports whether it changed anything.
func sanityConvertDoc(doc map[string]any, fields sanityBlocksFields, conv *sanityConversion) bool {
	typ, _ := doc["_type"].(string)
	changed := false
	names := make([]string, 0, len(fields[typ]))
	for name := range fields[typ] {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		items, ok := doc[name].([]any)
		if !ok || !sanityIsPortableText(items) {
			continue
		}
		blocks, reason := sanityToPortableDoc(items, fields[typ][name], conv)
		if reason != "" {
			id, _ := doc["_id"].(string)
			conv.kept = append(conv.kept, fmt.Sprintf("%s.%s: %s", id, name, reason))
			continue
		}
		doc[name] = map[string]any{"blocks": blocks}
		conv.fields++
		changed = true
	}
	return changed
}

// sanityIsPortableText: a list holding at least one `_type: "block"` item with
// `children`, the way the Studio recognises one.
func sanityIsPortableText(items []any) bool {
	for _, it := range items {
		if m, ok := it.(map[string]any); ok && m["_type"] == "block" {
			if _, ok := m["children"].([]any); ok {
				return true
			}
		}
	}
	return false
}

var sanityHeadingLevels = map[string]int{"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}

// sanityToPortableDoc converts one Portable Text array. A non-empty reason
// means it could not, and nothing of it is used.
func sanityToPortableDoc(items []any, field sanityBlocksField, conv *sanityConversion) ([]any, string) {
	var blocks []any
	var list map[string]any // the list block a run of list items is filling
	listKind := ""
	flattened, dropped := 0, 0
	for i, it := range items {
		m, ok := it.(map[string]any)
		if !ok {
			return nil, fmt.Sprintf("item %d is not an object", i)
		}
		id, _ := m["_key"].(string)
		if id == "" {
			id = fmt.Sprintf("b%d", i)
		}
		typ, _ := m["_type"].(string)
		if typ != "block" {
			if !field.objects[typ] {
				return nil, fmt.Sprintf("block type %q is not declared by the field", typ)
			}
			list = nil
			obj := map[string]any{"id": id, "type": typ}
			for k, v := range m {
				if k != "_type" && k != "_key" {
					obj[k] = v
				}
			}
			blocks = append(blocks, obj)
			continue
		}
		content, d := sanityInline(m)
		dropped += d

		if kind, _ := m["listItem"].(string); kind != "" {
			level := 1
			if n, ok := m["level"].(json.Number); ok {
				if l, err := n.Int64(); err == nil {
					level = int(l)
				}
			}
			if kind != "bullet" && kind != "number" {
				kind = "bullet"
				dropped++
			}
			// A deeper item stays in the list it is nested in; PortableDoc's
			// list items are flat.
			if list != nil && (level > 1 || kind == listKind) {
				if level > 1 {
					flattened++
				}
				list["items"] = append(list["items"].([]any), content)
				continue
			}
			if level > 1 {
				flattened++
			}
			list = map[string]any{"id": id, "type": "list", "ordered": kind == "number", "items": []any{content}}
			listKind = kind
			blocks = append(blocks, list)
			continue
		}
		list = nil

		style, _ := m["style"].(string)
		switch {
		case sanityHeadingLevels[style] > 0:
			blocks = append(blocks, map[string]any{"id": id, "type": "heading", "level": sanityHeadingLevels[style], "text": sanityPlainText(m)})
		case style == "blockquote":
			blocks = append(blocks, map[string]any{"id": id, "type": "pullquote", "content": content})
		default:
			if style != "" && style != "normal" {
				dropped++
			}
			blocks = append(blocks, map[string]any{"id": id, "type": "paragraph", "content": content})
		}
	}
	conv.flattened += flattened
	conv.dropped += dropped
	if blocks == nil {
		blocks = []any{}
	}
	return blocks, ""
}

// sanityDecorators maps Sanity's decorators onto PortableDoc's inline marks.
var sanityDecorators = map[string]string{
	"strong": "strong", "em": "em", "underline": "underline",
	"strike-through": "strikethrough", "code": "code",
}

// sanityInline turns a block's children into PortableDoc inline nodes and
// counts the marks it had no node for (their text is kept).
func sanityInline(block map[string]any) ([]any, int) {
	defs := map[string]map[string]any{}
	if mds, ok := block["markDefs"].([]any); ok {
		for _, d := range mds {
			if md, ok := d.(map[string]any); ok {
				if k, _ := md["_key"].(string); k != "" {
					defs[k] = md
				}
			}
		}
	}
	children, _ := block["children"].([]any)
	out := []any{}
	dropped := 0
	for _, c := range children {
		cm, ok := c.(map[string]any)
		if !ok {
			continue
		}
		if t, _ := cm["_type"].(string); t != "span" && t != "" {
			// An inline object: its `_type` becomes `type` (FieldVocabulary).
			obj := map[string]any{"type": t}
			for k, v := range cm {
				if k != "_type" {
					obj[k] = v
				}
			}
			out = append(out, obj)
			continue
		}
		text, _ := cm["text"].(string)
		node := map[string]any{"type": "text", "value": text}
		marks, _ := cm["marks"].([]any)
		var link map[string]any
		for _, mk := range marks {
			name, _ := mk.(string)
			if dec, ok := sanityDecorators[name]; ok {
				if dec == "code" {
					node = map[string]any{"type": "code", "value": text}
				} else {
					node = map[string]any{"type": dec, "children": []any{node}}
				}
				continue
			}
			if def, ok := defs[name]; ok && def["_type"] == "link" {
				if href, _ := def["href"].(string); href != "" {
					link = map[string]any{"type": "link", "href": href}
					continue
				}
			}
			dropped++
		}
		if link != nil {
			link["children"] = []any{node}
			node = link
		}
		out = append(out, node)
	}
	return out, dropped
}

// sanityPlainText is a block's text, spans joined (a heading carries no marks).
func sanityPlainText(block map[string]any) string {
	var b strings.Builder
	children, _ := block["children"].([]any)
	for _, c := range children {
		if cm, ok := c.(map[string]any); ok {
			if t, ok := cm["text"].(string); ok {
				b.WriteString(t)
			}
		}
	}
	return b.String()
}
