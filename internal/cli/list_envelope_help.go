package cli

import (
	"encoding/json"
	"fmt"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE DEFECT THIS FILE CLOSES (task-57081836b628df35, instance 6).
//
// Three verbs of the SAME CLI return their rows under three different envelope
// keys — `bp task ready` under "docs", `bp doc ls` under "documents", `bp task
// get` under "doc" — and no `--help` named any of them. The one place a key was
// written down is a MODULEDOC in the API (plugins/tasks.ex) that no --help
// renders, so every reader of `-o json` had to guess. The fleet already paid
// for that guess: a parser keyed on "tasks"/"id" read ZERO rows out of a 310 KB
// response and printed a confident EMPTY QUEUE. A wrong key and an empty queue
// are the same two characters of output, and nothing downstream can tell them
// apart.
//
// So the key is documented WHERE THE CALLER STANDS — in the verb's own --help,
// beside the pagination line — and it is CHECKED AT READ TIME. A documented key
// nobody verifies is the same class of promise as the refusals this row is
// about: true when written, unfalsifiable afterwards. listEnvelopeDrift reads
// the real response and says so when the help is wrong.
//
// SERVER-OWNED HALF, stated plainly: the command SUMMARY ("List tasks in the
// queue.") and the flag summaries come from GET /v1/capabilities
// (api/lib/barkpark/plugins/tasks.ex) and cannot be edited from here. The help
// RENDER — usageCommand in usage.go — is the CLI's, and that is the half this
// file writes into.

// listEnvelopeShape names, for one manifest command, the key its rows arrive under
// under `-o json` and the field on each row that carries the row's id.
//
// IDField is "" when the row's id field is not VERIFIED. An unverified claim is
// worse than a missing one here — the whole defect is a caller following a
// documented path that does not exist — so those commands document the key
// alone, and listEnvelopeDrift checks only the key for them.
type listEnvelopeShape struct {
	Key     string
	IDField string
}

// commandListEnvelopes is the registry. It is the SAME population the
// paginated-envelope guard re-derives from the API source
// (TestPaginatedCommandsUseKnownEnvelopeKeys, paginate_all_test.go): a new
// `paginated: true` command reds that test until it is recorded here, so the
// help cannot silently fall behind the server.
//
// Key provenance is the controller that builds the envelope; the id fields
// recorded below are the ones that were actually READ BACK off a live response
// or off the row builder, not inferred from the key's name:
//
//	task.ls / task.ready → tasks_controller.ex, the `docs:` key ·
//	                       rows built by tasks_controller/params.ex, the `doc_id:` field
//	doc.ls / doc.query / search.query → `documents:` · rows are stored documents,
//	                       keyed `_id` (Envelope.render)
//	token.ls             → member_controller.ex, the `tokens:` key · rows matched on
//	                       "id" by the destroy preview (destroy_confirm.go)
//	workspace.member-ls  → member_controller.ex, the `members:` key — the seat rows
//	                       carry several ref fields (identity/email/principal_id/
//	                       id), so no single id field is claimed
var commandListEnvelopes = map[string]listEnvelopeShape{
	"task.ls":                 {Key: "docs", IDField: "doc_id"},
	"task.ready":              {Key: "docs", IDField: "doc_id"},
	"doc.ls":                  {Key: "documents", IDField: "_id"},
	"doc.query":               {Key: "documents", IDField: "_id"},
	"search.query":            {Key: "documents", IDField: "_id"},
	"media.ls":                {Key: "assets"},
	"media.search":            {Key: "hits"},
	"media.collections":       {Key: "collections"},
	"media.collection-assets": {Key: "hits"},
	"ticket.inbox":            {Key: "tickets"},
	"token.ls":                {Key: "tokens", IDField: "id"},
	"workspace.member-ls":     {Key: "members"},
}

// listEnvelopeHelpLines is the block usageCommand renders. Empty for a command
// with no recorded envelope — help never invents a key.
func listEnvelopeHelpLines(cmd manifest.Command) []string {
	env, ok := commandListEnvelopes[cmd.ID]
	if !ok {
		return nil
	}
	// The example has to be RUNNABLE — the whole defect is a documented next
	// step the caller cannot take — so it carries the command's required
	// positional args (`bp doc ls <type>`), not just the noun and verb.
	invocation := "bp " + cmd.Noun + " " + cmd.Verb
	for _, a := range cmd.Args {
		if a.Required {
			invocation += " <" + a.Name + ">"
		}
	}
	lines := []string{
		"",
		"machine-readable output: -o json (or -o yaml)",
		fmt.Sprintf("  rows arrive under   .%s[]   — NOT at the top level, and NOT under a key named after the noun", env.Key),
	}
	if env.IDField != "" {
		lines = append(lines,
			fmt.Sprintf("  each row's id       .%s[].%s", env.Key, env.IDField),
			fmt.Sprintf("  e.g. %s -o json | jq -r '.%s[].%s'", invocation, env.Key, env.IDField))
	} else {
		lines = append(lines,
			fmt.Sprintf("  e.g. %s -o json | jq '.%s[0]'   (the row's id field is not fixed by this CLI — read one row)",
				invocation, env.Key))
	}
	lines = append(lines,
		"  A parser keyed on the wrong key reads ZERO rows and cannot tell that from an empty result.")
	return lines
}

// listEnvelopeDrift compares what the help PROMISED against what the server
// actually sent, and returns the advisory to print — "" when the help is right,
// when this is not a recorded command, when the read did not succeed, or when
// the body is not the shape this check reads. It never fails the command and
// never touches the body: an advisory on stderr, exactly like the pager notes.
//
// Two divergences, and they are different faults:
//
//   - the documented key is ABSENT while another known list key holds the rows
//     — the help sends a parser to a path that answers nothing;
//   - the documented key is present but its first row has no such id field —
//     the help names a field the caller's jq will resolve to null.
func listEnvelopeDrift(cmd manifest.Command, status int, respBody []byte) string {
	env, ok := commandListEnvelopes[cmd.ID]
	if !ok || status < 200 || status >= 300 {
		return ""
	}
	var body map[string]any
	if err := json.Unmarshal(respBody, &body); err != nil {
		return ""
	}
	rows, present := body[env.Key].([]any)
	if !present {
		// Only a body that carries rows SOMEWHERE is drift. A body with no list
		// at all is a different fault with its own name (unreadable_list_page).
		for _, k := range listEnvelopeKeys {
			if k == env.Key {
				continue
			}
			if other, ok := body[k].([]any); ok && len(other) > 0 {
				return fmt.Sprintf(
					"envelope drift: `bp %s %s --help` documents rows under .%s, but this response carried them under .%s (%d rows). "+
						"Read .%s and report the drift — the help is wrong, not your parser.",
					cmd.Noun, cmd.Verb, env.Key, k, len(other), k)
			}
		}
		return ""
	}
	if env.IDField == "" || len(rows) == 0 {
		return ""
	}
	first, isObj := rows[0].(map[string]any)
	if !isObj {
		return ""
	}
	if _, has := first[env.IDField]; !has {
		return fmt.Sprintf(
			"envelope drift: `bp %s %s --help` documents each row's id at .%s[].%s, but the rows in this response carry no such field. "+
				"A jq keyed on it resolves to null on every row.",
			cmd.Noun, cmd.Verb, env.Key, env.IDField)
	}
	return ""
}
