package cli

// tasks_adjudication.go — the ADJUDICATION TRIPLE on a task write:
// `disposition` (open|parked|closed), `reopen_trigger` (the durable
// when-reconsidered a parked row owes) and `disposition_rerun` (one command an
// auditor can run to try to prove the reason wrong).
//
// All three keys have persisted since PDS wave 24 and are fenced at birth by
// the api's `Content.Writer.ensure_task_born_adjudicated/5`; PR #17843
// (f8d1f0f5c) DECLARED them in the task schema, sourcing both the field names
// and the `options` list from `Barkpark.Tasks.Stage` rather than restating
// them. Until now `bp task create` had no flags for any of the three, so a
// filer spelled them `--set disposition=…` — a raw key/value write that sails
// past the vocabulary and only learns it was wrong from a 422 (or, worse, from
// a row born `parked` with no trigger).
//
// THE VOCABULARY IS NOT RETYPED IN GO. It is decoded from
// `task_adjudication_vocabulary.json`, the Go-readable copy of Stage's own
// lists, and `tasks_adjudication_drift_test.go` parses `stage.ex` and compares
// the two in BOTH directions — so editing the Elixir alone, or this JSON alone,
// reds. A blind or malformed fixture FAILS CLOSED: the CLI refuses rather than
// validating against a vocabulary it cannot state.

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"
)

//go:embed task_adjudication_vocabulary.json
var taskAdjudicationVocabularyJSON []byte

// taskAdjudicationVocabulary is the decoded fixture: the three content KEYS the
// birth fence writes, the disposition terms it accepts, and the subset of terms
// that owe a reopen trigger.
type taskAdjudicationVocabulary struct {
	Source              string   `json:"_source"`
	DispositionKey      string   `json:"disposition_key"`
	ReopenTriggerKey    string   `json:"reopen_trigger_key"`
	DispositionRerunKey string   `json:"disposition_rerun_key"`
	Dispositions        []string `json:"dispositions"`
	TriggerRequired     []string `json:"trigger_required_dispositions"`
}

// loadTaskAdjudicationVocabulary decodes the fixture strictly. An unknown field
// is an error, not a silent drop: a typo'd key would otherwise leave a list
// empty and turn the screen below into a no-op that accepts everything.
func loadTaskAdjudicationVocabulary() (taskAdjudicationVocabulary, error) {
	var v taskAdjudicationVocabulary
	dec := json.NewDecoder(bytes.NewReader(taskAdjudicationVocabularyJSON))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&v); err != nil {
		return v, fmt.Errorf("task adjudication vocabulary is unreadable: %w", err)
	}
	if v.DispositionKey == "" || v.ReopenTriggerKey == "" || v.DispositionRerunKey == "" {
		return v, fmt.Errorf("task adjudication vocabulary names no content keys")
	}
	if len(v.Dispositions) == 0 {
		return v, fmt.Errorf("task adjudication vocabulary lists no dispositions")
	}
	for _, term := range v.TriggerRequired {
		if !containsString(v.Dispositions, term) {
			return v, fmt.Errorf("trigger-required term %q is not a declared disposition", term)
		}
	}
	return v, nil
}

func containsString(list []string, want string) bool {
	for _, got := range list {
		if got == want {
			return true
		}
	}
	return false
}

// screenTaskAdjudication validates whatever adjudication the body carries —
// whether it arrived via --disposition/--reopen-trigger/--disposition-rerun or
// via the older --set disposition=… spelling, which is exactly the door this
// screen closes. A body with no disposition is untouched: filing a plain open
// task must stay a one-liner.
func screenTaskAdjudication(body map[string]any) error {
	v, err := loadTaskAdjudicationVocabulary()
	if err != nil {
		// FAIL CLOSED, but only for a write that actually claims an
		// adjudication: a bp with a broken fixture must not refuse ordinary
		// task creation, and must not wave an unscreened disposition through.
		if _, claims := body["disposition"]; claims {
			return err
		}
		return nil
	}

	raw, present := body[v.DispositionKey]
	if !present {
		return nil
	}
	term, ok := raw.(string)
	if !ok {
		return fmt.Errorf("%s must be a string, one of: %s", v.DispositionKey, strings.Join(v.Dispositions, ", "))
	}
	if strings.TrimSpace(term) == "" {
		return fmt.Errorf("%s cannot be blank — pass one of: %s", v.DispositionKey, strings.Join(v.Dispositions, ", "))
	}
	if !containsString(v.Dispositions, term) {
		return fmt.Errorf(
			"%q is not a %s the task schema declares — allowed: %s (the api screens the same list, "+
				"Barkpark.Tasks.Stage; terms are lowercase-canonical)",
			term, v.DispositionKey, strings.Join(v.Dispositions, ", "))
	}

	trigger, _ := body[v.ReopenTriggerKey].(string)
	if containsString(v.TriggerRequired, term) && strings.TrimSpace(trigger) == "" {
		return fmt.Errorf(
			"a %s=%s row must say what would reopen it — pass --reopen-trigger <when-reconsidered> "+
				"(the api refuses a hollow park with 422)",
			v.DispositionKey, term)
	}
	return nil
}
