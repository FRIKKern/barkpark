package cli

// cloud_providers_cmd.go is the `bp cloud providers` surface: the honest
// capability matrix for every cloud provider the seam knows. It reads the
// committed cross-surface fixture (internal/cli/cloud/providers_capabilities.json
// — charter Decision 8), marks each provider registered (wired to a real
// implementation) or planned (declared but not yet built), and shows a
// best-effort auth state for the registered ones. It makes NO network call: the
// matrix is a local fixture read and auth is the provider's own cheap
// credential check (Authenticator).
//
// This is the terminal twin of the Console's Providers page — the same
// vocabulary, because both read the same fixture.

import (
	"context"
	"sort"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// runCloudProviders renders the provider capability matrix. By default it hides
// dev-tier providers (the in-memory fake) — a real operator never picks them;
// `--all` reveals them.
func runCloudProviders(out *writer, g globals, args []string) int {
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudProvidersHelp(out)
		return exitOK
	}
	// --all is a GLOBAL bool flag, so parseGlobals consumes it into g.all before
	// the tail reaches here; the loop additionally accepts a literal --all / -a in
	// args (the path unit tests drive) so both forms enable the dev-tier reveal.
	all := g.all
	for _, a := range args {
		switch a {
		case "--all", "-a":
			all = true
		default:
			return useError(out, "usage", "bp cloud providers accepts only --all (run `bp cloud providers -h` for usage)", exitUsage)
		}
	}

	fixture, err := cloud.LoadCapabilities()
	if err != nil {
		return useError(out, "failed", "read provider capabilities: "+err.Error(), exitGeneric)
	}

	registered := map[string]bool{}
	for _, slug := range cloud.RegisteredProviders() {
		registered[slug] = true
	}

	// The provider universe is every DECLARED slug in the fixture, sorted for a
	// stable render — registered providers plus any planned placeholders.
	slugs := make([]string, 0, len(fixture))
	for slug := range fixture {
		slugs = append(slugs, slug)
	}
	sort.Strings(slugs)

	rows := make([]providerView, 0, len(slugs))
	anyPlanned := false
	hiddenDev := 0
	for _, slug := range slugs {
		row := fixture[slug]
		if row.Tier == "dev" && !all {
			hiddenDev++
			continue
		}
		v := providerView{slug: slug, registered: registered[slug], tier: row.Tier, caps: row.Capabilities}
		if v.registered {
			v.auth = providerAuthState(slug)
		}
		if !v.registered {
			anyPlanned = true
		}
		rows = append(rows, v)
	}

	if out.output == "json" || out.output == "yaml" {
		payload := make([]map[string]any, 0, len(rows))
		for _, v := range rows {
			payload = append(payload, v.structured())
		}
		out.emitStructured(map[string]any{"providers": payload})
		return exitOK
	}

	headers := []string{"PROVIDER", "STATE", "AUTH", "CORE", "CATALOG", "ARCHIVE", "RESURRECT", "DECOMMISSION", "ADOPT", "AUDIT", "PAUSE", "LABELS"}
	table := make([][]string, 0, len(rows))
	for _, v := range rows {
		table = append(table, []string{
			v.slug,
			v.stateLabel(),
			v.authLabel(),
			capMark(v.caps.Core),
			capMark(v.caps.Catalog),
			capMark(v.caps.Archive),
			capMark(v.caps.Resurrect),
			capMark(v.caps.Decommission),
			capMark(v.caps.Adopt),
			capMark(v.caps.Audit),
			capMark(v.caps.Pause),
			capMark(v.caps.Labels),
		})
	}
	renderHzTable(out, headers, table)
	if anyPlanned {
		out.outf("")
		out.outf("planned providers are declared in the capability fixture but not yet wired — they light up as later slices ship.")
	}
	if hiddenDev > 0 {
		out.outf("")
		out.outf("%d dev-tier provider(s) hidden — pass --all to include them.", hiddenDev)
	}
	return exitOK
}

// providerView is one row of the matrix.
type providerView struct {
	slug       string
	registered bool
	tier       string
	auth       *bool // nil = unknown / not applicable (planned, or no auth check)
	caps       cloud.Capabilities
}

func (v providerView) stateLabel() string {
	if v.registered {
		return "registered"
	}
	return "planned"
}

func (v providerView) authLabel() string {
	if v.auth == nil {
		return "—"
	}
	if *v.auth {
		return "yes"
	}
	return "no"
}

func (v providerView) structured() map[string]any {
	m := map[string]any{
		"slug":       v.slug,
		"registered": v.registered,
		"tier":       v.tier,
		"capabilities": map[string]any{
			"core":         v.caps.Core,
			"catalog":      v.caps.Catalog,
			"archive":      v.caps.Archive,
			"resurrect":    v.caps.Resurrect,
			"decommission": v.caps.Decommission,
			"adopt":        v.caps.Adopt,
			"audit":        v.caps.Audit,
			"pause":        v.caps.Pause,
			"labels":       v.caps.Labels,
		},
	}
	if v.auth == nil {
		m["authenticated"] = nil
	} else {
		m["authenticated"] = *v.auth
	}
	return m
}

// providerAuthState is the best-effort credential check for a registered
// provider: instantiate it through the registry and, when it advertises the
// Authenticator capability, ask it. Returns nil (unknown) when the provider
// cannot be built or does not report auth — never a fabricated state.
func providerAuthState(slug string) *bool {
	p, err := cloud.ProviderFor(slug, nil)
	if err != nil {
		return nil
	}
	a, ok := p.(cloud.Authenticator)
	if !ok {
		return nil
	}
	ok = a.HasAuth(context.Background())
	return &ok
}

// capMark renders a capability cell: ✓ when honoured, · when not.
func capMark(on bool) string {
	if on {
		return "✓"
	}
	return "·"
}

func printCloudProvidersHelp(out *writer) {
	const help = `bp cloud providers — the honest capability matrix for every cloud provider.

USAGE
  bp cloud providers [--all] [-o json|yaml]

Reads the committed cross-surface capability fixture and shows, per provider,
whether it is registered (wired to a real implementation) or planned (declared
but not yet built), a best-effort auth state, and which seam capabilities it
honours today. Dev-tier providers (the in-memory fake) are hidden by default;
--all reveals them.

  CORE          create / ip / delete / list a host
  CATALOG       a normalized, priced region + server-type menu
  ARCHIVE       snapshot an instance into a resurrection bundle
  RESURRECT     rebuild an instance from its newest archive
  DECOMMISSION  tear an instance down and verify no residue
  ADOPT         convert a standalone box into a SaaS tenant
  AUDIT         cross-check servers ↔ DNS ↔ registry
  PAUSE         stop / start a box without deleting it
  LABELS        add / list-by / remove managed labels (orphan-sweep fence)

The five lifecycle facets (archive/resurrect/decommission/adopt/audit) are
independent (charter Decision 20): a provider advertises exactly the ones it
honours, so honest degradation is per-verb, never all-or-nothing.

A capability is shown ONLY when the provider actually implements it — a Go
parity test fails the build if the fixture and the implementation disagree, so
the matrix never lies. Makes no network call.`
	out.outf("%s", help)
}
