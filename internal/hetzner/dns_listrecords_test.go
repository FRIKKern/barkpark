package hetzner

import (
	"context"
	"net/http"
	"reflect"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// zoneRRSetsFixture is the recorded shape of GET /zones/<zone>/rrsets: two
// names at the SAME IP (the go-live sibling pair the by-value sweep exists to
// catch), one name at a different IP, one apex "@", and one non-A rrset.
const zoneRRSetsFixture = `{
  "rrsets": [
    {"id":"acme/A","name":"acme","type":"A","ttl":300,"records":[{"value":"203.0.113.7"}]},
    {"id":"acme-blue/A","name":"acme-blue","type":"A","ttl":300,"records":[{"value":"203.0.113.7"}]},
    {"id":"other/A","name":"other","type":"A","ttl":300,"records":[{"value":"198.51.100.4"}]},
    {"id":"@/A","name":"@","type":"A","ttl":300,"records":[{"value":"203.0.113.7"},{"value":"198.51.100.4"}]},
    {"id":"acme/TXT","name":"acme","type":"TXT","ttl":300,"records":[{"value":"203.0.113.7"}]}
  ],
  "meta": {"pagination": {"page":1,"per_page":50,"previous_page":null,"next_page":null,"last_page":1,"total_entries":5}}
}`

func (f *fakeHetzner) serveZoneRRSets() {
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, zoneRRSetsFixture)
	})
}

// TestDNSListRecordsFlattensRRSets pins the mapping: one Record per (rrset,
// value), the apex "@" back to the EMPTY label, the zone carried on every row.
func TestDNSListRecordsFlattensRRSets(t *testing.T) {
	f := newFakeHetzner(t)
	f.serveZoneRRSets()

	got, err := f.dns().ListRecords(context.Background(), "barkpark.cloud.")
	if err != nil {
		t.Fatalf("ListRecords: %v", err)
	}
	want := []cloud.Record{
		{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "203.0.113.7"},
		{Zone: "barkpark.cloud", Name: "acme-blue", Type: "A", Value: "203.0.113.7"},
		{Zone: "barkpark.cloud", Name: "other", Type: "A", Value: "198.51.100.4"},
		{Zone: "barkpark.cloud", Name: "", Type: "A", Value: "203.0.113.7"},
		{Zone: "barkpark.cloud", Name: "", Type: "A", Value: "198.51.100.4"},
		{Zone: "barkpark.cloud", Name: "acme", Type: "TXT", Value: "203.0.113.7"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ListRecords =\n%#v\nwant\n%#v", got, want)
	}
	if _, ok := f.find("GET", "/zones/barkpark.cloud/rrsets"); !ok {
		t.Fatal("no GET /zones/barkpark.cloud/rrsets was issued — the listing did not reach the API")
	}
}

// TestDNSListRecordsErrorsRatherThanReadsClean is the anti-silence arm for the
// LISTING itself: an API failure must surface, never come back as an empty
// (= "nothing to sweep") slice.
func TestDNSListRecordsErrorsRatherThanReadsClean(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 503, `{"error":{"code":"unavailable","message":"zone service unavailable"}}`)
	})

	got, err := f.dns().ListRecords(context.Background(), "barkpark.cloud")
	if err == nil {
		t.Fatalf("ListRecords swallowed a 503 and returned %#v — a check that cannot list must never read as clean", got)
	}
	if got != nil {
		t.Errorf("ListRecords returned %#v alongside an error, want nil", got)
	}
}

// TestNativeDNSSatisfiesRecordLister is the RUNTIME half of cch-w57-s5's guard,
// pointed at the native provider. cch-w57-s5's table test lives in package
// cloud, which cannot import this package (cloud is imported BY it), so the
// native provider can only be covered from this side.
//
// It observes the PRODUCTION constructor through the DNSProvider interface —
// the same widening deprovisionDNS sees — so a decorator or a swapped body that
// forwards only DNSProvider reds here instead of silently degrading the fleet.
func TestNativeDNSSatisfiesRecordLister(t *testing.T) {
	f := newFakeHetzner(t)
	sites := []struct {
		site     string
		provider cloud.DNSProvider
	}{
		{"internal/hetzner.NewDNS(NewClient(token)) — the BARKPARK_HETZNER_NATIVE DNS flip", f.dns()},
	}
	if len(sites) == 0 {
		t.Fatal("no native DNS constructors listed — the guard would pass vacuously")
	}
	for _, s := range sites {
		if _, ok := s.provider.(cloud.RecordLister); !ok {
			t.Fatalf("%s builds %T, which does NOT satisfy cloud.RecordLister: deprovisionDNS "+
				"would take the by-NAME degrade arm for the whole fleet, leaving custom-domain "+
				"A records pointing at a recycled IP", s.site, s.provider)
		}
	}
}

// TestNativeDNSDrivesTheByValueSweep is the arm that reds if ListRecords is
// reverted: it runs cloud's own by-value sweep helpers THROUGH the native
// provider. Without ListRecords, ARecordNamesByValue returns the "cannot list
// records" error and the sweep deletes nothing — the runtime consequence, not
// just the type assertion.
func TestNativeDNSDrivesTheByValueSweep(t *testing.T) {
	f := newFakeHetzner(t)
	f.serveZoneRRSets()
	for _, name := range []string{"acme", "acme-blue"} {
		f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/"+name+"/A", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, 200, `{"action":{"id":31,"status":"success","progress":100}}`)
		})
	}
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/@/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"action":{"id":32,"status":"success","progress":100}}`)
	})

	names, err := cloud.ARecordNamesByValue(context.Background(), f.dns(), "barkpark.cloud", "203.0.113.7")
	if err != nil {
		t.Fatalf("ARecordNamesByValue through the native provider: %v", err)
	}
	// "" is the apex, which also points at the box IP; "other" (198.51.100.4)
	// and the TXT row must NOT appear.
	want := []string{"", "acme", "acme-blue"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("by-value census = %#v, want %#v", names, want)
	}

	deleted, err := cloud.SweepARecordsByValue(context.Background(), f.dns(), "barkpark.cloud", "203.0.113.7")
	if err != nil {
		t.Fatalf("SweepARecordsByValue through the native provider: %v", err)
	}
	if !reflect.DeepEqual(deleted, want) {
		t.Fatalf("sweep deleted %#v, want %#v", deleted, want)
	}
	if _, ok := f.find("DELETE", "/zones/barkpark.cloud/rrsets/acme-blue/A"); !ok {
		t.Fatal("the go-live sibling acme-blue was never deleted — this is the by-name trap the sweep exists to close")
	}
}

// TestNativeDNSSweepIsQuietOnAnUnrelatedIP is the QUIET arm: an IP no record
// points at sweeps nothing and issues no DELETE. A sweep that deletes on a
// miss would be worse than the degrade it replaces.
func TestNativeDNSSweepIsQuietOnAnUnrelatedIP(t *testing.T) {
	f := newFakeHetzner(t)
	f.serveZoneRRSets()

	deleted, err := cloud.SweepARecordsByValue(context.Background(), f.dns(), "barkpark.cloud", "192.0.2.254")
	if err != nil {
		t.Fatalf("SweepARecordsByValue: %v", err)
	}
	if len(deleted) != 0 {
		t.Fatalf("sweep deleted %#v for an IP no record holds, want nothing", deleted)
	}
	for _, r := range f.requests() {
		if r.Method == "DELETE" {
			t.Fatalf("sweep issued %s %s for an IP no record holds", r.Method, r.Path)
		}
	}
}
