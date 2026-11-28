package apiclient

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
)

// PaperCarriedItem names one list item a push carries back that the pulled
// BPML does not show all of: its top-level block id and its item id.
type PaperCarriedItem struct {
	Block string `json:"block"`
	Item  string `json:"item"`
}

// PaperCarried reads every list item of the paper's view that a push carries
// back and the print does not show all of (the source route's
// format=carried). rev and view are the read's x-paper-rev and x-bpml-view:
// equal to a pull's when the read names that pull's view. count is the whole
// count the server answers; the list holds every one, never a page.
func (c *Client) PaperCarried(slug string) (items []PaperCarriedItem, count int, rev string, view string, apiErr *PaperAPIErr, err error) {
	u := c.flatURL("/papers/" + url.PathEscape(slug) + "/source?format=carried")

	resp, err := c.authGet(u)
	if err != nil {
		return nil, 0, "", "", nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, paperBodyCap))
	if err != nil {
		return nil, 0, "", "", nil, fmt.Errorf("paper carried %s: %w", slug, err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, 0, "", "", decodePaperErr(resp.StatusCode, body), nil
	}

	var answer struct {
		Count   int                `json:"count"`
		Carried []PaperCarriedItem `json:"carried"`
	}
	if err := json.Unmarshal(body, &answer); err != nil {
		return nil, 0, "", "", nil, fmt.Errorf("paper carried %s: %w", slug, err)
	}

	return answer.Carried, answer.Count, resp.Header.Get("x-paper-rev"), resp.Header.Get("x-bpml-view"), nil, nil
}

// carriedCount reads x-bpml-carried-count: -1 when the server sent none.
func carriedCount(header string) (int, error) {
	if header == "" {
		return -1, nil
	}
	n, err := strconv.Atoi(header)
	if err != nil || n < 0 {
		return -1, fmt.Errorf("server sent an unreadable x-bpml-carried-count %q", header)
	}
	return n, nil
}
