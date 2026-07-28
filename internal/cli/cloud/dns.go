// DNS is the second seam in the cloud package: per-instance subdomain records
// (`<name>.barkpark.cloud`) get managed against a small DNSProvider interface
// with two implementations, mirroring the CloudProvider seam in provider.go:
//
//   - HetznerDNS — the real impl. It builds the SAME HTTP request the Hetzner
//     DNS API expects (POST/DELETE on /api/v1/records, Auth-API-Token header,
//     JSON body) and dispatches via an INJECTABLE *http.Client so a test can
//     point it at an httptest.Server and assert the exact request without ever
//     touching live DNS. Auth reads HETZNER_DNS_TOKEN, absent in tests.
//   - FakeDNS — an in-memory zone map keyed by fqdn. UpsertRecord is a map
//     write, Resolve reads the values back, DeleteRecord removes. No network,
//     no domain ownership, zero cost. This is what every future DNS test runs
//     against.
//
// YAGNI on purpose: UpsertRecord / DeleteRecord / Resolve and A records only.
// No CNAME/TXT, no wildcard automation (the `*.barkpark.cloud` delegation is a
// human task, cloud-15). Record listing exists ONLY for the by-value teardown
// sweep (RecordLister + SweepARecordsByValue below, PDF-D101) — never for
// general zone management.
package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
)

// Record is a single DNS record. Zone is the apex (e.g. "barkpark.cloud"), Name
// the label (e.g. "acme") so the fqdn is "acme.barkpark.cloud", Type is always
// "A" for now, Value the IPv4. TTL is seconds (0 → provider default).
type Record struct {
	Zone  string
	Name  string
	Type  string
	Value string
	TTL   int
}

// DNSProvider is the per-instance DNS seam. A real impl talks to a DNS API; the
// fake keeps a zone map in memory. The three methods are the whole API the
// per-instance subdomain flow needs — upsert a record, delete it, resolve it.
type DNSProvider interface {
	UpsertRecord(ctx context.Context, rec Record) error
	DeleteRecord(ctx context.Context, zone, name, typ string) error
	Resolve(ctx context.Context, fqdn string) ([]string, error)
}

// Fqdn joins a record label to its zone: ("acme","barkpark.cloud") →
// "acme.barkpark.cloud". An empty (apex) name yields the bare zone; trailing
// dots on either part are tolerated so callers needn't normalise first.
func Fqdn(name, zone string) string {
	name = strings.Trim(strings.TrimSpace(name), ".")
	zone = strings.Trim(strings.TrimSpace(zone), ".")
	if name == "" {
		return zone
	}
	return name + "." + zone
}

// FakeDNS is the in-memory DNSProvider every DNS test runs against — no
// network, no domain ownership, zero cost. Records live in a map keyed by fqdn;
// UpsertRecord overwrites the matching (fqdn,type) entry, Resolve reads the
// values back, DeleteRecord removes them. It is safe for concurrent use.
//
// NewFakeDNS returns a ready instance; the zero value also works (the map is
// lazily created on first UpsertRecord).
type FakeDNS struct {
	mu      sync.Mutex
	records map[string][]Record // keyed by fqdn
}

// NewFakeDNS returns an empty in-memory DNS provider.
func NewFakeDNS() *FakeDNS {
	return &FakeDNS{records: map[string][]Record{}}
}

// UpsertRecord writes the record under its fqdn, replacing any existing record
// of the same Type at that fqdn (an "upsert", as the name says). Defaults to an
// A record when Type is empty.
func (f *FakeDNS) UpsertRecord(_ context.Context, rec Record) error {
	if rec.Name == "" && rec.Zone == "" {
		return fmt.Errorf("cloud: fake UpsertRecord requires a zone or name")
	}
	if rec.Type == "" {
		rec.Type = "A"
	}
	fqdn := Fqdn(rec.Name, rec.Zone)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.records == nil {
		f.records = map[string][]Record{}
	}
	existing := f.records[fqdn]
	replaced := false
	for i, r := range existing {
		if strings.EqualFold(r.Type, rec.Type) {
			existing[i] = rec
			replaced = true
			break
		}
	}
	if !replaced {
		existing = append(existing, rec)
	}
	f.records[fqdn] = existing
	return nil
}

