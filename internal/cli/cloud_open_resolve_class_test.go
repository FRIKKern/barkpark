package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestRunCloudOpenNotFoundNameSpellingAuthToken is the misclassification pin:
// a resolve that found NOTHING must exit not_found even when the name the
// operator typed happens to spell one of the auth arm's tokens.
//
// openResolveFail used to decide "is this an auth failure?" by substring-matching
// the RENDERED sentence, and that sentence interpolates the caller's own ref
// (`no site matches %q`). So `bp cloud open site unauthorized-page` — a site that
// was deleted, or was never in this team — reported label `auth` at exit 3 and
// told the operator to re-run `bp login`, for a name that simply does not exist.
// The 401 that arm exists for arrives TYPED (*cloudclient.CloudRefusal carrying
// HTTPStatus), so the prose never had to be read at all.
func TestRunCloudOpenNotFoundNameSpellingAuthToken(t *testing.T) {
	for _, tc := range []struct{ kind, ref, want string }{
		{"site", "unauthorized-page", "no site matches"},
		{"instance", "not logged in", "no Barkpark matches"},
	} {
		t.Run(tc.kind+"/"+tc.ref, func(t *testing.T) {
			withTempConfigHome(t)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.WriteString(w, `{"barkparks":[],"sites":[]}`)
			}))
			defer srv.Close()
			seedCloudLogin(t, srv.URL)
			stubBrowser(t)

			_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
				out.output = "table"
				return runCloudOpen(out, globals{}, []string{tc.kind, tc.ref})
			})
			if code != exitNotFound {
				t.Fatalf("exit = %d, want %d (not_found): a %s that resolved to NOTHING was classified by the auth arm because the ref %q spells one of its substrings\nstderr: %s",
					code, exitNotFound, tc.kind, tc.ref, stderr)
			}
			if !bytes.Contains([]byte(stderr), []byte(tc.want)) {
				t.Fatalf("stderr = %s, want it to carry %q", stderr, tc.want)
			}
		})
	}
}

// TestRunCloudOpenUnauthorizedRefusalStaysAuth is the other half: a genuine
// control-plane 401 must STILL exit auth once the classification reads the
// refusal's typed HTTPStatus instead of its words. The body deliberately spells
// NEITHER "unauthorized" nor "not logged in" in its own slug, so the arm can
// only pass by reading the status.
func TestRunCloudOpenUnauthorizedRefusalStaysAuth(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"token_expired"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)
	stubBrowser(t)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudOpen(out, globals{}, []string{"instance", "acme"})
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth) for a control-plane 401\nstderr: %s", code, exitAuth, stderr)
	}
}

// TestRunCloudOpenNotLoggedInStaysAuth pins the local precondition arm: no cloud
// token at all is an auth failure, and stays one.
func TestRunCloudOpenNotLoggedInStaysAuth(t *testing.T) {
	withTempConfigHome(t)
	stubBrowser(t)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudOpen(out, globals{}, []string{"instance", "acme"})
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth) with no cloud token\nstderr: %s", code, exitAuth, stderr)
	}
}

// TestRunCloudOpenTransportFailureIsGeneric pins the fallthrough: a failure that
// is neither a declared local outcome nor a typed refusal (a transport error)
// stays generic.
func TestRunCloudOpenTransportFailureIsGeneric(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close() // nothing is listening — the resolve fails in transport
	seedCloudLogin(t, url)
	stubBrowser(t)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudOpen(out, globals{}, []string{"instance", "acme"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d (generic) for a transport failure\nstderr: %s", code, exitGeneric, stderr)
	}
}
