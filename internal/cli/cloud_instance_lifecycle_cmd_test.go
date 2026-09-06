package cli

// cloud_instance_lifecycle_cmd_test.go proves the provider-neutral fleet-lifecycle
// surface (S9): hetzner dispatch is BYTE-IDENTICAL to `bp cloud hetzner instance …`
// (the guts are untouched), azure gets a real CLI-level decommission + audit that
// run fully OFFLINE (fake azure provider, httptest DNS + control plane), and every
// unsupported (provider, verb) degrades with a printed reason. Zero live calls.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
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
	// archive (S14b, Decision 42: the portable bp-bundle-v1) and resurrect (S14d:
	// the portable-bundle restore target) are both registered via lifecycleDispatch;
	// only adopt stays unclaimed (a snapshot-based clone-swap).
	if !(az.Decommission && az.Audit && az.Archive && az.Resurrect) {
		t.Errorf("azure should register archive+decommission+audit+resurrect: %+v", az)
	}
	if az.Adopt {
		t.Errorf("azure must NOT claim adopt (snapshot clone-swap): %+v", az)
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

// TestNeutralHetznerLifecycleByteIdentical pins the S14b contract (Decision 42):
// the neutral archive is now the PORTABLE bp-bundle-v1, and `--fast` is the
// hetzner snapshot escape that stays BYTE-IDENTICAL to `bp cloud hetzner instance
// archive`. So two things must hold: neutral (no --fast) writes a bundle (a
// manifest lands in the store, and the receipt carries NO snapshot image id);
// `--fast` output equals the escape hatch's, byte-for-byte.
func TestNeutralHetznerLifecycleByteIdentical(t *testing.T) {
	wire := func(f *fakeHzAPI) {
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
	}
	runSnapshot := func(args ...string) (string, int) {
		instTestTuning(t)
		f := newFakeHzAPI(t)
		wire(f)
		stdout, _, code := runHzCLI(t, "json", args...)
		return stdout, code
	}

	// --fast == the escape hatch, byte-for-byte (the snapshot path is untouched).
	escOut, escCode := runSnapshot("hetzner", "instance", "archive", "okey.barkpark.cloud")
	fastOut, fastCode := runSnapshot("instance", "archive", "--provider", "hetzner", "--fast", "okey.barkpark.cloud")
	if escCode != exitOK || fastCode != exitOK {
		t.Fatalf("archive exit codes: escape=%d fast=%d", escCode, fastCode)
	}
	if escOut != fastOut {
		t.Errorf("--fast hetzner archive is NOT byte-identical to the escape hatch:\n escape: %q\n fast:   %q", escOut, fastOut)
	}
	if !strings.Contains(fastOut, "777") {
		t.Errorf("--fast snapshot receipt missing the image id: %s", fastOut)
	}

	// Neutral (no --fast) writes a PORTABLE bundle, not a snapshot.
	st := withFakeBundleStore(t)
	withFakeRemoteStream(t, cannedBundleTar(t))
	instTestTuning(t)
	f := newFakeHzAPI(t)
	wire(f)
	stdout, stderr, code := runHzCLI(t, "json", "instance", "archive", "--provider", "hetzner", "okey.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("neutral bundle archive exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	keys := bundleManifestKeys(t, st)
	if len(keys) != 1 {
		t.Fatalf("neutral archive should land exactly one bp-bundle-v1 manifest, got %v", keys)
	}
	if !strings.Contains(keys[0], "okey.barkpark.cloud") || !strings.HasPrefix(keys[0], "archives/") {
		t.Errorf("manifest key is not the pinned archives/<team>/<fqdn>/<stamp>/ layout: %s", keys[0])
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report not JSON: %v: %s", err, stdout)
	}
	if report["ok"] != true {
		t.Errorf("bundle archive not ok: %v", report)
	}
	b, _ := report["bundle"].(map[string]any)
	if b == nil || b["format"] != "bp-bundle-v1" {
		t.Errorf("neutral archive receipt missing the bp-bundle-v1 bundle: %v", report)
	}
	if strings.Contains(stdout, "image_id") {
		t.Errorf("neutral archive must NOT take a snapshot (no image_id):\n%s", stdout)
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

func TestAzureAuditDNSZoneNotFoundHintsSeparateToken(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	t.Setenv("HCLOUD_TOKEN", "compute-secret")
	azFake := cloud.NewFakeProvider()
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, http.StatusNotFound, `{"error":{"code":"not_found","message":"Zone not found"}}`)
	})

	_, stderr, code := runHzCLI(t, "table", "instance", "audit", "--provider", "azure")
	if code != exitNotFound {
		t.Fatalf("azure audit zone lookup exited %d, want %d; stderr: %s", code, exitNotFound, stderr)
	}
	for _, want := range []string{"BARKPARK_DNS_HCLOUD_TOKEN", "cloud/postfix/README.md", "Zone not found"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("azure audit error missing %q hint context: %s", want, stderr)
		}
	}
	if strings.Contains(stderr, "compute-secret") {
		t.Errorf("azure audit error exposed compute token: %s", stderr)
	}
}

