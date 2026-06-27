package cloud

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// recordedRun is a fake dnsRunner: it records every argv it is handed and
// returns a scripted (output, error) per call index, so a CloudDNS test asserts
// the exact `hcloud zone rrset …` invocations without shelling out to hcloud.
type recordedRun struct {
	calls   [][]string // full argv per call (name + args)
	outputs []string   // scripted combined output per call
	errs    []error    // scripted error per call
}

func (r *recordedRun) run(_ context.Context, name string, args ...string) (string, error) {
	argv := append([]string{name}, args...)
	i := len(r.calls)
	r.calls = append(r.calls, argv)
	out := ""
	if i < len(r.outputs) {
		out = r.outputs[i]
	}
	var err error
	if i < len(r.errs) {
		err = r.errs[i]
	}
	return out, err
}

// TestHcloudZoneRRSetArgv asserts the PURE upsert argv builder for both the apex
// (empty name → "@") and a sub-name, an A record with a value. set-records
// carries NO --ttl flag, so the TTL never appears in this argv.
func TestHcloudZoneRRSetArgv(t *testing.T) {
	tests := []struct {
		desc string
		rec  Record
		want []string
	}{
		{
			desc: "sub-name A record",
			rec:  Record{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "10.0.0.1", TTL: 60},
			want: []string{"hcloud", "zone", "rrset", "set-records", "barkpark.cloud", "acme", "A", "--record", "10.0.0.1"},
		},
		{
			desc: "apex A record (empty name → @)",
			rec:  Record{Zone: "barkpark.cloud", Name: "", Type: "A", Value: "10.0.0.2"},
			want: []string{"hcloud", "zone", "rrset", "set-records", "barkpark.cloud", "@", "A", "--record", "10.0.0.2"},
		},
		{
			desc: "default type A when empty",
			rec:  Record{Zone: "barkpark.cloud", Name: "x", Value: "10.0.0.3"},
			want: []string{"hcloud", "zone", "rrset", "set-records", "barkpark.cloud", "x", "A", "--record", "10.0.0.3"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.desc, func(t *testing.T) {
			if got := hcloudZoneRRSetArgv(tt.rec); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("hcloudZoneRRSetArgv = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestHcloudZoneRRSetTTLArgv asserts the PURE change-ttl argv builder.
func TestHcloudZoneRRSetTTLArgv(t *testing.T) {
	rec := Record{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "10.0.0.1", TTL: 120}
	want := []string{"hcloud", "zone", "rrset", "change-ttl", "barkpark.cloud", "acme", "A", "--ttl", "120"}
	if got := hcloudZoneRRSetTTLArgv(rec); !reflect.DeepEqual(got, want) {
		t.Fatalf("hcloudZoneRRSetTTLArgv = %v, want %v", got, want)
	}
}

// TestHcloudZoneRRSetDeleteArgv asserts the PURE delete argv builder for apex
// and sub-name, with the A default.
func TestHcloudZoneRRSetDeleteArgv(t *testing.T) {
	tests := []struct {
		desc string
		zone string
		name string
		typ  string
		want []string
	}{
		{
			desc: "sub-name",
			zone: "barkpark.cloud", name: "acme", typ: "A",
			want: []string{"hcloud", "zone", "rrset", "delete", "barkpark.cloud", "acme", "A"},
		},
		{
			desc: "apex (empty name → @)",
			zone: "barkpark.cloud", name: "", typ: "A",
			want: []string{"hcloud", "zone", "rrset", "delete", "barkpark.cloud", "@", "A"},
		},
		{
			desc: "default type A",
			zone: "barkpark.cloud", name: "acme", typ: "",
			want: []string{"hcloud", "zone", "rrset", "delete", "barkpark.cloud", "acme", "A"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.desc, func(t *testing.T) {
			if got := hcloudZoneRRSetDeleteArgv(tt.zone, tt.name, tt.typ); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("hcloudZoneRRSetDeleteArgv = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestHcloudZoneRRSetListArgv asserts the PURE list argv builder.
func TestHcloudZoneRRSetListArgv(t *testing.T) {
	want := []string{"hcloud", "zone", "rrset", "list", "barkpark.cloud", "-o", "json"}
	if got := hcloudZoneRRSetListArgv("barkpark.cloud"); !reflect.DeepEqual(got, want) {
		t.Fatalf("hcloudZoneRRSetListArgv = %v, want %v", got, want)
	}
}

// TestCloudDNSUpsertRecord drives UpsertRecord with an injected fake runner and
// asserts BOTH the set-records call and the follow-up change-ttl call (TTL > 0)
// carry the right argv.
func TestCloudDNSUpsertRecord(t *testing.T) {
	rr := &recordedRun{}
	c := &CloudDNS{Run: rr.run}

	rec := Record{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "10.0.0.1", TTL: 60}
	if err := c.UpsertRecord(context.Background(), rec); err != nil {
		t.Fatalf("UpsertRecord: %v", err)
	}

	if len(rr.calls) != 2 {
		t.Fatalf("got %d calls, want 2 (set-records + change-ttl); calls=%v", len(rr.calls), rr.calls)
	}
	wantSet := []string{"hcloud", "zone", "rrset", "set-records", "barkpark.cloud", "acme", "A", "--record", "10.0.0.1"}
	if !reflect.DeepEqual(rr.calls[0], wantSet) {
		t.Errorf("set-records argv = %v, want %v", rr.calls[0], wantSet)
	}
	wantTTL := []string{"hcloud", "zone", "rrset", "change-ttl", "barkpark.cloud", "acme", "A", "--ttl", "60"}
	if !reflect.DeepEqual(rr.calls[1], wantTTL) {
		t.Errorf("change-ttl argv = %v, want %v", rr.calls[1], wantTTL)
	}
}

// TestCloudDNSUpsertRecordNoTTL asserts a zero TTL skips the change-ttl call —
// only set-records is invoked.
func TestCloudDNSUpsertRecordNoTTL(t *testing.T) {
	rr := &recordedRun{}
	c := &CloudDNS{Run: rr.run}

	rec := Record{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "10.0.0.1"} // TTL 0
	if err := c.UpsertRecord(context.Background(), rec); err != nil {
		t.Fatalf("UpsertRecord: %v", err)
	}
	if len(rr.calls) != 1 {
		t.Fatalf("got %d calls, want 1 (set-records only, no TTL); calls=%v", len(rr.calls), rr.calls)
	}
}

// TestCloudDNSUpsertSurfacesStderr asserts a set-records failure wraps the
// runner's captured output — not a bare "exit status 1".
func TestCloudDNSUpsertSurfacesStderr(t *testing.T) {
	rr := &recordedRun{
		outputs: []string{"hcloud: invalid zone"},
		errs:    []error{errors.New("exit status 1")},
	}
	c := &CloudDNS{Run: rr.run}

	err := c.UpsertRecord(context.Background(), Record{Zone: "barkpark.cloud", Name: "acme", Type: "A", Value: "10.0.0.1"})
	if err == nil {
		t.Fatalf("UpsertRecord = nil, want error")
	}
	if !strings.Contains(err.Error(), "hcloud: invalid zone") {
		t.Errorf("error %q does not surface runner output", err.Error())
	}
}

// TestCloudDNSDeleteRecord asserts DeleteRecord invokes the delete argv.
func TestCloudDNSDeleteRecord(t *testing.T) {
	rr := &recordedRun{}
	c := &CloudDNS{Run: rr.run}

	if err := c.DeleteRecord(context.Background(), "barkpark.cloud", "acme", "A"); err != nil {
		t.Fatalf("DeleteRecord: %v", err)
	}
	want := []string{"hcloud", "zone", "rrset", "delete", "barkpark.cloud", "acme", "A"}
	if len(rr.calls) != 1 || !reflect.DeepEqual(rr.calls[0], want) {
		t.Fatalf("DeleteRecord calls = %v, want one call %v", rr.calls, want)
	}
}

// TestCloudDNSDeleteIdempotent asserts a "not found" failure is swallowed (the
// rrset is already absent — the desired end state holds).
func TestCloudDNSDeleteIdempotent(t *testing.T) {
	rr := &recordedRun{
		outputs: []string{"hcloud: Zone RRSet not found: barkpark.cloud acme A"},
		errs:    []error{errors.New("exit status 1")},
	}
	c := &CloudDNS{Run: rr.run}

	if err := c.DeleteRecord(context.Background(), "barkpark.cloud", "acme", "A"); err != nil {
		t.Fatalf("DeleteRecord on absent rrset = %v, want nil (idempotent)", err)
	}
}

// TestCloudDNSDeleteSurfacesStderr asserts a NON-"not found" delete failure
// surfaces the runner's captured output.
func TestCloudDNSDeleteSurfacesStderr(t *testing.T) {
	rr := &recordedRun{
		outputs: []string{"hcloud: rrset is protected"},
		errs:    []error{errors.New("exit status 1")},
	}
	c := &CloudDNS{Run: rr.run}

	err := c.DeleteRecord(context.Background(), "barkpark.cloud", "acme", "A")
	if err == nil {
		t.Fatalf("DeleteRecord = nil, want error for a non-'not found' failure")
	}
	if !strings.Contains(err.Error(), "rrset is protected") {
		t.Errorf("error %q does not surface runner output", err.Error())
	}
}

// TestCloudDNSResolve drives Resolve against a fake runner serving a JSON
// rrset list and asserts it (a) lists the right zone and (b) returns the
// matching sub-name's values, sorted.
func TestCloudDNSResolve(t *testing.T) {
	listJSON := `[
	  {"name":"@","type":"A","records":[{"value":"203.0.113.9"}]},
	  {"name":"acme","type":"A","records":[{"value":"10.0.0.2"},{"value":"10.0.0.1"}]}
	]`
	rr := &recordedRun{outputs: []string{listJSON}}
	c := &CloudDNS{Run: rr.run}

	got, err := c.Resolve(context.Background(), "acme.barkpark.cloud")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"10.0.0.1", "10.0.0.2"}) {
		t.Fatalf("Resolve = %v, want sorted [10.0.0.1 10.0.0.2]", got)
	}
	wantList := []string{"hcloud", "zone", "rrset", "list", "barkpark.cloud", "-o", "json"}
	if len(rr.calls) != 1 || !reflect.DeepEqual(rr.calls[0], wantList) {
		t.Fatalf("Resolve list call = %v, want %v", rr.calls, wantList)
	}
}

// TestCloudDNSResolveApex asserts a bare zone resolves the apex ("@") rrset.
func TestCloudDNSResolveApex(t *testing.T) {
	listJSON := `[{"name":"@","type":"A","records":[{"value":"203.0.113.9"}]}]`
	rr := &recordedRun{outputs: []string{listJSON}}
	c := &CloudDNS{Run: rr.run}

	got, err := c.Resolve(context.Background(), "barkpark.cloud")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"203.0.113.9"}) {
		t.Fatalf("Resolve apex = %v, want [203.0.113.9]", got)
	}
}

// TestCloudDNSSatisfiesInterface is a runtime check that CloudDNS is usable
// wherever a DNSProvider is expected (the warm-pool seam).
func TestCloudDNSSatisfiesInterface(t *testing.T) {
	var d DNSProvider = NewCloudDNS()
	_ = d
}
