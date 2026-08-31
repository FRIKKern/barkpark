// Package httpx holds bp's cross-package HTTP policy — the rules that must be
// identical on every client the binary builds, so a new call site cannot quietly
// opt out of one.
package httpx

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// MaxRedirects re-states Go's own default hop cap. Installing a CheckRedirect
// REPLACES the default policy wholesale — including the cap — so a client that
// sets a policy without one follows a redirect loop forever.
const MaxRedirects = 10

// CheckRedirect is bp's ONE redirect policy, and the choice it encodes is:
// A WRITE IS NEVER FOLLOWED, A READ IS.
//
// Go's default policy follows 301/302/303 by rewriting the request into a
// bodyless GET. So a POST against a host that redirects silently became a read:
// the mutation body was never sent, the redirect target answered 200, and bp
// printed that as a successful write. This is production-reachable, not a
// fixture invention — guerrilla serves a 517,831-byte text/html 200 login page
// one 302 hop from its root, which is exactly the HTML-200 write receipt the
// response fence refuses downstream. The fence catches the symptom; this is the
// cause. A write must not silently become a read.
//
// 307/308 DO preserve method and body, so following them would be safe in the
// narrow sense — they are refused anyway. A caller pointed at the wrong host
// learns nothing from a write that quietly lands somewhere else, one rule is
// easier to reason about than a status-code table, and the refusal names the
// destination so the fix is a one-line change to -s / BARKPARK_HOST.
//
// This is the same principle the five pre-existing CheckRedirect sites in
// internal/ already encode — apiclient/release_paper.go, cli/upgrade.go,
// cli/setup/healthgate.go, provisioner/verify.go and its fixture test all
// install http.ErrUseLastResponse. Those are probes that READ the 3xx itself
// (its Location, or its verbatim status), so they stop at the first hop instead
// of erroring; none of them follows a redirect silently, and neither does this.
//
// @canonical capability:http-redirect-policy aka:CheckRedirect,follow redirect,302,ErrUseLastResponse,downgrade POST to GET,strip credentials,Authorization,Cookie,cross-scheme,cross-port
func CheckRedirect(req *http.Request, via []*http.Request) error {
	if len(via) > 0 && IsWriteMethod(via[0].Method) {
		return fmt.Errorf(
			"refusing to follow a redirect on a %s to %s (→ %s): a redirect drops the request body and downgrades the write to a read — re-run against the final URL",
			via[0].Method, via[0].URL.Redacted(), req.URL.Redacted())
	}
	if len(via) >= MaxRedirects {
		return fmt.Errorf("stopped after %d redirects", MaxRedirects)
	}
	if len(via) > 0 && credentialsAtRisk(via[0].URL, req.URL) {
		req.Header.Del("Authorization")
		req.Header.Del("Cookie")
		req.Header.Del("Cookie2")
		req.Header.Del("WWW-Authenticate")
	}
	return nil
}

// credentialsAtRisk reports whether a redirect from "from" to "to" changes
// scheme or effective port while keeping the same hostname. Go's stdlib only
// strips Authorization/Cookie on a differing Hostname() (idnaASCIIFromURL in
// net/http's client.go ignores scheme and port entirely), so a same-host hop
// that flips https->http, or that moves to a different port, forwards bp's
// bearer token untouched unless this function says otherwise.
func credentialsAtRisk(from, to *url.URL) bool {
	if from.Hostname() != to.Hostname() {
		// A different host is already stripped by net/http itself.
		return false
	}
	return from.Scheme != to.Scheme || effectivePort(from) != effectivePort(to)
}

// effectivePort normalises url.URL.Port(), which is empty string for the
// scheme's default port, so https://h and https://h:443 compare equal.
func effectivePort(u *url.URL) string {
	if p := u.Port(); p != "" {
		return p
	}
	switch u.Scheme {
	case "https":
		return "443"
	case "http":
		return "80"
	default:
		return ""
	}
}

// IsWriteMethod reports whether a method carries a request body whose loss would
// change what the call did. Anything that is not a known read is treated as a
// write, so a verb added later is refused by default rather than followed by
// default.
func IsWriteMethod(method string) bool {
	switch strings.ToUpper(method) {
	case "", http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	default:
		return true
	}
}
