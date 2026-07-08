package cli

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// migrateEndpoint.scopedURL must produce exactly what the canonical
// apiclient.ScopedURL does for the same base/scope/suffix — it is a pure
// delegate, not a second copy of the /w/<ws>/p/<proj> scheme. Before the dedup
// there was NO test on the migrate copy; this closes that gap and pins the two
// paths together so they can never drift again.
func TestMigrateEndpointScopedURLDelegatesToCanonical(t *testing.T) {
	cases := []struct {
		name   string
		ep     migrateEndpoint
		suffix string
		want   string
	}{
		{
			name:   "plain slugs",
			ep:     migrateEndpoint{url: "https://api.example.com", workspace: "acme", project: "web"},
			suffix: "/v1/data/mutate/production",
			want:   "https://api.example.com/w/acme/p/web/v1/data/mutate/production",
		},
		{
			// endpointFrom already TrimRight's the base, but assert the delegate
			// normalizes anyway so a raw trailing-slash base can never splice "//w/".
			name:   "trailing-slash base normalized",
			ep:     migrateEndpoint{url: "https://api.example.com/", workspace: "acme", project: "web"},
			suffix: "/v1/schemas/production",
			want:   "https://api.example.com/w/acme/p/web/v1/schemas/production",
		},
		{
			name:   "slugs requiring escaping",
			ep:     migrateEndpoint{url: "https://api.example.com", workspace: "my ws/#a", project: "proj?b"},
			suffix: "/v1/schemas/production",
			want:   "https://api.example.com/w/my%20ws%2F%23a/p/proj%3Fb/v1/schemas/production",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.ep.scopedURL(tc.suffix)
			if got != tc.want {
				t.Errorf("scopedURL(%q):\n got=%q\nwant=%q", tc.suffix, got, tc.want)
			}
			// Parity: the method output must be byte-identical to a direct call to
			// the shared canonical function — proving it is a delegate, not a fork.
			if canonical := apiclient.ScopedURL(tc.ep.url, tc.ep.workspace, tc.ep.project, tc.suffix); got != canonical {
				t.Errorf("not delegating to apiclient.ScopedURL:\n method=%q\ncanonical=%q", got, canonical)
			}
		})
	}
}
