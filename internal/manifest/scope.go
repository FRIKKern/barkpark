package manifest

import "sort"

// ── Scope honesty ────────────────────────────────────────────────────────────
//
// THE BUG THIS FILE CLOSES. `bp -w gyldendal dataset stats` returned the
// DEFAULT workspace's numbers, byte-identically, with exit 0. The -w value was
// parsed into ctx.Workspace and then never reached the URL, the query string or
// a header, because the command's flat path_template has nowhere to put it and
// the scoped_prefix prepend was gated behind ctx.ScopedMirror — a field NO
// production caller has ever set true. An operator auditing workspace X was
// answered about workspace Y and nothing said so. A successful response from
// the wrong tenant is worse than a visible failure.
//
// THE RULE. When the operator NAMES a scope that diverges from the baked floor,
// every command has exactly one of four fates, and none of them is silence:
//
//   ScopeCarried          the URL the command actually builds already reads
//                         :workspace_slug/:project_slug (or the command declares
//                         a workspace/project arg). The flag reaches the wire.
//   ScopeMirrored         the server ADVERTISES a scoped_prefix for this command.
//                         BuildURL composes it, so the request goes to the
//                         workspace/project mirror instead of the flat route.
//   ScopeUnscopedByDesign declared, with a reason: -w/-p is meaningless for this
//                         command (it predates any workspace, or it operates
//                         ACROSS workspaces). Staying flat is the honest answer.
//   ScopeRefused          nothing can carry the scope. The CLI must refuse
//                         before it sends anything.
//
// WHY THE ADVERTISEMENT IS PER-COMMAND, NOT A SERVER FLAG. GET /v1/capabilities
// carries NO top-level mirror flag — checked live against
// guerrilla.barkpark.cloud on 2026-09-04: the response's only keys are
// auth_tier / commands / etag / generated_at / manifest_version / nouns /
// server, and the string "scoped_mirror" appears nowhere in it. What it DOES
// carry is a per-command `scoped_prefix` on 66 of 207 commands, every one of
// them "/w/:workspace_slug/p/:project_slug". That per-command key IS the
// advertisement, and the mirror behind it is live: on that same server
// GET /v1/data/query/production/task?limit=1 and
// GET /w/default/p/default/v1/data/query/production/task?limit=1 both answer
// 200 with an identical body, and /w/gyldendal/... answers 403 not_a_member —
// i.e. the mirror resolves AND isolates. url.go's older note that prepending
// "would 404/403" on today's servers is therefore stale for the commands that
// advertise a prefix.
//
// WHY DIVERGENCE, NOT PROVENANCE ALONE, ARMS THIS. Context.WorkspaceExplicit is
// true whenever ANY layer above Defaults spoke — including a saved config or a
// BARKPARK_WORKSPACE that is set to "default". Arming on provenance alone would
// re-route or refuse for every operator with a saved context, i.e. everyone.
// StatedScope requires BOTH provenance AND a value that differs from the floor,
// so the case that is currently CORRECT (floor scope, flat route) keeps its
// byte-identical behaviour and only the case that is currently WRONG changes.

// ScopeFate is what happens to an operator-stated -w/-p on one command.
type ScopeFate int

const (
	// ScopeCarried — the command's own URL reads the workspace/project scope.
	ScopeCarried ScopeFate = iota
	// ScopeMirrored — the server advertises a scoped_prefix; BuildURL composes it.
	ScopeMirrored
	// ScopeUnscopedByDesign — declared server-global with a reason; stays flat.
	ScopeUnscopedByDesign
	// ScopeRefused — nothing can carry the scope; the CLI must refuse before I/O.
	ScopeRefused
)

func (f ScopeFate) String() string {
	switch f {
	case ScopeCarried:
		return "carried"
	case ScopeMirrored:
		return "mirrored"
	case ScopeUnscopedByDesign:
		return "unscoped-by-design"
	case ScopeRefused:
		return "refused"
	}
	return "unknown"
}

