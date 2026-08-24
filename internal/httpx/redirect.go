// Package httpx holds bp's cross-package HTTP policy — the rules that must be
// identical on every client the binary builds, so a new call site cannot quietly
// opt out of one.
package httpx

import (
	"fmt"
	"net/http"
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
// @canonical capability:http-redirect-policy aka:CheckRedirect,follow redirect,302,ErrUseLastResponse,downgrade POST to GET
func CheckRedirect(req *http.Request, via []*http.Request) error {
	if len(via) > 0 && IsWriteMethod(via[0].Method) {
		return fmt.Errorf(
			"refusing to follow a redirect on a %s to %s (→ %s): a redirect drops the request body and downgrades the write to a read — re-run against the final URL",
			via[0].Method, via[0].URL.Redacted(), req.URL.Redacted())
	}
	if len(via) >= MaxRedirects {
		return fmt.Errorf("stopped after %d redirects", MaxRedirects)
	}
	return nil
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
