// DNS is the native cloud.DNSProvider over Hetzner's INTEGRATED Cloud DNS.
// hcloud-go v2 (v2.44.0) DOES expose the zone/rrset resources (Hetzner folded
// DNS into the Cloud API — the same surface `hcloud zone rrset` shells to), so
// this implements UpsertRecord / DeleteRecord / Resolve natively over the SDK:
// the drop-in analogue of cloud.CloudDNS (dns_cloud.go), same credential
// (HCLOUD_TOKEN), same semantics (apex = "@", A records, idempotent delete).
// The existing cloud.CloudDNS remains the provisioner's default; this is the
// SDK path the native provider family will unify on.
package hetzner

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// DNS implements cloud.DNSProvider over the hcloud SDK's zone/rrset resources.
type DNS struct {
	client *Client
}

// NewDNS wraps an authenticated Client as a DNS provider. When the DNS zone
// lives in a DIFFERENT Cloud project than compute, build this from a second
// Client carrying that project's token (the SDK analogue of CloudDNS.Token).
func NewDNS(c *Client) *DNS {
	return &DNS{client: c}
}

// rrsetName maps a record label to the API's rrset name: the apex (empty
// label) is the literal "@"; any other label is passed verbatim (the API takes
// the bare label, not the fqdn). Trailing dots are tolerated — the same
// mapping cloud.CloudDNS applies for the CLI's positional <name>.
func rrsetName(name string) string {
	name = strings.Trim(strings.TrimSpace(name), ".")
	if name == "" {
		return "@"
	}
	return name
}

// recordType defaults an empty type to "A", matching the cloud seam's other
// DNSProvider impls.
func recordType(typ string) hcloud.ZoneRRSetType {
	if typ == "" {
		return hcloud.ZoneRRSetTypeA
	}
	return hcloud.ZoneRRSetType(strings.ToUpper(typ))
}

// zoneRef normalizes a zone name into the SDK's zone reference (addressed by
// name; trailing dots trimmed).
func zoneRef(zone string) *hcloud.Zone {
	return &hcloud.Zone{Name: strings.Trim(strings.TrimSpace(zone), ".")}
}

// UpsertRecord creates-or-replaces the record <name>.<zone> → Value:
// create-if-absent (POST rrsets), replace-if-exists (the set-records action —
// exactly what `hcloud zone rrset set-records` does). Both paths wait the
// returned action to completion; a TTL > 0 rides the create or a follow-up
// change-ttl action, mirroring CloudDNS (the API's set-records carries no TTL).
func (d *DNS) UpsertRecord(ctx context.Context, rec cloud.Record) error {
	zone := zoneRef(rec.Zone)
	name := rrsetName(rec.Name)
	typ := recordType(rec.Type)
	fqdn := cloud.Fqdn(rec.Name, rec.Zone)

	existing, _, err := d.client.hc.Zone.GetRRSetByNameAndType(ctx, zone, name, typ)
	if err != nil {
		return fmt.Errorf("hetzner dns upsert %q: %w", fqdn, err)
	}

	if existing == nil {
		opts := hcloud.ZoneRRSetCreateOpts{
			Name:    name,
			Type:    typ,
			Records: []hcloud.ZoneRRSetRecord{{Value: rec.Value}},
		}
		if rec.TTL > 0 {
			ttl := rec.TTL
			opts.TTL = &ttl
		}
		result, _, err := d.client.hc.Zone.CreateRRSet(ctx, zone, opts)
		if err != nil {
			return fmt.Errorf("hetzner dns upsert %q: %w", fqdn, err)
		}
		if err := d.client.hc.Action.WaitFor(ctx, result.Action); err != nil {
			return fmt.Errorf("hetzner dns upsert %q: waiting for create action: %w", fqdn, err)
		}
		return nil
	}

	// Address follow-up calls by zone NAME (the SDK's get hands back a
	// zone-id-only reference; the name is the stable handle we already hold).
	existing.Zone = zone
	action, _, err := d.client.hc.Zone.SetRRSetRecords(ctx, existing, hcloud.ZoneRRSetSetRecordsOpts{
		Records: []hcloud.ZoneRRSetRecord{{Value: rec.Value}},
	})
	if err != nil {
		return fmt.Errorf("hetzner dns upsert %q: %w", fqdn, err)
	}
	if err := d.client.hc.Action.WaitFor(ctx, action); err != nil {
		return fmt.Errorf("hetzner dns upsert %q: waiting for set-records action: %w", fqdn, err)
	}

	if rec.TTL > 0 {
		ttl := rec.TTL
		action, _, err := d.client.hc.Zone.ChangeRRSetTTL(ctx, existing, hcloud.ZoneRRSetChangeTTLOpts{TTL: &ttl})
		if err != nil {
			return fmt.Errorf("hetzner dns change-ttl %q: %w", fqdn, err)
		}
		if err := d.client.hc.Action.WaitFor(ctx, action); err != nil {
			return fmt.Errorf("hetzner dns change-ttl %q: waiting for action: %w", fqdn, err)
		}
	}
	return nil
}

