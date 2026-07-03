package cli

// hetzner_overview_cmd.go is `bp cloud hetzner overview` — one page for the
// whole Hetzner estate, and the REFERENCE implementation of the GUI/CLI shared
// infrastructure contract (epic charter, decision 4): the -o json envelope this
// verb prints is byte-asserted against the committed golden fixture
// cloud/priv/static/__fixtures__/hetzner_overview.json, and the control-plane
// proxy (/v1/hetzner/overview) plus the dashboard's Infrastructure panel emit
// and render the SAME shape in later waves. The envelope is frozen:
//
//	{"ok":true, "fetched_at":RFC3339, "provider":{"kind","label"},
//	 "resources":{nine keys → row arrays}, "counts":{one int per key}}
//
// plus an "errors" map ONLY when a kind degraded. Nine kinds exactly —
// servers, volumes, networks, firewalls, load_balancers, floating_ips,
// primary_ips, dns_zones, backups (backups = the project's backup images;
// Object Storage is a separate credential plane and excluded in v1). The nine
// lists fan out CONCURRENTLY, and one kind failing must not zero the others:
// that kind rides as null with an errors entry, ok stays true while anything
// loaded. Rows are deliberately lean (id/name/status + a few fields) — the
// full detail is one `bp cloud hetzner <kind> get` away.

import (
	"context"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// hzOverviewLabel is the human name the envelope's provider block carries.
const hzOverviewLabel = "Hetzner Cloud"

// hetznerOverviewNow is the clock fetched_at rides on. A package var so the
// golden-fixture test can pin it and assert the envelope byte-for-byte.
var hetznerOverviewNow = time.Now

// hzOverviewKind is one resource kind of the overview: its charter key, its
// table columns (headers + the row keys they render), and the list call.
type hzOverviewKind struct {
	key     string
	headers []string
	cols    []string
	list    func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error)
}

// hzOverviewStatus dashes a kind (or row) that has no status into the
// contract's literal "n/a", so every row always carries the key.
func hzOverviewStatus(s string) string {
	if s == "" {
		return "n/a"
	}
	return s
}

