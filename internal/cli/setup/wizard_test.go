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
