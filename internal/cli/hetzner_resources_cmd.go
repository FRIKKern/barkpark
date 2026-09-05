package cli

// hetzner_resources_cmd.go carries the non-server halves of `bp cloud hetzner`:
// the ssh-key CRUD and the read-only discovery views (server-types, locations,
// datacenters, images, isos, pricing), plus every help text of the namespace.
// The server verbs and the shared plumbing (client/auth, parsing, tables,
// action waiting) live in hetzner_cmd.go.

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// ---------------------------------------------------------------------------
// ssh-key
// ---------------------------------------------------------------------------

func runHetznerSSHKey(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerSSHKeyHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing ssh-key command (run `bp cloud hetzner ssh-key -h` for usage)", exitUsage)
	}
	verb := args[0]
	rest := args[1:]
	switch verb {
	case "list", "ls":
		return runHetznerSSHKeyList(out, g, rest)
	case "get", "show":
		return runHetznerSSHKeyGet(out, g, rest)
	case "create":
		return runHetznerSSHKeyCreate(out, g, rest)
	case "delete", "rm":
		return runHetznerSSHKeyDelete(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown ssh-key command %q (run `bp cloud hetzner ssh-key -h` for usage)", verb), exitUsage)
	}
}

// hzSSHKeyRow is the structured shape of one ssh key. The public key itself
// only rides on the single-key views (get/create) — a list stays scannable.
func hzSSHKeyRow(k *hcloud.SSHKey, withPublicKey bool) map[string]any {
	row := map[string]any{
		"id":          k.ID,
		"name":        k.Name,
		"fingerprint": k.Fingerprint,
	}
	if withPublicKey {
		row["public_key"] = k.PublicKey
	}
	if !k.Created.IsZero() {
		row["created"] = k.Created.UTC().Format(time.RFC3339)
	}
	if len(k.Labels) > 0 {
		row["labels"] = k.Labels
	}
	return row
}

