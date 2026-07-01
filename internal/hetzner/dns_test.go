package hetzner

import (
	"context"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

func (f *fakeHetzner) dns() *DNS {
	return NewDNS(NewClient("test-token",
		WithEndpoint(f.srv.URL),
		WithPollBackoff(time.Millisecond),
	))
}

// TestDNSUpsertCreatesWhenAbsent asserts the create half of the upsert: an
// absent rrset (404 on the get) turns into POST /zones/<zone>/rrsets with the
// record value and TTL.
func TestDNSUpsertCreatesWhenAbsent(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets/acme/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 404, `{"error":{"code":"not_found","message":"rrset not found"}}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 201, `{
			"rrset":{"id":"acme/A","name":"acme","type":"A","ttl":300,"records":[{"value":"192.0.2.10"}],"zone":5},
			"action":{"id":21,"status":"success","progress":100}
		}`)
	})

	err := f.dns().UpsertRecord(context.Background(), cloud.Record{
		Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "192.0.2.10", TTL: 300,
	})
	if err != nil {
		t.Fatalf("UpsertRecord: %v", err)
	}
	req, ok := f.find("POST", "/zones/barkpark.cloud/rrsets")
	if !ok {
		t.Fatal("no POST /zones/barkpark.cloud/rrsets was issued")
	}
	if req.Body["name"] != "acme" || req.Body["type"] != "A" {
		t.Errorf("create body name/type = %v/%v, want acme/A", req.Body["name"], req.Body["type"])
	}
	if req.Body["ttl"] != float64(300) {
		t.Errorf("create body ttl = %v, want 300", req.Body["ttl"])
	}
	records, _ := req.Body["records"].([]any)
	if len(records) != 1 {
		t.Fatalf("create body records = %v, want one", req.Body["records"])
	}
	if rec, _ := records[0].(map[string]any); rec["value"] != "192.0.2.10" {
		t.Errorf("create body record value = %v, want 192.0.2.10", records[0])
	}
}

// TestDNSUpsertReplacesWhenPresent asserts the replace half: an existing rrset
// gets a set_records action with the new value.
func TestDNSUpsertReplacesWhenPresent(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets/acme/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"rrset":{"id":"acme/A","name":"acme","type":"A","records":[{"value":"192.0.2.1"}],"zone":5}}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/acme/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 201, `{"action":{"id":22,"status":"success","progress":100}}`)
	})

	err := f.dns().UpsertRecord(context.Background(), cloud.Record{
		Zone: "barkpark.cloud", Name: "acme", Value: "192.0.2.99",
	})
	if err != nil {
		t.Fatalf("UpsertRecord: %v", err)
	}
	req, ok := f.find("POST", "/zones/barkpark.cloud/rrsets/acme/A/actions/set_records")
	if !ok {
		t.Fatal("no set_records action was issued for the existing rrset")
	}
	records, _ := req.Body["records"].([]any)
	if len(records) != 1 {
		t.Fatalf("set_records body records = %v, want one", req.Body["records"])
	}
	if rec, _ := records[0].(map[string]any); rec["value"] != "192.0.2.99" {
		t.Errorf("set_records record value = %v, want 192.0.2.99", records[0])
	}
}

// TestDNSApexUsesAtName asserts the apex (empty label) addresses the rrset "@".
func TestDNSApexUsesAtName(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets/@/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"rrset":{"id":"@/A","name":"@","type":"A","records":[{"value":"192.0.2.1"}],"zone":5}}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/@/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 201, `{"action":{"id":23,"status":"success","progress":100}}`)
	})
	err := f.dns().UpsertRecord(context.Background(), cloud.Record{
		Zone: "barkpark.cloud", Name: "", Value: "192.0.2.50",
	})
	if err != nil {
		t.Fatalf("apex UpsertRecord: %v", err)
	}
	if _, ok := f.find("POST", "/zones/barkpark.cloud/rrsets/@/A/actions/set_records"); !ok {
		t.Error("apex upsert did not address the '@' rrset")
	}
}

// TestDNSDeleteIsIdempotent asserts a 404 on the delete is swallowed — the
// desired end state (no record) already holds.
func TestDNSDeleteIsIdempotent(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/gone/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 404, `{"error":{"code":"not_found","message":"rrset not found"}}`)
	})
	if err := f.dns().DeleteRecord(context.Background(), "barkpark.cloud", "gone", "A"); err != nil {
		t.Fatalf("DeleteRecord of an absent rrset errored: %v", err)
	}
	if _, ok := f.find("DELETE", "/zones/barkpark.cloud/rrsets/gone/A"); !ok {
		t.Error("no DELETE was issued")
	}
}

// TestDNSResolve asserts the fqdn → (zone, label) split and the sorted values.
func TestDNSResolve(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets/acme/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, `{"rrset":{"id":"acme/A","name":"acme","type":"A","records":[{"value":"192.0.2.9"},{"value":"192.0.2.1"}],"zone":5}}`)
	})
	values, err := f.dns().Resolve(context.Background(), "acme.barkpark.cloud")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if want := []string{"192.0.2.1", "192.0.2.9"}; !reflect.DeepEqual(values, want) {
		t.Errorf("Resolve = %v, want sorted %v", values, want)
	}
}

// TestDNSResolveAbsent asserts an unknown fqdn resolves to an empty (non-nil)
// slice — resolving nothing is not an error, per the seam's contract.
func TestDNSResolveAbsent(t *testing.T) {
	f := newFakeHetzner(t)
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets/ghost/A", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 404, `{"error":{"code":"not_found","message":"rrset not found"}}`)
	})
	values, err := f.dns().Resolve(context.Background(), "ghost.barkpark.cloud")
	if err != nil {
		t.Fatalf("Resolve of an absent fqdn errored: %v", err)
	}
	if values == nil || len(values) != 0 {
		t.Errorf("Resolve = %#v, want an empty non-nil slice", values)
	}
}
