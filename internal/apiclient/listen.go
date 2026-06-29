// Package apiclient — user-facing SSE listen. `Listen` streams the change feed
// and hands each event to a callback (the `bp listen` command prints them),
// distinct from the TUI's internal change-detection in change.go.
package apiclient

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// Listen opens the SSE change stream for `types` (comma-separated document types,
// or "" for all) and invokes onEvent for each event until the stream ends, ctx is
// cancelled (e.g. Ctrl-C), or an error occurs. onEvent receives the event name
// (e.g. "mutation") and its `data:` payload (multi-line frames are joined with
// "\n"). Returning an error from onEvent stops the stream.
func (c *Client) Listen(ctx context.Context, types string, onEvent func(event, data string) error) error {
	suffix := "/v1/data/listen/" + c.Dataset
	if types != "" {
		suffix += "?types=" + url.QueryEscape(types)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.scopedURL(suffix), nil)
	if err != nil {
		return err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	req.Header.Set("Accept", "text/event-stream")

	// No client timeout — the stream is long-lived; ctx cancellation ends it.
	resp, err := (&http.Client{Timeout: 0}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("listen: SSE status %d", resp.StatusCode)
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20) // tolerate large event frames

	var event string
	var data []string
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == "": // blank line = frame boundary → dispatch
			if len(data) > 0 {
				if err := onEvent(event, strings.Join(data, "\n")); err != nil {
					return err
				}
			}
			event, data = "", nil
		case strings.HasPrefix(line, ":"): // comment / keep-alive — ignore
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(line[len("event:"):])
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimSpace(line[len("data:"):]))
		}
	}
	return scanner.Err()
}