func runHetznerSSHKeyList(out *writer, g globals, args []string) int {
	if _, err := parseHzArgs(args, nil, nil, "bp cloud hetzner ssh-key list"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	keys, err := c.HCloud().SSHKey.All(hetznerCtx())
	if err != nil {
		return hzFail(out, "list ssh keys", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(keys))
		for _, k := range keys {
			rows = append(rows, hzSSHKeyRow(k, false))
		}
		out.emitStructured(map[string]any{"ssh_keys": rows})
		return exitOK
	}
	if len(keys) == 0 {
		out.outf("no ssh keys in this project — add one with 'bp cloud hetzner ssh-key create --name <n> --public-key-file ~/.ssh/id_ed25519.pub'")
		return exitOK
	}
	rows := make([][]string, 0, len(keys))
	for _, k := range keys {
		created := ""
		if !k.Created.IsZero() {
			created = k.Created.UTC().Format("2006-01-02")
		}
		rows = append(rows, []string{
			strconv.FormatInt(k.ID, 10),
			hzCell(k.Name),
			hzCell(k.Fingerprint),
			hzCell(created),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "FINGERPRINT", "CREATED"}, rows)
	return exitOK
}

func runHetznerSSHKeyGet(out *writer, g globals, args []string) int {
	target, ok := hzOneTarget(out, args, "bp cloud hetzner ssh-key get <id|name>")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	keys, err := resolveHzSSHKeys(hetznerCtx(), c.HCloud(), []string{target})
	if err != nil {
		return hzFail(out, "get ssh key", errOrNotFound(err))
	}
	row := hzSSHKeyRow(keys[0], true)
	if out.emitStructured(map[string]any{"ssh_key": row}) {
		return exitOK
	}
	renderKV(out, row)
	return exitOK
}

func runHetznerSSHKeyCreate(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner ssh-key create --name <n> (--public-key <k> | --public-key-file <f>)"
	a, err := parseHzArgs(args, []string{"name", "public-key", "public-key-file"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := a.val("name")
	pub := a.val("public-key")
	file := a.val("public-key-file")
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	if (pub == "") == (file == "") {
		return useError(out, "usage", "want exactly one of --public-key or --public-key-file (usage: "+usage+")", exitUsage)
	}
	if file != "" {
		data, rerr := os.ReadFile(file)
		if rerr != nil {
			return useError(out, "failed", "read --public-key-file: "+rerr.Error(), exitGeneric)
		}
		pub = strings.TrimSpace(string(data))
	}

	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	key, _, cerr := c.HCloud().SSHKey.Create(hetznerCtx(), hcloud.SSHKeyCreateOpts{Name: name, PublicKey: pub})
	if cerr != nil {
		return hzFail(out, "create ssh key "+name, cerr)
	}
	payload := map[string]any{"ok": true, "action": "create", "ssh_key": hzSSHKeyRow(key, true)}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("✓ created ssh key %s (id %d)", key.Name, key.ID)
	out.outf("  fingerprint: %s", key.Fingerprint)
	return exitOK
}

func runHetznerSSHKeyDelete(out *writer, g globals, args []string) int {
	target, yes, ok := hzOneTargetYes(out, args, "bp cloud hetzner ssh-key delete <id|name> [--yes]")
	if !ok {
		return exitUsage
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	keys, err := resolveHzSSHKeys(ctx, hc, []string{target})
	if err != nil {
		return hzFail(out, "delete ssh key", errOrNotFound(err))
	}
	key := keys[0]
	if cerr := hzConfirmDestroy(hzStdin, out, "ssh key", key.Name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if _, derr := hc.SSHKey.Delete(ctx, key); derr != nil {
		return hzFail(out, "delete ssh key "+key.Name, derr)
	}
	payload := map[string]any{"ok": true, "action": "delete", "ssh_key": map[string]any{"id": key.ID, "name": key.Name}}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("✓ deleted ssh key %s (id %d)", key.Name, key.ID)
	return exitOK
}

// ---------------------------------------------------------------------------
// discovery (read-only). Each accepts an optional bare `list`/`ls` verb so
// `bp cloud hetzner server-types list` and `… server-types` both work.
// ---------------------------------------------------------------------------

// hzDiscoveryArgs strips the optional list verb and parses the declared flags.
func hzDiscoveryArgs(args []string, valueFlags []string, usage string) (*hzArgs, error) {
	if len(args) > 0 && (args[0] == "list" || args[0] == "ls") {
		args = args[1:]
	}
	a, err := parseHzArgs(args, valueFlags, nil, usage)
	if err != nil {
		return nil, err
	}
	if len(a.pos) > 0 {
		return nil, fmt.Errorf("unexpected argument %q (usage: %s)", a.pos[0], usage)
	}
	return a, nil
}

func runHetznerServerTypes(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	if _, err := hzDiscoveryArgs(args, nil, "bp cloud hetzner server-types"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	types, err := c.HCloud().ServerType.All(hetznerCtx())
	if err != nil {
		return hzFail(out, "list server types", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(types))
		for _, t := range types {
			rows = append(rows, map[string]any{
				"id":           t.ID,
				"name":         t.Name,
				"description":  t.Description,
				"cores":        t.Cores,
				"memory_gb":    t.Memory,
				"disk_gb":      t.Disk,
				"storage_type": string(t.StorageType),
				"cpu_type":     string(t.CPUType),
				"architecture": string(t.Architecture),
			})
		}
		out.emitStructured(map[string]any{"server_types": rows})
		return exitOK
	}
	rows := make([][]string, 0, len(types))
	for _, t := range types {
		rows = append(rows, []string{
			strconv.FormatInt(t.ID, 10),
			hzCell(t.Name),
			strconv.Itoa(t.Cores),
			fmt.Sprintf("%g GB", t.Memory),
			fmt.Sprintf("%d GB", t.Disk),
			hzCell(string(t.CPUType)),
			hzCell(string(t.Architecture)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "CORES", "MEMORY", "DISK", "CPU", "ARCH"}, rows)
	return exitOK
}

func runHetznerLocations(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	if _, err := hzDiscoveryArgs(args, nil, "bp cloud hetzner locations"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	locs, err := c.HCloud().Location.All(hetznerCtx())
	if err != nil {
		return hzFail(out, "list locations", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(locs))
		for _, l := range locs {
			rows = append(rows, map[string]any{
				"id":           l.ID,
				"name":         l.Name,
				"description":  l.Description,
				"country":      l.Country,
				"city":         l.City,
				"network_zone": string(l.NetworkZone),
			})
		}
		out.emitStructured(map[string]any{"locations": rows})
		return exitOK
	}
	rows := make([][]string, 0, len(locs))
	for _, l := range locs {
		rows = append(rows, []string{
			strconv.FormatInt(l.ID, 10),
			hzCell(l.Name),
			hzCell(l.City),
			hzCell(l.Country),
			hzCell(string(l.NetworkZone)),
			hzCell(l.Description),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "CITY", "COUNTRY", "ZONE", "DESCRIPTION"}, rows)
	return exitOK
}

func runHetznerDatacenters(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	if _, err := hzDiscoveryArgs(args, nil, "bp cloud hetzner datacenters"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	dcs, err := c.HCloud().Datacenter.All(hetznerCtx())
	if err != nil {
		return hzFail(out, "list datacenters", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(dcs))
		for _, d := range dcs {
			row := map[string]any{
				"id":          d.ID,
				"name":        d.Name,
				"description": d.Description,
			}
			if d.Location != nil {
				row["location"] = d.Location.Name
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"datacenters": rows})
		return exitOK
	}
	rows := make([][]string, 0, len(dcs))
	for _, d := range dcs {
		loc := ""
		if d.Location != nil {
			loc = d.Location.Name
		}
		rows = append(rows, []string{
			strconv.FormatInt(d.ID, 10),
			hzCell(d.Name),
			hzCell(loc),
			hzCell(d.Description),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "LOCATION", "DESCRIPTION"}, rows)
	return exitOK
}

func runHetznerImages(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	const usage = "bp cloud hetzner images [--type snapshot|backup|system]"
	a, err := hzDiscoveryArgs(args, []string{"type"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	var opts hcloud.ImageListOpts
	switch a.val("type") {
	case "":
	case "snapshot":
		opts.Type = []hcloud.ImageType{hcloud.ImageTypeSnapshot}
	case "backup":
		opts.Type = []hcloud.ImageType{hcloud.ImageTypeBackup}
	case "system":
		opts.Type = []hcloud.ImageType{hcloud.ImageTypeSystem}
	default:
		return useError(out, "usage", fmt.Sprintf("invalid --type %q (want snapshot|backup|system)", a.val("type")), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	imgs, err := c.HCloud().Image.AllWithOpts(hetznerCtx(), opts)
	if err != nil {
		return hzFail(out, "list images", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(imgs))
		for _, im := range imgs {
			row := map[string]any{
				"id":           im.ID,
				"type":         string(im.Type),
				"status":       string(im.Status),
				"architecture": string(im.Architecture),
			}
			if im.Name != "" {
				row["name"] = im.Name
			}
			if im.Description != "" {
				row["description"] = im.Description
			}
			if im.OSFlavor != "" {
				row["os_flavor"] = im.OSFlavor
			}
			if im.OSVersion != "" {
				row["os_version"] = im.OSVersion
			}
			if !im.Created.IsZero() {
				row["created"] = im.Created.UTC().Format(time.RFC3339)
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"images": rows})
		return exitOK
	}
	rows := make([][]string, 0, len(imgs))
	for _, im := range imgs {
		created := ""
		if !im.Created.IsZero() {
			created = im.Created.UTC().Format("2006-01-02")
		}
		rows = append(rows, []string{
			strconv.FormatInt(im.ID, 10),
			hzCell(im.Name),
			hzCell(string(im.Type)),
			hzCell(string(im.Status)),
			hzCell(truncateCell(im.Description, 40)),
			hzCell(string(im.Architecture)),
			hzCell(created),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "STATUS", "DESCRIPTION", "ARCH", "CREATED"}, rows)
	return exitOK
}

func runHetznerISOs(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	if _, err := hzDiscoveryArgs(args, nil, "bp cloud hetzner isos"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	isos, err := c.HCloud().ISO.All(hetznerCtx())
	if err != nil {
		return hzFail(out, "list isos", err)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(isos))
		for _, iso := range isos {
			row := map[string]any{
				"id":   iso.ID,
				"name": iso.Name,
				"type": string(iso.Type),
			}
			if iso.Description != "" {
				row["description"] = iso.Description
			}
			if iso.Architecture != nil {
				row["architecture"] = string(*iso.Architecture)
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"isos": rows})
		return exitOK
	}
	rows := make([][]string, 0, len(isos))
	for _, iso := range isos {
		arch := ""
		if iso.Architecture != nil {
			arch = string(*iso.Architecture)
		}
		rows = append(rows, []string{
			strconv.FormatInt(iso.ID, 10),
			hzCell(iso.Name),
			hzCell(string(iso.Type)),
			hzCell(arch),
			hzCell(truncateCell(iso.Description, 50)),
		})
	}
	renderHzTable(out, []string{"ID", "NAME", "TYPE", "ARCH", "DESCRIPTION"}, rows)
	return exitOK
}

func runHetznerPricing(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerHelp(out)
		return exitOK
	}
	if _, err := hzDiscoveryArgs(args, nil, "bp cloud hetzner pricing"); err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	pricing, _, err := c.HCloud().Pricing.Get(hetznerCtx())
	if err != nil {
		return hzFail(out, "get pricing", err)
	}

	type priceRow struct {
		name, location, hourly, monthly string
	}
	var flat []priceRow
	for _, tp := range pricing.ServerTypes {
		name := ""
		if tp.ServerType != nil {
			name = tp.ServerType.Name
		}
		for _, p := range tp.Pricings {
			loc := ""
			if p.Location != nil {
				loc = p.Location.Name
			}
			flat = append(flat, priceRow{name: name, location: loc, hourly: p.Hourly.Gross, monthly: p.Monthly.Gross})
		}
	}

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(flat))
		for _, r := range flat {
			rows = append(rows, map[string]any{
				"name":          r.name,
				"location":      r.location,
				"hourly_gross":  r.hourly,
				"monthly_gross": r.monthly,
			})
		}
		out.emitStructured(map[string]any{
			"currency":     pricing.Currency,
			"vat_rate":     pricing.VATRate,
			"server_types": rows,
		})
		return exitOK
	}
	out.outf("currency: %s (VAT %s%%, gross prices)", pricing.Currency, pricing.VATRate)
	out.outf("")
	rows := make([][]string, 0, len(flat))
	for _, r := range flat {
		rows = append(rows, []string{hzCell(r.name), hzCell(r.location), hzCell(r.hourly), hzCell(r.monthly)})
	}
	renderHzTable(out, []string{"TYPE", "LOCATION", "HOURLY", "MONTHLY"}, rows)
	return exitOK
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

// printCloudHelp writes `bp cloud` usage.
func printCloudHelp(out *writer) {
	const help = `bp cloud — your fleet + a cloud provider's API, from bp.

USAGE
  bp cloud status                       triage your fleet (ranked, bucketed)
  bp cloud providers                    the capability matrix for every provider
  bp cloud instance <verb>              provider-neutral fleet control (any provider)
  bp cloud support add <name>           grow your Personal Dev Fleet: provision +
                                        bind + scrubbed pull + supervised listener
  bp cloud workspace <export|import>    per-workspace bundle over the content API
  bp cloud site <verb>                  spawn a website next to a Barkpark box
                                        (create · deploy · rollback · status)
  bp cloud open <target>                open a dashboard deep link
  bp cloud verify <instance>            re-run the golden-path probe suite
  bp cloud deploy <target>              push any git ref to an instance over SSH
  bp cloud <provider> <resource> <verb> drive a provider's API directly

FLEET (control plane — needs 'bp login')
  status    every Barkpark ranked most-urgent-first: attention · in-flight ·
            healthy, status cells colored by role      (bp cloud status -h)
  open      fleet | sites | activity | instance <id-or-name> | site <id-or-name>
            → a legacy-stable dashboard hash link       (bp cloud open -h)
  webhook   list · show · create · rm · toggle · rotate · deliveries · replay —
            control an instance's webhooks             (bp cloud webhook -h)
  verify    re-run the readiness probes (API · login · Studio) against a live
            box; exit 0 only when all pass             (bp cloud verify -h)
  deploy    push any git ref (branch/PR/main) to an instance over SSH — the
            same blue/green mechanics, pointed anywhere (bp cloud deploy -h)
  deployments
            the FLEET deploy rate over a pinned window, printed WITH its
            denominator — and a named refusal, never a fake zero, when it could
            not be read                            (bp cloud deployments -h)
  deliveries
            what actually happened to ONE merge: the PLATFORM delivery record for
            a sha — merged · waited · built · serving, and the run that delivered
            it — NOT the webhook log above    (bp cloud deliveries -h)
  domain    a domain's DNS/TLS checklist (found · points here · TLS · serving);
            exit 0 only when it's serving              (bp cloud domain -h)
  usage     an instance's usage meters — honest counts, "unmetered" where a
            source is quiet, never a fake zero          (bp cloud usage -h)
  members   your team's seats + pending invitations, the console's Members
            panel in the terminal                       (bp cloud members -h)
  autoupdate pin · unpin · pause · resume one instance's self-update policy
                                                    (bp cloud autoupdate -h)
  rollout   the fleet-wide autoupdate brake: status · halt · resume
                                                        (bp cloud rollout -h)
  rollback  roll ONE instance back to its previous blue/green code slot; pins it
            at that version, health-gated flip           (bp cloud rollback -h)
  update    trigger an in-place self-update run on ONE instance; --force
            overrides a pin for that one run               (bp cloud update -h)
  site      spawn a website that builds and serves next to a Barkpark box:
            create · deploy (--prebuilt ./dist ships a build made elsewhere) ·
            rollback · status · open · settings              (bp cloud site -h)

PROVIDERS (the provider's own API, YOUR credentials — no control plane)
  providers registered + planned providers and the capabilities each honours
            today — the honest matrix, no network call (bp cloud providers -h)
  instance  provider-neutral create · ip · delete · list · label through the
            seam: --provider hetzner|azure|fake     (bp cloud instance -h)
  hetzner   Hetzner Cloud (servers, ssh keys, images, …) — bp cloud hetzner -h
  azure     Azure ARM directly (service-principal creds) — bp cloud azure -h

Unlike 'bp launch' (which provisions THROUGH the Barkpark control plane), the
provider commands talk to the provider's own API directly.`
	out.outf("%s", help)
}

// printHetznerHelp writes the `bp cloud hetzner` namespace usage.
func printHetznerHelp(out *writer) {
	const help = `bp cloud hetzner — manage a Hetzner Cloud project (native API, no hcloud binary).

USAGE
  bp cloud hetzner <resource> <verb> [args] [flags]

RESOURCES
  overview      the whole estate on one page: per-kind counts + lean rows
                (read-only — bp cloud hetzner overview -h)
  server        list · get · create · delete · poweron · poweroff · reboot ·
                reset · shutdown · rebuild · resize · enable-rescue ·
                disable-rescue · create-image · enable-backup · disable-backup ·
                attach-iso · detach-iso · ip        (bp cloud hetzner server -h)
  ssh-key       list · get · create · delete       (bp cloud hetzner ssh-key -h)
  volume        block-storage volumes: create · attach · detach · resize · …
  network       private networks: subnets · routes · ip ranges
  firewall      firewalls: rules · apply/remove on servers
  load-balancer load balancers: services · targets · algorithm · type
  floating-ip   floating IPs: create · assign · unassign
  primary-ip    primary IPs: create · assign · unassign
  placement-group  spread placement groups
  certificate   TLS certificates: uploaded or managed (Let's Encrypt)
  dns           Cloud DNS: zones and records         (bp cloud hetzner dns -h)
  instance      fleet lifecycle: archive · archives · decommission · resurrect ·
                adopt · eject · audit           (bp cloud hetzner instance -h)
  storage       Object Storage (S3): buckets · objects · presign
                (S3 credentials, not the API token — bp cloud hetzner storage -h)
  backup        Postgres backups to Object Storage: create · list · restore ·
                prune                               (bp cloud hetzner backup -h)
  server-types  the offered server types            (read-only)
  lb-types      the offered load-balancer types     (read-only)
  locations     the available locations             (read-only)
  datacenters   the available datacenters           (read-only)
  images        system images / snapshots / backups [--type snapshot|backup|system]
  isos          the attachable ISOs                 (read-only)
  pricing       the project's gross prices per server type and location

AUTH (first match wins)
  --token <t>            explicit API token
  $HCLOUD_TOKEN          the standard Hetzner env var
  hcloud context         the active context of the official hcloud CLI

OUTPUT
  -o table   aligned columns (default on a tty)
  -o json    machine-readable JSON (default when piped)
  -o yaml    YAML

Every mutating verb waits for the Hetzner action to complete and reports the
outcome — nothing is fire-and-forget.

Destructive verbs (delete/rm · rebuild · decommission · prune) prompt on a
terminal: type the exact resource name to proceed. Pass --yes/-y to skip the
prompt; piped stdin (scripts, CI) never prompts.

EXAMPLES
  bp cloud hetzner server create --name web-1 --type cx22 --image ubuntu-24.04 \
      --location nbg1 --ssh-key deploy-key
  bp cloud hetzner server poweroff web-1
  bp cloud hetzner server ip web-1
  bp cloud hetzner images --type snapshot -o json`
	out.outf("%s", help)
}

// printHetznerServerHelp writes `bp cloud hetzner server` usage.
func printHetznerServerHelp(out *writer) {
	const help = `bp cloud hetzner server — manage the project's servers.

USAGE
  bp cloud hetzner server list
  bp cloud hetzner server get <id|name>
  bp cloud hetzner server create --name <n> --type <t> --image <img>
                                 [--location <loc>] [--ssh-key <k>[,<k>…]]
                                 [--label k=v]…
  bp cloud hetzner server delete <id|name> [--yes]
  bp cloud hetzner server poweron|poweroff|reboot|reset|shutdown <id|name>
  bp cloud hetzner server rebuild <id|name> --image <img> [--yes]
  bp cloud hetzner server resize <id|name> --type <t> [--upgrade-disk]
  bp cloud hetzner server enable-rescue <id|name> [--ssh-key <k>[,<k>…]]
  bp cloud hetzner server disable-rescue <id|name>
  bp cloud hetzner server create-image <id|name> --description <d> [--type snapshot|backup]
  bp cloud hetzner server enable-backup <id|name>
  bp cloud hetzner server disable-backup <id|name>
  bp cloud hetzner server attach-iso <id|name> <iso>
  bp cloud hetzner server detach-iso <id|name>
  bp cloud hetzner server ip <id|name>

NOTES
  <id|name>        every verb takes the numeric id or the server name
  create           waits until the server is RUNNING with a public IP; when no
                   --ssh-key is given the one-time root password is printed
  rebuild/resize   destructive/disruptive: rebuild wipes the disk, resize needs
                   a powered-off server (poweroff first)
  enable-rescue    prints the one-time rescue root password (unless --ssh-key);
                   takes effect on the next reboot
  ip               prints the bare IPv4 — ssh root@$(bp cloud hetzner server ip web-1)
  -o json|yaml     structured output for every verb`
	out.outf("%s", help)
}

// printHetznerSSHKeyHelp writes `bp cloud hetzner ssh-key` usage.
func printHetznerSSHKeyHelp(out *writer) {
	const help = `bp cloud hetzner ssh-key — manage the project's ssh keys.

USAGE
  bp cloud hetzner ssh-key list
  bp cloud hetzner ssh-key get <id|name>
  bp cloud hetzner ssh-key create --name <n> (--public-key <k> | --public-key-file <f>)
  bp cloud hetzner ssh-key delete <id|name> [--yes]

FLAGS (create)
  --name <n>             the key's name in the project
  --public-key <k>       the public key material, inline
  --public-key-file <f>  read the public key from a file (e.g. ~/.ssh/id_ed25519.pub)

EXAMPLE
  bp cloud hetzner ssh-key create --name deploy-key --public-key-file ~/.ssh/id_ed25519.pub`
	out.outf("%s", help)
}
