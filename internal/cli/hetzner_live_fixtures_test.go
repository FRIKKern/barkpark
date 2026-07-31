package cli

// hetzner_live_fixtures_test.go — THE PERMANENT RESIDUE OF THE EPIC'S FIRST L1.
//
// scripts/pds-live-hetzner-placement-group.sh drove a real bp verb against the
// real api.hetzner.cloud on 2026-07-31 and harvested the bodies it saw into
// testdata/pds_live_hetzner_*.json. That run needed a live credential and a live
// project; this test needs neither. It is how the perishable half of a live proof
// leaves something that rides CI forever.
//
// WHAT THESE ASSERTIONS ARE FOR — PDS-D401. hzResDestroyed's clean "(nil, nil) =
// gone" arm rests on a production assumption stated in hetzner_respost.go's own
// header: that the API answers a missing resource with a JSON 404. hcloud-go's
// errorFromBody returns nil unless hasJSONBody(), so a text/plain 404 would land
// in the "confirmation unavailable" arm instead — the destroy would report "not
// confirmed" on a perfectly successful delete. For twenty-nine waves that was an
// ASSUMPTION. These bytes are the measurement.
//
// WHY THERE IS NO UNIVERSAL BYTE-COUNT ASSERTION. The message is per resource
// kind: "placement group not found" is 100 bytes on the wire where the server's
// "server not found" is 91. A single len() constant across kinds would be a
// fixture-shaped lie. Every count is asserted PER ENTRY, from the manifest that
// recorded what each body actually came from.
//
// WHAT THIS TEST DOES NOT PROVE. It does not prove the refusal direction (a
// lying API that keeps returning a deleted resource) — that stays covered by the
// LYING-FAKE cases in hetzner_respost_test.go, and cannot be staged against a
// correct API at all. It proves that the bytes the apparatus reasons about are
// the bytes production actually sends.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

type pdsLiveFixture struct {
	File        string `json:"file"`
	Kind        string `json:"kind"`
	Request     string `json:"request"`
	HTTPStatus  int    `json:"http_status"`
	ContentType string `json:"content_type"`
	Bytes       int    `json:"bytes"`
	ErrorCode   string `json:"error_code"`
	Note        string `json:"note"`
}

type pdsLiveManifest struct {
	HarvestedAt string           `json:"harvested_at"`
	HarvestedBy string           `json:"harvested_by"`
	API         string           `json:"api"`
	Fixtures    []pdsLiveFixture `json:"fixtures"`
}

func loadPDSLiveManifest(t *testing.T) pdsLiveManifest {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "pds_live_hetzner_fixtures.json"))
	if err != nil {
		t.Fatalf("read the live-proof manifest: %v", err)
	}
	var m pdsLiveManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse the live-proof manifest: %v", err)
	}
	if len(m.Fixtures) == 0 {
		t.Fatal("the live-proof manifest lists no fixtures — an empty manifest would make every assertion below vacuously true")
	}
	if m.HarvestedBy == "" || m.HarvestedAt == "" {
		t.Fatal("the manifest does not say when it was harvested or by what — an undated body is not evidence")
	}
	return m
}

// TestPDSLiveFixturesRecordTheirOwnKindAndLength pins each harvested body to the
// kind and byte count the live run measured, ONE ENTRY AT A TIME. A fixture
// edited by hand (or re-harvested from a different kind) fails here rather than
// silently changing what the other tests are reasoning about.
func TestPDSLiveFixturesRecordTheirOwnKindAndLength(t *testing.T) {
	m := loadPDSLiveManifest(t)
	seen := map[string]bool{}
	for _, f := range m.Fixtures {
		if f.File == "" || f.Kind == "" {
			t.Errorf("manifest entry %+v does not name both a file and the KIND it came from", f)
			continue
		}
		if seen[f.File] {
			t.Errorf("%s is listed twice in the manifest", f.File)
		}
		seen[f.File] = true

		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Errorf("%s: %v", f.File, err)
			continue
		}
		if got := len(body); got != f.Bytes {
			t.Errorf("%s (%s): manifest records %d bytes, the file on disk is %d — the manifest and the harvested body have drifted apart",
				f.File, f.Kind, f.Bytes, got)
		}
		if f.ContentType != "application/json" {
			t.Errorf("%s: content_type %q — every harvested body is a JSON body", f.File, f.ContentType)
		}
		var any map[string]any
		if err := json.Unmarshal(body, &any); err != nil {
			t.Errorf("%s: not JSON at all: %v", f.File, err)
		}
	}
}

