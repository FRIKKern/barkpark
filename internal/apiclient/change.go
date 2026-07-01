// Package apiclient — real-time change detection. This file holds the SSE
// listener, its poll-once fallback, the OnChange notify seam, and the
// export-stream document-set hash. Split out of client.go to keep that file
// under budget; a same-package, behaviour-preserving relocation (Go compiles
// the package as a unit, so no API changes).
package apiclient

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

// StartSSE connects to the Phoenix SSE listener for real-time updates.
// Falls back to a single poll on reconnect, with exponential backoff. Change
// detection fires the OnChange callback (nil-safe). With OnChange unset the
// listener idles, so a CLI that never sets it never opens the stream.
func (c *Client) StartSSE(token string) {
	backoff := time.Second
	maxBackoff := 30 * time.Second

	for {
		if c.OnChange == nil {
			time.Sleep(time.Second)
			continue
		}
		err := c.listenSSE(token)
		if err != nil {
			c.pollOnce()
			time.Sleep(backoff)
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		} else {
			backoff = time.Second
		}
	}
}

func (c *Client) listenSSE(token string) error {
	sseURL := c.scopedURL("/v1/data/listen/" + c.Dataset)
	req, err := http.NewRequest("GET", sseURL, nil)
	if err != nil {
		return err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	sseClient := &http.Client{Timeout: 0}
	resp, err := sseClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("SSE status %d", resp.StatusCode)
	}

	// Use a line scanner instead of raw Read to handle SSE frames correctly.
	// Raise the line cap above bufio's 64KB default so a large mutation frame
	// carrying a big document envelope doesn't hit ErrTooLong and force a reconnect.
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "event: mutation") {
			c.notifyChange()
		}
	}
	return scanner.Err()
}

func (c *Client) pollOnce() {
	// Scoped change-detection fallback when the SSE listener drops. The legacy
	// flat document list has no scoped equivalent; the export endpoint streams
	// the dataset as NDJSON (one document envelope per line).
	//
	// Change detection hashes the DOCUMENT SET — the sorted set of
	// "_id:_rev" pairs — not the raw response body. The envelope's _rev bumps
	// on every mutation, so this hash changes iff a document is added, removed,
	// or revised. It deliberately ignores volatile / non-identity envelope
	// content and is order-independent, so a re-poll over the same docs (in any
	// order) yields the same hash and fires no spurious refresh.
	resp, err := c.authGet(c.scopedURL("/v1/data/export/" + c.Dataset))
	if err != nil {
		return
	}
	defer resp.Body.Close()

	hash := c.exportDocSetHash(resp.Body)

	c.mu.Lock()
	changed := hash != c.lastHash
	c.lastHash = hash
	c.mu.Unlock()

	if changed {
		c.notifyChange()
	}
}

// notifyChange invokes the OnChange callback if one is set. It is the single
// nil-safe seam where the framework-free client signals "the dataset changed".
func (c *Client) notifyChange() {
	if c.OnChange != nil {
		c.OnChange()
	}
}

// exportDocSetHash reads the NDJSON export stream and returns a stable hash of
// the document set: each line's "_id:_rev" pair, sorted and concatenated, then
// SHA-256'd. Unparseable lines are skipped so a single malformed record cannot
// poison the whole signature. The hash is identity-derived — independent of
// stream order and of any non-identity envelope fields.
func (c *Client) exportDocSetHash(r io.Reader) string {
	type docIdentity struct {
		ID  string `json:"_id"`
		Rev string `json:"_rev"`
	}

	pairs := make([]string, 0)
	scanner := bufio.NewScanner(r)
	// Export documents can be large; raise the line cap above bufio's 64KB
	// default so a big content blob doesn't truncate the _id/_rev decode.
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var d docIdentity
		if err := json.Unmarshal(line, &d); err != nil || d.ID == "" {
			continue
		}
		pairs = append(pairs, d.ID+":"+d.Rev)
	}

	sort.Strings(pairs)
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(pairs, "\n"))))
}
