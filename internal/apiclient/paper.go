package apiclient

// The working-copy transport (BPML masterplan W3). Two calls, deliberately
// thin: the CLI never parses BPML — pull fetches the server's canonical text
// plus its op-rev anchor, and sync sends edited text back for the SERVER to
// parse, diff and apply. The grammar keeps its single Elixir owner.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

// PaperTeachErr is one structured teaching error from the BPML parser —
// code + message + line + the fix, exactly as the server spells it.
type PaperTeachErr struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Line    int    `json:"line"`
	Hint    string `json:"hint"`
	OpIndex *int   `json:"op_index,omitempty"`
}

// PaperAPIErr is a non-2xx sync/pull outcome the caller can render honestly:
// the transport status plus the server's error envelope.
type PaperAPIErr struct {
	Status  int
	Code    string
	Message string
	Hint    string
	Errors  []PaperTeachErr
}

func (e *PaperAPIErr) Error() string {
	if e.Hint != "" {
		return fmt.Sprintf("%s: %s (%s)", e.Code, e.Message, e.Hint)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// PaperSyncResult is a successful push receipt. Rev is the paper-level op-rev
// (string on the wire, same spelling as the x-paper-rev anchor). When
// Unchanged, nothing applied and Bpml is empty; otherwise Bpml carries the
// CANONICAL post-write document the working copy must converge on.
type PaperSyncResult struct {
	OK        bool   `json:"ok"`
	Slug      string `json:"slug"`
	Rev       string `json:"rev"`
	OpCount   int    `json:"op_count"`
	Unchanged bool   `json:"unchanged"`
	Bpml      string `json:"bpml"`
}

const paperBodyCap = 32 << 20

// PaperPullBpml fetches the paper's readable BPML view and the op-rev it
// anchors on (the x-paper-rev header). The read is the public source route,
// carried with the token so scoped instances resolve.
func (c *Client) PaperPullBpml(slug string) (bpml string, rev string, apiErr *PaperAPIErr, err error) {
	u := c.flatURL("/papers/" + url.PathEscape(slug) + "/source?format=bpml")

	resp, err := c.authGet(u)
	if err != nil {
		return "", "", nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, paperBodyCap))
	if err != nil {
		return "", "", nil, fmt.Errorf("paper pull %s: %w", slug, err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", "", decodePaperErr(resp.StatusCode, body), nil
	}

	rev = resp.Header.Get("x-paper-rev")
	if rev == "" {
		return "", "", nil, fmt.Errorf("paper pull %s: server sent no x-paper-rev anchor", slug)
	}

	return string(body), rev, nil, nil
}

// PaperSync pushes an edited BPML document under the pulled anchor. A nil
// *PaperAPIErr with a nil error means the sync landed (or was a no-op — check
// Unchanged); a non-nil *PaperAPIErr is the server refusing with its reason
// (stale anchor, teaching errors, missing paper), never a transport failure.
func (c *Client) PaperSync(slug, bpml, baseRev string) (*PaperSyncResult, *PaperAPIErr, error) {
	payload, err := json.Marshal(map[string]string{"bpml": bpml, "baseRev": baseRev})
	if err != nil {
		return nil, nil, err
	}

	endpoint := c.flatURL("/v1/plugins/bulldocs/papers/" + url.PathEscape(slug) + "/sync")

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, paperBodyCap))
	if err != nil {
		return nil, nil, fmt.Errorf("paper sync %s: %w", slug, err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, decodePaperErr(resp.StatusCode, body), nil
	}

	var result PaperSyncResult
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, nil, fmt.Errorf("paper sync %s: unparsable receipt: %w", slug, err)
	}
	if !result.OK {
		return nil, nil, fmt.Errorf("paper sync %s: server answered 200 without ok:true", slug)
	}

	return &result, nil, nil
}

func decodePaperErr(status int, body []byte) *PaperAPIErr {
	var env struct {
		Error struct {
			Code    string          `json:"code"`
			Message string          `json:"message"`
			Hint    string          `json:"hint"`
			Errors  []PaperTeachErr `json:"errors"`
		} `json:"error"`
	}

	if err := json.Unmarshal(body, &env); err != nil || env.Error.Code == "" {
		return &PaperAPIErr{Status: status, Code: fmt.Sprintf("http_%d", status), Message: trimForErr(body)}
	}

	return &PaperAPIErr{
		Status:  status,
		Code:    env.Error.Code,
		Message: env.Error.Message,
		Hint:    env.Error.Hint,
		Errors:  env.Error.Errors,
	}
}

func trimForErr(body []byte) string {
	s := string(body)
	if len(s) > 200 {
		return s[:200] + "…"
	}
	return s
}