// TestPDSLive404sAreJSONNotFound is PDS-D401's measurement: production answers a
// missing resource with a JSON body carrying error.code = not_found, which is
// exactly the condition under which hcloud-go returns the clean (nil, nil) that
// hzResDestroyed reads as "gone".
func TestPDSLive404sAreJSONNotFound(t *testing.T) {
	m := loadPDSLiveManifest(t)
	n := 0
	for _, f := range m.Fixtures {
		if f.HTTPStatus != 404 {
			continue
		}
		n++
		body, err := os.ReadFile(filepath.Join("testdata", f.File))
		if err != nil {
			t.Fatalf("%s: %v", f.File, err)
		}
		var env struct {
			Error struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(body, &env); err != nil {
			t.Fatalf("%s: the real 404 body does not parse as JSON: %v", f.File, err)
		}
		if env.Error.Code != "not_found" {
			t.Errorf("%s (%s): error.code = %q, want not_found — hzResDestroyed's gone arm reasons about this exact shape",
				f.File, f.Kind, env.Error.Code)
		}
		if env.Error.Message == "" {
			t.Errorf("%s: the 404 carries no message", f.File)
		}
		if f.ErrorCode != env.Error.Code {
			t.Errorf("%s: the manifest records error_code=%q but the body says %q", f.File, f.ErrorCode, env.Error.Code)
		}
	}
	if n < 2 {
		t.Fatalf("only %d harvested 404 bodies — the point of harvesting two KINDS is that one kind cannot establish the shape is uniform", n)
	}
}

// TestPDSLive404LengthsDifferByKind is the guard against the assertion somebody
// will eventually be tempted to write: a single byte count for "the 404 body".
// The two kinds measured live differ (100 vs 91), and this test fails if a future
// edit makes them equal — at which point a universal count would look defensible
// and would still be wrong for the eight kinds nobody harvested.
func TestPDSLive404LengthsDifferByKind(t *testing.T) {
	m := loadPDSLiveManifest(t)
	byKind := map[string]int{}
	for _, f := range m.Fixtures {
		if f.HTTPStatus == 404 {
			byKind[f.Kind] = f.Bytes
		}
	}
	if len(byKind) < 2 {
		t.Fatalf("need 404 bodies from at least two kinds, have %d", len(byKind))
	}
	lengths := map[int]string{}
	for kind, n := range byKind {
		if other, dup := lengths[n]; dup {
			t.Errorf("the %s and %s 404 bodies are both %d bytes — do not let that tempt a universal byte-count assertion; the message is per kind",
				other, kind, n)
		}
		lengths[n] = kind
	}
}

// TestPDSLiveFixturesCarryNoCredential is the PDS-D102 discipline applied to this
// slice's own output: assert over the committed bytes rather than trusting the
// author who committed them. The live runs spent a 64-character Hetzner token and
// a Barkpark admin token; neither may have leaked into the residue.
func TestPDSLiveFixturesCarryNoCredential(t *testing.T) {
	entries, err := filepath.Glob(filepath.Join("testdata", "pds_live_*"))
	if err != nil || len(entries) == 0 {
		t.Fatalf("no pds_live_* fixtures found to scan (err=%v)", err)
	}
	// A 32+ character unbroken hex/base64-ish run is what every credential in
	// this repo looks like; document ids and revs are shorter or hyphenated.
	secretish := regexp.MustCompile(`[A-Za-z0-9]{32,}`)
	bearer := regexp.MustCompile(`(?i)bearer\s+\S+|authorization`)
	for _, path := range entries {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if m := secretish.Find(body); m != nil {
			t.Errorf("%s contains a %d-character unbroken alphanumeric run (%q…) — that is the shape of a credential, not of a harvested API body",
				path, len(m), string(m[:8]))
		}
		if m := bearer.Find(body); m != nil {
			t.Errorf("%s mentions %q — no authorization material belongs in a committed fixture", path, string(m))
		}
	}
}
