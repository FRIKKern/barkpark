package cli

// doctor_onboarding.go — `bp doctor --onboarding`, the D3 north-star client
// readiness RECEIPT. Plain `bp doctor` (doctor_cmd.go) answers "is the REMOTE
// server healthy" (setup.RunHealthGate, 7 server-side checks). This sibling
// answers the other, missing half the onboarding audit surfaced: "is THIS
// machine — this shell, this bp, this MCP wiring — actually ready to drive a
// Barkpark?". It composes primitives that already live on main into ONE
// trustworthy receipt an agent or a human can read top-to-bottom, in a fixed
// order, and it NEVER prints a bearer token (presence only, like `gh auth
// status`).
//
// The receipt, in order (BP-ONB audit shape):
//
//	(a) PATH        — exec.LookPath("bp"): is bp resolvable in THIS process? The
//	                  client half of BP-ONB-10 (the installer PATH postcondition).
//	(b) CLI         — installed cliVersion vs the newest cli-v* release
//	                  (latestReleaseVersion, the same resolver `bp upgrade` uses).
//	(c) CLOUD       — is a Cloud control-plane session present? url + team, never
//	                  the token.
//	(d) INSTANCE    — the target Barkpark's identity, LOCAL-FIRST: the stamped
//	                  ServerEntry.InstanceID/Aliases/Team from the saved config
//	                  (no network). Only when no stamped id exists does it reach
//	                  for the cross-team fleet (ListAllBarkparks carries id + team
//	                  per row) to name a legacy / not-yet-connected target.
//	(e) AUTH        — the manifest fetch: reachable + auth_tier for the target.
//	(f) MCP         — the curated 8-tool task catalog (registerTaskTools): names
//	                  + count, so a client knows what it will get.
//	(g) TOOL CALL   — a READ-ONLY proof: it actually invokes task_ready through
//	                  the SAME dispatch seam the MCP tool uses (execManifestCommand)
//	                  and surfaces the result — not a stub.
//	(h) RELOAD      — the exact client-reload instruction (restart Cursor / Claude
//	                  Desktop / Codex so the MCP child re-reads PATH).
//
// The seams below (onboardingLookBP / onboardingLatestRelease /
// onboardingLoadManifest / onboardingListFleet) are package vars, matching the
// house idiom (doctorGateOpts, upgradeExecutable, cloudCtx): the test swaps them
// to drive the whole receipt against fakes + one httptest server with no live
// deployment, and the command itself never knows it was swapped.

