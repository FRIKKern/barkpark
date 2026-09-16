package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// THE MEASUREMENT. The paper pane's three resolvers read through
// DataStore.QueryResult, which is an unconditional HTTP GET with no cache layer
// anywhere in the path. This file is the instrument that turns "the render
// blocks on the network" from a claim into a NUMBER: a counting stub transport
// (an httptest server that tallies every /v1/data/query request it serves)
// wrapped around one real buildPaperContent pass over a representative paper.
//
// The representative paper: paperRequestFixture below carries N=4 reference
// nodes, 2 valuerefs and 2 task chips across M=5 schemas. Two orderings were
// measured, because paperRefResolver's per-node scan RETURNS EARLY on the first
// type that holds the id — so the cost depends on where the referenced type
// sits in the schema slice:
//
//	                          before   after
//	referenced type FIRST       10       5
//	referenced type LAST        26       5
//
// 26 is M*N + M + 1, the filing's worst case (one query per schema per
// reference node, plus the valueref sweep, plus the task page). 10 is the same
// paper with the lucky ordering. After the shared per-render cache, both cost
// one page per type: 5.

// countingPaperServer serves one document page for every type and counts the
// query requests it is asked for. The count is the measurement.
type countingPaperServer struct {
	mu     sync.Mutex
	total  int
	byType map[string]int
	srv    *httptest.Server
}

func newCountingPaperServer(t *testing.T) *countingPaperServer {
	t.Helper()
	c := &countingPaperServer{byType: map[string]int{}}
	c.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		typeName := parts[len(parts)-1]
		c.mu.Lock()
		c.total++
		c.byType[typeName]++
		c.mu.Unlock()
		switch typeName {
		case "task":
			_, _ = w.Write([]byte(`{"result":{"documents":[` +
				`{"_id":"task-alpha","_type":"task","title":"Alpha","lifecycle_status":"open"},` +
				`{"_id":"task-beta","_type":"task","title":"Beta","lifecycle_status":"open"}` +
				`]}}`))
		case "person":
			_, _ = w.Write([]byte(`{"result":{"documents":[` +
				`{"_id":"person-1","_type":"person","title":"Ada Lovelace"},` +
				`{"_id":"person-2","_type":"person","title":"Grace Hopper"},` +
				`{"_id":"person-3","_type":"person","title":"Alan Turing"},` +
				`{"_id":"person-4","_type":"person","title":"Barbara Liskov"}` +
				`]}}`))
		default:
			_, _ = w.Write([]byte(`{"result":{"count":0,"documents":[]}}`))
		}
	}))
	t.Cleanup(c.srv.Close)
	return c
}

func (c *countingPaperServer) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.total
}

func (c *countingPaperServer) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.total = 0
	c.byType = map[string]int{}
}

// paperRequestFixture is the representative paper: 4 reference nodes (the
// per-schema-per-node scan's worst case), 2 valuerefs and 2 task chips.
func paperRequestFixture() string {
	var b strings.Builder
	b.WriteString(`{"version":1,"blocks":[`)
	for i := 1; i <= 4; i++ {
		fmt.Fprintf(&b, `{"type":"field-reference","label":"Author %d","value":"person-%d","refType":"person"},`, i, i)
	}
	b.WriteString(`{"type":"paragraph","content":[` +
		`{"type":"valueref","target":"person-1","field":"title","fallback":"pinned-a"},` +
		`{"type":"text","value":" and "},` +
		`{"type":"valueref","target":"person-2","field":"title","fallback":"pinned-b"},` +
		`{"type":"text","value":" track "},` +
		`{"type":"wikilink","target":"task-alpha","docId":"task-alpha"},` +
		`{"type":"text","value":" and "},` +
		`{"type":"wikilink","target":"task-beta","docId":"task-beta"}` +
		`]}]}`)
	return b.String()
}

// paperRequestSchemasFirst puts the referenced type at the HEAD of the scan (the
// lucky ordering, where paperRefResolver's per-node scan returns on its first
// query); paperRequestSchemasLast puts it at the TAIL, the filing's worst case.
var (
	paperRequestSchemasFirst = []Schema{
		{Name: "person", Title: "People"},
		{Name: "task", Title: "Tasks"},
		{Name: "paper", Title: "Papers"},
		{Name: "project", Title: "Projects"},
		{Name: "note", Title: "Notes"},
	}
	paperRequestSchemasLast = []Schema{
		{Name: "task", Title: "Tasks"},
		{Name: "paper", Title: "Papers"},
		{Name: "project", Title: "Projects"},
		{Name: "note", Title: "Notes"},
		{Name: "person", Title: "People"},
	}
)

// paperRequestModel wires a model against the counting server with M=5 schemas.
func paperRequestModel(t *testing.T, c *countingPaperServer, order []Schema) model {
	t.Helper()
	prev := schemas
	t.Cleanup(func() { schemas = prev })
	schemas = order

	theme := barkparkPaperTheme()
	decoded, err := pdrender.Decode([]byte(paperRequestFixture()))
	if err != nil || len(decoded) == 0 {
		t.Fatalf("fixture: block tree did not decode (%v, %d blocks)", err, len(decoded))
	}
	return model{
		ds:                  apiclient.New(apiclient.Config{BaseURL: c.srv.URL, Token: "t", Dataset: "production"}),
		paperTheme:          theme,
		paperProfile:        pdrender.NoColor,
		paperRegistry:       pdrender.DefaultRegistry(theme),
		selectedPaperBlocks: decoded,
	}
}

// THE RED ARM. One render of the representative paper must cost at most ONE
// query per schema. Reverting the shared cache restores the per-node scan and
// this count jumps to 26 — the test fails loudly with the measured number.
func TestPaperRenderCostsOneQueryPerType(t *testing.T) {
	for _, tc := range []struct {
		name  string
		order []Schema
	}{
		{"referenced type first", paperRequestSchemasFirst},
		{"referenced type last (the filing's worst case)", paperRequestSchemasLast},
	} {
		t.Run(tc.name, func(t *testing.T) {
			measureOnePaperRender(t, tc.order)
		})
	}
}

func measureOnePaperRender(t *testing.T, order []Schema) {
	t.Helper()
	c := newCountingPaperServer(t)
	m := paperRequestModel(t, c, order)

	out := m.buildPaperContent(72)
	got := c.count()
	t.Logf("MEASURED: one render of a paper with 4 reference nodes, 2 valuerefs "+
		"and 2 task chips across %d schemas issued %d query requests", len(schemas), got)

	if got > len(schemas) {
		t.Errorf("render issued %d query requests for %d schemas — the resolvers are "+
			"re-querying per reference node", got, len(schemas))
	}
	// Non-vacuous: the render must actually have RESOLVED, or a zero-cost render
	// would pass by rendering nothing.
	for _, want := range []string{"Ada Lovelace", "Grace Hopper", "Alan Turing", "Barbara Liskov"} {
		if !strings.Contains(out, want) {
			t.Errorf("the render did not resolve %q — the count measured a render that did nothing:\n%s", want, out)
		}
	}
	if strings.Contains(out, "Couldn't load") {
		t.Errorf("a fully-served render reported a read failure:\n%s", out)
	}
}
