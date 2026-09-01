package cli

// hetzner_net_cmd.go is the storage + networking third of the PR3 resources:
//
//	bp cloud hetzner volume    list · get · create · delete · attach · detach ·
//	                           resize · change-protection
//	bp cloud hetzner network   list · get · create · delete · add-subnet ·
//	                           delete-subnet · add-route · delete-route ·
//	                           change-ip-range
//	bp cloud hetzner firewall  list · get · create · delete · set-rules ·
//	                           apply-to-resource · remove-from-resource
//
// plus the PR3-wide plumbing every new resource funnels through: the generic
// id-or-name resolver (hzResolve) and the generic mutation receipt (hzResDone).
// The framework conventions (parseHzArgs, hzWait, hzFail, renderHzTable) live
// in hetzner_cmd.go; the load-balancer/IP/placement/certificate resources in
// hetzner_lb_cmd.go; DNS in hetzner_dns_cmd.go.

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// ---------------------------------------------------------------------------
// PR3-wide plumbing
// ---------------------------------------------------------------------------

// hzResolve looks a resource up by numeric id or name via the SDK's Get,
// translating the SDK's nil,nil miss into a named not-found error — the
// resolveHzServer contract, generalised for every PR3 resource. listCmd is the
// remediation the error points at.
func hzResolve[T any](ctx context.Context, get func(context.Context, string) (*T, *hcloud.Response, error), kind, idOrName, listCmd string) (*T, error) {
	v, _, err := get(ctx, idOrName)
	if err != nil {
		return nil, err
	}
	if v == nil {
		return nil, fmt.Errorf("%s %q not found (see `%s`)", kind, idOrName, listCmd)
	}
	return v, nil
}