import (
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/FRIKKern/barkpark/internal/manifest"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// mcpTaskToolNames is the curated MCP task-tool catalog, in registration order
// (registerTaskTools, mcp_tasks.go — the @canonical mcp-task-tools owner). The
// receipt reports this so a client sees exactly which tools it will get before it
// connects. doctor_onboarding_test cross-checks this list against the LIVE
// registration (a real in-memory MCP server) so the two can never drift.
var mcpTaskToolNames = []string{
	"task_ready", "task_next", "task_show", "task_close",
	"task_create", "task_prime", "task_stamp", "task_pulse",
}

// onboardingReloadInstruction is step (h): after PATH is fixed / bp is upgraded,
// a running MCP client keeps the OLD bp child until it is restarted. This is the
// exact remedy, named for the three clients the audit covered.
const onboardingReloadInstruction = "Restart your MCP client (Cursor / Claude Desktop / Codex) so it re-spawns its `bp` child process and re-reads PATH — a running client keeps the bp it launched with."

// Test seams (package vars, swapped by doctor_onboarding_test). Defaults are the
// real resolvers already on main.
var (
	onboardingLookBP        = func() (string, error) { return exec.LookPath("bp") }
	onboardingLatestRelease = func() (string, error) { return latestReleaseVersion(releaseRepoBase()) }
	onboardingLoadManifest  = loadManifest
	onboardingListFleet     = func(cfg *Config) ([]cloudclient.Barkpark, error) {
		return cfg.CloudClient().ListAllBarkparks(cloudCtx())
	}
)

// onboardingReceipt is the D3 north-star client-readiness receipt. Field order is
// the render order; JSON key order follows the struct declaration.
type onboardingReceipt struct {
	OK           bool            `json:"ok"`
	Path         onbPathCheck    `json:"path"`
	CLI          onbCLICheck     `json:"cli"`
	CloudSession onbCloudSession `json:"cloud_session"`
	Instance     *onbInstance    `json:"instance"`
	Auth         onbAuthCheck    `json:"auth"`
	MCP          onbMCPCatalog   `json:"mcp"`
	ToolCall     onbToolCall     `json:"tool_call"`
	Reload       string          `json:"reload_instruction"`
}

type onbPathCheck struct {
	Resolved bool   `json:"resolved"`
	Path     string `json:"path"`
	Detail   string `json:"detail"`
}

// The CLI-freshness leg is a TRI-state, not a boolean. "up-to-date" and "behind"
// are READINGS — they require a resolved release to compare against. Everything
// else (a dev build, an unreachable release feed) is an ABSENCE of reading, and
// this receipt refuses to launder an absence into either verdict: reporting
// up-to-date would be a green nobody earned, reporting behind would be a false
// alarm. Both are forbidden; "unreported" is the honest third answer.
const (
	onbCLIUpToDate   = "up-to-date"
	onbCLIBehind     = "behind"
	onbCLIUnreported = "unreported"
)

// onbCLIDevRemedy is the ONE command that refreshes a dev build. A dev binary
// cannot be compared against the cli-v* channel at all (and `bp upgrade` refuses
// on that same ground), so the only move that makes it current is rebuilding it
// from the tree it was built from.
const onbCLIDevRemedy = "git pull && make cli-install"

type onbCLICheck struct {
	Installed string `json:"installed"`
	Latest    string `json:"latest"`
	// Status is the tri-state verdict: onbCLIUpToDate / onbCLIBehind /
	// onbCLIUnreported. It is the authoritative field — read this, not the bool.
	Status string `json:"status"`
	// UpToDate is the boolean PROJECTION of Status, kept for readers written
	// against the original shape. It is a POINTER on purpose: an unreported leg
	// serialises as `"up_to_date": null`, so a bool-only reader gets an explicit
	// "no reading" instead of a fabricated true.
	UpToDate *bool  `json:"up_to_date"`
	Detail   string `json:"detail"`
}

// onbBool boxes a boolean for onbCLICheck.UpToDate (nil = no reading taken).
func onbBool(b bool) *bool { return &b }

type onbCloudSession struct {
	Present bool   `json:"present"`
	URL     string `json:"url"`
	Team    string `json:"team"`
}

type onbInstance struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Team    string   `json:"team"`
	URL     string   `json:"url"`
	Aliases []string `json:"aliases"`
	Source  string   `json:"source"`
	// AliasShadow is the compare-only fleet-reconcile advisory (D39). It is set
	// ONLY on the doctor receipt's local-first path (onboardingInstance), and ONLY
	// when the fleet row matching this box's stamped InstanceID carries a canonical
	// target the local alias set does not know — a rename the additive-only alias
	// store (mergeAliases, config.go) can never self-heal. It names the remedy
	// (`bp connect <newURL>`). Empty on every other path: fail-open (no token /
	// fleet error / no matching row), and always empty on whoami's network-free
	// localInstance — so `omitempty` keeps those receipts byte-identical. This
	// field is advisory ONLY; nothing here mutates config.
	AliasShadow string `json:"alias_shadow,omitempty"`
}

type onbAuthCheck struct {
	Reachable bool   `json:"reachable"`
	Tier      string `json:"tier"`
	Server    string `json:"server"`

	// TokenSource names WHICH credential produced that tier — the same label
	// `bp whoami -o json` publishes (flag | env:<NAME> | repo-file | saved |
	// default | none), from the same resolver. A receipt that reports "auth_tier
	// none" without saying which credential earned it cannot distinguish "you
	// are not logged in" from "a stale env var buried the login you have".
	TokenSource string `json:"token_source"`
	// TokenShadow is the one-line env-shadows-config finding, present ONLY when
	// an env token is standing in front of a different saved credential for this
	// same server. Advisory; it never changes the receipt's ok.
	TokenShadow string `json:"token_shadow,omitempty"`
}

type onbMCPCatalog struct {
	// Version is the MCP tool-catalog version. Per D12 there is no separately
	// versioned catalog — the 8-tool set ships in lockstep with the bp binary —
	// so this is cliVersion, the SAME value mcp_serve.go stamps as the served
	// server's Implementation.Version. A client reads it to know which catalog a
	// given bp exposes before it spawns the MCP child.
	Version string   `json:"version"`
	Count   int      `json:"count"`
	Tools   []string `json:"tools"`
}

type onbToolCall struct {
	Tool    string `json:"tool"`
	OK      bool   `json:"ok"`
	Status  int    `json:"status"`
	Summary string `json:"summary"`
}

// doctorOnboardingRequested reports whether the doctor args select the
// onboarding-receipt mode (`--onboarding` / its `--client` alias).
func doctorOnboardingRequested(args []string) bool {
	for _, a := range args {
		if a == "--onboarding" || a == "--client" {
			return true
		}
	}
	return false
}

