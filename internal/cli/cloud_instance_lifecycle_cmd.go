package cli

// cloud_instance_lifecycle_cmd.go is the PROVIDER-NEUTRAL fleet-lifecycle surface
// (charter S9, Decisions 20+21):
//
//	bp cloud instance archive|resurrect|decommission|adopt|audit  --provider <kind>
//	bp cloud instance pause|resume                                --provider <kind>
//
// It is deliberately a SIBLING of cloud_instance_cmd.go so that file's churn stays
// minimal — runCloudInstance routes the lifecycle verbs here. Dispatch is a table
// keyed by (provider, verb):
//
//   - HETZNER routes to the EXISTING free functions in hetzner_instance_cmd.go
//     (runInstanceArchive/Resurrect/Decommission/Adopt/Audit) with the tail
//     forwarded verbatim after stripping --provider, so the neutral path is
//     BYTE-IDENTICAL to `bp cloud hetzner instance <verb>` and its guts are
//     untouched (a refute/golden test proves this). Every hetzner flag —
//     --dns-token/BARKPARK_DNS_HCLOUD_TOKEN, --worker-token, --control-url, --zone,
//     the typed-name confirm — threads through unchanged.
//   - AZURE routes to CLI-level implementations below (decommission + audit only —
//     no snapshot archive/resurrect, no clone-swap adopt). Azure decommission is
//     UNRECOVERABLE (no archive is taken) and says so at the confirm; DNS still
//     rides the hetzner-hosted zone (Decision 10: DNS is provider-orthogonal).
//   - Any unsupported (provider, verb) degrades via degradeUnsupported with a
//     reason — never a dead verb.
//
// The dispatch table is ALSO the second capability-detection source (Decision 21):
// init() registers each provider's verbs into the seam via RegisterLifecycleVerbs,
// derived from the table keys, so a fixture claim can only be satisfied by a real
// dispatch entry. eject/export/import stay hetzner-escape-hatch-only — they are
// not neutral facets.

