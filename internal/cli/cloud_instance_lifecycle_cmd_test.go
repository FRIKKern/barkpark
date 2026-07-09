package cli

// cloud_instance_lifecycle_cmd_test.go proves the provider-neutral fleet-lifecycle
// surface (S9): hetzner dispatch is BYTE-IDENTICAL to `bp cloud hetzner instance …`
// (the guts are untouched), azure gets a real CLI-level decommission + audit that
// run fully OFFLINE (fake azure provider, httptest DNS + control plane), and every
// unsupported (provider, verb) degrades with a printed reason. Zero live calls.

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// ── two-source detection wiring ──────────────────────────────────────────────

// TestLifecycleDispatchRegistersFacets proves the dispatch table IS the second
// capability source: DetectCapabilities reports hetzner's all-five (registered,
// since its lifecycle lives in free functions) and azure's decommission+audit
// (registered from the dispatch table), matching the committed fixture.
func TestLifecycleDispatchRegistersFacets(t *testing.T) {
	// hetzner: the credential-less struct implements NO facet interface, so every
	// true facet here comes from RegisterLifecycleVerbs.
	hz := cloud.DetectCapabilities(cloud.ProviderHetzner, cloud.HcloudProvider{})
	if !(hz.Archive && hz.Resurrect && hz.Decommission && hz.Adopt && hz.Audit) {
		t.Errorf("hetzner should register all five lifecycle facets: %+v", hz)
	}

	for _, k := range azureEnvVars {
		t.Setenv(k, "")
	}
	p, err := cloud.ProviderFor(cloud.ProviderAzure, completeAzureCreds())
	if err != nil {
		t.Fatalf("ProviderFor(azure): %v", err)
	}
	az := cloud.DetectCapabilities(cloud.ProviderAzure, p)
	if !(az.Decommission && az.Audit) {
		t.Errorf("azure should register decommission+audit: %+v", az)
	}
	if az.Archive || az.Resurrect || az.Adopt {
		t.Errorf("azure must NOT claim archive/resurrect/adopt: %+v", az)
	}
}

// TestHetznerDispatchMatchesRegisteredVerbs pins the cli dispatch table's hetzner
// verbs equal to the seam's canonical HetznerLifecycleVerbs, so the two
// registration sources (cloud-package baseline, cli dispatch) can never drift.
func TestHetznerDispatchMatchesRegisteredVerbs(t *testing.T) {
	got := make([]string, 0, len(lifecycleDispatch[cloud.ProviderHetzner]))
	for v := range lifecycleDispatch[cloud.ProviderHetzner] {
		got = append(got, v)
	}
	want := append([]string(nil), cloud.HetznerLifecycleVerbs...)
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("hetzner dispatch verbs %v != canonical %v", got, want)
	}
}

// ── hetzner neutral == escape hatch (byte-identical) ─────────────────────────

// TestNeutralHetznerLifecycleByteIdentical runs the SAME archive scenario two ways
// — `bp cloud hetzner instance archive` and `bp cloud instance archive --provider
// hetzner` — and asserts identical stdout + exit. That is the refute that the
// neutral surface only strips --provider and forwards to the existing free
// function, guts untouched.
func TestNeutralHetznerLifecycleByteIdentical(t *testing.T) {
	run := func(args ...string) (string, int) {
		instTestTuning(t)
		f := newFakeHzAPI(t)
		f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Query().Get("name") != "" {
				hzWriteJSON(w, 200, `{"servers":[]}`)
				return
			}
			hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
		})
		f.mux.HandleFunc("POST /servers/9/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 201, `{"image":{"id":777,"type":"snapshot"},"action":{"id":31,"status":"success","progress":100}}`)
		})
		f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success","progress":100}]}`)
		})
		stdout, _, code := runHzCLI(t, "json", args...)
		return stdout, code
	}

	escOut, escCode := run("hetzner", "instance", "archive", "okey.barkpark.cloud")
	neuOut, neuCode := run("instance", "archive", "--provider", "hetzner", "okey.barkpark.cloud")
	if escCode != exitOK || neuCode != exitOK {
		t.Fatalf("archive exit codes: escape=%d neutral=%d", escCode, neuCode)
	}
	if escOut != neuOut {
		t.Errorf("neutral hetzner archive is NOT byte-identical to the escape hatch:\n escape:  %q\n neutral: %q", escOut, neuOut)
	}
	if !strings.Contains(neuOut, "777") {
		t.Errorf("archive receipt missing the image id: %s", neuOut)
	}
}

