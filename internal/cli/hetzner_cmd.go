package cli

// hetzner_cmd.go is the `bp cloud hetzner …` surface: direct, native control
// of a Hetzner Cloud project over internal/hetzner's SDK client (hcloud-go),
// no `hcloud` binary required. It is a built-in (not a manifest command)
// because it talks to api.hetzner.cloud, not a Barkpark server.
//
// Command tree:
//
//	bp cloud hetzner server    list · get · create · delete · poweron · poweroff ·
//	                           reboot · reset · shutdown · rebuild · resize ·
//	                           enable-rescue · disable-rescue · create-image ·
//	                           enable-backup · disable-backup · attach-iso ·
//	                           detach-iso · ip
//	bp cloud hetzner ssh-key   list · get · create · delete
//	bp cloud hetzner volume | network | firewall | load-balancer | floating-ip |
//	                           primary-ip | placement-group | certificate | dns
//	                           (the PR3 resources — hetzner_net_cmd.go,
//	                           hetzner_lb_cmd.go, hetzner_dns_cmd.go)
//	bp cloud hetzner server-types | locations | datacenters | images | isos |
//	                           pricing | lb-types (read-only discovery)
//	bp cloud hetzner storage   bucket · object — the S3 data plane
//	                           (PR4 — hetzner_storage_cmd.go, S3 credentials)
//	bp cloud hetzner backup    create · list · restore · prune — pg_dump → S3
//	                           (PR4 — hetzner_backup_cmd.go over internal/backup)
//
// Token resolution: --token flag > HCLOUD_TOKEN > the active `hcloud context`
// (hetzner.ResolveToken). Output rides the CLI-wide -o flag: table (default on
// a tty) | json | yaml through the shared writer, so `-o yaml` works here
// exactly like on every other cloud/sites command.
//
// EVERY mutating server verb waits its Hetzner Action(s) to completion
// (Action.WaitFor) and reports the outcome — never fire-and-forget; create
// additionally polls the server itself until it is running with a public IP.

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
	"github.com/mattn/go-runewidth"

	"github.com/FRIKKern/barkpark/internal/hetzner"
)

// hetznerCtx is the context every Hetzner API call runs under. A package var
// (the cloudCtx idiom) so a later task can bound it without touching call sites.
var hetznerCtx = context.Background

// newHetznerClient builds the authenticated SDK client. A package var so the
// tests can point it at an httptest fake with a fast poll interval; production
// honours HCLOUD_ENDPOINT (the same override the hcloud CLI supports).
var newHetznerClient = func(token string) *hetzner.Client {
	var opts []hetzner.Option
	if ep := strings.TrimSpace(os.Getenv("HCLOUD_ENDPOINT")); ep != "" {
		opts = append(opts, hetzner.WithEndpoint(ep))
	}
	return hetzner.NewClient(token, opts...)
}

// hetznerCreatePoll is the interval `server create` re-reads the server at
// while waiting for running+IP after the create actions succeed. A var so
// tests poll instantly.
var hetznerCreatePoll = 2 * time.Second

// hetznerCreatePollMax bounds the running+IP read-back loop.
const hetznerCreatePollMax = 60

// hetznerActionPollMax bounds the POST-CONDITION read-back the power verbs do
// (poweron/poweroff/shutdown). At hetznerCreatePoll (2s) that is ~30s, matching
// the official hcloud CLI's `--wait` shutdown timeout: long enough that a guest
// reacting to ACPI is not called a failure, short enough that a stuck box is
// reported while the owner is still watching.
const hetznerActionPollMax = 15

