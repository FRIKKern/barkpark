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
// human task, cloud-15), no record listing beyond Resolve.
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

// NewHetznerDNS returns a HetznerDNS for the given zone id, wired to the live
// Hetzner root and http.DefaultClient. Auth is read from HETZNER_DNS_TOKEN at
// request time.
func NewHetznerDNS(zoneID string) *HetznerDNS {
	return &HetznerDNS{ZoneID: zoneID}
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

// readBody reads an error-response body for inclusion in an error message,
// capped so a runaway body can't bloat the message.
func readBody(r io.Reader) string {
	b, _ := io.ReadAll(io.LimitReader(r, 1<<12))
	return strings.TrimSpace(string(b))
}

// compile-time assertion that *HetznerDNS satisfies the interface.
var _ DNSProvider = (*HetznerDNS)(nil)