// runDoctorOnboarding is `bp doctor --onboarding`. It builds the receipt against
// the resolved content target (ctx) + Cloud config and renders it (human, or a
// single machine document under -o json|yaml). Exit 0 when the CORE is ready
// (bp on PATH, target reachable, the read-only tool call succeeded), else
// exitGeneric — so a script can gate on it. CLI freshness and Cloud session are
// advisory (a self-hosted user legitimately has no Cloud session), so they inform
// the receipt without sinking the exit code.
func runDoctorOnboarding(out *writer, g globals, ctx manifest.Context, args []string, prov tokenProvenance) int {
	// The global flag parser strips -h/--help into g.help before dispatch, so
	// honour it here (its own arg scan below still catches a literal that slipped
	// through) — `bp doctor --onboarding --help` shows THIS help, not the receipt.
	if g.help {
		printOnboardingDoctorHelp(out)
		return exitOK
	}
	for _, a := range args {
		switch a {
		case "--onboarding", "--client":
			// the mode selector — consumed here
		case "-h", "--help":
			printOnboardingDoctorHelp(out)
			return exitOK
		default:
			return useError(out, "usage", "unexpected argument "+quote(a)+" (usage: bp doctor --onboarding)", exitUsage)
		}
	}

	r := buildOnboardingReceipt(g, ctx, prov)

	switch out.output {
	case "json":
		out.renderJSON(r)
	case "yaml":
		out.renderYAML(toGeneric(onboardingPayload(r)))
	default:
		renderOnboardingReceipt(out, r)
	}

	if r.OK {
		return exitOK
	}
	return exitGeneric
}

// buildOnboardingReceipt assembles the receipt from the live primitives (or the
// swapped test seams). It loads the manifest ONCE and reuses it for both the auth
// tier (e) and the read-only tool-call proof (g), so a single reachable target is
// probed once.
func buildOnboardingReceipt(g globals, ctx manifest.Context, prov tokenProvenance) onboardingReceipt {
	cfg, _ := LoadConfig()

	var m *manifest.Manifest
	if onboardingLoadManifest != nil {
		m, _ = onboardingLoadManifest(g, ctx)
	}

	r := onboardingReceipt{
		Path:         onboardingPathCheck(),
		CLI:          onboardingCLIFreshness(),
		CloudSession: onboardingCloudSession(cfg),
		Instance:     onboardingInstance(cfg, ctx),
		Auth:         onboardingAuth(m, ctx, prov),
		MCP:          onbMCPCatalog{Version: cliVersion, Count: len(mcpTaskToolNames), Tools: append([]string(nil), mcpTaskToolNames...)},
		ToolCall:     onboardingToolCallProof(g, ctx, m),
		Reload:       onboardingReloadInstruction,
	}
	// The core readiness gate: bp is drivable, the target answers, and a real
	// read-only tool call round-tripped. Freshness/Cloud are advisory.
	//
	// WHAT AN UNREPORTED LEG DOES TO `ok` (decided, not defaulted): nothing. An
	// unknown is not a failure — flipping ok:false on a dev build would fire an
	// alarm on the most common developer setup, and a receipt that cries wolf gets
	// ignored, which is the failure mode this whole check exists to prevent. The
	// leg stays advisory (as it always was) but it is now VISIBLY unreported in
	// both renders — Status "unreported", `up_to_date: null`, a "?" mark, and a
	// named caveat on the READY line — so nobody can read a green receipt as
	// "freshness verified". Silence about a leg is the sin; ok:false is a
	// different, equally dishonest one.
	r.OK = r.Path.Resolved && r.Auth.Reachable && r.ToolCall.OK
	return r
}

// onboardingWhoamiSpine is the D10 reconciliation seam: the receipt TAIL that
// `bp whoami -o json` carries and `bp doctor --onboarding` composes over, so the
// two never fork into a second receipt shape. It returns exactly the additive
// keys whoami merges into its payload — instance identity, the MCP tool catalog
// (version + names, D12), the read-only tool-call proof, and the client-reload
// instruction — assembled from the SAME helpers the doctor receipt uses
// (localInstance / mcpTaskToolNames / onboardingToolCallProof /
// onboardingReloadInstruction). It reuses the manifest whoami already fetched
// (never a second probe) and is LOCAL-FIRST: instance identity is read from the
// saved config, and the tool-call proof only leaves the process when the target
// is reachable (m != nil) — so whoami stays a config report that always exits 0,
// never a connectivity gate.
func onboardingWhoamiSpine(g globals, ctx manifest.Context, cfg *Config, m *manifest.Manifest) map[string]any {
	return map[string]any{
		"instance": localInstance(cfg, ctx),
		"cli":      whoamiCLIFreshness(),
		"mcp": map[string]any{
			"version": cliVersion,
			"count":   len(mcpTaskToolNames),
			"tools":   append([]string(nil), mcpTaskToolNames...),
		},
		"tool_call":          onboardingToolCallProof(g, ctx, m),
		"reload_instruction": onboardingReloadInstruction,
	}
}

