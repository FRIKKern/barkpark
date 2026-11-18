package cli

// schema_copy.go is `bp export --schemas <file>` and `bp import --schemas <file>`
// (task-cdd4555f010c1893): copy a dataset's schemas with its documents, so a
// copy to another instance needs no `bp schema apply` per schema.
//
// Export reads GET /v1/schemas/:dataset and writes every schema to one JSON
// file without the server's schemaHash, which each instance computes for
// itself. Import posts each schema to POST /v1/schemas/:dataset before any
// media or document is written. The POST is an upsert, so a re-run writes the
// same definitions again. The first schema write also creates the dataset on
// the target. A 429 waits out the server's Retry-After and retries the same
// schema, through the same pacer the media copy uses.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// schemaCopyFile is the file `bp export --schemas` writes.
type schemaCopyFile struct {
	Scope   string            `json:"scope"`
	Types   []string          `json:"types,omitempty"`
	Schemas []json.RawMessage `json:"schemas"`
}

// schemaCopyName reads the name of one schema definition.
func schemaCopyName(raw json.RawMessage) string {
	var head struct {
		Name string `json:"name"`
	}
	_ = json.Unmarshal(raw, &head)
	return head.Name
}

// fetchDatasetSchemas reads every schema of the dataset, with schemaHash
// removed. A non-2xx answer comes back as an error that carries the server's
// message.
func fetchDatasetSchemas(ctx manifest.Context, dataset string) ([]json.RawMessage, error) {
	out, _, err := fetchSchemaList(ctx, dataset, "")
	return out, err
}

