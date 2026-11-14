package cli

// schema_sync_plan.go is the comparison behind `bp schema pull|diff|push`
// (schema_sync_cmd.go): it reads a folder of schema files, compares it to the
// schemas the server lists, and builds the plan the three verbs print.
//
// Two definitions are equal when they differ only in what the server adds on
// its own. The comparison drops the keys in schemaSyncNoise, and a key whose
// value is empty (null, false, "", [] or {}) equals a key that is absent, so a
// short hand-written file equals the server's echo of it with every default
// filled in.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// schemaSyncNoise names the top-level keys the server computes or stamps.
// `id` repeats `name`; the rest are hashes, revision counters and timestamps.
var schemaSyncNoise = []string{
	"id", "_id", "schemaHash", "_schemaVersion", "warnings",
	"rev", "_rev", "revision",
	"inserted_at", "updated_at", "created_at",
	"insertedAt", "updatedAt", "createdAt", "_createdAt", "_updatedAt",
}

// schemaChange is one schema that differs, as a field-level summary. The
// direction is what a push would do to the server.
type schemaChange struct {
	Name          string   `json:"name"`
	FieldsAdded   []string `json:"fields_added"`
	FieldsRemoved []string `json:"fields_removed"`
	FieldsChanged []string `json:"fields_changed"`
	Keys          []string `json:"keys"`
}

// schemaPlan is what `bp schema diff` prints and `bp schema push` applies.
type schemaPlan struct {
	Scope     string         `json:"scope"`
	Dir       string         `json:"dir"`
	Added     []string       `json:"added"`     // in the folder only
	Changed   []schemaChange `json:"changed"`   // in both, and they differ
	Removed   []string       `json:"removed"`   // on the server only
	Unchanged int            `json:"unchanged"` // in both, and equal
	// Skipped are server schemas whose name cannot be a file name. No verb
	// writes, compares or deletes them.
	Skipped []string `json:"skipped"`
}

func (p *schemaPlan) differs() bool {
	return len(p.Added)+len(p.Changed)+len(p.Removed) > 0
}

// schemaFileNameOK reports whether a schema name is safe to use as a file
// name inside the folder. A name with a path separator, a NUL, a leading dot
// or ".." could write outside the folder, so it is refused.
func schemaFileNameOK(name string) bool {
	if name == "" || strings.HasPrefix(name, ".") || strings.Contains(name, "..") {
		return false
	}
	return !strings.ContainsAny(name, "/\\\x00")
}

// decodeSchemaJSON parses one definition and keeps numbers as written.
func decodeSchemaJSON(raw []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, fmt.Errorf("more than one JSON value")
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("not a JSON object")
	}
	return obj, nil
}

// prettySchemaJSON renders a definition the way `bp schema pull` writes it:
// two-space indent, keys sorted at every level, one trailing newline.
func prettySchemaJSON(obj map[string]any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(obj); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// readSchemaDir reads every <name>.json directly inside dir. It stops at the
// first file that is not a schema definition and names that file, so a push
// never starts from a folder it could only half read.
func readSchemaDir(dir string) (map[string]json.RawMessage, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := map[string]json.RawMessage{}
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		obj, err := decodeSchemaJSON(raw)
		if err != nil {
			return nil, fmt.Errorf("%s is not a schema definition: %v", path, err)
		}
		stem := strings.TrimSuffix(e.Name(), ".json")
		name, _ := obj["name"].(string)
		switch {
		case name == "":
			return nil, fmt.Errorf("%s has no name", path)
		case name != stem:
			return nil, fmt.Errorf("%s defines schema %q; the file name must be %s.json", path, name, name)
		case !schemaFileNameOK(name):
			return nil, fmt.Errorf("%s: %q cannot be a schema file name", path, name)
		}
		out[name] = raw
	}
	return out, nil
}

// schemaComparable strips what the comparison ignores from a decoded value:
// empty values inside objects, at every level.
func schemaComparable(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, val := range t {
			if c := schemaComparable(val); !schemaEmpty(c) {
				out[k] = c
			}
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, val := range t {
			out[i] = schemaComparable(val)
		}
		return out
	}
	return v
}

func schemaEmpty(v any) bool {
	switch t := v.(type) {
	case nil:
		return true
	case bool:
		return !t
	case string:
		return t == ""
	case []any:
		return len(t) == 0
	case map[string]any:
		return len(t) == 0
	}
	return false
}

// schemaComparableTop is schemaComparable for a whole definition: it also
// drops the server's own keys and the default kind.
func schemaComparableTop(obj map[string]any) map[string]any {
	out, _ := schemaComparable(obj).(map[string]any)
	for _, k := range schemaSyncNoise {
		delete(out, k)
	}
	if out["kind"] == "document" {
		delete(out, "kind")
	}
	return out
}