import (
	"fmt"
	"sort"
	"strings"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// lifecycleHandler is one (provider, verb) executor. It has the SAME signature as
// the existing hetzner free functions, so the hetzner column of the dispatch
// table IS those functions with zero adaptation.
type lifecycleHandler func(out *writer, g globals, args []string) int

// lifecycleDispatch is the neutral-lifecycle router AND the source the seam's
// per-provider verb registration derives from (init below). A verb a provider
// can't dispatch here cannot be registered, so the capability fixture cannot claim
// it — the "a claim needs a real dispatch entry" invariant (Decision 21).
var lifecycleDispatch = map[string]map[string]lifecycleHandler{
	cloud.ProviderHetzner: {
		cloud.VerbArchive: runInstanceArchive,
		// resurrect defaults to the PORTABLE bundle path (drop→restore→migrate onto a
		// fresh box, cross-provider). `--fast` selects the legacy snapshot restore
		// (runInstanceResurrect), byte-identical to `bp cloud hetzner instance resurrect`.
		cloud.VerbResurrect:    runHetznerResurrect,
		cloud.VerbDecommission: runInstanceDecommission,
		cloud.VerbAdopt:        runInstanceAdopt,
		cloud.VerbAudit:        runInstanceAudit,
	},
	cloud.ProviderAzure: {
		// archive is the PORTABLE bp-bundle-v1 (charter Decision 42): azure now
		// honours it through the neutral bundle writer, NOT a snapshot. The entry
		// exists so RegisterLifecycleVerbs advertises the capability (Decision 21);
		// the verb itself is intercepted in runCloudInstanceLifecycle and routed to
		// runNeutralArchive, so this handler is the fallback, not the hot path.
		cloud.VerbArchive:      runAzureArchive,
		cloud.VerbDecommission: runAzureInstanceDecommission,
		cloud.VerbAudit:        runAzureInstanceAudit,
		// Azure has no snapshot substrate, so its ONLY resurrect is the portable
		// bundle path (charter S14, Decision 12): a Hetzner-or-Azure archive bundle is
		// restored onto a fresh Azure box (never a warm-assign — D40). This dispatch
		// entry is what makes the azure fixture's resurrect:true a real capability
		// (Decision 21 — a claim needs a real dispatch entry).
		cloud.VerbResurrect: runAzureInstanceResurrect,
	},
}

// runAzureArchive is the azure column's VerbArchive dispatch fallback — it routes
// to the provider-neutral portable-bundle writer. Kept a real function (not the
// old degrade) so the dispatch table is an honest capability source.
func runAzureArchive(out *writer, g globals, args []string) int {
	return runNeutralArchive(out, g, cloud.ProviderAzure, args)
}

// init registers each provider's dispatched lifecycle verbs into the seam so
// DetectCapabilities reports them (Decision 21). Idempotent-by-union with the
// cloud package's own hetzner baseline; azure's decommission+audit reach the seam
// ONLY through this cli-package registration (the cloud test binary never links
// the azure package or this file).
func init() {
	for kind, verbs := range lifecycleDispatch {
		list := make([]string, 0, len(verbs))
		for v := range verbs {
			list = append(list, v)
		}
		cloud.RegisterLifecycleVerbs(kind, list...)
	}
}

// lifecycleWhat renders the human phrase degradeUnsupported prints for a missing
// lifecycle facet, so the reason reads naturally ("cannot archive an instance").
func lifecycleWhat(verb string) string {
	switch verb {
	case cloud.VerbArchive:
		return "archive an instance"
	case cloud.VerbResurrect:
		return "resurrect an instance from an archive"
	case cloud.VerbDecommission:
		return "decommission an instance"
	case cloud.VerbAdopt:
		return "adopt a standalone box as a tenant"
	case cloud.VerbAudit:
		return "audit the fleet"
	default:
		return verb + " an instance"
	}
}

// runCloudInstanceLifecycle dispatches a neutral lifecycle verb to its
// (provider, verb) handler, or degrades honestly when the combination is not
// supported.
func runCloudInstanceLifecycle(out *writer, g globals, verb string, args []string) int {
	kind, rest, err := splitProviderFlag(args)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	// archive is the PORTABLE-BUNDLE verb for EVERY provider (Decision 42): it no
	// longer routes to a per-kind snapshot handler — it collects the box into a
	// bp-bundle-v1 in object storage, resurrectable on the OTHER provider. hetzner
	// keeps `--fast` as the snapshot escape (handled inside runNeutralArchive). An
	// unknown provider is still a usage error naming the known slugs.
	if verb == cloud.VerbArchive {
		if !providerKnown(kind) {
			return useError(out, "usage", fmt.Sprintf("unknown provider %q (known: %s)", kind, strings.Join(cloud.RegisteredProviders(), ", ")), exitUsage)
		}
		return runNeutralArchive(out, g, kind, rest)
	}
	verbs, known := lifecycleDispatch[kind]
	if !known {
		// A registered provider with no per-kind CLI dispatch (the in-memory fake)
		// is executed GENERICALLY: resolve it through the seam and drive the verb's
		// optional facet interface (Archiver/Resurrector/Decommissioner/Adopter/
		// Auditor), degrading ONLY when the provider genuinely lacks the facet. This
		// makes the capability fixture's fake facet claims truthfully executable
		// instead of a parity-gate lie (Decision 29). A genuinely unknown slug is a
		// usage error naming the known providers.
		if providerKnown(kind) {
			return runNeutralFacet(out, kind, verb, rest)
		}
		return useError(out, "usage", fmt.Sprintf("unknown provider %q (known: %s)", kind, strings.Join(cloud.RegisteredProviders(), ", ")), exitUsage)
	}
	handler, ok := verbs[verb]
	if !ok {
		return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
	}
	return handler(out, g, rest)
}

// facetArgSpec returns how many positional arguments a neutral facet verb takes
// and a usage hint for them (audit takes none; adopt takes fqdn + team; the rest
// take a single fqdn|name). It mirrors the facet interface signatures at
// provider.go:274-297.
func facetArgSpec(verb string) (count int, hint string) {
	switch verb {
	case cloud.VerbAudit:
		return 0, ""
	case cloud.VerbAdopt:
		return 2, "<fqdn> <team>"
	default: // archive / resurrect / decommission
		return 1, "<fqdn|name>"
	}
}

// runNeutralFacet executes a lifecycle verb GENERICALLY through the seam's optional
// facet interfaces, for a registered provider that has no per-kind CLI dispatch
// entry (the in-memory fake today). It is modelled on runCloudInstancePause:
// resolveCloudProvider (env credentials) → type-assert the verb's facet interface →
// call it → emit a structured receipt, degrading honestly ONLY when the assert
// fails. Escape-hatch flag creds are not offered here — the fake needs none and
// hetzner/azure never route through this branch (they sit in lifecycleDispatch).
func runNeutralFacet(out *writer, kind, verb string, rest []string) int {
	count, hint := facetArgSpec(verb)
	usage := strings.TrimSpace("bp cloud instance "+verb+" "+hint) + " --provider " + kind
	a, err := parseHzArgs(rest, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != count {
		return useError(out, "usage", fmt.Sprintf("want exactly %d argument(s) (usage: %s)", count, usage), exitUsage)
	}
	p, code, ok := resolveCloudProvider(out, kind)
	if !ok {
		return code
	}
	ctx := cloudInstanceCtx()
	report := map[string]any{"ok": true, "provider": kind, "action": verb}
	var line string
	switch verb {
	case cloud.VerbArchive:
		impl, isImpl := p.(cloud.Archiver)
		if !isImpl {
			return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
		}
		arch, e := impl.Archive(ctx, a.pos[0])
		if e != nil {
			return facetFailed(out, kind, verb, e)
		}
		report["archive"] = map[string]any{"id": arch.ID, "fqdn": arch.FQDN, "provider": arch.Provider}
		line = fmt.Sprintf("✓ archived %s on %s → %s", a.pos[0], kind, arch.ID)
	case cloud.VerbResurrect:
		impl, isImpl := p.(cloud.Resurrector)
		if !isImpl {
			return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
		}
		s, e := impl.Resurrect(ctx, a.pos[0])
		if e != nil {
			return facetFailed(out, kind, verb, e)
		}
		report["instance"] = instanceRow(s)
		line = fmt.Sprintf("✓ resurrected %s on %s", s.Name, kind)
	case cloud.VerbDecommission:
		impl, isImpl := p.(cloud.Decommissioner)
		if !isImpl {
			return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
		}
		if e := impl.Decommission(ctx, a.pos[0]); e != nil {
			return facetFailed(out, kind, verb, e)
		}
		report["instance"] = map[string]any{"name": a.pos[0]}
		line = fmt.Sprintf("✓ decommissioned %s on %s", a.pos[0], kind)
	case cloud.VerbAdopt:
		impl, isImpl := p.(cloud.Adopter)
		if !isImpl {
			return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
		}
		if e := impl.Adopt(ctx, a.pos[0], a.pos[1]); e != nil {
			return facetFailed(out, kind, verb, e)
		}
		report["instance"] = map[string]any{"name": a.pos[0], "team": a.pos[1]}
		line = fmt.Sprintf("✓ adopted %s into %s on %s", a.pos[0], a.pos[1], kind)
	case cloud.VerbAudit:
		impl, isImpl := p.(cloud.Auditor)
		if !isImpl {
			return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
		}
		rep, e := impl.Audit(ctx)
		if e != nil {
			return facetFailed(out, kind, verb, e)
		}
		report["checked"] = rep.Checked
		report["issues"] = rep.Issues
		report["ok"] = len(rep.Issues) == 0
		if len(rep.Issues) > 0 {
			line = fmt.Sprintf("✗ audit found %d issue(s) on %s", len(rep.Issues), kind)
		} else {
			line = fmt.Sprintf("✓ audit clean — %d instance(s) checked on %s", rep.Checked, kind)
		}
	default:
		return degradeUnsupported(out, kind, verb, lifecycleWhat(verb))
	}
	clean, _ := report["ok"].(bool)
	if out.emitStructured(report) {
		if !clean {
			return exitGeneric
		}
		return exitOK
	}
	out.outf("%s", line)
	if !clean {
		return exitGeneric
	}
	return exitOK
}

// facetFailed renders a neutral-facet call failure through the shared envelope.
func facetFailed(out *writer, kind, verb string, err error) int {
	return useError(out, "failed", fmt.Sprintf("%s: %s: %s", kind, verb, err.Error()), exitGeneric)
}

// splitProviderFlag pulls --provider (or --provider=<kind>) out of a tail and
// returns the resolved kind (default hetzner) plus the REMAINING args verbatim —
// so a hetzner tail can be forwarded to the existing free functions unchanged (they
// do not declare --provider and would reject it) and an azure tail keeps its creds
// and lifecycle flags.
func splitProviderFlag(args []string) (kind string, rest []string, err error) {
	kind = cloud.ProviderHetzner
	rest = make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--provider":
			if i+1 >= len(args) {
				return "", nil, fmt.Errorf("--provider needs a value")
			}
			kind = args[i+1]
			i++
		case strings.HasPrefix(a, "--provider="):
			kind = a[len("--provider="):]
		default:
			rest = append(rest, a)
		}
	}
	if kind = strings.TrimSpace(kind); kind == "" {
		kind = cloud.ProviderHetzner
	}
	return kind, rest, nil
}

