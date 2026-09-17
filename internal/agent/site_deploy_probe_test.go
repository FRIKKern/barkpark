package agent

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The FAILURE DIRECTION this file exists to pin (dr-w15-s5, criterion 0):
//
//	an instance that predates dr-w15-s1 answers 404, and the beat must say
//	UNMEASURED — never `configured: false`.
//
// `false` is a VERDICT: it means THIS BOX REFUSES DEPLOYS. Reporting an
// un-upgraded box as refusing is a fabricated fact about a box nobody asked, and
// the whole fleet is old enough for that to be the COMMON case, not the edge
// one. So the 404 arm is asserted three ways below — the probe returns no
// record, gatherReport leaves the field nil, and the MARSHALLED BYTES carry
// neither the key nor the word `false` — because a reader downstream sees only
// the bytes.
//
// MUTATION TARGET (this is how these arms were proved to red rather than
// assumed to): in NewSiteDeployProbe's non-200 branch, replace
//
//	return nil, fmt.Errorf("site-deploy: status %d", resp.StatusCode)
//
// with `f := false; return &SiteDeployCapability{Configured: &f}, nil`.
// TestSiteDeployProbe404IsUnmeasuredNotFalse and
// TestGatherLeavesSiteDeployAbsentOnOldInstance both red.

// stubInstance serves one canned status+body at siteDeployPath and reports
// whether it was actually reached — a probe that never issued a request would
// otherwise pass every "no record" assertion vacuously.
func stubInstance(t *testing.T, status int, body string) (base string, hits *int) {
	t.Helper()
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != siteDeployPath {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		n++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &n
}

// THE RED-ON-REVERSION ARM.
func TestSiteDeployProbe404IsUnmeasuredNotFalse(t *testing.T) {
	base, hits := stubInstance(t, http.StatusNotFound, `{"errors":[{"code":"not_found"}]}`)
	probe := NewSiteDeployProbe(base, "tok", nil)
	if probe == nil {
		t.Fatal("probe is nil for a non-empty base")
	}
	got, err := probe()
	// PRECONDITION, not decoration: without it a probe that silently never
	// dialled would satisfy every assertion below.
	if *hits != 1 {
		t.Fatalf("the instance route was hit %d times, want 1 — the assertions below "+
			"would be vacuous", *hits)
	}
	if err == nil {
		t.Fatal("a 404 must be an error so gatherReport leaves the field unmeasured")
	}
	if got != nil {
		t.Fatalf("a 404 returned a record %+v — an instance that predates dr-w15-s1 "+
			"must yield the UNMEASURED sentinel (nil), never a record", got)
	}
}

// THE CONTROL: a 200 that really says false MUST carry false. Without this arm
// the rule above is satisfiable by a probe that can never report a refusal at
// all, which would be a different lie in the other direction.
func TestSiteDeployProbe200CarriesARealFalse(t *testing.T) {
	base, _ := stubInstance(t, http.StatusOK, `{"configured":false,"runner_alive":true}`)
	got, err := NewSiteDeployProbe(base, "tok", nil)()
	if err != nil {
		t.Fatalf("200 returned err = %v", err)
	}
	if got == nil || got.Configured == nil || *got.Configured != false {
		t.Fatalf("a box that SAID configured=false must report false, got %+v", got)
	}
	if got.RunnerAlive == nil || *got.RunnerAlive != true {
		t.Fatalf("runner_alive did not land: %+v", got)
	}
}

// A 200 whose body OMITS a key: the record is carried, the unstated half stays
// unstated. Same law one level down.
func TestSiteDeployProbe200MissingKeyIsNilNotFalse(t *testing.T) {
	base, _ := stubInstance(t, http.StatusOK, `{"runner_alive":true}`)
	got, err := NewSiteDeployProbe(base, "tok", nil)()
	if err != nil {
		t.Fatalf("200 returned err = %v", err)
	}
	if got == nil {
		t.Fatal("a 200 must carry a record")
	}
	if got.Configured != nil {
		t.Fatalf("an ABSENT configured key landed as %v — it must stay nil (unmeasured)", *got.Configured)
	}
}

// THE BYTES ARM. A downstream reader — merge_capability/2 on the control plane —
// sees only what is marshalled, so the absence has to be proved there too.
func TestGatherLeavesSiteDeployAbsentOnOldInstance(t *testing.T) {
	base, hits := stubInstance(t, http.StatusNotFound, `{}`)
	r := gatherReport(ReportConfig{SiteDeployProbe: NewSiteDeployProbe(base, "tok", nil)})
	if *hits != 1 {
		t.Fatalf("the instance route was hit %d times, want 1", *hits)
	}
	if r.SiteDeploy != nil {
		t.Fatalf("Report.SiteDeploy = %+v after a 404 — want nil (UNMEASURED)", r.SiteDeploy)
	}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var wire map[string]any
	if err := json.Unmarshal(b, &wire); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if v, ok := wire["site_deploy"]; ok {
		t.Fatalf("the beat carried site_deploy = %#v after a 404 — the key must be "+
			"ABSENT so merge_capability/2 reads nil/unmetered, not false", v)
	}
	// Control on the control: the same marshalled report DOES carry the key once
	// a box really answers, so the assertion above is about the 404 and not about
	// `omitempty` being permanently broken.
	base2, _ := stubInstance(t, http.StatusOK, `{"configured":true,"runner_alive":true}`)
	r2 := gatherReport(ReportConfig{SiteDeployProbe: NewSiteDeployProbe(base2, "tok", nil)})
	b2, _ := json.Marshal(r2)
	if !strings.Contains(string(b2), `"site_deploy"`) {
		t.Fatalf("a real 200 did not put site_deploy on the wire:\n%s", b2)
	}
	if r2.SiteDeploy == nil || r2.SiteDeploy.Configured == nil || !*r2.SiteDeploy.Configured {
		t.Fatalf("a real 200 did not land configured=true: %+v", r2.SiteDeploy)
	}
}

// An unwired probe is UNMEASURED too, and by the same encoding.
func TestGatherSiteDeployUnwiredIsAbsent(t *testing.T) {
	if p := NewSiteDeployProbe("", "tok", nil); p != nil {
		t.Fatal("an empty base must yield a nil probe (unwired)")
	}
	r := gatherReport(ReportConfig{})
	if r.SiteDeploy != nil {
		t.Fatalf("Report.SiteDeploy = %+v with no probe — want nil", r.SiteDeploy)
	}
	b, _ := json.Marshal(r)
	if strings.Contains(string(b), "site_deploy") {
		t.Fatalf("an unwired agent put site_deploy on the wire:\n%s", b)
	}
}
