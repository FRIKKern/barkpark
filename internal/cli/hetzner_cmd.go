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
	case "status":
		return runCloudStatus(out, g, args[1:])
	case "open":
		return runCloudOpen(out, g, args[1:])
	case "webhook", "webhooks":
		return runCloudWebhook(out, g, args[1:])
	case "verify":
		return runCloudVerify(out, g, args[1:])
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
	line := func(cells []string) string {
		parts := make([]string, len(cells))
		for i, c := range cells {
			parts[i] = runewidth.FillRight(c, widths[i])
		}
		return strings.TrimRight(strings.Join(parts, "  "), " ")
	}
	out.outf("%s", line(headers))
	for _, r := range rows {
		out.outf("%s", line(r))
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

// runHetznerServerAction is the shared executor for the flag-less action verbs
// (poweron/poweroff/reboot/…): resolve the server, fire the action, WAIT it to
// completion, report.
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
	return hzDone(out, verb, srv, nil)
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
	extra := map[string]any{"image": a.val("image")}
	if result.RootPassword != "" {
		extra["root_password"] = result.RootPassword
	}
	return hzDone(out, "rebuild", srv, extra)
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
	return hzDone(out, "resize", srv, map[string]any{
		"type":         a.val("type"),
		"upgrade_disk": a.bools["upgrade-disk"],
	})
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
	return hzDone(out, "enable-rescue", srv, extra)
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
	extra := map[string]any{"type": string(imgType)}
	if result.Image != nil {
		extra["image_id"] = result.Image.ID
	}
	return hzDone(out, "create-image", srv, extra)
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
	return hzDone(out, "attach-iso", srv, map[string]any{"iso": a.pos[1]})
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