// whoamiCLIFreshness is the whoami half of the CLI-freshness leg (charter D28):
// the SAME tri-state verdict the doctor receipt renders (onboardingCLIFreshness),
// but resolved ONLY from the on-disk release cache — it NEVER makes an HTTP call,
// so whoami keeps its local-first, always-exit-0 contract on the always-run hot
// path. The split of labour is deliberate: the doctor (already network-bearing)
// pays for the resolve and refreshes the cache; whoami reads it for free.
//
// The tri-state stays honest end to end:
//   - a dev build short-circuits to UNREPORTED — it cannot be compared against
//     the cli-v* channel at all, exactly as the doctor leg and `bp upgrade` hold;
//   - a cold or stale cache (never refreshed, or older than the TTL) is honest
//     UNREPORTED that names the ONE command which refreshes it: `bp doctor`;
//   - only a FRESH cache yields a reading — up-to-date or behind — and even then
//     it is transparently marked as cache-sourced.
//
// It never launders an absence into a green (up-to-date) or a false alarm
// (behind): an unknown is reported as unknown.
func whoamiCLIFreshness() onbCLICheck {
	c := onbCLICheck{Installed: cliVersion, Status: onbCLIUnreported}
	if cliVersion == "dev" {
		c.Detail = "running a dev build (go build) — there is no release to compare it against, so freshness is UNREPORTED; refresh it with `" + onbCLIDevRemedy + "`"
		return c
	}
	cache, fresh := readReleaseCache()
	if !fresh {
		c.Detail = "freshness UNREPORTED — no fresh release reading cached; run `bp doctor --onboarding` to refresh it"
		return c
	}
	c.Latest = cache.Latest
	if compareVersions(cliVersion, cache.Latest) < 0 {
		c.Status = onbCLIBehind
		c.UpToDate = onbBool(false)
		c.Detail = "a newer CLI is available (cached — run `bp doctor --onboarding` to re-check) — run `bp upgrade`"
		return c
	}
	c.Status = onbCLIUpToDate
	c.UpToDate = onbBool(true)
	c.Detail = "up to date (cached — run `bp doctor --onboarding` to re-check)"
	return c
}

// localInstance is whoami's NETWORK-FREE instance identity: the active saved
// target, read from local config only (no cross-team fleet fetch — that stays in
// the doctor receipt, which is a rarely-run diagnostic). It reports the resolved
// URL, the saved entry's display name, and the instance identity the connect path
// stamped on the ServerEntry (BP-ONB-05): the stable InstanceID and any host
// aliases the same instance answers on. Team prefers the entry's owning-team name
// (identity, stamped at connect) and falls back to the active Cloud-session team
// (cfg.CloudTeam) when the entry carries none. Returns nil only when there is no
// active target at all.
func localInstance(cfg *Config, ctx manifest.Context) *onbInstance {
	active := strings.TrimRight(strings.TrimSpace(ctx.Server), "/")
	if active == "" {
		return nil
	}
	inst := &onbInstance{URL: active, Source: "local"}
	if cfg != nil {
		if e, ok := cfg.FindServer(ctx.Server); ok {
			inst.Name = cfg.DisplayName(e)
			inst.ID = strings.TrimSpace(e.InstanceID)
			if len(e.Aliases) > 0 {
				inst.Aliases = append([]string(nil), e.Aliases...)
			}
			inst.Team = strings.TrimSpace(e.Team)
		}
		if inst.Team == "" {
			inst.Team = strings.TrimSpace(cfg.CloudTeam)
		}
	}
	return inst
}

// onboardingPathCheck is (a): can THIS process resolve `bp` on PATH? If not, the
// installer's PATH step didn't take in this shell — the client half of BP-ONB-10.
func onboardingPathCheck() onbPathCheck {
	p, err := onboardingLookBP()
	if err != nil || strings.TrimSpace(p) == "" {
		return onbPathCheck{
			Resolved: false,
			Detail:   "`bp` is not resolvable on PATH in this process — open a new shell, or re-run the installer, so PATH picks up bp",
		}
	}
	return onbPathCheck{Resolved: true, Path: p, Detail: "resolved on PATH"}
}

