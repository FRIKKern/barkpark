// Command mutate-load drives N concurrent task create+publish rounds
// over POST /v1/data/mutate/<dataset> and reports per-leg latency percentiles
// and error classes (HTTP status + error.code, or the transport failure).
//
// One ROUND is exactly the pair of requests `bp task create --publish` sends
// (internal/cli/tasks_create_cmd.go): a `create` mutation for `_type: task`
// with the parser's defaults (kind=task, lifecycle_status=open), title,
// description, one weighted tag (--tag) and the PortableDoc brief bp composes
// (ensureTaskPortableBrief), then — on a 2xx that carried an id — a `publish` mutation for
// the bare id. Each leg carries its own Idempotency-Key (`<base>-create`,
// `<base>-publish`), as legKey does. The tag-registry pre-read bp makes before
// a --publish is NOT mirrored: it is a GET, and this harness measures writes.
//
// SAFETY. The target must be loopback (localhost, 127.0.0.0/8, ::1) or the run
// is refused before any request is built, unless --i-own-this-target is passed.
// This is a WRITE load generator; pointing it at a shared box files real rows.
//
// Exit codes: 0 every round landed; 1 at least one leg failed (the report says
// which classes); 2 usage error or refused target.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	mrand "math/rand"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type config struct {
	Server      string
	Token       string
	Workspace   string
	Project     string
	Dataset     string
	Rounds      int
	Concurrency int
	DescBytes   int
	Publish     bool
	DedupBypass bool
	TitlePrefix string
	Tag         string
	EnsureTag   bool
	Timeout     time.Duration
	OwnTarget   bool
	JSON        bool
	Label       string
}

// legResult is one HTTP request's outcome.
type legResult struct {
	Leg     string        `json:"leg"`
	Class   string        `json:"class"` // "ok" | "http_<status>:<code>" | "transport:<kind>" | "no_id"
	Status  int           `json:"status"`
	Latency time.Duration `json:"latency_ns"`
	// Resends counts connections beyond the first for this one request. Go's
	// transport silently resends a request carrying an Idempotency-Key header
	// when a REUSED connection dies before any response byte — bp's create legs
	// carry that header, so bp gets these resends too. Counted, not hidden.
	Resends int `json:"resends"`
}

type legStats struct {
	Count   int            `json:"count"`
	OK      int            `json:"ok"`
	P50ms   float64        `json:"p50_ms"`
	P95ms   float64        `json:"p95_ms"`
	P99ms   float64        `json:"p99_ms"`
	MaxMs   float64        `json:"max_ms"`
	Classes map[string]int `json:"classes"`
	Resends int            `json:"transport_resends"`
}

type report struct {
	Label       string               `json:"label,omitempty"`
	Server      string               `json:"server"`
	Rounds      int                  `json:"rounds"`
	Concurrency int                  `json:"concurrency"`
	DescBytes   int                  `json:"desc_bytes"`
	WallMs      float64              `json:"wall_ms"`
	RoundsOK    int                  `json:"rounds_ok"`
	Legs        map[string]*legStats `json:"legs"`
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, http.DefaultTransport))
}

func run(args []string, stdout, stderr io.Writer, rt http.RoundTripper) int {
	cfg, err := parseFlags(args, stderr)
	if err != nil {
		fmt.Fprintln(stderr, "mutate-load:", err)
		return 2
	}
	if err := checkTarget(cfg.Server, cfg.OwnTarget); err != nil {
		fmt.Fprintln(stderr, "mutate-load: REFUSED:", err)
		return 2
	}
	client := &http.Client{Transport: rt, Timeout: cfg.Timeout}
	if cfg.EnsureTag && cfg.Tag != "" {
		ensureTag(context.Background(), cfg, client, stderr)
	}
	rep := drive(context.Background(), cfg, client)
	if cfg.JSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(rep)
	} else {
		printReport(stdout, rep)
	}
	if rep.RoundsOK != rep.Rounds {
		return 1
	}
	return 0
}

