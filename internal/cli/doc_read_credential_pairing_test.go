package cli

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// doc_read_credential_pairing_test.go — where THE BINDING meets THE WIDENING
// (hq-doc-get-auth-tier-gap c1).
//
// TWO CHANGES MET HERE, and neither one's test suite sees the other:
//
//  1. THE WIDENING (PR #17681, this row's code half). authHeaders' `case "none"`
//     stopped withholding the configured bearer, so doc.get / doc.ls / doc.query
//     — the tier-`none` read verbs — now CARRY a credential at their default
//     published perspective, where before they carried none at all. The row's
//     own tests (doc_read_optional_auth_test.go) measure the REQUEST BUILDER:
//     they prove the header is attached, and prove the tokenless request stays
//     byte-compatible. They say nothing about WHICH HOST it is attached for.
//
//  2. THE BINDING (task-c05d0f7fa7bef688, PR #18696). A credential that won at
//     the ACTIVE layer is paired to the server that layer saved it for and is
//     withheld — to the baked dev floor, never to empty — on a host mismatch.
//     Its wire arm (server_credential_pairing_test.go,
//     TestNoAuthorizationHeaderCarriesASavedCredentialToAMismatchedHost) drives
//     exactly ONE invocation: `doc ls` at the DEFAULT perspective.
//
// THE UNMEASURED PRODUCT. Nothing in the tree drives RESOLUTION and DISPATCH
// together for the widened verbs. The request-builder arms hand-build a
// manifest.Context and so never meet the binding at all; the binding's wire arm
// meets resolution but drives one verb at one perspective. The product — "does
// the credential a real invocation RESOLVES reach the wire, for each verb the
// widening touched, at each perspective" — was measured by neither.
//
// run.go attaches Authorization at TWO sites:
//
//	headers := authHeaders(cmd, ctx)                    // site 1 — tier-driven
//	if needsPerspectiveAuth || needsDraftIDAuth {
//	    headers["Authorization"] = "Bearer " + ctx.Token // site 2 — perspective
//	}
//
// MEASURED, not assumed (2026-09-17): site 2 is now REDUNDANT. Replacing its
// body with `_ = ctx.Token` reds NOTHING in `go test ./internal/cli/` — not one
// test, including the nine arms below. It cannot differ from site 1: site 2 is
// reachable only when cmd.AuthTier == "none" (nonPublishedPerspectiveRequiresAuth
// returns false otherwise), authHeaders' `case "none"` already attached the same
// `"Bearer " + ctx.Token` whenever ctx.Token != "", and an EMPTY ctx.Token is
// refused thirty lines earlier with "--perspective drafts requires an API token".
// The widening (1) is what made it redundant; before it, site 2 was the only
// attach a drafts/raw read had. It is left in place as the explicit statement of
// the perspective contract, and this paragraph is the record that it is today a
// belt over braces rather than a load-bearing line — so the next reader neither
// deletes it believing a test guards it, nor trusts it to guard anything.
//
// This file closes the product instead. Three verbs x {published(default),
// drafts, raw} x {mismatched host, matching host} = 18 wire arms, driven through
// Execute — manifest fetch included, because the manifest fetch is the FIRST
// request bp issues and a guard that fires after it has already leaked.
//
// ON READING AN ABSENCE. "the saved token was not seen" is an ABSENCE claim, and
// an absence is never caught by inspection. Every arm therefore PRINTS the full
// key set it measured (every recorded path + Authorization shape) and asserts the
// request count is non-zero before it asserts anything about what those requests
// contained — a recorder that received nothing would otherwise satisfy "no
// credential arrived" perfectly. The leak arms also assert the POSITIVE form:
// every bearer that did arrive is the public baked floor, so another credential
// leaking in the saved one's place cannot pass.