// onboardingCLIFreshness is (b): installed version vs the newest cli-v* release.
// A dev build is not "stale" — but it is not FRESH either: it cannot be compared,
// so it reports onbCLIUnreported and names the one command that fixes it. The
// same applies when the release feed cannot be resolved: no feed, no reading.
func onboardingCLIFreshness() onbCLICheck {
	c := onbCLICheck{Installed: cliVersion, Status: onbCLIUnreported}
	if cliVersion == "dev" {
		c.Detail = "running a dev build (go build) — there is no release to compare it against, so freshness is UNREPORTED; refresh it with `" + onbCLIDevRemedy + "`"
		return c
	}
	latest, err := onboardingLatestRelease()
	if err != nil {
		c.Detail = "freshness UNREPORTED — could not resolve the latest release: " + err.Error()
		return c
	}
	// Refresh the on-disk cache whoami reads. This is `bp doctor --onboarding`,
	// one of several network-bearing surfaces that keep the cache warm — bp
	// upgrade (runUpgrade) and the update-notice background resolve write it too;
	// only plain `bp doctor` (doctor_cmd.go) stays offline and refreshes nothing.
	// Best-effort: a cache-write failure never sinks the receipt's own live
	// reading below.
	_ = writeReleaseCache(latest)
	c.Latest = latest
	if compareVersions(cliVersion, latest) < 0 {
		c.Status = onbCLIBehind
		c.UpToDate = onbBool(false)
		c.Detail = "a newer CLI is available — run `bp upgrade`"
		return c
	}
	c.Status = onbCLIUpToDate
	c.UpToDate = onbBool(true)
	c.Detail = "up to date"
	return c
}

// onboardingCloudSession is (c): is a Cloud control-plane session present? url +
// team ONLY — never the token value (presence, like `gh auth status`).
func onboardingCloudSession(cfg *Config) onbCloudSession {
	s := onbCloudSession{}
	if cfg != nil && cfg.HasCloudToken() {
		s.Present = true
		s.URL = strings.TrimSpace(cfg.CloudURL)
		if s.URL == "" {
			s.URL = cloudclient.DefaultBaseURL
		}
		s.Team = cfg.CloudTeam
	}
	return s
}

// onboardingInstance is (d): the target Barkpark's identity, resolved LOCAL-FIRST
// with a fleet MERGE fallback. When the active target's saved ServerEntry carries
// the InstanceID the connect path stamped (BP-ONB-05, wave-2 slice-1), we return
// that local identity (Source "local") WITHOUT a cross-team fleet round-trip — the
// offline/first-time win, and the common case once a target is connected. Only
// when the stamped InstanceID is ABSENT (a legacy or not-yet-connected target) do
// we reach for the authoritative cross-team fleet (ListAllBarkparks carries id +
// team per row), matching the active content target against it. Failing both, we
// fall back to whatever local identity we have (url + name, id-less). Returns nil
// only when there is no active target at all.
func onboardingInstance(cfg *Config, ctx manifest.Context) *onbInstance {
	active := strings.TrimRight(strings.TrimSpace(ctx.Server), "/")

	// Local-first: a stamped InstanceID means we already know this box's identity
	// from the saved config — no fleet fetch, no network. This is the offline win.
	// The identity ALWAYS resolves locally here; the only thing that can leave the
	// process is the compare-only alias-shadow advisory below, and only under a
	// Cloud token. Fail-open throughout: no token / fleet error / no matching row
	// leave the receipt byte-identical.
	local := localInstance(cfg, ctx)
	if local != nil && local.ID != "" {
		local.AliasShadow = onboardingAliasShadowAdvisory(cfg, local)
		return local
	}

	// Fleet fallback: only when no stamped identity exists (legacy / pre-connect
	// targets). The fleet is authoritative for id + team when it can be reached.
	if cfg != nil && cfg.HasCloudToken() && onboardingListFleet != nil {
		if fleet, err := onboardingListFleet(cfg); err == nil {
			for _, b := range fleet {
				if fleetMatchesActive(b, active) {
					return fleetInstance(b)
				}
			}
		}
	}

	// Neither a stamped id nor a fleet match: report the id-less local identity
	// (url + saved name). localInstance covers every active!=\"\" case, so this is
	// the last honest report before nil (which only happens when active is empty).
	return local
}

// onboardingAliasShadowAdvisory is the D39 compare-only fleet reconcile: it
// answers "has the fleet renamed this box's canonical target out from under a
// stale local alias set?" WITHOUT ever mutating config. The alias store is
// additive-only by construction (mergeAliases, config.go — the sole persist
// writer, no prune path), so a canonical rename can never self-heal locally: the
// dead hostname prints as truth forever. This advisory makes that recoverable by
// naming the remedy (`bp connect <newURL>`, the existing ADDITIVE fold-in).
//
// It runs ONLY on the local-first path (a stamped InstanceID is present) and is
// TOKEN-GATED (same gate as the fleet fallback). It matches the fleet row by
// Barkpark.ID EQUALITY against the stamped InstanceID — NEVER by URL, because a
// URL match cannot detect the very rename this exists to catch. FAIL-OPEN: no
// token, a fleet error, or no matching row all return "" (silent, receipt
// unchanged); the identity itself always came from local config regardless.
func onboardingAliasShadowAdvisory(cfg *Config, local *onbInstance) string {
	if cfg == nil || local == nil || local.ID == "" || !cfg.HasCloudToken() || onboardingListFleet == nil {
		return ""
	}
	fleet, err := onboardingListFleet(cfg)
	if err != nil {
		return "" // fail-open: a fleet error never sinks the receipt
	}
	for _, b := range fleet {
		if strings.TrimSpace(b.ID) != local.ID {
			continue // ID EQUALITY — never a URL match
		}
		target := fleetTarget(b.URL, b.Host)
		if target == "" {
			return ""
		}
		// Does any local URL/alias already address this canonical target? Reuse the
		// fleetMatchesActive normalization (scheme-normalized URL + host forms).
		for _, known := range append([]string{local.URL}, local.Aliases...) {
			if fleetMatchesActive(b, strings.TrimRight(strings.TrimSpace(known), "/")) {
				return "" // the canonical target is already a known alias — no shadow
			}
		}
		return "fleet canonical target is now " + target + ", absent from local aliases — run `bp connect " + target + "` to fold it in"
	}
	return "" // no fleet row carries this InstanceID — fail-open, silent
}

