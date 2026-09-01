package cloudclient

// site_test.go pins the spawned-site (site-spawner) client contract that the CLI's
// deploy stream depends on for its honesty: which deployment statuses END the poll
// loop, and that the six visible stages keep their canonical order.
//
// The terminal set is load-bearing, not cosmetic: the CLI polls until it is true, so
// a real terminal status missing from it means the stream spins its full budget
// (300 × 2s ≈ 10 min) and then tells the user the deploy is "in progress" — which is
// exactly what `cancelled` used to do.

import (
	"context"
	"net/http"
	"testing"
)

// TestDeploySpawnSiteBodyOnlyCarriesSetFlags pins the cf-in-front deploy body
// contract (D57): `via`/`domain` ride the POST body ONLY when non-empty, exactly
// like `force`. A plain deploy must be byte-identical to the pre-cf request (no
// stray `via`/`domain` keys the server would have to ignore), and a cutover
// deploy must carry both.
func TestDeploySpawnSiteBodyOnlyCarriesSetFlags(t *testing.T) {
	cases := []struct {
		name           string
		force          bool
		via, domain    string
		wantForce      bool
		wantVia        any
		wantDomain     any
		wantViaPresent bool
	}{
		{name: "plain deploy carries nothing", wantForce: false},
		{name: "force only", force: true, wantForce: true},
		{
			name: "cloudflare cutover carries via+domain",
			via:  "cloudflare", domain: "blog.example.com",
			wantVia: "cloudflare", wantDomain: "blog.example.com", wantViaPresent: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got map[string]any
			c := newFake(t, "sess", func(w http.ResponseWriter, r *http.Request) {
				got = readJSON(t, r)
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(`{"deployment":{"id":"dep_1","status":"queued"}}`))
			})

			if _, err := c.DeploySpawnSite(context.Background(), "site_1", tc.force, tc.via, tc.domain); err != nil {
				t.Fatalf("DeploySpawnSite: %v", err)
			}

			if _, present := got["force"]; present != tc.wantForce {
				t.Fatalf("force present=%v, want %v (body=%v)", present, tc.wantForce, got)
			}
			if _, present := got["via"]; present != tc.wantViaPresent {
				t.Fatalf("via present=%v, want %v (body=%v)", present, tc.wantViaPresent, got)
			}
			if tc.wantViaPresent {
				if got["via"] != tc.wantVia {
					t.Fatalf("via=%v, want %v", got["via"], tc.wantVia)
				}
				if got["domain"] != tc.wantDomain {
					t.Fatalf("domain=%v, want %v", got["domain"], tc.wantDomain)
				}
			} else if _, present := got["domain"]; present {
				t.Fatalf("domain should be absent when unset (body=%v)", got)
			}
		})
	}
}

func TestSiteDeploymentTerminal(t *testing.T) {
	terminal := []string{
		"live", "failed", "cancelled",
		"canceled", // the other spelling of the same end-state
		"  LIVE  ", // whitespace + case are the server's business, not ours
		"Cancelled",
		// deferred settles as [] in the control plane's transition table, and it is
		// 73.7% of settled attempts — this list named it in NEITHER direction until
		// wave 32, which is why the majority outcome spun for ten minutes.
		"deferred", "Deferred", "  deferred  ",
	}
	for _, s := range terminal {
		if !SiteDeploymentTerminal(s) {
			t.Fatalf("SiteDeploymentTerminal(%q) = false, want true — the deploy stream would poll its full 300×2s budget (~10 min) against a row that can never change and then print \"deploy in progress\" over a settled deploy", s)
		}
	}
	// Every non-terminal status of the seven-value enum, plus the empty string, must
	// keep the loop polling.
	for _, s := range []string{"queued", "building", "pushing", "", "unknown"} {
		if SiteDeploymentTerminal(s) {
			t.Fatalf("SiteDeploymentTerminal(%q) = true, want false — the stream would stop before the deploy landed", s)
		}
	}
}

