// CloudDNS is the third DNSProvider seam (after HetznerDNS and FakeDNS): it
// manages per-instance subdomain records against Hetzner's INTEGRATED Cloud DNS
// via the `hcloud zone rrset` CLI, authenticating with the SAME Cloud token
// (HCLOUD_TOKEN / active `hcloud context`) the warm-pool already uses to create
// servers. It is the direct analogue of HcloudProvider in provider.go — shell
// out to `hcloud …` and surface the captured output on failure — and it lets
// the provisioner unify on one credential instead of carrying a separate
// HETZNER_DNS_TOKEN for the legacy dns.hetzner.com REST API (HetznerDNS).
//
// The real CLI surface (discovered against the live `barkpark.cloud` zone):
//
//	hcloud zone rrset set-records    <zone> <name> <type> --record <value>...
//	hcloud zone rrset change-ttl     <zone> <name> <type> --ttl <ttl>
//	hcloud zone rrset delete         <zone> <name> <type>
//	hcloud zone rrset list           <zone> -o json
//
// Positional <zone> <name> <type>; values via repeatable --record; the apex is
// the literal name "@". set-records is replace-if-exists / create-if-absent —
// exactly upsert. It carries NO --ttl flag, so a non-zero TTL is a second
// change-ttl call. delete errors "Zone RRSet not found" on a missing rrset; we
// swallow that to keep DeleteRecord idempotent (the desired end state holds).
//
// YAGNI, as with HetznerDNS: UpsertRecord / DeleteRecord / Resolve, A records,
// one value per record. No retries, no zone auto-creation (the zone exists).
package cloud

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// dnsRunner is the exec seam: it runs argv and returns combined stdout+stderr
// plus the error. Production uses runCapture (provider.go); tests inject a fake
// so CloudDNS never shells out to real hcloud. The signature mirrors the args of
// runCapture so the production runner is a one-line adapter.
type dnsRunner func(ctx context.Context, name string, args ...string) (string, error)

// CloudDNS is the real DNSProvider backed by `hcloud zone rrset`. The zero value
// is usable: a nil Run falls back to runCapture (the same exec mechanism
// provider.go uses). Zone is informational only — every argv carries its own
// zone from the Record/args, matching the CLI's positional <zone>.
type CloudDNS struct {
	// Run dispatches the hcloud argv. nil → runCapture (live hcloud).
	Run dnsRunner
	// Token, when set, runs every `hcloud zone rrset` exec with
	// HCLOUD_TOKEN=<Token> in the child env — so DNS authenticates against the
	// Cloud project that owns the zone, which may DIFFER from the compute token
	// used to create servers. Empty → DNS inherits the process HCLOUD_TOKEN /
	// `hcloud context` (single-credential mode, the original behaviour).
	Token string
}

// NewCloudDNS returns a CloudDNS wired to the live `hcloud` CLI. Auth is the
// active Cloud token (HCLOUD_TOKEN / `hcloud context`), read by hcloud itself —
// unless Token is set, which overrides HCLOUD_TOKEN for the DNS execs (so DNS
// can target a different project than compute).
func NewCloudDNS() *CloudDNS {
	return &CloudDNS{}
}

func (c *CloudDNS) run(ctx context.Context, name string, args ...string) (string, error) {
	if c.Run != nil {
		return c.Run(ctx, name, args...)
	}
	if c.Token != "" {
		return runCaptureWithEnv(ctx, []string{"HCLOUD_TOKEN=" + c.Token}, name, args...)
	}
	return runCapture(ctx, name, args...)
}

// rrsetName maps a record label to the CLI's positional <name>: the apex (empty
// label) is the literal "@"; any other label is passed verbatim (the CLI takes
// the bare label, not the fqdn). Trailing dots are tolerated.
func rrsetName(name string) string {
	name = strings.Trim(strings.TrimSpace(name), ".")
	if name == "" {
		return "@"
	}
	return name
}

// hcloudZoneRRSetArgv builds the EXACT argv `hcloud zone rrset set-records` execs
// for an upsert. PURE function (no exec, no env) so a test asserts the argv
// without invoking hcloud — the hcloudCreateArgv pattern from provider.go. The
// TTL is NOT here: set-records carries no --ttl flag, so a non-zero TTL is a
// separate change-ttl argv (hcloudZoneRRSetTTLArgv). Type defaults to A.
func hcloudZoneRRSetArgv(rec Record) []string {
	typ := rec.Type
	if typ == "" {
		typ = "A"
	}
	return []string{
		"hcloud", "zone", "rrset", "set-records",
		rec.Zone, rrsetName(rec.Name), typ,
		"--record", rec.Value,
	}
}

// hcloudZoneRRSetTTLArgv builds the argv that sets a record's TTL —
// `hcloud zone rrset change-ttl <zone> <name> <type> --ttl <ttl>`. Called only
// when TTL > 0 (set-records can't carry TTL). PURE, like hcloudZoneRRSetArgv.
func hcloudZoneRRSetTTLArgv(rec Record) []string {
	typ := rec.Type
	if typ == "" {
		typ = "A"
	}
	return []string{
		"hcloud", "zone", "rrset", "change-ttl",
		rec.Zone, rrsetName(rec.Name), typ,
		"--ttl", fmt.Sprintf("%d", rec.TTL),
	}
}

// hcloudZoneRRSetDeleteArgv builds the argv that removes a whole rrset —
// `hcloud zone rrset delete <zone> <name> <type>`. PURE. Type defaults to A.
func hcloudZoneRRSetDeleteArgv(zone, name, typ string) []string {
	if typ == "" {
		typ = "A"
	}
	return []string{
		"hcloud", "zone", "rrset", "delete",
		zone, rrsetName(name), typ,
	}
}

