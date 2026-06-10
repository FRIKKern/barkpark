package setup

import (
	"bytes"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Wizard is the interactive step flow `bp setup` (no --target on a TTY) runs.
// It is a Bubble Tea program over bubbles/textinput, styled to match the TUI
// palette (styles.go): target select → per-target inputs → plugin multi-select →
// a CONFIRM screen showing the SetupPlan + (for destructive/outbound targets) the
// dry-run plan → on confirm, returns the fully-formed SetupPlan to RunInteractive,
// which calls Execute(plan, {Confirm:true}).
//
// Wire it by assigning Wizard to Options.Wizard. It returns ErrWizardAborted when
// the user quits before confirming, so the caller can exit cleanly without
// running anything.
func Wizard(opts Options) (SetupPlan, error) {
	m := newWizardModel(opts.KnownServers)
	prog := tea.NewProgram(m)
	res, err := prog.Run()
	if err != nil {
		return SetupPlan{}, fmt.Errorf("wizard: %w", err)
	}
	final := res.(wizardModel)
	if final.aborted {
		return SetupPlan{}, ErrWizardAborted
	}
	return final.plan(), nil
}

// ErrWizardAborted is returned when the user quits the wizard before confirming.
// RunInteractive maps it to a clean exit (no error printed, nothing executed).
var ErrWizardAborted = fmt.Errorf("setup wizard aborted")

// ── styling (mirrors styles.go's palette: highlight #60a5fa / dim #52525b) ──

var (
	wzTitle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#60a5fa"})
	wzDim    = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"})
	wzSel    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#93c5fd"})
	wzCheck  = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#10b981", Dark: "#34d399"})
	wzLabel  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.AdaptiveColor{Light: "#71717a", Dark: "#a1a1aa"})
	wzAmber  = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#f59e0b", Dark: "#fbbf24"})
	wzBorder = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.AdaptiveColor{Light: "#d4d4d8", Dark: "#3f3f46"}).Padding(0, 1)
)

// wizardStage enumerates the linear flow.
type wizardStage int

const (
	stageTarget wizardStage = iota
	stageServerPick // connect-only: pick a remembered server or "enter a new server…"
	stageInputs
	stageProfile // local/deploy/provision only: clean vs demo seed content
	stagePlugins
	stageConfirm
	stageDone
)

// targetChoice is one row in the target-select list.
type targetChoice struct {
	target Target
	label  string
	blurb  string
}

var targetChoices = []targetChoice{
	{TargetConnect, "Connect", "point bp at an existing server"},
	{TargetLocal, "Local", "bring up a dev server here (docker or native)"},
	{TargetDeploy, "Deploy", "install on a server you own over SSH"},
	{TargetProvision, "Provision", "create a cloud host, then deploy (staged)"},
}

// wizardModel is the Bubble Tea model carrying the whole flow's state.
type wizardModel struct {
	stage   wizardStage
	aborted bool

	// target select
	targetIdx int

	// connect pick-list: remembered servers (most-recent-first) the connect flow
	// offers before the text input. Empty => no pick-list (text input only, as
	// before). serverIdx points at the highlighted row; the final row (index ==
	// len(knownServers)) is the "enter a new server…" escape. pickedNew is set
	// once the user chose that row (or there were no known servers), revealing the
	// text input. pickedServer holds the chosen entry when a saved row was picked.
	knownServers []KnownServerInfo
	serverIdx    int
	pickedNew    bool
	pickedServer *KnownServerInfo

	// per-target inputs (a small set of textinputs + a docker toggle)
	inputs    []textinput.Model
	inputKeys []string // parallel to inputs: which SetupPlan field each fills
	inputIdx  int
	docker    bool // local: docker vs native

	// profile select (local/deploy/provision; connect never seeds).
	// 0 = clean (default), 1 = demo.
	profileIdx int

	// plugin multi-select. pluginsTouched flips once the user toggles anything,
	// so the profile stage's precheck never overrides a deliberate selection.
	plugins        []string
	pluginPick     []bool
	pluginIdx      int
	pluginsTouched bool

	confirmYes bool
}

func newWizardModel(known []KnownServerInfo) wizardModel {
	plugins := DiscoverPlugins()
	pick := make([]bool, len(plugins))
	for i := range pick {
		pick[i] = true // default: all bundled checked
	}
	return wizardModel{
		stage:        stageTarget,
		plugins:      plugins,
		pluginPick:   pick,
		knownServers: known,
	}
}

func (m wizardModel) Init() tea.Cmd { return nil }