// TestNeutralHetznerDecommissionThreadsRegistryFlags proves the registry flags
// (--control-url/--worker-token) thread through the neutral surface unchanged — a
// live registry row is deprovisioned via the worker queue exactly as on the
// escape hatch.
func TestNeutralHetznerDecommissionThreadsRegistryFlags(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-1", Slug: "okey", Host: "192.0.2.9", DNSLabel: "okey",
		URL: "https://okey.barkpark.cloud", Mode: "managed",
	}})
	tornDown := false
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" || tornDown {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("POST /servers/9/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"image":{"id":777,"type":"snapshot"},"action":{"id":31,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		if tornDown {
			hzWriteJSON(w, 200, `{"rrsets":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"okey/A","name":"okey","type":"A","records":[{"value":"192.0.2.9"}]}]}`)
	})
	base := cp.srv.Config.Handler
	cp.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/deprovision") {
			tornDown = true
		}
		base.ServeHTTP(w, r)
	})

	stdout, stderr, code := runHzCLI(t, "json", "instance", "decommission", "--provider", "hetzner",
		"okey.barkpark.cloud", "--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("neutral decommission exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	deprovisioned := false
	for _, r := range cp.requests() {
		if strings.Contains(r, "POST /v1/internal/barkparks/row-1/deprovision") {
			deprovisioned = true
		}
	}
	if !deprovisioned {
		t.Error("neutral decommission never threaded the registry flags to deprovision the row")
	}
}

// ── azure decommission (offline, no archive) ─────────────────────────────────

// TestAzureDecommissionOfflineEndToEnd exercises the whole azure teardown: the
// unrecoverable warning, VM+NIC+PIP delete (via the fake provider), the
// hetzner-zone A-record delete, the registry DETACH (azure boxes are torn down by
// us, not the hetzner worker queue), and the residue verification — zero live
// calls.
func TestAzureDecommissionOfflineEndToEnd(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	azFake := cloud.NewFakeProvider()
	if _, err := azFake.Create(context.Background(), cloud.ServerSpec{Name: "web-1"}); err != nil {
		t.Fatalf("seed fake vm: %v", err)
	}
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })

	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-az", Slug: "web-1", DNSLabel: "web-1",
		URL: "https://web-1.barkpark.cloud", Mode: "managed",
	}})

	rrsetDeleted := false
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/web-1/A", func(w http.ResponseWriter, r *http.Request) {
		rrsetDeleted = true
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		if rrsetDeleted {
			hzWriteJSON(w, 200, `{"rrsets":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"web-1/A","name":"web-1","type":"A","records":[{"value":"20.0.0.9"}]}]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "instance", "decommission", "--provider", "azure",
		"web-1.barkpark.cloud", "--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("azure decommission exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	// Compute torn down.
	if _, err := azFake.IP(context.Background(), "web-1"); err == nil {
		t.Error("azure VM was not deleted from compute")
	}
	if !rrsetDeleted {
		t.Error("azure decommission never deleted the A record")
	}
	// Registry DETACHED (not the worker queue).
	detached := false
	for _, r := range cp.requests() {
		if strings.Contains(r, "row-az/deprovision") && strings.Contains(r, "detach") {
			detached = true
		}
	}
	if !detached {
		t.Error("azure registry row was not detached (registry-only removal)")
	}
	// The unrecoverable warning is visible on stderr AND in the report.
	if !strings.Contains(stderr, "UNRECOVERABLE") {
		t.Errorf("missing unrecoverable warning on stderr:\n%s", stderr)
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report not JSON: %v: %s", err, stdout)
	}
	if report["ok"] != true {
		t.Errorf("report.ok=%v residue=%v", report["ok"], report["residue"])
	}
	if w, _ := report["warning"].(string); !strings.Contains(w, "UNRECOVERABLE") {
		t.Errorf("report.warning missing the unrecoverable notice: %v", report["warning"])
	}
}

// ── azure audit (offline, archives skipped) ──────────────────────────────────

// TestAzureAuditOfflineSkipsArchives cross-checks compute + DNS + registry for a
// coherent azure fleet and asserts the honest archive-skip note is present, with a
// clean (findings-empty, exit 0) result.
func TestAzureAuditOfflineSkipsArchives(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	azFake := cloud.NewFakeProvider()
	if _, err := azFake.Create(context.Background(), cloud.ServerSpec{Name: "web-1"}); err != nil {
		t.Fatalf("seed fake vm: %v", err)
	}
	// Stamp the fqdn tag so the cross-check has an identity to match.
	if err := azFake.LabelServer(context.Background(), "web-1", cloud.FQDNLabelKey, "web-1.barkpark.cloud"); err != nil {
		t.Fatalf("tag fake vm: %v", err)
	}
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })

	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-az", Slug: "web-1", DNSLabel: "web-1",
		URL: "https://web-1.barkpark.cloud", Mode: "managed",
	}})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"web-1/A","name":"web-1","type":"A","records":[{"value":"20.0.0.9"}]}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "instance", "audit", "--provider", "azure",
		"--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("azure audit exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report not JSON: %v: %s", err, stdout)
	}
	if report["ok"] != true {
		t.Errorf("clean azure fleet should audit ok; findings=%v", report["findings"])
	}
	if report["archives_checked"] != false {
		t.Errorf("azure audit must report archives_checked=false: %v", report["archives_checked"])
	}
	if note, _ := report["note"].(string); !strings.Contains(note, "no archives") {
		t.Errorf("azure audit missing the honest archive-skip note: %v", report["note"])
	}
	if report["servers"].(float64) != 1 {
		t.Errorf("azure audit should count the one managed VM: %v", report["servers"])
	}
}

// TestAzureAuditFlagsResidue proves the cross-check actually bites: a DNS record
// with no managed VM and no registry row surfaces as a finding and a non-zero exit.
func TestAzureAuditFlagsResidue(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	azFake := cloud.NewFakeProvider() // no VMs
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })

	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"ghost/A","name":"ghost","type":"A","records":[{"value":"20.0.0.9"}]}]}`)
	})

	stdout, _, code := runHzCLI(t, "json", "instance", "audit", "--provider", "azure")
	if code != exitGeneric {
		t.Fatalf("azure audit with an orphan A record should exit %d, got %d\n%s", exitGeneric, code, stdout)
	}
	if !strings.Contains(stdout, "dns-unmatched") {
		t.Errorf("audit should flag the orphan A record: %s", stdout)
	}
}

