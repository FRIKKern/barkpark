package cli

// cloud_read_refusal_exit_test.go is the READ plane's half of the #11784 exit
// ladder (cch-w71 remainder, D866).
//
// Four call sites still handed EVERY refusal to the bare `cloudFail`, a seam
// that branches only on a dead session (HTTP 401):
//
//	runCloudSiteSettings   — PATCH /v1/sites/:id           ("update site settings")
//	runCloudSiteStatus     — GET   /v1/sites/:id           ("get site")
//	runCloudSiteOpen       — GET   /v1/sites/:id           ("get site")
//	runCloudDomainStatus   — GET   /v1/barkparks/:id/domain-status ("domain status")
//
// So a 403 the caller's PAT cannot fix, a 404 that is not their site and a 500
// the plane crashed on ALL printed "failed" and exited 1. A script gating on
// `bp cloud site status <ref> || …` could not tell "not found" from "forbidden"
// from "the server is down" — a refusal flattened onto one number is the same
// silent-wrong-answer family as a null that reads as a value.
//
// THE TABLES BELOW ARE DERIVED FROM THE LIVE ROUTE ARMS, not invented. The
// routes are in cloud/lib/barkpark_cloud/web/router.ex, module
// BarkparkCloud.Web.Router:
//
//	PATCH /v1/sites/:id — with_team_site(conn, {:ability, "write"}, …):
//	  401 unauthorized ......... Auth.require_user_or_pat/2
//	  403 forbidden ............ Auth.require_ability/2
//	  403 deploy_ability_required / rebind_ability_required — the route body's
//	      own capability-grant arms (prebuilt_enabled=true, content rebind)
//	  404 not_found ............ with_team_site/3 (teamless caller OR site miss)
//	  422 nothing_to_update / invalid_settings — the route body
//	  5xx ...................... 500 server_error (Router.handle_errors/2 crash
//	      slug); the rebind arm relays a failed token mint as 502
//
//	GET /v1/sites/:id — Auth.require_user/2 + an inline team scope:
//	  401 unauthorized, 404 not_found (teamless OR miss), 500 server_error.
//	  NO 403 arm (require_user/2 asks for no ability) and NO 409 — both are
//	  INERT on this route and are deliberately not fixtured as if they were live.
//
//	GET /v1/barkparks/:id/domain-status — Auth.require_user/2 + resolve_team_barkpark/2:
//	  401 unauthorized, 404 not_found (wrong team / absent / malformed id are
//	  deliberately indistinguishable), 500 server_error. DomainStatus.check/2 is
//	  TOTAL over probe failure — a stuck domain is a 200 with pending/failed
//	  rungs, never a 5xx — so the 5xx row here is the crash slug only.
//
// RED BEFORE (reproducible by reverting cloud_site_cmd.go + cloud_domain_cmd.go
// alone — the four arms back to their bare `cloudFail` calls): every non-401 row
// below exited 1. 403 wanted 3, 404 wanted 4, 500/502 wanted 8 — three families
// collapsed onto exitGeneric.
//
// VACUITY GUARD: these assert the EXIT CODE per status family, never a detail
// substring — cloudError already folds `detail` into Error(), so a substring
// check passes on pre-fix bytes too and would prove nothing. The 401 rows are
// the INVARIANT half: they were exit 3 before and must stay 3, because
// siteRefusalFail deliberately routes 401 back through cloudFail so the
// "session expired? run `bp login` again" sentence stays the one every cloud
// verb prints.

import (
	"strings"
	"testing"
)

// settingsRefused drives `bp cloud site settings <uuid> --theme dark` against a
// control plane that answers the PATCH with the given fixture. The ref is a
// UUID, so resolveOpenSiteID passes it through and the PATCH is the only
// request that fires.
func settingsRefused(t *testing.T, resp fakeResp) (string, int) {
	t.Helper()
	cp := newSiteCP(t)
	cp.patchResp = resp
	cp.serve()
	_, stderr, code := runSite(t, "table", "settings", testSiteID, "--theme", "dark")
	return stderr, code
}

// siteGetRefused drives one of the two `get site` readers against a control
// plane that answers GET /v1/sites/:id with the given fixture. `verb` is
// "status" or "open" — the same client call, two commands, and both used to
// flatten.
func siteGetRefused(t *testing.T, verb string, resp fakeResp) (string, int) {
	t.Helper()
	cp := newSiteCP(t)
	cp.getResp = resp
	cp.serve()
	args := []string{verb, testSiteID}
	if verb == "open" {
		// --print-only so a green run would never shell out to a launcher; the
		// refusal returns before that point either way.
		args = append(args, "--print-only")
	}
	_, stderr, code := runSite(t, "table", args...)
	return stderr, code
}

