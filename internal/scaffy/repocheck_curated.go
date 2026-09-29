package scaffy

// repocheck_curated.go — the curated-tuple anchor expansion behind
// `bp scaffy validate --repo` when NO --var set is supplied.
//
// WHY A CURATED ALLOWLIST AND NOT "expand every EXAMPLES value".
// A command's declared EXAMPLES are PER-VARIABLE lists, not coherent
// tuples: pairing EXAMPLES[0] of each variable is a guess, and the guess
// is wrong often enough to manufacture false drift. The census that
// refuted the naive design (ledger recipe
// tooling/grip/ledger/scaffy-anchor-skip-remainder-2026-08-17.md) found
// three distinct ways an EXAMPLES-driven expansion lies:
//
//   * ensure-import — TargetFile EXAMPLES and AnchorLine EXAMPLES are
//     unpaired; every synthesized pair lands R-002 on a file that is
//     PRESENT. The file-existence guard defends only against R-001.
//   * remove-docs-card — the anchors are add-docs-card's PLANTED state.
//     They are correctly absent on a clean tree; a check there asserts a
//     precondition validate cannot establish.
//   * add-block-type — the anchors carry the NEW type being created, so
//     they are absent by construction on every tree.
//
// So expansion is allowlisted: a command is expanded only when a human
// has curated COHERENT var tuples that are asserted to resolve against
// the tree as it stands. Everything else keeps today's behaviour —
// SKIPPED and COUNTED in SkippedToken, never silently passed.
//
// The counters AnchorsExpanded / MembersChecked mirror SkippedToken so
// the summary stays honest about which half of the catalog was measured.
//
// MAINTENANCE. A tuple here is a CLAIM about the tree. When it stops
// resolving the check reds (R-002/R-001) — that is the point: the whole
// purpose of expansion is to notice a live anchor that drifted. Repair
// the tuple only when the COMMAND was deliberately re-pointed; otherwise
// the red is the catalog telling the truth. A tuple that no longer
// satisfies the command's declared VARIABLES reds as R-004 instead.

// RuleRepoCuratedInvalid fires when a curated tuple in this file no
// longer satisfies its command's declared VARIABLES (renamed variable,
// a value that fell out of a ONEOF, a new required variable). It is a
// defect in the curation, not in the tree, and it is scoped to the one
// command so a correct catalog elsewhere stays green.
const RuleRepoCuratedInvalid = "R-004"

// curatedVarSets maps a catalog command's file stem to the coherent var
// tuples expansion may use. A command absent from this map is never
// expanded. Each tuple MUST supply every declared VARIABLE (the D37
// contract newSubstituter enforces).
//
// Membership rule, stated so the next reader can re-derive it rather
// than trust the list: a (command, tuple) pair belongs here only when
// every IN-op path it produces EXISTS on a clean tree AND every
// structural anchor it produces RESOLVES there. Deliberate
// non-resolvers are omitted, not repaired — classify-block-type's
// `section` member is the standing example: @section is still a one-line
// ~w sigil (tiers.ex), so the tier list opener `  @section [` genuinely
// does not exist and the command is DOCUMENTED to fail loud there.
var curatedVarSets = map[string][]map[string]string{
	// Anchor: the head line itself, in the named file. Both tuples name
	// real files whose head lines are live.
	"add-canonical-marker": {
		{
			"TargetFile":   "internal/apiclient/client.go",
			"HeadLine":     "func New(cfg Config) *Client {",
			"slug":         "api-client-new",
			"Aka":          "New,client,constructor",
			"CommentToken": "//",
		},
		{
			"TargetFile":   "api/lib/barkpark/content/graph.ex",
			"HeadLine":     "  def clamp_depth(nil), do: @default_depth",
			"slug":         "graph-depth-clamp",
			"Aka":          "depth,clamp,bound",
			"CommentToken": "#",
		},
	},

	// Anchor: `  def register_routes(_ctx) do` + `    [`, byte-uniform
	// across the six block-list plugins. Only the PATH carries a token,
	// so one tuple per plugin exercises one live file each. sheets and
	// onixedit are deliberately omitted — the command's own prose says
	// they carry different shapes and refuse loud.
	"add-plugin-route": {
		{
			"Plugin": "github", "Method": "get", "Path": "/github/status",
			"Controller": "BarkparkWeb.GithubStatusController",
			"ActionName": "Status", "AuthBucket": "Token",
		},
		{
			"Plugin": "tasks", "Method": "get", "Path": "/tasks/ready",
			"Controller": "BarkparkWeb.TaskReadyController",
			"ActionName": "Ready", "AuthBucket": "TokenRoot",
		},
		{
			"Plugin": "tickets", "Method": "post", "Path": "/tickets/stats",
			"Controller": "BarkparkWeb.TicketStatsController",
			"ActionName": "Stats", "AuthBucket": "TicketKey",
		},
	},

	// Anchor: `  def cli_commands do` + `    [`. Two live plugins carry
	// the open shape today (tasks, bulldocs); tickets DELEGATES behind a
	// Code.ensure_loaded? guard and is deliberately omitted.
	"add-cli-verb": {
		{
			"Plugin": "tasks", "Noun": "task", "Verb": "waiting",
			"Summary":      "List tasks waiting on a claim, oldest first.",
			"PathTemplate": "/v1/tasks/waiting",
		},
		{
			"Plugin": "bulldocs", "Noun": "paper", "Verb": "stats",
			"Summary":      "Paper counts by lifecycle state.",
			"PathTemplate": "/v1/papers/stats",
		},
	},

	// Anchor: `  @{{.tier}} [`. element and widget are live list openers
	// (tiers.ex); `section` is the deliberate non-resolver and is NOT a
	// member here — a member-must-resolve rule would false-positive it.
	"classify-block-type": {
		{"BlockName": "timeline", "Tier": "element"},
		{"BlockName": "timeline", "Tier": "widget"},
	},
}
