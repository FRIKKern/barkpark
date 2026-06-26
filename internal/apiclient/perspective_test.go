package apiclient

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestQueryPerspective asserts the perspective wiring:
//   - an empty Perspective (the CLI / manifest contract) sends NO perspective
//     param, so the server applies its own default (published);
//   - Perspective="drafts" (the TUI default) appends ?perspective=drafts;
//   - a filter combines with the perspective via proper query-string encoding.
func TestQueryPerspective(t *testing.T) {
	cases := []struct {
		name        string
		perspective string
		filter      string
		wantPersp   string // expected perspective query param ("" = absent)
		wantFilter  string // expected filter query param ("" = absent)
	}{
		{"cli-default-published", "", "", "", ""},
		{"tui-drafts", "drafts", "", "drafts", ""},
		{"raw", "raw", "", "raw", ""},
		{"drafts-with-filter", "drafts", `title == "x"`, "drafts", `title == "x"`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var gotPersp, gotFilter string
			var perspPresent bool
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				q := r.URL.Query()
				_, perspPresent = q["perspective"]
				gotPersp = q.Get("perspective")
				gotFilter = q.Get("filter")
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"documents":[]}`))
			}))
			defer srv.Close()

			c := New(Config{BaseURL: srv.URL, Token: "t", Perspective: tc.perspective})
			c.Query("post", tc.filter)

			if tc.wantPersp == "" && perspPresent {
				t.Fatalf("expected NO perspective param, got %q", gotPersp)
			}
			if tc.wantPersp != "" && gotPersp != tc.wantPersp {
				t.Fatalf("perspective param: want %q, got %q", tc.wantPersp, gotPersp)
			}
			if gotFilter != tc.wantFilter {
				t.Fatalf("filter param: want %q, got %q", tc.wantFilter, gotFilter)
			}
		})
	}
}

// TestPerspectiveFromEnv asserts the TUI default ("drafts") and overrides.
func TestPerspectiveFromEnv(t *testing.T) {
	cases := []struct {
		set  bool
		val  string
		want string
	}{
		{false, "", "drafts"}, // unset -> TUI default
		{true, "drafts", "drafts"},
		{true, "published", "published"},
		{true, "raw", "raw"},
		{true, "garbage", "drafts"}, // unrecognised -> default, never junk to server
		{true, "", "drafts"},        // empty string -> default
	}
	for _, tc := range cases {
		if tc.set {
			t.Setenv("BARKPARK_PERSPECTIVE", tc.val)
		} else {
			// Ensure unset for this case.
			t.Setenv("BARKPARK_PERSPECTIVE", "")
			// t.Setenv with "" still SETS it; emulate unset by clearing then checking
			// the empty-string branch which also yields "drafts".
		}
		if got := PerspectiveFromEnv(); got != tc.want {
			t.Fatalf("BARKPARK_PERSPECTIVE=%q (set=%v): want %q, got %q", tc.val, tc.set, tc.want, got)
		}
	}
}
