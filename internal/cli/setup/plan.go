package setup

// Plan is the structured, render-agnostic description of what a dry-run WOULD do.
// Each executor builds one in dry-run mode (via BuildPlan). The cli built-in
// renders it as the machine-readable JSON object an AI/automation consumes; the
// human dry-run path keeps each executor's existing prose verbatim (so the
// default text output is unchanged). No datum the human prose shows is missing
// from the JSON — the structured fields below mirror every line.
type Plan struct {
	Target          string            `json:"target"`
	DryRun          bool              `json:"dry_run"`
	Destructive     bool              `json:"destructive"`
	RequiresConfirm bool              `json:"requires_confirm"`
	Steps           []PlanStep        `json:"steps"`
	Env             map[string]string `json:"env,omitempty"`
	Plugins         PlanPlugins       `json:"plugins"`
	Needs           []PlanNeed        `json:"needs,omitempty"`
	ConnectTo       string            `json:"connect_to,omitempty"`

	// Profile is the resolved seed content profile ("clean" | "demo") for the
	// seeding targets (local/deploy/provision); empty for connect, which never
	// seeds. The matching env rides in Env as BARKPARK_SEED_PROFILE.
	Profile string `json:"profile,omitempty"`

	// KnownServers is the connect history surfaced to a JSON dry-run so an agent
	// can see the cached servers (and which is active) before connecting. Only
	// populated for the connect target.
	KnownServers []PlanKnownServer `json:"known_servers,omitempty"`

	// provision-only descriptors (omitted when empty)
	Provider   string `json:"provider,omitempty"`
	Region     string `json:"region,omitempty"`
	ServerType string `json:"server_type,omitempty"`
}

// PlanKnownServer is one remembered server in the connect Plan's known_servers
// array — the minimal, credential-free view an agent needs to see the cache.
type PlanKnownServer struct {
	Server        string `json:"server"`
	Active        bool   `json:"active"`
	LastConnected string `json:"last_connected,omitempty"`
}

// PlanStep is one ordered action in the plan. N is 1-based. Command is the
// copy-pasteable shell line when the step shells out; empty for narration-only
// beats (a "wait for X" / "verify Y" the executor handles inline).
type PlanStep struct {
	N           int    `json:"n"`
	Description string `json:"description"`
	Command     string `json:"command,omitempty"`
}

// PlanPlugins is the resolved plugin selection in machine form. Mode is one of
// "all" (BARKPARK_PLUGINS unset — registry discovers everything), "none" (the
// explicit kill switch, BARKPARK_PLUGINS=), or "whitelist" (Value is the CSV).
type PlanPlugins struct {
	Mode  string `json:"mode"`
	Value string `json:"value,omitempty"`
}

// PlanNeed is one prerequisite the plan reports for a real run: a CLI binary on
// PATH or a credential. Present reflects whether it was found at plan time.
type PlanNeed struct {
	What    string `json:"what"`
	Present bool   `json:"present"`
}

// planPlugins maps a plugin selection onto the structured PlanPlugins form,
// reusing PluginsEnvValue's kill-switch semantics so the JSON mode/value agree
// with the env line and the human summary.
func planPlugins(selected []string) PlanPlugins {
	value, set := PluginsEnvValue(selected)
	switch {
	case !set:
		return PlanPlugins{Mode: "all"}
	case value == "":
		return PlanPlugins{Mode: "none"}
	default:
		return PlanPlugins{Mode: "whitelist", Value: value}
	}
}

// addStep appends an ordered step to the plan, auto-numbering it.
func (p *Plan) addStep(description, command string) {
	p.Steps = append(p.Steps, PlanStep{N: len(p.Steps) + 1, Description: description, Command: command})
}

// Result is the structured outcome of a REAL (non-dry-run) setup run, emitted as
// JSON when the caller resolved the JSON output format. Message is a short human
// one-liner; the typed fields carry the machine-readable outcome.
type Result struct {
	OK         bool   `json:"ok"`
	Target     string `json:"target"`
	Server     string `json:"server,omitempty"`
	Tier       string `json:"tier,omitempty"`
	ConfigPath string `json:"config_path,omitempty"`
	Message    string `json:"message,omitempty"`

	// Profile echoes the seed profile that ran for the seeding targets
	// ("clean" | "demo"); empty on a pure connect. StudioURL and Next are the
	// machine form of the human done-screen (additive — existing keys untouched).
	Profile   string   `json:"profile,omitempty"`
	StudioURL string   `json:"studio_url,omitempty"`
	Next      []string `json:"next,omitempty"`
}
