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

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// schemaCopyFile is the file `bp export --schemas` writes.
type schemaCopyFile struct {
	Scope   string            `json:"scope"`
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
	status, body, err := doRequest("GET", ctxScopedURL(ctx, "/v1/schemas/"+url.PathEscape(dataset)), ctxAuthHeaders(ctx), nil)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("HTTP %d: %s", status, classifyError(status, body).errorMessage())
	}
	var env struct {
		Schemas []map[string]json.RawMessage `json:"schemas"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("the schema list did not parse: %v", err)
	}
	if env.Schemas == nil {
		return nil, fmt.Errorf("the schema list has no schemas key")
	}
	out := make([]json.RawMessage, 0, len(env.Schemas))
	for _, s := range env.Schemas {
		delete(s, "schemaHash")
		b, err := json.Marshal(s)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, nil
}

// exportSchemas writes the dataset's schemas to path. It writes a temporary
// file next to path and renames it, so a failed run leaves an earlier file
// as it was.
func exportSchemas(out *writer, ctx manifest.Context, dataset, path string) int {
	schemas, err := fetchDatasetSchemas(ctx, dataset)
	if err != nil {
		return useError(out, "request_failed", fmt.Sprintf("export --schemas: reading the schemas of %s: %v", exportScope(ctx), err), exitGeneric)
	}
	body, err := json.MarshalIndent(schemaCopyFile{Scope: exportScope(ctx), Schemas: schemas}, "", "  ")
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