// hzOverviewKinds is the closed, charter-frozen set of resource kinds, in the
// order the table view renders them. The JSON envelope's key order is the
// encoder's sorted-map order regardless.
func hzOverviewKinds() []hzOverviewKind {
	return []hzOverviewKind{
		{
			key:     "servers",
			headers: []string{"ID", "NAME", "STATUS", "TYPE", "LOCATION", "IPV4"},
			cols:    []string{"id", "name", "status", "server_type", "location", "ipv4"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				servers, err := hc.Server.AllWithOpts(ctx, hcloud.ServerListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(servers))
				for _, s := range servers {
					row := map[string]any{"id": s.ID, "name": s.Name, "status": hzOverviewStatus(string(s.Status))}
					if s.ServerType != nil {
						row["server_type"] = s.ServerType.Name
					}
					if loc := hzServerLocation(s); loc != "" {
						row["location"] = loc
					}
					if ip := hzIPv4(s); ip != "" {
						row["ipv4"] = ip
					}
					if created, ok := hzCreated(s.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "volumes",
			headers: []string{"ID", "NAME", "STATUS", "SIZE_GB", "SERVER", "LOCATION"},
			cols:    []string{"id", "name", "status", "size_gb", "server_id", "location"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				volumes, err := hc.Volume.AllWithOpts(ctx, hcloud.VolumeListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(volumes))
				for _, v := range volumes {
					row := map[string]any{"id": v.ID, "name": v.Name, "status": hzOverviewStatus(string(v.Status)), "size_gb": v.Size}
					if v.Server != nil {
						row["server_id"] = v.Server.ID
					}
					if v.Location != nil {
						row["location"] = v.Location.Name
					}
					if created, ok := hzCreated(v.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "networks",
			headers: []string{"ID", "NAME", "STATUS", "IP_RANGE", "SERVERS"},
			cols:    []string{"id", "name", "status", "ip_range", "server_count"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				networks, err := hc.Network.AllWithOpts(ctx, hcloud.NetworkListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(networks))
				for _, n := range networks {
					row := map[string]any{"id": n.ID, "name": n.Name, "status": "n/a", "server_count": len(n.Servers)}
					if n.IPRange != nil {
						row["ip_range"] = n.IPRange.String()
					}
					if created, ok := hzCreated(n.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "firewalls",
			headers: []string{"ID", "NAME", "STATUS", "RULES", "APPLIED_TO"},
			cols:    []string{"id", "name", "status", "rule_count", "applied_to_count"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				firewalls, err := hc.Firewall.AllWithOpts(ctx, hcloud.FirewallListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(firewalls))
				for _, f := range firewalls {
					row := map[string]any{"id": f.ID, "name": f.Name, "status": "n/a",
						"rule_count": len(f.Rules), "applied_to_count": len(f.AppliedTo)}
					if created, ok := hzCreated(f.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "load_balancers",
			headers: []string{"ID", "NAME", "STATUS", "TYPE", "LOCATION", "IPV4"},
			cols:    []string{"id", "name", "status", "type", "location", "ipv4"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				lbs, err := hc.LoadBalancer.AllWithOpts(ctx, hcloud.LoadBalancerListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(lbs))
				for _, lb := range lbs {
					row := map[string]any{"id": lb.ID, "name": lb.Name, "status": "n/a",
						"service_count": len(lb.Services), "target_count": len(lb.Targets)}
					if lb.LoadBalancerType != nil {
						row["type"] = lb.LoadBalancerType.Name
					}
					if lb.Location != nil {
						row["location"] = lb.Location.Name
					}
					if lb.PublicNet.IPv4.IP != nil {
						row["ipv4"] = lb.PublicNet.IPv4.IP.String()
					}
					if created, ok := hzCreated(lb.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "floating_ips",
			headers: []string{"ID", "NAME", "STATUS", "IP", "TYPE", "SERVER"},
			cols:    []string{"id", "name", "status", "ip", "type", "server_id"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				fips, err := hc.FloatingIP.AllWithOpts(ctx, hcloud.FloatingIPListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(fips))
				for _, f := range fips {
					row := map[string]any{"id": f.ID, "name": hzFloatingIPLabel(f), "status": "n/a", "type": string(f.Type)}
					if f.IP != nil {
						row["ip"] = f.IP.String()
					}
					if f.Server != nil {
						row["server_id"] = f.Server.ID
					}
					if created, ok := hzCreated(f.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "primary_ips",
			headers: []string{"ID", "NAME", "STATUS", "IP", "TYPE", "ASSIGNEE"},
			cols:    []string{"id", "name", "status", "ip", "type", "assignee_id"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				pips, err := hc.PrimaryIP.AllWithOpts(ctx, hcloud.PrimaryIPListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(pips))
				for _, p := range pips {
					row := map[string]any{"id": p.ID, "name": hzPrimaryIPLabel(p), "status": "n/a", "type": string(p.Type)}
					if p.IP != nil {
						row["ip"] = p.IP.String()
					}
					if p.AssigneeID != 0 {
						row["assignee_id"] = p.AssigneeID
					}
					if created, ok := hzCreated(p.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			key:     "dns_zones",
			headers: []string{"ID", "NAME", "STATUS", "MODE", "RECORDS"},
			cols:    []string{"id", "name", "status", "mode", "record_count"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				zones, err := hc.Zone.AllWithOpts(ctx, hcloud.ZoneListOpts{})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(zones))
				for _, z := range zones {
					row := map[string]any{"id": z.ID, "name": z.Name, "status": hzOverviewStatus(string(z.Status)),
						"mode": string(z.Mode), "record_count": z.RecordCount}
					if created, ok := hzCreated(z.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
		{
			// backups = the project's backup IMAGES (the hcloud token's plane).
			// Postgres/S3 backups need Object Storage credentials — a separate
			// credential plane, excluded from the overview by charter.
			key:     "backups",
			headers: []string{"ID", "NAME", "STATUS", "CREATED_FROM", "CREATED"},
			cols:    []string{"id", "name", "status", "created_from", "created"},
			list: func(ctx context.Context, hc *hcloud.Client) ([]map[string]any, error) {
				imgs, err := hc.Image.AllWithOpts(ctx, hcloud.ImageListOpts{Type: []hcloud.ImageType{hcloud.ImageTypeBackup}})
				if err != nil {
					return nil, err
				}
				rows := make([]map[string]any, 0, len(imgs))
				for _, im := range imgs {
					row := map[string]any{"id": im.ID, "name": hzImageLabel(im), "status": hzOverviewStatus(string(im.Status))}
					if im.CreatedFrom != nil {
						if im.CreatedFrom.Name != "" {
							row["created_from"] = im.CreatedFrom.Name
						} else {
							row["created_from"] = strconv.FormatInt(im.CreatedFrom.ID, 10)
						}
					}
					if created, ok := hzCreated(im.Created); ok {
						row["created"] = created
					}
					rows = append(rows, row)
				}
				return rows, nil
			},
		},
	}
}

// runHetznerOverview is `bp cloud hetzner overview`: fan out to all nine list
// calls concurrently, assemble the charter envelope, render json/yaml/table.
func runHetznerOverview(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerOverviewHelp(out)
		return exitOK
	}
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner overview"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	kinds := hzOverviewKinds()

	type hzOverviewResult struct {
		rows []map[string]any
		err  error
	}
	results := make([]hzOverviewResult, len(kinds))
	var wg sync.WaitGroup
	for i, k := range kinds {
		wg.Add(1)
		go func(i int, k hzOverviewKind) {
			defer wg.Done()
			rows, err := k.list(ctx, hc)
			results[i] = hzOverviewResult{rows: rows, err: err}
		}(i, k)
	}
	wg.Wait()

	// Assemble the frozen envelope. A degraded kind rides as null (NOT an
	// empty array — the panel must distinguish "nothing there" from "could
	// not load") with an errors entry; ok stays true while any kind loaded.
	resources := make(map[string]any, len(kinds))
	counts := make(map[string]any, len(kinds))
	kindErrs := map[string]any{}
	var firstErr error
	loaded := 0
	for i, k := range kinds {
		if results[i].err != nil {
			resources[k.key] = nil
			counts[k.key] = 0
			kindErrs[k.key] = results[i].err.Error()
			if firstErr == nil {
				firstErr = results[i].err
			}
			continue
		}
		loaded++
		resources[k.key] = results[i].rows
		counts[k.key] = len(results[i].rows)
	}
	if loaded == 0 {
		// Nothing loaded — that is not a degraded overview, it is a failure
		// (bad token, unreachable API). Report the first error cleanly.
		return hzFail(out, "overview", firstErr)
	}

	fetchedAt := hetznerOverviewNow().UTC().Format(time.RFC3339)
	payload := map[string]any{
		"ok":         true,
		"fetched_at": fetchedAt,
		"provider":   map[string]any{"kind": "hetzner", "label": hzOverviewLabel},
		"resources":  resources,
		"counts":     counts,
	}
	if len(kindErrs) > 0 {
		payload["errors"] = kindErrs
	}
	if out.emitStructured(payload) {
		return exitOK
	}

	// Table view: the counts summary first (every kind, honest "error" for a
	// degraded one), then a lean per-kind section for each non-empty kind.
	out.outf("hetzner — %s · fetched %s", hzOverviewLabel, fetchedAt)
	out.outf("")
	countRows := make([][]string, 0, len(kinds))
	for i, k := range kinds {
		count := strconv.Itoa(len(results[i].rows))
		if results[i].err != nil {
			count = "error"
		}
		countRows = append(countRows, []string{k.key, count})
	}
	renderHzTable(out, []string{"KIND", "COUNT"}, countRows)
	for i, k := range kinds {
		if results[i].err != nil {
			out.outf("")
			out.outf("! %s failed: %s — the other kinds are live", k.key, results[i].err.Error())
		}
	}
	for i, k := range kinds {
		if results[i].err != nil || len(results[i].rows) == 0 {
			continue
		}
		out.outf("")
		out.outf("%s (%d)", strings.ToUpper(k.key), len(results[i].rows))
		cells := make([][]string, 0, len(results[i].rows))
		for _, row := range results[i].rows {
			line := make([]string, len(k.cols))
			for j, col := range k.cols {
				line[j] = hzCell(cellString(row[col]))
			}
			cells = append(cells, line)
		}
		renderHzTable(out, k.headers, cells)
	}
	return exitOK
}

// printHetznerOverviewHelp writes `bp cloud hetzner overview` usage.
func printHetznerOverviewHelp(out *writer) {
	const help = `bp cloud hetzner overview — the whole estate on one page (read-only).

USAGE
  bp cloud hetzner overview [-o table|json|yaml]

Lists all nine resource kinds concurrently — servers, volumes, networks,
firewalls, load-balancers, floating-ips, primary-ips, dns zones and backup
images — and renders per-kind counts plus lean rows (id, name, status and a
few kind fields). Full detail stays one 'bp cloud hetzner <kind> get' away.

The -o json envelope is the shared GUI/CLI infrastructure contract: the cloud
dashboard's Infrastructure panel renders exactly this shape. If one kind fails
to load it is reported as null with an "errors" entry — the others still ride.

EXAMPLES
  bp cloud hetzner overview
  bp cloud hetzner overview -o json | jq .counts`
	out.outf("%s", help)
}