// hcloudZoneRRSetListArgv builds the argv that lists a zone's rrsets as JSON —
// `hcloud zone rrset list <zone> -o json`. PURE.
func hcloudZoneRRSetListArgv(zone string) []string {
	return []string{
		"hcloud", "zone", "rrset", "list",
		zone, "-o", "json",
	}
}

// UpsertRecord creates-or-replaces the A record <name>.<zone> → Value via
// `hcloud zone rrset set-records` (idempotent replace == upsert). When TTL > 0 a
// follow-up `change-ttl` sets the TTL, since set-records carries no --ttl flag.
// On failure it surfaces hcloud's captured output — never a bare "exit status
// 1" — mirroring HcloudProvider.Create.
func (c *CloudDNS) UpsertRecord(ctx context.Context, rec Record) error {
	argv := hcloudZoneRRSetArgv(rec)
	if out, err := c.run(ctx, argv[0], argv[1:]...); err != nil {
		return fmt.Errorf("hcloud zone rrset replace-records %q: %w: %s", Fqdn(rec.Name, rec.Zone), err, strings.TrimSpace(out))
	}
	if rec.TTL > 0 {
		ttlArgv := hcloudZoneRRSetTTLArgv(rec)
		if out, err := c.run(ctx, ttlArgv[0], ttlArgv[1:]...); err != nil {
			return fmt.Errorf("hcloud zone rrset change-ttl %q: %w: %s", Fqdn(rec.Name, rec.Zone), err, strings.TrimSpace(out))
		}
	}
	return nil
}

// DeleteRecord removes the rrset of type typ at name.zone via
// `hcloud zone rrset delete`. Deleting an absent rrset is a no-op (idempotent):
// hcloud prints "Zone RRSet not found" and exits non-zero, which we swallow —
// the desired end state (no such record) already holds. Any OTHER failure
// surfaces hcloud's captured output.
func (c *CloudDNS) DeleteRecord(ctx context.Context, zone, name, typ string) error {
	argv := hcloudZoneRRSetDeleteArgv(zone, name, typ)
	out, err := c.run(ctx, argv[0], argv[1:]...)
	if err != nil {
		if strings.Contains(strings.ToLower(out), "not found") {
			return nil // idempotent: already absent
		}
		return fmt.Errorf("hcloud zone rrset delete %q: %w: %s", Fqdn(name, zone), err, strings.TrimSpace(out))
	}
	return nil
}

// cloudRRSet is one row of `hcloud zone rrset list -o json`: a name, a type, and
// its records (each a {value}). Only the fields Resolve needs are decoded.
type cloudRRSet struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	Records []struct {
		Value string `json:"value"`
	} `json:"records"`
}

// Resolve returns the Values of every record whose name matches the label of
// fqdn, in fqdn's zone — parity with HetznerDNS.Resolve. It lists the zone via
// `hcloud zone rrset list <zone> -o json` and matches the apex ("@") or the
// bare label. The zone is taken as everything after the first label of fqdn (so
// "acme.barkpark.cloud" lists "barkpark.cloud" and matches name "acme"); a bare
// zone ("barkpark.cloud") lists itself and matches the apex. Sorted output.
func (c *CloudDNS) Resolve(ctx context.Context, fqdn string) ([]string, error) {
	fqdn = strings.Trim(strings.TrimSpace(fqdn), ".")
	label, zone := splitFqdn(fqdn)

	argv := hcloudZoneRRSetListArgv(zone)
	out, err := c.run(ctx, argv[0], argv[1:]...)
	if err != nil {
		return nil, fmt.Errorf("hcloud zone rrset list %q: %w: %s", zone, err, strings.TrimSpace(out))
	}
	var rrsets []cloudRRSet
	if err := json.Unmarshal([]byte(out), &rrsets); err != nil {
		return nil, fmt.Errorf("hcloud zone rrset list %q: decode: %w", zone, err)
	}

	wantName := rrsetName(label) // "@" for the apex, else the bare label
	values := make([]string, 0)
	for _, rr := range rrsets {
		if rr.Name != wantName {
			continue
		}
		for _, r := range rr.Records {
			values = append(values, r.Value)
		}
	}
	sort.Strings(values)
	return values, nil
}

// splitFqdn splits a fqdn into its first label and the remaining zone. A bare
// zone (no further label, or two-segment apex like "barkpark.cloud") yields an
// empty label and the whole input as the zone — so Resolve("barkpark.cloud")
// lists "barkpark.cloud" and matches the apex "@". A three-plus-segment fqdn
// like "acme.barkpark.cloud" yields ("acme", "barkpark.cloud").
func splitFqdn(fqdn string) (label, zone string) {
	parts := strings.Split(fqdn, ".")
	if len(parts) <= 2 {
		return "", fqdn // apex of a registrable zone
	}
	return parts[0], strings.Join(parts[1:], ".")
}

// compile-time assertion that *CloudDNS satisfies the interface.
var _ DNSProvider = (*CloudDNS)(nil)

// compile-time assertion that *CloudDNS also satisfies RecordLister — the
// OPTIONAL capability deprovisionDNS (warmpool.go) type-asserts to choose the
// by-VALUE sweep over the by-NAME delete. *CloudDNS is what production wires
// (cmd/barkpark-provisioner/main.go, internal/cli/cloud_support_cmd.go), and
// the assertion is a plain interface satisfaction, so dropping or renaming
// ListRecords silently degrades the WHOLE FLEET to by-name teardown without a
// single test going red. This line makes that a BUILD failure; the runtime
// table test in dns_cloud_test.go covers the constructor-swap case this cannot
// see.
var _ RecordLister = (*CloudDNS)(nil)
