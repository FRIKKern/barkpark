package setup

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// keyMsg builds a tea.KeyMsg for a named key the wizard's switch understands
// ("enter", "down", "up"). For these the wizard reads key.String(), which
// bubbletea maps directly from KeyType, so a typed KeyMsg is enough — no TTY.
func keyMsg(name string) tea.KeyMsg {
	switch name {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	default:
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(name)}
	}
}

// drive feeds a sequence of key names through Update and returns the final
// model.
func drive(m wizardModel, keys ...string) wizardModel {
	var model tea.Model = m
	for _, k := range keys {
		model, _ = model.Update(keyMsg(k))
	}
	return model.(wizardModel)
}

func twoKnownServers() []KnownServerInfo {
	return []KnownServerInfo{
		{Server: "https://api.barkpark.cloud", Token: "tok-prod", Workspace: "default", Project: "default", Dataset: "production", Tier: "admin", LastConnected: "2026-06-05T10:00:00Z", Active: true},
		{Server: "http://localhost:4000", Token: "barkpark-dev-token", Tier: "anonymous", LastConnected: "2026-06-04T09:00:00Z"},
	}
}

func TestWizardServerPickListRenders(t *testing.T) {
	m := newWizardModel(twoKnownServers())
	// Target stage defaults to Connect (index 0). Enter drops into the pick-list.
	m = drive(m, "enter")

	if m.stage != stageServerPick {
		t.Fatalf("connect + known servers should enter the pick-list, stage=%d", m.stage)
	}

	view := m.View()
	for _, want := range []string{
		"https://api.barkpark.cloud",
		"http://localhost:4000",
		"enter a new server", // the final "＋ enter a new server…" row
		"★",                   // the active marker on the active server
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("server-pick view missing %q:\n%s", want, view)
		}
	}
}

func TestWizardSelectSavedServerFillsPlan(t *testing.T) {
	m := newWizardModel(twoKnownServers())
	// enter -> pick-list; the first row is highlighted; enter selects it.
	m = drive(m, "enter", "enter")

	if m.pickedServer == nil {
		t.Fatalf("selecting the first row should set pickedServer")
	}
	// Picking a saved server skips the text input and lands on plugins.
	if m.stage != stagePlugins {
		t.Fatalf("after picking a saved server, stage should be plugins, got %d", m.stage)
	}

	p := m.plan()
	if p.Target != TargetConnect {
		t.Fatalf("target should be connect, got %q", p.Target)
	}
	if p.Server != "https://api.barkpark.cloud" {
		t.Fatalf("plan().Server should equal the picked server, got %q", p.Server)
	}
	if p.Token != "tok-prod" || p.Dataset != "production" {
		t.Fatalf("plan should carry the picked server's token+scope: token=%q dataset=%q", p.Token, p.Dataset)
	}
}

func TestWizardPickNewRevealsTextInput(t *testing.T) {
	m := newWizardModel(twoKnownServers())
	// enter -> pick-list, then down twice to land on the "new" row (index 2 of
	// 3 rows: 2 servers + 1 new), then enter.
	m = drive(m, "enter", "down", "down", "enter")

	if !m.pickedNew {
		t.Fatalf("selecting the final row should set pickedNew")
	}
	if m.stage != stageInputs {
		t.Fatalf("picking 'new' should reveal the text input (stageInputs), got %d", m.stage)
	}
	if len(m.inputs) == 0 || m.inputKeys[0] != "server" {
		t.Fatalf("new-server path should build the server text input, keys=%v", m.inputKeys)
	}
}

func TestWizardNoKnownServersSkipsPickList(t *testing.T) {
	m := newWizardModel(nil) // no history
	m = drive(m, "enter")    // connect + no history => straight to inputs

	if m.stage != stageInputs {
		t.Fatalf("no known servers should behave as before (text input only), got stage %d", m.stage)
	}
	if len(m.inputs) == 0 || m.inputKeys[0] != "server" {
		t.Fatalf("expected the server text input on the no-history path, keys=%v", m.inputKeys)
	}
}

// TestWizardLocalFlowEntersProfileStage pins the C1 stage sequence for a
// seeding target: target → inputs (docker toggle) → PROFILE → plugins.
func TestWizardLocalFlowEntersProfileStage(t *testing.T) {
	m := newWizardModel(nil)
	// down to Local (index 1), enter → inputs (docker toggle), enter → profile.
	m = drive(m, "down", "enter", "enter")

	if m.stage != stageProfile {
		t.Fatalf("local inputs should advance to the profile stage, got %d", m.stage)
	}
	view := m.View()
	for _, want := range []string{"content profile", "Clean", "Demo", "BARKPARK_SEED_PROFILE=demo make seed"} {
		if !strings.Contains(view, want) {
			t.Fatalf("profile view missing %q:\n%s", want, view)
		}
	}

	// Enter on the default (clean) row advances to plugins.
	m = drive(m, "enter")
	if m.stage != stagePlugins {
		t.Fatalf("profile select should advance to plugins, got %d", m.stage)
	}
}