// fleetMatchesActive reports whether a fleet row addresses the same box as the
// active content target, comparing scheme-normalized URL and host forms.
func fleetMatchesActive(b cloudclient.Barkpark, active string) bool {
	if active == "" {
		return false
	}
	for _, cand := range []string{b.URL, fleetTarget(b.URL, b.Host)} {
		if cand == "" {
			continue
		}
		if strings.TrimRight(strings.TrimSpace(cand), "/") == active {
			return true
		}
	}
	// Also compare the bare host of the active URL against the row host.
	if host := strings.TrimSpace(b.Host); host != "" {
		if strings.Contains(active, host) {
			return true
		}
	}
	return false
}

// fleetInstance projects a fleet row onto the receipt's instance block, deriving
// host aliases from the canonical URL + host (BP-ONB-05: one instance, many
// aliases; the identity slice will enrich this with server-declared aliases).
func fleetInstance(b cloudclient.Barkpark) *onbInstance {
	inst := &onbInstance{
		ID:      strings.TrimSpace(b.ID),
		Name:    strings.TrimSpace(b.Name),
		Team:    onboardingTeamLabel(b),
		URL:     fleetTarget(b.URL, b.Host),
		Aliases: onboardingAliases(b),
		Source:  "cloud-fleet",
	}
	return inst
}

// onboardingTeamLabel prefers the human team name, falling back to the team id.
func onboardingTeamLabel(b cloudclient.Barkpark) string {
	if b.Team != nil && strings.TrimSpace(b.Team.Name) != "" {
		return strings.TrimSpace(b.Team.Name)
	}
	return strings.TrimSpace(b.TeamID)
}

// onboardingAliases collects the distinct host aliases a single instance answers
// on — the canonical URL host plus any separately-recorded host. This is the
// client-side seed of BP-ONB-05's alias set (server-declared aliases land with
// the identity slice); for now it makes "same box, two hostnames" legible instead
// of reading as a phantom second server.
func onboardingAliases(b cloudclient.Barkpark) []string {
	seen := map[string]bool{}
	var out []string
	add := func(h string) {
		h = strings.TrimSpace(h)
		if h == "" || seen[h] {
			return
		}
		seen[h] = true
		out = append(out, h)
	}
	add(hostOf(b.URL))
	add(hostOf(b.Host))
	if len(out) <= 1 {
		return nil // a single host is not an alias set — keep the receipt honest
	}
	return out
}

// onboardingAuth is (e): the manifest fetch. A reachable target yields its
// auth_tier; an unreachable one is reported plainly (reachable:false) rather than
// failing the whole receipt with a stack trace.
func onboardingAuth(m *manifest.Manifest, ctx manifest.Context, prov tokenProvenance) onbAuthCheck {
	a := onbAuthCheck{Server: ctx.Server, TokenSource: prov.label()}
	if prov.Source == "" {
		a.TokenSource = tokenSourceUnknown
		if ctx.Token == "" {
			a.TokenSource = tokenSourceNone
		}
	}
	if m != nil {
		a.Reachable = true
		a.Tier = m.AuthTier
	}
	// The shadow rides here on the SAME condition whoami uses: an env token in
	// front of a different saved one, and a tier that shows the server did not
	// accept it (unreachable is not a rejection, so it stays quiet).
	if prov.shadowsSaved() && m != nil && (m.AuthTier == "" || m.AuthTier == "none") {
		a.TokenShadow = prov.shadowWarning(shadowReasonTierNone) + " — " + prov.shadowFix()
	}
	return a
}