func parseFlags(args []string, stderr io.Writer) (config, error) {
	var c config
	fs := flag.NewFlagSet("mutate-load", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&c.Server, "server", "http://localhost:4000", "target base URL (loopback only unless --i-own-this-target)")
	fs.StringVar(&c.Token, "token", os.Getenv("BARKPARK_LOAD_TOKEN"), "bearer token (default $BARKPARK_LOAD_TOKEN)")
	fs.StringVar(&c.Workspace, "workspace", "default", "workspace slug")
	fs.StringVar(&c.Project, "project", "default", "project slug")
	fs.StringVar(&c.Dataset, "dataset", "production", "dataset")
	fs.IntVar(&c.Rounds, "rounds", 50, "total create(+publish) rounds")
	fs.IntVar(&c.Concurrency, "concurrency", 10, "rounds in flight at once")
	fs.IntVar(&c.DescBytes, "desc-bytes", 200, "description size in bytes (3400 = the 2026-07-31 calibration datum)")
	fs.BoolVar(&c.Publish, "publish", true, "send the publish leg after each create")
	fs.BoolVar(&c.DedupBypass, "dedup-bypass", false, "set dedup_bypass:true on the create (skips the publish dedup wall; use for seeding)")
	fs.StringVar(&c.TitlePrefix, "title-prefix", "load", "title prefix; each title also carries a run id and round number")
	fs.StringVar(&c.Tag, "tag", "loadtest", "weighted tag put on every row (the publish wall's label spine needs 1-12); empty = none")
	fs.BoolVar(&c.EnsureTag, "ensure-tag", true, "before the run, create+publish the type:tag doc for --tag (errors are reported, not fatal)")
	fs.DurationVar(&c.Timeout, "timeout", 30*time.Second, "per-request client budget (bp's dispatchClientTimeout is 30s)")
	fs.BoolVar(&c.OwnTarget, "i-own-this-target", false, "permit a non-loopback target; this files real rows there")
	fs.BoolVar(&c.JSON, "json", false, "print the report as JSON")
	fs.StringVar(&c.Label, "label", "", "free-text label echoed in the report (e.g. the commit measured)")
	if err := fs.Parse(args); err != nil {
		return c, err
	}
	if fs.NArg() > 0 {
		return c, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if c.Rounds < 1 || c.Concurrency < 1 || c.DescBytes < 0 {
		return c, errors.New("--rounds and --concurrency must be >= 1, --desc-bytes >= 0")
	}
	return c, nil
}

// checkTarget refuses any host that is not literally loopback. A name is NOT
// resolved: "my-box" pointing at 127.0.0.1 through /etc/hosts is still refused,
// because the check must not depend on the resolver of the machine it runs on.
func checkTarget(server string, own bool) error {
	u, err := url.Parse(server)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return fmt.Errorf("--server %q is not an http(s) URL", server)
	}
	if isLoopback(u.Hostname()) || own {
		return nil
	}
	return fmt.Errorf("target host %q is not loopback; this harness writes real task rows. Run it against a local instance, or pass --i-own-this-target for a box you alone own", u.Hostname())
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func seedOf(runID string) int64 {
	var n int64
	for _, c := range runID {
		n = n*31 + int64(c)
	}
	return n
}

func newRunID() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func drive(ctx context.Context, cfg config, client *http.Client) report {
	runID := newRunID()
	endpoint := endpointOf(cfg)

	jobs := make(chan int)
	var mu sync.Mutex
	var legs []legResult
	roundsOK := 0

	var wg sync.WaitGroup
	start := time.Now()
	for w := 0; w < cfg.Concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				rs, ok := oneRound(ctx, cfg, client, endpoint, runID, i)
				mu.Lock()
				legs = append(legs, rs...)
				if ok {
					roundsOK++
				}
				mu.Unlock()
			}
		}()
	}
	for i := 0; i < cfg.Rounds; i++ {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	wall := time.Since(start)

	return report{
		Label: cfg.Label, Server: cfg.Server, Rounds: cfg.Rounds, Concurrency: cfg.Concurrency,
		DescBytes: cfg.DescBytes, WallMs: ms(wall), RoundsOK: roundsOK, Legs: summarize(legs),
	}
}

