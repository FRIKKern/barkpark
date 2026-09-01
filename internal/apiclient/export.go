// Package apiclient — dataset export. `Export` streams every document as NDJSON
// (one JSON per line) and hands each to a callback (the `bp export` command
// prints them). Unlike Listen (a long-lived SSE feed where EOF is a drop), an
// export is FINITE — but a clean EOF only proves completeness when the FRAMING
// can prove it. Export returns nil ONLY for an attestable framing (chunked, or
// a satisfied Content-Length); a close-delimited body, where a truncated stream
// is byte-identical to a complete one, is REFUSED with a non-nil error.
package apiclient

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
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
// ends it early. A clean server EOF returns nil ONLY when the response carried
// an end-of-stream signal Export can check — see the framing note at the end of
// the function for why a close-delimited body cannot be attested.
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
	// `application/x-ndjson` ALONE is not negotiable: the export route rides
	// :api / :scoped_api, both `plug(:accepts, ["json"])`, so Phoenix raises
	// NotAcceptableError -> 406 BEFORE auth and the operator sees only
	// "export: unknown error" (live: guerrilla returns 406 for x-ndjson and 401
	// for x-ndjson+json on the identical URL). Append `application/json` — the
	// same append AcceptBarkparkVendor makes server-side for text/event-stream
	// and application/x-tar — so the standard matcher negotiates JSON while the
	// header still states the streaming type this client actually parses. Doing
	// it client-side keeps `bp export` working against EVERY deployed server,
	// not only ones carrying a new plug branch.
	req.Header.Set("Accept", "application/x-ndjson, application/json")

	// No client timeout — a full-dataset export is long; ctx cancellation ends it.
	resp, err := (&http.Client{Timeout: 0}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		// No "export: " wrap — export_cmd already prefixes the message.
		return humanAPIError(resp.StatusCode, body)
	}

	// Classify the framing BEFORE reading a byte. Two of the three shapes carry
	// an explicit end-of-stream signal the transport itself verifies:
	//   chunked          — resp.TransferEncoding names it; a missing terminating
	//                      chunk surfaces as an unexpected EOF from Read.
	//   length-delimited — resp.ContentLength >= 0; a short body likewise.
	// The third — no Content-Length AND no chunked encoding — ends only when the
	// connection closes, so nothing distinguishes "the server finished" from
	// "the server died". That one is not attestable.
	attestable := resp.ContentLength >= 0
	for _, te := range resp.TransferEncoding {
		if strings.EqualFold(te, "chunked") {
			attestable = true
		}
	}

	scanner := bufio.NewScanner(resp.Body)
	// One exported document per line can far exceed the 64 KB default token cap
	// (rich content, large arrays) — allow up to 16 MB per line so a big document
	// never truncates the export with a "token too long" error.
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	docs := 0
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		if err := onDoc(line); err != nil {
			return err
		}
		docs++
	}
	// Export is finite, but a clean EOF is only proof of completeness when the
	// framing says so. Measured against hand-framed loopback servers (the cases
	// in export_framing_test.go): a chunked body without its terminating chunk
	// and a short Content-Length both surface as "unexpected EOF" — honest, and
	// returned here as-is; a truncated CLOSE-DELIMITED body is byte-identical to
	// a complete one and leaves scanner.Err() nil.
	//
	// `bp export` writes a sidecar (documents/bytes/sha256) whenever Export
	// returns nil, and `bp export --verify` then attests that sidecar against the
	// file. A silently truncated stream would therefore produce a PRESENT, VALID
	// sidecar for a SHORT backup — a falsified artifact that verifies. So a
	// close-delimited response is refused outright rather than attested: the
	// operator gets an explicit error naming the framing plus the count that did
	// arrive, and runExport's `err != nil` arms print PARTIAL and write NO
	// sidecar. (The real ExportController uses send_chunked — the honest framing
	// — so this refusal fires only behind a re-framing intermediary.)
	//
	// A real scanner error wins over the framing refusal: it is the more specific
	// diagnosis of the same incompleteness.
	if err := scanner.Err(); err != nil {
		return err
	}
	if !attestable {
		return fmt.Errorf(
			"export stream was close-delimited (no Content-Length, no chunked framing), "+
				"so a truncated body is indistinguishable from a complete one — "+
				"refusing to attest this export as complete; %d documents were received",
			docs)
	}
	return nil
}
