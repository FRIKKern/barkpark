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
	}
	for _, s := range terminal {
		if !SiteDeploymentTerminal(s) {
			t.Fatalf("SiteDeploymentTerminal(%q) = false, want true — the deploy stream would poll ~10 min and then report it as in progress", s)
		}
	}
	// Every non-terminal status of the six-value enum, plus the empty string, must
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
