package cli

// cloud_instance_cmd.go is the PROVIDER-NEUTRAL fleet surface:
//
//	bp cloud instance list|create|delete|ip|label  --provider hetzner|azure|fake
//	bp cloud azure    list|create|delete|ip         (raw escape hatch, its own creds)
//
// Both route through the cloud provider seam (internal/cli/cloud): `instance`
// resolves a provider by --provider through cloud.ProviderFor and calls the core
// CloudProvider methods (create/ip/delete/list) plus the OPTIONAL label
// capability when the provider advertises it — a provider that lacks a capability
// degrades with an honest printed reason, never a dead verb. `azure` is the
// escape hatch that talks straight to ARM with credentials resolved flag > env,
// bypassing the control plane entirely (the terminal twin of `bp cloud hetzner`).
//
// The provider-neutral fleet-LIFECYCLE verbs (archive/resurrect/decommission/
// adopt/audit/pause/resume) live in the sibling cloud_instance_lifecycle_cmd.go
// (S9) to keep this file's churn minimal; runCloudInstance routes them there. The
// raw `bp cloud hetzner instance …` surface survives untouched as the escape
// hatch, and eject/export/import stay hetzner-only there (not neutral facets).
//
// The named azure import self-registers the azure provider into the seam (its
// init() calls cloud.Register) AND powers the escape hatch's flag>env credential
// resolution — one import wires both.

import (
	"context"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/cli/cloud/azure"
)

// cloudInstanceCtx is the context every neutral fleet call runs under. A package
// var (the cloudCtx idiom) so a later task can bound it without touching call
// sites, and so tests keep it fast.
var cloudInstanceCtx = context.Background

// azureProviderBuilder resolves the escape hatch's credentials (flag > env, no
// stored blob) and builds the ARM-backed provider. A package var so a test can
// swap in a fake provider and assert routing WITHOUT a live Azure call.
var azureProviderBuilder = func(flags map[string]string) (cloud.CloudProvider, error) {
	creds, err := azure.ResolveCredentials(flags, nil)
	if err != nil {
		return nil, err
	}
	return azure.New(creds)
}

// ── bp cloud instance ────────────────────────────────────────────────────────