// DeleteRecord removes the rrset of type typ at name.zone. Deleting an absent
// rrset is a no-op (idempotent) — the desired end state (no such record)
// already holds — matching CloudDNS's "Zone RRSet not found" swallow.
func (d *DNS) DeleteRecord(ctx context.Context, zone, name, typ string) error {
	rrset := &hcloud.ZoneRRSet{
		Zone: zoneRef(zone),
		Name: rrsetName(name),
		Type: recordType(typ),
	}
	result, _, err := d.client.hc.Zone.DeleteRRSet(ctx, rrset)
	if err != nil {
		if hcloud.IsError(err, hcloud.ErrorCodeNotFound) {
			return nil // idempotent: already absent
		}
		return fmt.Errorf("hetzner dns delete %q: %w", cloud.Fqdn(name, zone), err)
	}
	if err := d.client.hc.Action.WaitFor(ctx, result.Action); err != nil {
		return fmt.Errorf("hetzner dns delete %q: waiting for action: %w", cloud.Fqdn(name, zone), err)
	}
	return nil
}

// Resolve returns the A-record values at fqdn, sorted — parity with the other
// DNSProvider impls. The zone is everything after the first label (so
// "acme.barkpark.cloud" reads rrset "acme" in zone "barkpark.cloud"); a bare
// two-segment zone resolves its apex "@". An absent rrset resolves to an empty
// (non-nil) slice — resolving nothing is not an error.
func (d *DNS) Resolve(ctx context.Context, fqdn string) ([]string, error) {
	fqdn = strings.Trim(strings.TrimSpace(fqdn), ".")
	label, zone := splitFqdn(fqdn)

	rrset, _, err := d.client.hc.Zone.GetRRSetByNameAndType(ctx, zoneRef(zone), rrsetName(label), hcloud.ZoneRRSetTypeA)
	if err != nil {
		return nil, fmt.Errorf("hetzner dns resolve %q: %w", fqdn, err)
	}
	values := make([]string, 0)
	if rrset != nil {
		for _, r := range rrset.Records {
			values = append(values, r.Value)
		}
	}
	sort.Strings(values)
	return values, nil
}

// splitFqdn splits a fqdn into its first label and the remaining zone — the
// same rule cloud.CloudDNS applies: two or fewer segments is a registrable
// zone's apex (empty label), three-plus yields (label, zone).
func splitFqdn(fqdn string) (label, zone string) {
	parts := strings.Split(fqdn, ".")
	if len(parts) <= 2 {
		return "", fqdn // apex of a registrable zone
	}
	return parts[0], strings.Join(parts[1:], ".")
}

// compile-time assertion that *DNS satisfies the cloud seam's interface, and
// the by-value sweep's optional RecordLister with it. The RecordLister line is
// the one that matters here: without it the build stays green and
// deprovisionDNS silently takes the by-name arm (see ListRecords below).
var _ cloud.DNSProvider = (*DNS)(nil)
var _ cloud.RecordLister = (*DNS)(nil)

// ListRecords returns every record in the zone, flattened to one cloud.Record
// per (rrset, value) — the native analogue of cloud.CloudDNS.ListRecords, and
// the capability cloud.RecordLister names.
//
// WHY THIS EXISTS AT ALL: deprovisionDNS (internal/cli/cloud/warmpool.go)
// type-asserts its DNSProvider to cloud.RecordLister and, on a MISS, degrades
// to the by-NAME delete without erroring — deliberately, because the box is
// already gone by then. So a DNSProvider missing this one method does not fail
// loudly; it quietly stops sweeping custom-domain A records off an IP Hetzner
// is about to hand to someone else. Flipping the fleet to this native provider
// without ListRecords would have been exactly that silent downgrade.
//
// The apex rrset "@" maps back to the EMPTY label so cloud.Fqdn renders it as
// the bare zone — the same normalisation CloudDNS.ListRecords applies.
func (d *DNS) ListRecords(ctx context.Context, zone string) ([]cloud.Record, error) {
	zone = strings.Trim(strings.TrimSpace(zone), ".")
	rrsets, err := d.client.hc.Zone.AllRRSets(ctx, zoneRef(zone))
	if err != nil {
		return nil, fmt.Errorf("hetzner dns list %q: %w", zone, err)
	}
	out := make([]cloud.Record, 0, len(rrsets))
	for _, rr := range rrsets {
		if rr == nil {
			continue
		}
		name := rr.Name
		if name == "@" {
			name = ""
		}
		for _, r := range rr.Records {
			out = append(out, cloud.Record{
				Zone:  zone,
				Name:  name,
				Type:  string(rr.Type),
				Value: r.Value,
			})
		}
	}
	return out, nil
}