// docPairingRecorder is a fake server that answers /v1/capabilities with a
// manifest carrying all three doc read verbs AT THEIR LIVE SHAPE (tier "none",
// each declaring a `perspective` flag), and records the path + Authorization of
// every request it receives.
type docPairingRecorder struct {
	*httptest.Server
	mu   sync.Mutex
	reqs []docPairingHit
}

type docPairingHit struct {
	path string
	auth string
}

func (d *docPairingRecorder) seen() []docPairingHit {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]docPairingHit, len(d.reqs))
	copy(out, d.reqs)
	return out
}

// describe renders the whole key set for the log. Bearer values are rendered as
// a LENGTH and a 4-char tail, never in full: the assertions below are on the
// PRESENCE of a header, and a test that prints credentials teaches the next
// author to print credentials.
func (d *docPairingRecorder) describe() string {
	hits := d.seen()
	if len(hits) == 0 {
		return "(no requests recorded)"
	}
	var b strings.Builder
	for i, h := range hits {
		shape := "<no Authorization header>"
		if h.auth != "" {
			tok := strings.TrimPrefix(h.auth, "Bearer ")
			shape = fmt.Sprintf("Bearer <%d chars, tail %q>", len(tok), tokenTail(tok))
		}
		fmt.Fprintf(&b, "\n  [%d] %s  %s", i, h.path, shape)
	}
	return b.String()
}

// carried reports whether any recorded request presented exactly this bearer.
func (d *docPairingRecorder) carried(tok string) bool {
	for _, h := range d.seen() {
		if h.auth == "Bearer "+tok {
			return true
		}
	}
	return false
}

// carriedOnDocRoute is the CONTROL's question: did the credential reach the
// document route itself, not merely the manifest fetch? An arm that only ever
// checked /v1/capabilities would pass while every doc read went out anonymous.
func (d *docPairingRecorder) carriedOnDocRoute(tok string) bool {
	for _, h := range d.seen() {
		if strings.HasPrefix(h.path, "/v1/data/") && h.auth == "Bearer "+tok {
			return true
		}
	}
	return false
}

const docPairingManifestTemplate = `{
  "manifest_version": "1",
  "etag": "doc-pairing",
  "server": {"name": "test", "base_url": "BASEURL"},
  "auth_tier": "admin",
  "nouns": [{"name": "doc", "summary": "Docs."}],
  "commands": [
    {"id":"doc.get","noun":"doc","verb":"get","summary":"Fetch one document.",
     "http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","in":"path"},
             {"name":"doc_id","required":true,"type":"string","in":"path"}],
     "flags":[{"name":"perspective","type":"string","default":"published"}],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"List documents.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","in":"path"}],
     "flags":[{"name":"limit","type":"int"},{"name":"offset","type":"int"},
              {"name":"perspective","type":"string","default":"published"}],
     "writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"},
    {"id":"doc.query","noun":"doc","verb":"query","summary":"Query documents.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","in":"path"}],
     "flags":[{"name":"filter","type":"string","repeatable":true},
              {"name":"limit","type":"int"},{"name":"offset","type":"int"},
              {"name":"perspective","type":"string","default":"published"}],
     "writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"}
  ]
}`

func newDocPairingRecorder() *docPairingRecorder {
	d := &docPairingRecorder{}
	d.Server = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		d.mu.Lock()
		d.reqs = append(d.reqs, docPairingHit{path: req.URL.Path, auth: req.Header.Get("Authorization")})
		d.mu.Unlock()
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(http.StatusOK)
		if strings.HasPrefix(req.URL.Path, "/v1/capabilities") {
			_, _ = rw.Write([]byte(strings.Replace(docPairingManifestTemplate, "BASEURL", d.URL, 1)))
			return
		}
		if strings.HasPrefix(req.URL.Path, "/v1/data/doc/") {
			_, _ = rw.Write([]byte(`{"result":{"_id":"quiz-1","_type":"quiz"}}`))
			return
		}
		_, _ = rw.Write([]byte(`{"result":{"documents":[]}}`))
	}))
	return d
}

