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
	"slices"
	"sort"
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

// THE DNS OBSERVERS (PDS wave 32). Both DNS read paths in hcloud-go v2.44
// swallow a 404 into `(nil, resp, nil)` — `if IsError(err, ErrorCodeNotFound) {
// return nil, resp, nil }` in ZoneClient.getByIDOrName (zone.go) and in
// GetRRSetByNameAndType (zone_rrset.go). That is precisely the
// hzResGoneRead[T] triple, so these plug into the MUTATION half with no new
// apparatus — and it is why they must never be paid with hzResDestroyed, whose
// (nil, nil) branch would report `confirmed_gone:true` for a create.

// hzObserveZoneCreated reads the create receipt off the create RESPONSE object.
// The ADVISORY pair is the RAW --mode token: hzResDivergence skips an empty
// `asked`, so an unset --mode simply does not compare, while passing the
// RESOLVED mode would be degenerately always-equal — an advisory that can never
// fire is apparatus nobody can test.
func hzObserveZoneCreated(askedMode string) hzResObserveFn[hcloud.Zone] {
	return func(zone *hcloud.Zone) hzResObservation {
		extra := map[string]any{"mode": string(zone.Mode), "record_count": zone.RecordCount}
		if zone.TTL > 0 {
			extra["ttl"] = zone.TTL
		}
		if zone.Status != "" {
			extra["status"] = string(zone.Status)
		}
		if len(zone.AuthoritativeNameservers.Assigned) > 0 {
			extra["nameservers"] = zone.AuthoritativeNameservers.Assigned
		}
		return hzResAgreesWith(extra, hzResDivergence(
			hzResAsked{"mode", askedMode, string(zone.Mode)},
		))
	}
}

// hzObserveZoneUpdated confirms `dns zone update` against the zone the API now
// reports. Both halves are OPTIONAL — the verb refuses upfront unless at least
// one was given — so each is compared only when it was asked for.
func hzObserveZoneUpdated(wantTTL *int, wantLabels map[string]string) hzResObserveFn[hcloud.Zone] {
	return func(zone *hcloud.Zone) hzResObservation {
		if wantTTL != nil && zone.TTL != *wantTTL {
			return hzResDisagrees("ttl", strconv.Itoa(zone.TTL), strconv.Itoa(*wantTTL))
		}
		for k, want := range wantLabels {
			got, present := zone.Labels[k]
			if !present {
				return hzResDisagrees("labels", "no label "+strconv.Quote(k), strconv.Quote(k)+"="+strconv.Quote(want))
			}
			if got != want {
				return hzResDisagrees("labels", strconv.Quote(k)+"="+strconv.Quote(got),
					strconv.Quote(k)+"="+strconv.Quote(want))
			}
		}
		extra := map[string]any{"ttl": zone.TTL, "record_count": zone.RecordCount}
		if len(zone.Labels) > 0 {
			extra["labels"] = zone.Labels
		}
		return hzResAgrees(extra)
	}
}

// hzRRSetValues reads the values an rrset NOW holds.
func hzRRSetValues(rrset *hcloud.ZoneRRSet) []string {
	values := make([]string, 0, len(rrset.Records))
	for _, rec := range rrset.Records {
		values = append(values, rec.Value)
	}
	return values
}

// hzObserveRecordCreated reads the create receipt off the create RESPONSE
// object's rrset.
func hzObserveRecordCreated(rrset *hcloud.ZoneRRSet) hzResObservation {
	extra := map[string]any{
		"type":   string(rrset.Type),
		"values": hzRRSetValues(rrset),
	}
	if rrset.TTL != nil {
		extra["ttl"] = *rrset.TTL
	}
	if rrset.Zone != nil && rrset.Zone.Name != "" {
		extra["zone"] = rrset.Zone.Name
	}
	return hzResAgrees(extra)
}

// hzObserveRecordUpdated confirms `dns record update` by re-reading the rrset on
// the (zone, name, type) key the verb already holds. Values are compared as a
// SET-EQUAL multiset in order-insensitive fashion: the API is free to reorder an
// rrset's records, and refusing on order would red a correct update.
func hzObserveRecordUpdated(wantValues []string, wantTTL *int) hzResObserveFn[hcloud.ZoneRRSet] {
	return func(rrset *hcloud.ZoneRRSet) hzResObservation {
		observed := hzRRSetValues(rrset)
		if len(wantValues) > 0 {
			got := slices.Clone(observed)
			want := slices.Clone(wantValues)
			sort.Strings(got)
			sort.Strings(want)
			if !slices.Equal(got, want) {
				return hzResDisagrees("values", fmt.Sprintf("%v", observed), fmt.Sprintf("%v", wantValues))
			}
		}
		if wantTTL != nil {
			if rrset.TTL == nil {
				return hzResDisagrees("ttl", "no ttl at all", strconv.Itoa(*wantTTL))
			}
			if *rrset.TTL != *wantTTL {
				return hzResDisagrees("ttl", strconv.Itoa(*rrset.TTL), strconv.Itoa(*wantTTL))
			}
		}
		extra := map[string]any{"type": string(rrset.Type), "values": observed}
		if rrset.TTL != nil {
			extra["ttl"] = *rrset.TTL
		}
		if rrset.Zone != nil && rrset.Zone.Name != "" {
			extra["zone"] = rrset.Zone.Name
		}
		return hzResAgrees(extra)
	}
}

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
	case "update":
		return runHetznerDNSZoneUpdate(out, g, rest)
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

