package cli

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// hzServerTypeStockFixture is a recorded-shape GET /server_types response that
// exercises all three per-location stock states in one read:
//
//	cx23    — carries `locations`, in stock at fsn1, out at nbg1  → MEASURED, some
//	cpx11   — carries `locations`, available:false everywhere     → MEASURED, none
//	ccx13   — carries NO `locations` key at all                   → UNMEASURED
//
// The distinction between the last two is the defect class this row names: an
// absence rendered as a false zero. `bp cloud hetzner server-types` must not
// report "out of stock everywhere" for a server type nobody measured.
//
// Note what the fixture does NOT contain: any datacenter-side availability.
// ServerType.Locations is the only source; Datacenter.ServerTypes.Available is
// deprecated and sunsets 2026-10-01.
const hzServerTypeStockFixture = `{"server_types":[
	{"id":1,"name":"cx23","description":"CX23","cores":2,"memory":4,"disk":40,
	 "storage_type":"local","cpu_type":"shared","architecture":"x86",
	 "locations":[
		{"id":1,"name":"fsn1","available":true,"recommended":true,"deprecation":null},
		{"id":2,"name":"nbg1","available":false,"recommended":false,"deprecation":null}
	 ]},
	{"id":2,"name":"cpx11","description":"CPX11","cores":2,"memory":2,"disk":40,
	 "storage_type":"local","cpu_type":"shared","architecture":"x86",
	 "locations":[
		{"id":1,"name":"fsn1","available":false,"recommended":false,"deprecation":null},
		{"id":2,"name":"nbg1","available":false,"recommended":false,"deprecation":null}
	 ]},
	{"id":3,"name":"ccx13","description":"CCX13","cores":2,"memory":8,"disk":80,
	 "storage_type":"local","cpu_type":"dedicated","architecture":"x86"}
]}`

func hzServeStockFixture(t *testing.T) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /server_types", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, hzServerTypeStockFixture)
	})
	return f
}