// oneRound sends create then (if asked, and the create returned an id)
// publish. A round is OK only if every leg it was supposed to send is OK.
func oneRound(ctx context.Context, cfg config, client *http.Client, endpoint, runID string, i int) ([]legResult, bool) {
	base := newRunID() + newRunID()
	rnd := mrand.New(mrand.NewSource(int64(i) ^ seedOf(runID)))
	create := map[string]any{
		"_type":            "task",
		"kind":             "task",
		"lifecycle_status": "open",
		"title":            fmt.Sprintf("%s %s round %d", makeTitle(rnd, cfg.TitlePrefix), runID, i),
		"description":      makeDescription(rnd, cfg.DescBytes),
	}
	// The brief ensureTaskPortableBrief composes when none is given (no
	// criteria, so only the Purpose pair). The Tasks plugin halts a publish
	// without one (409 halted, "task brief is required before publish").
	create["brief"] = map[string]any{"version": 1, "blocks": []any{
		map[string]any{"id": "purpose", "type": "heading", "level": 2, "text": "Purpose"},
		map[string]any{"id": "purpose-copy", "type": "paragraph", "content": []any{map[string]any{"type": "text", "value": create["description"]}}},
	}}
	if cfg.Tag != "" {
		create["tags"] = []map[string]any{{"tag": cfg.Tag, "strength": 50, "rationale": "local mutate-load harness row"}}
	}
	if cfg.DedupBypass {
		create["dedup_bypass"] = true
	}
	cr, body := send(ctx, client, cfg.Token, endpoint, base+"-create", "create",
		[]map[string]any{{"create": create}})
	out := []legResult{cr}
	if cr.Class != "ok" {
		return out, false
	}
	id, ok := firstResultID(body)
	if !ok {
		out[0].Class = "no_id"
		return out, false
	}
	if !cfg.Publish {
		return out, true
	}
	bare := strings.TrimPrefix(id, "drafts.")
	pr, _ := send(ctx, client, cfg.Token, endpoint, base+"-publish", "publish",
		[]map[string]any{{"publish": map[string]any{"id": bare, "type": "task"}}})
	out = append(out, pr)
	return out, pr.Class == "ok"
}

// ensureTag registers --tag as a published type:tag doc (TagRegistry: a tag
// is registered iff a published tag doc whose id equals the tag exists). An
// existing tag makes the create 409; the publish of an already-published doc
// is harmless. Neither leg is counted in the report.
func ensureTag(ctx context.Context, cfg config, client *http.Client, stderr io.Writer) {
	ep := endpointOf(cfg)
	base := newRunID() + newRunID()
	c, _ := send(ctx, client, cfg.Token, ep, base+"-tag-create", "tag", []map[string]any{{"create": map[string]any{
		"_type": "tag", "_id": "drafts." + cfg.Tag, "title": cfg.Tag,
		"description": "Tag carried by rows the local mutate-load harness writes.",
	}}})
	p, _ := send(ctx, client, cfg.Token, ep, base+"-tag-publish", "tag", []map[string]any{{"publish": map[string]any{"id": cfg.Tag, "type": "tag"}}})
	fmt.Fprintf(stderr, "ensure-tag %s: create=%s publish=%s\n", cfg.Tag, c.Class, p.Class)
}

func endpointOf(cfg config) string {
	return strings.TrimRight(cfg.Server, "/") + "/w/" + url.PathEscape(cfg.Workspace) +
		"/p/" + url.PathEscape(cfg.Project) + "/v1/data/mutate/" + url.PathEscape(cfg.Dataset)
}

func send(ctx context.Context, client *http.Client, token, endpoint, key, leg string, mutations []map[string]any) (legResult, []byte) {
	payload, _ := json.Marshal(map[string]any{"mutations": mutations})
	req, err := http.NewRequestWithContext(ctx, "POST", endpoint, strings.NewReader(string(payload)))
	if err != nil {
		return legResult{Leg: leg, Class: "transport:build"}, nil
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", key)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	var conns atomic.Int32
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
		GotConn: func(httptrace.GotConnInfo) { conns.Add(1) },
	}))
	resends := func() int {
		if n := int(conns.Load()); n > 1 {
			return n - 1
		}
		return 0
	}
	t0 := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return legResult{Leg: leg, Class: "transport:" + transportKind(err), Latency: time.Since(t0), Resends: resends()}, nil
	}
	body, rerr := io.ReadAll(resp.Body)
	resp.Body.Close()
	lat := time.Since(t0)
	if rerr != nil {
		return legResult{Leg: leg, Class: "transport:" + transportKind(rerr), Status: resp.StatusCode, Latency: lat}, nil
	}
	r := legResult{Leg: leg, Status: resp.StatusCode, Latency: lat, Resends: resends()}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		r.Class = "ok"
	} else {
		r.Class = fmt.Sprintf("http_%d:%s", resp.StatusCode, errorCode(body))
	}
	return r, body
}

func transportKind(err error) string {
	var ne net.Error
	switch {
	case errors.As(err, &ne) && ne.Timeout():
		return "timeout"
	case strings.Contains(err.Error(), "connection refused"):
		return "refused"
	case errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || strings.Contains(err.Error(), "EOF"):
		return "eof"
	case strings.Contains(err.Error(), "connection reset"):
		return "reset"
	default:
		return "other"
	}
}