// runCloud is the `bp cloud …` dispatcher. It carries two kinds of subcommand:
// a PROVIDER (today only hetzner) for direct provider-API control, and the
// control-plane fleet verbs — `status` (the decision-15 triage view), `open`
// (the decision-14 dashboard deep link), `webhook` (the console panel's
// terminal twin), and `verify` (the on-demand golden-path suite, D53). A new
// provider slots in as a sibling of hetzner.
func runCloud(out *writer, g globals, args []string) int {
	if len(args) == 0 {
		if g.help {
			printCloudHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing cloud command (run `bp cloud -h` for usage)", exitUsage)
	}
	switch args[0] {
	case "hetzner":
		return runCloudHetzner(out, g, args[1:])
	case "azure":
		return runCloudAzure(out, g, args[1:])
	case "instance", "instances":
		return runCloudInstance(out, g, args[1:])
	case "support", "supports":
		return runCloudSupport(out, g, args[1:])
	case "workspace", "workspaces":
		return runCloudWorkspace(out, g, args[1:])
	case "providers":
		return runCloudProviders(out, g, args[1:])
	case "status":
		return runCloudStatus(out, g, args[1:])
	case "open":
		return runCloudOpen(out, g, args[1:])
	case "webhook", "webhooks":
		return runCloudWebhook(out, g, args[1:])
	case "verify":
		return runCloudVerify(out, g, args[1:])
	case "deploy":
		return runCloudDeploy(out, g, args[1:])
	case "site", "sites":
		return runCloudSite(out, g, args[1:])
	// `deployments` (plural) is the FLEET deploy census — a rate over a pinned
	// window. Deliberately NOT a sibling verb of `bp cloud deploy` (singular),
	// which pushes ONE ref to ONE box: one acts, one measures.
	case "deployments":
		return runCloudDeployments(out, g, args[1:])
	// `deliveries` is the PLATFORM delivery record for ONE sha — what happened
	// to a merge. It is NOT `bp cloud webhook deliveries` (a tenant instance's
	// webhook send log), which is why it sits at the top level under its own
	// verb and why its header line names the population it read.
	case "deliveries":
		return runCloudDeliveries(out, g, args[1:])
	case "domain", "domains":
		return runCloudDomain(out, g, args[1:])
	case "usage":
		return runCloudUsage(out, g, args[1:])
	case "members", "member":
		return runCloudMembers(out, g, args[1:])
	case "autoupdate":
		return runCloudAutoupdate(out, g, args[1:])
	case "rollout":
		return runCloudRollout(out, g, args[1:])
	case "rollback":
		return runCloudRollback(out, g, args[1:])
	// `update` is the self-update TRIGGER — the verb the console prints as a
	// copy-pasteable recovery chip (cliChipHtml("bp cloud update " + instance) in
	// app.js). It sits beside `rollback` because they are siblings: two relayed,
	// team-admin-gated, async run triggers against one box, one forward and one
	// back. Deliberately NOT aliased to `autoupdate` (which sets POLICY and starts
	// nothing) — one acts, one configures.
	case "update":
		return runCloudUpdate(out, g, args[1:])
	default:
		return useError(out, "usage", fmt.Sprintf("unknown cloud command %q (run `bp cloud -h` for usage)", args[0]), exitUsage)
	}
}

// runCloudHetzner routes `bp cloud hetzner <resource> …` to its resource.
func runCloudHetzner(out *writer, g globals, args []string) int {
	if len(args) == 0 {
		if g.help {
			printHetznerHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing hetzner resource (run `bp cloud hetzner -h` for usage)", exitUsage)
	}
	resource := args[0]
	rest := args[1:]
	switch resource {
	case "overview":
		return runHetznerOverview(out, g, rest)
	case "server", "servers":
		return runHetznerServer(out, g, rest)
	case "ssh-key", "ssh-keys":
		return runHetznerSSHKey(out, g, rest)
	case "volume", "volumes":
		return runHetznerVolume(out, g, rest)
	case "network", "networks":
		return runHetznerNetwork(out, g, rest)
	case "firewall", "firewalls":
		return runHetznerFirewall(out, g, rest)
	case "load-balancer", "load-balancers", "lb":
		return runHetznerLoadBalancer(out, g, rest)
	case "lb-types", "lb-type", "load-balancer-types":
		return runHetznerLBTypes(out, g, rest)
	case "floating-ip", "floating-ips":
		return runHetznerFloatingIP(out, g, rest)
	case "primary-ip", "primary-ips":
		return runHetznerPrimaryIP(out, g, rest)
	case "placement-group", "placement-groups":
		return runHetznerPlacementGroup(out, g, rest)
	case "certificate", "certificates", "cert":
		return runHetznerCertificate(out, g, rest)
	case "dns":
		return runHetznerDNS(out, g, rest)
	case "instance", "instances":
		return runHetznerInstance(out, g, rest)
	case "storage":
		return runHetznerStorage(out, g, rest)
	case "backup", "backups":
		return runHetznerBackup(out, g, rest)
	case "server-types", "server-type":
		return runHetznerServerTypes(out, g, rest)
	case "locations", "location":
		return runHetznerLocations(out, g, rest)
	case "datacenters", "datacenter":
		return runHetznerDatacenters(out, g, rest)
	case "images", "image":
		return runHetznerImages(out, g, rest)
	case "isos", "iso":
		return runHetznerISOs(out, g, rest)
	case "pricing":
		return runHetznerPricing(out, g, rest)
	case "help":
		printHetznerHelp(out)
		return exitOK
	default:
		return useError(out, "usage", fmt.Sprintf("unknown hetzner resource %q (run `bp cloud hetzner -h` for usage)", resource), exitUsage)
	}
}

// hetznerClient resolves the token (flag > env > hcloud context) and returns
// the authenticated client, or emits the clear no-token error (exit 3).
func hetznerClient(out *writer, g globals) (*hetzner.Client, bool) {
	tok := strings.TrimSpace(g.token)
	if tok == "" {
		t, err := hetzner.ResolveToken()
		if err != nil {
			useError(out, "auth", "no Hetzner Cloud token — pass --token <t>, set HCLOUD_TOKEN, or select an `hcloud context`", exitAuth)
			return nil, false
		}
		tok = t
	}
	return newHetznerClient(tok), true
}

// hzExit maps a Hetzner API error onto the CLI's stable exit-code scheme.
func hzExit(err error) int {
	switch {
	case hcloud.IsError(err, hcloud.ErrorCodeNotFound):
		return exitNotFound
	case hcloud.IsError(err, hcloud.ErrorCodeUnauthorized):
		return exitAuth
	case hcloud.IsError(err, hcloud.ErrorCodeRateLimitExceeded):
		return exitRateLimit
	default:
		return exitGeneric
	}
}

// hzFail emits err through the shared error envelope with the mapped exit code.
func hzFail(out *writer, what string, err error) int {
	return useError(out, "failed", what+": "+err.Error(), hzExit(err))
}

func hzDNSFail(out *writer, what string, err error, usedComputeToken bool) int {
	if usedComputeToken && hcloud.IsError(err, hcloud.ErrorCodeNotFound) {
		return useError(out, "failed", what+": "+err.Error()+
			"; set BARKPARK_DNS_HCLOUD_TOKEN to the DNS-project token (see cloud/postfix/README.md section 1)", hzExit(err))
	}
	return hzFail(out, what, err)
}

// ---------------------------------------------------------------------------
// arg parsing (the parseAttachArgs idiom, generalised: positionals + declared
// value flags — repeatable — + declared bool flags; anything else is a usage
// error so a typo never silently no-ops)
// ---------------------------------------------------------------------------

type hzArgs struct {
	pos   []string
	vals  map[string][]string
	bools map[string]bool
}

// val returns the last value of --name, "" when absent.
func (a *hzArgs) val(name string) string {
	vs := a.vals[name]
	if len(vs) == 0 {
		return ""
	}
	return vs[len(vs)-1]
}

// list returns every value of --name, additionally splitting each on commas
// (so `--ssh-key a,b --ssh-key c` yields [a b c]).
func (a *hzArgs) list(name string) []string {
	var out []string
	for _, v := range a.vals[name] {
		for _, part := range strings.Split(v, ",") {
			if p := strings.TrimSpace(part); p != "" {
				out = append(out, p)
			}
		}
	}
	return out
}

// parseHzArgs splits a hetzner subcommand tail into positionals and declared
// flags. valueFlags take a value (`--name v` or `--name=v`) and may repeat;
// boolFlags stand alone. usage is echoed on error.
func parseHzArgs(args []string, valueFlags, boolFlags []string, usage string) (*hzArgs, error) {
	isVal := map[string]bool{}
	for _, f := range valueFlags {
		isVal["--"+f] = true
	}
	isBool := map[string]bool{}
	for _, f := range boolFlags {
		isBool["--"+f] = true
	}
	out := &hzArgs{vals: map[string][]string{}, bools: map[string]bool{}}
	for i := 0; i < len(args); i++ {
		a := args[i]
		// A bare "-" is a positional by unix convention (stdin/stdout), never a flag.
		if a == "" || a == "-" || a[0] != '-' {
			out.pos = append(out.pos, a)
			continue
		}
		// -y is the one blessed short flag: the destroy-tier --yes alias.
		// Honoured only where the verb declared --yes, so -y on any other verb
		// still errors as unknown instead of silently no-opping.
		if a == "-y" && isBool["--yes"] {
			out.bools["yes"] = true
			continue
		}
		key, inline, hasInline := a, "", false
		if eq := strings.IndexByte(a, '='); eq >= 0 && strings.HasPrefix(a, "--") {
			key, inline, hasInline = a[:eq], a[eq+1:], true
		}
		switch {
		case isVal[key]:
			val := inline
			if !hasInline {
				if i+1 >= len(args) {
					return nil, fmt.Errorf("%s needs a value (usage: %s)", key, usage)
				}
				val = args[i+1]
				i++
			}
			out.vals[strings.TrimPrefix(key, "--")] = append(out.vals[strings.TrimPrefix(key, "--")], val)
		case isBool[key]:
			if hasInline {
				return nil, fmt.Errorf("flag %q takes no value", key)
			}
			out.bools[strings.TrimPrefix(key, "--")] = true
		default:
			return nil, fmt.Errorf("unknown flag %q (usage: %s)", key, usage)
		}
	}
	return out, nil
}

// parseHzLabels turns repeated `--label k=v` values into the label map.
func parseHzLabels(pairs []string) (map[string]string, error) {
	if len(pairs) == 0 {
		return nil, nil
	}
	labels := make(map[string]string, len(pairs))
	for _, p := range pairs {
		eq := strings.IndexByte(p, '=')
		if eq <= 0 {
			return nil, fmt.Errorf("invalid --label %q (want key=value)", p)
		}
		labels[p[:eq]] = p[eq+1:]
	}
	return labels, nil
}

// ---------------------------------------------------------------------------
// id-or-name references. Rebuild/attach-iso/resize bodies take an IDOrName —
// a numeric arg rides as the id, anything else as the name (mirrors the
// hetzner package's imageRef).
// ---------------------------------------------------------------------------

func hzImageRef(s string) *hcloud.Image {
	if id, err := strconv.ParseInt(s, 10, 64); err == nil {
		return &hcloud.Image{ID: id}
	}
	return &hcloud.Image{Name: s}
}

func hzServerTypeRef(s string) *hcloud.ServerType {
	if id, err := strconv.ParseInt(s, 10, 64); err == nil {
		return &hcloud.ServerType{ID: id}
	}
	return &hcloud.ServerType{Name: s}
}

// resolveHzServer looks a server up by numeric id or name, with a clean
// not-found error (the SDK returns nil,nil for an unknown name).
func resolveHzServer(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.Server, error) {
	srv, _, err := hc.Server.Get(ctx, idOrName)
	if err != nil {
		return nil, err
	}
	if srv == nil {
		return nil, fmt.Errorf("server %q not found (see `bp cloud hetzner server list`)", idOrName)
	}
	return srv, nil
}

// resolveHzSSHKeys resolves ssh-key names/ids to full keys. The create/rescue
// bodies carry key IDs, so a name must be looked up — and the lookup doubles
// as a clear "ssh key X not found" error before anything is provisioned.
func resolveHzSSHKeys(ctx context.Context, hc *hcloud.Client, refs []string) ([]*hcloud.SSHKey, error) {
	keys := make([]*hcloud.SSHKey, 0, len(refs))
	for _, ref := range refs {
		key, _, err := hc.SSHKey.Get(ctx, ref)
		if err != nil {
			return nil, fmt.Errorf("look up ssh key %q: %w", ref, err)
		}
		if key == nil {
			return nil, fmt.Errorf("ssh key %q not found (see `bp cloud hetzner ssh-key list`)", ref)
		}
		keys = append(keys, key)
	}
	return keys, nil
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

// hzCell renders a table cell, dashing out empties so columns stay scannable.
func hzCell(s string) string {
	if s == "" {
		return "—"
	}
	return sanitizeCell(s)
}

// renderHzTable prints an aligned upper-header table (the barkparks/sites
// idiom: data-driven widths, two-space gutters, no separator row). Each cell is
// clamped at cellMaxRunes display cells (truncateCell, "..." suffix) before
// measuring, so one long value (a server description, DNS TXT record, or label)
// can't stretch its column past the terminal — matching table.go. Headers stay
// unclamped (short by construction); full data is one `-o json` away.
func renderHzTable(out *writer, headers []string, rows [][]string) {
	// Clamp every cell once, up front, so both the width measurement and the
	// row rendering below see the same truncated strings.
	for _, r := range rows {
		for i := range r {
			r[i] = truncateCell(r[i], cellMaxRunes)
		}
	}
	// Widths are measured in terminal display cells (runewidth), not bytes or
	// runes: a CJK ideograph is one rune but two columns, and a combining mark
	// is one rune but zero columns — a rune width would shear the alignment for
	// either. FillRight pads to that same cell width. Matches table.go.
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = runewidth.StringWidth(h)
	}
	for _, r := range rows {
		for i := range headers {
			if i < len(r) {
				if n := runewidth.StringWidth(r[i]); n > widths[i] {
					widths[i] = n
				}
			}
		}
	}
	// Header-driven chrome: one tinter per column, resolved from the header
	// label (nil for a column with no chrome vocabulary). Tinting is applied to
	// DATA rows only, only when out.color is on, and only wraps the padded cell
	// in an SGR span — column widths above are measured on bare strings, so the
	// color-off path stays byte-identical to a build without chrome_table.go.
	tinters := make([]cellTinter, len(headers))
	for i, h := range headers {
		tinters[i] = tinterForHeader(h)
	}
	line := func(cells []string, paint bool) string {
		parts := make([]string, len(cells))
		for i, c := range cells {
			padded := runewidth.FillRight(c, widths[i])
			if paint && out.color && i < len(tinters) {
				padded = paintChromeCell(tinters[i], padded, c)
			}
			parts[i] = padded
		}
		return strings.TrimRight(strings.Join(parts, "  "), " ")
	}
	out.outf("%s", line(headers, false))
	for _, r := range rows {
		out.outf("%s", line(r, true))
	}
}

// hzServerRow is the structured (json/yaml) shape of one server.
func hzServerRow(s *hcloud.Server) map[string]any {
	row := map[string]any{
		"id":     s.ID,
		"name":   s.Name,
		"status": string(s.Status),
	}
	if s.ServerType != nil {
		row["type"] = s.ServerType.Name
	}
	if loc := hzServerLocation(s); loc != "" {
		row["location"] = loc
	}
	if s.Image != nil {
		row["image"] = hzImageLabel(s.Image)
	}
	if s.PublicNet.IPv4.IP != nil {
		row["ipv4"] = s.PublicNet.IPv4.IP.String()
	}
	if s.PublicNet.IPv6.IP != nil {
		row["ipv6"] = s.PublicNet.IPv6.IP.String()
	}
	if !s.Created.IsZero() {
		row["created"] = s.Created.UTC().Format(time.RFC3339)
	}
	if len(s.Labels) > 0 {
		row["labels"] = s.Labels
	}
	if s.RescueEnabled {
		row["rescue_enabled"] = true
	}
	if s.BackupWindow != "" {
		row["backup_window"] = s.BackupWindow
	}
	if s.ISO != nil {
		row["iso"] = s.ISO.Name
	}
	return row
}

// hzServerLocation prefers the non-deprecated Location, falling back to the
// datacenter's location for older payloads.
func hzServerLocation(s *hcloud.Server) string {
	if s.Location != nil {
		return s.Location.Name
	}
	if s.Datacenter != nil && s.Datacenter.Location != nil {
		return s.Datacenter.Location.Name
	}
	return ""
}

// hzImageLabel names an image for humans: name (system images), else
// description (snapshots/backups), else the bare id.
func hzImageLabel(img *hcloud.Image) string {
	if img.Name != "" {
		return img.Name
	}
	if img.Description != "" {
		return img.Description
	}
	return strconv.FormatInt(img.ID, 10)
}

func hzIPv4(s *hcloud.Server) string {
	if s.PublicNet.IPv4.IP != nil {
		return s.PublicNet.IPv4.IP.String()
	}
	return ""
}

// hzDone reports a completed mutating verb: `{ok, action, server, …extra}` on
// json/yaml, a ✓ line (plus extra key: value lines, sorted) on the table view.
func hzDone(out *writer, action string, srv *hcloud.Server, extra map[string]any) int {
	payload := map[string]any{
		"ok":     true,
		"action": action,
		"server": map[string]any{"id": srv.ID, "name": srv.Name},
	}
	for k, v := range extra {
		payload[k] = v
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("✓ %s — server %s (id %d)", action, srv.Name, srv.ID)
	keys := make([]string, 0, len(extra))
	for k := range extra {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out.outf("  %s: %s", k, cellString(extra[k]))
	}
	return exitOK
}

// hzWait polls the given actions to completion, skipping nils (some SDK calls
// return an optional action). This is the never-fire-and-forget seam every
// mutating verb funnels through.
func hzWait(ctx context.Context, hc *hcloud.Client, actions ...*hcloud.Action) error {
	live := make([]*hcloud.Action, 0, len(actions))
	for _, a := range actions {
		if a != nil {
			live = append(live, a)
		}
	}
	if len(live) == 0 {
		return nil
	}
	return hc.Action.WaitFor(ctx, live...)
}

// ---------------------------------------------------------------------------
// server
// ---------------------------------------------------------------------------

func runHetznerServer(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerServerHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing server command (run `bp cloud hetzner server -h` for usage)", exitUsage)
	}
	verb := args[0]
	rest := args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerServerList(out, g, rest)
	case "get", "show":
		return runHetznerServerGet(out, g, rest)
	case "create":
		return runHetznerServerCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerServerDelete(out, g, rest)
	case "poweron":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.Poweron(ctx, srv)
			return a, err
		})
	case "poweroff":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.Poweroff(ctx, srv)
			return a, err
		})
	case "reboot":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.Reboot(ctx, srv)
			return a, err
		})
	case "reset":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.Reset(ctx, srv)
			return a, err
		})
	case "shutdown":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.Shutdown(ctx, srv)
			return a, err
		})
	case "disable-rescue":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.DisableRescue(ctx, srv)
			return a, err
		})
	case "enable-backup":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.EnableBackup(ctx, srv, "")
			return a, err
		})
	case "disable-backup":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.DisableBackup(ctx, srv)
			return a, err
		})
	case "detach-iso":
		return runHetznerServerAction(out, g, verb, rest, func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error) {
			a, _, err := hc.Server.DetachISO(ctx, srv)
			return a, err
		})
	case "rebuild":
		return runHetznerServerRebuild(out, g, rest)
	case "resize":
		return runHetznerServerResize(out, g, rest)
	case "enable-rescue":
		return runHetznerServerEnableRescue(out, g, rest)
	case "create-image":
		return runHetznerServerCreateImage(out, g, rest)
	case "attach-iso":
		return runHetznerServerAttachISO(out, g, rest)
	case "ip":
		return runHetznerServerIP(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown server command %q (run `bp cloud hetzner server -h` for usage)", verb), exitUsage)
	}
}

