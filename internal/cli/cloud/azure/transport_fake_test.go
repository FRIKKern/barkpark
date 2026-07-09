package azure

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fakeResponse is the committed on-disk shape of one recorded HTTP response: an
// ARM/AAD status, the headers that matter to the SDK (LRO Azure-AsyncOperation /
// Location, Content-Type), and the JSON body. Fixtures live under fixtures/ and
// are the SOLE source of truth for what the SDK "sees" — no bytes are synthesized
// in code, so a fixture edit is a reviewable diff.
type fakeResponse struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    json.RawMessage   `json:"body,omitempty"`
}

// fakeRoute maps a request (method + lowercased-URL substring predicates) to an
// ORDERED list of fixture files. A route hit N times serves fixtures[N] and
// clamps at the last — so a single route drives an LRO poll sequence (e.g. a VM
// GET that reads "Creating" then "Succeeded") straight from committed files.
type fakeRoute struct {
	name     string
	method   string   // "" matches any method
	contains []string // ALL must appear in the lowercased URL
	absent   []string // NONE may appear in the lowercased URL
	fixtures []string // fixture basenames, served in order (last repeats)
}

// fakeTransport is a policy.Transporter that replays committed fixtures with ZERO
// network access. It is the Azure analogue of the cloud package's runCapture
// recorder: inject it via WithTransport and every ARM client + the credential's
// token exchange resolve against fixtures/. An unmatched request fails the test
// loudly (a missing fixture is a bug, never a silent pass).
type fakeTransport struct {
	t      *testing.T
	dir    string
	routes []fakeRoute

	mu    sync.Mutex
	calls map[string]int
	log   []loggedRequest
}

type loggedRequest struct {
	Method string
	URL    string
	Route  string
	Body   string // the request body bytes, captured so a test can assert what was SENT
}

func newFakeTransport(t *testing.T, routes []fakeRoute) *fakeTransport {
	t.Helper()
	return &fakeTransport{t: t, dir: fixturesDir(t), routes: routes, calls: map[string]int{}}
}

func fixturesDir(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return filepath.Join(wd, "fixtures")
}

func (ft *fakeTransport) Do(req *http.Request) (*http.Response, error) {
	// Drain the request body so a caller that inspects it later can't block, and
	// CAPTURE it: the fake replays fixtures for responses, but a test may still need
	// to assert on what the SDK SENT (e.g. that a Tags PATCH carries barkpark-fqdn).
	var reqBody []byte
	if req.Body != nil {
		reqBody, _ = io.ReadAll(req.Body)
		_ = req.Body.Close()
	}
	lower := strings.ToLower(req.URL.String())

	ft.mu.Lock()
	defer ft.mu.Unlock()

	for _, r := range ft.routes {
		if r.method != "" && !strings.EqualFold(r.method, req.Method) {
			continue
		}
		if !allContain(lower, r.contains) || anyContain(lower, r.absent) {
			continue
		}
		ft.log = append(ft.log, loggedRequest{Method: req.Method, URL: req.URL.String(), Route: r.name, Body: string(reqBody)})
		idx := ft.calls[r.name]
		ft.calls[r.name]++
		if idx >= len(r.fixtures) {
			idx = len(r.fixtures) - 1
		}
		return ft.buildResponse(req, r.fixtures[idx])
	}

	ft.t.Fatalf("fakeTransport: no route for %s %s (add a fixture route)", req.Method, req.URL.String())
	return nil, fmt.Errorf("no route")
}

func (ft *fakeTransport) buildResponse(req *http.Request, fixture string) (*http.Response, error) {
	raw, err := os.ReadFile(filepath.Join(ft.dir, fixture))
	if err != nil {
		ft.t.Fatalf("fakeTransport: read fixture %q: %v", fixture, err)
	}
	var fr fakeResponse
	if err := json.Unmarshal(raw, &fr); err != nil {
		ft.t.Fatalf("fakeTransport: parse fixture %q: %v", fixture, err)
	}
	body := []byte(fr.Body)
	h := http.Header{}
	h.Set("Content-Type", "application/json")
	for k, v := range fr.Headers {
		h.Set(k, v)
	}
	status := fr.Status
	if status == 0 {
		status = 200
	}
	return &http.Response{
		StatusCode:    status,
		Status:        fmt.Sprintf("%d %s", status, http.StatusText(status)),
		Header:        h,
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
		Request:       req,
	}, nil
}

// hits returns how many times a named route was served — lets a test assert, for
// example, that the failed-create path DID call the VM delete.
func (ft *fakeTransport) hits(route string) int {
	ft.mu.Lock()
	defer ft.mu.Unlock()
	return ft.calls[route]
}