func TestAzureAuditDNSZoneNotFoundWithEnvTokenDoesNotHint(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	t.Setenv("BARKPARK_DNS_HCLOUD_TOKEN", "dns-secret")
	azFake := cloud.NewFakeProvider()
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, http.StatusNotFound, `{"error":{"code":"not_found","message":"Zone not found"}}`)
	})

	_, stderr, code := runHzCLI(t, "table", "instance", "audit", "--provider", "azure")
	if code != exitNotFound {
		t.Fatalf("azure audit zone lookup exited %d, want %d; stderr: %s", code, exitNotFound, stderr)
	}
	for _, absent := range []string{"BARKPARK_DNS_HCLOUD_TOKEN", "cloud/postfix/README.md", "dns-secret"} {
		if strings.Contains(stderr, absent) {
			t.Errorf("azure audit error unexpectedly contains %q: %s", absent, stderr)
		}
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

// TestAzureCreateThenAuditIsClean proves the identity loop closes: a box created
// through the COMMAND PATH (`bp cloud azure create`, which stamps barkpark-fqdn in
// doInstanceCreate) audits clean with NO manual LabelServer — unlike
// TestAzureAuditOfflineSkipsArchives, which hand-stamps the tag. This is the whole
// point of the slice: create gives the box its identity so audit stops flagging it.
func TestAzureCreateThenAuditIsClean(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	azFake := cloud.NewFakeProvider()
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })

	// Create via the escape-hatch command — NO manual LabelServer. doInstanceCreate
	// stamps barkpark-fqdn=web-1.barkpark.cloud on the fake through ServerLabeler.
	stdout, stderr, code := runAzureCapture(t, "json", "create", "--name", "web-1")
	if code != exitOK {
		t.Fatalf("azure create exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	// The receipt must carry the stamped identity.
	if !strings.Contains(stdout, "web-1.barkpark.cloud") {
		t.Fatalf("create receipt missing the stamped %s identity:\n%s", cloud.FQDNLabelKey, stdout)
	}
	// And it is on the box as a real tag (not just a printed string).
	got, err := azFake.ListByLabel(context.Background(), cloud.FQDNLabelKey, "web-1.barkpark.cloud")
	if err != nil || len(got) != 1 || got[0].Name != "web-1" {
		t.Fatalf("create did not stamp %s on the box: %+v (err=%v)", cloud.FQDNLabelKey, got, err)
	}

	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-az", Slug: "web-1", DNSLabel: "web-1",
		URL: "https://web-1.barkpark.cloud", Mode: "managed",
	}})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"web-1/A","name":"web-1","type":"A","records":[{"value":"20.0.0.9"}]}]}`)
	})

	stdout, stderr, code = runHzCLI(t, "json", "instance", "audit", "--provider", "azure",
		"--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("audit of a command-created box should be clean; exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	if strings.Contains(stdout, "unlabeled-vm") {
		t.Errorf("a command-created box must NOT be flagged unlabeled:\n%s", stdout)
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report not JSON: %v: %s", err, stdout)
	}
	if report["ok"] != true {
		t.Errorf("clean audit expected; findings=%v", report["findings"])
	}
}

// TestAzureAuditFlagsTrulyUnlabeledVM refutes over-exemption: a managed VM with
// NO barkpark-fqdn and NO barkpark-warm tag (a real orphan) still surfaces as an
// unlabeled-vm finding with a non-zero exit — the warm exemption must not swallow
// genuine orphans.
func TestAzureAuditFlagsTrulyUnlabeledVM(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	azFake := cloud.NewFakeProvider()
	// Managed (Create stamps barkpark-managed) but never given its fqdn identity.
	if _, err := azFake.Create(context.Background(), cloud.ServerSpec{Name: "ghost-vm"}); err != nil {
		t.Fatalf("seed vm: %v", err)
	}
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })

	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[]}`)
	})

	stdout, _, code := runHzCLI(t, "json", "instance", "audit", "--provider", "azure")
	if code != exitGeneric {
		t.Fatalf("a truly unlabeled managed VM should exit %d, got %d\n%s", exitGeneric, code, stdout)
	}
	if !strings.Contains(stdout, "unlabeled-vm") {
		t.Errorf("audit should flag the unlabeled managed VM:\n%s", stdout)
	}
}

