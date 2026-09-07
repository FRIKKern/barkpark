package cli

// site_node_slot_health_render_test.go — THE SERVED SLOT AND THE HEALTH VERDICT,
// decoded from the producer's own payload shapes and asserted to render
// DISTINGUISHABLY.
//
// THE DEFECT THIS EXISTS FOR. `deployment_json/1` has emitted `slot`, `port` and
// `health_exit_code` since #15095, and `cloudclient.SiteDeployment` declared only
// `Port`. `json.Unmarshal` drops unmodelled keys in silence, so
// `bp cloud site status -o json` shipped neither — and
// `deploy/site-spawner-node-live-proof.sh`, which reads `deployment.slot` and
// `deployment.health_exit_code` off exactly that envelope, degraded to
// DEPLOY_NO_SLOT against a control plane that was sending the truth all along.
//
// WHY A HAPPY-PATH TEST CANNOT SEE THE BUG THAT REOPENED THIS ROW.
// `health_exit_code` is 0 when the gate RAN AND PASSED. Model it as an `int` (or
// tag it `omitempty`, or gate the map write on `!= 0` the way every other numeric
// key on this envelope is gated) and the SUCCESS case becomes byte-identical to
// the ABSENT case. A fixture that only ever carries a failing health check, or
// only ever carries a passing one, is green under both the correct and the broken
// model. The distinction is only visible when 0 and absent are asserted AGAINST
// EACH OTHER, in one test, on the same envelope — which is what the
// zero-vs-absent arm below does.
//
// The five shapes are the producer's, not invented: slot+port together (a normal
// node deploy after SWITCH), port with a NULL slot (the served port matched
// neither allocated slot — "we do not know which half"), health 0, health 14, and
// health absent. The last three are exactly the values router.ex's comment above
// the three keys enumerates.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// wireDeployment decodes a REAL `{"deployment": …}` body the way postSiteDeploy
// and SpawnSiteDeployment do, so a missing json tag fails here rather than being
// blamed on the renderer downstream.
func wireDeployment(t *testing.T, body string) cloudclient.SiteDeployment {
	t.Helper()
	var wire struct {
		Deployment cloudclient.SiteDeployment `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(body), &wire); err != nil {
		t.Fatalf("decode deployment body: %v", err)
	}
	return wire.Deployment
}

// A node deploy that went live: the box measured Caddy proxying to green:7003 and
// the health gate ran and passed.
const nodeLiveDeploymentBody = `{"deployment":{
  "id":"dep-live","site_id":"site-1","status":"live","stage":"RETIRE",
  "build_id":"b-9f2c1ab","url":"https://guerrilla.barkpark.cloud/sites/blog/",
  "runtime_target":"node","slot":"green","port":7003,"health_exit_code":0,
  "inserted_at":"2026-09-02T10:00:00Z","updated_at":"2026-09-02T10:04:12Z"}}`

// The pair router.ex calls "a real signal, not a bug": a served port that matches
// neither of the site's two allocated slots, so `slot` is null while `port` stands.
const nodeUnnamedSlotDeploymentBody = `{"deployment":{
  "id":"dep-odd","site_id":"site-1","status":"live","stage":"RETIRE",
  "build_id":"b-odd","runtime_target":"node","slot":null,"port":7005,
  "health_exit_code":0,"inserted_at":"2026-09-02T11:00:00Z","updated_at":"2026-09-02T11:03:00Z"}}`

// The health gate RAN and FAILED — exit 14, the cross-engine convention. Nothing
// was switched, so no slot was ever served.
const nodeHealthFailedDeploymentBody = `{"deployment":{
  "id":"dep-sick","site_id":"site-1","status":"failed","stage":"HEALTH",
  "build_id":"b-sick","runtime_target":"node","slot":null,"port":null,
  "health_exit_code":14,"failure_reason":"the new build failed its health check",
  "inserted_at":"2026-09-02T12:00:00Z","updated_at":"2026-09-02T12:02:40Z"}}`

// The build died in BUILD: HEALTH never ran, so the code is null. THE ONE THAT
// MUST NOT LOOK LIKE A PASS.
const nodeHealthNeverRanDeploymentBody = `{"deployment":{
  "id":"dep-dead","site_id":"site-1","status":"failed","stage":"BUILD",
  "build_id":"b-dead","runtime_target":"node","slot":null,"port":null,
  "health_exit_code":null,"failure_reason":"the build command exited 1",
  "inserted_at":"2026-09-02T13:00:00Z","updated_at":"2026-09-02T13:00:51Z"}}`

// A static deploy: a symlink swap has no slot, no port and no health gate, and the
// producer omits nothing — it sends all three as null.
const staticDeploymentBody = `{"deployment":{
  "id":"dep-static","site_id":"site-2","status":"live","stage":"RETIRE",
  "build_id":"b-static","slot":null,"port":null,"health_exit_code":null,
  "inserted_at":"2026-09-02T14:00:00Z","updated_at":"2026-09-02T14:01:30Z"}}`

// THE DECODE. Asserted before any render assertion, so a dropped json tag blames
// the struct rather than the map builder.
func TestSiteDeploymentDecodesSlotPortAndHealthExitCode(t *testing.T) {
	live := wireDeployment(t, nodeLiveDeploymentBody)
	if live.Slot != "green" {
		t.Errorf("Slot did not decode: got %q, want \"green\" — SiteDeployment declares no json:\"slot\" tag, so json.Unmarshal dropped the key the control plane sent", live.Slot)
	}
	if live.Port != 7003 {
		t.Errorf("Port did not decode: got %d, want 7003", live.Port)
	}
	if live.HealthExitCode == nil {
		t.Fatalf("HealthExitCode did not decode: got nil, want a pointer to 0 — a passing health check decoded as \"never measured\"")
	}
	if *live.HealthExitCode != 0 {
		t.Errorf("HealthExitCode = %d, want 0", *live.HealthExitCode)
	}

	odd := wireDeployment(t, nodeUnnamedSlotDeploymentBody)
	if odd.Slot != "" {
		t.Errorf("a null slot decoded to %q, want \"\"", odd.Slot)
	}
	if odd.Port != 7005 {
		t.Errorf("Port must stand while Slot is null (that pair is the signal): got %d, want 7005", odd.Port)
	}

	sick := wireDeployment(t, nodeHealthFailedDeploymentBody)
	if sick.HealthExitCode == nil || *sick.HealthExitCode != 14 {
		t.Errorf("HealthExitCode = %v, want 14", sick.HealthExitCode)
	}

	dead := wireDeployment(t, nodeHealthNeverRanDeploymentBody)
	if dead.HealthExitCode != nil {
		t.Errorf("a null health_exit_code decoded to %d, want nil — the pointer is the only thing keeping \"never measured\" apart from \"passed\"", *dead.HealthExitCode)
	}
}

// THE ARM THAT REOPENED THIS ROW. 0 (ran, passed) and absent (never ran) must not
// collapse into the same JSON envelope. This fails on `int`, on
// `json:"health_exit_code,omitempty"`, and on a `!= 0` gate in siteDeploymentMap —
// the three shapes a reviewer would each call reasonable in isolation.
func TestSiteDeploymentMapKeepsPassingHealthApartFromNeverMeasured(t *testing.T) {
	passed := siteDeploymentMap(wireDeployment(t, nodeLiveDeploymentBody))
	never := siteDeploymentMap(wireDeployment(t, nodeHealthNeverRanDeploymentBody))
	failed := siteDeploymentMap(wireDeployment(t, nodeHealthFailedDeploymentBody))

	got, ok := passed["health_exit_code"]
	if !ok {
		t.Fatalf("a PASSING health check (exit 0) emitted no health_exit_code key at all — \"the gate ran and passed\" is now indistinguishable from \"nobody measured\", which is the zero-value success this row exists to refuse")
	}
	if got != 0 {
		t.Errorf("health_exit_code = %v, want 0", got)
	}

	if v, ok := never["health_exit_code"]; ok {
		t.Errorf("a build that died in BUILD emitted health_exit_code = %v; it must emit NO KEY — a rendered 0 there certifies a build that was never health-checked", v)
	}

	if failed["health_exit_code"] != 14 {
		t.Errorf("health_exit_code = %v, want 14", failed["health_exit_code"])
	}

	// The three envelopes must be mutually distinguishable, not merely each
	// individually plausible.
	if _, p := passed["health_exit_code"]; !p {
		t.Fatal("unreachable")
	}
	if _, n := never["health_exit_code"]; n {
		t.Fatal("unreachable")
	}
}

// SLOT AND PORT ARE INDEPENDENT. A null slot must not suppress the port, and a
// static row must carry neither.
func TestSiteDeploymentMapSlotAndPortAreIndependent(t *testing.T) {
	live := siteDeploymentMap(wireDeployment(t, nodeLiveDeploymentBody))
	if live["slot"] != "green" {
		t.Errorf("slot = %v, want \"green\" — `bp cloud site status -o json` is what deploy/site-spawner-node-live-proof.sh reads for its DEPLOY_NO_SLOT assertion", live["slot"])
	}
	if live["port"] != 7003 {
		t.Errorf("port = %v, want 7003", live["port"])
	}

	odd := siteDeploymentMap(wireDeployment(t, nodeUnnamedSlotDeploymentBody))
	if _, ok := odd["slot"]; ok {
		t.Errorf("a null slot emitted slot = %v; it must emit no key", odd["slot"])
	}
	if odd["port"] != 7005 {
		t.Errorf("port = %v, want 7005 — the port is the stronger fact and must stand when the slot cannot be named", odd["port"])
	}

	static := siteDeploymentMap(wireDeployment(t, staticDeploymentBody))
	for _, k := range []string{"slot", "port", "health_exit_code"} {
		if v, ok := static[k]; ok {
			t.Errorf("a static deployment emitted %s = %v; a symlink swap has no slot, no port and no health gate, so all three must be absent", k, v)
		}
	}
}

// THE HUMAN RENDER. `-o json` carries the raw values; the header must SAY which of
// the three states it got, because a bare "health: 0" reads as an absence.
func TestSiteHealthGateLineDistinguishesRanPassedFromNeverMeasured(t *testing.T) {
	zero, fourteen := 0, 14
	passed := siteHealthGateLine(&zero)
	failed := siteHealthGateLine(&fourteen)
	never := siteHealthGateLine(nil)

	if !strings.Contains(passed, "passed") || !strings.Contains(passed, "0") {
		t.Errorf("exit 0 rendered as %q — it must say the gate RAN and PASSED", passed)
	}
	if !strings.Contains(failed, "FAILED") || !strings.Contains(failed, "14") {
		t.Errorf("exit 14 rendered as %q", failed)
	}
	if !strings.Contains(never, "never ran") || strings.Contains(never, "passed") {
		t.Errorf("a never-measured health rendered as %q — it must not read as a pass", never)
	}
	if passed == never || failed == never || passed == failed {
		t.Errorf("two of the three health states render identically: passed=%q failed=%q never=%q", passed, failed, never)
	}
}

func TestSiteServedSlotLineNamesTheUnnamedSlot(t *testing.T) {
	if got := siteServedSlotLine("green", 7003); !strings.Contains(got, "green") || !strings.Contains(got, "7003") {
		t.Errorf("served slot rendered as %q, want the slot AND the port", got)
	}
	odd := siteServedSlotLine("", 7005)
	if !strings.Contains(odd, "7005") || !strings.Contains(odd, "unknown") {
		t.Errorf("a port with no nameable slot rendered as %q — the box LOOKED and what it found fits neither slot; that must not render as the blank it prints when nobody looked", odd)
	}
	if got := siteServedSlotLine("", 0); got != "" {
		t.Errorf("a static row rendered a served-slot line %q, want none", got)
	}
}

// END TO END through the status header a user actually reads.
func TestSpawnSiteStatusHeaderShowsSlotAndHealth(t *testing.T) {
	node := cloudclient.SpawnSite{ID: "site-1", Name: "blog", Slug: "blog", Kind: "node", RuntimeTarget: "node", Framework: "astro"}

	live := wireDeployment(t, nodeLiveDeploymentBody)
	out, buf, _ := newTestWriter()
	renderKV(out, spawnSiteStatusMap(node, &live, &live, []cloudclient.SiteDeployment{live}))
	got := buf.String()
	for _, want := range []string{"served slot", "green", "7003", "health", "passed"} {
		if !strings.Contains(got, want) {
			t.Errorf("status header is missing %q; got:\n%s", want, got)
		}
	}

	dead := wireDeployment(t, nodeHealthNeverRanDeploymentBody)
	out2, buf2, _ := newTestWriter()
	renderKV(out2, spawnSiteStatusMap(node, &dead, &dead, []cloudclient.SiteDeployment{dead}))
	got2 := buf2.String()
	if !strings.Contains(got2, "never ran") {
		t.Errorf("a node deploy that died before HEALTH must SAY the gate never ran; got:\n%s", got2)
	}
	if strings.Contains(got2, "passed") {
		t.Errorf("a never-measured health check rendered as a pass; got:\n%s", got2)
	}

	// A static site's header is unchanged: no health row at all, rather than a
	// permanent dash that teaches the reader to ignore the row.
	static := cloudclient.SpawnSite{ID: "site-2", Name: "docs", Slug: "docs", Kind: "static", Framework: "astro"}
	sd := wireDeployment(t, staticDeploymentBody)
	out3, buf3, _ := newTestWriter()
	renderKV(out3, spawnSiteStatusMap(static, &sd, &sd, []cloudclient.SiteDeployment{sd}))
	if got3 := buf3.String(); strings.Contains(got3, "health") || strings.Contains(got3, "served slot") {
		t.Errorf("a static site's status header grew a node-only row; got:\n%s", got3)
	}
}