// target returns the currently-selected Target.
func (m wizardModel) target() Target { return targetChoices[m.targetIdx].target }

// buildInputs constructs the textinputs for the chosen target. Connect needs a
// server URL; deploy needs ssh-host + domain; provision needs region + server
// type (provider is a sub-select folded into the target inputs as a text field
// for simplicity). Local needs only the docker toggle (handled separately).
func (m *wizardModel) buildInputs() {
	m.inputs = nil
	m.inputKeys = nil
	add := func(key, placeholder, value string) {
		ti := textinput.New()
		ti.Placeholder = placeholder
		ti.SetValue(value)
		ti.Prompt = "  "
		m.inputs = append(m.inputs, ti)
		m.inputKeys = append(m.inputKeys, key)
	}
	switch m.target() {
	case TargetConnect:
		add("server", "https://api.example.com", "")
	case TargetLocal:
		// no text inputs — docker toggle only
	case TargetDeploy:
		add("ssh-host", "root@1.2.3.4", "")
		add("domain", "demo.example.com  (or the server IP + scheme http)", "")
		add("scheme", "https", "https")
	case TargetProvision:
		add("provider", "hetzner | azure", "hetzner")
		add("region", "nbg1", "")
		add("server-type", "cax11", "")
		add("domain", "demo.example.com  (or the server IP + scheme http)", "")
	}
	m.inputIdx = 0
	if len(m.inputs) > 0 {
		m.inputs[0].Focus()
	}
}

func (m wizardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	key, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}
	switch key.String() {
	case "ctrl+c", "q":
		if m.stage != stageInputs { // 'q' is a valid char in text inputs
			m.aborted = true
			return m, tea.Quit
		}
	case "esc":
		m.aborted = true
		return m, tea.Quit
	}

	switch m.stage {
	case stageTarget:
		return m.updateTarget(key)
	case stageServerPick:
		return m.updateServerPick(key)
	case stageInputs:
		return m.updateInputs(key)
	case stageProfile:
		return m.updateProfile(key)
	case stagePlugins:
		return m.updatePlugins(key)
	case stageConfirm:
		return m.updateConfirm(key)
	}
	return m, nil
}

// afterInputs is the stage that follows the inputs screen: the profile select
// for the seeding targets (local/deploy/provision), plugins for connect (a
// pure upsert never seeds, so it never asks).
func (m wizardModel) afterInputs() wizardStage {
	if m.target() == TargetConnect {
		return stagePlugins
	}
	return stageProfile
}

func (m wizardModel) updateTarget(key tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch key.String() {
	case "up", "k":
		if m.targetIdx > 0 {
			m.targetIdx--
		}
	case "down", "j":
		if m.targetIdx < len(targetChoices)-1 {
			m.targetIdx++
		}
	case "enter":
		// Connect with a non-empty history: offer the pick-list first. Every other
		// case goes straight to the inputs stage (text input / docker toggle).
		if m.target() == TargetConnect && len(m.knownServers) > 0 {
			m.serverIdx = 0
			m.pickedNew = false
			m.pickedServer = nil
			m.stage = stageServerPick
			return m, nil
		}
		m.buildInputs()
		// Local with no text inputs jumps straight to the docker toggle within
		// the inputs stage; the inputs view renders the toggle for local.
		m.stage = stageInputs
	}
	return m, nil
}

// updateServerPick drives the connect pick-list. Rows 0..len-1 are remembered
// servers; the final row is "enter a new server…". Enter on a saved row fills
// the server from history and skips the text input (straight to plugins); enter
// on the new row reveals the text input.
func (m wizardModel) updateServerPick(key tea.KeyMsg) (tea.Model, tea.Cmd) {
	newRow := len(m.knownServers) // index of the "＋ enter a new server…" row
	switch key.String() {
	case "up", "k":
		if m.serverIdx > 0 {
			m.serverIdx--
		}
	case "down", "j":
		if m.serverIdx < newRow {
			m.serverIdx++
		}
	case "enter":
		if m.serverIdx == newRow {
			// "enter a new server…" — reveal the text input.
			m.pickedNew = true
			m.pickedServer = nil
			m.buildInputs()
			m.stage = stageInputs
			return m, nil
		}
		// A saved server was picked: fill it and skip the text input.
		picked := m.knownServers[m.serverIdx]
		m.pickedServer = &picked
		m.pickedNew = false
		m.stage = stagePlugins
		return m, nil
	}
	return m, nil
}

