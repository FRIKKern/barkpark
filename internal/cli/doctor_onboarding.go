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
//	(d) INSTANCE    — the target Barkpark from the cross-team fleet
//	                  (ListAllBarkparks carries id + team per row): instance id,
//	                  team, canonical URL + any host aliases. Falls back to the
//	                  active saved server when the fleet can't be reached.
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

type onbCLICheck struct {
	Installed string `json:"installed"`
	Latest    string `json:"latest"`
	UpToDate  bool   `json:"up_to_date"`
	Detail    string `json:"detail"`
}

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
}

type onbAuthCheck struct {
	Reachable bool   `json:"reachable"`
	Tier      string `json:"tier"`
	Server    string `json:"server"`
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
func runDoctorOnboarding(out *writer, g globals, ctx manifest.Context, args []string) int {
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

	r := buildOnboardingReceipt(g, ctx)

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
func buildOnboardingReceipt(g globals, ctx manifest.Context) onboardingReceipt {
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
		Auth:         onboardingAuth(m, ctx),
		MCP:          onbMCPCatalog{Version: cliVersion, Count: len(mcpTaskToolNames), Tools: append([]string(nil), mcpTaskToolNames...)},
		ToolCall:     onboardingToolCallProof(g, ctx, m),
		Reload:       onboardingReloadInstruction,
	}
	// The core readiness gate: bp is drivable, the target answers, and a real
	// read-only tool call round-tripped. Freshness/Cloud are advisory.
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
		"mcp": map[string]any{
			"version": cliVersion,
			"count":   len(mcpTaskToolNames),
			"tools":   append([]string(nil), mcpTaskToolNames...),
		},
		"tool_call":          onboardingToolCallProof(g, ctx, m),
		"reload_instruction": onboardingReloadInstruction,
	}
}

// localInstance is whoami's NETWORK-FREE instance identity: the active saved
// target, read from local config only (no cross-team fleet fetch — that stays in
// the doctor receipt, which is a rarely-run diagnostic). It reports the resolved
// URL, the saved entry's display name, and the Cloud-session team. The instance
// ID + host aliases are the identity slice's ServerEntry.InstanceID/Aliases
// (BP-ONB-05); until that slice lands (and onb-backlog-doctor-prefer-local-
// serverentry wires this accessor to it) they read empty here — the spine keys
// are present and additive from day one, and fill in without a shape change.
// Returns nil only when there is no active target at all.
func localInstance(cfg *Config, ctx manifest.Context) *onbInstance {
	active := strings.TrimRight(strings.TrimSpace(ctx.Server), "/")
	if active == "" {
		return nil
	}
	inst := &onbInstance{URL: active, Source: "local"}
	if cfg != nil {
		if e, ok := cfg.FindServer(ctx.Server); ok {
			inst.Name = cfg.DisplayName(e)
		}
		inst.Team = strings.TrimSpace(cfg.CloudTeam)
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
// A dev build is not "stale" — it just can't be compared.
func onboardingCLIFreshness() onbCLICheck {
	c := onbCLICheck{Installed: cliVersion}
	if cliVersion == "dev" {
		c.UpToDate = true
		c.Detail = "running a dev build — release comparison skipped"
		return c
	}
	latest, err := onboardingLatestRelease()
	if err != nil {
		c.Detail = "could not resolve the latest release: " + err.Error()
		return c
	}
	c.Latest = latest
	if compareVersions(cliVersion, latest) < 0 {
		c.Detail = "a newer CLI is available — run `bp upgrade`"
		return c
	}
	c.UpToDate = true
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

// onboardingInstance is (d): the target Barkpark's identity. The cross-team fleet
// (ListAllBarkparks) is authoritative — it carries the instance id + team per row
// — so we match the active content target against it and report id/team/url +
// host aliases. When the fleet can't be reached (or the user is self-hosted with
// no Cloud session), we fall back to the active saved server (url only). Returns
// nil only when there is no active target at all.
func onboardingInstance(cfg *Config, ctx manifest.Context) *onbInstance {
	active := strings.TrimRight(strings.TrimSpace(ctx.Server), "/")

	if cfg != nil && cfg.HasCloudToken() && onboardingListFleet != nil {
		if fleet, err := onboardingListFleet(cfg); err == nil {
			for _, b := range fleet {
				if fleetMatchesActive(b, active) {
					return fleetInstance(b)
				}
			}
		}
	}

	if active == "" {
		return nil
	}
	return &onbInstance{URL: active, Source: "active-server"}
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
func onboardingAuth(m *manifest.Manifest, ctx manifest.Context) onbAuthCheck {
	a := onbAuthCheck{Server: ctx.Server}
	if m != nil {
		a.Reachable = true
		a.Tier = m.AuthTier
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
		var env struct {
			Error struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(body, &env) == nil && env.Error.Code != "" {
			return "task_ready returned " + env.Error.Code
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
	out.outf("  %s CLI                 %s", mark(r.CLI.UpToDate), cliDetail(r.CLI))
	out.outf("  %s Cloud session       %s", mark(r.CloudSession.Present), cloudDetail(r.CloudSession))
	out.outf("  %s Instance            %s", mark(r.Instance != nil), instanceDetail(r.Instance))
	out.outf("  %s Auth                %s", mark(r.Auth.Reachable), authDetail(r.Auth))
	out.outf("  %s MCP catalog         %d tools: %s", mark(r.MCP.Count == len(mcpTaskToolNames)), r.MCP.Count, strings.Join(r.MCP.Tools, ", "))
	out.outf("  %s Tool-call proof     %s", mark(r.ToolCall.OK), r.ToolCall.Summary)

	out.outf("  → reload: %s", r.Reload)

	if r.OK {
		out.outf("=> READY — bp resolves, %s is reachable, and a read-only tool call round-tripped", r.Auth.Server)
	} else {
		out.outf("=> NOT READY — %s", strings.Join(onboardingBlockers(r), "; "))
	}
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
		return a.Server + " — unreachable (check it's running or run `bp setup`)"
	}
	tier := a.Tier
	if tier == "" {
		tier = "unknown"
	}
	return a.Server + " — reachable, auth_tier " + tier
}

// printOnboardingDoctorHelp documents `bp doctor --onboarding`.
func printOnboardingDoctorHelp(out *writer) {
	const help = `bp doctor --onboarding — the client-readiness onboarding receipt.

USAGE
  bp doctor --onboarding [-o json|yaml]

WHAT IT DOES
  emits ONE trustworthy receipt for THIS machine's readiness to drive a Barkpark,
  in a fixed order: (a) bp on PATH, (b) CLI freshness vs the newest release,
  (c) Cloud session presence, (d) the target instance's id + team + URL/aliases,
  (e) target reachability + auth tier, (f) the 8-tool MCP task catalog,
  (g) a READ-ONLY tool-call proof (a real task_ready call), and (h) the exact
  client-reload instruction. It NEVER prints a bearer token.

  Distinct from plain ` + "`bp doctor`" + `, which runs the remote server HEALTH gate.

  Exits 0 when the core is ready (bp resolves, the target is reachable, and the
  read-only tool call succeeded); non-zero otherwise, so a script can gate on it.`
	out.outf("%s", help)
}