// TestAzureAuditExemptsWarmBox proves the exemption: a pre-baked warm box carries
// barkpark-warm but no barkpark-fqdn (its identity is stamped only at assign), so
// the audit must NOT flag it as unlabeled — it is inventory, not an orphan.
func TestAzureAuditExemptsWarmBox(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	azFake := cloud.NewFakeProvider()
	if _, err := azFake.Create(context.Background(), cloud.ServerSpec{Name: "warm-9"}); err != nil {
		t.Fatalf("seed warm box: %v", err)
	}
	// Mark it warm — legitimately fqdn-less until an assign stamps its identity.
	if err := azFake.LabelServer(context.Background(), "warm-9", cloud.WarmLabelKey, "true"); err != nil {
		t.Fatalf("mark warm: %v", err)
	}
	oldBuilder := azureProviderBuilder
	azureProviderBuilder = func(map[string]string) (cloud.CloudProvider, error) { return azFake, nil }
	t.Cleanup(func() { azureProviderBuilder = oldBuilder })

	// Empty zone: no DNS records, no registry — the warm box is the only survivor,
	// and it must not become a finding.
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "instance", "audit", "--provider", "azure")
	if code != exitOK {
		t.Fatalf("a fleet of only a warm box should audit clean; exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	if strings.Contains(stdout, "unlabeled-vm") {
		t.Errorf("a warm box must be EXEMPT from the unlabeled-vm finding:\n%s", stdout)
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report not JSON: %v: %s", err, stdout)
	}
	if report["servers"].(float64) != 1 {
		t.Errorf("the warm box is still a counted managed VM: %v", report["servers"])
	}
	if report["ok"] != true {
		t.Errorf("warm-only fleet should audit ok; findings=%v", report["findings"])
	}
}

// ── honest degradation ───────────────────────────────────────────────────────