// hzResDone reports a completed mutating verb on a non-server resource:
// `{ok, action, <kind>: {id, name}, …extra}` on json/yaml, a ✓ line (plus
// sorted extra key: value lines) on the table view — the hzDone shape with the
// resource kind as the payload key so scripts can key on it.
func hzResDone(out *writer, action, kind string, id any, name string, extra map[string]any) int {
	payload := map[string]any{
		"ok":                  true,
		"action":              action,
		hzResPayloadKey(kind): map[string]any{"id": id, "name": name},
	}
	for k, v := range extra {
		payload[k] = v
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("✓ %s — %s %s (id %v)", action, kind, name, id)
	hzResPrintExtra(out, extra)
	return exitOK
}

// hzCIDR parses a --flag CIDR value with a usage-grade error message.
func hzCIDR(s, flag string) (*net.IPNet, error) {
	_, ipnet, err := net.ParseCIDR(s)
	if err != nil {
		return nil, fmt.Errorf("invalid %s %q (want CIDR notation like 10.0.0.0/16)", flag, s)
	}
	return ipnet, nil
}

// hzCreated formats a resource's Created stamp for structured rows.
func hzCreated(t time.Time) (string, bool) {
	if t.IsZero() {
		return "", false
	}
	return t.UTC().Format(time.RFC3339), true
}

// ---------------------------------------------------------------------------
// volume
// ---------------------------------------------------------------------------

// THE VOLUME / NETWORK / FIREWALL OBSERVERS (PDS wave 32, the last of the debt)
// ----------------------------------------------------------------------------
// Every hcloud ACTION endpoint returns `{action}` and nothing else, so for the
// mutating verbs here the SINGLE-RESOURCE GET on the RESOLVED id is the only
// server-side source there is. Each observer below is handed the FRESH resource
// and reports what it says — never the flag the operator typed.
//
// THE POLARITY IS THE WHOLE POINT (PDS-D415). These plug into hzResObserved,
// whose (nil, nil) branch REFUSES; hzResDestroyed's means the opposite. Two
// v2.44 read paths swallow a 404 into `(nil, resp, nil)` verbatim — Zone's
// getByIDOrName (zone.go) and GetRRSetByNameAndType (zone_rrset.go) — and the
// hcloud GetByID readers here do the same, which is exactly the shape
// hzResGoneRead[T] models. Paying any of these with the destroy helper would
// emit `confirmed_gone:true` on a create.
//
// THE PAIRED DIRECTIONS (add-subnet/delete-subnet, add-route/delete-route,
// apply-to-resource/remove-from-resource, attach/detach) each get an explicit
// PRESENT and ABSENT observer rather than one predicate with a boolean: NO ARM
// OF THE RECEIPT CENSUS READS THE DIRECTION BRANCH, so a payment that confirms
// "present" on both arms of a pair is fully green there. Only the both-direction
// fakes in hetzner_net_cmd_test.go can catch that, which is why they exist.

// hzVolumeServerID reports the server a volume is attached to. One reader, so
// the attach and detach observers cannot disagree about what "attached" means.
func hzVolumeServerID(vol *hcloud.Volume) (int64, bool) {
	if vol.Server == nil {
		return 0, false
	}
	return vol.Server.ID, true
}

// hzObserveVolumeCreated reads the create receipt off the create RESPONSE
// object, which for a create IS server truth: the linux device and the settled
// status are things nobody typed.
func hzObserveVolumeCreated(vol *hcloud.Volume) hzResObservation {
	extra := map[string]any{"size_gb": vol.Size}
	if vol.Status != "" {
		extra["status"] = string(vol.Status)
	}
	if vol.LinuxDevice != "" {
		extra["linux_device"] = vol.LinuxDevice
	}
	if vol.Location != nil {
		extra["location"] = vol.Location.Name
	}
	return hzResAgrees(extra)
}

// hzObserveVolumeAttached confirms attach against the RESOLVED server id — a
// volume's nested server ref carries an id and, on a live read, no name at all
// (PDS-D399 trap (a)), so the human name rides through the call site's extra.
func hzObserveVolumeAttached(serverID int64) hzResObserveFn[hcloud.Volume] {
	return func(vol *hcloud.Volume) hzResObservation {
		got, attached := hzVolumeServerID(vol)
		if !attached {
			return hzResDisagrees("server", "no server at all", fmt.Sprintf("server id %d", serverID))
		}
		if got != serverID {
			return hzResDisagrees("server", fmt.Sprintf("server id %d", got), fmt.Sprintf("server id %d", serverID))
		}
		return hzResAgrees(map[string]any{"attached": true, "server_id": got, "status": string(vol.Status)})
	}
}

// hzObserveVolumeDetached is the inverse: the volume must now report no server.
func hzObserveVolumeDetached(vol *hcloud.Volume) hzResObservation {
	if id, attached := hzVolumeServerID(vol); attached {
		return hzResDisagrees("server", fmt.Sprintf("STILL attached to server id %d", id), "no server")
	}
	return hzResAgrees(map[string]any{"attached": false, "status": string(vol.Status)})
}

// hzObserveVolumeSize confirms resize by reading the size the volume NOW
// reports. A volume only grows, so a short read is a real post-condition miss.
func hzObserveVolumeSize(want int) hzResObserveFn[hcloud.Volume] {
	return func(vol *hcloud.Volume) hzResObservation {
		if vol.Size != want {
			return hzResDisagrees("size_gb", strconv.Itoa(vol.Size), strconv.Itoa(want))
		}
		return hzResAgrees(map[string]any{"size_gb": vol.Size})
	}
}

// hzObserveVolumeProtection confirms change-protection off the volume's own
// protection block, not the flag that asked for it.
func hzObserveVolumeProtection(want bool) hzResObserveFn[hcloud.Volume] {
	return func(vol *hcloud.Volume) hzResObservation {
		if vol.Protection.Delete != want {
			return hzResDisagrees("delete_protection", strconv.FormatBool(vol.Protection.Delete), strconv.FormatBool(want))
		}
		return hzResAgrees(map[string]any{"delete_protection": vol.Protection.Delete})
	}
}

func runHetznerVolume(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerVolumeHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing volume command (run `bp cloud hetzner volume -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerVolumeList(out, g, rest)
	case "get", "show":
		return runHetznerVolumeGet(out, g, rest)
	case "create":
		return runHetznerVolumeCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerVolumeDelete(out, g, rest)
	case "attach":
		return runHetznerVolumeAttach(out, g, rest)
	case "detach":
		return runHetznerVolumeDetach(out, g, rest)
	case "resize":
		return runHetznerVolumeResize(out, g, rest)
	case "change-protection":
		return runHetznerVolumeChangeProtection(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown volume command %q (run `bp cloud hetzner volume -h` for usage)", verb), exitUsage)
	}
}

func resolveHzVolume(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.Volume, error) {
	return hzResolve(ctx, hc.Volume.Get, "volume", idOrName, "bp cloud hetzner volume list")
}

// hzVolumeRow is the structured (json/yaml) shape of one volume.
func hzVolumeRow(v *hcloud.Volume) map[string]any {
	row := map[string]any{
		"id":      v.ID,
		"name":    v.Name,
		"size_gb": v.Size,
		"status":  string(v.Status),
	}
	if v.Location != nil {
		row["location"] = v.Location.Name
	}
	if v.Server != nil {
		row["server_id"] = v.Server.ID
	}
	if v.Format != nil && *v.Format != "" {
		row["format"] = *v.Format
	}
	if v.LinuxDevice != "" {
		row["linux_device"] = v.LinuxDevice
	}
	if v.Protection.Delete {
		row["delete_protection"] = true
	}
	if created, ok := hzCreated(v.Created); ok {
		row["created"] = created
	}
	if len(v.Labels) > 0 {
		row["labels"] = v.Labels
	}
	return row
}

func runHetznerVolumeList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner volume list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	vols, err := c.HCloud().Volume.AllWithOpts(hetznerCtx(), hcloud.VolumeListOpts{})
	if err != nil {
		return hzFail(out, "list volumes", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(vols))
		for _, v := range vols {
			rows = append(rows, hzVolumeRow(v))
		}
		out.emitStructured(map[string]any{"volumes": rows})
		return exitOK
	}
	if len(vols) == 0 {
		out.outf("no volumes in this project — create one with 'bp cloud hetzner volume create --name <n> --size <gb> --location <loc>'")
		return exitOK
	}
	rows := make([][]string, 0, len(vols))
	for _, v := range vols {
		loc, srv := "", ""
		if v.Location != nil {
			loc = v.Location.Name
		}
		if v.Server != nil {
			srv = strconv.FormatInt(v.Server.ID, 10)
		}
		rows = append(rows, []string{
			strconv.FormatInt(v.ID, 10),
			hzCell(v.Name),
			fmt.Sprintf("%d GB", v.Size),
			hzCell(string(v.Status)),
			hzCell(loc),
			hzCell(srv),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "SIZE", "STATUS", "LOCATION", "SERVER"}, rows)
	return exitOK
}

func runHetznerVolumeGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner volume get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	vol, err := resolveHzVolume(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get volume", errOrNotFound(err))
	}
	row := hzVolumeRow(vol)
	if out.emitStructured(map[string]any{"volume": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerVolumeCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner volume create --name <n> --size <gb> (--location <loc> | --server <s>) [--format ext4|xfs] [--automount] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "size", "location", "server", "format", "label"}, []string{"automount"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := a.val("name")
	if name == "" || a.val("size") == "" {
		return useError(out, "usage", "--name and --size are required (usage: "+usage+")", exitUsage)
	}
	size, serr := strconv.Atoi(a.val("size"))
	if serr != nil || size <= 0 {
		return useError(out, "usage", fmt.Sprintf("invalid --size %q (want GB as a positive integer)", a.val("size")), exitUsage)
	}
	if (a.val("location") == "") == (a.val("server") == "") {
		return useError(out, "usage", "want exactly one of --location or --server (usage: "+usage+")", exitUsage)
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

	opts := hcloud.VolumeCreateOpts{Name: name, Size: size, Labels: labels}
	if loc := a.val("location"); loc != "" {
		opts.Location = &hcloud.Location{Name: loc}
	} else {
		srv, rerr := resolveHzServer(ctx, hc, a.val("server"))
		if rerr != nil {
			return hzFail(out, "create volume", errOrNotFound(rerr))
		}
		opts.Server = srv
	}
	if f := a.val("format"); f != "" {
		opts.Format = hcloud.Ptr(f)
	}
	if a.bools["automount"] {
		opts.Automount = hcloud.Ptr(true)
	}

	result, _, err := hc.Volume.Create(ctx, opts)
	if err != nil {
		return hzFail(out, "create volume "+name, err)
	}
	if result.Volume == nil {
		return useError(out, "failed", "create volume "+name+": the API returned no volume", exitGeneric)
	}
	out.info("volume %s accepted — waiting for the create action(s)…", name)
	actions := append([]*hcloud.Action{result.Action}, result.NextActions...)
	if werr := hzWait(ctx, hc, actions...); werr != nil {
		return hzFail(out, "create volume "+name+": create action failed", werr)
	}
	// CLASS A2: the create RESPONSE object is server truth, so the receipt is
	// read off it and carries no request-only extra beside it.
	return hzResObservedResponse(out, "create", "volume", result.Volume.ID, result.Volume.Name,
		nil, result.Volume, hzObserveVolumeCreated)
}

func runHetznerVolumeDelete(out *writer, g globals, args []string) int {
	target, yes, ok := hzOneTargetYes(out, args, "bp cloud hetzner volume delete <id|name> [--yes]")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	vol, err := resolveHzVolume(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete volume", errOrNotFound(err))
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "volume", vol.Name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if _, derr := hc.Volume.Delete(ctx, vol); derr != nil {
		return hzFail(out, "delete volume "+vol.Name, derr)
	}
	// PDS-D400: the gone-check binds to vol.ID — the id ALREADY RESOLVED — and
	// never re-runs `target`, which a volume merely NAMED "42" would hijack.
	return hzResDestroyed(out, ctx, "delete", "volume", vol.ID, vol.Name, nil,
		func(c context.Context) (*hcloud.Volume, *hcloud.Response, error) { return hc.Volume.GetByID(c, vol.ID) })
}

func runHetznerVolumeAttach(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner volume attach <id|name> --server <s> [--automount]"
	a, err := parseHzArgs(args, []string{"server"}, []string{"automount"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("server") == "" {
		return useError(out, "usage", "want <id|name> and --server <s> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	vol, rerr := resolveHzVolume(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "attach volume", errOrNotFound(rerr))
	}
	srv, rerr := resolveHzServer(ctx, hc, a.val("server"))
	if rerr != nil {
		return hzFail(out, "attach volume "+vol.Name, errOrNotFound(rerr))
	}
	opts := hcloud.VolumeAttachOpts{Server: srv}
	if a.bools["automount"] {
		opts.Automount = hcloud.Ptr(true)
	}
	action, _, err := hc.Volume.AttachWithOpts(ctx, vol, opts)
	if err != nil {
		return hzFail(out, "attach volume "+vol.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "attach volume "+vol.Name+": action failed", werr)
	}
	// The action endpoint returns `{action}` and nothing else, so the
	// single-resource GET on the RESOLVED id is the only server-side source.
	// srv.Name rides through `extra` — the sanctioned trap-(a) carve-out: it is
	// the name the RESOLVE read returned for the id being compared, not argv.
	return hzResObserved(out, ctx, "attach", "volume", vol.ID, vol.Name, map[string]any{"server": srv.Name},
		func(c context.Context) (*hcloud.Volume, *hcloud.Response, error) { return hc.Volume.GetByID(c, vol.ID) },
		hzObserveVolumeAttached(srv.ID))
}

func runHetznerVolumeDetach(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner volume detach <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	vol, err := resolveHzVolume(ctx, hc, target)
	if err != nil {
		return hzFail(out, "detach volume", errOrNotFound(err))
	}
	action, _, err := hc.Volume.Detach(ctx, vol)
	if err != nil {
		return hzFail(out, "detach volume "+vol.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "detach volume "+vol.Name+": action failed", werr)
	}
	return hzResObserved(out, ctx, "detach", "volume", vol.ID, vol.Name, nil,
		func(c context.Context) (*hcloud.Volume, *hcloud.Response, error) { return hc.Volume.GetByID(c, vol.ID) },
		hzObserveVolumeDetached)
}

func runHetznerVolumeResize(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner volume resize <id|name> --size <gb>"
	a, err := parseHzArgs(args, []string{"size"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("size") == "" {
		return useError(out, "usage", "want <id|name> and --size <gb> (usage: "+usage+")", exitUsage)
	}
	size, serr := strconv.Atoi(a.val("size"))
	if serr != nil || size <= 0 {
		return useError(out, "usage", fmt.Sprintf("invalid --size %q (want GB as a positive integer; volumes only grow)", a.val("size")), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	vol, rerr := resolveHzVolume(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "resize volume", errOrNotFound(rerr))
	}
	action, _, err := hc.Volume.Resize(ctx, vol, size)
	if err != nil {
		return hzFail(out, "resize volume "+vol.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "resize volume "+vol.Name+": action failed", werr)
	}
	return hzResObserved(out, ctx, "resize", "volume", vol.ID, vol.Name, nil,
		func(c context.Context) (*hcloud.Volume, *hcloud.Response, error) { return hc.Volume.GetByID(c, vol.ID) },
		hzObserveVolumeSize(size))
}

// hzProtectionFlag parses the shared change-protection tail: exactly one of
// --enable/--disable, returning the desired protection state.
func hzProtectionFlag(a *hzArgs, usage string) (bool, error) {
	if a.bools["enable"] == a.bools["disable"] {
		return false, fmt.Errorf("want exactly one of --enable or --disable (usage: %s)", usage)
	}
	return a.bools["enable"], nil
}

func runHetznerVolumeChangeProtection(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner volume change-protection <id|name> (--enable | --disable)"
	a, err := parseHzArgs(args, nil, []string{"enable", "disable"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
	}
	protect, perr := hzProtectionFlag(a, usage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	vol, rerr := resolveHzVolume(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "change-protection volume", errOrNotFound(rerr))
	}
	action, _, err := hc.Volume.ChangeProtection(ctx, vol, hcloud.VolumeChangeProtectionOpts{Delete: hcloud.Ptr(protect)})
	if err != nil {
		return hzFail(out, "change-protection volume "+vol.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "change-protection volume "+vol.Name+": action failed", werr)
	}
	return hzResObserved(out, ctx, "change-protection", "volume", vol.ID, vol.Name, nil,
		func(c context.Context) (*hcloud.Volume, *hcloud.Response, error) { return hc.Volume.GetByID(c, vol.ID) },
		hzObserveVolumeProtection(protect))
}

// ---------------------------------------------------------------------------
// network
// ---------------------------------------------------------------------------

// hzNetIPNet renders a *net.IPNet for a receipt, tolerating the nil the SDK
// hands back for a field the API omitted.
func hzNetIPNet(n *net.IPNet) string {
	if n == nil {
		return ""
	}
	return n.String()
}

// hzNetworkSubnetSummary describes the subnets a network NOW carries, so a
// refusal says what IS there instead of only what is not.
func hzNetworkSubnetSummary(netw *hcloud.Network) []string {
	seen := make([]string, 0, len(netw.Subnets))
	for _, s := range netw.Subnets {
		seen = append(seen, fmt.Sprintf("%s %s in %s", s.Type, hzNetIPNet(s.IPRange), s.NetworkZone))
	}
	return seen
}

// hzNetworkRouteSummary is the same for routes.
func hzNetworkRouteSummary(netw *hcloud.Network) []string {
	seen := make([]string, 0, len(netw.Routes))
	for _, r := range netw.Routes {
		seen = append(seen, fmt.Sprintf("%s via %s", hzNetIPNet(r.Destination), r.Gateway))
	}
	return seen
}

// hzNetworkSubnetMatch identifies ONE subnet. add-subnet may omit --ip-range
// (the API picks one), so an empty ipRange matches on type+zone alone and the
// receipt reports the range the API CHOSE.
type hzNetworkSubnetMatch struct {
	subnetType  hcloud.NetworkSubnetType
	networkZone hcloud.NetworkZone
	ipRange     string
	describe    string
}

func (m hzNetworkSubnetMatch) matches(s hcloud.NetworkSubnet) bool {
	if m.ipRange != "" {
		return hzNetIPNet(s.IPRange) == m.ipRange
	}
	return s.Type == m.subnetType && s.NetworkZone == m.networkZone
}

// hzObserveNetworkCreated reads the create receipt off the create RESPONSE
// object. The ADVISORY pair is the POST-hzCIDR token (PDS-D432 + wave 32):
// hzCIDR is bare net.ParseCIDR and MASKS HOST BITS, so enrolling the raw
// --ip-range flag would advise `you asked for 10.0.0.5/16, the server reports
// 10.0.0.0/16` on a create that did exactly what was asked. The normalised
// token is what actually left the client, so that is what is compared.
func hzObserveNetworkCreated(askedIPRange string) hzResObserveFn[hcloud.Network] {
	return func(netw *hcloud.Network) hzResObservation {
		observed := hzNetIPNet(netw.IPRange)
		extra := map[string]any{"subnets": len(netw.Subnets), "routes": len(netw.Routes)}
		if observed != "" {
			extra["ip_range"] = observed
		}
		return hzResAgreesWith(extra, hzResDivergence(
			hzResAsked{"ip_range", askedIPRange, observed},
		))
	}
}

// hzObserveNetworkIPRange confirms change-ip-range against the range the
// network NOW reports.
func hzObserveNetworkIPRange(want string) hzResObserveFn[hcloud.Network] {
	return func(netw *hcloud.Network) hzResObservation {
		observed := hzNetIPNet(netw.IPRange)
		if observed != want {
			return hzResDisagrees("ip_range", strconv.Quote(observed), strconv.Quote(want))
		}
		return hzResAgrees(map[string]any{"ip_range": observed})
	}
}

// hzObserveNetworkSubnetPresent confirms add-subnet: the network NOW carries the
// subnet, and the receipt reports the range the API settled on.
func hzObserveNetworkSubnetPresent(m hzNetworkSubnetMatch) hzResObserveFn[hcloud.Network] {
	return func(netw *hcloud.Network) hzResObservation {
		for _, s := range netw.Subnets {
			if !m.matches(s) {
				continue
			}
			return hzResAgrees(map[string]any{
				"subnet_observed": true,
				"type":            string(s.Type),
				"network_zone":    string(s.NetworkZone),
				"ip_range":        hzNetIPNet(s.IPRange),
				"subnets":         len(netw.Subnets),
			})
		}
		return hzResDisagrees("subnets", fmt.Sprintf("%v", hzNetworkSubnetSummary(netw)), m.describe)
	}
}

// hzObserveNetworkSubnetAbsent is delete-subnet's half — the same containment
// predicate, INVERTED. Separate functions, not one flag, because no census arm
// reads a direction branch.
func hzObserveNetworkSubnetAbsent(m hzNetworkSubnetMatch) hzResObserveFn[hcloud.Network] {
	return func(netw *hcloud.Network) hzResObservation {
		for _, s := range netw.Subnets {
			if m.matches(s) {
				return hzResDisagrees("subnets", m.describe+" is STILL present", "no "+m.describe)
			}
		}
		return hzResAgrees(map[string]any{
			"subnet_absent": true,
			"subnets":       len(netw.Subnets),
			"subnet_list":   hzNetworkSubnetSummary(netw),
		})
	}
}

// hzNetworkRouteMatches binds a route on the NORMALISED destination and the
// gateway, both as the client sent them.
func hzNetworkRouteMatches(destination, gateway string) func(hcloud.NetworkRoute) bool {
	return func(r hcloud.NetworkRoute) bool {
		return hzNetIPNet(r.Destination) == destination && r.Gateway.String() == gateway
	}
}

// hzObserveNetworkRoutePresent confirms add-route.
func hzObserveNetworkRoutePresent(destination, gateway string) hzResObserveFn[hcloud.Network] {
	match := hzNetworkRouteMatches(destination, gateway)
	return func(netw *hcloud.Network) hzResObservation {
		for _, r := range netw.Routes {
			if !match(r) {
				continue
			}
			return hzResAgrees(map[string]any{
				"route_observed": true,
				"destination":    hzNetIPNet(r.Destination),
				"gateway":        r.Gateway.String(),
				"routes":         len(netw.Routes),
			})
		}
		return hzResDisagrees("routes", fmt.Sprintf("%v", hzNetworkRouteSummary(netw)),
			fmt.Sprintf("a route to %s via %s", destination, gateway))
	}
}

// hzObserveNetworkRouteAbsent confirms delete-route.
func hzObserveNetworkRouteAbsent(destination, gateway string) hzResObserveFn[hcloud.Network] {
	match := hzNetworkRouteMatches(destination, gateway)
	return func(netw *hcloud.Network) hzResObservation {
		for _, r := range netw.Routes {
			if match(r) {
				return hzResDisagrees("routes",
					fmt.Sprintf("the route to %s via %s is STILL present", destination, gateway),
					fmt.Sprintf("no route to %s via %s", destination, gateway))
			}
		}
		return hzResAgrees(map[string]any{
			"route_absent": true,
			"routes":       len(netw.Routes),
			"route_list":   hzNetworkRouteSummary(netw),
		})
	}
}

func runHetznerNetwork(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerNetworkHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing network command (run `bp cloud hetzner network -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerNetworkList(out, g, rest)
	case "get", "show":
		return runHetznerNetworkGet(out, g, rest)
	case "create":
		return runHetznerNetworkCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerNetworkDelete(out, g, rest)
	case "add-subnet":
		return runHetznerNetworkAddSubnet(out, g, rest)
	case "delete-subnet":
		return runHetznerNetworkDeleteSubnet(out, g, rest)
	case "add-route":
		return runHetznerNetworkRoute(out, g, "add-route", rest)
	case "delete-route":
		return runHetznerNetworkRoute(out, g, "delete-route", rest)
	case "change-ip-range":
		return runHetznerNetworkChangeIPRange(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown network command %q (run `bp cloud hetzner network -h` for usage)", verb), exitUsage)
	}
}

func resolveHzNetwork(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.Network, error) {
	return hzResolve(ctx, hc.Network.Get, "network", idOrName, "bp cloud hetzner network list")
}

// hzNetworkRow is the structured (json/yaml) shape of one network.
func hzNetworkRow(n *hcloud.Network) map[string]any {
	row := map[string]any{
		"id":   n.ID,
		"name": n.Name,
	}
	if n.IPRange != nil {
		row["ip_range"] = n.IPRange.String()
	}
	if len(n.Subnets) > 0 {
		subnets := make([]map[string]any, 0, len(n.Subnets))
		for _, s := range n.Subnets {
			sub := map[string]any{"type": string(s.Type), "network_zone": string(s.NetworkZone)}
			if s.IPRange != nil {
				sub["ip_range"] = s.IPRange.String()
			}
			if s.Gateway != nil {
				sub["gateway"] = s.Gateway.String()
			}
			subnets = append(subnets, sub)
		}
		row["subnets"] = subnets
	}
	if len(n.Routes) > 0 {
		routes := make([]map[string]any, 0, len(n.Routes))
		for _, r := range n.Routes {
			rt := map[string]any{}
			if r.Destination != nil {
				rt["destination"] = r.Destination.String()
			}
			if r.Gateway != nil {
				rt["gateway"] = r.Gateway.String()
			}
			routes = append(routes, rt)
		}
		row["routes"] = routes
	}
	if len(n.Servers) > 0 {
		ids := make([]int64, 0, len(n.Servers))
		for _, s := range n.Servers {
			ids = append(ids, s.ID)
		}
		row["server_ids"] = ids
	}
	if n.Protection.Delete {
		row["delete_protection"] = true
	}
	if created, ok := hzCreated(n.Created); ok {
		row["created"] = created
	}
	if len(n.Labels) > 0 {
		row["labels"] = n.Labels
	}
	return row
}

func runHetznerNetworkList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner network list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	nets, err := c.HCloud().Network.AllWithOpts(hetznerCtx(), hcloud.NetworkListOpts{})
	if err != nil {
		return hzFail(out, "list networks", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(nets))
		for _, n := range nets {
			rows = append(rows, hzNetworkRow(n))
		}
		out.emitStructured(map[string]any{"networks": rows})
		return exitOK
	}
	if len(nets) == 0 {
		out.outf("no networks in this project — create one with 'bp cloud hetzner network create --name <n> --ip-range 10.0.0.0/16'")
		return exitOK
	}
	rows := make([][]string, 0, len(nets))
	for _, n := range nets {
		ipRange := ""
		if n.IPRange != nil {
			ipRange = n.IPRange.String()
		}
		rows = append(rows, []string{
			strconv.FormatInt(n.ID, 10),
			hzCell(n.Name),
			hzCell(ipRange),
			strconv.Itoa(len(n.Subnets)),
			strconv.Itoa(len(n.Servers)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "IP-RANGE", "SUBNETS", "SERVERS"}, rows)
	return exitOK
}

func runHetznerNetworkGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner network get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	netw, err := resolveHzNetwork(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get network", errOrNotFound(err))
	}
	row := hzNetworkRow(netw)
	if out.emitStructured(map[string]any{"network": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerNetworkCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner network create --name <n> --ip-range <cidr> [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "ip-range", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := a.val("name")
	if name == "" || a.val("ip-range") == "" {
		return useError(out, "usage", "--name and --ip-range are required (usage: "+usage+")", exitUsage)
	}
	ipRange, cerr := hzCIDR(a.val("ip-range"), "--ip-range")
	if cerr != nil {
		return useError(out, "usage", cerr.Error(), exitUsage)
	}
	labels, lerr := parseHzLabels(a.list("label"))
	if lerr != nil {
		return useError(out, "usage", lerr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	netw, _, err := c.HCloud().Network.Create(hetznerCtx(), hcloud.NetworkCreateOpts{
		Name:    name,
		IPRange: ipRange,
		Labels:  labels,
	})
	if err != nil {
		return hzFail(out, "create network "+name, err)
	}
	// THE EMPTY-ID COLLAPSE. hcloud-go's generated NetworkFromSchema takes a
	// schema VALUE and returns a freshly-allocated pointer, so `netw == nil` is
	// unreachable and the naive paint would report confirmed_present:true with
	// empty observed fields on a response carrying no network at all. Collapsing
	// an id-less object to nil makes hzResObservedResponse's refusal REACHABLE —
	// and it also removes the nil dereference this line used to carry.
	obj := netw
	var id any = name
	observedName := name
	if obj != nil && obj.ID == 0 {
		obj = nil
	}
	if obj != nil {
		id, observedName = obj.ID, obj.Name
	}
	return hzResObservedResponse(out, "create", "network", id, observedName, nil, obj,
		hzObserveNetworkCreated(ipRange.String()))
}

func runHetznerNetworkDelete(out *writer, g globals, args []string) int {
	target, yes, ok := hzOneTargetYes(out, args, "bp cloud hetzner network delete <id|name> [--yes]")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	netw, err := resolveHzNetwork(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete network", errOrNotFound(err))
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "network", netw.Name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if _, derr := hc.Network.Delete(ctx, netw); derr != nil {
		return hzFail(out, "delete network "+netw.Name, derr)
	}
	return hzResDestroyed(out, ctx, "delete", "network", netw.ID, netw.Name, nil,
		func(c context.Context) (*hcloud.Network, *hcloud.Response, error) {
			return hc.Network.GetByID(c, netw.ID)
		})
}

func runHetznerNetworkAddSubnet(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner network add-subnet <id|name> --type cloud|server|vswitch --network-zone <z> [--ip-range <cidr>]"
	a, err := parseHzArgs(args, []string{"type", "network-zone", "ip-range"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("type") == "" || a.val("network-zone") == "" {
		return useError(out, "usage", "want <id|name>, --type and --network-zone (usage: "+usage+")", exitUsage)
	}
	subnetType := hcloud.NetworkSubnetType(a.val("type"))
	switch subnetType {
	case hcloud.NetworkSubnetTypeCloud, hcloud.NetworkSubnetTypeServer, hcloud.NetworkSubnetTypeVSwitch:
	default:
		return useError(out, "usage", fmt.Sprintf("invalid --type %q (want cloud|server|vswitch)", a.val("type")), exitUsage)
	}
	subnet := hcloud.NetworkSubnet{Type: subnetType, NetworkZone: hcloud.NetworkZone(a.val("network-zone"))}
	if r := a.val("ip-range"); r != "" {
		ipRange, cerr := hzCIDR(r, "--ip-range")
		if cerr != nil {
			return useError(out, "usage", cerr.Error(), exitUsage)
		}
		subnet.IPRange = ipRange
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	netw, rerr := resolveHzNetwork(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "add-subnet", errOrNotFound(rerr))
	}
	action, _, err := hc.Network.AddSubnet(ctx, netw, hcloud.NetworkAddSubnetOpts{Subnet: subnet})
	if err != nil {
		return hzFail(out, "add-subnet to network "+netw.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "add-subnet to network "+netw.Name+": action failed", werr)
	}
	// --ip-range is OPTIONAL here: when it is omitted the API picks the range,
	// so the match falls back to (type, zone) and the receipt reports whichever
	// range the network now carries.
	match := hzNetworkSubnetMatch{
		subnetType:  subnetType,
		networkZone: hcloud.NetworkZone(a.val("network-zone")),
		ipRange:     hzNetIPNet(subnet.IPRange),
		describe:    fmt.Sprintf("a %s subnet in %s", subnetType, a.val("network-zone")),
	}
	if match.ipRange != "" {
		match.describe = fmt.Sprintf("the subnet %s", match.ipRange)
	}
	return hzResObserved(out, ctx, "add-subnet", "network", netw.ID, netw.Name, nil,
		func(c context.Context) (*hcloud.Network, *hcloud.Response, error) {
			return hc.Network.GetByID(c, netw.ID)
		},
		hzObserveNetworkSubnetPresent(match))
}

func runHetznerNetworkDeleteSubnet(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner network delete-subnet <id|name> --ip-range <cidr>"
	a, err := parseHzArgs(args, []string{"ip-range"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("ip-range") == "" {
		return useError(out, "usage", "want <id|name> and --ip-range <cidr> (usage: "+usage+")", exitUsage)
	}
	ipRange, cerr := hzCIDR(a.val("ip-range"), "--ip-range")
	if cerr != nil {
		return useError(out, "usage", cerr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	netw, rerr := resolveHzNetwork(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "delete-subnet", errOrNotFound(rerr))
	}
	action, _, err := hc.Network.DeleteSubnet(ctx, netw, hcloud.NetworkDeleteSubnetOpts{
		Subnet: hcloud.NetworkSubnet{IPRange: ipRange},
	})
	if err != nil {
		return hzFail(out, "delete-subnet from network "+netw.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "delete-subnet from network "+netw.Name+": action failed", werr)
	}
	return hzResObserved(out, ctx, "delete-subnet", "network", netw.ID, netw.Name, nil,
		func(c context.Context) (*hcloud.Network, *hcloud.Response, error) {
			return hc.Network.GetByID(c, netw.ID)
		},
		hzObserveNetworkSubnetAbsent(hzNetworkSubnetMatch{
			ipRange:  ipRange.String(),
			describe: "the subnet " + ipRange.String(),
		}))
}

// runHetznerNetworkRoute is the shared executor for add-route/delete-route —
// the two verbs take the same --destination/--gateway pair.
func runHetznerNetworkRoute(out *writer, g globals, verb string, args []string) int {
	usage := "bp cloud hetzner network " + verb + " <id|name> --destination <cidr> --gateway <ip>"
	a, err := parseHzArgs(args, []string{"destination", "gateway"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("destination") == "" || a.val("gateway") == "" {
		return useError(out, "usage", "want <id|name>, --destination and --gateway (usage: "+usage+")", exitUsage)
	}
	dest, cerr := hzCIDR(a.val("destination"), "--destination")
	if cerr != nil {
		return useError(out, "usage", cerr.Error(), exitUsage)
	}
	gw := net.ParseIP(a.val("gateway"))
	if gw == nil {
		return useError(out, "usage", fmt.Sprintf("invalid --gateway %q (want an IP address)", a.val("gateway")), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	netw, rerr := resolveHzNetwork(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, verb, errOrNotFound(rerr))
	}
	route := hcloud.NetworkRoute{Destination: dest, Gateway: gw}
	var action *hcloud.Action
	if verb == "add-route" {
		action, _, err = hc.Network.AddRoute(ctx, netw, hcloud.NetworkAddRouteOpts{Route: route})
	} else {
		action, _, err = hc.Network.DeleteRoute(ctx, netw, hcloud.NetworkDeleteRouteOpts{Route: route})
	}
	if err != nil {
		return hzFail(out, verb+" on network "+netw.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, verb+" on network "+netw.Name+": action failed", werr)
	}
	// THE DIRECTION BRANCH THE CENSUS CANNOT SEE. This one call site carries two
	// (kind, action) keys, and every census arm reads it as one — a payment that
	// confirmed "route present" on BOTH arms would be fully green there. The
	// observer is therefore chosen by the SAME `verb` that chose the API call,
	// and TestHetznerNetworkRouteBothDirections pins both halves.
	observe := hzObserveNetworkRoutePresent(dest.String(), gw.String())
	if verb != "add-route" {
		observe = hzObserveNetworkRouteAbsent(dest.String(), gw.String())
	}
	return hzResObserved(out, ctx, verb, "network", netw.ID, netw.Name, nil,
		func(c context.Context) (*hcloud.Network, *hcloud.Response, error) {
			return hc.Network.GetByID(c, netw.ID)
		},
		observe)
}

func runHetznerNetworkChangeIPRange(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner network change-ip-range <id|name> --ip-range <cidr>"
	a, err := parseHzArgs(args, []string{"ip-range"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("ip-range") == "" {
		return useError(out, "usage", "want <id|name> and --ip-range <cidr> (usage: "+usage+")", exitUsage)
	}
	ipRange, cerr := hzCIDR(a.val("ip-range"), "--ip-range")
	if cerr != nil {
		return useError(out, "usage", cerr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	netw, rerr := resolveHzNetwork(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "change-ip-range", errOrNotFound(rerr))
	}
	action, _, err := hc.Network.ChangeIPRange(ctx, netw, hcloud.NetworkChangeIPRangeOpts{IPRange: ipRange})
	if err != nil {
		return hzFail(out, "change-ip-range on network "+netw.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "change-ip-range on network "+netw.Name+": action failed", werr)
	}
	return hzResObserved(out, ctx, "change-ip-range", "network", netw.ID, netw.Name, nil,
		func(c context.Context) (*hcloud.Network, *hcloud.Response, error) {
			return hc.Network.GetByID(c, netw.ID)
		},
		hzObserveNetworkIPRange(ipRange.String()))
}

// ---------------------------------------------------------------------------
// firewall
// ---------------------------------------------------------------------------

// hzFirewallResourceMatch identifies ONE firewall attachment across the
// server|label_selector union WITHOUT ever reading a field the resource's Type
// does not have (PDS-D399 trap (b): the union is flattened into one struct, so
// reading .Server on a label-selector resource yields a ZERO VALUE, not an
// error — a confident false "confirmed").
type hzFirewallResourceMatch struct {
	kind     hcloud.FirewallResourceType
	serverID int64
	selector string
	describe string
}

func hzFirewallServerMatch(srv *hcloud.Server) hzFirewallResourceMatch {
	return hzFirewallResourceMatch{
		kind: hcloud.FirewallResourceTypeServer, serverID: srv.ID,
		describe: fmt.Sprintf("an attachment to server id %d", srv.ID),
	}
}

func hzFirewallSelectorMatch(selector string) hzFirewallResourceMatch {
	return hzFirewallResourceMatch{
		kind: hcloud.FirewallResourceTypeLabelSelector, selector: selector,
		describe: fmt.Sprintf("a label-selector attachment for %q", selector),
	}
}

// matches switches on Type BEFORE any pointer is dereferenced.
func (m hzFirewallResourceMatch) matches(r hcloud.FirewallResource) bool {
	if r.Type != m.kind {
		return false
	}
	switch m.kind {
	case hcloud.FirewallResourceTypeServer:
		return r.Server != nil && r.Server.ID == m.serverID
	case hcloud.FirewallResourceTypeLabelSelector:
		return r.LabelSelector != nil && r.LabelSelector.Selector == m.selector
	default:
		return false
	}
}

// hzFirewallAppliedSummary describes what the firewall is NOW applied to, by
// union arm, so a refusal says what IS there.
func hzFirewallAppliedSummary(fw *hcloud.Firewall) []string {
	seen := make([]string, 0, len(fw.AppliedTo))
	for _, r := range fw.AppliedTo {
		switch r.Type {
		case hcloud.FirewallResourceTypeServer:
			if r.Server != nil {
				seen = append(seen, fmt.Sprintf("server id %d", r.Server.ID))
				continue
			}
			seen = append(seen, "server (unreadable)")
		case hcloud.FirewallResourceTypeLabelSelector:
			if r.LabelSelector != nil {
				seen = append(seen, fmt.Sprintf("label_selector %q", r.LabelSelector.Selector))
				continue
			}
			seen = append(seen, "label_selector (unreadable)")
		default:
			seen = append(seen, string(r.Type))
		}
	}
	return seen
}

// hzObserveFirewallCreated reads the create receipt off the create RESPONSE
// object. Its ADVISORY pair is `rule_count`, and the GRADE is stated where a
// reader will meet it: EQUAL COUNTS DO NOT MEAN EQUAL RULES. A count is what a
// create response can be compared on cheaply and honestly; asserting rule
// EQUALITY would need a normalising comparison of the whole rule set, which the
// API is free to reorder and canonicalise. So the count is reported as an
// observation, the mismatch is advisory (the API accepted the create), and the
// receipt names the field `rule_count` rather than `rules` — the old key was a
// pure argv echo of len(rules).
func hzObserveFirewallCreated(askedRuleCount string) hzResObserveFn[hcloud.Firewall] {
	return func(fw *hcloud.Firewall) hzResObservation {
		return hzResAgreesWith(map[string]any{
			"rule_count":  len(fw.Rules),
			"applied_to":  len(fw.AppliedTo),
			"rule_grade":  "COUNT — equal counts do not mean equal rules",
			"rule_source": "the create response",
		}, hzResDivergence(
			hzResAsked{"rule_count", askedRuleCount, strconv.Itoa(len(fw.Rules))},
		))
	}
}

// hzObserveFirewallRuleCount confirms set-rules. set-rules REPLACES the whole
// set, so a differing count is a genuine post-condition miss and refuses — but
// the grade is still COUNT, and the receipt says so rather than implying the
// rules were compared.
func hzObserveFirewallRuleCount(want int) hzResObserveFn[hcloud.Firewall] {
	return func(fw *hcloud.Firewall) hzResObservation {
		if len(fw.Rules) != want {
			return hzResDisagrees("rule_count", strconv.Itoa(len(fw.Rules)), strconv.Itoa(want))
		}
		return hzResAgrees(map[string]any{
			"rule_count": len(fw.Rules),
			"rule_grade": "COUNT — equal counts do not mean equal rules",
		})
	}
}

// hzObserveFirewallApplied confirms apply-to-resource.
func hzObserveFirewallApplied(m hzFirewallResourceMatch) hzResObserveFn[hcloud.Firewall] {
	return func(fw *hcloud.Firewall) hzResObservation {
		for _, r := range fw.AppliedTo {
			if !m.matches(r) {
				continue
			}
			return hzResAgrees(map[string]any{
				"attachment_observed": true,
				"attachment_type":     string(r.Type),
				"applied_to":          len(fw.AppliedTo),
			})
		}
		return hzResDisagrees("applied_to", fmt.Sprintf("%v", hzFirewallAppliedSummary(fw)), m.describe)
	}
}

// hzObserveFirewallRemoved is remove-from-resource's half — the same predicate,
// INVERTED, and a separate function because no census arm reads the direction.
func hzObserveFirewallRemoved(m hzFirewallResourceMatch) hzResObserveFn[hcloud.Firewall] {
	return func(fw *hcloud.Firewall) hzResObservation {
		for _, r := range fw.AppliedTo {
			if m.matches(r) {
				return hzResDisagrees("applied_to", m.describe+" is STILL attached", "no "+m.describe)
			}
		}
		return hzResAgrees(map[string]any{
			"attachment_absent": true,
			"applied_to":        len(fw.AppliedTo),
			"applied_to_list":   hzFirewallAppliedSummary(fw),
		})
	}
}

func runHetznerFirewall(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerFirewallHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing firewall command (run `bp cloud hetzner firewall -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerFirewallList(out, g, rest)
	case "get", "show":
		return runHetznerFirewallGet(out, g, rest)
	case "create":
		return runHetznerFirewallCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerFirewallDelete(out, g, rest)
	case "set-rules":
		return runHetznerFirewallSetRules(out, g, rest)
	case "apply-to-resource":
		return runHetznerFirewallResource(out, g, "apply-to-resource", rest)
	case "remove-from-resource":
		return runHetznerFirewallResource(out, g, "remove-from-resource", rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown firewall command %q (run `bp cloud hetzner firewall -h` for usage)", verb), exitUsage)
	}
}

func resolveHzFirewall(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.Firewall, error) {
	return hzResolve(ctx, hc.Firewall.Get, "firewall", idOrName, "bp cloud hetzner firewall list")
}

// hzFirewallRuleSpec is the on-disk (--rules-file) shape of one firewall rule —
// the API's own field names, so a rule copied from Hetzner docs pastes in.
type hzFirewallRuleSpec struct {
	Direction      string   `json:"direction"`
	Protocol       string   `json:"protocol"`
	Port           string   `json:"port,omitempty"`
	SourceIPs      []string `json:"source_ips,omitempty"`
	DestinationIPs []string `json:"destination_ips,omitempty"`
	Description    string   `json:"description,omitempty"`
}

// loadHzFirewallRules reads and validates a --rules-file: a JSON array of
// hzFirewallRuleSpec. Every CIDR is parsed up front so a typo fails with the
// rule index, not an opaque API 422.
func loadHzFirewallRules(path string) ([]hcloud.FirewallRule, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read --rules-file: %w", err)
	}
	var specs []hzFirewallRuleSpec
	if err := json.Unmarshal(data, &specs); err != nil {
		return nil, fmt.Errorf("parse --rules-file %s: %w (want a JSON array of rules)", path, err)
	}
	rules := make([]hcloud.FirewallRule, 0, len(specs))
	for i, s := range specs {
		rule := hcloud.FirewallRule{
			Direction: hcloud.FirewallRuleDirection(s.Direction),
			Protocol:  hcloud.FirewallRuleProtocol(s.Protocol),
		}
		if rule.Direction != hcloud.FirewallRuleDirectionIn && rule.Direction != hcloud.FirewallRuleDirectionOut {
			return nil, fmt.Errorf("--rules-file rule %d: invalid direction %q (want in|out)", i, s.Direction)
		}
		if s.Port != "" {
			rule.Port = hcloud.Ptr(s.Port)
		}
		if s.Description != "" {
			rule.Description = hcloud.Ptr(s.Description)
		}
		for _, cidr := range s.SourceIPs {
			ipNet, cerr := hzCIDR(cidr, fmt.Sprintf("--rules-file rule %d source_ips entry", i))
			if cerr != nil {
				return nil, cerr
			}
			rule.SourceIPs = append(rule.SourceIPs, *ipNet)
		}
		for _, cidr := range s.DestinationIPs {
			ipNet, cerr := hzCIDR(cidr, fmt.Sprintf("--rules-file rule %d destination_ips entry", i))
			if cerr != nil {
				return nil, cerr
			}
			rule.DestinationIPs = append(rule.DestinationIPs, *ipNet)
		}
		rules = append(rules, rule)
	}
	return rules, nil
}

// hzFirewallRuleRow is the structured shape of one applied rule.
func hzFirewallRuleRow(r hcloud.FirewallRule) map[string]any {
	row := map[string]any{
		"direction": string(r.Direction),
		"protocol":  string(r.Protocol),
	}
	if r.Port != nil {
		row["port"] = *r.Port
	}
	if r.Description != nil && *r.Description != "" {
		row["description"] = *r.Description
	}
	if len(r.SourceIPs) > 0 {
		ips := make([]string, 0, len(r.SourceIPs))
		for _, ip := range r.SourceIPs {
			ips = append(ips, ip.String())
		}
		row["source_ips"] = ips
	}
	if len(r.DestinationIPs) > 0 {
		ips := make([]string, 0, len(r.DestinationIPs))
		for _, ip := range r.DestinationIPs {
			ips = append(ips, ip.String())
		}
		row["destination_ips"] = ips
	}
	return row
}

// hzFirewallRow is the structured (json/yaml) shape of one firewall. Rules ride
// in full — a firewall IS its rules.
func hzFirewallRow(f *hcloud.Firewall) map[string]any {
	row := map[string]any{
		"id":   f.ID,
		"name": f.Name,
	}
	rules := make([]map[string]any, 0, len(f.Rules))
	for _, r := range f.Rules {
		rules = append(rules, hzFirewallRuleRow(r))
	}
	row["rules"] = rules
	if len(f.AppliedTo) > 0 {
		applied := make([]map[string]any, 0, len(f.AppliedTo))
		for _, res := range f.AppliedTo {
			entry := map[string]any{"type": string(res.Type)}
			if res.Server != nil {
				entry["server_id"] = res.Server.ID
			}
			if res.LabelSelector != nil {
				entry["label_selector"] = res.LabelSelector.Selector
			}
			applied = append(applied, entry)
		}
		row["applied_to"] = applied
	}
	if created, ok := hzCreated(f.Created); ok {
		row["created"] = created
	}
	if len(f.Labels) > 0 {
		row["labels"] = f.Labels
	}
	return row
}

func runHetznerFirewallList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner firewall list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	fws, err := c.HCloud().Firewall.AllWithOpts(hetznerCtx(), hcloud.FirewallListOpts{})
	if err != nil {
		return hzFail(out, "list firewalls", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(fws))
		for _, f := range fws {
			rows = append(rows, hzFirewallRow(f))
		}
		out.emitStructured(map[string]any{"firewalls": rows})
		return exitOK
	}
	if len(fws) == 0 {
		out.outf("no firewalls in this project — create one with 'bp cloud hetzner firewall create --name <n> [--rules-file rules.json]'")
		return exitOK
	}
	rows := make([][]string, 0, len(fws))
	for _, f := range fws {
		rows = append(rows, []string{
			strconv.FormatInt(f.ID, 10),
			hzCell(f.Name),
			strconv.Itoa(len(f.Rules)),
			strconv.Itoa(len(f.AppliedTo)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "RULES", "APPLIED-TO"}, rows)
	return exitOK
}

func runHetznerFirewallGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner firewall get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	fw, err := resolveHzFirewall(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get firewall", errOrNotFound(err))
	}
	row := hzFirewallRow(fw)
	if out.emitStructured(map[string]any{"firewall": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerFirewallCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner firewall create --name <n> [--rules-file <f>] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "rules-file", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := a.val("name")
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	labels, lerr := parseHzLabels(a.list("label"))
	if lerr != nil {
		return useError(out, "usage", lerr.Error(), exitUsage)
	}
	var rules []hcloud.FirewallRule
	if f := a.val("rules-file"); f != "" {
		var rerr error
		rules, rerr = loadHzFirewallRules(f)
		if rerr != nil {
			return useError(out, "usage", rerr.Error(), exitUsage)
		}
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	result, _, err := hc.Firewall.Create(ctx, hcloud.FirewallCreateOpts{Name: name, Rules: rules, Labels: labels})
	if err != nil {
		return hzFail(out, "create firewall "+name, err)
	}
	if werr := hzWait(ctx, hc, result.Actions...); werr != nil {
		return hzFail(out, "create firewall "+name+": create action failed", werr)
	}
	// THE EMPTY-ID COLLAPSE, the same one the network create carries above.
	//
	// WHAT WAS REMOVED AND WHY. A hand-rolled `result.Firewall == nil` refusal
	// used to stand here. hcloud-go's generated FirewallFromSchema takes a
	// schema VALUE and returns `&hcloudFirewall` on every path, so once Create
	// returns no error that branch CANNOT be taken — dead code that read as
	// protection and gave none, and which pushed the reader past the failure
	// that can actually arrive.
	//
	// WHAT ARRIVES INSTEAD: a 2xx whose body carries no firewall object. The
	// zero value then confirms id 0, an empty name and rule_count 0 — a
	// confident receipt for a network security posture nobody has, which is
	// strictly worse than the argv echo this site already retired. Collapsing an
	// id-less object to nil makes hzResObservedResponse's refusal REACHABLE, so
	// the one guard left here is the one that can fire.
	obj := result.Firewall
	var id any = name
	observedName := name
	if obj == nil || obj.ID == 0 {
		obj = nil
	} else {
		id, observedName = obj.ID, obj.Name
	}
	// CLASS A2: the create RESPONSE object is server truth, so the receipt is
	// read off it — rule_count comes from obj.Rules, never from len(rules).
	return hzResObservedResponse(out, "create", "firewall", id, observedName,
		nil, obj, hzObserveFirewallCreated(strconv.Itoa(len(rules))))
}

func runHetznerFirewallDelete(out *writer, g globals, args []string) int {
	target, yes, ok := hzOneTargetYes(out, args, "bp cloud hetzner firewall delete <id|name> [--yes]")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	fw, err := resolveHzFirewall(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete firewall", errOrNotFound(err))
	}
	if cerr := hzConfirmDestroy(hzStdin, out, "firewall", fw.Name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if _, derr := hc.Firewall.Delete(ctx, fw); derr != nil {
		return hzFail(out, "delete firewall "+fw.Name, derr)
	}
	return hzResDestroyed(out, ctx, "delete", "firewall", fw.ID, fw.Name, nil,
		func(c context.Context) (*hcloud.Firewall, *hcloud.Response, error) {
			return hc.Firewall.GetByID(c, fw.ID)
		})
}

func runHetznerFirewallSetRules(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner firewall set-rules <id|name> --rules-file <f>"
	a, err := parseHzArgs(args, []string{"rules-file"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("rules-file") == "" {
		return useError(out, "usage", "want <id|name> and --rules-file <f> (usage: "+usage+")", exitUsage)
	}
	rules, rerr := loadHzFirewallRules(a.val("rules-file"))
	if rerr != nil {
		return useError(out, "usage", rerr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	fw, ferr := resolveHzFirewall(ctx, hc, a.pos[0])
	if ferr != nil {
		return hzFail(out, "set-rules", errOrNotFound(ferr))
	}
	actions, _, err := hc.Firewall.SetRules(ctx, fw, hcloud.FirewallSetRulesOpts{Rules: rules})
	if err != nil {
		return hzFail(out, "set-rules on firewall "+fw.Name, err)
	}
	if werr := hzWait(ctx, hc, actions...); werr != nil {
		return hzFail(out, "set-rules on firewall "+fw.Name+": action failed", werr)
	}
	return hzResObserved(out, ctx, "set-rules", "firewall", fw.ID, fw.Name, nil,
		func(c context.Context) (*hcloud.Firewall, *hcloud.Response, error) {
			return hc.Firewall.GetByID(c, fw.ID)
		},
		hzObserveFirewallRuleCount(len(rules)))
}

// runHetznerFirewallResource is the shared executor for apply-to-resource and
// remove-from-resource — same target flags, opposite direction.
func runHetznerFirewallResource(out *writer, g globals, verb string, args []string) int {
	usage := "bp cloud hetzner firewall " + verb + " <id|name> (--server <s> | --label-selector <sel>)"
	a, err := parseHzArgs(args, []string{"server", "label-selector"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
	}
	if (a.val("server") == "") == (a.val("label-selector") == "") {
		return useError(out, "usage", "want exactly one of --server or --label-selector (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	fw, ferr := resolveHzFirewall(ctx, hc, a.pos[0])
	if ferr != nil {
		return hzFail(out, verb, errOrNotFound(ferr))
	}

	var resource hcloud.FirewallResource
	var match hzFirewallResourceMatch
	extra := map[string]any{}
	if s := a.val("server"); s != "" {
		srv, rerr := resolveHzServer(ctx, hc, s)
		if rerr != nil {
			return hzFail(out, verb+" on firewall "+fw.Name, errOrNotFound(rerr))
		}
		resource = hcloud.FirewallResource{
			Type:   hcloud.FirewallResourceTypeServer,
			Server: &hcloud.FirewallResourceServer{ID: srv.ID},
		}
		// Trap (a): the nested server ref carries an id and no name, so the
		// human name rides through `extra` while the match binds on the id.
		extra["server"] = srv.Name
		match = hzFirewallServerMatch(srv)
	} else {
		resource = hcloud.FirewallResource{
			Type:          hcloud.FirewallResourceTypeLabelSelector,
			LabelSelector: &hcloud.FirewallResourceLabelSelector{Selector: a.val("label-selector")},
		}
		extra["label_selector"] = a.val("label-selector")
		match = hzFirewallSelectorMatch(a.val("label-selector"))
	}

	var actions []*hcloud.Action
	if verb == "apply-to-resource" {
		actions, _, err = hc.Firewall.ApplyResources(ctx, fw, []hcloud.FirewallResource{resource})
	} else {
		actions, _, err = hc.Firewall.RemoveResources(ctx, fw, []hcloud.FirewallResource{resource})
	}
	if err != nil {
		return hzFail(out, verb+" on firewall "+fw.Name, err)
	}
	if werr := hzWait(ctx, hc, actions...); werr != nil {
		return hzFail(out, verb+" on firewall "+fw.Name+": action failed", werr)
	}
	// THE SECOND DIRECTION BRANCH THE CENSUS CANNOT SEE — same shape as
	// runHetznerNetworkRoute above, same reason, same both-direction fake.
	observe := hzObserveFirewallApplied(match)
	if verb != "apply-to-resource" {
		observe = hzObserveFirewallRemoved(match)
	}
	return hzResObserved(out, ctx, verb, "firewall", fw.ID, fw.Name, extra,
		func(c context.Context) (*hcloud.Firewall, *hcloud.Response, error) {
			return hc.Firewall.GetByID(c, fw.ID)
		},
		observe)
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

// printHetznerVolumeHelp writes `bp cloud hetzner volume` usage.
func printHetznerVolumeHelp(out *writer) {
	const help = `bp cloud hetzner volume — manage the project's block-storage volumes.

USAGE
  bp cloud hetzner volume list
  bp cloud hetzner volume get <id|name>
  bp cloud hetzner volume create --name <n> --size <gb> (--location <loc> | --server <s>)
                                 [--format ext4|xfs] [--automount] [--label k=v]…
  bp cloud hetzner volume delete <id|name> [--yes]
  bp cloud hetzner volume attach <id|name> --server <s> [--automount]
  bp cloud hetzner volume detach <id|name>
  bp cloud hetzner volume resize <id|name> --size <gb>
  bp cloud hetzner volume change-protection <id|name> (--enable | --disable)

NOTES
  create             --location makes a detached volume; --server creates it
                     attached to that server (required for --automount)
  resize             volumes only grow — the new --size must exceed the current
  change-protection  toggles delete protection
  -o json|yaml       structured output for every verb

EXAMPLE
  bp cloud hetzner volume create --name data-1 --size 10 --server web-1 --format ext4 --automount`
	out.outf("%s", help)
}

// printHetznerNetworkHelp writes `bp cloud hetzner network` usage.
func printHetznerNetworkHelp(out *writer) {
	const help = `bp cloud hetzner network — manage the project's private networks.

USAGE
  bp cloud hetzner network list
  bp cloud hetzner network get <id|name>
  bp cloud hetzner network create --name <n> --ip-range <cidr> [--label k=v]…
  bp cloud hetzner network delete <id|name> [--yes]
  bp cloud hetzner network add-subnet <id|name> --type cloud|server|vswitch
                                      --network-zone <z> [--ip-range <cidr>]
  bp cloud hetzner network delete-subnet <id|name> --ip-range <cidr>
  bp cloud hetzner network add-route <id|name> --destination <cidr> --gateway <ip>
  bp cloud hetzner network delete-route <id|name> --destination <cidr> --gateway <ip>
  bp cloud hetzner network change-ip-range <id|name> --ip-range <cidr>

NOTES
  add-subnet       --ip-range is optional for cloud subnets (auto-allocated
                   from the network's range when omitted)
  change-ip-range  the new range can only GROW the network, never shrink it
  network zones    eu-central · us-east · us-west (see 'bp cloud hetzner locations')

EXAMPLE
  bp cloud hetzner network create --name backend --ip-range 10.0.0.0/16
  bp cloud hetzner network add-subnet backend --type cloud --network-zone eu-central --ip-range 10.0.1.0/24`
	out.outf("%s", help)
}

// printHetznerFirewallHelp writes `bp cloud hetzner firewall` usage.
func printHetznerFirewallHelp(out *writer) {
	const help = `bp cloud hetzner firewall — manage the project's firewalls.

USAGE
  bp cloud hetzner firewall list
  bp cloud hetzner firewall get <id|name>
  bp cloud hetzner firewall create --name <n> [--rules-file <f>] [--label k=v]…
  bp cloud hetzner firewall delete <id|name> [--yes]
  bp cloud hetzner firewall set-rules <id|name> --rules-file <f>
  bp cloud hetzner firewall apply-to-resource <id|name> (--server <s> | --label-selector <sel>)
  bp cloud hetzner firewall remove-from-resource <id|name> (--server <s> | --label-selector <sel>)

RULES FILE (JSON array, the API's own field names)
  [{"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"]},
   {"direction":"in","protocol":"icmp","source_ips":["0.0.0.0/0"],"description":"ping"}]
  direction: in|out · protocol: tcp|udp|icmp|esp|gre · port: "80" or a range "80-85"

NOTES
  set-rules   REPLACES the whole rule set with the file's rules
  apply/remove targets: one server (--server) or every server matching a
  label selector (--label-selector env=prod)

EXAMPLE
  bp cloud hetzner firewall create --name web-fw --rules-file rules.json
  bp cloud hetzner firewall apply-to-resource web-fw --server web-1`
	out.outf("%s", help)
}
