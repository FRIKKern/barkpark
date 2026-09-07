package cli

import (
	"encoding/json"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A `bp task get <id> -o json` envelope duplicates FIVE fields at both `doc.*`
// and `doc.content.*` — assignee, kind, lifecycle_status, parent_id, priority —
// and the two a triaging reader checks FIRST (lifecycle_status, priority) are
// among them. Both paths answer, so the reader learns "task fields live under
// content". That lesson is then WRONG for exactly the two fields whose
// misreading is dangerous, and JSON has no way to say so:
//
//	.doc.content.claim     absent -> null -> reads as UNCLAIMED    -> invites a claim steal
//	.doc.content.criteria  absent -> null -> reads as NO CRITERIA  -> invites a criteria-free close
//
// Measured 2026-09-06 by lead-studio-10 on a live row whose claim was HEALTHY
// at epoch 2 under an open PR: the null was read as a lapsed claim, and a
// re-claim (the standing remedy for exactly that reading) was one keystroke
// away. A missing key is not an error in any language these parsers are written
// in, so nothing warned.
//
// The fix has to be IN BAND. A stderr advisory does not reach `jq
// .doc.content.claim`; a new `--claim` projection helps only the reader who
// already knows they were wrong. So `bp task get` MATERIALISES the two wrong
// paths as sentinels whose value is not a claim and not a criteria list, and
// whose text names the true path. The wrong read now answers something a parser
// cannot mistake for "unclaimed" or "criteria-free":
//
//	$ bp task get <id> -o json | jq -r '.doc.content.claim._misread'
//	WRONG PATH: the claim lives at .doc.claim …
//
// Scope, deliberately narrow:
//   - keyed on the manifest id `task.get`, so no other verb's body changes;
//   - machine output only (-o json / -o yaml) — the sentinel exists for a path
//     walker, and the human table already collapses `doc` into one cell;
//   - written ONLY when the key is ABSENT. If the server ever ships a real
//     `content.claim`, that value wins and this is a no-op. The CLI never
//     overwrites a server field.
//
// This changes the CLI's rendered READ body only. No request payload, no server
// response, no write path.
const (
	taskMisreadKey = "_misread"

	taskContentClaimMisread = "WRONG PATH: the claim lives at .doc.claim, not .doc.content.claim. " +
		"This key exists only so the wrong read cannot answer null — null there reads as UNCLAIMED and invites a claim steal."

	taskContentCriteriaMisread = "WRONG PATH: the acceptance criteria live at .doc.content.acceptance_criteria, not .doc.content.criteria, " +
		"and each entry is keyed `criterion` (NOT `text`). This key exists only so the wrong read cannot answer null — " +
		"null there reads as A ROW WITH NO CRITERIA and invites a criteria-free close."
)

// taskContentClaimSentinel is the value planted at the wrong claim path. It
// carries the field names a claim reader walks INTO (epoch, worker, ts_iso) so
// that `.doc.content.claim.epoch` is loud too, and not another null: every one
// of them is a string that says WRONG PATH, so an epoch comparison or a worker
// equality test fails visibly instead of quietly.
func taskContentClaimSentinel() map[string]any {
	return map[string]any{
		taskMisreadKey: taskContentClaimMisread,
		"epoch":        "WRONG PATH: read .doc.claim.epoch",
		"worker":       "WRONG PATH: read .doc.claim.worker",
		"ts_iso":       "WRONG PATH: read .doc.claim.ts_iso",
	}
}

// taskContentCriteriaSentinel is the value planted at the wrong criteria path.
// An OBJECT, never a list: a reader that iterates it, indexes [0], or counts it
// as criteria gets a shape mismatch rather than a plausible empty list.
func taskContentCriteriaSentinel() map[string]any {
	return map[string]any{
		taskMisreadKey: taskContentCriteriaMisread,
	}
}

// taskGetMisreadPaths names, in one place, the wrong paths this file closes and
// the sentinel each one gets. The help block (usage.go) and the tests read it,
// so the documented paths and the planted ones cannot drift.
func taskGetMisreadPaths() map[string]func() map[string]any {
	return map[string]func() map[string]any{
		"claim":    taskContentClaimSentinel,
		"criteria": taskContentCriteriaSentinel,
	}
}

// annotateTaskGetMisreads returns respBody with the misread sentinels planted
// under `doc.content`, or respBody UNCHANGED when this is not a machine-output
// `task.get` 2xx, when the body is not the expected object shape, or when the
// server already answers at those keys. Pure: it never writes, never sends, and
// never fails the command — an unrecognised body is returned verbatim.
func annotateTaskGetMisreads(cmd manifest.Command, status int, machineOut bool, respBody []byte) []byte {
	if cmd.ID != taskGetCommandID || !machineOut {
		return respBody
	}
	if status < 200 || status >= 300 {
		return respBody
	}
	var env map[string]any
	if err := json.Unmarshal(respBody, &env); err != nil {
		return respBody
	}
	doc, ok := env["doc"].(map[string]any)
	if !ok {
		return respBody
	}
	content, ok := doc["content"].(map[string]any)
	if !ok {
		return respBody
	}
	planted := false
	for key, sentinel := range taskGetMisreadPaths() {
		if _, present := content[key]; present {
			continue
		}
		content[key] = sentinel()
		planted = true
	}
	if !planted {
		return respBody
	}
	annotated, err := json.Marshal(env)
	if err != nil {
		return respBody
	}
	return annotated
}

// taskGetEnvelopeHelpLines is the `bp task get --help` block that ends the
// hand-rolled path walk against an undocumented shape. Nothing else in the help
// mentions `-o json` at all, so every reader of this envelope was obliged to
// guess where the claim and the criteria live — and the shape taught the wrong
// guess. Asserted against the planted sentinels by
// TestTaskGetHelpNamesEveryMisreadPath, so help and behaviour cannot drift.
func taskGetEnvelopeHelpLines() []string {
	return []string{
		"machine-readable output: -o json (or -o yaml). The envelope is {\"ok\":…, \"doc\":{…}}.",
		"",
		"where things live in -o json:",
		"  the claim               .doc.claim  (.epoch, .worker, .ts_iso) — NOT .doc.content.claim",
		"  the acceptance criteria .doc.content.acceptance_criteria[]  entries keyed `criterion` (NOT `text`), plus `met` and `evidence`",
		"  the description         .doc.content.description",
		"  progress                .doc.criteria_progress  {met,total}",
		"  e.g. bp task get <doc_id> -o json | jq '.doc.claim, [.doc.content.acceptance_criteria[].criterion]'",
		"",
		"  Five fields (assignee, kind, lifecycle_status, parent_id, priority) answer at BOTH",
		"  .doc.X and .doc.content.X — the claim and the criteria do NOT. Reading",
		"  .doc.content.claim or .doc.content.criteria gets a `_misread` sentinel naming the",
		"  real path, never a null that would read as unclaimed / criteria-free.",
	}
}
