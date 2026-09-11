package cloud

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// cpEdgeFixture is the control plane's committed copy of the canonical Go
// fixture. Path.expand out of internal/cli/cloud/ to the repo root, then down
// into the served fixtures directory — the MIRROR of the path
// edge_capabilities_contract_test.exs walks in the other direction.
const cpEdgeFixture = "../../../cloud/priv/static/__fixtures__/edge_capabilities.json"

// THE NO-SILENT-DROP PROOF (criterion 1).
//
// Two decodes of the SAME fixture bytes: the generic EdgeRow keeps every edge
// key, and the COMPUTE matrix's fixed ProviderRow drops all of them without an
// error. The second half is the CONTROL — without it, "the edge decoder keeps
// its keys" is a claim about a decoder nobody showed could lose them.
func TestEdgeKeysSurviveDecodeAndComputeStructDropsThem(t *testing.T) {
	rows, err := LoadEdgeCapabilities()
	if err != nil {
		t.Fatalf("LoadEdgeCapabilities: %v", err)
	}

	cf, ok := rows["cloudflare"]
	if !ok {
		t.Fatalf("no cloudflare row in edge_capabilities.json; got kinds %v", kindsOf(rows))
	}

	want := map[string]bool{
		"dns":       true,
		"tls":       true,
		"cdn":       true,
		"tunnel":    false,
		"storage":   false,
		"edge_fn":   false,
		"full_host": false,
	}
	if !reflect.DeepEqual(cf.Capabilities, want) {
		t.Fatalf("cloudflare edge capabilities decoded as %v, want %v", cf.Capabilities, want)
	}

	// CONTROL: the fixed compute struct silently loses every one of those keys.
	var compute map[string]ProviderRow
	if err := json.Unmarshal(edgeCapabilitiesFixture, &compute); err != nil {
		t.Fatalf("compute-struct decode of the edge fixture errored (expected a SILENT drop): %v", err)
	}
	computeCF, ok := compute["cloudflare"]
	if !ok {
		t.Fatalf("control decode lost the cloudflare row entirely")
	}
	if computeCF.Capabilities != (Capabilities{}) {
		t.Fatalf("control assumption broken: an edge row populated a compute capability field: %+v", computeCF.Capabilities)
	}
	for key := range want {
		blob, err := json.Marshal(computeCF)
		if err != nil {
			t.Fatalf("marshal control row: %v", err)
		}
		var roundTrip map[string]any
		if err := json.Unmarshal(blob, &roundTrip); err != nil {
			t.Fatalf("unmarshal control row: %v", err)
		}
		if _, survived := roundTrip[key]; survived {
			t.Fatalf("control invalid: edge key %q survived the compute struct, so this test proves nothing", key)
		}
	}
}

// `unknown` is METADATA, never a capability — the same role ProviderRow.Tier
// plays in the compute matrix. A key named there must not reach a surface as a
// bool in either direction.
func TestEdgeUnknownIsMetadataNotACapability(t *testing.T) {
	rows, err := LoadEdgeCapabilities()
	if err != nil {
		t.Fatalf("LoadEdgeCapabilities: %v", err)
	}

	vercel, ok := rows["vercel"]
	if !ok {
		t.Fatalf("no vercel row; got kinds %v", kindsOf(rows))
	}

	if _, leaked := vercel.Capabilities[UnknownEdgeKey]; leaked {
		t.Fatalf("%q leaked into the capability bools: %v", UnknownEdgeKey, vercel.Capabilities)
	}
	if len(vercel.Unknown) == 0 {
		t.Fatalf("vercel row states every edge capability; this repo drives only its deploy seam, so %q may not be empty", UnknownEdgeKey)
	}
	for _, capability := range vercel.Unknown {
		if vercel.Answers(capability) {
			t.Fatalf("vercel claims %q as a bool AND names it unknown — one of the two is a lie", capability)
		}
	}

	// Every kind's stated-plus-unknown key set is the SAME contract: a new edge
	// key cannot be quietly omitted for one provider.
	cf := rows["cloudflare"]
	if got, want := unionKeys(vercel), unionKeys(cf); !reflect.DeepEqual(got, want) {
		t.Fatalf("vercel covers edge keys %v, cloudflare covers %v — every kind must state or explicitly not-know every key", got, want)
	}
}

// A non-bool value that is NOT the `unknown` list is a hard error, never a
// silent drop. Mutation-proves the decoder's own guard.
func TestEdgeRowRejectsANonBoolCapability(t *testing.T) {
	var row EdgeRow
	err := json.Unmarshal([]byte(`{"dns": true, "tls": "yes"}`), &row)
	if err == nil {
		t.Fatalf("a string capability decoded without error: %+v", row)
	}
}

// THE DRIFT LOCK, Go half: this test decodes BOTH copies and asserts the bytes
// are identical, so mutating the ELIXIR copy reds the GO suite. Its twin,
// edge_capabilities_contract_test.exs, does the same in reverse. Either copy
// edited alone reds both suites — the mirror is LOCKED, not merely mirrored.
func TestEdgeFixtureCopyIsByteIdentical(t *testing.T) {
	cpBytes, err := os.ReadFile(filepath.Clean(cpEdgeFixture))
	if err != nil {
		t.Fatalf("read the control plane's copy at %s: %v", cpEdgeFixture, err)
	}

	if string(cpBytes) != string(edgeCapabilitiesFixture) {
		t.Fatalf("cloud/priv/static/__fixtures__/edge_capabilities.json has drifted from "+
			"internal/cli/cloud/edge_capabilities.json — refresh it with a straight `cp` of "+
			"the Go fixture (never hand-edit one side).\ncp copy:\n%s\ngo copy:\n%s",
			cpBytes, edgeCapabilitiesFixture)
	}

	// And the copy must still DECODE to the same rows — byte equality is the
	// gate, term equality is the thing the gate is protecting.
	var cpRows map[string]EdgeRow
	if err := json.Unmarshal(cpBytes, &cpRows); err != nil {
		t.Fatalf("decode the control plane's copy: %v", err)
	}
	goRows, err := LoadEdgeCapabilities()
	if err != nil {
		t.Fatalf("LoadEdgeCapabilities: %v", err)
	}
	if !reflect.DeepEqual(cpRows, goRows) {
		t.Fatalf("the two copies decode differently: cp=%v go=%v", cpRows, goRows)
	}
}

func kindsOf(rows map[string]EdgeRow) []string {
	out := make([]string, 0, len(rows))
	for kind := range rows {
		out = append(out, kind)
	}
	sort.Strings(out)
	return out
}

func unionKeys(row EdgeRow) []string {
	out := append([]string{}, row.Unknown...)
	for key := range row.Capabilities {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}
