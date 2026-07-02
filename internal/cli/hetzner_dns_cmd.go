package cli

// hetzner_dns_cmd.go is the DNS third of the PR3 resources — Hetzner's
// INTEGRATED Cloud DNS (the zone/rrset resources hcloud-go v2.44 exposes, the
// same surface internal/hetzner's DNS provider rides):
//
//	bp cloud hetzner dns zone    list · get · create · delete
//	bp cloud hetzner dns record  list · create · update · delete
//
// Records are rrsets: one (name, type) set holding one or more values. The
// apex is addressed as "@" (an empty --name means the apex too). Shared
// plumbing (hzResolve, hzResDone, parseHzArgs, hzWait) lives in
// hetzner_cmd.go / hetzner_net_cmd.go.

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

func runHetznerDNS(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerDNSHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing dns command (run `bp cloud hetzner dns -h` for usage)", exitUsage)
	}
	group, rest := args[0], args[1:]
	switch group {
	case "zone", "zones":
		return runHetznerDNSZone(out, g, rest)
	case "record", "records", "rrset", "rrsets":
		return runHetznerDNSRecord(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown dns command %q (run `bp cloud hetzner dns -h` for usage)", group), exitUsage)
	}
}

// hzZoneRef normalizes a --zone value into the SDK's name-addressed zone
// reference (trailing dots trimmed — the internal/hetzner dns.go mapping).
func hzZoneRef(zone string) *hcloud.Zone {
	return &hcloud.Zone{Name: strings.Trim(strings.TrimSpace(zone), ".")}
}

// hzRRSetName maps a record label to the API's rrset name: the apex (empty
// label) is the literal "@"; any other label rides verbatim, trailing dots
// tolerated.
func hzRRSetName(name string) string {
	name = strings.Trim(strings.TrimSpace(name), ".")
	if name == "" {
		return "@"
	}
	return name
}

// ---------------------------------------------------------------------------
// zone
// ---------------------------------------------------------------------------