// errorCode reads error.code from the mutate error envelope; "-" when the
// body is not that envelope (an HTML 500 page, an empty body).
func errorCode(body []byte) string {
	var env struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Error) == 0 {
		return "-"
	}
	var obj struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(env.Error, &obj) == nil && obj.Code != "" {
		return obj.Code
	}
	return "-"
}

func firstResultID(body []byte) (string, bool) {
	var out struct {
		Results []struct {
			ID string `json:"id"`
		} `json:"results"`
	}
	if json.Unmarshal(body, &out) != nil || len(out.Results) == 0 || out.Results[0].ID == "" {
		return "", false
	}
	return out.Results[0].ID, true
}

// pseudoWord is a random 3-syllable consonant-vowel word. Titles and
// descriptions are built from these so no two rounds share trigrams by more
// than chance: the server's birth dedup refuses near-identical titles
// (409 duplicate_task), and a load run that 409s measures the refusal, not the
// write path.
func pseudoWord(rnd *mrand.Rand) string {
	const cons, vows = "bdfgklmnprstvz", "aeiou"
	b := make([]byte, 0, 6)
	for i := 0; i < 3; i++ {
		b = append(b, cons[rnd.Intn(len(cons))], vows[rnd.Intn(len(vows))])
	}
	return string(b)
}

func makeTitle(rnd *mrand.Rand, prefix string) string {
	w := make([]string, 5)
	for i := range w {
		w[i] = pseudoWord(rnd)
	}
	return prefix + " " + strings.Join(w, " ")
}

// makeDescription builds exactly n bytes of pseudo-prose (the 2026-07-31
// calibration datum is n≈3400). The label spine needs >= 20 characters to
// publish, so n < 20 is a deliberate label_spine probe.
func makeDescription(rnd *mrand.Rand, n int) string {
	var b strings.Builder
	for b.Len() < n {
		if b.Len() > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(pseudoWord(rnd))
	}
	return b.String()[:n]
}

func summarize(rs []legResult) map[string]*legStats {
	by := map[string][]legResult{}
	for _, r := range rs {
		by[r.Leg] = append(by[r.Leg], r)
	}
	out := map[string]*legStats{}
	for leg, list := range by {
		s := &legStats{Count: len(list), Classes: map[string]int{}}
		lats := make([]time.Duration, 0, len(list))
		for _, r := range list {
			s.Classes[r.Class]++
			s.Resends += r.Resends
			if r.Class == "ok" {
				s.OK++
			}
			lats = append(lats, r.Latency)
		}
		sort.Slice(lats, func(a, b int) bool { return lats[a] < lats[b] })
		s.P50ms, s.P95ms, s.P99ms = ms(pct(lats, 50)), ms(pct(lats, 95)), ms(pct(lats, 99))
		s.MaxMs = ms(lats[len(lats)-1])
		out[leg] = s
	}
	return out
}

// pct is nearest-rank over ALL requests of a leg, failed ones included: a 500
// that took 5s is part of what the caller waited for.
func pct(sorted []time.Duration, p int) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	rank := (p*len(sorted) + 99) / 100
	if rank < 1 {
		rank = 1
	}
	return sorted[rank-1]
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func printReport(w io.Writer, r report) {
	if r.Label != "" {
		fmt.Fprintf(w, "label: %s\n", r.Label)
	}
	fmt.Fprintf(w, "target: %s  rounds: %d  concurrency: %d  desc_bytes: %d  wall: %.0fms\n",
		r.Server, r.Rounds, r.Concurrency, r.DescBytes, r.WallMs)
	legs := make([]string, 0, len(r.Legs))
	for l := range r.Legs {
		legs = append(legs, l)
	}
	sort.Strings(legs)
	for _, l := range legs {
		s := r.Legs[l]
		fmt.Fprintf(w, "leg %-8s n=%d ok=%d p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms transport_resends=%d\n",
			l, s.Count, s.OK, s.P50ms, s.P95ms, s.P99ms, s.MaxMs, s.Resends)
		classes := make([]string, 0, len(s.Classes))
		for c := range s.Classes {
			classes = append(classes, c)
		}
		sort.Strings(classes)
		for _, c := range classes {
			fmt.Fprintf(w, "  class %-40s %d\n", c, s.Classes[c])
		}
	}
	fmt.Fprintf(w, "SUMMARY rounds_ok=%d/%d failed=%d\n", r.RoundsOK, r.Rounds, r.Rounds-r.RoundsOK)
}