// docPairingArms is the matrix: every doc read verb crossed with the perspective
// axis the widening touched. The empty perspective is the DEFAULT published
// invocation (attach site 1); drafts and raw reach attach site 2.
var docPairingArms = []struct {
	name string
	argv []string
}{
	{"doc.get/default", []string{"doc", "get", "quiz", "quiz-1"}},
	{"doc.get/drafts", []string{"doc", "get", "quiz", "quiz-1", "--perspective", "drafts"}},
	{"doc.get/raw", []string{"doc", "get", "quiz", "quiz-1", "--perspective", "raw"}},
	{"doc.ls/default", []string{"doc", "ls", "quiz"}},
	{"doc.ls/drafts", []string{"doc", "ls", "quiz", "--perspective", "drafts"}},
	{"doc.ls/raw", []string{"doc", "ls", "quiz", "--perspective", "raw"}},
	{"doc.query/default", []string{"doc", "query", "quiz"}},
	{"doc.query/drafts", []string{"doc", "query", "quiz", "--perspective", "drafts"}},
	{"doc.query/raw", []string{"doc", "query", "quiz", "--perspective", "raw"}},
}

// TestDocReadVerbsNeverCarryASavedCredentialToAMismatchedHost is the LEAK arm.
//
// MUTATION PROOF (run 2026-09-17, macOS, CGO_ENABLED=0, go test -count=1):
//   - replace resolveContextProv's binding predicate (cli.go, "THE BINDING")
//     with `if false` -> ALL NINE arms fail, each naming its verb, its
//     perspective and the host pair: "LEAK: doc.get/drafts carried the
//     credential saved for https://guerrilla.barkpark.cloud to http://127.0.0.1:…".
//   - make attach site 2 read past ctx — `if c, err := LoadConfig(); err == nil
//     && c.Token != "" { tok = c.Token }` -> exactly the SIX drafts/raw arms
//     fail and the three default arms pass, which is the reachability of site 2
//     stated as a measurement. HONESTLY RECORDED: that mutation is ALSO caught by
//     three pre-existing request-builder tests
//     (TestBuildManifestRequestAuthenticatesNonPublishedPerspective,
//     TestDocReadsAttachConfiguredBearerAtEveryPerspective,
//     TestSearchQueryNonPublishedPerspectiveIsAuthenticated). These arms are not
//     the only guard against it; what they add is that the leak is measured ON
//     THE WIRE, after a real resolution, rather than on a hand-built Context.
//
// The matching-host CONTROL lives in the sibling test below and is not optional:
// "the credential did not arrive" is also what a CLI that sends no credential at
// all produces, and that CLI is the false-404 bug this row exists to kill.
func TestDocReadVerbsNeverCarryASavedCredentialToAMismatchedHost(t *testing.T) {
	for _, arm := range docPairingArms {
		t.Run(arm.name, func(t *testing.T) {
			withTempConfigHome(t)
			clearBarkparkEnv(t)
			t.Chdir(t.TempDir())
			srv := newDocPairingRecorder()
			defer srv.Close()
			// Saved for host A. The recorder is a DIFFERENT host, named by a raw -s.
			savedFor(t, pairingHostA, pairingSavedToken)

			argv := append([]string{"-s", srv.URL}, arm.argv...)
			_, stderr, _ := captureExecuteArgv(t, argv...)

			hits := srv.seen()
			t.Logf("%s recorded %d request(s):%s", arm.name, len(hits), srv.describe())

			// PRECONDITION before any absence is read: something was measured.
			if len(hits) == 0 {
				t.Fatalf("VACUOUS: %s reached the recorder zero times, so the absence below "+
					"measures nothing.\nstderr:\n%s", arm.name, stderr)
			}
			if srv.carried(pairingSavedToken) {
				t.Fatalf("LEAK: %s carried the credential saved for %s to %s.\nrecorded:%s\nstderr:\n%s",
					arm.name, pairingHostA, srv.URL, srv.describe(), stderr)
			}
			// The POSITIVE form of the absence: every bearer that DID arrive is
			// the public baked floor (or no header at all). Asserting only
			// "not the saved token" would be satisfied by any OTHER credential
			// leaking in its place.
			for i, h := range hits {
				if h.auth == "" {
					continue
				}
				if h.auth != "Bearer "+bakedDefaults().Token {
					t.Fatalf("%s request [%d] %s presented an unexpected bearer (%d chars, tail %q); "+
						"the only value a mismatched host may see is the public floor %q.\nrecorded:%s",
						arm.name, i, h.path, len(strings.TrimPrefix(h.auth, "Bearer ")),
						tokenTail(strings.TrimPrefix(h.auth, "Bearer ")), bakedDefaults().Token, srv.describe())
				}
			}
			// The withholding is announced before the request goes out — a silent
			// downgrade is how an operator concludes "the doc vanished".
			if !strings.Contains(stderr, pairingHostA) {
				t.Fatalf("%s withheld the credential SILENTLY — stderr must name %s.\nstderr:\n%s",
					arm.name, pairingHostA, stderr)
			}
		})
	}
}