// Resolve returns the Values of every record at fqdn, sorted for deterministic
// assertions. An unknown fqdn resolves to an empty (non-nil) slice — resolving
// nothing is not an error.
func (f *FakeDNS) Resolve(_ context.Context, fqdn string) ([]string, error) {
	fqdn = strings.Trim(strings.TrimSpace(fqdn), ".")
	f.mu.Lock()
	defer f.mu.Unlock()
	recs := f.records[fqdn]
	out := make([]string, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.Value)
	}
	sort.Strings(out)
	return out, nil
}

// DeleteRecord removes the record of the given type at name.zone. Deleting an
// absent record is a no-op (idempotent), not an error — the desired end state
// (no such record) already holds.
func (f *FakeDNS) DeleteRecord(_ context.Context, zone, name, typ string) error {
	if typ == "" {
		typ = "A"
	}
	fqdn := Fqdn(name, zone)
	f.mu.Lock()
	defer f.mu.Unlock()
	existing := f.records[fqdn]
	kept := existing[:0]
	for _, r := range existing {
		if !strings.EqualFold(r.Type, typ) {
			kept = append(kept, r)
		}
	}
	if len(kept) == 0 {
		delete(f.records, fqdn)
	} else {
		f.records[fqdn] = kept
	}
	return nil
}

// compile-time assertion that *FakeDNS satisfies the interface.
var _ DNSProvider = (*FakeDNS)(nil)

// hetznerDNSBase is the Hetzner DNS API root. Hetzner-first to match the
// provisioning strategy (HcloudProvider in provider.go).
const hetznerDNSBase = "https://dns.hetzner.com/api/v1"

// HetznerDNS is the real DNSProvider. It builds the exact HTTP requests the
// Hetzner DNS API expects and dispatches them through an INJECTABLE http.Client,
// reading auth from HETZNER_DNS_TOKEN. The zero value is usable: a nil Client
// falls back to http.DefaultClient, and an empty BaseURL falls back to the live
// Hetzner root — so a test sets Client + BaseURL to an httptest.Server and the
// production path needs neither.
type HetznerDNS struct {
	// Client dispatches the request. nil → http.DefaultClient.
	Client *http.Client
	// BaseURL overrides the Hetzner DNS API root (set to an httptest.Server URL
	// in tests). Empty → the live Hetzner root.
	BaseURL string
	// ZoneID is the Hetzner zone the records live in. The API addresses records
	// by zone id, not by zone name.
	ZoneID string
	// Token overrides the HETZNER_DNS_TOKEN env auth (mainly for tests). Empty →
	// read the env at request time.
	Token string
}

func (h *HetznerDNS) base() string {
	if h.BaseURL != "" {
		return strings.TrimRight(h.BaseURL, "/")
	}
	return hetznerDNSBase
}

func (h *HetznerDNS) client() *http.Client {
	if h.Client != nil {
		return h.Client
	}
	return http.DefaultClient
}

func (h *HetznerDNS) token() string {
	if h.Token != "" {
		return h.Token
	}
	return strings.TrimSpace(os.Getenv("HETZNER_DNS_TOKEN"))
}

// hetznerRecordBody is the JSON payload Hetzner's POST/PUT /records expects.
type hetznerRecordBody struct {
	ZoneID string `json:"zone_id"`
	Type   string `json:"type"`
	Name   string `json:"name"`
	Value  string `json:"value"`
	TTL    int    `json:"ttl,omitempty"`
}

