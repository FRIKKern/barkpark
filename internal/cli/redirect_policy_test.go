package cli

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The fixture this whole file is built on: a host that answers ANY request with
// a redirect to a second host serving a text/html 200 login page. That is not an
// invention — guerrilla serves exactly that shape (a 517,831-byte text/html 200)
// one 302 hop from its root, which is how a write receipt of "200 OK" over an
// HTML body reached production. redirectFixture returns the redirecting host's
// URL plus a record of every request the DESTINATION saw.
type redirectLanding struct {
	methods []string
	bodies  []string
}

func redirectFixture(t *testing.T, status int) (redirectURL string, landing *redirectLanding) {
	t.Helper()
	landing = &redirectLanding{}
	dest := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 1024)
		n, _ := r.Body.Read(buf)
		landing.methods = append(landing.methods, r.Method)
		landing.bodies = append(landing.bodies, string(buf[:n]))
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "<!doctype html><title>Sign in</title>")
	}))
	t.Cleanup(dest.Close)

	src := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, dest.URL+"/login", status)
	}))
	t.Cleanup(src.Close)
	return src.URL + "/v1/data/mutate/production", landing
}

// A WRITE that meets a redirect must FAIL LOUDLY. Under Go's default policy a
// 302 rewrites the POST into a bodyless GET, the login page answers 200, and bp
// reported a successful write over a request whose body was never sent.
func TestDoRequestRefusesRedirectOnWrite(t *testing.T) {
	for _, status := range []int{
		http.StatusMovedPermanently,  // 301
		http.StatusFound,             // 302
		http.StatusSeeOther,          // 303
		http.StatusTemporaryRedirect, // 307
		http.StatusPermanentRedirect, // 308
	} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			url, landing := redirectFixture(t, status)
			code, body, err := doRequest("POST", url, nil, []byte(`{"mutations":[]}`))
			if err == nil {
				t.Fatalf("POST through a %d redirect returned no error: status=%d body=%.80q — the write silently became a read", status, code, body)
			}
			if !strings.Contains(err.Error(), "refusing to follow") {
				t.Fatalf("error does not name the refusal: %v", err)
			}
			if code == http.StatusOK {
				t.Fatalf("POST through a %d redirect reported 200 OK", status)
			}
			if len(landing.methods) != 0 {
				t.Fatalf("redirect destination was contacted %v — a refused write must not reach it", landing.methods)
			}
		})
	}
}

// Every write verb, not just POST — the defect is in the client, not the route.
func TestDoRequestRefusesRedirectOnEveryWriteVerb(t *testing.T) {
	for _, method := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		t.Run(method, func(t *testing.T) {
			url, _ := redirectFixture(t, http.StatusFound)
			if _, _, err := doRequest(method, url, nil, []byte(`{}`)); err == nil {
				t.Fatalf("%s through a 302 returned no error", method)
			}
		})
	}
}

// The streaming client (media upload) is the same write path with a
// non-replayable body — a redirect there drops the upload just as silently.
func TestDoRequestStreamRefusesRedirectOnWrite(t *testing.T) {
	url, landing := redirectFixture(t, http.StatusFound)
	body := strings.NewReader("--boundary\r\n")
	code, _, err := doRequestStream("POST", url, nil, body, int64(body.Len()))
	if err == nil {
		t.Fatalf("streaming POST through a 302 returned no error (status=%d)", code)
	}
	if !strings.Contains(err.Error(), "refusing to follow") {
		t.Fatalf("error does not name the refusal: %v", err)
	}
	if len(landing.methods) != 0 {
		t.Fatalf("redirect destination was contacted %v", landing.methods)
	}
}

// A READ still follows — the policy narrows writes only, so an http→https or
// path-normalising redirect on a GET keeps working exactly as before.
func TestDoRequestStillFollowsRedirectOnRead(t *testing.T) {
	url, landing := redirectFixture(t, http.StatusFound)
	code, body, err := doRequest("GET", url, nil, nil)
	if err != nil {
		t.Fatalf("GET through a 302 failed: %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("GET through a 302 got %d, want 200", code)
	}
	if !strings.Contains(string(body), "Sign in") {
		t.Fatalf("GET did not land on the destination: %.80q", body)
	}
	if len(landing.methods) != 1 || landing.methods[0] != "GET" {
		t.Fatalf("destination saw %v, want one GET", landing.methods)
	}
}

// Setting CheckRedirect REPLACES Go's default policy wholesale, including its
// 10-hop cap. A read against an infinite redirect loop must still terminate.
func TestDoRequestCapsRedirectHopsOnRead(t *testing.T) {
	var srv *httptest.Server
	hops := 0
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hops++
		http.Redirect(w, r, srv.URL+"/again", http.StatusFound)
	}))
	t.Cleanup(srv.Close)

	if _, _, err := doRequest("GET", srv.URL, nil, nil); err == nil {
		t.Fatalf("infinite redirect loop on a GET returned no error after %d hops", hops)
	}
	if hops > maxRedirects+1 {
		t.Fatalf("followed %d hops, want at most %d", hops, maxRedirects+1)
	}
}