// runCloudInstance dispatches the provider-neutral fleet verbs.
func runCloudInstance(out *writer, g globals, args []string) int {
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudInstanceHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing instance command (run `bp cloud instance -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runCloudInstanceList(out, rest)
	case "create":
		return runCloudInstanceCreate(out, rest)
	case "delete", "rm":
		return runCloudInstanceDelete(out, g, rest)
	case "ip":
		return runCloudInstanceIP(out, rest)
	case "label":
		return runCloudInstanceLabel(out, rest)
	case "archives":
		return runInstanceArchivesList(out, rest)
	case cloud.VerbArchive, cloud.VerbResurrect, cloud.VerbDecommission, cloud.VerbAdopt, cloud.VerbAudit:
		return runCloudInstanceLifecycle(out, g, verb, rest)
	case "pause", "resume":
		return runCloudInstancePause(out, verb, rest)
	case "top":
		return runCloudInstanceTop(out, g, rest)
	case "authority":
		return runCloudInstanceAuthority(out, g, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown instance command %q (run `bp cloud instance -h` for usage)", verb), exitUsage)
	}
}

// instanceProviderKind reads the --provider flag, defaulting to hetzner so a bare
// `bp cloud instance list` targets the common case.
func instanceProviderKind(a *hzArgs) string {
	if k := strings.TrimSpace(a.val("provider")); k != "" {
		return k
	}
	return cloud.ProviderHetzner
}

// resolveCloudProvider maps a --provider kind to a live CloudProvider through the
// seam registry. It fails loud two ways: an unregistered kind is a USAGE error
// naming the known slugs; a registered kind whose credentials don't resolve is an
// AUTH error. On failure it emits through the shared envelope and returns the
// exit code the caller should propagate.
func resolveCloudProvider(out *writer, kind string) (cloud.CloudProvider, int, bool) {
	if !providerKnown(kind) {
		return nil, useError(out, "usage", fmt.Sprintf("unknown provider %q (known: %s)", kind, strings.Join(cloud.RegisteredProviders(), ", ")), exitUsage), false
	}
	p, err := cloud.ProviderFor(kind, nil)
	if err != nil {
		return nil, useError(out, "auth", err.Error(), exitAuth), false
	}
	return p, exitOK, true
}

// providerKnown reports whether kind is a registered provider slug.
func providerKnown(kind string) bool {
	for _, s := range cloud.RegisteredProviders() {
		if s == kind {
			return true
		}
	}
	return false
}

func runCloudInstanceList(out *writer, args []string) int {
	a, err := parseHzArgs(args, []string{"provider"}, nil, "bp cloud instance list [--provider hetzner|azure|fake]")
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q", a.pos[0]), exitUsage)
	}
	kind := instanceProviderKind(a)
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	return doInstanceList(out, p, kind)
}

func runCloudInstanceCreate(out *writer, args []string) int {
	const usage = "bp cloud instance create --name <n> [--provider hetzner|azure|fake] [--type <t>] [--region <r>] [--image <img>]"
	a, err := parseHzArgs(args, []string{"provider", "name", "type", "region", "image"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage", fmt.Sprintf("unexpected argument %q (usage: %s)", a.pos[0], usage), exitUsage)
	}
	name := strings.TrimSpace(a.val("name"))
	if name == "" {
		return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
	}
	kind := instanceProviderKind(a)
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	return doInstanceCreate(out, p, kind, name, a.val("type"), a.val("region"), a.val("image"))
}

func runCloudInstanceDelete(out *writer, g globals, args []string) int {
	const usage = "bp cloud instance delete <name> [--provider hetzner|azure|fake] [--yes]"
	a, err := parseHzArgs(args, []string{"provider"}, []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
	}
	kind := instanceProviderKind(a)
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	// --yes is a GLOBAL bool (g.yes); -y / a literal --yes in the tail also count.
	return doInstanceDelete(out, p, kind, a.pos[0], g.yes || a.bools["yes"])
}

func runCloudInstanceIP(out *writer, args []string) int {
	const usage = "bp cloud instance ip <name> [--provider hetzner|azure|fake]"
	a, err := parseHzArgs(args, []string{"provider"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
	}
	kind := instanceProviderKind(a)
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	return doInstanceIP(out, p, kind, a.pos[0])
}

// runCloudInstanceLabel is the OPTIONAL-capability surface: it works only where
// the provider advertises the label interfaces, and degrades honestly otherwise.
func runCloudInstanceLabel(out *writer, args []string) int {
	if len(args) == 0 {
		return useError(out, "usage", "missing label command: set|rm (usage: bp cloud instance label set <name> <key> <value> | rm <name> <key> [--provider …])", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "set", "add":
		return runCloudInstanceLabelSet(out, rest)
	case "rm", "remove":
		return runCloudInstanceLabelRemove(out, rest)
	default:
		return useError(out, "usage", fmt.Sprintf("unknown label command %q (want set|rm)", verb), exitUsage)
	}
}

func runCloudInstanceLabelSet(out *writer, args []string) int {
	const usage = "bp cloud instance label set <name> <key> <value> [--provider hetzner|azure|fake]"
	a, err := parseHzArgs(args, []string{"provider"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 3 {
		return useError(out, "usage", "want <name> <key> <value> (usage: "+usage+")", exitUsage)
	}
	kind := instanceProviderKind(a)
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	labeler, ok := p.(cloud.ServerLabeler)
	if !ok {
		return degradeUnsupported(out, kind, "labels", "set a managed label")
	}
	if err := labeler.LabelServer(cloudInstanceCtx(), a.pos[0], a.pos[1], a.pos[2]); err != nil {
		return useError(out, "failed", fmt.Sprintf("%s: label instance %q: %s", kind, a.pos[0], err.Error()), exitGeneric)
	}
	if out.emitStructured(map[string]any{
		"ok": true, "provider": kind, "action": "label",
		"instance": map[string]any{"name": a.pos[0]},
		"label":    map[string]any{"key": a.pos[1], "value": a.pos[2]},
	}) {
		return exitOK
	}
	out.outf("✓ labeled %s on %s — %s=%s", a.pos[0], kind, a.pos[1], a.pos[2])
	return exitOK
}

func runCloudInstanceLabelRemove(out *writer, args []string) int {
	const usage = "bp cloud instance label rm <name> <key> [--provider hetzner|azure|fake]"
	a, err := parseHzArgs(args, []string{"provider"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 2 {
		return useError(out, "usage", "want <name> <key> (usage: "+usage+")", exitUsage)
	}
	kind := instanceProviderKind(a)
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	remover, ok := p.(cloud.ServerLabelRemover)
	if !ok {
		return degradeUnsupported(out, kind, "labels", "remove a managed label")
	}
	if err := remover.RemoveLabel(cloudInstanceCtx(), a.pos[0], a.pos[1]); err != nil {
		return useError(out, "failed", fmt.Sprintf("%s: remove label from instance %q: %s", kind, a.pos[0], err.Error()), exitGeneric)
	}
	if out.emitStructured(map[string]any{
		"ok": true, "provider": kind, "action": "unlabel",
		"instance": map[string]any{"name": a.pos[0]},
		"label":    map[string]any{"key": a.pos[1]},
	}) {
		return exitOK
	}
	out.outf("✓ removed label %s from %s on %s", a.pos[1], a.pos[0], kind)
	return exitOK
}

// degradeUnsupported prints an HONEST reason a capability is missing on a
// provider — the "never a dead verb" contract. The wording matches the seam
// vocabulary `bp cloud providers` renders, so the operator can cross-check.
func degradeUnsupported(out *writer, kind, capability, what string) int {
	return useError(out, "unsupported",
		fmt.Sprintf("provider %q does not support %s — cannot %s (see `bp cloud providers` for what each provider honours)", kind, capability, what),
		exitGeneric)
}

// ── shared executors (one impl for both `instance` and `azure`) ──────────────

// instanceRow is the structured (json/yaml) shape of one instance.
func instanceRow(s cloud.Server) map[string]any {
	row := map[string]any{"name": s.Name}
	if s.IP != "" {
		row["ipv4"] = s.IP
	}
	if s.ID != "" {
		row["id"] = s.ID
	}
	if len(s.Labels) > 0 {
		row["labels"] = s.Labels
	}
	return row
}

func doInstanceList(out *writer, p cloud.CloudProvider, kind string) int {
	servers, err := p.List(cloudInstanceCtx())
	if err != nil {
		return useError(out, "failed", fmt.Sprintf("%s: list instances: %s", kind, err.Error()), exitGeneric)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(servers))
		for _, s := range servers {
			rows = append(rows, instanceRow(s))
		}
		out.emitStructured(map[string]any{"provider": kind, "instances": rows})
		return exitOK
	}
	if len(servers) == 0 {
		out.outf("no instances on %s — create one with 'bp cloud instance create --provider %s --name <name>'", kind, kind)
		return exitOK
	}
	// PROVIDER is the kind this list was resolved for — free identity the command
	// already holds, painted through GenProviderMark (renderHzTable's header-driven
	// chrome). Every row on one `bp cloud instance list` shares the same provider,
	// so the column is a constant, but it makes a mixed-fleet operator's provider
	// unambiguous and matches the control-plane fleet table's vocabulary.
	table := make([][]string, 0, len(servers))
	for _, s := range servers {
		table = append(table, []string{hzCell(kind), hzCell(s.Name), hzCell(s.IP), hzCell(s.ID)})
	}
	renderHzTable(out, []string{"PROVIDER", "NAME", "IPV4", "ID"}, table)
	return exitOK
}

func doInstanceCreate(out *writer, p cloud.CloudProvider, kind, name, typ, region, image string) int {
	ctx := cloudInstanceCtx()
	// FreshSpec supplies the provider's defaults (and, for hetzner, resolves the
	// newest baked warm image); flags override any field. Providers with no
	// default in cloud.DefaultSpec (azure) fill their own inside Create.
	spec := cloud.FreshSpec(ctx, kind)
	spec.Name = name
	if s := strings.TrimSpace(typ); s != "" {
		spec.ServerType = s
	}
	if s := strings.TrimSpace(region); s != "" {
		spec.Region = s
	}
	if s := strings.TrimSpace(image); s != "" {
		spec.Image = s
	}
	out.info("creating instance %q on %s…", name, kind)
	srv, err := p.Create(ctx, spec)
	if err != nil {
		return useError(out, "failed", fmt.Sprintf("%s: create instance %q: %s", kind, name, err.Error()), exitGeneric)
	}

	// Stamp the box's public FQDN identity (barkpark-fqdn) exactly as the warm-pool
	// one-shot does (cloud.WarmPool.labelFQDN, warmpool.go) — the tag a name-safe
	// delete and the fleet audit both key on. The fqdn is derived HERE from the
	// operator's --name (never inside the provider's Create: a provider may mangle
	// the box name, and deriving there would stamp a lie). Mirror labelFQDN's
	// fail-closed intent, but on THIS operator escape path we do NOT auto-teardown a
	// created box — a silent success that leaves an unlabeled box is the failure we
	// refuse, so we error LOUD naming the box the operator now owns. A provider that
	// cannot label degrades with a printed reason (never a fatal for an unlabelable
	// provider — the box is still real and reported).
	fqdn := cloud.Fqdn(name, instDefaultZone)
	if labeler, ok := p.(cloud.ServerLabeler); ok {
		if lerr := labeler.LabelServer(ctx, srv.Name, cloud.FQDNLabelKey, fqdn); lerr != nil {
			return useError(out, "failed",
				fmt.Sprintf("%s: created instance %q but could NOT stamp its %s=%s identity: %s — the box EXISTS and is unlabeled (a fleet audit will flag it; a name-safe delete cannot confirm it). Fix it with `bp cloud instance label set %s %s %s --provider %s`, or delete the box.",
					kind, srv.Name, cloud.FQDNLabelKey, fqdn, lerr.Error(),
					srv.Name, cloud.FQDNLabelKey, fqdn, kind),
				exitGeneric)
		}
		if srv.Labels == nil {
			srv.Labels = map[string]string{}
		}
		srv.Labels[cloud.FQDNLabelKey] = fqdn
	} else {
		out.info("provider %q cannot label servers — %q was created WITHOUT its %s identity; a fleet audit will flag it and a name-safe delete cannot confirm the box",
			kind, srv.Name, cloud.FQDNLabelKey)
	}

	if out.emitStructured(map[string]any{
		"ok": true, "provider": kind, "action": "create", "instance": instanceRow(srv),
	}) {
		return exitOK
	}
	out.outf("✓ created %s on %s", srv.Name, kind)
	if srv.IP != "" {
		out.outf("  ipv4: %s", srv.IP)
	}
	if srv.ID != "" {
		out.outf("  id: %s", srv.ID)
	}
	return exitOK
}

func doInstanceDelete(out *writer, p cloud.CloudProvider, kind, name string, yes bool) int {
	if cerr := hzConfirmDestroy(hzStdin, out, "instance", name, yes); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}
	if err := p.Delete(cloudInstanceCtx(), name); err != nil {
		return useError(out, "failed", fmt.Sprintf("%s: delete instance %q: %s", kind, name, err.Error()), exitGeneric)
	}
	if out.emitStructured(map[string]any{
		"ok": true, "provider": kind, "action": "delete", "instance": map[string]any{"name": name},
	}) {
		return exitOK
	}
	out.outf("✓ deleted %s on %s", name, kind)
	return exitOK
}

func doInstanceIP(out *writer, p cloud.CloudProvider, kind, name string) int {
	ip, err := p.IP(cloudInstanceCtx(), name)
	if err != nil {
		return useError(out, "failed", fmt.Sprintf("%s: instance %q ip: %s", kind, name, err.Error()), exitGeneric)
	}
	// Only an EXPLICIT -o json/yaml gets the envelope; the piped default stays the
	// bare IP so `ssh root@$(bp cloud instance ip web-1)` keeps working.
	if out.outputExplicit && (out.output == "json" || out.output == "yaml") &&
		out.emitStructured(map[string]any{"ip": ip, "provider": kind, "instance": map[string]any{"name": name}}) {
		return exitOK
	}
	out.outf("%s", ip)
	return exitOK
}

// ── bp cloud azure (raw escape hatch) ────────────────────────────────────────

// azureCredFlags are the service-principal flags every azure verb accepts; they
// outrank the AZURE_* environment (flag > env), and env fills any gap.
var azureCredFlags = []string{"tenant-id", "client-id", "client-secret", "subscription-id"}

// azureFlagCreds collects the cred flags into the underscore-keyed map
// ResolveCredentials expects. Empty flags are omitted so env can fill them.
func azureFlagCreds(a *hzArgs) map[string]string {
	m := map[string]string{}
	for _, k := range azureCredFlags {
		if v := strings.TrimSpace(a.val(k)); v != "" {
			m[strings.ReplaceAll(k, "-", "_")] = v
		}
	}
	return m
}

// azureEscapeProvider builds the ARM provider from an escape-hatch invocation's
// cred flags (flag > env). A resolve failure is an AUTH error; a construction
// failure (malformed credential) is generic.
func azureEscapeProvider(out *writer, a *hzArgs) (cloud.CloudProvider, int, bool) {
	p, err := azureProviderBuilder(azureFlagCreds(a))
	if err != nil {
		// A completeness/validation failure is an auth problem; azidentity
		// rejecting a malformed tuple is a config error. Both are surfaced clearly.
		if strings.Contains(err.Error(), "incomplete") {
			return nil, useError(out, "auth", err.Error(), exitAuth), false
		}
		return nil, useError(out, "failed", err.Error(), exitGeneric), false
	}
	return p, exitOK, true
}

// runCloudAzure is the raw ARM escape hatch: same core verbs as `instance`, but
// hardwired to azure with its own flag>env credentials, no control plane.
func runCloudAzure(out *writer, g globals, args []string) int {
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudAzureHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing azure command (run `bp cloud azure -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		a, perr := parseHzArgs(rest, azureCredFlags, nil, "bp cloud azure list [creds]")
		if perr != nil {
			return useError(out, "usage", perr.Error(), exitUsage)
		}
		if len(a.pos) > 0 {
			return useError(out, "usage", fmt.Sprintf("unexpected argument %q", a.pos[0]), exitUsage)
		}
		p, code, ok := azureEscapeProvider(out, a)
		if !ok {
			return code
		}
		return doInstanceList(out, p, cloud.ProviderAzure)
	case "create":
		const usage = "bp cloud azure create --name <n> [--type <t>] [--region <r>] [--image <img>] [creds]"
		a, perr := parseHzArgs(rest, append([]string{"name", "type", "region", "image"}, azureCredFlags...), nil, usage)
		if perr != nil {
			return useError(out, "usage", perr.Error(), exitUsage)
		}
		name := strings.TrimSpace(a.val("name"))
		if name == "" {
			return useError(out, "usage", "--name is required (usage: "+usage+")", exitUsage)
		}
		p, code, ok := azureEscapeProvider(out, a)
		if !ok {
			return code
		}
		return doInstanceCreate(out, p, cloud.ProviderAzure, name, a.val("type"), a.val("region"), a.val("image"))
	case "delete", "rm":
		const usage = "bp cloud azure delete <name> [--yes] [creds]"
		a, perr := parseHzArgs(rest, azureCredFlags, []string{"yes"}, usage)
		if perr != nil {
			return useError(out, "usage", perr.Error(), exitUsage)
		}
		if len(a.pos) != 1 {
			return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
		}
		p, code, ok := azureEscapeProvider(out, a)
		if !ok {
			return code
		}
		return doInstanceDelete(out, p, cloud.ProviderAzure, a.pos[0], g.yes || a.bools["yes"])
	case "ip":
		const usage = "bp cloud azure ip <name> [creds]"
		a, perr := parseHzArgs(rest, azureCredFlags, nil, usage)
		if perr != nil {
			return useError(out, "usage", perr.Error(), exitUsage)
		}
		if len(a.pos) != 1 {
			return useError(out, "usage", "want exactly one <name> (usage: "+usage+")", exitUsage)
		}
		p, code, ok := azureEscapeProvider(out, a)
		if !ok {
			return code
		}
		return doInstanceIP(out, p, cloud.ProviderAzure, a.pos[0])
	default:
		return useError(out, "usage", fmt.Sprintf("unknown azure command %q (run `bp cloud azure -h` for usage)", verb), exitUsage)
	}
}

