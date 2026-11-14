package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// syncFakeServer answers the three schema routes the way the real server
// does, as read from api/lib/barkpark/content/schema_definition.ex and
// schema.ex. The upsert is a cast: a key the body leaves out keeps its stored
// value, and a key the server does not store is dropped. The echo fills the
// defaults (visibility "public", kind "document", empty lists and objects) and
// adds required?, of and to to each field. It counts the writes it gets.
type syncFakeServer struct {
	srv *httptest.Server

	mu      sync.Mutex
	schemas map[string]map[string]any // stored rows, cast spelling
	posts   []string
	deletes []string
	// old makes the fake a server without `?definition=stored`: it ignores
	// the query and always sends the served form.
	old bool
}

var syncFakeCamel = map[string]string{"deskGroups": "desk_groups", "listPreview": "list_preview", "initialValues": "initial_values", "crossValidations": "cross_validations", "readerWrites": "reader_writes"}
var syncFakeCast = []string{"name", "title", "icon", "visibility", "singleton", "kind", "fields", "actions", "groups", "fieldsets", "desk_groups", "desk", "list_preview", "initial_values", "cross_validations", "layout", "prefill", "reader_writes"}

func newSyncFakeServer(t *testing.T) *syncFakeServer {
	t.Helper()
	s := &syncFakeServer{schemas: map[string]map[string]any{}}
	s.srv = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *syncFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: s.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

// cast stores a request body the way the changeset does.
func (s *syncFakeServer) cast(in map[string]any) string {
	for camel, snake := range syncFakeCamel {
		if v, ok := in[camel]; ok {
			delete(in, camel)
			if _, has := in[snake]; !has {
				in[snake] = v
			}
		}
	}
	name, _ := in["name"].(string)
	row := s.schemas[name]
	if row == nil {
		row = map[string]any{}
		s.schemas[name] = row
	}
	for _, k := range syncFakeCast {
		if v, ok := in[k]; ok {
			row[k] = v
		}
	}
	return name
}

func syncFakeSpecs(list []any) []any {
	out := []any{}
	for _, v := range list {
		spec := map[string]any{"type": "string"}
		if m, ok := v.(map[string]any); ok {
			spec = map[string]any{}
			for _, k := range []string{"type", "to", "name"} {
				if val, ok := m[k]; ok {
					spec[k] = val
				}
			}
		} else if str, ok := v.(string); ok {
			spec["type"] = str
		}
		out = append(out, spec)
	}
	return out
}

// echo serves a stored row the way serialize_schema_for_sdk does.
func syncFakeEcho(row map[string]any) map[string]any {
	or := func(k string, d any) any {
		if v := row[k]; v != nil {
			return v
		}
		return d
	}
	fields := []any{}
	list, _ := row["fields"].([]any)
	for _, f := range list {
		m, _ := f.(map[string]any)
		o := map[string]any{}
		for k, v := range m {
			o[k] = v
		}
		rules, _ := m["validation"].(map[string]any)
		o["required?"] = rules["required"] == true
		switch m["type"] {
		case "array":
			if of, ok := m["of"].([]any); ok {
				o["of"] = syncFakeSpecs(of)
			} else {
				o["of"] = []any{map[string]any{"type": "string"}}
			}
		case "reference":
			if ref, ok := m["refType"].(string); ok {
				o["to"] = []any{map[string]any{"type": ref}}
			} else {
				o["to"] = []any{}
			}
		}
		fields = append(fields, o)
	}
	out := map[string]any{
		"id": row["name"], "name": row["name"], "title": row["title"], "icon": row["icon"],
		"schemaHash": "hash-of-" + fmt.Sprint(row["name"]),
		"visibility": or("visibility", "public"), "singleton": or("singleton", false), "kind": or("kind", "document"),
		"fields": fields, "actions": or("actions", []any{}), "groups": or("groups", []any{}),
		"fieldsets": or("fieldsets", []any{}), "deskGroups": or("desk_groups", []any{}),
		"desk": or("desk", map[string]any{}), "crossValidations": or("cross_validations", []any{}),
		"listPreview": or("list_preview", map[string]any{}), "initialValues": or("initial_values", map[string]any{}),
		"layout": or("layout", []any{}), "prefill": or("prefill", map[string]any{}),
	}
	if rw, ok := row["reader_writes"].(map[string]any); ok {
		out["readerWrites"] = rw
	}
	return out
}

func (s *syncFakeServer) handle(w http.ResponseWriter, r *http.Request) {
	const route = "/w/ws/p/proj/v1/schemas/production"
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case r.Method == http.MethodGet && r.URL.Path == route:
		list := []map[string]any{}
		env := map[string]any{"_schemaVersion": 1}
		stored := !s.old && r.URL.Query().Get("definition") == "stored"
		for _, row := range s.schemas {
			served := syncFakeEcho(row)
			if stored {
				served["fields"], env["definition"] = row["fields"], "stored"
			}
			list = append(list, served)
		}
		env["schemas"] = list
		_ = json.NewEncoder(w).Encode(env)
	case r.Method == http.MethodPost && r.URL.Path == route:
		body, _ := io.ReadAll(r.Body)
		var def map[string]any
		if json.Unmarshal(body, &def) != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		name := s.cast(def)
		s.posts = append(s.posts, name)
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(syncFakeEcho(s.schemas[name]))
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, route+"/"):
		name := strings.TrimPrefix(r.URL.Path, route+"/")
		delete(s.schemas, name)
		s.deletes = append(s.deletes, name)
		_ = json.NewEncoder(w).Encode(map[string]any{"deleted": name, "id": "row-" + name, "dataset": "production"})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// seed stores definitions as if they had been posted, without counting them.
func (s *syncFakeServer) seed(defs ...map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, def := range defs {
		s.cast(def)
	}
}

func (s *syncFakeServer) stored(name, key string) any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.schemas[name][key]
}

func (s *syncFakeServer) writes() (posts, deletes []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.posts...), append([]string{}, s.deletes...)
}