// hzStockRows runs `server-types -o json` against the fixture and returns the
// rows keyed by server-type name.
func hzStockRows(t *testing.T) map[string]map[string]any {
	t.Helper()
	hzServeStockFixture(t)
	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server-types")
	if code != exitOK {
		t.Fatalf("server-types -o json exited %d, stderr: %s", code, stderr)
	}
	var payload struct {
		ServerTypes []map[string]any `json:"server_types"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, stdout)
	}
	byName := map[string]map[string]any{}
	for _, row := range payload.ServerTypes {
		name, _ := row["name"].(string)
		byName[name] = row
	}
	for _, want := range []string{"cx23", "cpx11", "ccx13"} {
		if _, ok := byName[want]; !ok {
			t.Fatalf("row %q missing from payload:\n%s", want, stdout)
		}
	}
	return byName
}

// TestHetznerServerTypesJSONCarriesPerLocationStock is the RED-on-reversion arm
// for the JSON surface: drop the ServerType.Locations projection and every
// assertion below fails, because the fields simply are not there.
func TestHetznerServerTypesJSONCarriesPerLocationStock(t *testing.T) {
	rows := hzStockRows(t)

	// --- cx23: measured, in stock at fsn1 only ---------------------------
	cx23 := rows["cx23"]
	if known, _ := cx23["availability_known"].(bool); !known {
		t.Errorf("cx23 availability_known = %v, want true (the response carried `locations`)", cx23["availability_known"])
	}
	locs, ok := cx23["locations"].([]any)
	if !ok || len(locs) != 2 {
		t.Fatalf("cx23 locations = %#v, want 2 entries off ServerType.Locations", cx23["locations"])
	}
	got := map[string]bool{}
	for _, l := range locs {
		m, _ := l.(map[string]any)
		name, _ := m["name"].(string)
		avail, _ := m["available"].(bool)
		got[name] = avail
	}
	if !got["fsn1"] || got["nbg1"] {
		t.Errorf("cx23 per-location availability = %v, want fsn1:true nbg1:false", got)
	}
	if at := hzStrings(t, cx23["available_at"]); len(at) != 1 || at[0] != "fsn1" {
		t.Errorf("cx23 available_at = %v, want [fsn1]", at)
	}

	// --- cpx11: MEASURED, out of stock everywhere ------------------------
	cpx11 := rows["cpx11"]
	if known, _ := cpx11["availability_known"].(bool); !known {
		t.Errorf("cpx11 availability_known = %v, want true — the API measured it and the answer was zero", cpx11["availability_known"])
	}
	if l, ok := cpx11["locations"].([]any); !ok || len(l) != 2 {
		t.Errorf("cpx11 locations = %#v, want the 2 measured (unavailable) entries", cpx11["locations"])
	}
	if cpx11["available_at"] == nil {
		t.Errorf("cpx11 available_at is null; a MEASURED empty stock answer must be [], not null")
	}
	if at := hzStrings(t, cpx11["available_at"]); len(at) != 0 {
		t.Errorf("cpx11 available_at = %v, want empty", at)
	}

	// --- ccx13: UNMEASURED ----------------------------------------------
	// The whole point of this row. An absence must not render as a zero.
	ccx13 := rows["ccx13"]
	if known, _ := ccx13["availability_known"].(bool); known {
		t.Errorf("ccx13 availability_known = %v, want false (the response carried no `locations` key)", ccx13["availability_known"])
	}
	if ccx13["locations"] != nil {
		t.Errorf("ccx13 locations = %#v, want null — an unmeasured signal must not be an empty list", ccx13["locations"])
	}
	if ccx13["available_at"] != nil {
		t.Errorf("ccx13 available_at = %#v, want null — an unmeasured signal must not be an empty list", ccx13["available_at"])
	}
}

// TestHetznerServerTypesStockStatesAreDistinguishable is the arm that fails if
// the two failure-shaped states ever collapse: "measured, in stock nowhere" and
// "never measured" must differ in BOTH the JSON and the table. A single shared
// rendering of the two is the defect, however plausible it looks.
func TestHetznerServerTypesStockStatesAreDistinguishable(t *testing.T) {
	rows := hzStockRows(t)
	outOfStock, unmeasured := rows["cpx11"], rows["ccx13"]

	sameField := func(k string) bool {
		a, _ := json.Marshal(outOfStock[k])
		b, _ := json.Marshal(unmeasured[k])
		return string(a) == string(b)
	}
	if sameField("availability_known") && sameField("locations") && sameField("available_at") {
		t.Errorf("out-of-stock-everywhere and unmeasured render identically in JSON:\n  cpx11 = %v\n  ccx13 = %v", outOfStock, unmeasured)
	}

	// Same two facts, table surface.
	hzServeStockFixture(t)
	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "server-types")
	if code != exitOK {
		t.Fatalf("server-types table exited %d, stderr: %s", code, stderr)
	}
	header, cells := hzTableCells(t, stdout)
	if !strings.Contains(header, "AVAILABLE") {
		t.Fatalf("header %q has no AVAILABLE column:\n%s", header, stdout)
	}
	if cells["cx23"] != "fsn1" {
		t.Errorf("cx23 AVAILABLE cell = %q, want %q", cells["cx23"], "fsn1")
	}
	if cells["cpx11"] != "none" {
		t.Errorf("cpx11 (measured, out of stock everywhere) AVAILABLE cell = %q, want %q", cells["cpx11"], "none")
	}
	if cells["ccx13"] != "?" {
		t.Errorf("ccx13 (unmeasured) AVAILABLE cell = %q, want %q", cells["ccx13"], "?")
	}
	if cells["cpx11"] == cells["ccx13"] {
		t.Errorf("out-of-stock-everywhere and unmeasured render the same table cell %q — an absence is being reported as a zero", cells["cpx11"])
	}
}

// TestHetznerServerTypesIgnoresDatacenterAvailability is the source-discipline
// arm. The deprecated Datacenter-side availability list (sunsets 2026-10-01)
// must never feed this surface: it says cx23 is in stock at nbg1, and the
// ServerType.Locations truth says it is not. The command must never read it —
// and, being a `server-types` read, must not even call GET /datacenters.
func TestHetznerServerTypesIgnoresDatacenterAvailability(t *testing.T) {
	f := hzServeStockFixture(t)
	f.mux.HandleFunc("GET /datacenters", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"datacenters":[
			{"id":1,"name":"fsn1-dc14","location":{"id":1,"name":"fsn1"},
			 "server_types":{"supported":[1,2,3],"available":[1,2,3],"available_for_migration":[1,2,3]}},
			{"id":2,"name":"nbg1-dc3","location":{"id":2,"name":"nbg1"},
			 "server_types":{"supported":[1,2,3],"available":[1,2,3],"available_for_migration":[1,2,3]}}
		]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "server-types")
	if code != exitOK {
		t.Fatalf("server-types -o json exited %d, stderr: %s", code, stderr)
	}
	if f.count("GET", "/datacenters") != 0 {
		t.Errorf("server-types issued GET /datacenters — the deprecated datacenter-side availability must never source this surface")
	}
	var payload struct {
		ServerTypes []map[string]any `json:"server_types"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, stdout)
	}
	for _, row := range payload.ServerTypes {
		if name, _ := row["name"].(string); name != "cx23" {
			continue
		}
		at := hzStrings(t, row["available_at"])
		for _, loc := range at {
			if loc == "nbg1" {
				t.Errorf("cx23 available_at includes nbg1 — that is the DEPRECATED datacenter-side answer; ServerType.Locations says available:false there")
			}
		}
		if len(at) != 1 || at[0] != "fsn1" {
			t.Errorf("cx23 available_at = %v, want [fsn1] straight off ServerType.Locations", at)
		}
	}
}