// fetchSchemaList is fetchDatasetSchemas with a query string for the list
// route. It also returns the envelope's `definition`, which a server sets to
// "stored" when it answered `?definition=stored` (schema_sync_echo.go).
func fetchSchemaList(ctx manifest.Context, dataset, query string) ([]json.RawMessage, string, error) {
	status, body, err := doRequest("GET", ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset)+query), ctxAuthHeaders(ctx), nil)
	if err != nil {
		return nil, "", err
	}
	if status < 200 || status >= 300 {
		return nil, "", fmt.Errorf("HTTP %d: %s", status, classifyError(status, body).errorMessage())
	}
	var env struct {
		Schemas    []map[string]json.RawMessage `json:"schemas"`
		Definition string                       `json:"definition"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, "", fmt.Errorf("the schema list did not parse: %v", err)
	}
	if env.Schemas == nil {
		return nil, "", fmt.Errorf("the schema list has no schemas key")
	}
	out := make([]json.RawMessage, 0, len(env.Schemas))
	for _, s := range env.Schemas {
		delete(s, "schemaHash")
		b, err := json.Marshal(s)
		if err != nil {
			return nil, "", err
		}
		out = append(out, b)
	}
	return out, env.Definition, nil
}

// exportSchemas writes the dataset's schemas to path. When types names any,
// it writes their schemas and every schema they reach (schemaClosure), so the
// file recreates working types on the target (task-5b5fdb17a8a70795). It
// writes a temporary file next to path and renames it, so a failed run leaves
// an earlier file as it was.
func exportSchemas(out *writer, ctx manifest.Context, dataset, path string, types []string) int {
	schemas, err := fetchDatasetSchemas(ctx, dataset)
	if err != nil {
		return useError(out, "request_failed", fmt.Sprintf("export --schemas: reading the schemas of %s: %v", exportScope(ctx), err), exitGeneric)
	}
	total := len(schemas)
	if len(types) > 0 {
		var reached, missing []string
		schemas, reached, missing = schemaClosure(schemas, types)
		if len(missing) > 0 {
			out.errf("export --schemas: %s has no schema for type %s, so the file leaves it out", exportScope(ctx), strings.Join(missing, ", "))
		}
		if len(reached) > 0 {
			out.errf("export --schemas: the named types use %d more schema(s), written too: %s", len(reached), strings.Join(reached, ", "))
		}
		if len(schemas) < total {
			out.errf("export --schemas: the file holds %d of the %d schemas in %s, so datasetSchemaContentHash matches the source only when the source holds these %d alone",
				len(schemas), total, exportScope(ctx), len(schemas))
		}
	}
	body, err := json.MarshalIndent(schemaCopyFile{Scope: exportScope(ctx), Types: types, Schemas: schemas}, "", "  ")
	if err != nil {
		return useError(out, "failed", fmt.Sprintf("export --schemas: %v", err), exitGeneric)
	}
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return useError(out, "failed", fmt.Sprintf("export --schemas: %v", err), exitGeneric)
		}
	}
	tmp := path + exportPartialSuffix
	if err := os.WriteFile(tmp, append(body, '\n'), 0o644); err != nil {
		return useError(out, "failed", fmt.Sprintf("export --schemas: %v", err), exitGeneric)
	}
	if err := os.Rename(tmp, path); err != nil {
		return useError(out, "failed", fmt.Sprintf("export --schemas: %v", err), exitGeneric)
	}
	out.errf("exported %d schema(s) to %s", len(schemas), path)
	return exitOK
}

// readSchemaCopy reads a file `bp export --schemas` wrote. Every schema must
// carry a name, because the server keys the upsert on it.
func readSchemaCopy(path string) (*schemaCopyFile, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f schemaCopyFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("%s is not a `bp export --schemas` file: %v", path, err)
	}
	if f.Schemas == nil {
		return nil, fmt.Errorf("%s has no schemas list", path)
	}
	for i, s := range f.Schemas {
		if schemaCopyName(s) == "" {
			return nil, fmt.Errorf("%s: schema %d has no name", path, i+1)
		}
	}
	return &f, nil
}

// applySchemas posts every schema in f to the target dataset, in file order.
// It stops at the first refusal and names the schema. The schemas before it
// stay applied, and a re-run applies them again with no change.
func applySchemas(out *writer, ctx manifest.Context, dataset string, f *schemaCopyFile) error {
	client := newTransferClient()
	pacer := newMediaPacer(0)
	u := ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset))
	for i, s := range f.Schemas {
		resp, err := pacer.do(client, func() (*http.Request, error) {
			req, err := http.NewRequest(http.MethodPost, u, bytes.NewReader(s))
			if err != nil {
				return nil, err
			}
			for k, v := range ctxAuthHeaders(ctx) {
				req.Header.Set(k, v)
			}
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Accept", "application/json")
			return req, nil
		})
		if err != nil {
			return fmt.Errorf("schema %s: %v; %d of %d schema(s) were applied before it", schemaCopyName(s), err, i, len(f.Schemas))
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, responseByteCap))
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			msg := fmt.Sprintf("schema %s: HTTP %d: %s; %d of %d schema(s) were applied before it",
				schemaCopyName(s), resp.StatusCode, classifyError(resp.StatusCode, body).errorMessage(), i, len(f.Schemas))
			if resp.StatusCode == http.StatusNotFound {
				msg += fmt.Sprintf(". If workspace %s does not exist on the target, create it first with `bp workspace create %s`", orDash(ctx.Workspace), orDash(ctx.Workspace))
			}
			return fmt.Errorf("%s", msg)
		}
		if serr := builtinWriteReceiptErr("schema apply", resp.StatusCode, body); serr != nil {
			return fmt.Errorf("schema %s: %v", schemaCopyName(s), serr)
		}
		if got := schemaCopyName(body); got != schemaCopyName(s) {
			return fmt.Errorf("schema %s: the target answered %d but its receipt names schema %q", schemaCopyName(s), resp.StatusCode, got)
		}
	}
	if pacer.throttled > 0 && !out.machineOut() {
		out.errf("import: the target answered 429 to %d schema write(s) and the import waited %s in total", pacer.throttled, pacer.waited)
	}
	return nil
}

// schemaClosure keeps the schemas of types and every schema they reach: the
// object types a field names (namedType, at any depth: array members, block
// members, nested fields) and the document types a reference field points at
// (to[].type and refType). Each schema reached is searched the same way until
// nothing new turns up. The schemas keep the order the server listed them in.
// reached names the schemas added beyond types; missing names the types with
// no schema.
func schemaClosure(schemas []json.RawMessage, types []string) (kept []json.RawMessage, reached, missing []string) {
	byName := make(map[string]json.RawMessage, len(schemas))
	for _, s := range schemas {
		byName[schemaCopyName(s)] = s
	}
	keep := map[string]bool{}
	var queue []string
	for _, t := range types {
		if _, ok := byName[t]; !ok {
			missing = append(missing, t)
			continue
		}
		if !keep[t] {
			keep[t] = true
			queue = append(queue, t)
		}
	}
	for len(queue) > 0 {
		name := queue[0]
		queue = queue[1:]
		var def any
		if err := json.Unmarshal(byName[name], &def); err != nil {
			continue
		}
		for _, used := range schemaTypeNames(def, nil) {
			if _, ok := byName[used]; ok && !keep[used] {
				keep[used] = true
				queue = append(queue, used)
			}
		}
	}
	for _, s := range schemas {
		name := schemaCopyName(s)
		if !keep[name] {
			continue
		}
		kept = append(kept, s)
		if !containsString(types, name) {
			reached = append(reached, name)
		}
	}
	return kept, reached, missing
}

// schemaTypeNames collects the type names one schema definition uses.
func schemaTypeNames(v any, acc []string) []string {
	switch x := v.(type) {
	case map[string]any:
		for k, child := range x {
			switch k {
			case "namedType", "refType":
				if name, ok := child.(string); ok && name != "" {
					acc = append(acc, name)
				}
			case "to":
				if targets, ok := child.([]any); ok {
					for _, t := range targets {
						if m, ok := t.(map[string]any); ok {
							if name, ok := m["type"].(string); ok && name != "" {
								acc = append(acc, name)
							}
						}
					}
				}
			}
			acc = schemaTypeNames(child, acc)
		}
	case []any:
		for _, child := range x {
			acc = schemaTypeNames(child, acc)
		}
	}
	return acc
}