func runHetznerDNSZone(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerDNSHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing dns zone command (run `bp cloud hetzner dns zone -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerDNSZoneList(out, g, rest)
	case "get", "show":
		return runHetznerDNSZoneGet(out, g, rest)
	case "create":
		return runHetznerDNSZoneCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerDNSZoneDelete(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown dns zone command %q (run `bp cloud hetzner dns zone -h` for usage)", verb), exitUsage)
	}
}

func resolveHzZone(ctx context.Context, hc *hcloud.Client, idOrName string) (*hcloud.Zone, error) {
	return hzResolve(ctx, hc.Zone.Get, "zone", strings.Trim(strings.TrimSpace(idOrName), "."), "bp cloud hetzner dns zone list")
}

// hzZoneRow is the structured (json/yaml) shape of one zone.
func hzZoneRow(z *hcloud.Zone) map[string]any {
	row := map[string]any{
		"id":   z.ID,
		"name": z.Name,
		"mode": string(z.Mode),
	}
	if z.TTL > 0 {
		row["ttl"] = z.TTL
	}
	if z.Status != "" {
		row["status"] = string(z.Status)
	}
	row["record_count"] = z.RecordCount
	if len(z.AuthoritativeNameservers.Assigned) > 0 {
		row["nameservers"] = z.AuthoritativeNameservers.Assigned
	}
	if z.Protection.Delete {
		row["delete_protection"] = true
	}
	if created, ok := hzCreated(z.Created); ok {
		row["created"] = created
	}
	if len(z.Labels) > 0 {
		row["labels"] = z.Labels
	}
	return row
}

func runHetznerDNSZoneList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner dns zone list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	zones, err := c.HCloud().Zone.AllWithOpts(hetznerCtx(), hcloud.ZoneListOpts{})
	if err != nil {
		return hzFail(out, "list dns zones", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(zones))
		for _, z := range zones {
			rows = append(rows, hzZoneRow(z))
		}
		out.emitStructured(map[string]any{"zones": rows})
		return exitOK
	}
	if len(zones) == 0 {
		out.outf("no dns zones in this project — create one with 'bp cloud hetzner dns zone create --name example.com'")
		return exitOK
	}
	rows := make([][]string, 0, len(zones))
	for _, z := range zones {
		rows = append(rows, []string{
			strconv.FormatInt(z.ID, 10),
			hzCell(z.Name),
			hzCell(string(z.Mode)),
			strconv.Itoa(z.TTL),
			hzCell(string(z.Status)),
			strconv.Itoa(z.RecordCount),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "MODE", "TTL", "STATUS", "RECORDS"}, rows)
	return exitOK
}

func runHetznerDNSZoneGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner dns zone get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	zone, err := resolveHzZone(hetznerCtx(), c.HCloud(), target)
	if err != nil {
		return hzFail(out, "get dns zone", errOrNotFound(err))
	}
	row := hzZoneRow(zone)
	if out.emitStructured(map[string]any{"zone": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerDNSZoneCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns zone create --name <domain> [--mode primary|secondary] [--ttl <s>] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"name", "mode", "ttl", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", "unexpected argument "+strconv.Quote(a.pos[0])+" (usage: "+usage+")", exitUsage)
	}
	name := strings.Trim(strings.TrimSpace(a.val("name")), ".")
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	mode := hcloud.ZoneModePrimary
	switch a.val("mode") {
	case "", "primary":
	case "secondary":
		mode = hcloud.ZoneModeSecondary
	default:
		return useError(out, "usage", "invalid --mode "+strconv.Quote(a.val("mode"))+" (want primary|secondary)", exitUsage)
	}
	labels, lerr := parseHzLabels(a.list("label"))
	if lerr != nil {
		return useError(out, "usage", lerr.Error(), exitUsage)
	}
	opts := hcloud.ZoneCreateOpts{Name: name, Mode: mode, Labels: labels}
	if t := a.val("ttl"); t != "" {
		ttl, terr := strconv.Atoi(t)
		if terr != nil || ttl <= 0 {
			return useError(out, "usage", "invalid --ttl "+strconv.Quote(t)+" (want seconds as a positive integer)", exitUsage)
		}
		opts.TTL = hcloud.Ptr(ttl)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	result, _, err := hc.Zone.Create(ctx, opts)
	if err != nil {
		return hzFail(out, "create dns zone "+name, err)
	}
	if result.Zone == nil {
		return useError(out, "failed", "create dns zone "+name+": the API returned no zone", exitGeneric)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create dns zone "+name+": create action failed", werr)
	}
	extra := map[string]any{"mode": string(mode)}
	if len(result.Zone.AuthoritativeNameservers.Assigned) > 0 {
		extra["nameservers"] = result.Zone.AuthoritativeNameservers.Assigned
	}
	return hzResDone(out, "create", "zone", result.Zone.ID, result.Zone.Name, extra)
}

func runHetznerDNSZoneDelete(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner dns zone delete <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	zone, err := resolveHzZone(ctx, hc, target)
	if err != nil {
		return hzFail(out, "delete dns zone", errOrNotFound(err))
	}
	result, _, err := hc.Zone.Delete(ctx, zone)
	if err != nil {
		return hzFail(out, "delete dns zone "+zone.Name, err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "delete dns zone "+zone.Name+": delete action failed", werr)
	}
	return hzResDone(out, "delete", "zone", zone.ID, zone.Name, nil)
}

// ---------------------------------------------------------------------------
// record (rrset)
// ---------------------------------------------------------------------------

func runHetznerDNSRecord(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerDNSHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing dns record command (run `bp cloud hetzner dns record -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerDNSRecordList(out, g, rest)
	case "create":
		return runHetznerDNSRecordCreate(out, g, rest)
	case "update":
		return runHetznerDNSRecordUpdate(out, g, rest)
	case "delete", "rm":
		return runHetznerDNSRecordDelete(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown dns record command %q (run `bp cloud hetzner dns record -h` for usage)", verb), exitUsage)
	}
}

// hzRecordType validates and normalizes a --type value against the record
// types this surface supports.
func hzRecordType(out *writer, s string) (hcloud.ZoneRRSetType, bool) {
	typ := strings.ToUpper(strings.TrimSpace(s))
	switch typ {
	case "A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA":
		return hcloud.ZoneRRSetType(typ), true
	default:
		useError(out, "usage", "invalid --type "+strconv.Quote(s)+" (want A|AAAA|CNAME|TXT|MX|NS|SRV|CAA)", exitUsage)
		return "", false
	}
}

// hzRRSetRecords builds the record values body from the repeated --value flag.
// Values ride VERBATIM (no comma-splitting — a TXT value may contain commas).
func hzRRSetRecords(values []string) []hcloud.ZoneRRSetRecord {
	records := make([]hcloud.ZoneRRSetRecord, 0, len(values))
	for _, v := range values {
		records = append(records, hcloud.ZoneRRSetRecord{Value: v})
	}
	return records
}

// hzRRSetRow is the structured (json/yaml) shape of one rrset.
func hzRRSetRow(r *hcloud.ZoneRRSet) map[string]any {
	row := map[string]any{
		"name": r.Name,
		"type": string(r.Type),
	}
	if r.ID != "" {
		row["id"] = r.ID
	}
	if r.TTL != nil {
		row["ttl"] = *r.TTL
	}
	values := make([]string, 0, len(r.Records))
	for _, rec := range r.Records {
		values = append(values, rec.Value)
	}
	row["values"] = values
	if len(r.Labels) > 0 {
		row["labels"] = r.Labels
	}
	return row
}

func runHetznerDNSRecordList(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns record list --zone <z>"
	a, err := parseHzArgs(args, []string{"zone"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 || a.val("zone") == "" {
		return useError(out, "usage", "--zone is required (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	rrsets, err := c.HCloud().Zone.AllRRSets(hetznerCtx(), hzZoneRef(a.val("zone")))
	if err != nil {
		return hzFail(out, "list dns records in zone "+a.val("zone"), err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(rrsets))
		for _, r := range rrsets {
			rows = append(rows, hzRRSetRow(r))
		}
		out.emitStructured(map[string]any{"zone": strings.Trim(strings.TrimSpace(a.val("zone")), "."), "records": rows})
		return exitOK
	}
	if len(rrsets) == 0 {
		out.outf("no records in zone %s — add one with 'bp cloud hetzner dns record create --zone %s --type A --name www --value <ip>'", a.val("zone"), a.val("zone"))
		return exitOK
	}
	rows := make([][]string, 0, len(rrsets))
	for _, r := range rrsets {
		ttl := ""
		if r.TTL != nil {
			ttl = strconv.Itoa(*r.TTL)
		}
		values := make([]string, 0, len(r.Records))
		for _, rec := range r.Records {
			values = append(values, rec.Value)
		}
		rows = append(rows, []string{
			hzCell(r.Name),
			hzCell(string(r.Type)),
			hzCell(ttl),
			hzCell(truncateCell(strings.Join(values, " "), 60)),
		})
	}
	renderHzTable(out, []string{"NAME", "TYPE", "TTL", "VALUES"}, rows)
	return exitOK
}

// hzRecordArgs parses the shared record-mutation tail: --zone, --type and
// --name are required (name "@" or "" addresses the apex).
func hzRecordArgs(out *writer, args []string, withValue bool, usage string) (*hzArgs, bool) {
	valueFlags := []string{"zone", "type", "name"}
	if withValue {
		valueFlags = append(valueFlags, "value", "ttl")
	}
	a, err := parseHzArgs(args, valueFlags, nil, usage)
	if err != nil {
		useError(out, "usage", err.Error(), exitUsage)
		return nil, false
	}
	if len(a.pos) > 0 {
		useError(out, "usage", "unexpected argument "+strconv.Quote(a.pos[0])+" (usage: "+usage+")", exitUsage)
		return nil, false
	}
	if a.val("zone") == "" || a.val("type") == "" {
		useError(out, "usage", "--zone and --type are required (usage: "+usage+")", exitUsage)
		return nil, false
	}
	if _, present := a.vals["name"]; !present {
		useError(out, "usage", "--name is required — use @ for the zone apex (usage: "+usage+")", exitUsage)
		return nil, false
	}
	return a, true
}

// hzRecordTTL parses an optional --ttl into the SDK's *int.
func hzRecordTTL(out *writer, s string) (*int, bool) {
	if s == "" {
		return nil, true
	}
	ttl, err := strconv.Atoi(s)
	if err != nil || ttl <= 0 {
		useError(out, "usage", "invalid --ttl "+strconv.Quote(s)+" (want seconds as a positive integer)", exitUsage)
		return nil, false
	}
	return hcloud.Ptr(ttl), true
}

func runHetznerDNSRecordCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns record create --zone <z> --type <t> --name <n|@> --value <v> [--value <v>…] [--ttl <s>]"
	a, ok := hzRecordArgs(out, args, true, usage)
	if !ok {
		return exitUsage
	}
	typ, ok := hzRecordType(out, a.val("type"))
	if !ok {
		return exitUsage
	}
	values := a.vals["value"]
	if len(values) == 0 {
		return useError(out, "usage", "--value is required (usage: "+usage+")", exitUsage)
	}
	ttl, ok := hzRecordTTL(out, a.val("ttl"))
	if !ok {
		return exitUsage
	}
	c, cok := hetznerClient(out, g)
	if !cok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	name := hzRRSetName(a.val("name"))
	result, _, err := hc.Zone.CreateRRSet(ctx, hzZoneRef(a.val("zone")), hcloud.ZoneRRSetCreateOpts{
		Name:    name,
		Type:    typ,
		TTL:     ttl,
		Records: hzRRSetRecords(values),
	})
	if err != nil {
		return hzFail(out, "create dns record "+name+"/"+string(typ), err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "create dns record "+name+"/"+string(typ)+": action failed", werr)
	}
	extra := map[string]any{"type": string(typ), "values": values, "zone": strings.Trim(strings.TrimSpace(a.val("zone")), ".")}
	if ttl != nil {
		extra["ttl"] = *ttl
	}
	id := any(name)
	if result.RRSet != nil && result.RRSet.ID != "" {
		id = result.RRSet.ID
	}
	return hzResDone(out, "create", "record", id, name, extra)
}

func runHetznerDNSRecordUpdate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns record update --zone <z> --type <t> --name <n|@> --value <v> [--value <v>…] [--ttl <s>]"
	a, ok := hzRecordArgs(out, args, true, usage)
	if !ok {
		return exitUsage
	}
	typ, ok := hzRecordType(out, a.val("type"))
	if !ok {
		return exitUsage
	}
	values := a.vals["value"]
	ttl, ok := hzRecordTTL(out, a.val("ttl"))
	if !ok {
		return exitUsage
	}
	if len(values) == 0 && ttl == nil {
		return useError(out, "usage", "nothing to update — pass --value and/or --ttl (usage: "+usage+")", exitUsage)
	}
	c, cok := hetznerClient(out, g)
	if !cok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	name := hzRRSetName(a.val("name"))
	rrset := &hcloud.ZoneRRSet{Zone: hzZoneRef(a.val("zone")), Name: name, Type: typ}
	if len(values) > 0 {
		action, _, err := hc.Zone.SetRRSetRecords(ctx, rrset, hcloud.ZoneRRSetSetRecordsOpts{Records: hzRRSetRecords(values)})
		if err != nil {
			return hzFail(out, "update dns record "+name+"/"+string(typ), err)
		}
		if werr := hzWait(ctx, hc, action); werr != nil {
			return hzFail(out, "update dns record "+name+"/"+string(typ)+": set-records action failed", werr)
		}
	}
	if ttl != nil {
		action, _, err := hc.Zone.ChangeRRSetTTL(ctx, rrset, hcloud.ZoneRRSetChangeTTLOpts{TTL: ttl})
		if err != nil {
			return hzFail(out, "update dns record "+name+"/"+string(typ)+": change-ttl", err)
		}
		if werr := hzWait(ctx, hc, action); werr != nil {
			return hzFail(out, "update dns record "+name+"/"+string(typ)+": change-ttl action failed", werr)
		}
	}
	extra := map[string]any{"type": string(typ), "zone": strings.Trim(strings.TrimSpace(a.val("zone")), ".")}
	if len(values) > 0 {
		extra["values"] = values
	}
	if ttl != nil {
		extra["ttl"] = *ttl
	}
	return hzResDone(out, "update", "record", name, name, extra)
}

func runHetznerDNSRecordDelete(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns record delete --zone <z> --type <t> --name <n|@>"
	a, ok := hzRecordArgs(out, args, false, usage)
	if !ok {
		return exitUsage
	}
	typ, ok := hzRecordType(out, a.val("type"))
	if !ok {
		return exitUsage
	}
	c, cok := hetznerClient(out, g)
	if !cok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	name := hzRRSetName(a.val("name"))
	rrset := &hcloud.ZoneRRSet{Zone: hzZoneRef(a.val("zone")), Name: name, Type: typ}
	result, _, err := hc.Zone.DeleteRRSet(ctx, rrset)
	if err != nil {
		return hzFail(out, "delete dns record "+name+"/"+string(typ), err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "delete dns record "+name+"/"+string(typ)+": action failed", werr)
	}
	return hzResDone(out, "delete", "record", name, name, map[string]any{
		"type": string(typ),
		"zone": strings.Trim(strings.TrimSpace(a.val("zone")), "."),
	})
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

// printHetznerDNSHelp writes `bp cloud hetzner dns` usage.
func printHetznerDNSHelp(out *writer) {
	const help = `bp cloud hetzner dns — manage Hetzner Cloud DNS zones and records.

USAGE
  bp cloud hetzner dns zone list
  bp cloud hetzner dns zone get <id|name>
  bp cloud hetzner dns zone create --name <domain> [--mode primary|secondary] [--ttl <s>]
  bp cloud hetzner dns zone delete <id|name>
  bp cloud hetzner dns record list --zone <z>
  bp cloud hetzner dns record create --zone <z> --type <t> --name <n|@> --value <v>
                                     [--value <v>…] [--ttl <s>]
  bp cloud hetzner dns record update --zone <z> --type <t> --name <n|@>
                                     [--value <v>…] [--ttl <s>]
  bp cloud hetzner dns record delete --zone <z> --type <t> --name <n|@>

NOTES
  records are rrsets  one (--name, --type) pair holds ALL its values; create
                      takes --value repeatedly, update REPLACES the whole set
  --name              the record label ("www"), or @ for the zone apex
  --type              A · AAAA · CNAME · TXT · MX · NS · SRV · CAA
  MX / SRV            the priority rides inside --value ("10 mail.example.com")
  zone create         prints the authoritative nameservers to delegate to

EXAMPLE
  bp cloud hetzner dns zone create --name example.com
  bp cloud hetzner dns record create --zone example.com --type A --name www --value 192.0.2.10 --ttl 300
  bp cloud hetzner dns record create --zone example.com --type MX --name @ --value "10 mail.example.com"`
	out.outf("%s", help)
}