// hzOneTarget parses a tail that must be exactly `<id|name>` (no flags).
func hzOneTarget(out *writer, args []string, usage string) (string, bool) {
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		useError(out, "usage", err.Error(), exitUsage)
		return "", false
	}
	if len(a.pos) != 1 {
		useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
		return "", false
	}
	return a.pos[0], true
}

func runHetznerServerList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner server list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	servers, err := c.HCloud().Server.AllWithOpts(ctx, hcloud.ServerListOpts{})
	if err != nil {
		return hzFail(out, "list servers", err)
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(servers))
		for _, s := range servers {
			rows = append(rows, hzServerRow(s))
		}
		out.emitStructured(map[string]any{"servers": rows})
		return exitOK
	}
	if len(servers) == 0 {
		out.outf("no servers in this project — create one with 'bp cloud hetzner server create --name <n> --type <t> --image <img>'")
		return exitOK
	}
	rows := make([][]string, 0, len(servers))
	for _, s := range servers {
		typ := ""
		if s.ServerType != nil {
			typ = s.ServerType.Name
		}
		rows = append(rows, []string{
			strconv.FormatInt(s.ID, 10),
			hzCell(s.Name),
			hzCell(string(s.Status)),
			hzCell(typ),
			hzCell(hzServerLocation(s)),
			hzCell(hzIPv4(s)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "STATUS", "TYPE", "LOCATION", "IPV4"}, rows)
	return exitOK
}

func runHetznerServerGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner server get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	srv, err := resolveHzServer(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get server", errOrNotFound(err))
	}
	row := hzServerRow(srv)
	if out.emitStructured(map[string]any{"server": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

// errOrNotFound is a no-op passthrough that exists to make the not-found exit
// mapping explicit at call sites: resolveHzServer's "not found" error is a
// plain error (the SDK returned nil,nil), so hzExit would classify it generic.
// Wrap it as a Hetzner not_found so the exit code lands on exitNotFound.
func errOrNotFound(err error) error {
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "not found") && !hcloud.IsError(err, hcloud.ErrorCodeNotFound) {
		return hcloud.Error{Code: hcloud.ErrorCodeNotFound, Message: err.Error()}
	}
	return err
}

func runHetznerServerCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner server create --name <n> --type <t> --image <img> [--location <loc>] [--ssh-key <k>[,<k>…]] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "type", "image", "location", "ssh-key", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name, typ, image := a.val("name"), a.val("type"), a.val("image")
	if name == "" || typ == "" || image == "" {
		return useError(out, "usage", "--name, --type and --image are required (usage: "+usage+")", exitUsage)
	}
	labels, lerr := parseHzLabels(a.list("label"))
	if lerr != nil {
		return useError(out, "usage", lerr.Error(), exitUsage)
	}

	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()

	keys, kerr := resolveHzSSHKeys(ctx, hc, a.list("ssh-key"))
	if kerr != nil {
		return hzFail(out, "create server", errOrNotFound(kerr))
	}

	opts := hcloud.ServerCreateOpts{
		Name:       name,
		ServerType: hzServerTypeRef(typ),
		Image:      hzImageRef(image),
		SSHKeys:    keys,
		Labels:     labels,
	}
	if loc := a.val("location"); loc != "" {
		opts.Location = &hcloud.Location{Name: loc}
	}

	result, _, err := hc.Server.Create(ctx, opts)
	if err != nil {
		return hzFail(out, "create server", err)
	}
	if result.Server == nil {
		return useError(out, "failed", "create server "+name+": the API returned no server", exitGeneric)
	}
	out.info("server %s accepted — waiting for the create action(s)…", name)
	actions := append([]*hcloud.Action{result.Action}, result.NextActions...)
	if werr := hzWait(ctx, hc, actions...); werr != nil {
		return hzFail(out, "create server "+name+": create action failed", werr)
	}

	// Actions done ≠ booted: re-read until the box reports running WITH a
	// public IP, so "create succeeded" always means "reachable server".
	srv := result.Server
	for i := 0; i < hetznerCreatePollMax; i++ {
		if srv != nil && srv.Status == hcloud.ServerStatusRunning && hzIPv4(srv) != "" {
			break
		}
		time.Sleep(hetznerCreatePoll)
		fresh, _, gerr := hc.Server.GetByID(ctx, result.Server.ID)
		if gerr != nil {
			return hzFail(out, "create server "+name+": read-back", gerr)
		}
		if fresh != nil {
			srv = fresh
		}
	}
	if srv == nil || srv.Status != hcloud.ServerStatusRunning || hzIPv4(srv) == "" {
		return useError(out, "failed", fmt.Sprintf("create server %s: created (id %d) but not running with an IP yet — check `bp cloud hetzner server get %s`", name, result.Server.ID, name), exitGeneric)
	}

	extra := map[string]any{"status": string(srv.Status), "ipv4": hzIPv4(srv)}
	if srv.PublicNet.IPv6.IP != nil {
		extra["ipv6"] = srv.PublicNet.IPv6.IP.String()
	}
	// No ssh key on the box → Hetzner mints a root password; surface it or it
	// is lost (it is never retrievable again).
	if result.RootPassword != "" {
		extra["root_password"] = result.RootPassword
	}
	return hzDone(out, "create", srv, extra)
}

func runHetznerServerDelete(out *writer, g globals, args []string) int {
	target, yes, ok := hzOneTargetYes(out, args, "bp cloud hetzner server delete <id|name> [--yes]")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, err := resolveHzServer(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete server", errOrNotFound(err))
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "server", srv.Name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	result, _, err := hc.Server.DeleteWithResult(ctx, srv)
	if err != nil {
		return hzFail(out, "delete server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "delete server "+srv.Name+": delete action failed", werr)
	}
	return hzDone(out, "delete", srv, nil)
}

// ---------------------------------------------------------------------------
// server-action post-conditions (PDS-D355)
//
// runHetznerServerAction used to end at `hzDone(out, verb, srv, nil)` with the
// server object it had resolved BEFORE firing the action. The receipt therefore
// carried `id` and `name` — precisely the two fields an action cannot change —
// so `bp cloud hetzner server reboot web-1` printed byte-identical output
// whether the machine came back up or stayed down.
//
// SHARPLY: hzWait already catches an ACTION-level failure (the Action goes to
// `error` and the verb exits non-zero). What was uncaught is the resulting
// SERVER STATE. So every action verb now re-reads the server after the action
// and reports what it OBSERVED, which is the same move runHetznerServerCreate
// makes 60 lines up ("Actions done ≠ booted"). This is a port, not an
// invention.
//
// There is no single predicate: the nine verbs fall into five shapes.
//
//	A  poweron       → Status == running, BOUNDED POLL (transient `starting`)
//	B  poweroff      → Status == off,     BOUNDED POLL (transient `stopping`)
//	C  reboot, reset → NO DISCRIMINATOR EXISTS. hcloud.Server carries no boot
//	                   time, uptime or boot id, and the pre- and post-states are
//	                   both `running`. The sentence is therefore NARROWED — it
//	                   says what it confirmed and names what it cannot — never
//	                   strengthened. Reporting `Status == running` under an
//	                   unchanged "✓ reboot" would still be vacuous.
//	D  shutdown      → ACPI. The guest OS has to react, so a SINGLE read would
//	                   false-red a healthy shutdown; the poll is mandatory and a
//	                   timeout is an honest PARTIAL ("signal sent; the guest has
//	                   not powered off after N"), not a failure.
//	E  metadata      → disable-rescue/enable-backup/disable-backup/detach-iso
//	                   flip a field that is already settled once the action
//	                   completes: one read is enough.
//
// THE NEW FAILURE MODE, HANDLED EXPLICITLY. Every post-condition read is a way
// for a verb to fail where it previously could not. A rate-limited or otherwise
// erroring GetByID after a SUCCESSFUL reboot must never tell the owner the
// reboot failed — that is the same lie pointing the other way. A read-back that
// errors is reported as "confirmation unavailable" and exits 0; only a read-back
// that SUCCEEDS and disagrees is a failed post-condition.
// ---------------------------------------------------------------------------

// hzPost is one verb's post-condition: what to re-read, whether the state is
// reached asynchronously, what the receipt reports, and how to say it did not
// hold.
type hzPost struct {
	// holds is the post-condition, read off a FRESH server. nil means the verb
	// has no observable discriminator (reboot/reset): its claim is narrowed
	// instead, and it can never fail here.
	holds func(*hcloud.Server) bool
	// poll re-reads up to hetznerActionPollMax times while holds is false.
	poll bool
	// observe is the state the receipt carries, always off the FRESH server.
	observe func(*hcloud.Server) map[string]any
	// unmet phrases the post-condition NOT holding, for the receipt or error.
	unmet func(srv *hcloud.Server, window time.Duration) string
	// partial marks a verb whose unmet post-condition is not a failure: the
	// verb did all it promises (shutdown only sends a signal), so it reports an
	// honest partial and exits 0.
	partial bool
	// bindHolds specializes the predicate for a verb whose post-condition
	// depends on WHAT WAS ASKED FOR — rebuild's --image, resize's --type,
	// attach-iso's <iso>. The OBSERVATION stays argument-free (the receipt
	// reports what the server says now, never the request), so only holds and
	// unmet are bound; hzBoundPost is the one place that binds them. A verb
	// declares bindHolds OR a static holds, never both.
	bindHolds func(want string) (func(*hcloud.Server) bool, func(*hcloud.Server, time.Duration) string)
	// unreadable names a FRESH server on which the post-condition cannot be
	// evaluated at all — rebuild's Image comes back nil for sources the API
	// declines to echo. That is CONFIRMATION UNAVAILABLE (the same escape a
	// failed read-back takes), never a failed verb. Empty string = readable.
	unreadable func(*hcloud.Server) string
}

// hzServerPostConditions maps every verb that reports a completed-verb receipt
// for a server to what it must observe — the nine that funnel through
// runHetznerServerAction AND the flag verbs that carry their own opts struct
// and finish through hzFlagVerbDone (PDS-D366). ONE table, because
// hzActionObserved reads it by name and the success-claim registry rows
// traverse that seam; a sibling map would fork the owner.
// The executor never GUESSES a
// post-condition: a verb missing from this map degrades to the zero hzPost, so
// it still re-reads but asserts nothing and its receipt carries only id/name —
// silently back to the defect this block exists to kill. That degradation is
// why the map is not trusted to be complete: hetzner_cmd_test.go DERIVES the
// verb list from the switch at test time and fails on a verb this map omits
// (and on an entry no verb uses).
var hzServerPostConditions = map[string]hzPost{
	// A — start.
	"poweron": {
		holds:   func(s *hcloud.Server) bool { return s.Status == hcloud.ServerStatusRunning },
		poll:    true,
		observe: hzObserveStatus,
		unmet: func(s *hcloud.Server, w time.Duration) string {
			return fmt.Sprintf("the power-on action completed but the server still reports %q after %s", s.Status, w)
		},
	},
	// B — hard stop.
	"poweroff": {
		holds:   func(s *hcloud.Server) bool { return s.Status == hcloud.ServerStatusOff },
		poll:    true,
		observe: hzObserveStatus,
		unmet: func(s *hcloud.Server, w time.Duration) string {
			return fmt.Sprintf("the power-off action completed but the server still reports %q after %s", s.Status, w)
		},
	},
	// C — no discriminator: narrow, never strengthen.
	"reboot": {observe: hzObserveRestart("reboot")},
	"reset":  {observe: hzObserveRestart("reset")},
	// D — ACPI: the guest has to react, and not reacting yet is not a failure.
	"shutdown": {
		holds:   func(s *hcloud.Server) bool { return s.Status == hcloud.ServerStatusOff },
		poll:    true,
		partial: true,
		observe: hzObserveStatus,
		unmet: func(s *hcloud.Server, w time.Duration) string {
			return fmt.Sprintf("shutdown signal sent; the guest has not powered off after %s (it still reports %q) — "+
				"ACPI needs the guest OS to react, so re-check with `bp cloud hetzner server get %s`", w, s.Status, s.Name)
		},
	},
	// E — metadata flips, settled once the action completes.
	"disable-rescue": {
		holds:   func(s *hcloud.Server) bool { return !s.RescueEnabled },
		observe: hzObserveRescue,
		unmet: func(s *hcloud.Server, _ time.Duration) string {
			return "the disable-rescue action completed but the server still reports rescue mode enabled"
		},
	},
	"enable-backup": {
		holds:   func(s *hcloud.Server) bool { return s.BackupWindow != "" },
		observe: hzObserveBackups,
		unmet: func(s *hcloud.Server, _ time.Duration) string {
			return "the enable-backup action completed but the server reports no backup window"
		},
	},
	"disable-backup": {
		holds:   func(s *hcloud.Server) bool { return s.BackupWindow == "" },
		observe: hzObserveBackups,
		unmet: func(s *hcloud.Server, _ time.Duration) string {
			return fmt.Sprintf("the disable-backup action completed but the server still reports backup window %q", s.BackupWindow)
		},
	},
	"detach-iso": {
		holds:   func(s *hcloud.Server) bool { return s.ISO == nil },
		observe: hzObserveISO,
		unmet: func(s *hcloud.Server, _ time.Duration) string {
			return "the detach-ISO action completed but the server still reports an ISO attached"
		},
	},
	// F — the flag verbs. Like shape E the predicate is a settled field rather
	// than a transient status, but it compares the server against WHAT WAS ASKED
	// FOR, so it is bound at call time. enable-rescue and attach-iso settle
	// instantly and take one read (attach-iso deliberately mirrors detach-iso);
	// rebuild and resize poll — see the note on "rebuild" below.
	// rebuild and resize POLL. The other three settle the instant their action
	// completes, but these two are the longest-running server operations here and
	// the field the receipt reads (Image / ServerType) is populated by the same
	// backend that just finished the action. If that record lags the action by a
	// beat, a ONE-SHOT read reports "the rebuild completed but the server runs a
	// different image" on a rebuild that worked — the identical lie this file
	// exists to kill, pointing the other way. Polling costs NOTHING on agreement:
	// hzReadBack only re-reads while `holds` is false, so the agreeing path is
	// still exactly one GET.
	"rebuild": {
		poll:    true,
		observe: hzObserveImage,
		unreadable: func(s *hcloud.Server) string {
			if s.Image == nil {
				return "the server reports no image after the rebuild, so the image it now runs could not be confirmed"
			}
			return ""
		},
		bindHolds: func(want string) (func(*hcloud.Server) bool, func(*hcloud.Server, time.Duration) string) {
			return func(s *hcloud.Server) bool { return hzImageMatches(s.Image, want) },
				func(s *hcloud.Server, _ time.Duration) string {
					return fmt.Sprintf("the rebuild action completed but the server reports image %s, not the requested %q",
						hzImageName(s.Image), want)
				}
		},
	},
	"resize": {
		poll:    true,
		observe: hzObserveServerType,
		unreadable: func(s *hcloud.Server) string {
			if s.ServerType == nil {
				return "the server reports no type after the resize, so the type it now runs could not be confirmed"
			}
			return ""
		},
		bindHolds: func(want string) (func(*hcloud.Server) bool, func(*hcloud.Server, time.Duration) string) {
			return func(s *hcloud.Server) bool { return hzServerTypeMatches(s.ServerType, want) },
				func(s *hcloud.Server, _ time.Duration) string {
					return fmt.Sprintf("the resize action completed but the server reports type %s, not the requested %q",
						hzServerTypeName(s.ServerType), want)
				}
		},
	},
	"enable-rescue": {
		holds:   func(s *hcloud.Server) bool { return s.RescueEnabled },
		observe: hzObserveRescue,
		unmet: func(s *hcloud.Server, _ time.Duration) string {
			return "the enable-rescue action completed but the server does not report rescue mode enabled"
		},
	},
	"attach-iso": {
		observe: hzObserveISO,
		bindHolds: func(want string) (func(*hcloud.Server) bool, func(*hcloud.Server, time.Duration) string) {
			return func(s *hcloud.Server) bool { return hzISOMatches(s.ISO, want) },
				func(s *hcloud.Server, _ time.Duration) string {
					if s.ISO == nil {
						return "the attach-ISO action completed but the server reports no ISO attached"
					}
					return fmt.Sprintf("the attach-ISO action completed but the server reports ISO %q attached, not the requested %q",
						s.ISO.Name, want)
				}
		},
	},
}

// hzServerPostConditionExemptions names the verbs that report a completed-verb
// receipt in this file and legitimately have NO post-condition on the SERVER —
// with the reason, so an exemption is a stated argument that a reviewer can
// refuse rather than a silent omission. The derivation gate reads this map:
// an exemption for a verb that no longer exists is as much a defect as a
// missing post-condition, and a verb may not be exempt AND keyed.
var hzServerPostConditionExemptions = map[string]string{
	"create": "runHetznerServerCreate already re-reads the server it created — the running+IPv4 poll is its post-condition, " +
		"so its receipt is observation and not a request echo",
	"delete": "a deleted server has no state to re-read: its honest post-condition is a 404 on GET /servers/<id>, " +
		"which the delete action completing already implies",
	// The `instance` verbs (hetzner_instance_cmd.go). They are exempt from the
	// SERVER post-condition table because none of them asserts a state of the
	// server this table describes — each observes something else, and the
	// reason below names WHAT and WHERE, so a reviewer can go read it and
	// refuse the argument. An exemption whose stated reason is false is worse
	// than no exemption at all.
	"archive": "archive changes no field on hcloud.Server — it produces an IMAGE, so its post-condition is on that image and " +
		"instArchive runs it: GET /images/<id> after the snapshot action, polling through `creating`, reported as " +
		"image_status (and confirmation: unavailable when the read cannot settle). It rides the same ground as " +
		"create-image (filed: pds-w26-create-image-image-postcondition). Its receipt also carries a non-optional " +
		"`quiesced`, because a --stop archive whose SSH quiesce failed is a crash-consistent snapshot",
	"resurrect": "the server in a resurrect receipt IS a post-action read-back: instCreateFromArchive polls " +
		"hc.Server.GetByID until the box reports running WITH an IPv4 before returning, and the receipt's health key " +
		"is an observed probe of https://<fqdn>/api/schemas. Residue filed separately: image_id is still a request " +
		"echo and --no-health omits `health` rather than saying it was skipped (pds-w27-bl-hetzner-instance-verb-receipt-residue)",
	"adopt": "the server in an adopt receipt is the CLONE instCloneSwap built and health-gated — created through the same " +
		"running+IPv4 read-back poll, then confirmed against https://<fqdn>/api/schemas before the old box is destroyed. " +
		"Residue filed separately: registry_id/team_id are cp.Adopt response echoes never re-read " +
		"(pds-w27-bl-hetzner-instance-verb-receipt-residue)",
	"eject": "the server in an eject receipt is the health-gated clone (same read-back as adopt); eject's OWN post-condition " +
		"is on the control-plane registry, not on hcloud.Server, and runInstanceEject runs it — it asserts the status " +
		"cp.Deprovision returns is \"removed\" AND re-reads cp.List() to confirm the row is gone, degrading to the " +
		"hzPartial confirmation-unavailable shape when either observation fails",
}

// hzBoundPost resolves the post-condition a verb actually runs: the table entry
// for the argument-free verbs, and the entry with its predicate bound to the
// requested ref for rebuild/resize/attach-iso.
func hzBoundPost(verb, want string) hzPost {
	post := hzServerPostConditions[verb]
	if post.bindHolds == nil {
		return post
	}
	post.holds, post.unmet = post.bindHolds(want)
	return post
}

// hzForeignPostConditions names the verbs whose post-condition is REAL but
// lives on a resource OTHER than the server the receipt names, with the read it
// performs spelled out. It is the third classification the derivation gate
// knows about, and it exists because the other two both lie about create-image:
// keying it in hzServerPostConditions would claim a server field the verb never
// moves, and excusing it in hzServerPostConditionExemptions says "nothing is
// re-read", which stopped being true when the verb learnt to GET /images/<id>.
//
// A verb here is NOT exempt from anything. The entry states what it re-reads;
// the derivation gate refuses a verb that is in two of the three maps at once,
// and refuses an entry naming a verb that emits no receipt, exactly as it does
// for the other two.
var hzForeignPostConditions = map[string]string{
	"create-image": "create-image moves no field on hcloud.Server — it produces an IMAGE, so it re-reads THAT: " +
		"GET /images/<id> once the create action has completed. The receipt carries the OBSERVED image_status, " +
		"image_description and image_ready, never the CreateImage response echo, and a read-back that fails is " +
		"`confirmation: unavailable` at exit 0 — the same escape hzFlagVerbDone takes when only the confirming " +
		"read failed (pds-w26-create-image-image-postcondition)",
}

// hzImageMatches / hzServerTypeMatches / hzISOMatches read the OBSERVED ref the
// same way the request built it: hzImageRef (and hzServerTypeRef, and the
// attach-iso body) send a numeric arg as an id and anything else as a name, so
// the confirmation has to fork on exactly that — a snapshot image carries an
// EMPTY Name, and comparing it to the numeric id the caller typed would
// false-red a rebuild that worked.
func hzImageMatches(img *hcloud.Image, want string) bool {
	if img == nil {
		return false
	}
	if id, err := strconv.ParseInt(want, 10, 64); err == nil {
		return img.ID == id
	}
	return img.Name == want
}

func hzServerTypeMatches(st *hcloud.ServerType, want string) bool {
	if st == nil {
		return false
	}
	if id, err := strconv.ParseInt(want, 10, 64); err == nil {
		return st.ID == id
	}
	return strings.EqualFold(st.Name, want)
}

func hzISOMatches(iso *hcloud.ISO, want string) bool {
	if iso == nil {
		return false
	}
	if id, err := strconv.ParseInt(want, 10, 64); err == nil {
		return iso.ID == id
	}
	return iso.Name == want
}

func hzImageName(img *hcloud.Image) string {
	if img == nil {
		return "none"
	}
	return strconv.Quote(hzImageLabel(img))
}

func hzServerTypeName(st *hcloud.ServerType) string {
	if st == nil {
		return "none"
	}
	return strconv.Quote(st.Name)
}

func hzObserveImage(s *hcloud.Server) map[string]any {
	if s.Image == nil {
		return map[string]any{"image_observed": false}
	}
	return map[string]any{"image_observed": true, "image": hzImageLabel(s.Image), "image_id": s.Image.ID}
}

// hzObserveServerType is the NARROWED resize receipt. `--upgrade-disk` used to
// ride the receipt as a pure request echo ("upgrade_disk: true" whether or not
// a byte of disk moved); hcloud.Server carries no "disk was upgraded" field, so
// the receipt reports the primary disk size it READ and asserts nothing about
// an upgrade having happened.
func hzObserveServerType(s *hcloud.Server) map[string]any {
	row := map[string]any{"primary_disk_size": s.PrimaryDiskSize}
	if s.ServerType != nil {
		row["server_type"] = s.ServerType.Name
		row["server_type_id"] = s.ServerType.ID
	}
	return row
}

func hzObserveRescue(s *hcloud.Server) map[string]any {
	return map[string]any{"rescue_enabled": s.RescueEnabled}
}

func hzObserveStatus(s *hcloud.Server) map[string]any {
	return map[string]any{"status": string(s.Status)}
}

// hzObserveRestart is shape C's narrowed sentence. It reports the status it
// re-read AND states, in the same breath, the thing the receipt does NOT prove:
// the Hetzner API exposes no boot time, so no field can distinguish "rebooted"
// from "never went down".
func hzObserveRestart(verb string) func(*hcloud.Server) map[string]any {
	return func(s *hcloud.Server) map[string]any {
		return map[string]any{
			"status": string(s.Status),
			"confirmed": fmt.Sprintf("the %s action completed and the server now reports %q — "+
				"the API exposes no boot time, so this does not confirm the OS restarted", verb, s.Status),
		}
	}
}

// hzObserveBackups reports the window the SERVER chose: EnableBackup's window
// argument is deprecated and ignored (`_ = window` in the SDK), so re-reading it
// is both the post-condition and the only way an owner learns when backups run.
func hzObserveBackups(s *hcloud.Server) map[string]any {
	return map[string]any{"backups_enabled": s.BackupWindow != "", "backup_window": s.BackupWindow}
}

func hzObserveISO(s *hcloud.Server) map[string]any {
	row := map[string]any{"iso_attached": s.ISO != nil}
	if s.ISO != nil {
		row["iso"] = s.ISO.Name
	}
	return row
}

// hzActionObserved is the receipt payload one action verb carries, read off the
// FRESH server. runHetznerServerAction and the success-claim registry both go
// through it, so the enrolled row probes the REAL call shape instead of a
// hand-injected map no verb ever passes.
func hzActionObserved(verb string, srv *hcloud.Server) map[string]any {
	post, ok := hzServerPostConditions[verb]
	if !ok || post.observe == nil || srv == nil {
		return nil
	}
	return post.observe(srv)
}

// hzActionWindow is the wall-clock the bounded read-back spans. Derived, not
// hard-coded, so the honest-partial sentence stays true when tests shrink the
// poll interval.
func hzActionWindow() time.Duration {
	return time.Duration(hetznerActionPollMax) * hetznerCreatePoll
}

// hzReadBack re-reads the server after an action, polling while the
// post-condition is unsettled. An error here means CONFIRMATION is unavailable,
// never that the verb failed — the caller must not convert it into one.
func hzReadBack(ctx context.Context, hc *hcloud.Client, id int64, post hzPost) (*hcloud.Server, error) {
	fresh, _, err := hc.Server.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if fresh == nil {
		return nil, fmt.Errorf("server %d is no longer readable", id)
	}
	if !post.poll || post.holds == nil {
		return fresh, nil
	}
	for i := 0; i < hetznerActionPollMax && !post.holds(fresh); i++ {
		time.Sleep(hetznerCreatePoll)
		next, _, gerr := hc.Server.GetByID(ctx, id)
		if gerr != nil {
			return nil, gerr
		}
		if next != nil {
			fresh = next
		}
	}
	return fresh, nil
}

// hzPartial reports a verb that did everything it promises without the owner's
// end state having arrived — today only ACPI shutdown, where a guest that has
// not reacted inside the window is a slow guest, not a failed verb. It is
// deliberately NOT a ✓: the receipt says what was sent and what was observed.
func hzPartial(out *writer, action string, srv *hcloud.Server, note string, extra map[string]any) int {
	payload := map[string]any{
		"ok":       true,
		"action":   action,
		"complete": false,
		"note":     note,
		"server":   map[string]any{"id": srv.ID, "name": srv.Name},
	}
	for k, v := range extra {
		payload[k] = v
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("⚠ %s — server %s (id %d): %s", action, srv.Name, srv.ID, note)
	keys := make([]string, 0, len(extra))
	for k := range extra {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out.outf("  %s: %s", k, cellString(extra[k]))
	}
	return exitOK
}

// runHetznerServerAction is the shared executor for the flag-less action verbs
// (poweron/poweroff/reboot/…): resolve the server, fire the action, WAIT it to
// completion, RE-READ the server, and report the state it observed — see the
// hzPost block above for why every one of those steps is load-bearing.
func runHetznerServerAction(out *writer, g globals, verb string, args []string, act func(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server) (*hcloud.Action, error)) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner server "+verb+" <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, err := resolveHzServer(ctx, hc, target)
	if err != nil {
		return hzFail(out, verb+" server", errOrNotFound(err))
	}
	action, err := act(ctx, hc, srv)
	if err != nil {
		return hzFail(out, verb+" server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, verb+" server "+srv.Name+": action failed", werr)
	}

	post := hzServerPostConditions[verb]
	fresh, rerr := hzReadBack(ctx, hc, srv.ID, post)
	if rerr != nil {
		// The action was fired AND waited to success; only the confirming read
		// failed. Say exactly that — reporting it as a failed verb would be the
		// same lie in the opposite direction.
		return hzDone(out, verb, srv, map[string]any{
			"confirmation":       "unavailable",
			"confirmation_error": rerr.Error(),
		})
	}
	extra := hzActionObserved(verb, fresh)
	if post.holds != nil && !post.holds(fresh) {
		note := post.unmet(fresh, hzActionWindow())
		if post.partial {
			return hzPartial(out, verb, fresh, note, extra)
		}
		return useError(out, "failed", verb+" server "+fresh.Name+": "+note, exitGeneric)
	}
	return hzDone(out, verb, fresh, extra)
}

// hzFlagVerbDone finishes a flag-carrying server verb (rebuild, resize,
// enable-rescue, attach-iso). Those four cannot ride runHetznerServerAction —
// each has its own opts struct, its own response payload and its own
// confirmation prompt — but the receipt obligation is IDENTICAL: never report
// the server that was resolved before the action fired. So the re-read, the
// confirmation-unavailable escape and the unmet sentence live here and read the
// same hzServerPostConditions table the executor reads.
//
// `extra` is the response-sourced part of the receipt — today only the root
// password from rebuild and enable-rescue, which the API never re-exposes and
// which therefore CANNOT come from a read-back. Everything else in the receipt
// is observed.
func hzFlagVerbDone(ctx context.Context, out *writer, hc *hcloud.Client, verb string, srv *hcloud.Server, want string, extra map[string]any) int {
	post := hzBoundPost(verb, want)
	fresh, rerr := hzReadBack(ctx, hc, srv.ID, post)
	if rerr != nil {
		// The action was fired AND waited to success; only the confirming read
		// failed. Same escape runHetznerServerAction takes, for the same reason.
		return hzDone(out, verb, srv, hzMergeExtra(extra, map[string]any{
			"confirmation":       "unavailable",
			"confirmation_error": rerr.Error(),
		}))
	}
	if post.unreadable != nil {
		if why := post.unreadable(fresh); why != "" {
			return hzDone(out, verb, fresh, hzMergeExtra(extra, map[string]any{
				"confirmation":       "unavailable",
				"confirmation_error": why,
			}))
		}
	}
	observed := hzActionObserved(verb, fresh)
	if post.holds != nil && !post.holds(fresh) {
		return useError(out, "failed", verb+" server "+fresh.Name+": "+post.unmet(fresh, hzActionWindow()), exitGeneric)
	}
	return hzDone(out, verb, fresh, hzMergeExtra(extra, observed))
}

// hzMergeExtra combines the response-sourced and the observed halves of a
// receipt into one payload, without mutating either.
func hzMergeExtra(a, b map[string]any) map[string]any {
	merged := make(map[string]any, len(a)+len(b))
	for k, v := range a {
		merged[k] = v
	}
	for k, v := range b {
		merged[k] = v
	}
	return merged
}

func runHetznerServerRebuild(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner server rebuild <id|name> --image <img> [--yes]"
	a, err := parseHzArgs(args, []string{"image"}, []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("image") == "" {
		return useError(out, "usage", "want <id|name> and --image <img> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, rerr := resolveHzServer(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "rebuild server", errOrNotFound(rerr))
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "the disk contents of server", srv.Name, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	result, _, err := hc.Server.RebuildWithResult(ctx, srv, hcloud.ServerRebuildOpts{Image: hzImageRef(a.val("image"))})
	if err != nil {
		return hzFail(out, "rebuild server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "rebuild server "+srv.Name+": action failed", werr)
	}
	// The root password is response-only — the API never re-exposes it — so it
	// is the one field that legitimately cannot be observed. The image is NOT:
	// it used to be echoed back from --image, and is now read off the server.
	extra := map[string]any{}
	if result.RootPassword != "" {
		extra["root_password"] = result.RootPassword
	}
	return hzFlagVerbDone(ctx, out, hc, "rebuild", srv, a.val("image"), extra)
}

func runHetznerServerResize(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner server resize <id|name> --type <t> [--upgrade-disk]"
	a, err := parseHzArgs(args, []string{"type"}, []string{"upgrade-disk"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("type") == "" {
		return useError(out, "usage", "want <id|name> and --type <t> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, rerr := resolveHzServer(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "resize server", errOrNotFound(rerr))
	}
	action, _, err := hc.Server.ChangeType(ctx, srv, hcloud.ServerChangeTypeOpts{
		ServerType:  hzServerTypeRef(a.val("type")),
		UpgradeDisk: a.bools["upgrade-disk"],
	})
	if err != nil {
		return hzFail(out, "resize server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "resize server "+srv.Name+": action failed", werr)
	}
	return hzFlagVerbDone(ctx, out, hc, "resize", srv, a.val("type"), nil)
}

func runHetznerServerEnableRescue(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner server enable-rescue <id|name> [--ssh-key <k>[,<k>…]]"
	a, err := parseHzArgs(args, []string{"ssh-key"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, rerr := resolveHzServer(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "enable-rescue server", errOrNotFound(rerr))
	}
	keys, kerr := resolveHzSSHKeys(ctx, hc, a.list("ssh-key"))
	if kerr != nil {
		return hzFail(out, "enable-rescue server "+srv.Name, errOrNotFound(kerr))
	}
	result, _, err := hc.Server.EnableRescue(ctx, srv, hcloud.ServerEnableRescueOpts{
		Type:    hcloud.ServerRescueTypeLinux64,
		SSHKeys: keys,
	})
	if err != nil {
		return hzFail(out, "enable-rescue server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "enable-rescue server "+srv.Name+": action failed", werr)
	}
	// The root password is the ONLY way into rescue without a key; it is never
	// retrievable again, so it must ride in the receipt.
	extra := map[string]any{}
	if result.RootPassword != "" {
		extra["root_password"] = result.RootPassword
	}
	return hzFlagVerbDone(ctx, out, hc, "enable-rescue", srv, "", extra)
}

func runHetznerServerCreateImage(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner server create-image <id|name> --description <d> [--type snapshot|backup]"
	a, err := parseHzArgs(args, []string{"description", "type"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("description") == "" {
		return useError(out, "usage", "want <id|name> and --description <d> (usage: "+usage+")", exitUsage)
	}
	imgType := hcloud.ImageTypeSnapshot
	switch a.val("type") {
	case "", "snapshot":
	case "backup":
		imgType = hcloud.ImageTypeBackup
	default:
		return useError(out, "usage", fmt.Sprintf("invalid --type %q (want snapshot|backup)", a.val("type")), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, rerr := resolveHzServer(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "create-image", errOrNotFound(rerr))
	}
	result, _, err := hc.Server.CreateImage(ctx, srv, &hcloud.ServerCreateImageOpts{
		Type:        imgType,
		Description: hcloud.Ptr(a.val("description")),
	})
	if err != nil {
		return hzFail(out, "create-image for server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create-image for server "+srv.Name+": action failed", werr)
	}
	// THE POST-CONDITION, on the IMAGE — see hzForeignPostConditions["create-image"].
	// The action completing says the snapshot JOB finished, not that an image
	// exists in a state anyone can use, so the id the response handed back is
	// RE-READ and the receipt reports what that read observed.
	return hzDone(out, "create-image", srv, hzCreateImageObserved(ctx, hc, result.Image, imgType))
}

// hzCreateImageObserved builds the IMAGE half of a create-image receipt by
// re-reading the image the action produced.
//
// WHAT EACH OUTCOME SAYS, AND WHY IT SAYS IT
//
//   - THE READ CONFIRMS. image_status and image_description are the values
//     GET /images/<id> reported, not the ones CreateImage echoed, and
//     image_ready is the status compared against `available`. A snapshot that
//     never materialised therefore CANNOT print the same receipt as one that
//     did — which is the entire defect this replaced.
//   - THE IMAGE IS STILL `creating`. Not a failure and not ready: the status is
//     reported verbatim with image_ready false. Nothing in the receipt says the
//     snapshot can be restored from, because at that moment it cannot.
//   - THE READ FAILS. The action was fired AND waited to success; only the
//     confirming read failed, so this is `confirmation: unavailable` at exit 0
//     — the same escape, and the same two keys, hzFlagVerbDone takes. image_id
//     is still reported because it is the only handle the operator has, but
//     NOTHING is claimed about the image's state.
//
// Unlike instArchive this does not POLL through `creating`: nothing downstream
// boots from this image, so making the operator wait buys nothing an honest
// `image_status: creating` does not already tell them.
func hzCreateImageObserved(ctx context.Context, hc *hcloud.Client, img *hcloud.Image, imgType hcloud.ImageType) map[string]any {
	extra := map[string]any{"type": string(imgType)}
	if img == nil {
		extra["confirmation"] = "unavailable"
		extra["confirmation_error"] = "the create-image action completed but the response named no image, " +
			"so there is no id to re-read"
		return extra
	}
	extra["image_id"] = img.ID
	fresh, _, gerr := hc.Image.GetByID(ctx, img.ID)
	switch {
	case gerr != nil:
		extra["confirmation"] = "unavailable"
		extra["confirmation_error"] = fmt.Sprintf("image %d could not be re-read: %v", img.ID, gerr)
	case fresh == nil:
		extra["confirmation"] = "unavailable"
		extra["confirmation_error"] = fmt.Sprintf("the create-image action completed but GET /images/%d reports "+
			"no such image, so nothing confirms the snapshot exists", img.ID)
	default:
		extra["image_id"] = fresh.ID
		extra["image_status"] = string(fresh.Status)
		extra["image_description"] = fresh.Description
		extra["image_ready"] = fresh.Status == hcloud.ImageStatusAvailable
		if fresh.Type != "" {
			extra["type"] = string(fresh.Type)
		}
	}
	return extra
}

func runHetznerServerAttachISO(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner server attach-iso <id|name> <iso>"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 2 {
		return useError(out, "usage", "want <id|name> and <iso> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, rerr := resolveHzServer(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "attach-iso", errOrNotFound(rerr))
	}
	iso := &hcloud.ISO{Name: a.pos[1]}
	if id, perr := strconv.ParseInt(a.pos[1], 10, 64); perr == nil {
		iso = &hcloud.ISO{ID: id}
	}
	action, _, err := hc.Server.AttachISO(ctx, srv, iso)
	if err != nil {
		return hzFail(out, "attach-iso to server "+srv.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "attach-iso to server "+srv.Name+": action failed", werr)
	}
	return hzFlagVerbDone(ctx, out, hc, "attach-iso", srv, a.pos[1], nil)
}

func runHetznerServerIP(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner server ip <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	srv, err := resolveHzServer(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "server ip", errOrNotFound(err))
	}
	ip := hzIPv4(srv)
	if ip == "" {
		return useError(out, "failed", fmt.Sprintf("server %s has no public IPv4", srv.Name), exitGeneric)
	}
	// Only an EXPLICIT -o json/yaml gets the envelope; the piped default must stay
	// the bare IP so `ssh root@$(bp cloud hetzner server ip web-1)` (stdout is a
	// pipe inside $(...)) keeps working.
	if out.outputExplicit && (out.output == "json" || out.output == "yaml") &&
		out.emitStructured(map[string]any{"ip": ip, "server": map[string]any{"id": srv.ID, "name": srv.Name}}) {
		return exitOK
	}
	// Bare IP on the human path too: `ssh root@$(bp cloud hetzner server ip web-1)`.
	out.outf("%s", ip)
	return exitOK
}