// lastBody returns the captured request body of the most recent hit on a named
// route (empty if the route was never served) — so a test can assert what the SDK
// actually PUT/PATCHed, not just how many times.
func (ft *fakeTransport) lastBody(route string) string {
	ft.mu.Lock()
	defer ft.mu.Unlock()
	for i := len(ft.log) - 1; i >= 0; i-- {
		if ft.log[i].Route == route {
			return ft.log[i].Body
		}
	}
	return ""
}

func allContain(s string, subs []string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}

func anyContain(s string, subs []string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// ── shared route tables ──────────────────────────────────────────────────────

// authRoutes serve the credential's token exchange: tenant discovery
// (openid-configuration) then the client-credentials token POST. MSAL caches the
// token, so these are hit once per provider regardless of how many ARM calls run.
func authRoutes() []fakeRoute {
	return []fakeRoute{
		{name: "auth-oidc", method: "GET", contains: []string{"openid-configuration"}, fixtures: []string{"openid_configuration.json"}},
		{name: "auth-token", method: "POST", contains: []string{"/oauth2/v2.0/token"}, fixtures: []string{"token.json"}},
	}
}

// createRoutes drive a full Create→LRO→ip-readback. The RG PUT is disambiguated
// from resource PUTs by the ABSENCE of a "providers" segment (the RG client uses
// the lowercase ".../resourcegroups/<rg>" path with no provider). The VM GET
// serves a genuine two-step poll: Creating, then Succeeded.
func createRoutes() []fakeRoute {
	rs := authRoutes()
	rs = append(rs,
		fakeRoute{name: "rg-put", method: "PUT", contains: []string{"/resourcegroups/"}, absent: []string{"providers"}, fixtures: []string{"resource_group_put.json"}},
		fakeRoute{name: "vnet-put", method: "PUT", contains: []string{"/virtualnetworks/"}, fixtures: []string{"vnet_put.json"}},
		fakeRoute{name: "pip-put", method: "PUT", contains: []string{"/publicipaddresses/"}, fixtures: []string{"publicip_put.json"}},
		fakeRoute{name: "pip-get", method: "GET", contains: []string{"/publicipaddresses/"}, fixtures: []string{"publicip_get.json"}},
		fakeRoute{name: "nic-put", method: "PUT", contains: []string{"/networkinterfaces/"}, fixtures: []string{"nic_put.json"}},
		fakeRoute{name: "vm-put", method: "PUT", contains: []string{"/virtualmachines/"}, fixtures: []string{"vm_put.json"}},
		fakeRoute{name: "vm-get", method: "GET", contains: []string{"/virtualmachines/"}, fixtures: []string{"vm_get_creating.json", "vm_get_succeeded.json"}},
	)
	return rs
}

// deleteRoutes serve idempotent per-box teardown (VM → NIC → PublicIP), each a
// 200 with no LRO headers so the poller completes on the first response.
func deleteRoutes() []fakeRoute {
	return []fakeRoute{
		{name: "vm-delete", method: "DELETE", contains: []string{"/virtualmachines/"}, fixtures: []string{"delete_ok.json"}},
		{name: "nic-delete", method: "DELETE", contains: []string{"/networkinterfaces/"}, fixtures: []string{"delete_ok.json"}},
		{name: "pip-delete", method: "DELETE", contains: []string{"/publicipaddresses/"}, fixtures: []string{"delete_ok.json"}},
	}
}

// tagRoute serves the TagsClient.UpdateAtScope PATCH (both Merge and Delete land
// on .../providers/Microsoft.Resources/tags/default).
func tagRoute() fakeRoute {
	return fakeRoute{name: "tags-patch", method: "PATCH", contains: []string{"/providers/microsoft.resources/tags/default"}, fixtures: []string{"tags_default.json"}}
}

// listRoute serves the generic resources list pager (List / ListByLabel).
func listRoute() fakeRoute {
	return fakeRoute{name: "resources-list", method: "GET", contains: []string{"/subscriptions/", "/resources"}, absent: []string{"resourcegroups"}, fixtures: []string{"resources_list.json"}}
}

// powerRoutes serve a deallocate/start POST as an async-operation LRO: the POST
// is 202 with an Azure-AsyncOperation header, and the operation GET reports
// Succeeded on the first poll.
func powerRoutes() []fakeRoute {
	return []fakeRoute{
		{name: "vm-deallocate", method: "POST", contains: []string{"/deallocate"}, fixtures: []string{"power_op_accepted.json"}},
		{name: "vm-start", method: "POST", contains: []string{"/virtualmachines/", "/start"}, fixtures: []string{"power_op_accepted.json"}},
		{name: "async-op", method: "GET", contains: []string{"/operations/"}, fixtures: []string{"operation_succeeded.json"}},
	}
}
