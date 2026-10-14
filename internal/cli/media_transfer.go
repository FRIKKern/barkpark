package cli

// media_transfer.go holds the parts of the blob sidecar that decide HOW a media
// file moves: the route a file is read from, and the pace the requests go out
// at. fetchWorkspaceBlobs and uploadWorkspaceBlobs (cloud_workspace_cmd.go) use
// both.
//
// THE ROUTE (task-bf56c5d0302a2d6f). The sidecar used to read every file from
// the flat `/media/files/<path>`. The flat route resolves its tenant from the
// token or, failing that, the seeded Default workspace (router.ex `:api`,
// DeriveWorkspaceFromToken then AssignDefaultScope). A media row that lives in
// any other workspace is then outside the read scope, and the server answers
// 404 "file not found" for a file it serves fine on its scoped route. That is
// what turned 535 of gyldendal-no's 1,299 files into "file not found" on a dev
// pull while the public `/w/gyldendal-no/p/default/images/...` URLs answered
// 200. The fix reads each file from `/w/<ws>/p/<project>/media/files/<path>`,
// the scoped delivery route, with the workspace from the bundle manifest and
// the project from the row's own project_id.
//
// THE PACE. Every media GET is a read on the source's rate limiter
// (`read_per_minute`, 300 by default) and every blob push is a write on the
// target's (`write_per_minute`, 60). The sidecar used to send one request per
// file as fast as the network allowed, so a large set ran into 429 and every
// refused file counted as a failure. mediaPacer spaces the requests, waits out
// the server's Retry-After on a 429, retries the same file, and widens its own
// spacing after each 429 so the rest of the run stays under the limit.

import (
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Package-level clock seams so tests can run a 429 sequence without sleeping.
var (
	mediaSleep = time.Sleep
	mediaNow   = time.Now
)

const (
	// defaultMediaRatePerMinute is the starting pace when the caller names
	// none. It sits under the server's default read budget of 300 a minute.
	defaultMediaRatePerMinute = 240
	// mediaMaxRateLimitRetries bounds how often ONE file is retried after a
	// 429 before it is reported as a failure.
	mediaMaxRateLimitRetries = 12
	// mediaMaxRetryAfter caps a single wait, so a hostile or broken header
	// cannot park the pull for an hour.
	mediaMaxRetryAfter = 120 * time.Second
	// mediaMinBackoffInterval and mediaMaxBackoffInterval bound the spacing the
	// pacer widens to after a 429.
	mediaMinBackoffInterval = 250 * time.Millisecond
	mediaMaxBackoffInterval = 10 * time.Second
	// mediaEaseAfter is how many successes in a row earn a 10% shorter gap,
	// never shorter than the configured base pace.
	mediaEaseAfter = 20
)

// mediaPacer spaces media requests and handles 429 for one sidecar run.
type mediaPacer struct {
	base       time.Duration // the configured gap; 0 means no fixed pace
	interval   time.Duration // the current gap, never below base
	last       time.Time
	streak     int
	maxRetries int

	throttled int           // how many 429 answers this run saw
	waited    time.Duration // total time spent waiting on Retry-After
}

// newMediaPacer builds a pacer for perMinute requests a minute. perMinute <= 0
// sends without a fixed pace and only slows down after a 429.
func newMediaPacer(perMinute int) *mediaPacer {
	p := &mediaPacer{maxRetries: mediaMaxRateLimitRetries}
	if perMinute > 0 {
		p.base = time.Minute / time.Duration(perMinute)
		p.interval = p.base
	}
	return p
}

// wait blocks until the next request may go out.
func (p *mediaPacer) wait() {
	if p.interval > 0 && !p.last.IsZero() {
		if d := p.last.Add(p.interval).Sub(mediaNow()); d > 0 {
			mediaSleep(d)
		}
	}
	p.last = mediaNow()
}

// rateLimited records a 429: it waits out the server's Retry-After (or a
// doubling fallback when the header is absent) and widens the gap for every
// request after this one.
func (p *mediaPacer) rateLimited(retryAfter string, attempt int) {
	p.throttled++
	p.streak = 0
	d, ok := parseRetryAfter(retryAfter, mediaNow())
	if !ok {
		d = time.Second << uint(min(attempt, 6))
	}
	if d > mediaMaxRetryAfter {
		d = mediaMaxRetryAfter
	}
	if d > 0 {
		mediaSleep(d)
		p.waited += d
	}
	next := p.interval * 2
	if next < mediaMinBackoffInterval {
		next = mediaMinBackoffInterval
	}
	if next > mediaMaxBackoffInterval {
		next = mediaMaxBackoffInterval
	}
	if next > p.interval {
		p.interval = next
	}
	p.last = mediaNow()
}

// succeeded eases the gap back toward the base pace after a run of successes.
func (p *mediaPacer) succeeded() {
	p.streak++
	if p.streak < mediaEaseAfter || p.interval <= p.base {
		return
	}
	p.streak = 0
	p.interval = p.interval * 9 / 10
	if p.interval < p.base {
		p.interval = p.base
	}
}

// do sends the request that build makes, through the pacer, and retries it on
// 429 up to maxRetries times. build is called once per attempt, so a request
// with a file body opens a fresh reader each time. The last 429 response is
// returned as is when the retries run out, so the caller classifies it like
// any other refusal.
func (p *mediaPacer) do(client *http.Client, build func() (*http.Request, error)) (*http.Response, error) {
	for attempt := 0; ; attempt++ {
		p.wait()
		req, err := build()
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode != http.StatusTooManyRequests || attempt >= p.maxRetries {
			if resp.StatusCode < 300 {
				p.succeeded()
			}
			return resp, nil
		}
		ra := resp.Header.Get("Retry-After")
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		p.rateLimited(ra, attempt)
	}
}

// parseRetryAfter reads a Retry-After value: delay seconds or an HTTP date.
func parseRetryAfter(v string, now time.Time) (time.Duration, bool) {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0, false
	}
	if n, err := strconv.Atoi(v); err == nil {
		if n < 0 {
			return 0, false
		}
		return time.Duration(n) * time.Second, true
	}
	if t, err := http.ParseTime(v); err == nil {
		d := t.Sub(now)
		if d < 0 {
			d = 0
		}
		return d, true
	}
	return 0, false
}

// blobFetchURL is the URL one media file is read from. With a workspace slug
// it is the scoped delivery route the server serves the file on; without one
// (a bundle whose manifest names no workspace) it falls back to the flat
// route, which is all such a bundle can say.
func blobFetchURL(base, workspace string, ref mediaBlobRef) string {
	if workspace == "" {
		return base + "/media/files/" + escapeBlobPath(ref.path)
	}
	project := ref.project
	if project == "" {
		project = "default"
	}
	return base + "/w/" + url.PathEscape(workspace) + "/p/" + url.PathEscape(project) +
		"/media/files/" + escapeBlobPath(ref.path)
}
