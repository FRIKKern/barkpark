// Package apiclient — dataset export. `Export` streams every document as NDJSON
// (one JSON per line) and hands each to a callback (the `bp export` command
// prints them). Unlike Listen (a long-lived SSE feed where EOF is a drop), an
// export is FINITE: a clean EOF means the whole dataset streamed, so Export
// returns nil.
package apiclient

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"net/url"
)

// ExportOpts filters a dataset export.
type ExportOpts struct {
	// Type restricts the export to one document type (server `?type=`); "" = all.
	Type string
	// Perspective picks published | drafts | raw (server default raw); "" = default.
	Perspective string
}

// Export streams the dataset's documents (GET /v1/data/export/:dataset) and
// invokes onDoc once per NDJSON line (a single JSON document, verbatim).
// Returning an error from onDoc stops the stream. ctx cancellation (Ctrl-C)
// ends it early; a clean server EOF means the export finished (returns nil).
func (c *Client) Export(ctx context.Context, opts ExportOpts, onDoc func(line string) error) error {
	suffix := "/v1/data/export/" + c.Dataset
	q := url.Values{}
	if opts.Type != "" {
		q.Set("type", opts.Type)
	}
	if opts.Perspective != "" {
		q.Set("perspective", opts.Perspective)
	}
	if enc := q.Encode(); enc != "" {
		suffix += "?" + enc
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.scopedURL(suffix), nil)
	if err != nil {
		return err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	req.Header.Set("Accept", "application/x-ndjson")

	// No client timeout — a full-dataset export is long; ctx cancellation ends it.
	resp, err := (&http.Client{Timeout: 0}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("export: status %d", resp.StatusCode)
	}

	scanner := bufio.NewScanner(resp.Body)
	// One exported document per line can far exceed the 64 KB default token cap
	// (rich content, large arrays) — allow up to 16 MB per line so a big document
	// never truncates the export with a "token too long" error.
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		if err := onDoc(line); err != nil {
			return err
		}
	}
	// Export is finite: a clean EOF means every document streamed.
	return scanner.Err()
}