// TestNeutralLifecycleDegrades: azure ADOPT (its one remaining gap now that
// archive (S14b) and resurrect (S14d) ride the portable bundle) and a genuinely
// facet-less provider both degrade with a printed reason; an unknown provider is
// a usage error. None of these paths touch the network.
func TestNeutralLifecycleDegrades(t *testing.T) {
	// azure lacks the adopt facet (dispatch has archive+resurrect+decommission+audit).
	_, stderr, code := runInstanceCapture(t, "table", "adopt", "--provider", "azure", "box.barkpark.cloud", "acme")
	if code != exitGeneric {
		t.Fatalf("azure adopt should degrade with exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	for _, want := range []string{"azure", "does not support", "adopt"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("azure adopt degrade missing %q:\n%s", want, stderr)
		}
	}
	// A registered provider that satisfies ONLY cloud.CloudProvider (no facet
	// interface, no dispatch entry) degrades honestly through the generic facet
	// executor — the assert fails, so there is no fake-parity button.
	cloud.Register("s9facetless", func(map[string]string) (cloud.CloudProvider, error) {
		return coreOnlyProvider{}, nil
	})
	_, stderr, code = runInstanceCapture(t, "table", "resurrect", "--provider", "s9facetless", "web-1")
	if code != exitGeneric {
		t.Fatalf("facet-less resurrect should degrade with exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	if !strings.Contains(stderr, "does not support") {
		t.Errorf("facet-less resurrect degrade missing the honest reason:\n%s", stderr)
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

// TestNeutralFakeFacetsExecute proves the generic facet executor actually RUNS the
// fake provider's facet interfaces instead of degrading — closing the parity-gate
// lie (Decision 29). archive returns a synthetic receipt, adopt validates its
// inputs, decommission of a seeded box succeeds while an unknown box is a
// not-found error, and audit reports a clean cross-check. Zero network.
func TestNeutralFakeFacetsExecute(t *testing.T) {
	// archive → a PORTABLE bp-bundle-v1 lands in the store (Decision 42), and the
	// receipt keeps the fake archive-id lineage. This proves the full write path
	// offline: synthetic payload → the S14a writer → FakeBundleStore.
	st := withFakeBundleStore(t)
	stdout, stderr, code := runInstanceCapture(t, "json", "archive", "--provider", "fake", "web-1")
	if code != exitOK {
		t.Fatalf("fake archive should succeed, got exit %d\n%s\n%s", code, stdout, stderr)
	}
	var arch map[string]any
	if err := json.Unmarshal([]byte(stdout), &arch); err != nil {
		t.Fatalf("archive report not JSON: %v: %s", err, stdout)
	}
	if arch["ok"] != true {
		t.Errorf("archive report.ok=%v", arch["ok"])
	}
	if a, _ := arch["archive"].(map[string]any); a == nil || !strings.Contains(a["id"].(string), "fake-archive-web-1") {
		t.Errorf("archive receipt missing the synthetic id: %v", arch["archive"])
	}
	if b, _ := arch["bundle"].(map[string]any); b == nil || b["format"] != "bp-bundle-v1" {
		t.Errorf("fake archive receipt missing the bp-bundle-v1 bundle: %v", arch["bundle"])
	}
	if keys := bundleManifestKeys(t, st); len(keys) != 1 {
		t.Errorf("fake archive should write exactly one manifest, got %v", keys)
	}

	// adopt validates its two inputs and succeeds.
	stdout, stderr, code = runInstanceCapture(t, "json", "adopt", "--provider", "fake", "box.barkpark.cloud", "acme")
	if code != exitOK {
		t.Fatalf("fake adopt should succeed, got exit %d\n%s\n%s", code, stdout, stderr)
	}

	// decommission needs a live box: seed one under a test slug, tear it down,
	// then prove an unknown target is a not-found FAILURE (not a silent success).
	shared := cloud.NewFakeProvider()
	if _, err := shared.Create(context.Background(), cloud.ServerSpec{Name: "web-9"}); err != nil {
		t.Fatalf("seed box: %v", err)
	}
	cloud.Register("s9decomm", func(map[string]string) (cloud.CloudProvider, error) { return shared, nil })

	stdout, stderr, code = runInstanceCapture(t, "json", "decommission", "--provider", "s9decomm", "web-9")
	if code != exitOK {
		t.Fatalf("fake decommission of a live box should succeed, got exit %d\n%s\n%s", code, stdout, stderr)
	}
	stdout, stderr, code = runInstanceCapture(t, "json", "decommission", "--provider", "s9decomm", "ghost")
	if code != exitGeneric {
		t.Fatalf("fake decommission of an unknown box should fail with exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	if !strings.Contains(stdout+stderr, "not found") {
		t.Errorf("unknown-box decommission should surface a not-found error:\nstdout=%s\nstderr=%s", stdout, stderr)
	}

	// audit cross-checks the fleet with a clean result.
	stdout, stderr, code = runInstanceCapture(t, "json", "audit", "--provider", "fake")
	if code != exitOK {
		t.Fatalf("fake audit should succeed, got exit %d\n%s\n%s", code, stdout, stderr)
	}
	var au map[string]any
	if err := json.Unmarshal([]byte(stdout), &au); err != nil {
		t.Fatalf("audit report not JSON: %v: %s", err, stdout)
	}
	if au["ok"] != true {
		t.Errorf("clean fake audit should report ok; got %v", au)
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

// task-688ebffc4b0aa50a — the by-name trap on the AZURE arm. Same law, same
// zone: `azure decommission` deleted (and verified) the fqdn's first label only,
// so the go-live `<label>-<teamid>` sibling at the same address outlived the VM
// while the receipt reported no residue. The sweep must take both names at the
// released address and spare a bystander sitting somewhere else.
func TestAzureDecommissionSweepsSiblingAtSameIPBystanderSurvives(t *testing.T) {
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

	var mu sync.Mutex
	zone := map[string]string{
		"web-1":          "20.0.0.9",
		"web-1-506f035e": "20.0.0.9",
		"bystander":      "20.0.0.77",
	}
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/{name}/A", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		delete(zone, r.PathValue("name"))
		mu.Unlock()
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		names := make([]string, 0, len(zone))
		for n := range zone {
			names = append(names, n)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, n := range names {
			parts = append(parts, `{"id":"`+n+`/A","name":"`+n+`","type":"A","records":[{"value":"`+zone[n]+`"}]}`)
		}
		mu.Unlock()
		hzWriteJSON(w, 200, `{"rrsets":[`+strings.Join(parts, ",")+`]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "instance", "decommission", "--provider", "azure",
		"web-1.barkpark.cloud", "--control-url", cp.srv.URL, "--worker-token", "wtok")

	mu.Lock()
	_, platformLeft := zone["web-1"]
	_, siblingLeft := zone["web-1-506f035e"]
	_, bystanderLeft := zone["bystander"]
	mu.Unlock()

	if platformLeft {
		t.Error("the platform A record web-1.barkpark.cloud survived the teardown")
	}
	if siblingLeft {
		t.Error("the go-live sibling web-1-506f035e.barkpark.cloud survived at the released VM address — a by-name delete left it standing (task-688ebffc4b0aa50a)")
	}
	if !bystanderLeft {
		t.Error("the by-value sweep took bystander.barkpark.cloud at a DIFFERENT address — the sweep is too wide")
	}
	if code != exitOK {
		t.Fatalf("azure decommission exit=%d stderr=%s stdout=%s", code, stderr, stdout)
	}
	var report map[string]any
	_ = json.Unmarshal([]byte(stdout), &report)
	if report["ok"] != true {
		t.Errorf("report.ok = %v, want true (residue: %v)", report["ok"], report["residue"])
	}
}

// task-688ebffc4b0aa50a — the azure VERIFY leg on its own seam. The command-level
// test above cannot reach it: azure's sweep and its verify read the SAME zone
// with the same credential, so whenever the sweep succeeds the verify is
// necessarily clean, and a mutation that blinds the verify alone stays green
// through the command. So the leg is driven directly, against a zone that still
// holds a sibling at the released address: it must NAME that survivor, and it
// must NOT re-report the platform label the by-name check above already covers.
func TestAzureVerifyGoneNamesSiblingAtReleasedIP(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[
			{"id":"web-1/A","name":"web-1","type":"A","records":[{"value":"20.0.0.9"}]},
			{"id":"web-1-506f035e/A","name":"web-1-506f035e","type":"A","records":[{"value":"20.0.0.9"}]},
			{"id":"bystander/A","name":"bystander","type":"A","records":[{"value":"20.0.0.77"}]}
		]}`)
	})

	dns := newHetznerClient("test-token").HCloud()
	out := newWriter(io.Discard, io.Discard)
	residue := azureVerifyGone(out, cloud.NewFakeProvider(), dns, nil,
		"web-1.barkpark.cloud", "web-1", "web-1", "barkpark.cloud", "20.0.0.9")

	joined := strings.Join(residue, " | ")
	if !strings.Contains(joined, "web-1-506f035e.barkpark.cloud still resolves to the released box IP 20.0.0.9") {
		t.Errorf("the by-value leg did not name the surviving sibling: %s", joined)
	}
	if strings.Contains(joined, "bystander") {
		t.Errorf("a record at a DIFFERENT address was reported as residue: %s", joined)
	}
	// The platform label is reported ONCE, by the by-name check — the by-value
	// leg must skip it rather than double-count the same record.
	if n := strings.Count(joined, "web-1.barkpark.cloud"); n != 1 {
		t.Errorf("the platform record is reported %d times, want exactly 1: %s", n, joined)
	}
}
