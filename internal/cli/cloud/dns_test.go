package cloud

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

// TestFqdn asserts the label+zone join, including the trailing-dot and apex
// edge cases callers rely on.
func TestFqdn(t *testing.T) {
	tests := []struct {
		name string
		zone string
		want string
	}{
		{name: "acme", zone: "barkpark.cloud", want: "acme.barkpark.cloud"},
		{name: "", zone: "barkpark.cloud", want: "barkpark.cloud"},
		{name: "acme.", zone: "barkpark.cloud.", want: "acme.barkpark.cloud"},
		{name: " acme ", zone: " barkpark.cloud ", want: "acme.barkpark.cloud"},
	}
	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			if got := Fqdn(tt.name, tt.zone); got != tt.want {
				t.Fatalf("Fqdn(%q, %q) = %q, want %q", tt.name, tt.zone, got, tt.want)
			}
		})
	}
}

// TestFakeDNSUpsertResolveDelete is the core fake contract: upsert an A record
// for acme.barkpark.cloud → Resolve returns the IP → DeleteRecord → Resolve
// returns empty. An upsert of the same (fqdn,type) replaces rather than
// appends, and Resolve of an unknown fqdn is empty (not an error).
func TestFakeDNSUpsertResolveDelete(t *testing.T) {
	ctx := context.Background()
	fdns := NewFakeDNS()

	const zone, name = "barkpark.cloud", "acme"
	fqdn := Fqdn(name, zone) // acme.barkpark.cloud

	// Unknown fqdn resolves empty, no error.
	if got, err := fdns.Resolve(ctx, fqdn); err != nil || len(got) != 0 {
		t.Fatalf("Resolve before upsert = %v, %v; want empty, nil", got, err)
	}

	// Upsert an A record → Resolve returns its IP.
	if err := fdns.UpsertRecord(ctx, Record{Zone: zone, Name: name, Type: "A", Value: "10.0.0.1", TTL: 60}); err != nil {
		t.Fatalf("UpsertRecord: %v", err)
	}
	got, err := fdns.Resolve(ctx, fqdn)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"10.0.0.1"}) {
		t.Fatalf("Resolve(%q) = %v, want [10.0.0.1]", fqdn, got)
	}

	// Re-upsert the same (fqdn, type) replaces the value — no duplicate row.
	if err := fdns.UpsertRecord(ctx, Record{Zone: zone, Name: name, Type: "A", Value: "10.0.0.2"}); err != nil {
		t.Fatalf("re-UpsertRecord: %v", err)
	}
	got, _ = fdns.Resolve(ctx, fqdn)
	if !reflect.DeepEqual(got, []string{"10.0.0.2"}) {
		t.Fatalf("Resolve after re-upsert = %v, want [10.0.0.2] (replace, not append)", got)
	}

	// Delete → Resolve empty.
	if err := fdns.DeleteRecord(ctx, zone, name, "A"); err != nil {
		t.Fatalf("DeleteRecord: %v", err)
	}
	if got, _ := fdns.Resolve(ctx, fqdn); len(got) != 0 {
		t.Fatalf("Resolve after delete = %v, want empty", got)
	}

	// Deleting an already-absent record is idempotent (no error).
	if err := fdns.DeleteRecord(ctx, zone, name, "A"); err != nil {
		t.Fatalf("idempotent DeleteRecord: %v", err)
	}
}

// TestFakeDNSSatisfiesInterface is a runtime check that the fake is usable
// wherever a DNSProvider is expected.
func TestFakeDNSSatisfiesInterface(t *testing.T) {
	var d DNSProvider = NewFakeDNS()
	if err := d.UpsertRecord(context.Background(), Record{Zone: "barkpark.cloud", Name: "x", Value: "1.2.3.4"}); err != nil {
		t.Fatalf("UpsertRecord via interface: %v", err)
	}
}

// TestHetznerDNSUpsertRequest asserts the real provider builds the EXACT HTTP
// request the Hetzner DNS API expects — POST /api/v1/records, Auth-API-Token
// header, JSON body with zone_id/type/name/value/ttl — WITHOUT calling live
// DNS. The httptest.Server records the request and returns 200; HETZNER_DNS_TOKEN
// is supplied via the struct field so the env stays clean.
func TestHetznerDNSUpsertRequest(t *testing.T) {
	ctx := context.Background()

	var gotMethod, gotPath, gotToken, gotContentType string
	var gotBody hetznerRecordBody
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotToken = r.Header.Get("Auth-API-Token")
		gotContentType = r.Header.Get("Content-Type")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	h := &HetznerDNS{
		Client:  srv.Client(),
		BaseURL: srv.URL + "/api/v1",
		ZoneID:  "zone-123",
		Token:   "test-token",
	}

	if err := h.UpsertRecord(ctx, Record{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "10.0.0.1", TTL: 60}); err != nil {
		t.Fatalf("UpsertRecord: %v", err)
	}

	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotPath != "/api/v1/records" {
		t.Errorf("path = %q, want /api/v1/records", gotPath)
	}
	if gotToken != "test-token" {
		t.Errorf("Auth-API-Token = %q, want test-token", gotToken)
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotContentType)
	}
	want := hetznerRecordBody{ZoneID: "zone-123", Type: "A", Name: "acme", Value: "10.0.0.1", TTL: 60}
	if gotBody != want {
		t.Errorf("body = %+v, want %+v", gotBody, want)
	}
}

// TestHetznerDNSResolveAndDelete drives the find-then-delete path against a
// stub Hetzner that serves a fixed records list and records the DELETE — again
// without any live DNS. Resolve reads the value back; DeleteRecord finds the id
// and issues DELETE /api/v1/records/<id>.
func TestHetznerDNSResolveAndDelete(t *testing.T) {
	ctx := context.Background()

	var deletedPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/records":
			if r.URL.Query().Get("zone_id") != "zone-123" {
				t.Errorf("list zone_id = %q, want zone-123", r.URL.Query().Get("zone_id"))
			}
			_ = json.NewEncoder(w).Encode(hetznerRecordsList{Records: []hetznerRecord{
				{ID: "rec-1", Type: "A", Name: "acme", Value: "10.0.0.1"},
			}})
		case r.Method == http.MethodDelete:
			deletedPath = r.URL.Path
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer srv.Close()

	h := &HetznerDNS{Client: srv.Client(), BaseURL: srv.URL + "/api/v1", ZoneID: "zone-123", Token: "test-token"}

	got, err := h.Resolve(ctx, "acme")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"10.0.0.1"}) {
		t.Fatalf("Resolve = %v, want [10.0.0.1]", got)
	}

	if err := h.DeleteRecord(ctx, "barkpark.cloud", "acme", "A"); err != nil {
		t.Fatalf("DeleteRecord: %v", err)
	}
	if deletedPath != "/api/v1/records/rec-1" {
		t.Fatalf("DELETE path = %q, want /api/v1/records/rec-1", deletedPath)
	}
}
