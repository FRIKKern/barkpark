package cli

// hetzner_lb_cmd.go is the traffic + attachment third of the PR3 resources:
//
//	bp cloud hetzner load-balancer    list · get · create · delete · add-service ·
//	                                  delete-service · add-target · remove-target ·
//	                                  change-algorithm · change-type
//	bp cloud hetzner lb-types         the offered load-balancer types (read-only)
//	bp cloud hetzner floating-ip      list · get · create · delete · assign · unassign
//	bp cloud hetzner primary-ip       list · get · create · delete · assign · unassign
//	bp cloud hetzner placement-group  list · get · create · delete
//	bp cloud hetzner certificate      list · get · create-uploaded · create-managed · delete
//
// Shared plumbing (hzResolve, hzResDone, parseHzArgs, hzWait, tables) lives in
// hetzner_cmd.go / hetzner_net_cmd.go.

import (
	"context"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// ---------------------------------------------------------------------------
// load-balancer
// ---------------------------------------------------------------------------

func runHetznerLoadBalancer(out *writer, g globals, args []string) int {
	if g.help || len(args) == 0 {
		printHetznerLoadBalancerHelp(out)
		if g.help {
			return exitOK
		}
		return exitUsage
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerLBList(out, g, rest)
	case "get", "show":
		return runHetznerLBGet(out, g, rest)
	case "create":
		return runHetznerLBCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerLBDelete(out, g, rest)
	case "add-service":
		return runHetznerLBAddService(out, g, rest)
	case "delete-service":
		return runHetznerLBDeleteService(out, g, rest)
	case "add-target":
		return runHetznerLBAddTarget(out, g, rest)
	case "remove-target":
		return runHetznerLBRemoveTarget(out, g, rest)
	case "change-algorithm":
		return runHetznerLBChangeAlgorithm(out, g, rest)
	case "change-type":
		return runHetznerLBChangeType(out, g, rest)
	default:
		out.errf("barkpark: unknown load-balancer command %q", verb)
		printHetznerLoadBalancerHelp(out)
		return exitUsage
	}
}

func resolveHzLB(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.LoadBalancer, error) {
	return hzResolve(ctx, hc.LoadBalancer.Get, "load-balancer", idOrName, "bp cloud hetzner load-balancer list")
}

// hzLBTypeRef builds an IDOrName load-balancer-type reference (the
// hzServerTypeRef idiom).
func hzLBTypeRef(s string) *hcloud.LoadBalancerType {
	if id, err := strconv.ParseInt(s, 10, 64); err == nil {
		return &hcloud.LoadBalancerType{ID: id}
	}
	return &hcloud.LoadBalancerType{Name: s}
}

// hzLBAlgorithm validates an --algorithm value against the API's two types.
func hzLBAlgorithm(s string) (hcloud.LoadBalancerAlgorithmType, error) {
	switch t := hcloud.LoadBalancerAlgorithmType(s); t {
	case hcloud.LoadBalancerAlgorithmTypeRoundRobin, hcloud.LoadBalancerAlgorithmTypeLeastConnections:
		return t, nil
	default:
		return "", fmt.Errorf("invalid --algorithm %q (want round_robin|least_connections)", s)
	}
}

// hzLBRow is the structured (json/yaml) shape of one load balancer.
func hzLBRow(lb *hcloud.LoadBalancer) map[string]any {
	row := map[string]any{
		"id":   lb.ID,
		"name": lb.Name,
	}
	if lb.LoadBalancerType != nil {
		row["type"] = lb.LoadBalancerType.Name
	}
	if lb.Location != nil {
		row["location"] = lb.Location.Name
	}
	if lb.PublicNet.IPv4.IP != nil {
		row["ipv4"] = lb.PublicNet.IPv4.IP.String()
	}
	if lb.PublicNet.IPv6.IP != nil {
		row["ipv6"] = lb.PublicNet.IPv6.IP.String()
	}
	if lb.Algorithm.Type != "" {
		row["algorithm"] = string(lb.Algorithm.Type)
	}
	if len(lb.Services) > 0 {
		services := make([]map[string]any, 0, len(lb.Services))
		for _, s := range lb.Services {
			services = append(services, map[string]any{
				"protocol":         string(s.Protocol),
				"listen_port":      s.ListenPort,
				"destination_port": s.DestinationPort,
			})
		}
		row["services"] = services
	}
	if len(lb.Targets) > 0 {
		targets := make([]map[string]any, 0, len(lb.Targets))
		for _, t := range lb.Targets {
			entry := map[string]any{"type": string(t.Type)}
			if t.Server != nil && t.Server.Server != nil {
				entry["server_id"] = t.Server.Server.ID
			}
			if t.LabelSelector != nil {
				entry["label_selector"] = t.LabelSelector.Selector
			}
			if t.IP != nil {
				entry["ip"] = t.IP.IP
			}
			targets = append(targets, entry)
		}
		row["targets"] = targets
	}
	if created, ok := hzCreated(lb.Created); ok {
		row["created"] = created
	}
	if len(lb.Labels) > 0 {
		row["labels"] = lb.Labels
	}
	return row
}

func runHetznerLBList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner load-balancer list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	lbs, err := c.HCloud().LoadBalancer.AllWithOpts(hetznerCtx(), hcloud.LoadBalancerListOpts{})
	if err != nil {
		return hzFail(out, "list load balancers", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(lbs))
		for _, lb := range lbs {
			rows = append(rows, hzLBRow(lb))
		}
		out.emitStructured(map[string]any{"load_balancers": rows})
		return exitOK
	}
	if len(lbs) == 0 {
		out.outf("no load balancers in this project — create one with 'bp cloud hetzner load-balancer create --name <n> --type lb11 --location <loc>'")
		return exitOK
	}
	rows := make([][]string, 0, len(lbs))
	for _, lb := range lbs {
		typ, loc, ipv4 := "", "", ""
		if lb.LoadBalancerType != nil {
			typ = lb.LoadBalancerType.Name
		}
		if lb.Location != nil {
			loc = lb.Location.Name
		}
		if lb.PublicNet.IPv4.IP != nil {
			ipv4 = lb.PublicNet.IPv4.IP.String()
		}
		rows = append(rows, []string{
			strconv.FormatInt(lb.ID, 10),
			hzCell(lb.Name),
			hzCell(typ),
			hzCell(loc),
			hzCell(ipv4),
			hzCell(string(lb.Algorithm.Type)),
			strconv.Itoa(len(lb.Services)),
			strconv.Itoa(len(lb.Targets)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "LOCATION", "IPV4", "ALGORITHM", "SERVICES", "TARGETS"}, rows)
	return exitOK
}

func runHetznerLBGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner load-balancer get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	lb, err := resolveHzLB(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get load-balancer", errOrNotFound(err))
	}
	row := hzLBRow(lb)
	if out.emitStructured(map[string]any{"load_balancer": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerLBCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer create --name <n> --type <t> (--location <loc> | --network-zone <z>) [--algorithm round_robin|least_connections] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "type", "location", "network-zone", "algorithm", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name, typ := a.val("name"), a.val("type")
	if name == "" || typ == "" {
		return useError(out, "usage", "--name and --type are required (usage: "+usage+")", exitUsage)
	}
	if (a.val("location") == "") == (a.val("network-zone") == "") {
		return useError(out, "usage", "want exactly one of --location or --network-zone (usage: "+usage+")", exitUsage)
	}
	labels, lerr := parseHzLabels(a.list("label"))
	if lerr != nil {
		return useError(out, "usage", lerr.Error(), exitUsage)
	}
	opts := hcloud.LoadBalancerCreateOpts{
		Name:             name,
		LoadBalancerType: hzLBTypeRef(typ),
		Labels:           labels,
	}
	if loc := a.val("location"); loc != "" {
		opts.Location = &hcloud.Location{Name: loc}
	} else {
		opts.NetworkZone = hcloud.NetworkZone(a.val("network-zone"))
	}
	if alg := a.val("algorithm"); alg != "" {
		t, aerr := hzLBAlgorithm(alg)
		if aerr != nil {
			return useError(out, "usage", aerr.Error(), exitUsage)
		}
		opts.Algorithm = &hcloud.LoadBalancerAlgorithm{Type: t}
	}

	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	result, _, err := hc.LoadBalancer.Create(ctx, opts)
	if err != nil {
		return hzFail(out, "create load-balancer "+name, err)
	}
	if result.LoadBalancer == nil {
		return useError(out, "failed", "create load-balancer "+name+": the API returned no load balancer", exitGeneric)
	}
	out.info("load-balancer %s accepted — waiting for the create action…", name)
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create load-balancer "+name+": create action failed", werr)
	}
	extra := map[string]any{}
	if result.LoadBalancer.PublicNet.IPv4.IP != nil {
		extra["ipv4"] = result.LoadBalancer.PublicNet.IPv4.IP.String()
	}
	return hzResDone(out, "create", "load-balancer", result.LoadBalancer.ID, result.LoadBalancer.Name, extra)
}

func runHetznerLBDelete(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner load-balancer delete <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	lb, err := resolveHzLB(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete load-balancer", errOrNotFound(err))
	}
	if _, derr := hc.LoadBalancer.Delete(ctx, lb); derr != nil {
		return hzFail(out, "delete load-balancer "+lb.Name, derr)
	}
	return hzResDone(out, "delete", "load-balancer", lb.ID, lb.Name, nil)
}

func runHetznerLBAddService(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer add-service <id|name> --protocol tcp|http|https --listen-port <p> [--destination-port <p>] [--proxy-protocol]"
	a, err := parseHzArgs(args, []string{"protocol", "listen-port", "destination-port"}, []string{"proxy-protocol"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("protocol") == "" || a.val("listen-port") == "" {
		return useError(out, "usage", "want <id|name>, --protocol and --listen-port (usage: "+usage+")", exitUsage)
	}
	protocol := hcloud.LoadBalancerServiceProtocol(a.val("protocol"))
	switch protocol {
	case hcloud.LoadBalancerServiceProtocolTCP, hcloud.LoadBalancerServiceProtocolHTTP, hcloud.LoadBalancerServiceProtocolHTTPS:
	default:
		return useError(out, "usage", fmt.Sprintf("invalid --protocol %q (want tcp|http|https)", a.val("protocol")), exitUsage)
	}
	listenPort, perr := strconv.Atoi(a.val("listen-port"))
	if perr != nil {
		return useError(out, "usage", fmt.Sprintf("invalid --listen-port %q", a.val("listen-port")), exitUsage)
	}
	opts := hcloud.LoadBalancerAddServiceOpts{
		Protocol:   protocol,
		ListenPort: hcloud.Ptr(listenPort),
	}
	if d := a.val("destination-port"); d != "" {
		destPort, derr := strconv.Atoi(d)
		if derr != nil {
			return useError(out, "usage", fmt.Sprintf("invalid --destination-port %q", d), exitUsage)
		}
		opts.DestinationPort = hcloud.Ptr(destPort)
	}
	if a.bools["proxy-protocol"] {
		opts.Proxyprotocol = hcloud.Ptr(true)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	lb, rerr := resolveHzLB(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "add-service", errOrNotFound(rerr))
	}
	action, _, err := hc.LoadBalancer.AddService(ctx, lb, opts)
	if err != nil {
		return hzFail(out, "add-service on load-balancer "+lb.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "add-service on load-balancer "+lb.Name+": action failed", werr)
	}
	return hzResDone(out, "add-service", "load-balancer", lb.ID, lb.Name, map[string]any{
		"protocol":    string(protocol),
		"listen_port": listenPort,
	})
}

func runHetznerLBDeleteService(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer delete-service <id|name> --listen-port <p>"
	a, err := parseHzArgs(args, []string{"listen-port"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("listen-port") == "" {
		return useError(out, "usage", "want <id|name> and --listen-port <p> (usage: "+usage+")", exitUsage)
	}
	listenPort, perr := strconv.Atoi(a.val("listen-port"))
	if perr != nil {
		return useError(out, "usage", fmt.Sprintf("invalid --listen-port %q", a.val("listen-port")), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	lb, rerr := resolveHzLB(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "delete-service", errOrNotFound(rerr))
	}
	action, _, err := hc.LoadBalancer.DeleteService(ctx, lb, listenPort)
	if err != nil {
		return hzFail(out, "delete-service on load-balancer "+lb.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "delete-service on load-balancer "+lb.Name+": action failed", werr)
	}
	return hzResDone(out, "delete-service", "load-balancer", lb.ID, lb.Name, map[string]any{"listen_port": listenPort})
}

// hzLBTargetFlags validates the one-of target flags shared by add-target and
// remove-target: exactly one of --server / --label-selector / --ip.
func hzLBTargetFlags(a *hzArgs, usage string) error {
	n := 0
	for _, f := range []string{"server", "label-selector", "ip"} {
		if a.val(f) != "" {
			n++
		}
	}
	if n != 1 {
		return fmt.Errorf("want exactly one of --server, --label-selector or --ip (usage: %s)", usage)
	}
	return nil
}

func runHetznerLBAddTarget(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer add-target <id|name> (--server <s> | --label-selector <sel> | --ip <ip>) [--use-private-ip]"
	a, err := parseHzArgs(args, []string{"server", "label-selector", "ip"}, []string{"use-private-ip"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
	}
	if terr := hzLBTargetFlags(a, usage); terr != nil {
		return useError(out, "usage", terr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	lb, rerr := resolveHzLB(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "add-target", errOrNotFound(rerr))
	}

	var action *hcloud.Action
	extra := map[string]any{}
	switch {
	case a.val("server") != "":
		srv, serr := resolveHzServer(ctx, hc, a.val("server"))
		if serr != nil {
			return hzFail(out, "add-target on load-balancer "+lb.Name, errOrNotFound(serr))
		}
		opts := hcloud.LoadBalancerAddServerTargetOpts{Server: srv}
		if a.bools["use-private-ip"] {
			opts.UsePrivateIP = hcloud.Ptr(true)
		}
		action, _, err = hc.LoadBalancer.AddServerTarget(ctx, lb, opts)
		extra["server"] = srv.Name
	case a.val("label-selector") != "":
		opts := hcloud.LoadBalancerAddLabelSelectorTargetOpts{Selector: a.val("label-selector")}
		if a.bools["use-private-ip"] {
			opts.UsePrivateIP = hcloud.Ptr(true)
		}
		action, _, err = hc.LoadBalancer.AddLabelSelectorTarget(ctx, lb, opts)
		extra["label_selector"] = a.val("label-selector")
	default:
		ip := net.ParseIP(a.val("ip"))
		if ip == nil {
			return useError(out, "usage", fmt.Sprintf("invalid --ip %q (want an IP address)", a.val("ip")), exitUsage)
		}
		action, _, err = hc.LoadBalancer.AddIPTarget(ctx, lb, hcloud.LoadBalancerAddIPTargetOpts{IP: ip})
		extra["ip"] = ip.String()
	}
	if err != nil {
		return hzFail(out, "add-target on load-balancer "+lb.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "add-target on load-balancer "+lb.Name+": action failed", werr)
	}
	return hzResDone(out, "add-target", "load-balancer", lb.ID, lb.Name, extra)
}

func runHetznerLBRemoveTarget(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer remove-target <id|name> (--server <s> | --label-selector <sel> | --ip <ip>)"
	a, err := parseHzArgs(args, []string{"server", "label-selector", "ip"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
	}
	if terr := hzLBTargetFlags(a, usage); terr != nil {
		return useError(out, "usage", terr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	lb, rerr := resolveHzLB(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "remove-target", errOrNotFound(rerr))
	}

	var action *hcloud.Action
	extra := map[string]any{}
	switch {
	case a.val("server") != "":
		srv, serr := resolveHzServer(ctx, hc, a.val("server"))
		if serr != nil {
			return hzFail(out, "remove-target on load-balancer "+lb.Name, errOrNotFound(serr))
		}
		action, _, err = hc.LoadBalancer.RemoveServerTarget(ctx, lb, srv)
		extra["server"] = srv.Name
	case a.val("label-selector") != "":
		action, _, err = hc.LoadBalancer.RemoveLabelSelectorTarget(ctx, lb, a.val("label-selector"))
		extra["label_selector"] = a.val("label-selector")
	default:
		ip := net.ParseIP(a.val("ip"))
		if ip == nil {
			return useError(out, "usage", fmt.Sprintf("invalid --ip %q (want an IP address)", a.val("ip")), exitUsage)
		}
		action, _, err = hc.LoadBalancer.RemoveIPTarget(ctx, lb, ip)
		extra["ip"] = ip.String()
	}
	if err != nil {
		return hzFail(out, "remove-target on load-balancer "+lb.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "remove-target on load-balancer "+lb.Name+": action failed", werr)
	}
	return hzResDone(out, "remove-target", "load-balancer", lb.ID, lb.Name, extra)
}

func runHetznerLBChangeAlgorithm(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer change-algorithm <id|name> --algorithm round_robin|least_connections"
	a, err := parseHzArgs(args, []string{"algorithm"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("algorithm") == "" {
		return useError(out, "usage", "want <id|name> and --algorithm (usage: "+usage+")", exitUsage)
	}
	alg, aerr := hzLBAlgorithm(a.val("algorithm"))
	if aerr != nil {
		return useError(out, "usage", aerr.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	lb, rerr := resolveHzLB(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "change-algorithm", errOrNotFound(rerr))
	}
	action, _, err := hc.LoadBalancer.ChangeAlgorithm(ctx, lb, hcloud.LoadBalancerChangeAlgorithmOpts{Type: alg})
	if err != nil {
		return hzFail(out, "change-algorithm on load-balancer "+lb.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "change-algorithm on load-balancer "+lb.Name+": action failed", werr)
	}
	return hzResDone(out, "change-algorithm", "load-balancer", lb.ID, lb.Name, map[string]any{"algorithm": string(alg)})
}

func runHetznerLBChangeType(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner load-balancer change-type <id|name> --type <t>"
	a, err := parseHzArgs(args, []string{"type"}, nil, usage)
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
	lb, rerr := resolveHzLB(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "change-type", errOrNotFound(rerr))
	}
	action, _, err := hc.LoadBalancer.ChangeType(ctx, lb, hcloud.LoadBalancerChangeTypeOpts{LoadBalancerType: hzLBTypeRef(a.val("type"))})
	if err != nil {
		return hzFail(out, "change-type on load-balancer "+lb.Name, err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "change-type on load-balancer "+lb.Name+": action failed", werr)
	}
	return hzResDone(out, "change-type", "load-balancer", lb.ID, lb.Name, map[string]any{"type": a.val("type")})
}

// runHetznerLBTypes is the read-only lb-types discovery view (the server-types
// idiom for load balancers).
func runHetznerLBTypes(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	if _, err := hzDiscoveryArgs(args, nil, "bp cloud hetzner lb-types"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	types, err := c.HCloud().LoadBalancerType.All(hetznerCtx())
	if err != nil {
		return hzFail(out, "list load-balancer types", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(types))
		for _, t := range types {
			rows = append(rows, map[string]any{
				"id":              t.ID,
				"name":            t.Name,
				"description":     t.Description,
				"max_connections": t.MaxConnections,
				"max_services":    t.MaxServices,
				"max_targets":     t.MaxTargets,
			})
		}
		out.emitStructured(map[string]any{"load_balancer_types": rows})
		return exitOK
	}
	rows := make([][]string, 0, len(types))
	for _, t := range types {
		rows = append(rows, []string{
			strconv.FormatInt(t.ID, 10),
			hzCell(t.Name),
			strconv.Itoa(t.MaxConnections),
			strconv.Itoa(t.MaxServices),
			strconv.Itoa(t.MaxTargets),
			hzCell(t.Description),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "MAX-CONNECTIONS", "MAX-SERVICES", "MAX-TARGETS", "DESCRIPTION"}, rows)
	return exitOK
}

// ---------------------------------------------------------------------------
// floating-ip
// ---------------------------------------------------------------------------

func runHetznerFloatingIP(out *writer, g globals, args []string) int {
	if g.help || len(args) == 0 {
		printHetznerFloatingIPHelp(out)
		if g.help {
			return exitOK
		}
		return exitUsage
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerFloatingIPList(out, g, rest)
	case "get", "show":
		return runHetznerFloatingIPGet(out, g, rest)
	case "create":
		return runHetznerFloatingIPCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerFloatingIPDelete(out, g, rest)
	case "assign":
		return runHetznerFloatingIPAssign(out, g, rest)
	case "unassign":
		return runHetznerFloatingIPUnassign(out, g, rest)
	default:
		out.errf("barkpark: unknown floating-ip command %q", verb)
		printHetznerFloatingIPHelp(out)
		return exitUsage
	}
}

func resolveHzFloatingIP(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.FloatingIP, error) {
	return hzResolve(ctx, hc.FloatingIP.Get, "floating-ip", idOrName, "bp cloud hetzner floating-ip list")
}

// hzFloatingIPLabel names a floating IP for receipts: the name when set, the
// address otherwise (unnamed IPs are common).
func hzFloatingIPLabel(f *hcloud.FloatingIP) string {
	if f.Name != "" {
		return f.Name
	}
	if f.IP != nil {
		return f.IP.String()
	}
	return strconv.FormatInt(f.ID, 10)
}

// hzFloatingIPRow is the structured (json/yaml) shape of one floating IP.
func hzFloatingIPRow(f *hcloud.FloatingIP) map[string]any {
	row := map[string]any{
		"id":   f.ID,
		"type": string(f.Type),
	}
	if f.Name != "" {
		row["name"] = f.Name
	}
	if f.IP != nil {
		row["ip"] = f.IP.String()
	}
	if f.Server != nil {
		row["server_id"] = f.Server.ID
	}
	if f.HomeLocation != nil {
		row["home_location"] = f.HomeLocation.Name
	}
	if f.Blocked {
		row["blocked"] = true
	}
	if f.Protection.Delete {
		row["delete_protection"] = true
	}
	if created, ok := hzCreated(f.Created); ok {
		row["created"] = created
	}
	if len(f.Labels) > 0 {
		row["labels"] = f.Labels
	}
	return row
}

func runHetznerFloatingIPList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner floating-ip list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	fips, err := c.HCloud().FloatingIP.AllWithOpts(hetznerCtx(), hcloud.FloatingIPListOpts{})
	if err != nil {
		return hzFail(out, "list floating ips", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(fips))
		for _, f := range fips {
			rows = append(rows, hzFloatingIPRow(f))
		}
		out.emitStructured(map[string]any{"floating_ips": rows})
		return exitOK
	}
	if len(fips) == 0 {
		out.outf("no floating ips in this project — create one with 'bp cloud hetzner floating-ip create --type ipv4 --home-location <loc>'")
		return exitOK
	}
	rows := make([][]string, 0, len(fips))
	for _, f := range fips {
		ip, srv, home := "", "", ""
		if f.IP != nil {
			ip = f.IP.String()
		}
		if f.Server != nil {
			srv = strconv.FormatInt(f.Server.ID, 10)
		}
		if f.HomeLocation != nil {
			home = f.HomeLocation.Name
		}
		rows = append(rows, []string{
			strconv.FormatInt(f.ID, 10),
			hzCell(f.Name),
			hzCell(string(f.Type)),
			hzCell(ip),
			hzCell(srv),
			hzCell(home),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "IP", "SERVER", "HOME"}, rows)
	return exitOK
}

func runHetznerFloatingIPGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner floating-ip get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	fip, err := resolveHzFloatingIP(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get floating-ip", errOrNotFound(err))
	}
	row := hzFloatingIPRow(fip)
	if out.emitStructured(map[string]any{"floating_ip": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerFloatingIPCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner floating-ip create --type ipv4|ipv6 (--home-location <loc> | --server <s>) [--name <n>] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"type", "home-location", "server", "name", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	ipType := hcloud.FloatingIPType(a.val("type"))
	if ipType != hcloud.FloatingIPTypeIPv4 && ipType != hcloud.FloatingIPTypeIPv6 {
		return useError(out, "usage", fmt.Sprintf("invalid --type %q (want ipv4|ipv6)", a.val("type")), exitUsage)
	}
	if (a.val("home-location") == "") == (a.val("server") == "") {
		return useError(out, "usage", "want exactly one of --home-location or --server (usage: "+usage+")", exitUsage)
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
	opts := hcloud.FloatingIPCreateOpts{Type: ipType, Labels: labels}
	if n := a.val("name"); n != "" {
		opts.Name = hcloud.Ptr(n)
	}
	if loc := a.val("home-location"); loc != "" {
		opts.HomeLocation = &hcloud.Location{Name: loc}
	} else {
		srv, rerr := resolveHzServer(ctx, hc, a.val("server"))
		if rerr != nil {
			return hzFail(out, "create floating-ip", errOrNotFound(rerr))
		}
		opts.Server = srv
	}
	result, _, err := hc.FloatingIP.Create(ctx, opts)
	if err != nil {
		return hzFail(out, "create floating-ip", err)
	}
	if result.FloatingIP == nil {
		return useError(out, "failed", "create floating-ip: the API returned no floating ip", exitGeneric)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create floating-ip: create action failed", werr)
	}
	extra := map[string]any{"type": string(ipType)}
	if result.FloatingIP.IP != nil {
		extra["ip"] = result.FloatingIP.IP.String()
	}
	return hzResDone(out, "create", "floating-ip", result.FloatingIP.ID, hzFloatingIPLabel(result.FloatingIP), extra)
}

func runHetznerFloatingIPDelete(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner floating-ip delete <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	fip, err := resolveHzFloatingIP(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete floating-ip", errOrNotFound(err))
	}
	if _, derr := hc.FloatingIP.Delete(ctx, fip); derr != nil {
		return hzFail(out, "delete floating-ip "+hzFloatingIPLabel(fip), derr)
	}
	return hzResDone(out, "delete", "floating-ip", fip.ID, hzFloatingIPLabel(fip), nil)
}

func runHetznerFloatingIPAssign(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner floating-ip assign <id|name> --server <s>"
	a, err := parseHzArgs(args, []string{"server"}, nil, usage)
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
	fip, rerr := resolveHzFloatingIP(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "assign floating-ip", errOrNotFound(rerr))
	}
	srv, rerr := resolveHzServer(ctx, hc, a.val("server"))
	if rerr != nil {
		return hzFail(out, "assign floating-ip "+hzFloatingIPLabel(fip), errOrNotFound(rerr))
	}
	action, _, err := hc.FloatingIP.Assign(ctx, fip, srv)
	if err != nil {
		return hzFail(out, "assign floating-ip "+hzFloatingIPLabel(fip), err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "assign floating-ip "+hzFloatingIPLabel(fip)+": action failed", werr)
	}
	return hzResDone(out, "assign", "floating-ip", fip.ID, hzFloatingIPLabel(fip), map[string]any{"server": srv.Name})
}

func runHetznerFloatingIPUnassign(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner floating-ip unassign <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	fip, err := resolveHzFloatingIP(ctx, hc, target)
	if err != nil {
		return hzFail(out, "unassign floating-ip", errOrNotFound(err))
	}
	action, _, err := hc.FloatingIP.Unassign(ctx, fip)
	if err != nil {
		return hzFail(out, "unassign floating-ip "+hzFloatingIPLabel(fip), err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "unassign floating-ip "+hzFloatingIPLabel(fip)+": action failed", werr)
	}
	return hzResDone(out, "unassign", "floating-ip", fip.ID, hzFloatingIPLabel(fip), nil)
}

// ---------------------------------------------------------------------------
// primary-ip
// ---------------------------------------------------------------------------

func runHetznerPrimaryIP(out *writer, g globals, args []string) int {
	if g.help || len(args) == 0 {
		printHetznerPrimaryIPHelp(out)
		if g.help {
			return exitOK
		}
		return exitUsage
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerPrimaryIPList(out, g, rest)
	case "get", "show":
		return runHetznerPrimaryIPGet(out, g, rest)
	case "create":
		return runHetznerPrimaryIPCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerPrimaryIPDelete(out, g, rest)
	case "assign":
		return runHetznerPrimaryIPAssign(out, g, rest)
	case "unassign":
		return runHetznerPrimaryIPUnassign(out, g, rest)
	default:
		out.errf("barkpark: unknown primary-ip command %q", verb)
		printHetznerPrimaryIPHelp(out)
		return exitUsage
	}
}

// resolveHzPrimaryIP resolves an id, name, OR literal address — primary IPs
// are the one resource people naturally address by the IP itself.
func resolveHzPrimaryIP(ctx context.Context, hc *hcloud.Client, ref string) (*hcloud.PrimaryIP, error) {
	if net.ParseIP(ref) != nil {
		pip, _, err := hc.PrimaryIP.GetByIP(ctx, ref)
		if err != nil {
			return nil, err
		}
		if pip == nil {
			return nil, fmt.Errorf("primary-ip %q not found (see `bp cloud hetzner primary-ip list`)", ref)
		}
		return pip, nil
	}
	return hzResolve(ctx, hc.PrimaryIP.Get, "primary-ip", ref, "bp cloud hetzner primary-ip list")
}

// hzPrimaryIPLabel names a primary IP for receipts: name, else address, else id.
func hzPrimaryIPLabel(p *hcloud.PrimaryIP) string {
	if p.Name != "" {
		return p.Name
	}
	if p.IP != nil {
		return p.IP.String()
	}
	return strconv.FormatInt(p.ID, 10)
}

// hzPrimaryIPRow is the structured (json/yaml) shape of one primary IP.
func hzPrimaryIPRow(p *hcloud.PrimaryIP) map[string]any {
	row := map[string]any{
		"id":   p.ID,
		"type": string(p.Type),
	}
	if p.Name != "" {
		row["name"] = p.Name
	}
	if p.IP != nil {
		row["ip"] = p.IP.String()
	}
	if p.AssigneeID != 0 {
		row["assignee_id"] = p.AssigneeID
		row["assignee_type"] = p.AssigneeType
	}
	if p.Location != nil {
		row["location"] = p.Location.Name
	}
	if p.AutoDelete {
		row["auto_delete"] = true
	}
	if p.Protection.Delete {
		row["delete_protection"] = true
	}
	if created, ok := hzCreated(p.Created); ok {
		row["created"] = created
	}
	if len(p.Labels) > 0 {
		row["labels"] = p.Labels
	}
	return row
}

func runHetznerPrimaryIPList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner primary-ip list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	pips, err := c.HCloud().PrimaryIP.AllWithOpts(hetznerCtx(), hcloud.PrimaryIPListOpts{})
	if err != nil {
		return hzFail(out, "list primary ips", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(pips))
		for _, p := range pips {
			rows = append(rows, hzPrimaryIPRow(p))
		}
		out.emitStructured(map[string]any{"primary_ips": rows})
		return exitOK
	}
	if len(pips) == 0 {
		out.outf("no primary ips in this project — create one with 'bp cloud hetzner primary-ip create --type ipv4 --datacenter <dc> --name <n>'")
		return exitOK
	}
	rows := make([][]string, 0, len(pips))
	for _, p := range pips {
		ip, assignee := "", ""
		if p.IP != nil {
			ip = p.IP.String()
		}
		if p.AssigneeID != 0 {
			assignee = fmt.Sprintf("%s %d", p.AssigneeType, p.AssigneeID)
		}
		rows = append(rows, []string{
			strconv.FormatInt(p.ID, 10),
			hzCell(p.Name),
			hzCell(string(p.Type)),
			hzCell(ip),
			hzCell(assignee),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "IP", "ASSIGNEE"}, rows)
	return exitOK
}

func runHetznerPrimaryIPGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner primary-ip get <id|name|ip>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	pip, err := resolveHzPrimaryIP(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get primary-ip", errOrNotFound(err))
	}
	row := hzPrimaryIPRow(pip)
	if out.emitStructured(map[string]any{"primary_ip": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerPrimaryIPCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner primary-ip create --type ipv4|ipv6 (--datacenter <dc> | --location <loc>) [--name <n>] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"type", "datacenter", "location", "name", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	ipType := hcloud.PrimaryIPType(a.val("type"))
	if ipType != hcloud.PrimaryIPTypeIPv4 && ipType != hcloud.PrimaryIPTypeIPv6 {
		return useError(out, "usage", fmt.Sprintf("invalid --type %q (want ipv4|ipv6)", a.val("type")), exitUsage)
	}
	if (a.val("datacenter") == "") == (a.val("location") == "") {
		return useError(out, "usage", "want exactly one of --datacenter or --location (usage: "+usage+")", exitUsage)
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
	opts := hcloud.PrimaryIPCreateOpts{
		Type:         ipType,
		Name:         a.val("name"),
		AssigneeType: "server",
		Datacenter:   a.val("datacenter"),
		Location:     a.val("location"),
		Labels:       labels,
	}
	result, _, err := hc.PrimaryIP.Create(ctx, opts)
	if err != nil {
		return hzFail(out, "create primary-ip", err)
	}
	if result == nil || result.PrimaryIP == nil {
		return useError(out, "failed", "create primary-ip: the API returned no primary ip", exitGeneric)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create primary-ip: create action failed", werr)
	}
	extra := map[string]any{"type": string(ipType)}
	if result.PrimaryIP.IP != nil {
		extra["ip"] = result.PrimaryIP.IP.String()
	}
	return hzResDone(out, "create", "primary-ip", result.PrimaryIP.ID, hzPrimaryIPLabel(result.PrimaryIP), extra)
}

func runHetznerPrimaryIPDelete(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner primary-ip delete <id|name|ip>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	pip, err := resolveHzPrimaryIP(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete primary-ip", errOrNotFound(err))
	}
	if _, derr := hc.PrimaryIP.Delete(ctx, pip); derr != nil {
		return hzFail(out, "delete primary-ip "+hzPrimaryIPLabel(pip), derr)
	}
	return hzResDone(out, "delete", "primary-ip", pip.ID, hzPrimaryIPLabel(pip), nil)
}

func runHetznerPrimaryIPAssign(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner primary-ip assign <id|name|ip> --server <s>"
	a, err := parseHzArgs(args, []string{"server"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("server") == "" {
		return useError(out, "usage", "want <id|name|ip> and --server <s> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	pip, rerr := resolveHzPrimaryIP(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "assign primary-ip", errOrNotFound(rerr))
	}
	srv, rerr := resolveHzServer(ctx, hc, a.val("server"))
	if rerr != nil {
		return hzFail(out, "assign primary-ip "+hzPrimaryIPLabel(pip), errOrNotFound(rerr))
	}
	action, _, err := hc.PrimaryIP.Assign(ctx, hcloud.PrimaryIPAssignOpts{
		ID:           pip.ID,
		AssigneeID:   srv.ID,
		AssigneeType: "server",
	})
	if err != nil {
		return hzFail(out, "assign primary-ip "+hzPrimaryIPLabel(pip), err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "assign primary-ip "+hzPrimaryIPLabel(pip)+": action failed", werr)
	}
	return hzResDone(out, "assign", "primary-ip", pip.ID, hzPrimaryIPLabel(pip), map[string]any{"server": srv.Name})
}

func runHetznerPrimaryIPUnassign(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner primary-ip unassign <id|name|ip>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	pip, err := resolveHzPrimaryIP(ctx, hc, target)
	if err != nil {
		return hzFail(out, "unassign primary-ip", errOrNotFound(err))
	}
	action, _, err := hc.PrimaryIP.Unassign(ctx, pip.ID)
	if err != nil {
		return hzFail(out, "unassign primary-ip "+hzPrimaryIPLabel(pip), err)
	}
	if werr := hzWait(ctx, hc, action); werr != nil {
		return hzFail(out, "unassign primary-ip "+hzPrimaryIPLabel(pip)+": action failed", werr)
	}
	return hzResDone(out, "unassign", "primary-ip", pip.ID, hzPrimaryIPLabel(pip), nil)
}

// ---------------------------------------------------------------------------
// placement-group
// ---------------------------------------------------------------------------

func runHetznerPlacementGroup(out *writer, g globals, args []string) int {
	if g.help || len(args) == 0 {
		printHetznerPlacementGroupHelp(out)
		if g.help {
			return exitOK
		}
		return exitUsage
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerPlacementGroupList(out, g, rest)
	case "get", "show":
		return runHetznerPlacementGroupGet(out, g, rest)
	case "create":
		return runHetznerPlacementGroupCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerPlacementGroupDelete(out, g, rest)
	default:
		out.errf("barkpark: unknown placement-group command %q", verb)
		printHetznerPlacementGroupHelp(out)
		return exitUsage
	}
}

func resolveHzPlacementGroup(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.PlacementGroup, error) {
	return hzResolve(ctx, hc.PlacementGroup.Get, "placement-group", idOrName, "bp cloud hetzner placement-group list")
}

// hzPlacementGroupRow is the structured (json/yaml) shape of one group.
func hzPlacementGroupRow(pg *hcloud.PlacementGroup) map[string]any {
	row := map[string]any{
		"id":   pg.ID,
		"name": pg.Name,
		"type": string(pg.Type),
	}
	if len(pg.Servers) > 0 {
		row["server_ids"] = pg.Servers
	}
	if created, ok := hzCreated(pg.Created); ok {
		row["created"] = created
	}
	if len(pg.Labels) > 0 {
		row["labels"] = pg.Labels
	}
	return row
}

func runHetznerPlacementGroupList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner placement-group list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	pgs, err := c.HCloud().PlacementGroup.AllWithOpts(hetznerCtx(), hcloud.PlacementGroupListOpts{})
	if err != nil {
		return hzFail(out, "list placement groups", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(pgs))
		for _, pg := range pgs {
			rows = append(rows, hzPlacementGroupRow(pg))
		}
		out.emitStructured(map[string]any{"placement_groups": rows})
		return exitOK
	}
	if len(pgs) == 0 {
		out.outf("no placement groups in this project — create one with 'bp cloud hetzner placement-group create --name <n> --type spread'")
		return exitOK
	}
	rows := make([][]string, 0, len(pgs))
	for _, pg := range pgs {
		rows = append(rows, []string{
			strconv.FormatInt(pg.ID, 10),
			hzCell(pg.Name),
			hzCell(string(pg.Type)),
			strconv.Itoa(len(pg.Servers)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "SERVERS"}, rows)
	return exitOK
}

func runHetznerPlacementGroupGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner placement-group get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	pg, err := resolveHzPlacementGroup(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get placement-group", errOrNotFound(err))
	}
	row := hzPlacementGroupRow(pg)
	if out.emitStructured(map[string]any{"placement_group": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerPlacementGroupCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner placement-group create --name <n> --type spread [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "type", "label"}, nil, usage)
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
	// spread is the only type the API offers today; default it, reject others
	// so a typo fails here instead of as a 422.
	pgType := a.val("type")
	if pgType == "" {
		pgType = string(hcloud.PlacementGroupTypeSpread)
	}
	if pgType != string(hcloud.PlacementGroupTypeSpread) {
		return useError(out, "usage", fmt.Sprintf("invalid --type %q (want spread — the only type Hetzner offers)", pgType), exitUsage)
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
	result, _, err := hc.PlacementGroup.Create(ctx, hcloud.PlacementGroupCreateOpts{
		Name:   name,
		Type:   hcloud.PlacementGroupType(pgType),
		Labels: labels,
	})
	if err != nil {
		return hzFail(out, "create placement-group "+name, err)
	}
	if result.PlacementGroup == nil {
		return useError(out, "failed", "create placement-group "+name+": the API returned no placement group", exitGeneric)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create placement-group "+name+": create action failed", werr)
	}
	return hzResDone(out, "create", "placement-group", result.PlacementGroup.ID, result.PlacementGroup.Name, map[string]any{"type": pgType})
}

func runHetznerPlacementGroupDelete(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner placement-group delete <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	pg, err := resolveHzPlacementGroup(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete placement-group", errOrNotFound(err))
	}
	if _, derr := hc.PlacementGroup.Delete(ctx, pg); derr != nil {
		return hzFail(out, "delete placement-group "+pg.Name, derr)
	}
	return hzResDone(out, "delete", "placement-group", pg.ID, pg.Name, nil)
}

// ---------------------------------------------------------------------------
// certificate
// ---------------------------------------------------------------------------

func runHetznerCertificate(out *writer, g globals, args []string) int {
	if g.help || len(args) == 0 {
		printHetznerCertificateHelp(out)
		if g.help {
			return exitOK
		}
		return exitUsage
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerCertificateList(out, g, rest)
	case "get", "show":
		return runHetznerCertificateGet(out, g, rest)
	case "create-uploaded":
		return runHetznerCertificateCreateUploaded(out, g, rest)
	case "create-managed":
		return runHetznerCertificateCreateManaged(out, g, rest)
	case "delete", "rm":
		return runHetznerCertificateDelete(out, g, rest)
	default:
		out.errf("barkpark: unknown certificate command %q", verb)
		printHetznerCertificateHelp(out)
		return exitUsage
	}
}

func resolveHzCertificate(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.Certificate, error) {
	return hzResolve(ctx, hc.Certificate.Get, "certificate", idOrName, "bp cloud hetzner certificate list")
}

// hzCertificateRow is the structured (json/yaml) shape of one certificate.
func hzCertificateRow(cert *hcloud.Certificate) map[string]any {
	row := map[string]any{
		"id":   cert.ID,
		"name": cert.Name,
		"type": string(cert.Type),
	}
	if len(cert.DomainNames) > 0 {
		row["domain_names"] = cert.DomainNames
	}
	if cert.Fingerprint != "" {
		row["fingerprint"] = cert.Fingerprint
	}
	if !cert.NotValidAfter.IsZero() {
		row["not_valid_after"] = cert.NotValidAfter.UTC().Format("2006-01-02")
	}
	if cert.Status != nil && cert.Status.Issuance != "" {
		row["issuance_status"] = string(cert.Status.Issuance)
	}
	if created, ok := hzCreated(cert.Created); ok {
		row["created"] = created
	}
	if len(cert.Labels) > 0 {
		row["labels"] = cert.Labels
	}
	return row
}

func runHetznerCertificateList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner certificate list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	certs, err := c.HCloud().Certificate.AllWithOpts(hetznerCtx(), hcloud.CertificateListOpts{})
	if err != nil {
		return hzFail(out, "list certificates", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(certs))
		for _, cert := range certs {
			rows = append(rows, hzCertificateRow(cert))
		}
		out.emitStructured(map[string]any{"certificates": rows})
		return exitOK
	}
	if len(certs) == 0 {
		out.outf("no certificates in this project — add one with 'bp cloud hetzner certificate create-managed --name <n> --domain example.com'")
		return exitOK
	}
	rows := make([][]string, 0, len(certs))
	for _, cert := range certs {
		notAfter := ""
		if !cert.NotValidAfter.IsZero() {
			notAfter = cert.NotValidAfter.UTC().Format("2006-01-02")
		}
		rows = append(rows, []string{
			strconv.FormatInt(cert.ID, 10),
			hzCell(cert.Name),
			hzCell(string(cert.Type)),
			hzCell(truncateCell(strings.Join(cert.DomainNames, ","), 40)),
			hzCell(notAfter),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "DOMAINS", "NOT-AFTER"}, rows)
	return exitOK
}

func runHetznerCertificateGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner certificate get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	cert, err := resolveHzCertificate(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get certificate", errOrNotFound(err))
	}
	row := hzCertificateRow(cert)
	if out.emitStructured(map[string]any{"certificate": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerCertificateCreateUploaded(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner certificate create-uploaded --name <n> --cert-file <f> --key-file <f> [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "cert-file", "key-file", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := a.val("name")
	if name == "" || a.val("cert-file") == "" || a.val("key-file") == "" {
		return useError(out, "usage", "--name, --cert-file and --key-file are required (usage: "+usage+")", exitUsage)
	}
	certPEM, cerr := os.ReadFile(a.val("cert-file"))
	if cerr != nil {
		return useError(out, "failed", "read --cert-file: "+cerr.Error(), exitGeneric)
	}
	keyPEM, kerr := os.ReadFile(a.val("key-file"))
	if kerr != nil {
		return useError(out, "failed", "read --key-file: "+kerr.Error(), exitGeneric)
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
	result, _, err := hc.Certificate.CreateCertificate(ctx, hcloud.CertificateCreateOpts{
		Name:        name,
		Type:        hcloud.CertificateTypeUploaded,
		Certificate: string(certPEM),
		PrivateKey:  string(keyPEM),
		Labels:      labels,
	})
	if err != nil {
		return hzFail(out, "create-uploaded certificate "+name, err)
	}
	if result.Certificate == nil {
		return useError(out, "failed", "create-uploaded certificate "+name+": the API returned no certificate", exitGeneric)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create-uploaded certificate "+name+": action failed", werr)
	}
	extra := map[string]any{"type": string(hcloud.CertificateTypeUploaded)}
	if result.Certificate.Fingerprint != "" {
		extra["fingerprint"] = result.Certificate.Fingerprint
	}
	return hzResDone(out, "create-uploaded", "certificate", result.Certificate.ID, result.Certificate.Name, extra)
}

func runHetznerCertificateCreateManaged(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner certificate create-managed --name <n> --domain <d>[,<d>…] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "domain", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := a.val("name")
	domains := a.list("domain")
	if name == "" || len(domains) == 0 {
		return useError(out, "usage", "--name and --domain are required (usage: "+usage+")", exitUsage)
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
	result, _, err := hc.Certificate.CreateCertificate(ctx, hcloud.CertificateCreateOpts{
		Name:        name,
		Type:        hcloud.CertificateTypeManaged,
		DomainNames: domains,
		Labels:      labels,
	})
	if err != nil {
		return hzFail(out, "create-managed certificate "+name, err)
	}
	if result.Certificate == nil {
		return useError(out, "failed", "create-managed certificate "+name+": the API returned no certificate", exitGeneric)
	}
	// Managed issuance runs as an action (Let's Encrypt behind the scenes) —
	// wait it so "created" always means "issued", not "pending".
	out.info("certificate %s accepted — waiting for issuance…", name)
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create-managed certificate "+name+": issuance failed", werr)
	}
	return hzResDone(out, "create-managed", "certificate", result.Certificate.ID, result.Certificate.Name, map[string]any{
		"type":         string(hcloud.CertificateTypeManaged),
		"domain_names": domains,
	})
}

func runHetznerCertificateDelete(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner certificate delete <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	cert, err := resolveHzCertificate(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete certificate", errOrNotFound(err))
	}
	if _, derr := hc.Certificate.Delete(ctx, cert); derr != nil {
		return hzFail(out, "delete certificate "+cert.Name, derr)
	}
	return hzResDone(out, "delete", "certificate", cert.ID, cert.Name, nil)
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

// printHetznerLoadBalancerHelp writes `bp cloud hetzner load-balancer` usage.
func printHetznerLoadBalancerHelp(out *writer) {
	const help = `bp cloud hetzner load-balancer — manage the project's load balancers.

USAGE
  bp cloud hetzner load-balancer list
  bp cloud hetzner load-balancer get <id|name>
  bp cloud hetzner load-balancer create --name <n> --type <t> (--location <loc> | --network-zone <z>)
                                        [--algorithm round_robin|least_connections] [--label k=v]…
  bp cloud hetzner load-balancer delete <id|name>
  bp cloud hetzner load-balancer add-service <id|name> --protocol tcp|http|https --listen-port <p>
                                             [--destination-port <p>] [--proxy-protocol]
  bp cloud hetzner load-balancer delete-service <id|name> --listen-port <p>
  bp cloud hetzner load-balancer add-target <id|name> (--server <s> | --label-selector <sel> | --ip <ip>)
                                            [--use-private-ip]
  bp cloud hetzner load-balancer remove-target <id|name> (--server <s> | --label-selector <sel> | --ip <ip>)
  bp cloud hetzner load-balancer change-algorithm <id|name> --algorithm round_robin|least_connections
  bp cloud hetzner load-balancer change-type <id|name> --type <t>
  bp cloud hetzner lb-types                          the offered types (read-only)

NOTES
  types            lb11 · lb21 · lb31 — see 'bp cloud hetzner lb-types'
  --use-private-ip route to the target over a shared private network instead of
                   its public IP (server and label-selector targets)
  --destination-port defaults to the listen port when omitted

EXAMPLE
  bp cloud hetzner load-balancer create --name web-lb --type lb11 --location nbg1
  bp cloud hetzner load-balancer add-service web-lb --protocol http --listen-port 80
  bp cloud hetzner load-balancer add-target web-lb --server web-1`
	out.outf("%s", help)
}

// printHetznerFloatingIPHelp writes `bp cloud hetzner floating-ip` usage.
func printHetznerFloatingIPHelp(out *writer) {
	const help = `bp cloud hetzner floating-ip — manage the project's floating IPs.

USAGE
  bp cloud hetzner floating-ip list
  bp cloud hetzner floating-ip get <id|name>
  bp cloud hetzner floating-ip create --type ipv4|ipv6 (--home-location <loc> | --server <s>)
                                      [--name <n>] [--label k=v]…
  bp cloud hetzner floating-ip delete <id|name>
  bp cloud hetzner floating-ip assign <id|name> --server <s>
  bp cloud hetzner floating-ip unassign <id|name>

NOTES
  create    --server both anchors the home location and assigns immediately;
            --home-location creates the IP unassigned
  assign    a floating IP moves freely between servers in any location — the
            failover primitive

EXAMPLE
  bp cloud hetzner floating-ip create --type ipv4 --server web-1 --name web-vip
  bp cloud hetzner floating-ip assign web-vip --server web-2`
	out.outf("%s", help)
}

// printHetznerPrimaryIPHelp writes `bp cloud hetzner primary-ip` usage.
func printHetznerPrimaryIPHelp(out *writer) {
	const help = `bp cloud hetzner primary-ip — manage the project's primary IPs.

USAGE
  bp cloud hetzner primary-ip list
  bp cloud hetzner primary-ip get <id|name|ip>
  bp cloud hetzner primary-ip create --type ipv4|ipv6 (--datacenter <dc> | --location <loc>)
                                     [--name <n>] [--label k=v]…
  bp cloud hetzner primary-ip delete <id|name|ip>
  bp cloud hetzner primary-ip assign <id|name|ip> --server <s>
  bp cloud hetzner primary-ip unassign <id|name|ip>

NOTES
  <id|name|ip>  primary IPs also resolve by their literal address
  assign        the target server must be powered off and in the IP's location
  unassign      detaches the IP but keeps it reserved (billed while unattached)

EXAMPLE
  bp cloud hetzner primary-ip create --type ipv4 --location nbg1 --name web-ip
  bp cloud hetzner primary-ip assign web-ip --server web-1`
	out.outf("%s", help)
}

// printHetznerPlacementGroupHelp writes `bp cloud hetzner placement-group` usage.
func printHetznerPlacementGroupHelp(out *writer) {
	const help = `bp cloud hetzner placement-group — manage the project's placement groups.

USAGE
  bp cloud hetzner placement-group list
  bp cloud hetzner placement-group get <id|name>
  bp cloud hetzner placement-group create --name <n> [--type spread] [--label k=v]…
  bp cloud hetzner placement-group delete <id|name>

NOTES
  spread   the only type Hetzner offers — servers in the group land on
           different physical hosts (blast-radius isolation)
  attach   servers join a group at create time ('bp cloud hetzner server create')
           or via the Hetzner console; a group must be empty to delete

EXAMPLE
  bp cloud hetzner placement-group create --name web-spread --type spread`
	out.outf("%s", help)
}

// printHetznerCertificateHelp writes `bp cloud hetzner certificate` usage.
func printHetznerCertificateHelp(out *writer) {
	const help = `bp cloud hetzner certificate — manage the project's TLS certificates.

USAGE
  bp cloud hetzner certificate list
  bp cloud hetzner certificate get <id|name>
  bp cloud hetzner certificate create-uploaded --name <n> --cert-file <f> --key-file <f>
  bp cloud hetzner certificate create-managed --name <n> --domain <d>[,<d>…]
  bp cloud hetzner certificate delete <id|name>

NOTES
  create-uploaded  bring your own PEM pair (certificate chain + private key)
  create-managed   Hetzner issues and renews via Let's Encrypt — the domains
                   must already point at a Hetzner load balancer; the command
                   waits for issuance to complete
  usage            certificates attach to load-balancer https services

EXAMPLE
  bp cloud hetzner certificate create-managed --name web-tls --domain example.com,www.example.com`
	out.outf("%s", help)
}