// TestDocReadVerbsStillCarryTheirCredentialToTheirOwnHost is THE CONTROL, and it
// is the arm that would catch a binding that over-fires.
//
// It is also the only test in the tree that proves attach SITE 2 carries the
// resolved credential end-to-end on the wire: the drafts/raw arms here go red if
// the perspective branch stops attaching, which is precisely the state this row
// was filed about (a private schema read that answers not_found while holding a
// valid admin token).
//
// MUTATION PROOF (run 2026-09-17): drop the `normalizeServerURL(active.Server)
// != normalizeServerURL(ctx.Server)` conjunct so the binding fires on EVERY
// active-layer token -> ALL NINE arms fail with "CONTROL FAILED: … did not carry
// the saved credential to the DOCUMENT ROUTE on the very server it was saved
// for". A binding that withholds everywhere passes the leak arms perfectly and
// silently unauthenticates every read — which is the false-404 again, wearing a
// security fix as a costume.
//
// The assertion is on the DOCUMENT route, not merely "some request carried it":
// an arm satisfied by the /v1/capabilities fetch alone would stay green while
// every doc read went out anonymous.
func TestDocReadVerbsStillCarryTheirCredentialToTheirOwnHost(t *testing.T) {
	for _, arm := range docPairingArms {
		t.Run(arm.name, func(t *testing.T) {
			withTempConfigHome(t)
			clearBarkparkEnv(t)
			t.Chdir(t.TempDir())
			srv := newDocPairingRecorder()
			defer srv.Close()
			// Saved for the recorder ITSELF — the ordinary authenticated flow.
			savedFor(t, srv.URL, pairingSavedToken)

			_, stderr, _ := captureExecuteArgv(t, arm.argv...)

			hits := srv.seen()
			t.Logf("%s recorded %d request(s):%s", arm.name, len(hits), srv.describe())

			if len(hits) == 0 {
				t.Fatalf("VACUOUS control: %s reached the recorder zero times.\nstderr:\n%s", arm.name, stderr)
			}
			if !srv.carriedOnDocRoute(pairingSavedToken) {
				t.Fatalf("CONTROL FAILED: %s did not carry the saved credential to the DOCUMENT ROUTE on "+
					"the very server it was saved for (%s). A tier-none read of a visibility:private "+
					"schema without its credential is the false-404 this row exists to kill.\n"+
					"recorded:%s\nstderr:\n%s", arm.name, srv.URL, srv.describe(), stderr)
			}
			if strings.Contains(stderr, "withheld") {
				t.Fatalf("CONTROL FAILED: %s reported a withholding against its OWN server.\nstderr:\n%s",
					arm.name, stderr)
			}
		})
	}
}
