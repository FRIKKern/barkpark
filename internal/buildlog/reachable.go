// Package buildlog owns ONE question, asked identically by every surface that
// touches a Deployment's `build_log_url`: can the READER of that field actually
// retrieve what it points at?
//
// WHY A PACKAGE FOR ONE PREDICATE. The field used to be stamped by
// internal/builder as `"file://" + <a path on the builder host>` and printed by
// internal/cli as a bare `log: <url>` line. Both halves were locally true and
// jointly a lie: the builder's own filesystem is not the reader's, nothing
// uploads that file, and the control plane discards any non-http(s) value
// outright (cloud's build_log_url allowlist), so the operator was handed a
// pointer that resolves on exactly one machine on earth — and not theirs.
//
// THE GUARD IS ON THE SHAPE, NOT ON A LIST OF BAD SCHEMES. A reader of this
// field fetches it with Go's net/http (the CLI's cloudclient, the Console's
// fetch, curl). net/http can retrieve http and https and NOTHING else. So the
// predicate is "would the reader's own transport retrieve this?", which makes
// every scheme nobody enumerated — ftp://, s3://, journal:, a bare
// /var/log/… path, a relative path — fail by construction rather than by
// somebody remembering to add it.
package buildlog

import (
	"net/url"
	"strings"
)

// ReaderFetchable reports whether raw is a URL the READER of a build_log_url
// can retrieve over the network. True for http/https URLs that carry a host;
// false for everything else, INCLUDING the empty string (nothing to fetch) and
// including a syntactically fine URL whose scheme no HTTP client speaks.
//
// A host is required because `http:///var/log/x` and `file:///var/log/x` differ
// only in a word: neither names a machine the reader could reach.
func ReaderFetchable(raw string) bool {
	s := strings.TrimSpace(raw)
	if s == "" {
		return false
	}
	u, err := url.Parse(s)
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https":
		return u.Host != ""
	default:
		return false
	}
}

// WhereItActuallyLives renders a non-fetchable build_log_url as what it IS — a
// location on the machine that WROTE the log — rather than as a link. Callers
// use it only after ReaderFetchable has said no; it never invents a scheme it
// was not given.
//
// A `file://` URL degrades to its bare path (that is the only part with
// meaning); anything else is echoed verbatim so an unfamiliar shape is not
// silently rewritten into something it is not.
func WhereItActuallyLives(raw string) string {
	s := strings.TrimSpace(raw)
	if u, err := url.Parse(s); err == nil && strings.EqualFold(u.Scheme, "file") {
		if p := u.Path; p != "" {
			return p
		}
	}
	return s
}

// ReachableDoor is the route that DOES serve a deployment's build log to a
// remote reader, named wherever a surface has to tell someone that the pointer
// in hand is not one. `bp sites logs <site> <deployment-id>` is its CLI verb.
const ReachableDoor = "GET /v1/sites/:id/deployments/:dep_id/build-log"