// PATCH /v1/sites/:id — `bp cloud site settings`.
func TestRunCloudSiteSettingsExitsByStatusFamily(t *testing.T) {
	for _, tc := range []siteRefusalCase{
		// The invariant: 401 keeps the shared dead-session seam and its `bp login`
		// sentence. Not red before — it is here so a future edit cannot quietly
		// pull 401 onto the ladder and lose that copy.
		{"401 unauthorized", fakeResp{401, `{"error":"unauthorized"}`}, exitAuth},
		// Auth.require_ability/2 — the caller's token lacks `write` on this team.
		{"403 forbidden", fakeResp{403, `{"error":"forbidden","required":"write","scope":"token"}`}, exitAuth},
		// The route body's own capability-grant arms.
		{"403 deploy_ability_required", fakeResp{403, `{"error":"deploy_ability_required","detail":"enabling off-box builds grants this site the right to serve bytes it did not build"}`}, exitAuth},
		{"403 rebind_ability_required", fakeResp{403, `{"error":"rebind_ability_required","detail":"repointing a site's content binding MINTS a public-read token in the scope you name"}`}, exitAuth},
		// with_team_site/3 — wrong team, missing site, or a teamless login.
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		// The 422 family — user-fixable, exit 1. INVARIANT: these were 1 before.
		{"422 nothing_to_update", fakeResp{422, `{"error":"nothing_to_update","detail":"mutable fields: theme, doc_type, prebuilt_enabled"}`}, exitGeneric},
		{"422 invalid_settings", fakeResp{422, `{"error":"invalid_settings","detail":"theme: is invalid"}`}, exitGeneric},
		// The 5xx family — transient or a crash, retryable, exit 8.
		{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
		{"502 read_token_mint_failed", fakeResp{502, `{"error":"read_token_mint_failed","detail":"the box refused to mint the site's read token"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stderr, code := settingsRefused(t, tc.resp)
			if code != tc.want {
				t.Fatalf("a %s settings refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
		})
	}
}

// GET /v1/sites/:id — `bp cloud site status` and `bp cloud site open` read the
// same row through the same client call, so they ride ONE table.
func TestRunCloudSiteGetExitsByStatusFamily(t *testing.T) {
	for _, verb := range []string{"status", "open"} {
		for _, tc := range []siteRefusalCase{
			{"401 unauthorized", fakeResp{401, `{"error":"unauthorized"}`}, exitAuth},
			{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
			{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
		} {
			t.Run(verb+"/"+tc.name, func(t *testing.T) {
				stderr, code := siteGetRefused(t, verb, tc.resp)
				if code != tc.want {
					t.Fatalf("a %s refusal of `bp cloud site %s` must exit %d (%s), got %d (%s)\n%s",
						tc.name, verb, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
				}
			})
		}
	}
}

// GET /v1/barkparks/:id/domain-status — the ERROR arm of `bp cloud domain
// status`. Its SUCCESS path has been a real gate since it shipped
// (domainStatusExit: 0 only when every rung of every host is ok); only the
// refusal arm flattened, which is exactly the case a `&& deploy` chain hits
// when the instance is gone.
func TestRunCloudDomainStatusRefusalExitsByStatusFamily(t *testing.T) {
	for _, tc := range []siteRefusalCase{
		{"401 unauthorized", fakeResp{401, `{"error":"unauthorized"}`}, exitAuth},
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newDomainServer(t, tc.resp.status, tc.resp.body)
			stdout, stderr, code := runDomain(t, "table", false, "status", testInstanceID)
			if code != tc.want {
				t.Fatalf("a %s domain-status refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
			if strings.TrimSpace(stdout) != "" {
				t.Fatalf("a refusal must keep stdout clean:\n%s", stdout)
			}
		})
	}
}

// A refused domain-status read must say the INSTANCE was not found — not "no
// such site". The ladder's `not_found` arm is site-voiced for every other kind,
// and a checklist reader who is handed a site sentence goes hunting the wrong
// object. This is the one assertion in this file that reads copy, and it is
// safe from vacuity because the pre-fix bytes said "domain status: not_found".
func TestRunCloudDomainStatusRefusalNamesTheInstance(t *testing.T) {
	newDomainServer(t, 404, `{"error":"not_found"}`)
	_, stderr, code := runDomain(t, "table", false, "status", testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit=%d (%s) want %d (not-found)\n%s", code, siteExitName(code), exitNotFound, stderr)
	}
	if !strings.Contains(stderr, "instance") {
		t.Fatalf("a refused domain-status read must name the INSTANCE, not a site:\n%s", stderr)
	}
}
