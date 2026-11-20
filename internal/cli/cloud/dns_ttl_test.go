package cloud

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// maxBoxRecordTTL is the longest TTL these tests accept on an A record that
// points at a box. A box's IP is released when the box is deleted, so a record
// left at the zone default (seen at 3600 s on 2026-11-19) keeps resolvers
// answering a dead address for an hour after teardown deletes it.
const maxBoxRecordTTL = 300

// assertShortTTL fails unless dns holds exactly one A record at name.zone and
// that record carries a TTL in (0, maxBoxRecordTTL]. TTL 0 means "zone
// default", which is the bug.
func assertShortTTL(t *testing.T, dns *FakeDNS, zone, name string) {
	t.Helper()
	recs, err := dns.ListRecords(context.Background(), zone)
	if err != nil {
		t.Fatalf("ListRecords: %v", err)
	}
	var got []Record
	for _, r := range recs {
		if r.Name == name && strings.EqualFold(r.Type, "A") {
			got = append(got, r)
		}
	}
	if len(got) != 1 {
		t.Fatalf("A records at %s.%s = %+v, want exactly one", name, zone, got)
	}
	if got[0].TTL <= 0 || got[0].TTL > maxBoxRecordTTL {
		t.Errorf("A record %s.%s TTL = %d, want 1..%d (0 means the zone default)", name, zone, got[0].TTL, maxBoxRecordTTL)
	}
}

// TestGoLiveWritesShortTTL covers every go-live entry into configureHost: the
// warm-pool pop (Provision), the one-shot create (ProvisionOneShot), and the
// warm assign (AssignWarm). Each must write the instance A record with a short
// TTL, not the zone default.
func TestGoLiveWritesShortTTL(t *testing.T) {
	ctx := context.Background()
	spec := acmeSpec()

	t.Run("warm pop", func(t *testing.T) {
		wp, _, dns, _, _ := newFakeWarmPool(t, greenGate(spec.healthTarget()))
		if _, err := wp.Provision(ctx, spec); err != nil {
			t.Fatalf("Provision: %v", err)
		}
		assertShortTTL(t, dns, spec.Zone, spec.Name)
	})

	t.Run("one-shot", func(t *testing.T) {
		dns := NewFakeDNS()
		wp := &WarmPool{
			Provider:           NewFakeProvider(),
			DNS:                dns,
			Runner:             &recordingRunner{},
			Health:             greenGate(spec.healthTarget()),
			Registry:           NewFakeRegistry(),
			HealthPollInterval: time.Millisecond,
			HealthPollDeadline: 30 * time.Millisecond,
		}
		if _, err := wp.ProvisionOneShot(ctx, spec); err != nil {
			t.Fatalf("ProvisionOneShot: %v", err)
		}
		assertShortTTL(t, dns, spec.Zone, spec.Name)
	})

	t.Run("warm assign", func(t *testing.T) {
		wp, prov, dns, _, _ := warmAssignPool(greenGate(spec.healthTarget()))
		host, err := CreateWarmServer(ctx, prov, warmSpec())
		if err != nil {
			t.Fatalf("seed warm box: %v", err)
		}
		if _, err := wp.AssignWarm(ctx, host, spec); err != nil {
			t.Fatalf("AssignWarm: %v", err)
		}
		assertShortTTL(t, dns, spec.Zone, spec.Name)
	})
}

// TestGoLiveIssuesChangeTTLThroughCloudDNS wires the production DNS provider
// (CloudDNS, with a fake runner) into a warm assign and asserts the go-live
// issues `hcloud zone rrset change-ttl … --ttl <short>` for the instance
// record. set-records has no --ttl flag, so without change-ttl the record keeps
// the zone default.
func TestGoLiveIssuesChangeTTLThroughCloudDNS(t *testing.T) {
	ctx := context.Background()
	spec := acmeSpec()
	wp, prov, _, _, _ := warmAssignPool(greenGate(spec.healthTarget()))
	rr := &recordedRun{}
	wp.DNS = &CloudDNS{Run: rr.run}

	host, err := CreateWarmServer(ctx, prov, warmSpec())
	if err != nil {
		t.Fatalf("seed warm box: %v", err)
	}
	if _, err := wp.AssignWarm(ctx, host, spec); err != nil {
		t.Fatalf("AssignWarm: %v", err)
	}

	var ttlCall []string
	for _, c := range rr.calls {
		if len(c) >= 7 && c[3] == "change-ttl" && c[4] == spec.Zone && c[5] == spec.Name && c[6] == "A" {
			ttlCall = c
		}
	}
	if ttlCall == nil {
		t.Fatalf("no `hcloud zone rrset change-ttl %s %s A` call; calls=%v", spec.Zone, spec.Name, rr.calls)
	}
	if last := ttlCall[len(ttlCall)-1]; last == "0" || ttlCall[len(ttlCall)-2] != "--ttl" {
		t.Errorf("change-ttl argv = %v, want a trailing --ttl <short>", ttlCall)
	}
}

// TestRepointDNSWritesShortTTL covers the resurrect path: RepointDNS points the
// bundle's fqdn at a fresh box, and that record must carry a short TTL too.
func TestRepointDNSWritesShortTTL(t *testing.T) {
	dns := NewFakeDNS()
	e := &RestoreExecutor{DNS: dns}
	if err := e.RepointDNS(context.Background(), "acme.barkpark.cloud", "203.0.113.7"); err != nil {
		t.Fatalf("RepointDNS: %v", err)
	}
	assertShortTTL(t, dns, "barkpark.cloud", "acme")
}

// TestCloudDNSDeleteMissingZoneIsAnError: "Zone not found" means the DNS token
// cannot see the zone, so the record may still be live. DeleteRecord must
// return an error, not report a clean delete. Only a missing rrset ("Zone
// RRSet not found") in a visible zone is the idempotent no-op.
func TestCloudDNSDeleteMissingZoneIsAnError(t *testing.T) {
	cases := []struct {
		desc    string
		out     string
		wantErr bool
	}{
		{"missing zone, API form", "hcloud: Zone not found (not_found)", true},
		{"missing zone, lookup form", "hcloud: Zone not found: barkpark.cloud", true},
		{"missing rrset", "hcloud: Zone RRSet not found: barkpark.cloud acme A", false},
		{"missing rrset, lower case", "hcloud: zone rrset not found: acme", false},
		{"other not found", "hcloud: server not found", true},
	}
	for _, tc := range cases {
		t.Run(tc.desc, func(t *testing.T) {
			rr := &recordedRun{outputs: []string{tc.out}, errs: []error{errors.New("exit status 1")}}
			c := &CloudDNS{Run: rr.run}
			err := c.DeleteRecord(context.Background(), "barkpark.cloud", "acme", "A")
			if tc.wantErr && err == nil {
				t.Fatalf("DeleteRecord(%q) = nil, want an error (the record may still be live)", tc.out)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("DeleteRecord(%q) = %v, want nil (rrset already absent)", tc.out, err)
			}
			if tc.wantErr && !strings.Contains(err.Error(), tc.out) {
				t.Errorf("error %q does not carry hcloud's output %q", err.Error(), tc.out)
			}
		})
	}
}