// ── help ─────────────────────────────────────────────────────────────────────

func printCloudInstanceHelp(out *writer) {
	const help = `bp cloud instance — provider-neutral fleet control through the cloud seam.

USAGE
  bp cloud instance list         [--provider hetzner|azure|fake]
  bp cloud instance create       --name <n> [--provider …] [--type <t>] [--region <r>] [--image <img>]
  bp cloud instance delete       <name> [--provider …] [--yes]
  bp cloud instance ip           <name> [--provider …]
  bp cloud instance label        set <name> <key> <value> | rm <name> <key> [--provider …]
  bp cloud instance archive      <fqdn|server> [--provider …]
  bp cloud instance resurrect    <fqdn> [--provider …]
  bp cloud instance decommission <fqdn|server> [--provider …] [--yes] [--direct]
  bp cloud instance adopt        <fqdn|server> --team <id> [--provider …]
  bp cloud instance audit        [--provider …]
  bp cloud instance pause        <name> [--provider …]
  bp cloud instance resume       <name> [--provider …]
  bp cloud instance top          <name> [--points <n>] [-o json|yaml]
  bp cloud instance authority    [--workspace <slug>] [--sql] [--skip-export-probe]

WHAT IT DOES
  Resolves --provider (default hetzner) through the provider seam and runs the
  core create/ip/delete/list verbs — the SAME code path for every provider.
  Label + lifecycle verbs need the provider's optional capability; a provider that
  lacks one prints an honest reason (never a dead verb) — 'bp cloud providers'
  shows what each honours. Credentials come from each provider's own environment
  (HCLOUD_TOKEN for hetzner, AZURE_* for azure); use 'bp cloud azure' to pass
  Azure creds as flags.

  LIFECYCLE (archive/resurrect/decommission/adopt/audit) treats a whole instance —
  server + DNS record + control-plane row — as one unit. Hetzner honours all five;
  Azure honours decommission + audit only (no snapshot archive/resurrect, no
  clone-swap adopt) and its decommission is UNRECOVERABLE (no archive is taken).
  The hetzner path is identical to 'bp cloud hetzner instance <verb>', which also
  keeps the hetzner-only eject/export/import escape hatches.

  PAUSE/RESUME stop/start a box without deleting it (azure deallocate/start);
  hetzner does not honour pause and degrades with a reason.

  TOP is a one-shot vitals snapshot (CPU/memory/disk/load + service health) read
  from the on-box agent's beat window through the control plane — the same truth
  on every provider and on adopted/self-hosted boxes. Needs 'bp login'; -o json
  emits the control plane's envelope verbatim.

  AUTHORITY answers, for ONE box, whether the operator token you present covers
  its target workspace — the membership set from GET /api/workspaces plus a real
  probe of GET /api/workspaces/<target>/export. It reads the INSTANCE with a
  content-API token (not 'bp login'), and there is deliberately no --all: a pass
  on one box says nothing about another. '--sql' prints the DB-only zero-admin
  sweep the HTTP surface cannot answer.`
	out.outf("%s", help)
}

func printCloudAzureHelp(out *writer) {
	const help = `bp cloud azure — drive Azure ARM directly (the raw escape hatch).

USAGE
  bp cloud azure list
  bp cloud azure create --name <n> [--type <t>] [--region <r>] [--image <img>]
  bp cloud azure delete <name> [--yes]
  bp cloud azure ip     <name>

AUTH (first match wins, per field)
  --tenant-id / --client-id / --client-secret / --subscription-id   explicit
  $AZURE_TENANT_ID / $AZURE_CLIENT_ID / $AZURE_CLIENT_SECRET / $AZURE_SUBSCRIPTION_ID

Talks straight to the Azure Resource Manager with YOUR service-principal
credentials — no Barkpark control plane. The provider-neutral 'bp cloud instance
--provider azure' is the everyday path; this escape hatch exists for scripts that
carry Azure creds as flags.`
	out.outf("%s", help)
}