// ── pause / resume (cloud.Pauser) ────────────────────────────────────────────

// runCloudInstancePause routes pause/resume through the optional cloud.Pauser
// capability: azure honours it (deallocate/start), hetzner does not and degrades
// with a reason. It resolves the provider from the seam (env credentials — the
// same path `bp cloud instance create --provider azure` takes); the flag-creds
// escape hatch is `bp cloud azure`.
func runCloudInstancePause(out *writer, verb string, args []string) int {
	usage := "bp cloud instance " + verb + " <name> [--provider hetzner|azure|fake]"
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
	pauser, ok := p.(cloud.Pauser)
	if !ok {
		return degradeUnsupported(out, kind, "pause", verb+" a box without deleting it")
	}
	name := a.pos[0]
	ctx := cloudInstanceCtx()
	var perr error
	if verb == "resume" {
		perr = pauser.Resume(ctx, name)
	} else {
		perr = pauser.Pause(ctx, name)
	}
	if perr != nil {
		return useError(out, "failed", fmt.Sprintf("%s: %s instance %q: %s", kind, verb, name, perr.Error()), exitGeneric)
	}
	if out.emitStructured(map[string]any{
		"ok": true, "provider": kind, "action": verb,
		"instance": map[string]any{"name": name},
	}) {
		return exitOK
	}
	if verb == "resume" {
		out.outf("✓ resumed %s on %s", name, kind)
	} else {
		out.outf("✓ paused %s on %s (compute billing released; disk preserved)", name, kind)
	}
	return exitOK
}

