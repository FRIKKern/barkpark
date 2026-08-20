package apiclient

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var (
	releasePaperUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	releasePaperETag = regexp.MustCompile(`^"sha256:[0-9a-f]{64}"$`)
	releasePaperSHA  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// ReleasePaperRef is the complete immutable address of one prospective Paper
// reader. ReleaseGateID selects the admission; RevisionID pins that gate's
// exact reserved/target Wave revision and is sent as the server's
// wave_revision query parameter.
type ReleasePaperRef struct {
	Origin        string
	Workspace     string
	Project       string
	EpicID        string
	WaveID        string
	ReleaseGateID string
	RevisionID    string
	CandidateID   string
	Role          string
}

func (r ReleasePaperRef) validate() error {
	for _, field := range []struct {
		name  string
		value string
	}{
		{"epic_id", r.EpicID}, {"wave_id", r.WaveID},
	} {
		if !releasePaperRouteSegment(field.value) {
			return fmt.Errorf("release Paper %s is not a stable route segment", field.name)
		}
	}
	for _, field := range []struct {
		name  string
		value string
	}{
		{"workspace", r.Workspace}, {"project", r.Project},
	} {
		if field.value != "" && !releasePaperRouteSegment(field.value) {
			return fmt.Errorf("release Paper %s is not a stable route segment", field.name)
		}
	}
	if !releasePaperUUID.MatchString(r.ReleaseGateID) {
		return fmt.Errorf("release Paper release_gate_id is invalid")
	}
	if !releasePaperUUID.MatchString(r.RevisionID) {
		return fmt.Errorf("release Paper revision_id is invalid")
	}
	if !releasePaperUUID.MatchString(r.CandidateID) {
		return fmt.Errorf("release Paper candidate_id is invalid")
	}
	if r.Role != "campaign" && r.Role != "successor" {
		return fmt.Errorf("release Paper role must be campaign or successor")
	}
	return nil
}

func releasePaperRouteSegment(value string) bool {
	if strings.TrimSpace(value) == "" || strings.TrimSpace(value) != value ||
		value == "." || value == ".." || strings.ContainsAny(value, `/\`) {
		return false
	}
	for _, char := range value {
		if char < 0x20 || char == 0x7f {
			return false
		}
	}
	return true
}

// ParseReleasePaperRef recognizes only the canonical, fully scoped release
// source URL. A URL that starts naming this route but is incomplete is an
// error, never a signal to retry the mutable Paper slug route.
func ParseReleasePaperRef(value string) (ReleasePaperRef, bool, error) {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return ReleasePaperRef{}, false, nil
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return ReleasePaperRef{}, false, nil
	}
	segments := strings.Split(strings.Trim(parsed.EscapedPath(), "/"), "/")
	looksRelease := len(segments) > 8 && segments[4] == "v1" && segments[5] == "cycles" && segments[8] == "release-gates"
	if !looksRelease {
		return ReleasePaperRef{}, false, nil
	}
	if len(segments) != 13 || segments[0] != "w" || segments[2] != "p" ||
		segments[10] != "papers" || segments[12] != "source" || parsed.User != nil || parsed.Fragment != "" {
		return ReleasePaperRef{}, true, fmt.Errorf("release Paper reference has an invalid canonical path")
	}
	decoded := make([]string, len(segments))
	for i, segment := range segments {
		decoded[i], err = url.PathUnescape(segment)
		if err != nil {
			return ReleasePaperRef{}, true, fmt.Errorf("release Paper reference path is invalid")
		}
	}
	query, err := url.ParseQuery(parsed.RawQuery)
	if err != nil {
		return ReleasePaperRef{}, true, fmt.Errorf("release Paper reference query is invalid")
	}
	if len(query) != 2 || len(query["wave_revision"]) != 1 || len(query["candidate_id"]) != 1 {
		return ReleasePaperRef{}, true, fmt.Errorf("release Paper reference requires exact wave_revision and candidate_id pins")
	}
	ref := ReleasePaperRef{
		Origin: parsed.Scheme + "://" + parsed.Host, Workspace: decoded[1], Project: decoded[3],
		EpicID: decoded[6], WaveID: decoded[7], ReleaseGateID: decoded[9],
		RevisionID: query.Get("wave_revision"), CandidateID: query.Get("candidate_id"), Role: decoded[11],
	}
	if err := ref.validate(); err != nil {
		return ReleasePaperRef{}, true, err
	}
	return ref, true, nil
}

// ReleasePaperSource is the immutable server envelope plus its canonical Paper
// projection. Raw retains the bytes used for release evidence.
type ReleasePaperSource struct {
	PaperSource
	Raw           json.RawMessage
	ReleaseGateID string
	WaveRevision  string
	CandidateID   string
	Role          string
	DocumentID    string
	DocID         string
	ContentDigest string
}

// PaperReleaseSource reads one server-resolved Paper candidate without any
// mutable-slug, alternate-origin, or alternate-scope fallback.
func (c *Client) PaperReleaseSource(ref ReleasePaperRef) (ReleasePaperSource, error) {
	if err := ref.validate(); err != nil {
		return ReleasePaperSource{}, err
	}
	if ref.Origin != "" && strings.TrimRight(ref.Origin, "/") != strings.TrimRight(c.baseURL, "/") {
		return ReleasePaperSource{}, fmt.Errorf("release Paper origin does not match configured server")
	}
	if ref.Workspace != "" && ref.Workspace != c.Workspace {
		return ReleasePaperSource{}, fmt.Errorf("release Paper workspace does not match configured scope")
	}
	if ref.Project != "" && ref.Project != c.Project {
		return ReleasePaperSource{}, fmt.Errorf("release Paper project does not match configured scope")
	}

	path := "/v1/cycles/" + url.PathEscape(ref.EpicID) + "/" + url.PathEscape(ref.WaveID) +
		"/release-gates/" + url.PathEscape(ref.ReleaseGateID) + "/papers/" + url.PathEscape(ref.Role) + "/source"
	query := url.Values{
		"wave_revision": []string{ref.RevisionID},
		"candidate_id":  []string{ref.CandidateID},
	}
	endpoint := c.scopedURL(path) + "?" + query.Encode()
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return ReleasePaperSource{}, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	httpClient := *c.client
	httpClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := httpClient.Do(req)
	if err != nil {
		return ReleasePaperSource{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
		return ReleasePaperSource{}, fmt.Errorf("release Paper source: status %d: %s", resp.StatusCode, bodyPreview(body))
	}
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(resp.Header.Get("Content-Type"), ";")[0]))
	if contentType != "application/json" {
		return ReleasePaperSource{}, fmt.Errorf("release Paper source Content-Type must be application/json")
	}

	headers := map[string]string{
		"ETag":                       resp.Header.Get("ETag"),
		"X-Barkpark-Release-Gate":    resp.Header.Get("X-Barkpark-Release-Gate"),
		"X-Barkpark-Wave-Revision":   resp.Header.Get("X-Barkpark-Wave-Revision"),
		"X-Barkpark-Paper-Candidate": resp.Header.Get("X-Barkpark-Paper-Candidate"),
		"X-Barkpark-Paper-Role":      resp.Header.Get("X-Barkpark-Paper-Role"),
	}
	if !releasePaperETag.MatchString(headers["ETag"]) ||
		headers["X-Barkpark-Release-Gate"] != ref.ReleaseGateID ||
		headers["X-Barkpark-Wave-Revision"] != ref.RevisionID ||
		headers["X-Barkpark-Paper-Candidate"] != ref.CandidateID ||
		headers["X-Barkpark-Paper-Role"] != ref.Role {
		return ReleasePaperSource{}, fmt.Errorf("release Paper response pin headers are missing or drifted")
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDocBytes+1))
	if err != nil {
		return ReleasePaperSource{}, fmt.Errorf("release Paper source: read body: %w", err)
	}
	if int64(len(body)) > maxDocBytes {
		return ReleasePaperSource{}, fmt.Errorf("release Paper source: body exceeds %d bytes", maxDocBytes)
	}
	var payload struct {
		ReleaseGateID string `json:"release_gate_id"`
		WaveRevision  string `json:"wave_revision"`
		CandidateID   string `json:"candidate_id"`
		Role          string `json:"role"`
		DocumentID    string `json:"document_id"`
		DocID         string `json:"doc_id"`
		Title         string `json:"title"`
		ContentDigest string `json:"content_digest"`
		Source        struct {
			Kind   string          `json:"kind"`
			Blocks json.RawMessage `json:"blocks"`
		} `json:"source"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return ReleasePaperSource{}, fmt.Errorf("release Paper source: decode: %w", err)
	}
	if payload.ReleaseGateID != ref.ReleaseGateID || payload.WaveRevision != ref.RevisionID ||
		payload.CandidateID != ref.CandidateID || payload.CandidateID != headers["X-Barkpark-Paper-Candidate"] || payload.Role != ref.Role ||
		!releasePaperUUID.MatchString(payload.DocumentID) || strings.TrimSpace(payload.DocID) == "" ||
		!releasePaperSHA.MatchString(payload.ContentDigest) || payload.Source.Kind != "blocks" ||
		len(bytes.TrimSpace(payload.Source.Blocks)) == 0 || !json.Valid(payload.Source.Blocks) {
		return ReleasePaperSource{}, fmt.Errorf("release Paper source envelope is missing or drifted")
	}
	if headers["ETag"] != `"sha256:`+payload.ContentDigest+`"` {
		return ReleasePaperSource{}, fmt.Errorf("release Paper ETag drifted from content digest")
	}
	return ReleasePaperSource{
		PaperSource: PaperSource{ID: payload.DocID, Title: payload.Title, Rev: payload.CandidateID,
			Kind: payload.Source.Kind, Blocks: payload.Source.Blocks},
		Raw: body, ReleaseGateID: payload.ReleaseGateID, WaveRevision: payload.WaveRevision,
		CandidateID: payload.CandidateID, Role: payload.Role, DocumentID: payload.DocumentID,
		DocID: payload.DocID, ContentDigest: payload.ContentDigest,
	}, nil
}