func runHetznerDNSZoneUpdate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns zone update <id|name> [--ttl <s>] [--label k=v]…"
	a, err := parseHzArgs(args, []string{"ttl", "label"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
	}
	_, hasLabel := a.vals["label"]
	ttlStr := a.val("ttl")
	if !hasLabel && ttlStr == "" {
		return useError(out, "usage", "nothing to update — pass --ttl and/or --label (usage: "+usage+")", exitUsage)
	}
	var ttl *int
	if ttlStr != "" {
		n, terr := strconv.Atoi(ttlStr)
		if terr != nil || n <= 0 {
			return useError(out, "usage", "invalid --ttl "+strconv.Quote(ttlStr)+" (want seconds as a positive integer)", exitUsage)
		}
		ttl = hcloud.Ptr(n)
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
	zone, rerr := resolveHzZone(ctx, hc, a.pos[0])
	if rerr != nil {
		return hzFail(out, "update dns zone", errOrNotFound(rerr))
	}
	if hasLabel {
		if _, _, uerr := hc.Zone.Update(ctx, zone, hcloud.ZoneUpdateOpts{Labels: labels}); uerr != nil {
			return hzFail(out, "update dns zone "+zone.Name, uerr)
		}
	}
	if ttl != nil {
		action, _, terr := hc.Zone.ChangeTTL(ctx, zone, hcloud.ZoneChangeTTLOpts{TTL: *ttl})
		if terr != nil {
			return hzFail(out, "update dns zone "+zone.Name+": change-ttl", terr)
		}
		if werr := hzWait(ctx, hc, action); werr != nil {
			return hzFail(out, "update dns zone "+zone.Name+": change-ttl action failed", werr)
		}
	}
	// The update rides two ACTION/PATCH endpoints that report nothing about the
	// settled zone, so the single-resource GET on the RESOLVED id is the only
	// server-side source. Only what was ASKED FOR is compared.
	wantLabels := map[string]string(nil)
	if hasLabel {
		wantLabels = labels
	}
	return hzResObserved(out, ctx, "update", "zone", zone.ID, zone.Name, nil,
		func(c context.Context) (*hcloud.Zone, *hcloud.Response, error) { return hc.Zone.GetByID(c, zone.ID) },
		hzObserveZoneUpdated(ttl, wantLabels))
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
	// CLASS A2, with the RAW --mode token as the advisory's asked side.
	return hzResObservedResponse(out, "create", "zone", result.Zone.ID, result.Zone.Name,
		nil, result.Zone, hzObserveZoneCreated(a.val("mode")))
}

func runHetznerDNSZoneDelete(out *writer, g globals, args []string) int {
	target, yes, ok := hzOneTargetYes(out, args, "bp cloud hetzner dns zone delete <id|name> [--yes]")
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
	if cerr := hzConfirmDestroy(hzStdin, out, "dns zone", zone.Name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	result, _, err := hc.Zone.Delete(ctx, zone)
	if err != nil {
		return hzFail(out, "delete dns zone "+zone.Name, err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "delete dns zone "+zone.Name+": delete action failed", werr)
	}
	// The zone is the one benign kind: hc.Zone.Get is a single GET /zones/{id}
	// with no name-filtered fallback. The gone-check binds to zone.ID anyway —
	// PDS-D400 is a rule about the SHAPE of a destroy confirmation, not a
	// per-kind escape hatch.
	return hzResDestroyed(out, ctx, "delete", "zone", zone.ID, zone.Name, nil,
		func(c context.Context) (*hcloud.Zone, *hcloud.Response, error) { return hc.Zone.GetByID(c, zone.ID) })
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
	case "get", "show":
		return runHetznerDNSRecordGet(out, g, rest)
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

func runHetznerDNSRecordGet(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns record get --zone <z> --type <t> --name <n|@>"
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
	name := hzRRSetName(a.val("name"))
	zoneName := strings.Trim(strings.TrimSpace(a.val("zone")), ".")
	rrset, _, err := c.HCloud().Zone.GetRRSetByNameAndType(ctx, hzZoneRef(a.val("zone")), name, typ)
	if err != nil {
		return hzFail(out, "get dns record "+name+"/"+string(typ), err)
	}
	if rrset == nil {
		return hzFail(out, "get dns record "+name+"/"+string(typ),
			errOrNotFound(fmt.Errorf("record %s/%s not found in zone %s (see `bp cloud hetzner dns record list --zone %s`)", name, string(typ), zoneName, zoneName)))
	}
	row := hzRRSetRow(rrset)
	if out.emitStructured(map[string]any{"record": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

// hzRecordArgs parses the shared record-mutation tail: --zone, --type and
// --name are required (name "@" or "" addresses the apex). boolFlags lets the
// destroy-tier delete declare --yes without create/update growing it.
func hzRecordArgs(out *writer, args []string, withValue bool, usage string, boolFlags ...string) (*hzArgs, bool) {
	valueFlags := []string{"zone", "type", "name"}
	if withValue {
		valueFlags = append(valueFlags, "value", "ttl")
	}
	a, err := parseHzArgs(args, valueFlags, boolFlags, usage)
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
	// THE EMPTY-ID COLLAPSE, AND WHY THE OBVIOUS PAINT DOES NOT WORK. Handing
	// `result.RRSet` straight to hzResObservedResponse produces NO refusal:
	// hcloud-go's generated ZoneRRSetFromSchema takes a schema VALUE and returns
	// a freshly-allocated pointer assigned unconditionally, so result.RRSet is
	// never nil — a create response with no `rrset` key would exit 0 with
	// confirmed_present:true and EMPTY observed fields, which is WORSE than the
	// argv echo it replaces. Collapsing an id-less rrset to nil is what makes the
	// refusal reachable. LIVE BEHAVIOUR CHANGE: `bp cloud hetzner dns record
	// create` now exits non-zero (hzResNotReadable) when the API accepts the
	// create and hands back no usable rrset.
	obj := result.RRSet
	if obj != nil && obj.ID == "" {
		obj = nil
	}
	id := any(name)
	if obj != nil {
		id = obj.ID
	}
	return hzResObservedResponse(out, "create", "record", id, name, nil, obj, hzObserveRecordCreated)
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
	// `record` IS payable even though it resolves no numeric id: the read is a
	// single-resource GET on the (zone, name, type) key the verb ALREADY HOLDS,
	// so the confirming read cannot address a second rrset.
	return hzResObserved(out, ctx, "update", "record", name, name, nil,
		func(c context.Context) (*hcloud.ZoneRRSet, *hcloud.Response, error) {
			return hc.Zone.GetRRSetByNameAndType(c, rrset.Zone, rrset.Name, rrset.Type)
		}, hzObserveRecordUpdated(values, ttl))
}

func runHetznerDNSRecordDelete(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner dns record delete --zone <z> --type <t> --name <n|@> [--yes]"
	a, ok := hzRecordArgs(out, args, false, usage, "yes")
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
	if cerr := hzConfirmDestroy(hzStdin, out, "dns "+string(typ)+" record", name, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	rrset := &hcloud.ZoneRRSet{Zone: hzZoneRef(a.val("zone")), Name: name, Type: typ}
	result, _, err := hc.Zone.DeleteRRSet(ctx, rrset)
	if err != nil {
		return hzFail(out, "delete dns record "+name+"/"+string(typ), err)
	}
	if werr := hzWait(ctx, hc, result.Action); werr != nil {
		return hzFail(out, "delete dns record "+name+"/"+string(typ)+": action failed", werr)
	}
	// A record resolves nothing, so there is no numeric id to bind to. It is
	// read back by the (zone, name, type) key the verb ALREADY HOLDS — the same
	// PDS-D400 discipline one level up: the confirming read cannot address a
	// second rrset.
	return hzResDestroyed(out, ctx, "delete", "record", name, name, map[string]any{
		"type": string(typ),
		"zone": strings.Trim(strings.TrimSpace(a.val("zone")), "."),
	}, func(c context.Context) (*hcloud.ZoneRRSet, *hcloud.Response, error) {
		return hc.Zone.GetRRSetByNameAndType(c, rrset.Zone, rrset.Name, rrset.Type)
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
  bp cloud hetzner dns zone update <id|name> [--ttl <s>] [--label k=v]…
  bp cloud hetzner dns zone delete <id|name> [--yes]
  bp cloud hetzner dns record list --zone <z>
  bp cloud hetzner dns record get --zone <z> --type <t> --name <n|@>
  bp cloud hetzner dns record create --zone <z> --type <t> --name <n|@> --value <v>
                                     [--value <v>…] [--ttl <s>]
  bp cloud hetzner dns record update --zone <z> --type <t> --name <n|@>
                                     [--value <v>…] [--ttl <s>]
  bp cloud hetzner dns record delete --zone <z> --type <t> --name <n|@> [--yes]

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