// workspaceNames / projectNames are the placeholder and arg spellings that mean
// "the workspace scope" / "the project scope". They are the same sets
// resolvePlaceholder folds into ctx.Workspace / ctx.Project, kept here so a new
// alias is added in one place.
var (
	workspaceNames = []string{"workspace_slug", "workspace", "ws"}
	projectNames   = []string{"project_slug", "project", "p"}
)

// StatedScope returns the scope flags the operator NAMED to a value that
// diverges from the baked floor — "-w", "-p", or both — in flag order. Empty
// means the ambient floor is in play and nothing about the request changes.
//
// Divergence is deliberately ANDed with provenance rather than replacing it:
// `-w default` on an instance whose real workspace is named `default` is not a
// wrong answer waiting to happen, and a Context built as a literal (a test, a
// caller that skips Resolve) reads as not-stated and is left alone.
func StatedScope(ctx Context) []string {
	floor := DefaultDefaults()
	var out []string
	if ctx.WorkspaceExplicit && ctx.Workspace != "" && ctx.Workspace != floor.Workspace {
		out = append(out, "-w")
	}
	if ctx.ProjectExplicit && ctx.Project != "" && ctx.Project != floor.Project {
		out = append(out, "-p")
	}
	return out
}

// ScopeFateFor classifies one command. It is TOTAL — every command gets a fate,
// and "silently ignore the flag" is reachable only through an explicit
// declaration in scopeDispositions.
func ScopeFateFor(cmd Command) ScopeFate {
	if commandCarriesScope(cmd) {
		return ScopeCarried
	}
	if cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" {
		return ScopeMirrored
	}
	if d, ok := ScopeDispositionFor(cmd); ok && d.Unscoped {
		return ScopeUnscopedByDesign
	}
	return ScopeRefused
}

// commandCarriesScope reports whether the URL this command builds — its flat
// path_template plus the scoped_prefix when the auth_tier already composes it —
// reads the workspace or project scope, or whether the command declares one as
// its own arg/flag (e.g. workspace.project-create's :workspace_slug).
//
// The membership test is against the PARSED placeholder set, never
// strings.Contains(tmpl, ":"+n): ":p" is a prefix of :principal_ref, :paper_id,
// :plugin and :path, so the substring form reports "reads the project scope" on
// the strength of an unrelated segment.
func commandCarriesScope(cmd Command) bool {
	tmpl := cmd.HTTP.PathTemplate
	if isScopedTier(cmd.AuthTier) && cmd.ScopedPrefix != nil {
		tmpl = *cmd.ScopedPrefix + tmpl
	}
	present := PlaceholderNames(tmpl)
	declared := map[string]bool{}
	for _, a := range cmd.Args {
		declared[a.Name] = true
	}
	for _, f := range cmd.Flags {
		declared[f.Name] = true
	}
	for _, n := range append(append([]string{}, workspaceNames...), projectNames...) {
		if present[n] || declared[n] {
			return true
		}
	}
	return false
}

// ScopeDisposition is the DECLARED verdict for a family of commands whose URL
// cannot carry the workspace/project scope. Every such family must be declared:
// an undeclared one reds TestEveryUnscopableCommandIsDeclared, which is the
// point — a new command that quietly drops -w is a filing, not a default.
//
// Unscoped=false (refuse) is the safe verdict and the one to reach for when in
// doubt: the operator sees a usage-shaped refusal instead of another workspace's
// data. Unscoped=true is reserved for commands where the flag is meaningless by
// construction, not merely unimplemented.
type ScopeDisposition struct {
	// Unscoped true = staying flat is CORRECT and the flag is ignored on purpose.
	// false = refuse before I/O.
	Unscoped bool
	// Reason is why, in one sentence. Required — a declaration without one reds.
	Reason string
}