// onboardingToolCallProof is (g): the READ-ONLY proof. It invokes task_ready
// through the exact dispatch seam the MCP task_ready tool uses
// (execManifestCommand over the manifest's task.ready verb) and surfaces the
// result — the HTTP status plus a one-line summary of the ready queue. It is NOT
// a stub: a green receipt means a real read tool round-tripped against the target.
func onboardingToolCallProof(g globals, ctx manifest.Context, m *manifest.Manifest) onbToolCall {
	tc := onbToolCall{Tool: "task_ready"}
	if m == nil {
		tc.Summary = "target unreachable — cannot run the read-only proof"
		return tc
	}
	ready, ok := m.Tree().Lookup("task", "ready")
	if !ok {
		tc.Summary = "manifest has no task.ready verb"
		return tc
	}
	status, body, err := execManifestCommand(g, ctx, m, *ready, nil)
	if err != nil {
		tc.Summary = "call failed: " + err.Error()
		return tc
	}
	tc.Status = status
	tc.OK = status >= 200 && status < 300
	tc.Summary = summarizeReadyResult(body, tc.OK)
	return tc
}

// summarizeReadyResult turns the task_ready response body into a one-line,
// bearer-free summary: a ready-count on success, or the server error code on
// failure. It reads only server-side content — never anything the client holds.
func summarizeReadyResult(body []byte, ok bool) string {
	if !ok {
		// The shared parser: a refusal whose other fields are shaped
		// unexpectedly must still surrender its code, or the doctor reports a
		// bare "non-2xx" for a server that named its reason.
		//
		// The HINT rides along when the server sent one. A doctor line exists to
		// tell the operator what to DO, and the code alone ("task_ready returned
		// not_ready") names the fault while withholding the fix the server had
		// already written down. Still server-side content only — a hint is
		// composed by the server and holds nothing the client knows.
		if env, ok := apierr.Parse(body); ok && env.Code != "" {
			line := "task_ready returned " + env.Code
			if h := env.HintLine(); h != "" {
				line += " — " + h
			}
			return line
		}
		return "task_ready returned a non-2xx status"
	}
	n := readyCount(body)
	if n < 0 {
		return "task_ready responded 2xx"
	}
	if n == 1 {
		return "task_ready responded — 1 ready task"
	}
	return "task_ready responded — " + itoa(n) + " ready tasks"
}

// readyCount tolerantly counts the ready tasks in a task_ready body across the
// shapes the endpoint may use ({tasks|documents|data:[...]}, or a bare array),
// returning -1 when none of them fit (still a valid 2xx, just uncounted).
func readyCount(body []byte) int {
	var wrapped struct {
		Docs      []json.RawMessage `json:"docs"`
		Tasks     []json.RawMessage `json:"tasks"`
		Documents []json.RawMessage `json:"documents"`
		Data      []json.RawMessage `json:"data"`
	}
	if json.Unmarshal(body, &wrapped) == nil {
		switch {
		case wrapped.Docs != nil:
			return len(wrapped.Docs)
		case wrapped.Tasks != nil:
			return len(wrapped.Tasks)
		case wrapped.Documents != nil:
			return len(wrapped.Documents)
		case wrapped.Data != nil:
			return len(wrapped.Data)
		}
	}
	var arr []json.RawMessage
	if json.Unmarshal(body, &arr) == nil {
		return len(arr)
	}
	return -1
}

