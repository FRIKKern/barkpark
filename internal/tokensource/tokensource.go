// Package tokensource hands the on-box daemons (barkpark-builder,
// barkpark-runtime) a bearer token that follows its --token-file across a
// rewrite, so a supersede-mint does not strand a long-running process.
//
// Why this exists: provisioning supersede-mints the box's 'report' agent token
// on claim / stale-reclaim and rewrites /etc/barkpark/agent.token. The control
// plane revokes the superseded token, so a daemon that read the file once at
// start 401s on every poll until someone restarts it.
//
// Policy — re-read on 401, retry at most once:
//
//   - The caller attaches `Authorization: Bearer <Token()>`; the happy path
//     never touches the disk, Token() returns the cached value.
//   - A 401 re-reads the file. If the token now differs from the one that
//     request carried, the request is replayed ONCE with the new token.
//   - A 401 with an unchanged file returns the 401 to the caller untouched —
//     no second attempt, so a genuinely revoked token cannot hot-loop. The
//     daemon's own poll interval is the only retry cadence.
//
// "Differs from the one the request carried" (not "the reload changed the
// cache") matters under concurrency: when two requests 401 together, the first
// reload swaps the cache and the second sees no change, yet the second request
// still carried the stale token and must be replayed.
//
// A literal --token has no file to re-read; Literal wraps it so the daemons
// keep one code path, and its 401s pass straight through as before.
package tokensource

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
)

// Source is a bearer token that may be refreshed from a file.
type Source struct {
	path string // "" for a literal token

	mu  sync.Mutex
	cur string
}

// Literal returns a Source for a fixed token (the --token flag). It never
// reloads.
func Literal(token string) *Source {
	return &Source{cur: token}
}

// FromFile reads path now and returns a Source that re-reads it on a 401.
// An unreadable or empty file is an error at start, exactly as the read-once
// code refused to start.
func FromFile(path string) (*Source, error) {
	tok, err := readFile(path)
	if err != nil {
		return nil, err
	}
	return &Source{path: path, cur: tok}, nil
}

func readFile(path string) (string, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	tok := strings.TrimSpace(string(buf))
	if tok == "" {
		return "", fmt.Errorf("token file %s is empty", path)
	}
	return tok, nil
}

// Token returns the current cached token. No disk read.
func (s *Source) Token() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cur
}

// Reload re-reads the token file and returns the (possibly new) current
// token. A literal Source, an unreadable file, or an empty file keeps the
// cached token — a half-written rewrite must not blank the credential.
func (s *Source) Reload() string {
	if s.path == "" {
		return s.Token()
	}
	tok, err := readFile(s.path)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err == nil {
		s.cur = tok
	}
	return s.cur
}

// Wrap returns a RoundTripper that applies the re-read-on-401 policy to
// requests carrying a bearer. A nil base means http.DefaultTransport.
func (s *Source) Wrap(base http.RoundTripper) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return &transport{src: s, base: base}
}

// Client returns a shallow copy of c (Timeout, Jar, CheckRedirect kept) whose
// transport is wrapped by s. A nil c yields a fresh client with no timeout —
// callers pass their own Timeout-bearing fallback.
func (s *Source) Client(c *http.Client) *http.Client {
	var cp http.Client
	if c != nil {
		cp = *c
	}
	cp.Transport = s.Wrap(cp.Transport)
	return &cp
}

type transport struct {
	src  *Source
	base http.RoundTripper
}

// RoundTrip acts only on requests that already carry a bearer (the daemon's
// attachAuth sets it from Token()). A request without one passes straight
// through — in particular a redirect to another host, from which http.Client
// has already stripped Authorization, never has the token put back.
func (t *transport) RoundTrip(req *http.Request) (*http.Response, error) {
	auth := req.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return t.base.RoundTrip(req)
	}
	sent := strings.TrimPrefix(auth, "Bearer ")

	resp, err := t.base.RoundTrip(req)
	if err != nil || resp.StatusCode != http.StatusUnauthorized {
		return resp, err
	}

	fresh := t.src.Reload()
	if fresh == "" || fresh == sent {
		// The file still holds the token the server just refused: return the
		// 401. Retrying here is what would loop hot.
		return resp, nil
	}

	var body io.ReadCloser
	if req.Body != nil && req.Body != http.NoBody {
		if req.GetBody == nil {
			// Cannot replay an unrewindable body. The cache is already
			// refreshed, so the caller's next request carries the new token.
			return resp, nil
		}
		b, gerr := req.GetBody()
		if gerr != nil {
			return resp, nil
		}
		body = b
	} else {
		body = req.Body
	}

	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	_ = resp.Body.Close()

	// A RoundTripper must not mutate its input: replay on a clone.
	retry := req.Clone(req.Context())
	retry.Body = body
	retry.Header.Set("Authorization", "Bearer "+fresh)
	return t.base.RoundTrip(retry)
}

// ErrNoToken is returned by Resolve when neither a literal nor a file is given.
var ErrNoToken = errors.New("--token or --token-file is required")

// Resolve implements the daemons' flag precedence: a non-empty literal wins
// (kept exactly as before), otherwise the file. Neither is ErrNoToken.
func Resolve(literal, file string) (*Source, error) {
	if literal != "" {
		return Literal(literal), nil
	}
	if file == "" {
		return nil, ErrNoToken
	}
	src, err := FromFile(file)
	if err != nil {
		return nil, fmt.Errorf("read --token-file %s: %w", file, err)
	}
	return src, nil
}