// scopeDispositions is keyed by manifest NOUN, because the reason is almost
// always a property of the resource family rather than of one verb.
// scopeDispositionOverrides handles the per-command exceptions.
//
// Every entry here was checked against the live guerrilla manifest on
// 2026-09-04: these are exactly the nouns with at least one command that has no
// scope placeholder in its path AND no advertised scoped_prefix.
var scopeDispositions = map[string]ScopeDisposition{
	"auth":      {Unscoped: true, Reason: "account identity on the SERVER — register/login/reset/mfa run before any workspace membership exists, so there is no workspace for -w to name"},
	"workspace": {Unscoped: true, Reason: "the workspace COLLECTION route (GET/POST /api/workspaces) operates across every workspace the caller can see; narrowing it to one would answer a different question than the one asked"},

	"access":              {Reason: "/v1/access grants are looked up by grant id; no workspace/project-scoped access route is advertised, so -w/-p cannot reach the wire"},
	"app_token":           {Reason: "/v1/auth/app-tokens is keyed on the calling identity, and no scoped mirror is advertised for it"},
	"bulldocs":            {Reason: "the bulldocs ingest routes address a paper by slug with no scope segment and advertise no scoped_prefix"},
	"chat":                {Reason: "chat sessions are addressed by session id with no scope segment and advertise no scoped_prefix"},
	"fleet":               {Reason: "the fleet roster/beat routes are instance-wide and advertise no scoped_prefix"},
	"fleet_support_token": {Reason: "fleet support tokens are minted against the instance, not a workspace, and advertise no scoped_prefix"},
	"graph":               {Reason: "the /v1/graph corpus routes carry no scope segment and advertise no scoped_prefix"},
	"incident":            {Reason: "status-page incidents are instance-wide and advertise no scoped_prefix"},
	"media":               {Reason: "the media search-settings routes scope by :dataset only and advertise no scoped_prefix"},
	"plugin":              {Reason: "plugin listing and settings are instance-wide and advertise no scoped_prefix"},
	"search":              {Reason: "the search settings/reindex routes scope by :dataset only and advertise no scoped_prefix"},
	"secret":              {Reason: "the flat /v1/secrets routes are the global-tier surface; the workspace-scoped secrets live under separate scoped verbs that carry the slugs in their own path_template"},
	"session":             {Reason: "session records are addressed by slug with no scope segment and advertise no scoped_prefix"},
	"share":               {Reason: "/v1/shares grants and tokens are addressed by id with no scope segment and advertise no scoped_prefix"},
	"sheets":              {Reason: "the sheets import/export routes address a sheet by slug with no scope segment and advertise no scoped_prefix"},
	"task":                {Reason: "the task ledger routes address a task by doc_id with no scope segment and advertise no scoped_prefix"},
	"ticket":              {Reason: "the ticket inbox routes carry no scope segment and advertise no scoped_prefix"},
	"ticket-key":          {Reason: "ticket signing keys are minted against the instance and advertise no scoped_prefix"},
	"webhook":             {Reason: "webhook subscriptions scope by :dataset only and advertise no scoped_prefix"},
}

// scopeDispositionOverrides declares a single command whose verdict differs
// from its noun's. Empty today; it exists so a per-command exception never has
// to be bought by loosening a whole family.
var scopeDispositionOverrides = map[string]ScopeDisposition{}

// ScopeDispositionFor returns the declared verdict for cmd — the per-command
// override first, then the noun. ok is false when the family is UNDECLARED,
// which ScopeFateFor treats as "refuse" (fail closed) and the manifest-wide
// enumeration test treats as a red.
func ScopeDispositionFor(cmd Command) (ScopeDisposition, bool) {
	if d, ok := scopeDispositionOverrides[cmd.ID]; ok {
		return d, true
	}
	d, ok := scopeDispositions[cmd.Noun]
	return d, ok
}

// DeclaredScopeNouns returns the declared nouns, sorted. Diagnostics and tests
// read the table through this rather than reaching into the map.
func DeclaredScopeNouns() []string {
	out := make([]string, 0, len(scopeDispositions))
	for n := range scopeDispositions {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}