func schemaCanon(v any) string {
	b, _ := json.Marshal(v) // map keys sort, so equal values give equal bytes
	return string(b)
}

// schemaFieldsByName indexes the `fields` list of a comparable definition.
func schemaFieldsByName(obj map[string]any) map[string]string {
	out := map[string]string{}
	list, _ := obj["fields"].([]any)
	for _, f := range list {
		if m, ok := f.(map[string]any); ok {
			if name, _ := m["name"].(string); name != "" {
				out[name] = schemaCanon(m)
			}
		}
	}
	return out
}

// compareSchema returns the summary of one schema that differs, or nil when
// local and server are equal.
func compareSchema(name string, local, server map[string]any) *schemaChange {
	l, s := schemaComparableTop(local), schemaComparableTop(server)
	if schemaCanon(l) == schemaCanon(s) {
		return nil
	}
	ch := &schemaChange{Name: name, FieldsAdded: []string{}, FieldsRemoved: []string{}, FieldsChanged: []string{}, Keys: []string{}}
	lf, sf := schemaFieldsByName(l), schemaFieldsByName(s)
	for f, canon := range lf {
		if old, ok := sf[f]; !ok {
			ch.FieldsAdded = append(ch.FieldsAdded, f)
		} else if old != canon {
			ch.FieldsChanged = append(ch.FieldsChanged, f)
		}
	}
	for f := range sf {
		if _, ok := lf[f]; !ok {
			ch.FieldsRemoved = append(ch.FieldsRemoved, f)
		}
	}
	keys := map[string]bool{}
	for k := range l {
		keys[k] = true
	}
	for k := range s {
		keys[k] = true
	}
	for k := range keys {
		if schemaCanon(l[k]) == schemaCanon(s[k]) {
			continue
		}
		// `fields` is listed as a key only when the summary above says
		// nothing, which means the same fields are in another order.
		if k == "fields" {
			if len(ch.FieldsAdded)+len(ch.FieldsRemoved)+len(ch.FieldsChanged) == 0 {
				ch.Keys = append(ch.Keys, "fields (order)")
			}
			continue
		}
		ch.Keys = append(ch.Keys, k)
	}
	sort.Strings(ch.FieldsAdded)
	sort.Strings(ch.FieldsRemoved)
	sort.Strings(ch.FieldsChanged)
	sort.Strings(ch.Keys)
	return ch
}

// buildSchemaPlan compares the folder to the server's schema list.
func buildSchemaPlan(scope, dir string, local map[string]json.RawMessage, server []json.RawMessage) (*schemaPlan, error) {
	p := &schemaPlan{Scope: scope, Dir: dir, Added: []string{}, Changed: []schemaChange{}, Removed: []string{}, Skipped: []string{}}
	onServer := map[string]bool{}
	for _, raw := range server {
		obj, err := decodeSchemaJSON(raw)
		if err != nil {
			return nil, fmt.Errorf("the server sent a schema that did not parse: %v", err)
		}
		name, _ := obj["name"].(string)
		if !schemaFileNameOK(name) {
			p.Skipped = append(p.Skipped, name)
			continue
		}
		onServer[name] = true
		lraw, ok := local[name]
		if !ok {
			p.Removed = append(p.Removed, name)
			continue
		}
		lobj, err := decodeSchemaJSON(lraw)
		if err != nil {
			return nil, err
		}
		if ch := compareSchema(name, lobj, obj); ch != nil {
			p.Changed = append(p.Changed, *ch)
		} else {
			p.Unchanged++
		}
	}
	for name := range local {
		if !onServer[name] {
			p.Added = append(p.Added, name)
		}
	}
	sort.Strings(p.Added)
	sort.Strings(p.Removed)
	sort.Strings(p.Skipped)
	sort.Slice(p.Changed, func(i, j int) bool { return p.Changed[i].Name < p.Changed[j].Name })
	return p, nil
}

// summary is the one-line form of a change: "+a, -b, ~c; keys: title".
func (c schemaChange) summary() string {
	var parts []string
	for _, f := range c.FieldsAdded {
		parts = append(parts, "+"+f)
	}
	for _, f := range c.FieldsRemoved {
		parts = append(parts, "-"+f)
	}
	for _, f := range c.FieldsChanged {
		parts = append(parts, "~"+f)
	}
	s := ""
	if len(parts) > 0 {
		s = "fields: " + strings.Join(parts, ", ")
	}
	if len(c.Keys) > 0 {
		if s != "" {
			s += "; "
		}
		s += "keys: " + strings.Join(c.Keys, ", ")
	}
	return s
}
