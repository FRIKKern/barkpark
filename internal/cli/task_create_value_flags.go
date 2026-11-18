package cli

import "fmt"

// taskCreateValueFlags are the `bp task create` flags that take the next
// argument as their value. ONE list, read by both passes over the arguments:
// parseTaskCreateArgs dispatches on it, and the prose scan
// (resolveTaskCreateProse) reads it to find where the flags end. Before, the
// scan knew only --title and --description, so after `--set --` it read "--"
// as the end of the flags while the parser took it as --set's value
// (task-4b3183fca9ea2708). A flag missing here is an unknown flag to the
// parser, never a flag that silently gets an empty value.
var taskCreateValueFlags = map[string]bool{
	"--title":             true,
	"--description":       true,
	"--execution-policy":  true,
	"--disposition":       true,
	"--reopen-trigger":    true,
	"--disposition-rerun": true,
	"--set":               true,
}

// resolveTaskCreateProse is task create's prose-file pass: every prose field,
// with the flags' end found the way parseTaskCreateArgs finds it.
func resolveTaskCreateProse(tail []string, warn func(string, ...any)) ([]string, error) {
	return resolveProseTextFilesFor(tail, nil, taskCreateValueFlags, warn)
}

// applyTaskCreateValue writes one value flag's value into the create body.
func applyTaskCreateValue(body map[string]any, key, v string) error {
	switch key {
	case "--title":
		body["title"] = v
	case "--description":
		body["description"] = v
	case "--execution-policy":
		policy, err := parseTaskExecutionPolicyJSON([]byte(v))
		if err != nil {
			return fmt.Errorf("--execution-policy: %w", err)
		}
		body["execution_policy"] = policy
	case "--disposition", "--reopen-trigger", "--disposition-rerun":
		// The adjudication triple as FIRST-CLASS flags. The three content
		// keys are read from the shared vocabulary fixture, never spelled
		// here — see tasks_adjudication.go. An unreadable fixture refuses
		// the flag rather than writing a key it cannot name.
		vocab, err := loadTaskAdjudicationVocabulary()
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
		switch key {
		case "--disposition":
			body[vocab.DispositionKey] = v
		case "--reopen-trigger":
			body[vocab.ReopenTriggerKey] = v
		default:
			body[vocab.DispositionRerunKey] = v
		}
	case "--set":
		return applyTaskSet(body, v)
	default:
		return fmt.Errorf("%s is listed as a task create value flag but nothing reads it", key)
	}
	return nil
}