// ── honest degradation ───────────────────────────────────────────────────────

// TestNeutralLifecycleDegrades: azure archive (a facet azure lacks) and fake
// archive (no CLI dispatch) both degrade with a printed reason; an unknown
// provider is a usage error. None builds a provider or touches the network.
func TestNeutralLifecycleDegrades(t *testing.T) {
	// azure lacks the archive facet.
	_, stderr, code := runInstanceCapture(t, "table", "archive", "--provider", "azure", "web-1")
	if code != exitGeneric {
		t.Fatalf("azure archive should degrade with exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	for _, want := range []string{"azure", "does not support", "archive"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("azure archive degrade missing %q:\n%s", want, stderr)
		}
	}
	// fake has the facet INTERFACES but no CLI dispatch entry, so the neutral
	// verb degrades (its capability row stays honest for the seam; the CLI-level
	// wiring is deliberately hetzner+azure only).
	_, stderr, code = runInstanceCapture(t, "table", "archive", "--provider", "fake", "web-1")
	if code != exitGeneric {
		t.Fatalf("fake archive should degrade with exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	if !strings.Contains(stderr, "does not support") {
		t.Errorf("fake archive degrade missing the honest reason:\n%s", stderr)
	}
	// unknown provider → usage.
	_, stderr, code = runInstanceCapture(t, "table", "audit", "--provider", "gcp")
	if code != exitUsage {
		t.Fatalf("unknown provider should be usage exit %d, got %d\n%s", exitUsage, code, stderr)
	}
	if !strings.Contains(stderr, "gcp") {
		t.Errorf("unknown-provider error should name the bad kind:\n%s", stderr)
	}
}

// ── pause / resume ───────────────────────────────────────────────────────────

// TestPauseResumeRouting: hetzner does not honour pause and degrades with a
// reason; a registered Pauser (a fake) pauses and resumes an existing box.
func TestPauseResumeRouting(t *testing.T) {
	t.Setenv("HCLOUD_TOKEN", "test-token") // hetzner provider builds without shelling out

	_, stderr, code := runInstanceCapture(t, "table", "pause", "web-1", "--provider", "hetzner")
	if code != exitGeneric {
		t.Fatalf("hetzner pause should degrade with exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	for _, want := range []string{"hetzner", "does not support", "pause"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("hetzner pause degrade missing %q:\n%s", want, stderr)
		}
	}

	shared := cloud.NewFakeProvider()
	if _, err := shared.Create(context.Background(), cloud.ServerSpec{Name: "box"}); err != nil {
		t.Fatalf("seed box: %v", err)
	}
	cloud.Register("s9pause", func(map[string]string) (cloud.CloudProvider, error) { return shared, nil })

	stdout, stderr, code := runInstanceCapture(t, "table", "pause", "box", "--provider", "s9pause")
	if code != exitOK {
		t.Fatalf("fake pause exit=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "paused") {
		t.Errorf("pause receipt missing: %s", stdout)
	}
	stdout, stderr, code = runInstanceCapture(t, "table", "resume", "box", "--provider", "s9pause")
	if code != exitOK {
		t.Fatalf("fake resume exit=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "resumed") {
		t.Errorf("resume receipt missing: %s", stdout)
	}
}