// itoa is a tiny int→string without importing strconv at this call site.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// onboardingPayload projects the receipt onto a generic map for the -o yaml path
// (the json path renders the struct directly to preserve declared field order).
func onboardingPayload(r onboardingReceipt) map[string]any {
	b, _ := json.Marshal(r)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

// renderOnboardingReceipt prints the human receipt: a header, one ✓/✗-marked line
// per section in the fixed audit order, then an overall verdict.
func renderOnboardingReceipt(out *writer, r onboardingReceipt) {
	out.outf("bp doctor — onboarding readiness receipt")

	out.outf("  %s PATH                bp %s", mark(r.Path.Resolved), pathDetail(r.Path))
	out.outf("  %s CLI                 %s", markTri(r.CLI.Status), cliDetail(r.CLI))
	out.outf("  %s Cloud session       %s", mark(r.CloudSession.Present), cloudDetail(r.CloudSession))
	out.outf("  %s Instance            %s", mark(r.Instance != nil), instanceDetail(r.Instance))
	if r.Instance != nil && r.Instance.AliasShadow != "" {
		out.outf("  ⚠ alias shadow        %s", r.Instance.AliasShadow)
	}
	out.outf("  %s Auth                %s", mark(r.Auth.Reachable), authDetail(r.Auth))
	if r.Auth.TokenShadow != "" {
		out.outf("  ⚠ credential shadow   %s", r.Auth.TokenShadow)
	}
	out.outf("  %s MCP catalog         %d tools: %s", mark(r.MCP.Count == len(mcpTaskToolNames)), r.MCP.Count, strings.Join(r.MCP.Tools, ", "))
	out.outf("  %s Tool-call proof     %s", mark(r.ToolCall.OK), r.ToolCall.Summary)

	out.outf("  → reload: %s", r.Reload)

	if r.OK {
		verdict := "=> READY — bp resolves, " + r.Auth.Server + " is reachable, and a read-only tool call round-tripped"
		// A READY receipt must never imply that an unreported leg was verified.
		if un := onboardingUnreported(r); len(un) > 0 {
			verdict += " (UNREPORTED: " + strings.Join(un, "; ") + ")"
		}
		out.outf("%s", verdict)
	} else {
		out.outf("=> NOT READY — %s", strings.Join(onboardingBlockers(r), "; "))
	}
}

// onboardingUnreported names the legs that took NO reading — legs that are
// neither pass nor fail. They do not sink r.OK (see buildOnboardingReceipt), but
// they are printed on the verdict line so a green receipt cannot be mistaken for
// a fully-measured one.
func onboardingUnreported(r onboardingReceipt) []string {
	var u []string
	if r.CLI.Status == onbCLIUnreported {
		u = append(u, "CLI freshness")
	}
	return u
}

// onboardingBlockers lists the core failures sinking readiness (advisory misses
// like a stale CLI or an absent Cloud session are intentionally not blockers).
func onboardingBlockers(r onboardingReceipt) []string {
	var b []string
	if !r.Path.Resolved {
		b = append(b, "bp not on PATH")
	}
	if !r.Auth.Reachable {
		b = append(b, "target unreachable")
	}
	if !r.ToolCall.OK {
		b = append(b, "read-only tool call did not succeed")
	}
	if len(b) == 0 {
		b = append(b, "not ready")
	}
	return b
}

func mark(ok bool) string {
	if ok {
		return "✓"
	}
	return "✗"
}

// markTri renders a tri-state leg: ✓ read-and-good, ✗ read-and-bad, ? no reading
// taken. A "?" is deliberately NOT a "✗" — the check did not fail, it abstained.
func markTri(status string) string {
	switch status {
	case onbCLIUpToDate:
		return "✓"
	case onbCLIBehind:
		return "✗"
	default:
		return "?"
	}
}

func pathDetail(p onbPathCheck) string {
	if p.Resolved {
		return "→ " + p.Path
	}
	return "— " + p.Detail
}

func cliDetail(c onbCLICheck) string {
	if c.Latest != "" {
		return c.Installed + " (latest " + c.Latest + ") — " + c.Detail
	}
	return c.Installed + " — " + c.Detail
}

func cloudDetail(s onbCloudSession) string {
	if !s.Present {
		return "not logged in — run `bp login` for a Cloud session"
	}
	if s.Team != "" {
		return "logged in to " + s.URL + " (team " + s.Team + ")"
	}
	return "logged in to " + s.URL
}

func instanceDetail(i *onbInstance) string {
	if i == nil {
		return "no active target — run `bp setup` or `bp use <name>`"
	}
	parts := []string{}
	if i.Name != "" {
		parts = append(parts, i.Name)
	}
	if i.URL != "" {
		parts = append(parts, i.URL)
	}
	label := strings.Join(parts, " ")
	if i.ID != "" {
		label += " [id " + i.ID + "]"
	}
	if i.Team != "" {
		label += " · team " + i.Team
	}
	if len(i.Aliases) > 0 {
		label += " · aliases " + strings.Join(i.Aliases, ", ")
	}
	return strings.TrimSpace(label)
}

func authDetail(a onbAuthCheck) string {
	if !a.Reachable {
		line := a.Server + " — unreachable (check it's running or run `bp setup`)"
		if a.TokenSource != "" {
			line += " · credential " + a.TokenSource
		}
		return line
	}
	tier := a.Tier
	if tier == "" {
		tier = "unknown"
	}
	line := a.Server + " — reachable, auth_tier " + tier
	if a.TokenSource != "" {
		line += " · credential " + a.TokenSource
	}
	return line
}

// printOnboardingDoctorHelp documents `bp doctor --onboarding`.
func printOnboardingDoctorHelp(out *writer) {
	const help = `bp doctor --onboarding — the client-readiness onboarding receipt.

USAGE
  bp doctor --onboarding [-o json|yaml]

WHAT IT DOES
  emits ONE trustworthy receipt for THIS machine's readiness to drive a Barkpark,
  in a fixed order: (a) bp on PATH, (b) CLI freshness vs the newest release
  (up-to-date / behind / unreported — a dev build can't be compared, so it says
  so instead of claiming a green),
  (c) Cloud session presence, (d) the target instance's id + team + URL/aliases,
  (e) target reachability + auth tier, (f) the 8-tool MCP task catalog,
  (g) a READ-ONLY tool-call proof (a real task_ready call), and (h) the exact
  client-reload instruction. It NEVER prints a bearer token.

  Distinct from plain ` + "`bp doctor`" + `, which runs the remote server HEALTH gate.

  Exits 0 when the core is ready (bp resolves, the target is reachable, and the
  read-only tool call succeeded); non-zero otherwise, so a script can gate on it.`
	out.outf("%s", help)
}