func (m wizardModel) updateInputs(key tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Local: the inputs stage is just the docker toggle + advance.
	if m.target() == TargetLocal {
		switch key.String() {
		case "d", "left", "right", " ", "tab":
			m.docker = !m.docker
			return m, nil
		case "enter":
			m.stage = m.afterInputs()
			return m, nil
		}
		return m, nil
	}

	switch key.String() {
	case "tab", "down":
		m.focusInput(m.inputIdx + 1)
		return m, nil
	case "shift+tab", "up":
		m.focusInput(m.inputIdx - 1)
		return m, nil
	case "enter":
		if m.inputIdx < len(m.inputs)-1 {
			m.focusInput(m.inputIdx + 1)
			return m, nil
		}
		m.stage = m.afterInputs()
		return m, nil
	}
	var cmd tea.Cmd
	m.inputs[m.inputIdx], cmd = m.inputs[m.inputIdx].Update(key)
	return m, cmd
}

func (m *wizardModel) focusInput(idx int) {
	if idx < 0 {
		idx = 0
	}
	if idx > len(m.inputs)-1 {
		idx = len(m.inputs) - 1
	}
	for i := range m.inputs {
		if i == idx {
			m.inputs[i].Focus()
		} else {
			m.inputs[i].Blur()
		}
	}
	m.inputIdx = idx
}

// updateProfile drives the content-profile select: row 0 is clean (the
// recommended default), row 1 is demo. Enter applies the profile's plugin
// precheck and advances to the plugin multi-select.
func (m wizardModel) updateProfile(key tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch key.String() {
	case "up", "k":
		if m.profileIdx > 0 {
			m.profileIdx--
		}
	case "down", "j":
		if m.profileIdx < 1 {
			m.profileIdx++
		}
	case "enter":
		m.applyProfilePrecheck()
		m.stage = stagePlugins
	}
	return m, nil
}

// profile returns the selected seed profile.
func (m wizardModel) profile() string {
	if m.profileIdx == 1 {
		return ProfileDemo
	}
	return ProfileClean
}

// applyProfilePrecheck aligns the plugin pre-selection with the chosen profile
// — clean pre-checks only bulldocs (the whitelist matches the clean desk; the
// server unions media in), demo restores the all-checked default. It never
// overrides a selection the user already touched.
func (m *wizardModel) applyProfilePrecheck() {
	if m.pluginsTouched {
		return
	}
	for i := range m.pluginPick {
		if m.profile() == ProfileClean {
			m.pluginPick[i] = m.plugins[i] == "bulldocs"
		} else {
			m.pluginPick[i] = true
		}
	}
}

func (m wizardModel) updatePlugins(key tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch key.String() {
	case "up", "k":
		if m.pluginIdx > 0 {
			m.pluginIdx--
		}
	case "down", "j":
		if m.pluginIdx < len(m.plugins)-1 {
			m.pluginIdx++
		}
	case " ", "x":
		if len(m.pluginPick) > 0 {
			m.pluginPick[m.pluginIdx] = !m.pluginPick[m.pluginIdx]
			m.pluginsTouched = true
		}
	case "a":
		for i := range m.pluginPick {
			m.pluginPick[i] = true
		}
		m.pluginsTouched = true
	case "n":
		for i := range m.pluginPick {
			m.pluginPick[i] = false
		}
		m.pluginsTouched = true
	case "enter":
		m.stage = stageConfirm
	}
	return m, nil
}

func (m wizardModel) updateConfirm(key tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch key.String() {
	case "y", "enter":
		m.confirmYes = true
		m.stage = stageDone
		return m, tea.Quit
	case "n":
		m.aborted = true
		return m, tea.Quit
	}
	return m, nil
}

// selectedPlugins maps the multi-select state onto the plan's Plugins slice with
// the kill-switch semantics: ALL checked => nil (unset = all bundled); a strict
// subset => that subset; NONE checked => an explicit empty slice (kill switch).
func (m wizardModel) selectedPlugins() []string {
	all := true
	none := true
	var picked []string
	for i, on := range m.pluginPick {
		if on {
			picked = append(picked, m.plugins[i])
			none = false
		} else {
			all = false
		}
	}
	switch {
	case all:
		return nil // unset semantics: register everything
	case none:
		return []string{} // explicit kill switch
	default:
		return picked
	}
}