// azureUnrecoverableWarning is the danger banner azure decommission always shows:
// Azure has no snapshot-based archive, so the teardown cannot be undone.
const azureUnrecoverableWarning = "WARNING: azure decommission is UNRECOVERABLE — no archive is taken; the VM, its disk and all data are permanently deleted."

// ── azure decommission (CLI-level, no archive) ───────────────────────────────

// runAzureInstanceDecommission tears an Azure instance down as ONE unit — VM +
// NIC + PublicIP (via AzureProvider.Delete), its A-record in the hetzner-hosted
// zone, and its control-plane registry row — then VERIFIES no residue survives.
// Unlike the hetzner path there is NO archive: Azure has no snapshot-based
// resurrection, so the typed-name confirm carries an explicit unrecoverable
// warning. Zero live calls in tests: the azure provider is built through the
// swappable azureProviderBuilder, DNS through the instDNSClient hcloud seam, and
// the registry through cpFleet — every one already fixture-driven.
func runAzureInstanceDecommission(out *writer, g globals, args []string) int {
	const usage = "bp cloud instance decommission <fqdn|vm> --provider azure [--name <vm>] [--zone <z>] [--fqdn <f>] [--direct] [--yes] [--dns-token <t>] [--control-url <u>] [--worker-token <t>] [azure creds]"
	valueFlags := append([]string{"name", "zone", "fqdn", "dns-token", "control-url", "worker-token"}, azureCredFlags...)
	a, err := parseHzArgs(args, valueFlags, []string{"direct", "yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|vm> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	// Resolve the fqdn (its DNS label + zone) and the VM name. The positional may
	// be either the fqdn or the box name; --name overrides the VM name when it
	// differs from the DNS label.
	fqdn := strings.Trim(strings.TrimSpace(a.pos[0]), ".")
	if a.val("fqdn") != "" {
		fqdn = strings.Trim(strings.TrimSpace(a.val("fqdn")), ".")
	}
	if !strings.Contains(fqdn, ".") {
		fqdn = fqdn + "." + zone
	}
	label, fzone := instLabelOf(fqdn)
	if fzone == "" {
		fzone = zone
	}
	vmName := strings.TrimSpace(a.val("name"))
	if vmName == "" {
		vmName = label
	}

	// The confirm gate covers the whole teardown and, crucially, warns that this
	// is unrecoverable (Azure keeps no archive) BEFORE anything is destroyed. The
	// banner rides errf (always visible, TTY or not) AND the confirm-prompt kind,
	// and is echoed into the structured report so a scripted caller sees it too.
	out.errf("%s", azureUnrecoverableWarning)
	if cerr := hzConfirmDestroy(hzStdin, out, "instance (no archive — unrecoverable)", fqdn, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}

	p, code, ok := azureEscapeProviderFromFlags(out, a)
	if !ok {
		return code
	}
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := cloudInstanceCtx()
	report := map[string]any{"provider": cloud.ProviderAzure, "fqdn": fqdn, "vm": vmName, "warning": azureUnrecoverableWarning}

	// The box address, read from the platform A record BEFORE anything is torn
	// down — the only handle the by-value DNS sweep below has, and the VM's
	// public IP is gone the moment step 1 runs (task-688ebffc4b0aa50a).
	boxIP := ""
	if pre, perr := instLookupA(ctx, dns, fzone, label); perr == nil && len(pre) > 0 {
		boxIP = strings.TrimSpace(pre[0])
	}

	// 1. Compute: delete the VM + NIC + PublicIP (idempotent; 404-tolerant).
	if derr := p.Delete(ctx, vmName); derr != nil {
		return useError(out, "failed", "azure decommission "+fqdn+": delete compute: "+derr.Error(), exitGeneric)
	}
	report["compute_deleted"] = vmName

	// 2. Registry row: the worker's deprovision queue tears down HETZNER boxes, so
	//    for azure we delete compute ourselves (above) and DETACH the row
	//    (registry-only). --direct skips the registry entirely.
	cp := instCP(a)
	if cp != nil && !a.bools["direct"] {
		rows, lerr := cp.List()
		if lerr != nil {
			return useError(out, "failed", "azure decommission "+fqdn+": "+lerr.Error(), exitGeneric)
		}
		if row := cpFindRow(rows, label, fzone, ""); row != nil {
			if _, derr := cp.Deprovision(row.ID, true); derr != nil {
				return useError(out, "failed", "azure decommission "+fqdn+": registry detach: "+derr.Error(), exitGeneric)
			}
			report["registry"] = "detached"
		} else {
			out.info("no registry row for %s — infra-only teardown", fqdn)
		}
	} else if cp == nil {
		out.info("no WORKER_TOKEN — registry row (if any) is NOT touched; infra teardown only")
	}

	// 3. DNS: sweep the hetzner-hosted zone BY VALUE, not by name (PDF-D101,
	//    task-688ebffc4b0aa50a). Deleting the fqdn's first label alone leaves the
	//    go-live `<label>-<teamid>` sibling and any attached custom host pointing
	//    at an address Azure is about to hand to somebody else — and the by-name
	//    verify below then reads clean. Azure boxes have no managed co-tenant on
	//    a hetzner-zone address, so the sweep is unconditionally exclusive here;
	//    an unknown IP degrades to the historical by-name delete.
	swept, derr := instTeardownDNS(ctx, dns, fzone, label, boxIP, true)
	if derr != nil {
		return useError(out, "failed", "azure decommission "+fqdn+": dns delete: "+derr.Error(), exitGeneric)
	}
	report["dns_deleted"] = swept

	// 4. VERIFY no residue across compute + DNS + registry.
	residue := azureVerifyGone(out, p, dns, cp, fqdn, vmName, label, fzone, boxIP)
	report["residue"] = residue
	report["ok"] = len(residue) == 0
	if out.emitStructured(report) {
		if len(residue) > 0 {
			return exitGeneric
		}
		return exitOK
	}
	if len(residue) > 0 {
		out.outf("✗ azure decommission %s left residue:", fqdn)
		for _, r := range residue {
			out.outf("  - %s", r)
		}
		return exitGeneric
	}
	out.outf("✓ azure decommission %s — no residue (VM, DNS and registry all clean)", fqdn)
	return exitOK
}

// azureVerifyGone re-reads compute (the managed VM list), DNS, and the registry
// and lists every survivor of an azure decommission.
func azureVerifyGone(out *writer, p cloud.CloudProvider, dns *hcloud.Client, cp *cpFleet, fqdn, vmName, label, zone, ip string) []string {
	ctx := cloudInstanceCtx()
	var residue []string
	servers, err := p.List(ctx)
	if err != nil {
		residue = append(residue, "could not verify compute: "+err.Error())
	} else {
		for _, s := range servers {
			if s.Name == vmName || s.Labels[cloud.FQDNLabelKey] == fqdn {
				residue = append(residue, fmt.Sprintf("azure VM %s still exists", s.Name))
			}
		}
	}
	values, derr := instLookupA(ctx, dns, zone, label)
	if derr != nil {
		residue = append(residue, "could not verify DNS: "+derr.Error())
	} else if len(values) > 0 {
		residue = append(residue, fmt.Sprintf("DNS A %s.%s still resolves to %s", label, zone, strings.Join(values, ", ")))
	}
	// BY VALUE: a survivor at the released address under ANOTHER name is named
	// here rather than silently passing as delta zero (task-688ebffc4b0aa50a).
	if strings.TrimSpace(ip) != "" {
		names, verr := instARecordNamesByValue(ctx, dns, zone, ip)
		if verr != nil {
			residue = append(residue, "could not verify DNS by value: "+verr.Error())
		} else {
			for _, n := range names {
				if n == hzRRSetName(label) {
					continue // already reported by the by-name check above
				}
				residue = append(residue, fmt.Sprintf("DNS A %s still resolves to the released box IP %s", cloud.Fqdn(hzLabelOfRRSetName(n), zone), ip))
			}
		}
	}
	if cp != nil {
		rows, lerr := cp.List()
		if lerr != nil {
			residue = append(residue, "could not verify registry: "+lerr.Error())
		} else if row := cpFindRow(rows, label, zone, ""); row != nil {
			residue = append(residue, fmt.Sprintf("registry row %s (%s) still exists", row.ID, row.Slug))
		}
	}
	return residue
}

// ── azure audit (CLI-level, archives skipped) ────────────────────────────────

// runAzureInstanceAudit cross-checks the three surfaces Azure has — managed VMs
// (the RG-scoped List; the O(all-VMs) waiver stands), the hetzner-hosted DNS zone,
// and the control-plane registry — and reports every orphan/mismatch. The
// archive-residue check the hetzner audit runs is SKIPPED with an honest printed
// note (Azure keeps no archives). Non-zero exit when findings exist (a residue
// gate for CI), mirroring the hetzner audit's contract.
func runAzureInstanceAudit(out *writer, g globals, args []string) int {
	const usage = "bp cloud instance audit --provider azure [--zone <z>] [--external <label,…>] [--dns-token <t>] [--control-url <u>] [--worker-token <t>] [azure creds]"
	valueFlags := append([]string{"zone", "external", "dns-token", "control-url", "worker-token"}, azureCredFlags...)
	a, err := parseHzArgs(args, valueFlags, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	external := map[string]bool{}
	for _, l := range a.list("external") {
		external[hzRRSetName(l)] = true
	}

	p, code, ok := azureEscapeProviderFromFlags(out, a)
	if !ok {
		return code
	}
	dnsUsesComputeToken := instDNSUsesComputeToken(a)
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := cloudInstanceCtx()

	servers, serr := p.List(ctx)
	if serr != nil {
		return useError(out, "failed", "azure audit: list VMs: "+serr.Error(), exitGeneric)
	}
	rrsets, derr := dns.Zone.AllRRSets(ctx, hzZoneRef(zone))
	if derr != nil {
		return hzDNSFail(out, "azure audit: list dns records", derr, dnsUsesComputeToken)
	}
	var rows []cpBarkpark
	cp := instCP(a)
	if cp != nil {
		rows, err = cp.List()
		if err != nil {
			return useError(out, "failed", "azure audit: "+err.Error(), exitGeneric)
		}
	}

	type finding struct {
		Kind   string `json:"kind"`
		Who    string `json:"who"`
		Detail string `json:"detail"`
	}
	var findings []finding

	// Managed VMs: each should carry a barkpark-fqdn tag, have its A record, and a
	// registry row when the control plane is reachable.
	managedByLabel := map[string]bool{}
	for _, s := range servers {
		fqdn := s.Labels[cloud.FQDNLabelKey]
		if fqdn == "" {
			// A pre-baked warm-pool box is LEGITIMATELY identity-less: its FQDN is
			// stamped only when it is assigned to a customer (cloud warmpool_assign
			// labelFQDN), so flagging it as unlabeled would be a false positive.
			// Skip it — it is not an orphan, it is inventory awaiting a claim.
			if _, warm := s.Labels[cloud.WarmLabelKey]; warm {
				continue
			}
			findings = append(findings, finding{"unlabeled-vm", s.Name, "managed VM with no " + cloud.FQDNLabelKey + " tag"})
			continue
		}
		label, fzone := instLabelOf(fqdn)
		managedByLabel[label] = true
		if fzone == zone {
			values, verr := instLookupA(ctx, dns, zone, label)
			if verr == nil && len(values) == 0 {
				findings = append(findings, finding{"no-dns", s.Name, fqdn + " runs but has no A record in the zone"})
			}
		}
		if cp != nil && cpFindRow(rows, label, fzone, "") == nil {
			findings = append(findings, finding{"no-registry-row", s.Name, fqdn + " runs but the control plane has no row (standalone or drift?)"})
		}
	}

	// DNS: every A record should point at a managed VM (or a known-external label).
	externalSeen := 0
	for _, rr := range rrsets {
		if rr.Type != hcloud.ZoneRRSetTypeA {
			continue
		}
		if external[rr.Name] {
			externalSeen++
			continue
		}
		if managedByLabel[rr.Name] {
			continue
		}
		who := rr.Name + "." + zone
		if cp != nil && cpFindRow(rows, rr.Name, zone, "") != nil {
			findings = append(findings, finding{"dns-row-no-vm", who, "A record matches a registry row but no managed VM"})
			continue
		}
		findings = append(findings, finding{"dns-unmatched", who, "A record matches no managed VM (external service, or an orphan)"})
	}

	// Registry rows: each row's dns_label should be a managed VM.
	for i := range rows {
		row := &rows[i]
		if row.DNSLabel != "" && !managedByLabel[row.DNSLabel] {
			findings = append(findings, finding{"row-no-vm", row.Slug, "registry row's dns_label has no managed VM (dead box or drift)"})
		}
		if row.DeprovisionStatus == "failed" {
			findings = append(findings, finding{"failed-deprovision", row.Slug, "the last deprovision job failed — see the control plane console"})
		}
	}

	sort.SliceStable(findings, func(i, j int) bool { return findings[i].Kind < findings[j].Kind })

	const archiveNote = "azure has no archives — archive residue not checked"
	summary := map[string]any{
		"provider":         cloud.ProviderAzure,
		"servers":          len(servers),
		"findings":         findings,
		"ok":               len(findings) == 0,
		"archives_checked": false,
		"note":             archiveNote,
	}
	if externalSeen > 0 {
		summary["external_dns"] = externalSeen
	}
	if cp != nil {
		summary["registry_rows"] = len(rows)
	}
	if out.emitStructured(summary) {
		if len(findings) > 0 {
			return exitGeneric
		}
		return exitOK
	}
	out.outf("azure fleet: %d managed VM(s)%s", len(servers), func() string {
		if cp != nil {
			return fmt.Sprintf(", %d registry row(s)", len(rows))
		}
		return " (registry not checked — no WORKER_TOKEN)"
	}())
	out.outf("note: %s", archiveNote)
	if len(findings) == 0 {
		out.outf("✓ audit clean — VMs, DNS and registry are coherent")
		return exitOK
	}
	tbl := make([][]string, 0, len(findings))
	for _, f := range findings {
		tbl = append(tbl, []string{hzCell(f.Kind), hzCell(f.Who), hzCell(f.Detail)})
	}
	renderHzTable(out, []string{"FINDING", "WHO", "DETAIL"}, tbl)
	return exitGeneric
}

// azureEscapeProviderFromFlags builds the azure provider for the neutral lifecycle
// verbs from an invocation's cred flags (flag > env), reusing the escape hatch's
// swappable azureProviderBuilder so tests inject a fake with zero live calls.
func azureEscapeProviderFromFlags(out *writer, a *hzArgs) (cloud.CloudProvider, int, bool) {
	p, err := azureProviderBuilder(azureFlagCreds(a))
	if err != nil {
		if strings.Contains(err.Error(), "incomplete") {
			return nil, useError(out, "auth", err.Error(), exitAuth), false
		}
		return nil, useError(out, "failed", err.Error(), exitGeneric), false
	}
	return p, exitOK, true
}