// newUpsertRequest builds (but does not send) the POST /api/v1/records request
// that creates rec in this zone. It is the request-builder seam: a test can
// assert method/URL/header/body without dispatching. Auth goes in the
// Auth-API-Token header per Hetzner's spec.
func (h *HetznerDNS) newUpsertRequest(ctx context.Context, rec Record) (*http.Request, error) {
	typ := rec.Type
	if typ == "" {
		typ = "A"
	}
	body := hetznerRecordBody{
		ZoneID: h.ZoneID,
		Type:   typ,
		Name:   rec.Name,
		Value:  rec.Value,
		TTL:    rec.TTL,
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.base()+"/records", bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Auth-API-Token", h.token())
	return req, nil
}

// newDeleteRequest builds (but does not send) the GET /api/v1/records request
// used to find the record id, scoped to the zone. Hetzner deletes records by
// id, so deletion is a find-then-delete; this builds the find half, and
// newDeleteByIDRequest builds the delete half.
func (h *HetznerDNS) newListRequest(ctx context.Context) (*http.Request, error) {
	u := h.base() + "/records?" + url.Values{"zone_id": {h.ZoneID}}.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Auth-API-Token", h.token())
	return req, nil
}

// newDeleteByIDRequest builds (but does not send) the DELETE /api/v1/records/<id>
// request that removes a record by its Hetzner id.
func (h *HetznerDNS) newDeleteByIDRequest(ctx context.Context, id string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, h.base()+"/records/"+id, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Auth-API-Token", h.token())
	return req, nil
}

// UpsertRecord creates rec in the zone via POST /api/v1/records. The request is
// built by the pure newUpsertRequest helper, so a real run and the request test
// exercise the same bytes.
func (h *HetznerDNS) UpsertRecord(ctx context.Context, rec Record) error {
	req, err := h.newUpsertRequest(ctx, rec)
	if err != nil {
		return err
	}
	resp, err := h.client().Do(req)
	if err != nil {
		return fmt.Errorf("hetzner dns upsert %q: %w", Fqdn(rec.Name, rec.Zone), err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("hetzner dns upsert %q: status %d: %s", Fqdn(rec.Name, rec.Zone), resp.StatusCode, readBody(resp.Body))
	}
	return nil
}

// hetznerRecord is one row of Hetzner's GET /records response.
type hetznerRecord struct {
	ID    string `json:"id"`
	Type  string `json:"type"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

type hetznerRecordsList struct {
	Records []hetznerRecord `json:"records"`
}

// DeleteRecord removes the record of type typ at name in the zone: list the
// zone's records, find the matching (name,type), then DELETE it by id. Absent
// record → no-op (idempotent).
func (h *HetznerDNS) DeleteRecord(ctx context.Context, zone, name, typ string) error {
	if typ == "" {
		typ = "A"
	}
	recs, err := h.list(ctx)
	if err != nil {
		return err
	}
	for _, r := range recs {
		if r.Name == name && strings.EqualFold(r.Type, typ) {
			req, err := h.newDeleteByIDRequest(ctx, r.ID)
			if err != nil {
				return err
			}
			resp, err := h.client().Do(req)
			if err != nil {
				return fmt.Errorf("hetzner dns delete %q: %w", Fqdn(name, zone), err)
			}
			resp.Body.Close()
			if resp.StatusCode/100 != 2 {
				return fmt.Errorf("hetzner dns delete %q: status %d", Fqdn(name, zone), resp.StatusCode)
			}
		}
	}
	return nil
}

// Resolve returns the Values of every record whose Hetzner name matches the
// label of fqdn, in the configured zone. Sorted for deterministic results.
func (h *HetznerDNS) Resolve(ctx context.Context, fqdn string) ([]string, error) {
	recs, err := h.list(ctx)
	if err != nil {
		return nil, err
	}
	fqdn = strings.Trim(strings.TrimSpace(fqdn), ".")
	out := make([]string, 0, len(recs))
	for _, r := range recs {
		// Hetzner stores the bare label in Name; reconstruct the fqdn against the
		// record's value only when names line up. Match either the bare label
		// (fqdn's first segment) or the full fqdn.
		if r.Name == fqdn || strings.HasPrefix(fqdn, r.Name+".") {
			out = append(out, r.Value)
		}
	}
	sort.Strings(out)
	return out, nil
}

// list fetches and decodes the zone's records.
func (h *HetznerDNS) list(ctx context.Context) ([]hetznerRecord, error) {
	req, err := h.newListRequest(ctx)
	if err != nil {
		return nil, err
	}
	resp, err := h.client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("hetzner dns list: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("hetzner dns list: status %d", resp.StatusCode)
	}
	var parsed hetznerRecordsList
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("hetzner dns list: decode: %w", err)
	}
	return parsed.Records, nil
}

// ── the by-value sweep (PDF-D101) ────────────────────────────────────────────
//
// `bp cloud support remove` tears down leaked A records by VALUE, not name:
// the support chain writes <name>.<zone> while the main go-live path writes
// <slug>-<team>.<zone> at the SAME IP — a by-name delete removes one, leaves
// the sibling, and a by-name census still reads clean. These helpers list the
// zone and match record VALUES against the box IP instead.

// RecordLister is the optional listing capability the by-value sweep needs on
// top of DNSProvider. All three providers implement it; a provider that does
// not is an ERROR at sweep time, never a silent empty result.
type RecordLister interface {
	// ListRecords returns every record in the zone.
	ListRecords(ctx context.Context, zone string) ([]Record, error)
}

// ListRecords returns every record FakeDNS holds in the zone, sorted by
// (Name, Type) for deterministic assertions.
func (f *FakeDNS) ListRecords(_ context.Context, zone string) ([]Record, error) {
	zone = strings.Trim(strings.TrimSpace(zone), ".")
	f.mu.Lock()
	defer f.mu.Unlock()
	out := []Record{}
	for _, recs := range f.records {
		for _, r := range recs {
			if strings.EqualFold(strings.Trim(strings.TrimSpace(r.Zone), "."), zone) {
				out = append(out, r)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].Type < out[j].Type
	})
	return out, nil
}

// ListRecords returns every record in the configured zone. The zone argument
// is carried into the returned Records; the listing itself is scoped by the
// configured ZoneID (Hetzner's legacy API addresses zones by id, not name).
func (h *HetznerDNS) ListRecords(ctx context.Context, zone string) ([]Record, error) {
	recs, err := h.list(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]Record, 0, len(recs))
	for _, r := range recs {
		out = append(out, Record{Zone: zone, Name: r.Name, Type: r.Type, Value: r.Value})
	}
	return out, nil
}

// ListRecords lists the zone's rrsets via `hcloud zone rrset list -o json`,
// flattened to one Record per (name, value). The apex "@" maps back to the
// empty label so Fqdn renders it as the bare zone. (Defined here rather than
// in dns_cloud.go so the whole by-value seam lives in one place.)
func (c *CloudDNS) ListRecords(ctx context.Context, zone string) ([]Record, error) {
	argv := hcloudZoneRRSetListArgv(zone)
	out, err := c.run(ctx, argv[0], argv[1:]...)
	if err != nil {
		return nil, fmt.Errorf("hcloud zone rrset list %q: %w: %s", zone, err, strings.TrimSpace(out))
	}
	var rrsets []cloudRRSet
	if err := json.Unmarshal([]byte(out), &rrsets); err != nil {
		return nil, fmt.Errorf("hcloud zone rrset list %q: decode: %w", zone, err)
	}
	recs := make([]Record, 0, len(rrsets))
	for _, rr := range rrsets {
		name := rr.Name
		if name == "@" {
			name = ""
		}
		for _, v := range rr.Records {
			recs = append(recs, Record{Zone: zone, Name: name, Type: rr.Type, Value: v.Value})
		}
	}
	return recs, nil
}

// ARecordNamesByValue returns the sorted, de-duplicated names of every A rrset
// in zone holding a record whose value equals ip — the teardown census's fifth
// leg. A provider without RecordLister is an ERROR, not an empty result: a
// check that cannot list must never read as clean.
func ARecordNamesByValue(ctx context.Context, dns DNSProvider, zone, ip string) ([]string, error) {
	lister, ok := dns.(RecordLister)
	if !ok {
		return nil, fmt.Errorf("cloud: DNS provider %T cannot list records — the by-value sweep needs RecordLister", dns)
	}
	recs, err := lister.ListRecords(ctx, zone)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	names := []string{}
	for _, r := range recs {
		typ := r.Type
		if typ == "" {
			typ = "A"
		}
		if !strings.EqualFold(typ, "A") || strings.TrimSpace(r.Value) != ip {
			continue
		}
		if !seen[r.Name] {
			seen[r.Name] = true
			names = append(names, r.Name)
		}
	}
	sort.Strings(names)
	return names, nil
}

// SweepARecordsByValue deletes every A rrset in zone that resolves to ip. It
// returns the names it actually deleted. An individual delete failure does not
// stop the sweep (the siblings still go); the failures aggregate into the
// returned error, alongside whatever WAS deleted.
func SweepARecordsByValue(ctx context.Context, dns DNSProvider, zone, ip string) ([]string, error) {
	names, err := ARecordNamesByValue(ctx, dns, zone, ip)
	if err != nil {
		return nil, err
	}
	deleted := []string{}
	var errs []string
	for _, name := range names {
		if derr := dns.DeleteRecord(ctx, zone, name, "A"); derr != nil {
			errs = append(errs, derr.Error())
			continue
		}
		deleted = append(deleted, name)
	}
	if len(errs) > 0 {
		return deleted, fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return deleted, nil
}

// readBody reads an error-response body for inclusion in an error message,
// capped so a runaway body can't bloat the message.
func readBody(r io.Reader) string {
	b, _ := io.ReadAll(io.LimitReader(r, 1<<12))
	return strings.TrimSpace(string(b))
}

// compile-time assertion that *HetznerDNS satisfies the interface.
var _ DNSProvider = (*HetznerDNS)(nil)