// plan assembles the final SetupPlan from the collected state. When the connect
// pick-list selected a remembered server, the server URL + its token/scope come
// from history rather than the (skipped) text input.
func (m wizardModel) plan() SetupPlan {
	p := SetupPlan{Target: m.target(), Plugins: m.selectedPlugins()}
	vals := map[string]string{}
	for i, k := range m.inputKeys {
		vals[k] = strings.TrimSpace(m.inputs[i].Value())
	}
	p.Server = vals["server"]
	p.SSHHost = vals["ssh-host"]
	p.Domain = vals["domain"]
	p.Scheme = vals["scheme"]
	p.Provider = vals["provider"]
	p.Region = vals["region"]
	p.ServerType = vals["server-type"]
	if m.target() == TargetLocal {
		p.Docker = m.docker
	}
	if m.target() != TargetConnect {
		p.Profile = m.profile()
	}
	if m.pickedServer != nil {
		p.Server = m.pickedServer.Server
		p.Token = m.pickedServer.Token
		p.Workspace = m.pickedServer.Workspace
		p.Project = m.pickedServer.Project
		p.Dataset = m.pickedServer.Dataset
	}
	return p
}

// ── views ──

func (m wizardModel) View() string {
	switch m.stage {
	case stageTarget:
		return m.viewTarget()
	case stageServerPick:
		return m.viewServerPick()
	case stageInputs:
		return m.viewInputs()
	case stageProfile:
		return m.viewProfile()
	case stagePlugins:
		return m.viewPlugins()
	case stageConfirm:
		return m.viewConfirm()
	}
	return ""
}

func (m wizardModel) viewTarget() string {
	var b strings.Builder
	b.WriteString(wzTitle.Render("bp setup") + wzDim.Render(" — choose a target") + "\n\n")
	// Context line on a re-run: show which server bp currently defaults to.
	for _, s := range m.knownServers {
		if s.Active {
			b.WriteString(wzDim.Render("currently connected to "+s.Server+" (★)") + "\n\n")
			break
		}
	}
	for i, c := range targetChoices {
		cursor := "  "
		label := c.label
		if i == m.targetIdx {
			cursor = wzSel.Render("▸ ")
			label = wzSel.Render(label)
		}
		b.WriteString(fmt.Sprintf("%s%-10s %s\n", cursor, label, wzDim.Render(c.blurb)))
	}
	b.WriteString("\n" + wzDim.Render("↑/↓ move · enter select · q quit") + "\n")
	return b.String()
}

// viewServerPick renders the remembered-server pick-list: one row per saved
// server (URL + dim "last connected <when>", the active one marked ▸★), then a
// final "＋ enter a new server…" row.
func (m wizardModel) viewServerPick() string {
	var b strings.Builder
	b.WriteString(wzTitle.Render("bp setup → connect") + wzDim.Render(" — pick a server") + "\n\n")

	for i, s := range m.knownServers {
		cursor := "  "
		mark := "  "
		url := s.Server
		if s.Active {
			mark = wzCheck.Render("★ ")
		}
		if i == m.serverIdx {
			cursor = wzSel.Render("▸ ")
			url = wzSel.Render(url)
		}
		when := ""
		if s.LastConnected != "" {
			when = wzDim.Render("  last connected " + relativeTime(s.LastConnected))
		}
		b.WriteString(fmt.Sprintf("%s%s%s%s\n", cursor, mark, url, when))
	}

	// Final row: enter a new server.
	cursor := "  "
	label := "＋ enter a new server…"
	if m.serverIdx == len(m.knownServers) {
		cursor = wzSel.Render("▸ ")
		label = wzSel.Render(label)
	}
	b.WriteString(fmt.Sprintf("%s  %s\n", cursor, label))

	b.WriteString("\n" + wzDim.Render("↑/↓ move · enter select · esc quit") + "\n")
	return b.String()
}

func (m wizardModel) viewInputs() string {
	var b strings.Builder
	b.WriteString(wzTitle.Render("bp setup → "+targetChoices[m.targetIdx].label) + "\n\n")

	if m.target() == TargetLocal {
		mode := "native (mix + postgres)"
		if m.docker {
			mode = "docker compose"
		}
		b.WriteString(wzLabel.Render("bring-up mode:") + " " + wzSel.Render(mode) + "\n")
		b.WriteString(wzDim.Render("  (d / space toggles docker ↔ native)") + "\n")
		b.WriteString("\n" + wzAmber.Render("note: this resets a local database on the real run") + "\n")
		b.WriteString("\n" + wzDim.Render("enter continue · esc quit") + "\n")
		return b.String()
	}

	for i, ti := range m.inputs {
		b.WriteString(wzLabel.Render(m.inputKeys[i]+":") + "\n")
		b.WriteString(ti.View() + "\n")
		_ = i
	}
	b.WriteString("\n" + wzDim.Render("tab/↑↓ move · enter next · esc quit") + "\n")
	return b.String()
}

