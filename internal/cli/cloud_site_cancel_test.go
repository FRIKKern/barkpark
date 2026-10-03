package cli

import (
	"strings"
	"testing"
)

// task-4187bcf6d0424cfc: `bp cloud site cancel <site> <deployment-id>`, the
// operator cancel. It relays the control plane's decision and never prints a
// "cancelled" the plane did not write.

const cancelledEnvelope = `{"ok":true,"status":"cancelled","slot_free":true,"next":"redeploy to build again: ` +
	"`bp cloud site deploy <site>`" + ` or the console's Deploy button","deployment":{"id":"dep-9","status":"cancelled","failure_reason":"operator_cancelled"}}`

func TestRunCloudSiteCancelSaysTheSlotIsFreeAndHowToRebuild(t *testing.T) {
	cp := newSiteCP(t)
	cp.cancelResp = fakeResp{200, cancelledEnvelope}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "cancel", testSiteID, "dep-9")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if cp.cancelPath != "/v1/sites/"+testSiteID+"/deployments/dep-9/cancel" {
		t.Fatalf("cancel addressed %q", cp.cancelPath)
	}
	for _, want := range []string{"cancelled deployment dep-9", "slot is free", "next: redeploy"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("receipt missing %q:\n%s", want, stdout)
		}
	}
}

func TestRunCloudSiteCancelAlreadyCancelledSaysNothingWasWritten(t *testing.T) {
	cp := newSiteCP(t)
	cp.cancelResp = fakeResp{200, strings.Replace(cancelledEnvelope, `"status":"cancelled","slot_free"`, `"status":"already_cancelled","slot_free"`, 1)}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "cancel", testSiteID, "dep-9")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "already cancelled") || !strings.Contains(stdout, "nothing new was written") {
		t.Fatalf("idempotent receipt must say nothing was written:\n%s", stdout)
	}
}

func TestRunCloudSiteCancelRefusalExitsNonZeroWithThePlanesDetail(t *testing.T) {
	cp := newSiteCP(t)
	cp.cancelResp = fakeResp{409, `{"ok":false,"error":"in_flight","status":"pushing","detail":"this deployment is pushing on the box, and a cancel from here cannot stop it. Wait for it to settle (live or failed), then redeploy"}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "cancel", testSiteID, "dep-9")
	if code == exitOK {
		t.Fatalf("a refused cancel must exit non-zero; stdout:\n%s", stdout)
	}
	if strings.Contains(stdout, "cancelled deployment") {
		t.Fatalf("printed a cancel the plane refused:\n%s", stdout)
	}
	if !strings.Contains(stderr, "in_flight") || !strings.Contains(stderr, "cannot stop it") {
		t.Fatalf("refusal must carry the plane's code and detail:\n%s", stderr)
	}
}

func TestRunCloudSiteCancelJSONIsTheEnvelopeVerbatim(t *testing.T) {
	cp := newSiteCP(t)
	cp.cancelResp = fakeResp{200, cancelledEnvelope}
	cp.serve()

	stdout, stderr, code := runSite(t, "json", "cancel", testSiteID, "dep-9")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if strings.TrimSpace(stdout) != cancelledEnvelope {
		t.Fatalf("-o json must re-emit the envelope verbatim:\n%s", stdout)
	}
}

func TestRunCloudSiteCancelWantsTwoArguments(t *testing.T) {
	_, stderr, code := runSite(t, "table", "cancel", testSiteID)
	if code != exitUsage {
		t.Fatalf("exit=%d want usage\n%s", code, stderr)
	}
	if !strings.Contains(stderr, "<deployment-id>") {
		t.Fatalf("usage must name the missing deployment id:\n%s", stderr)
	}
}