// TestWizardConnectSkipsProfileStage: connect never seeds, so the inputs stage
// jumps straight to plugins and the plan carries no profile.
func TestWizardConnectSkipsProfileStage(t *testing.T) {
	m := newWizardModel(nil)
	m = drive(m, "enter", "enter") // connect → inputs → (enter) next stage

	if m.stage != stagePlugins {
		t.Fatalf("connect should skip the profile stage, got %d", m.stage)
	}
	if p := m.plan(); p.Profile != "" {
		t.Fatalf("connect plan should carry no profile, got %q", p.Profile)
	}
}

// TestWizardProfileDefaultCleanPrechecksBulldocsAndTasks: leaving the profile
// stage on the default (clean) pre-checks bulldocs and tasks in the plugin
// multi-select, and the assembled plan carries Profile=clean.
func TestWizardProfileDefaultCleanPrechecksBulldocsAndTasks(t *testing.T) {
	m := newWizardModel(nil)
	m = drive(m, "down", "enter", "enter", "enter") // local → inputs → profile → plugins

	if m.stage != stagePlugins {
		t.Fatalf("expected plugins stage, got %d", m.stage)
	}
	for i, p := range m.plugins {
		want := p == "bulldocs" || p == "tasks"
		if m.pluginPick[i] != want {
			t.Fatalf("clean precheck: plugin %q picked=%v, want %v", p, m.pluginPick[i], want)
		}
	}
	plan := m.plan()
	if plan.Profile != ProfileClean {
		t.Fatalf("plan.Profile = %q, want %q", plan.Profile, ProfileClean)
	}
	got := plan.Plugins
	if len(got) != 2 {
		t.Fatalf("clean precheck should whitelist bulldocs+tasks (2 plugins), got %v", got)
	}
	pluginSet := map[string]bool{}
	for _, p := range got {
		pluginSet[p] = true
	}
	if !pluginSet["bulldocs"] || !pluginSet["tasks"] {
		t.Fatalf("clean precheck should whitelist bulldocs and tasks, got %v", got)
	}
}

// TestWizardProfileDemoKeepsAllPlugins: choosing demo leaves the all-checked
// default and the plan carries Profile=demo (Plugins nil = all bundled).
func TestWizardProfileDemoKeepsAllPlugins(t *testing.T) {
	m := newWizardModel(nil)
	m = drive(m, "down", "enter", "enter", "down", "enter") // profile: down → Demo

	plan := m.plan()
	if plan.Profile != ProfileDemo {
		t.Fatalf("plan.Profile = %q, want %q", plan.Profile, ProfileDemo)
	}
	if plan.Plugins != nil {
		t.Fatalf("demo should keep the all-bundled default (nil), got %v", plan.Plugins)
	}
}

// TestWizardProfilePrecheckNeverOverridesTouchedPlugins: a deliberate plugin
// toggle survives even when the user navigates the profile stage afterwards.
func TestWizardProfilePrecheckNeverOverridesTouchedPlugins(t *testing.T) {
	m := newWizardModel(nil)
	m = drive(m, "down", "enter", "enter", "enter") // land on plugins (clean precheck)
	m = drive(m, "a")                               // user checks ALL — a deliberate touch
	if !m.pluginsTouched {
		t.Fatalf("toggling should mark pluginsTouched")
	}
	m.applyProfilePrecheck() // a later precheck must be a no-op
	for i, on := range m.pluginPick {
		if !on {
			t.Fatalf("touched selection was overridden for %q", m.plugins[i])
		}
	}
}

// TestWizardConfirmShowsProfileLine: the confirm screen renders the profile
// line for a seeding target.
func TestWizardConfirmShowsProfileLine(t *testing.T) {
	m := newWizardModel(nil)
	m = drive(m, "down", "enter", "enter", "enter", "enter") // through to confirm

	if m.stage != stageConfirm {
		t.Fatalf("expected confirm stage, got %d", m.stage)
	}
	view := m.View()
	if !strings.Contains(view, "profile:") || !strings.Contains(view, "clean (papers + media)") {
		t.Fatalf("confirm view missing the profile line:\n%s", view)
	}
}

// TestWizardTargetContextLine: a re-run with an active saved server shows the
// "currently connected to …" context line under the title.
func TestWizardTargetContextLine(t *testing.T) {
	m := newWizardModel(twoKnownServers())
	view := m.View()
	if !strings.Contains(view, "currently connected to https://api.barkpark.cloud (★)") {
		t.Fatalf("target view missing the currently-connected context line:\n%s", view)
	}
}
