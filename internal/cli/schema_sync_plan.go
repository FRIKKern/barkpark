package cli

// schema_sync_plan.go is the comparison behind `bp schema pull|diff|push`
// (schema_sync_cmd.go): it reads a folder of schema files, compares it to the
// schemas the server lists, and builds the plan the three verbs print.
//
// The comparison follows what the server stores and echoes
// (api/lib/barkpark/content/schema_definition.ex and schema.ex, sdk_content):
//
//   - Only the top-level keys in schemaEchoKeys are compared. A key the file
//     leaves out, or sets to null, counts as that key's server default. Other
//     top-level keys (`_comment`, a misspelled key) are dropped by the server,
//     so they are not compared. Every compared value must match exactly.
//   - In each field the server adds `required?`, an `of` list on an array
//     field and a `to` list on a reference field. schemaEchoField computes
//     the same three on both sides. Everything else in a field is compared
//     exactly: false, "", [] and {} are values there.
//   - The upsert keeps the stored value of a key the request leaves out. So
//     schemaPushBody sends every compared key, with the default for the ones
//     the file leaves out, and a key removed from a file is cleared.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// schemaEchoKey is one top-level key the server stores and echoes.
type schemaEchoKey struct {
	echo string // the spelling GET /v1/schemas serves and pull writes
	cast string // the spelling the upsert casts, when it differs
	def  any    // what the server echoes when the key was never set
}

// schemaEchoKeys is every stored key the schema list echoes, with its
// default. `owner_scoped` and `cors_origins` are stored but never echoed, so
// no verb can compare them; push sends them only when a file has them.
var schemaEchoKeys = []schemaEchoKey{
	{echo: "title"},
	{echo: "icon"},
	{echo: "visibility", def: "public"},
	{echo: "singleton", def: false},
	{echo: "kind", def: "document"},
	{echo: "fields", def: []any{}},
	{echo: "actions", def: []any{}},
	{echo: "groups", def: []any{}},
	{echo: "fieldsets", def: []any{}},
	{echo: "deskGroups", cast: "desk_groups", def: []any{}},
	{echo: "desk", def: map[string]any{}},
	{echo: "crossValidations", cast: "cross_validations", def: []any{}},
	{echo: "listPreview", cast: "list_preview", def: map[string]any{}},
	{echo: "initialValues", cast: "initial_values", def: map[string]any{}},
	{echo: "layout", def: []any{}},
	{echo: "prefill", def: map[string]any{}},
	{echo: "readerWrites", cast: "reader_writes"},
}

// schemaKeyValue reads one stored key from a definition under either
// spelling. The cast spelling wins when a file has both, as on the server.
func schemaKeyValue(obj map[string]any, k schemaEchoKey) (any, bool) {
	if k.cast != "" {
		if v, ok := obj[k.cast]; ok {
			return v, true
		}
	}
	v, ok := obj[k.echo]
	return v, ok
}

// schemaChange is one schema that differs, as a field-level summary. The
// direction is what a push would do to the server.
type schemaChange struct {
	Name          string   `json:"name"`
	FieldsAdded   []string `json:"fields_added"`
	FieldsRemoved []string `json:"fields_removed"`
	FieldsChanged []string `json:"fields_changed"`
	Keys          []string `json:"keys"`
	// CutMembers names the array fields a push would damage on a server that
	// cannot return stored fields. See schemaCutMembers.
	CutMembers []string `json:"cut_members,omitempty"`
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
	// StoredFields is true when the server sent each field list as stored
	// (`?definition=stored`) and false when it sent the served form.
	StoredFields bool `json:"stored_fields"`
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

// schemaComparableTop reduces a definition to what the server would return
// for it: the stored keys only, defaults filled in. With stored, the server
// sent each field list as stored and fields are compared as written. Without
// it the server sent the served form, so both sides are put in that form.
func schemaComparableTop(obj map[string]any, stored bool) map[string]any {
	out := map[string]any{}
	for _, k := range schemaEchoKeys {
		v, ok := schemaKeyValue(obj, k)
		if !ok || v == nil || v == "" {
			v = k.def // the cast stores "" as null
		}
		if list, isList := v.([]any); isList && k.echo == "fields" {
			fields := schemaCastFields(list)
			for i, f := range fields {
				if stored {
					fields[i] = schemaStoredField(f)
				} else {
					fields[i] = schemaEchoField(f)
				}
			}
			v = fields
		}
		out[k.echo] = v
	}
	return out
}

// schemaPushBody is the upsert body for one file: the file as written, plus
// the default of every stored key it leaves out. The upsert keeps the stored
// value of a key the body omits, so without the defaults a key removed from
// the file would stay on the server.
func schemaPushBody(raw json.RawMessage) (json.RawMessage, error) {
	obj, err := decodeSchemaJSON(raw)
	if err != nil {
		return nil, err
	}
	for _, k := range schemaEchoKeys {
		if k.echo == "title" {
			continue // required; the server names it when it is missing
		}
		if _, ok := schemaKeyValue(obj, k); ok {
			continue
		}
		name := k.cast
		if name == "" {
			name = k.echo
		}
		obj[name] = k.def
	}
	return json.Marshal(obj)
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
func compareSchema(name string, local, server map[string]any, stored bool) *schemaChange {
	l, s := schemaComparableTop(local, stored), schemaComparableTop(server, stored)
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
func buildSchemaPlan(scope, dir string, local map[string]json.RawMessage, server []json.RawMessage, stored bool) (*schemaPlan, error) {
	p := &schemaPlan{Scope: scope, Dir: dir, StoredFields: stored, Added: []string{}, Changed: []schemaChange{}, Removed: []string{}, Skipped: []string{}}
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
		if ch := compareSchema(name, lobj, obj, stored); ch != nil {
			if !stored {
				ch.CutMembers = schemaCutMembers(lobj, obj)
			}
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
