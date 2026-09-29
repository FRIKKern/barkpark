package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// TLS-mode reconciliation — the LIVE-SITE half of the CP→box TLS channel.
//
// ## The gap this closes
//
// cf-agent-sites-tls-channel put `serving_mode` on the agent claim/pending
// site inline, and executeDeploy derives the rendered TLS block from it via
// tlsModeForServing. That channel only ever speaks about ONE site: the
// deployment being claimed. Every OTHER live site's TLS mode comes from
// StateFromDisk, which re-parses the on-box Caddyfile — the box never asks the
// control plane what a live site's serving_mode is.
//
// So a site that flips to cf_proxied while it is already live keeps its
// rendered `tls { on_demand }` block until somebody deploys it again. Between
// the flip and that deploy Caddy still runs on-demand ACME behind the
// Cloudflare proxy, whose challenge cannot complete — a live error 526. The
// reverse is the same defect pointed the other way: a cf_proxied → direct flip
// leaves `tls internal` in place over a hostname that now resolves straight to
// the box, so every visitor gets a self-signed cert.
//
// ## The invariant
//
// After a serving_mode flip on the control plane, in either direction, the
// box's rendered TLS block for that site matches the new mode WITHOUT an
// operator-initiated deploy, within one poll interval (Executor.Interval,
// DefaultInterval = 5s) plus one control-plane round trip. The mechanism is a
// state fetch on the idle path of the claim loop: every cycle that claims no
// deployment asks GET /v1/agent/sites for this box's sites and their current
// serving_mode, compares each against what the Caddyfile actually renders, and
// rewrites + reloads only when they differ.
//
// ## Why the idle path, and why a fetch rather than a control-plane trigger
//
//   - The claim loop already polls the control plane on this cadence, so the
//     bound is the cadence the box is already paying for and no new timer,
//     backoff, or scheduler enters the executor.
//   - A control-plane trigger (a no-op deployment, or a new `rerender` claim
//     kind) would make the invariant depend on an enqueue that can be lost:
//     a flip written while the box is down, or a row swept by a queue cleanup,
//     leaves the box stale forever with nothing to detect it. A fetch is
//     level-triggered — it re-derives the truth every cycle, so a missed cycle
//     costs latency, never correctness.
//   - It needs no migration and no new queue semantics on the CP.
//
// ## What it will NOT touch
//
//   - Any block that is not a runtime-managed live site — foreign vhosts, the
//     Studio block, provisioner attach-domain blocks. Reconciliation maps over
//     state.LiveSites only, and writeCaddyfile's Rewrite preserves the rest.
//   - A site the control plane does not list (slug absent from the response).
//   - A TLSModeOriginCA block. `serving_mode` is a two-value vocabulary
//     (direct | cf_proxied) and cannot express Origin CA — a cf_proxied site
//     serving CF Full-Strict from on-box cert files is CORRECT, and treating
//     it as drift would downgrade it to self-signed on the next idle cycle.
//     Reconciliation moves a block only between on-demand and internal.

// agentSitesPath is the box's site-state fetch: this barkpark's sites and the
// control plane's CURRENT serving_mode for each.
const agentSitesPath = "/v1/agent/sites"

// agentSite is one entry of the GET /v1/agent/sites response — the shape the
// box consumes to reconcile TLS modes. It is deliberately the same vocabulary
// as InlineSite.ServingMode, not a second one.
type agentSite struct {
	Slug        string   `json:"slug"`
	Domains     []string `json:"domains"`
	ServingMode string   `json:"serving_mode"`
}

// reconcileTLSModes performs one reconciliation pass. It reports whether the
// Caddyfile was rewritten (and Caddy reloaded).
//
// Errors are returned, never fatal to the caller's cycle: a control plane that
// does not serve /v1/agent/sites (404) is not an error at all — it is an older
// control plane, and the box simply keeps today's behaviour.
func (e *Executor) reconcileTLSModes(ctx context.Context, state State) (bool, error) {
	if len(state.LiveSites) == 0 {
		return false, nil
	}

	sites, ok, err := e.fetchAgentSites(ctx)
	if err != nil {
		return false, err
	}
	if !ok {
		return false, nil
	}

	modeBySlug := make(map[string]string, len(sites))
	for _, s := range sites {
		if s.Slug == "" {
			continue
		}
		modeBySlug[s.Slug] = s.ServingMode
	}

	desired, drifted := reconciledSites(state.LiveSites, modeBySlug)
	if len(drifted) == 0 {
		return false, nil
	}

	if err := e.writeCaddyfile(desired); err != nil {
		return false, fmt.Errorf("tls reconcile write caddyfile: %w", err)
	}
	if err := e.reloadCaddy(ctx); err != nil {
		return false, fmt.Errorf("tls reconcile reload caddy: %w", err)
	}

	e.logf("tls reconcile: rewrote %d site(s) after a serving_mode flip: %s",
		len(drifted), strings.Join(drifted, ", "))
	return true, nil
}

// reconciledSites returns live with every drifted site's TLSMode corrected to
// the control plane's current serving_mode, plus the slugs that moved. A site
// the control plane does not list, and any site rendering Origin CA, is copied
// through untouched (see the package note above).
//
// Pure and total: the caller can diff its output against its input without
// running a subprocess, which is what makes the drift decision unit-testable
// against what is WRITTEN rather than against a call count.
func reconciledSites(live []caddyfile.Site, modeBySlug map[string]string) ([]caddyfile.Site, []string) {
	out := make([]caddyfile.Site, len(live))
	copy(out, live)

	var drifted []string
	for i, s := range out {
		mode, listed := modeBySlug[s.Slug]
		if !listed {
			continue
		}
		if s.TLSMode == caddyfile.TLSModeOriginCA {
			continue
		}
		want := tlsModeForServing(mode)
		if normalizedTLSMode(s.TLSMode) == want {
			continue
		}
		out[i].TLSMode = want
		drifted = append(drifted, s.Slug)
	}
	return out, drifted
}

// normalizedTLSMode maps a parsed block's TLS mode onto the vocabulary
// tlsModeForServing produces, so the empty string (a block with no `tls` line,
// which Caddy serves on demand) compares equal to an explicit on_demand and
// never reads as drift.
func normalizedTLSMode(mode string) string {
	if mode == caddyfile.TLSModeInternal {
		return caddyfile.TLSModeInternal
	}
	return caddyfile.TLSModeOnDemand
}

// fetchAgentSites GETs /v1/agent/sites. Returns (sites, true, nil) on 200,
// (nil, false, nil) on 404 — a control plane without this surface, where the
// box must keep its current Caddyfile rather than guess an empty site list —
// and (nil, false, err) on anything else.
func (e *Executor) fetchAgentSites(ctx context.Context) ([]agentSite, bool, error) {
	url := strings.TrimRight(e.ControlURL, "/") + agentSitesPath
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, false, err
	}
	e.attachAuth(req)

	resp, err := e.http().Do(req)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var out struct {
			Sites []agentSite `json:"sites"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil, false, fmt.Errorf("decode agent sites: %w", err)
		}
		return out.Sites, true, nil

	case http.StatusNotFound:
		return nil, false, nil

	default:
		return nil, false, statusError(resp)
	}
}