// TestSpawnSiteStagesOrder pins the six visible stages and their order — the bar the
// CLI renders and the deploy engine walks.
func TestSpawnSiteStagesOrder(t *testing.T) {
	want := []string{"PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"}
	if len(SpawnSiteStages) != len(want) {
		t.Fatalf("SpawnSiteStages = %v, want %v", SpawnSiteStages, want)
	}
	for i, name := range want {
		if SpawnSiteStages[i] != name {
			t.Fatalf("SpawnSiteStages[%d] = %q, want %q (order is the contract)", i, SpawnSiteStages[i], name)
		}
	}
}

// TestCloudErrorCarriesDetail pins the CLI's half of the honest-failure promise.
//
// The control plane puts the machine code in `error` and the human sentence in
// `detail` — "which box refused and what it said", "which flag fixes this". The
// site-spawner routes invest heavily in that copy (read_token_mint_failed names
// the instance and quotes it; content_binding_required names --dataset). If
// cloudError drops `detail`, every one of those becomes a bare slug on screen and
// the investment is invisible. This is the whole "real failure messages" bar.
func TestCloudErrorCarriesDetail(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		want string
	}{
		{
			name: "code and detail are both surfaced",
			body: `{"error":"read_token_mint_failed","detail":"acme refused to mint the site's read token (HTTP 403): forbidden"}`,
			want: "read_token_mint_failed: acme refused to mint the site's read token (HTTP 403): forbidden",
		},
		{
			name: "a code with no detail is unchanged",
			body: `{"error":"barkpark_not_found"}`,
			want: "barkpark_not_found",
		},
		{
			// `details` (an object, from a changeset) must NOT poison the decode
			// and dump the raw body — degrade to the code alone.
			name: "a non-string detail degrades to the code, never a raw body dump",
			body: `{"error":"invalid","detail":{"name":["can't be blank"]}}`,
			want: "invalid",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := cloudError(422, []byte(tc.body)).Error()
			if got != tc.want {
				t.Fatalf("cloudError = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestListSpawnSiteDeploymentsDecodesDeferralChain: deploy-reliability W13 S3.
//
// The control plane writes deferral_depth / deferral_bound / deferral_cause on
// every deferred row (W12) and now emits them from its sole base deployment
// serializer. Before this slice `SiteDeployment` declared NONE of the three, so
// json.Unmarshal dropped a perfectly correct payload on the floor without a
// word — which is why the CLI still recovers a wait's depth by regexing the
// English out of failure_reason.
//
// IT CAN LOSE: delete the three fields from `SiteDeployment` and the first
// block reds with nil pointers; make them plain ints and the second block reds,
// because an absent chain would decode to 0 and read as "deferred zero times".
func TestListSpawnSiteDeploymentsDecodesDeferralChain(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"deployments":[
			{"id":"dep-1","site_id":"site-1","status":"deferred",
			 "deferral_depth":3,"deferral_bound":12,
			 "deferral_cause":"BOX_AT_CAPACITY_DEFERRED"},
			{"id":"dep-2","site_id":"site-1","status":"live",
			 "deferral_depth":null,"deferral_bound":null,"deferral_cause":null}
		]}`))
	})

	page, err := c.ListSpawnSiteDeployments(context.Background(), "site-1", 0, "")
	if err != nil {
		t.Fatalf("ListSpawnSiteDeployments: %v", err)
	}
	if len(page.Deployments) != 2 {
		t.Fatalf("decoded %d deployment(s), want 2", len(page.Deployments))
	}

	chain := page.Deployments[0]
	if chain.DeferralDepth == nil || chain.DeferralBound == nil || chain.DeferralCause == nil {
		t.Fatalf("the chain was on the wire and decoded nil: %+v", chain)
	}
	if *chain.DeferralDepth != 3 || *chain.DeferralBound != 12 {
		t.Fatalf("depth/bound = %d/%d, want 3/12", *chain.DeferralDepth, *chain.DeferralBound)
	}
	// The frozen LEDGER CLASS, not a raw box code.
	if *chain.DeferralCause != "BOX_AT_CAPACITY_DEFERRED" {
		t.Fatalf("deferral_cause = %q", *chain.DeferralCause)
	}

	// A row with no chain stays UNKNOWN. Every deferral written before
	// migration 20260807150000 is in this state, so a zero here would be the
	// control plane confidently asserting a depth nobody ever recorded.
	none := page.Deployments[1]
	if none.DeferralDepth != nil || none.DeferralBound != nil || none.DeferralCause != nil {
		t.Fatalf("a row with no chain must decode nil, got %+v", none)
	}
}

// --- the create-time content-binding verdict (ssw8) --------------------------
//
// POST /v1/sites answers with the row under `site` and the control plane's
// create-time read of the bound type under a TOP-LEVEL `content_binding` key.
// CreateSpawnSite decoded `{site}` alone and threw the verdict away, so a caller
// whose binding came back UNVERIFIED was handed a row that looked exactly like a
// confirmed one.
//
// The count pointer is the subtle half: the producer OMITS `count` when the box
// published no total, so ABSENT and ZERO are different answers and a `Count int`
// would render them identically.
func TestCreateSpawnSiteDecodesTheBindingVerdict(t *testing.T) {
	intp := func(i int) *int { return &i }
	for _, tc := range []struct {
		name       string
		body       string
		wantStatus string
		wantType   string
		wantDetail string
		wantCount  *int
	}{
		{
			name:       "bound with the box's total",
			body:       `{"site":{"id":"site_1"},"content_binding":{"status":"bound","doc_type":"post","count":12}}`,
			wantStatus: "bound", wantType: "post", wantCount: intp(12),
		},
		{
			// The key is absent — not null, not 0. nil is the ONLY honest decode.
			name:       "bound with NO count key",
			body:       `{"site":{"id":"site_1"},"content_binding":{"status":"bound","doc_type":"post"}}`,
			wantStatus: "bound", wantType: "post", wantCount: nil,
		},
		{
			// ...and a real zero is a real answer, distinguishable from the above.
			name:       "bound with an explicit zero total",
			body:       `{"site":{"id":"site_1"},"content_binding":{"status":"bound","doc_type":"post","count":0}}`,
			wantStatus: "bound", wantType: "post", wantCount: intp(0),
		},
		{
			// `detail`, not `reason` — and no doc_type on this arm at all.
			name:       "unverified carries detail",
			body:       `{"site":{"id":"site_1"},"content_binding":{"status":"unverified","detail":"blog-box has no URL yet"}}`,
			wantStatus: "unverified", wantDetail: "blog-box has no URL yet",
		},
		{
			// The :not_applicable case — no key at all, so no verdict, which must
			// NOT decode into anything a renderer could mistake for "unverified".
			name: "absent content_binding is the zero verdict",
			body: `{"site":{"id":"site_1"}}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newFake(t, "sess", func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(tc.body))
			})
			got, err := c.CreateSpawnSite(context.Background(), SpawnSiteCreate{Name: "blog"})
			if err != nil {
				t.Fatalf("CreateSpawnSite: %v", err)
			}
			if got.Site.ID != "site_1" {
				t.Fatalf("site row lost: %+v", got.Site)
			}
			b := got.ContentBinding
			if b.Status != tc.wantStatus || b.DocType != tc.wantType || b.Detail != tc.wantDetail {
				t.Fatalf("verdict = %+v, want status=%q doc_type=%q detail=%q", b, tc.wantStatus, tc.wantType, tc.wantDetail)
			}
			switch {
			case tc.wantCount == nil && b.Count != nil:
				t.Fatalf("count = %d, want ABSENT — an omitted count must stay nil, or the receipt can print a total nobody published", *b.Count)
			case tc.wantCount != nil && b.Count == nil:
				t.Fatalf("count = nil, want %d", *tc.wantCount)
			case tc.wantCount != nil && *b.Count != *tc.wantCount:
				t.Fatalf("count = %d, want %d", *b.Count, *tc.wantCount)
			}
		})
	}
}
