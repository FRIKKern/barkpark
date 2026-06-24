package cli

import "testing"

// extractDeployURL must handle both `vercel deploy` output shapes: plain text
// (URL on the last line) and JSON (a "url": "….vercel.app" field, where the last
// non-empty line is just "}"). Regression test for the "deployed: }" bug.
func TestExtractDeployURL(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "plain text, url on last line",
			in:   "Inspect: https://vercel.com/guerrilla/co-lab/abc\nhttps://co-776jn3e40-guerrilla.vercel.app\n",
			want: "https://co-776jn3e40-guerrilla.vercel.app",
		},
		{
			name: "json output (last line is })",
			in: `{
  "deployment": {
    "id": "dpl_x",
    "url": "https://co-776jn3e40-guerrilla.vercel.app",
    "inspectorUrl": "https://vercel.com/guerrilla/co-lab/abc",
    "deploymentApiUrl": "https://api.vercel.com/v13/deployments/dpl_x"
  }
}`,
			want: "https://co-776jn3e40-guerrilla.vercel.app",
		},
		{
			name: "no vercel.app url falls back to last line",
			in:   "some progress\nfinal line\n",
			want: "final line",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := extractDeployURL(c.in); got != c.want {
				t.Fatalf("extractDeployURL() = %q, want %q", got, c.want)
			}
		})
	}
}