// viewProfile renders the content-profile select (local/deploy/provision only).
func (m wizardModel) viewProfile() string {
	var b strings.Builder
	b.WriteString(wzTitle.Render("bp setup → content profile") + "\n\n")

	rows := []struct{ label, blurb string }{
		{"Clean", "papers + media only — the recommended starting point"},
		{"Demo", "8 example schemas + 27 documents (kitchen-sink dev fixture)"},
	}
	for i, r := range rows {
		cursor := "  "
		label := r.label
		if i == m.profileIdx {
			cursor = wzSel.Render("▸ ")
			label = wzSel.Render(label)
		}
		b.WriteString(fmt.Sprintf("%s%-10s %s\n", cursor, label, wzDim.Render(r.blurb)))
	}
	b.WriteString("\n" + wzDim.Render("the demo profile is always available later: BARKPARK_SEED_PROFILE=demo make seed") + "\n")
	b.WriteString("\n" + wzDim.Render("↑/↓ move · enter select · esc quit") + "\n")
	return b.String()
}

func (m wizardModel) viewPlugins() string {
	var b strings.Builder
	b.WriteString(wzTitle.Render("bp setup → plugins") + "\n\n")
	b.WriteString(wzDim.Render("default: all bundled checked (= BARKPARK_PLUGINS unset). Uncheck to whitelist; none = kill switch.") + "\n\n")
	for i, p := range m.plugins {
		box := "[ ]"
		if m.pluginPick[i] {
			box = wzCheck.Render("[x]")
		}
		cursor := "  "
		name := p
		if i == m.pluginIdx {
			cursor = wzSel.Render("▸ ")
			name = wzSel.Render(p)
		}
		b.WriteString(fmt.Sprintf("%s%s %s\n", cursor, box, name))
	}
	b.WriteString("\n" + wzDim.Render("space toggle · a all · n none · enter continue · esc quit") + "\n")
	return b.String()
}

func (m wizardModel) viewConfirm() string {
	var b strings.Builder
	p := m.plan()
	b.WriteString(wzTitle.Render("bp setup → confirm") + "\n\n")

	b.WriteString(wzLabel.Render("target:  ") + " " + p.Target + "\n")
	switch p.Target {
	case TargetConnect:
		b.WriteString(wzLabel.Render("server:  ") + " " + dash(p.Server) + "\n")
	case TargetLocal:
		mode := "native"
		if p.Docker {
			mode = "docker"
		}
		b.WriteString(wzLabel.Render("mode:    ") + " " + mode + "\n")
	case TargetDeploy:
		b.WriteString(wzLabel.Render("ssh-host:") + " " + dash(p.SSHHost) + "\n")
		b.WriteString(wzLabel.Render("domain:  ") + " " + dash(p.Domain) + "\n")
		b.WriteString(wzLabel.Render("scheme:  ") + " " + dash(p.Scheme) + "\n")
	case TargetProvision:
		b.WriteString(wzLabel.Render("provider:") + " " + dash(p.Provider) + "\n")
		b.WriteString(wzLabel.Render("region:  ") + " " + dash(p.Region) + "\n")
		b.WriteString(wzLabel.Render("type:    ") + " " + dash(p.ServerType) + "\n")
		b.WriteString(wzLabel.Render("domain:  ") + " " + dash(p.Domain) + "\n")
	}
	if p.Target != TargetConnect {
		b.WriteString(wzLabel.Render("profile: ") + " " + profileSummary(p.profileOrDefault()) + "\n")
	}
	b.WriteString(wzLabel.Render("plugins: ") + " " + PluginsSummary(p.Plugins) + "\n")

	// For destructive/outbound targets, show the dry-run plan inline so the
	// operator confirms against the EXACT commands.
	if p.Target != TargetConnect {
		var buf bytes.Buffer
		_ = Execute(p, Options{DryRun: true, Out: &buf})
		b.WriteString("\n" + wzBorder.Render(strings.TrimRight(buf.String(), "\n")) + "\n")
	}

	b.WriteString("\n" + wzAmber.Render("proceed for real?") + " " + wzDim.Render("y confirm · n abort") + "\n")
	return b.String()
}

// relativeTime renders an RFC3339 timestamp as a coarse "<n> ago" phrase for the
// pick-list. An unparseable value is returned verbatim so the row still shows
// something rather than a blank.
func relativeTime(rfc3339 string) string {
	t, err := time.Parse(time.RFC3339, rfc3339)
	if err != nil {
		return rfc3339
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

func dash(s string) string {
	if strings.TrimSpace(s) == "" {
		return wzDim.Render("(none)")
	}
	return s
}
