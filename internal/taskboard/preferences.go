package taskboard

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
)

const taskboardPreferencesFile = "taskboard-preferences.json"

// taskboardPreferences contains user-owned presentation choices that should
// survive a `bp tasks` restart. Ratios are stored instead of terminal columns
// so the chosen split remains useful when the next terminal has a different
// width.
type taskboardPreferences struct {
	DetailsPaneRatio float64 `json:"details_pane_ratio"`
}

// loadTaskboardPreferences is deliberately tolerant. Preferences improve the
// presentation but are never allowed to prevent the task board from opening.
func loadTaskboardPreferences(dir string) (taskboardPreferences, bool) {
	if dir == "" {
		return taskboardPreferences{}, false
	}
	raw, err := os.ReadFile(filepath.Join(dir, taskboardPreferencesFile))
	if err != nil {
		return taskboardPreferences{}, false
	}
	var prefs taskboardPreferences
	if err := json.Unmarshal(raw, &prefs); err != nil {
		return taskboardPreferences{}, false
	}
	if prefs.DetailsPaneRatio <= 0 || prefs.DetailsPaneRatio >= 1 ||
		math.IsNaN(prefs.DetailsPaneRatio) || math.IsInf(prefs.DetailsPaneRatio, 0) {
		return taskboardPreferences{}, false
	}
	return prefs, true
}

// saveTaskboardPreferences atomically persists the current split. Like the
// first-paint cache, this is best-effort: a read-only config directory must not
// interrupt the TUI.
func saveTaskboardPreferences(dir string, prefs taskboardPreferences) {
	if dir == "" || prefs.DetailsPaneRatio <= 0 || prefs.DetailsPaneRatio >= 1 ||
		math.IsNaN(prefs.DetailsPaneRatio) || math.IsInf(prefs.DetailsPaneRatio, 0) {
		return
	}
	raw, err := json.Marshal(prefs)
	if err != nil {
		return
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, taskboardPreferencesFile+".tmp-*")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return
	}
	if err := os.Rename(tmpName, filepath.Join(dir, taskboardPreferencesFile)); err != nil {
		os.Remove(tmpName)
	}
}