// hzStrings unpacks a JSON string array (or nil) into a Go slice.
func hzStrings(t *testing.T, v any) []string {
	t.Helper()
	if v == nil {
		return nil
	}
	raw, ok := v.([]any)
	if !ok {
		t.Fatalf("value %#v is not a JSON array", v)
	}
	out := make([]string, 0, len(raw))
	for _, e := range raw {
		s, _ := e.(string)
		out = append(out, s)
	}
	return out
}

// hzTableCells splits the rendered server-types table into its header line and
// a name → AVAILABLE (last column) map.
//
// The AVAILABLE column is last, so it is read by slicing at the header's own
// column offset and trimming — never by Fields()[n], which would silently
// re-split a multi-word cell, and never by a width assertion on the whole
// group, which right-padding can satisfy while the cell itself is wrong.
func hzTableCells(t *testing.T, stdout string) (string, map[string]string) {
	t.Helper()
	lines := strings.Split(strings.TrimRight(stdout, "\n"), "\n")
	if len(lines) < 2 {
		t.Fatalf("table has %d lines, want a header + rows:\n%s", len(lines), stdout)
	}
	header := lines[0]
	col := strings.Index(header, "AVAILABLE")
	if col < 0 {
		return header, nil
	}
	cells := map[string]string{}
	for _, line := range lines[1:] {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		name := fields[1]
		if col >= len(line) {
			cells[name] = ""
			continue
		}
		cells[name] = strings.TrimSpace(line[col:])
	}
	return header, cells
}

// TestHetznerServerTypesStockRenderSnapshot pins the rendered table so a future
// reader sees the three states side by side rather than inferring them.
func TestHetznerServerTypesStockRenderSnapshot(t *testing.T) {
	hzServeStockFixture(t)
	stdout, _, code := runHzCLI(t, "table", "hetzner", "server-types")
	if code != exitOK {
		t.Fatalf("exit %d", code)
	}
	want := strings.Join([]string{
		"ID  NAME   CORES  MEMORY  DISK   CPU        ARCH  AVAILABLE",
		"1   cx23   2      4 GB    40 GB  shared     x86   fsn1",
		"2   cpx11  2      2 GB    40 GB  shared     x86   none",
		"3   ccx13  2      8 GB    80 GB  dedicated  x86   ?",
	}, "\n") + "\n"
	if stdout != want {
		t.Errorf("table render drifted.\n got:\n%s\nwant:\n%s", stdout, want)
	}
}
