package cli

// webhook_create_required_args_lock_test.go — THE MANIFEST MUST BE ABLE TO
// SATISFY THE DOOR IT DRIVES.
//
// THE DEFECT THIS EXISTS FOR (S7 #32, Gyldendal). `bp` is MANIFEST-DRIVEN: the
// whole instance surface comes from GET /v1/capabilities, so a command's
// declared inputs ARE the only fields the CLI can ever put in the request body.
// `webhook.create` declared exactly one input, `url`. The server's changeset
// says `validate_required([:name, :url])`. So every `bp webhook create <url>`
// that ever ran sent `{"url": …}` and came back 422 "name: can't be blank" —
// not a call that failed, a verb that COULD NOT SUCCEED. Gyldendal created
// their subscription with raw REST instead.
//
// WHY THE LOCK IS SHAPED THIS WAY. The bug is not "a flag is missing"; it is
// that two files disagreed and nothing compared them. So this test reads BOTH
// PRODUCERS FROM SOURCE — the Ecto changeset's required list and the manifest
// command's declaration — and asserts the declaration can satisfy the list. It
// is structural, not empirical: no server, no fixture, no network. Copying the
// required list into a Go slice would just add a third hand-maintained copy of
// the same truth, which is the unlocked mirror the sites help lock was written
// to kill (internal/cli/sites_help_shipped_lock_test.go, #16632).
//
// WHY "DECLARED AS A REQUIRED ARG" AND NOT MERELY "MENTIONED". Two narrower
// facts about this repo make the weaker assertions vacuous:
//
//   - A FLAG WOULD NOT REACH THE BODY. buildBody only folds flags into the
//     JSON body when commandFlagBelongsInBody says so, and that function admits
//     batch writes and cycle.open — nothing else. A `--name` flag on
//     webhook.create would be parsed, then dropped on the floor, and the 422
//     would not move. So a required field must be a positional ARG.
//   - AN OPTIONAL ARG WOULD NOT HELP. Command.ArgLocation puts a non-path arg
//     of a write into "body", and buildBody writes it only when the caller
//     supplied a value. An optional `name` leaves the identical 422 one
//     forgotten argument away, which is the dead verb with extra steps.
//
// Hence: for each field the changeset REQUIRES, the manifest must declare an
// arg with that exact name, required:true, that is not consumed by the path
// template.
//
// THE NON-VACUITY GUARD. A lock that reads nothing passes everything, so every
// read is floored — an unreadable file, a missing `validate_required`, a
// webhook.create block that parses to zero args, or a path template that never
// appears are all hard failures, never skips. And
// TestWebhookCreateLockExtractorsAreNotBlind feeds both extractors the exact
// PRE-FIX text and asserts they recover the disagreement — if the regexes stop
// seeing their producers, the lock says so instead of going quietly green.
//
// Cited by SYMBOL, never by line: `grep -n 'validate_required' ` on the schema
// and `grep -n '"webhook.create"' ` on the manifest find every anchor this file
// depends on, and cannot rot.

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The two producers, both in this repository — read as real files, never as
// fixture copies of themselves.
const (
	webhookSchemaRelPath       = "api/lib/barkpark/webhooks/webhook.ex"
	webhookCapabilitiesRelPath = "api/lib/barkpark/plugins/capabilities.ex"
	// The manifest command under lock.
	webhookCreateCmdID = "webhook.create"
)

var (
	// `validate_required([:a, :b])`, possibly spread over several lines.
	reValidateRequired = regexp.MustCompile(`validate_required\(\[([^\]]*)\]\)`)
	reElixirAtom       = regexp.MustCompile(`:([a-z_][a-zA-Z0-9_]*)`)

	// `arg("name", true, "string", "…")` — name and the required flag.
	reManifestArg = regexp.MustCompile(`arg\(\s*"([a-z_][a-z0-9_]*)"\s*,\s*(true|false)\s*,`)
	// `flag("name", "string", "…")`.
	reManifestFlag = regexp.MustCompile(`flag\(\s*"([a-z_][a-z0-9_-]*)"\s*,`)
	// The route this command posts to, e.g. "/v1/webhooks/:dataset".
	reManifestPath = regexp.MustCompile(`"(/v1/[^"]*)"`)
	// A `:placeholder` segment inside a path template.
	rePathPlaceholder = regexp.MustCompile(`:([a-z_][a-z0-9_]*)`)
)

func repoRootForWebhookLock(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for dir := wd; ; {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no go.mod above %s", wd)
		}
		dir = parent
	}
}

func readProducerForWebhookLock(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		// A lock that cannot read a producer must FAIL, never skip: a skip is
		// indistinguishable from a pass in a CI summary.
		t.Fatalf("read %s: %v", path, err)
	}
	if len(b) == 0 {
		t.Fatalf("%s is empty — the lock has nothing to read", path)
	}
	return string(b)
}

// changesetRequiredFields returns the field names of the webhook changeset's
// single `validate_required([...])`. Zero fields, or more than one call, is a
// hard failure: the extractor has gone blind or the schema grew a shape this
// lock does not model.
func changesetRequiredFields(t *testing.T, src string) []string {
	t.Helper()
	matches := reValidateRequired.FindAllStringSubmatch(src, -1)
	if len(matches) != 1 {
		t.Fatalf("found %d validate_required(...) calls in %s, want exactly 1 — the extractor has gone blind or the changeset changed shape",
			len(matches), webhookSchemaRelPath)
	}
	var fields []string
	for _, m := range reElixirAtom.FindAllStringSubmatch(matches[0][1], -1) {
		fields = append(fields, m[1])
	}
	if len(fields) == 0 {
		t.Fatalf("validate_required in %s parsed to ZERO fields — refusing to lock a manifest against an empty required set", webhookSchemaRelPath)
	}
	sort.Strings(fields)
	return fields
}

// manifestCommandBlock slices the `core_cmd("<id>", …)` declaration out of the
// capabilities module: from the quoted id to the start of the next core_cmd.
func manifestCommandBlock(t *testing.T, src, id string) string {
	t.Helper()
	start := strings.Index(src, `"`+id+`"`)
	if start < 0 {
		t.Fatalf("%q not found in %s — the command was renamed or removed", id, webhookCapabilitiesRelPath)
	}
	rest := src[start:]
	if next := strings.Index(rest, "core_cmd("); next > 0 {
		rest = rest[:next]
	}
	if strings.TrimSpace(rest) == "" {
		t.Fatalf("%q declaration sliced to an EMPTY block — the block extractor has gone blind", id)
	}
	return rest
}

// manifestDeclaredArgs returns arg name -> required, for one command block.
func manifestDeclaredArgs(block string) map[string]bool {
	args := map[string]bool{}
	for _, m := range reManifestArg.FindAllStringSubmatch(block, -1) {
		args[m[1]] = m[2] == "true"
	}
	return args
}

// manifestDeclaredFlags returns the flag names declared on one command block.
func manifestDeclaredFlags(block string) map[string]bool {
	flags := map[string]bool{}
	for _, m := range reManifestFlag.FindAllStringSubmatch(block, -1) {
		flags[m[1]] = true
	}
	return flags
}

// manifestPathPlaceholders returns the `:segment` names of the command's route
// — the inputs the URL consumes, which therefore never reach the JSON body.
func manifestPathPlaceholders(t *testing.T, block, id string) map[string]bool {
	t.Helper()
	m := reManifestPath.FindStringSubmatch(block)
	if m == nil {
		t.Fatalf("no /v1 path template found in the %q block — the extractor has gone blind", id)
	}
	out := map[string]bool{}
	for _, p := range rePathPlaceholder.FindAllStringSubmatch(m[1], -1) {
		out[p[1]] = true
	}
	return out
}

// TestWebhookCreateManifestCanSatisfyTheServersRequiredSet is the lock. It reds
// whenever either side moves: drop `name` from the manifest declaration and it
// names the field the CLI could never send; add a field to the changeset's
// required list without declaring it and it names that one instead.
func TestWebhookCreateManifestCanSatisfyTheServersRequiredSet(t *testing.T) {
	root := repoRootForWebhookLock(t)
	schema := readProducerForWebhookLock(t, filepath.Join(root, filepath.FromSlash(webhookSchemaRelPath)))
	caps := readProducerForWebhookLock(t, filepath.Join(root, filepath.FromSlash(webhookCapabilitiesRelPath)))

	required := changesetRequiredFields(t, schema)
	block := manifestCommandBlock(t, caps, webhookCreateCmdID)
	args := manifestDeclaredArgs(block)
	flags := manifestDeclaredFlags(block)
	pathParams := manifestPathPlaceholders(t, block, webhookCreateCmdID)

	if len(args) == 0 {
		t.Fatalf("%q declares ZERO args — refusing to pass a lock against an empty declaration", webhookCreateCmdID)
	}

	for _, field := range required {
		// A field the ROUTE supplies is not a body field and needs no arg.
		if pathParams[field] {
			continue
		}
		declaredRequired, isArg := args[field]
		switch {
		case !isArg && flags[field]:
			// buildBody folds flags into the JSON body only for batch writes and
			// cycle.open (commandFlagBelongsInBody). A flag here is parsed and
			// then dropped, so the 422 does not move.
			t.Errorf("%s requires %q, but %s declares it as a FLAG. Flags do not reach the request body for this command "+
				"(commandFlagBelongsInBody admits batch writes and cycle.open only), so the value would be parsed and discarded "+
				"and the server would still answer 422 %q: can't be blank. Declare it as a required arg.",
				webhookSchemaRelPath, field, webhookCreateCmdID, field)
		case !isArg:
			t.Errorf("%s requires %q, but %s declares no input for it. bp is manifest-driven, so there is no spelling of "+
				"`bp webhook create` that puts %q in the body: EVERY invocation 422s %q: can't be blank. The verb is dead. "+
				"Declare arg(%q, true, \"string\", …) in the %s block of %s.",
				webhookSchemaRelPath, field, webhookCreateCmdID, field, field, field, webhookCreateCmdID, webhookCapabilitiesRelPath)
		case !declaredRequired:
			t.Errorf("%s requires %q, but %s declares it as an OPTIONAL arg. buildBody writes a body arg only when the caller "+
				"supplied a value, so omitting it reproduces the same 422 %q: can't be blank. Mark it required:true.",
				webhookSchemaRelPath, field, webhookCreateCmdID, field)
		}
	}
}

// TestWebhookCreateLockExtractorsAreNotBlind feeds both extractors the exact
// PRE-FIX source shapes and asserts they recover the disagreement the lock is
// built to catch. Without this, a regex that stopped matching would turn the
// lock green on a broken manifest.
func TestWebhookCreateLockExtractorsAreNotBlind(t *testing.T) {
	const preFixSchema = `
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :url, :dataset])
    |> validate_required([:name, :url])
    |> validate_change(:url, &validate_outbound_url/2)
  end
`
	got := changesetRequiredFields(t, preFixSchema)
	if strings.Join(got, ",") != "name,url" {
		t.Fatalf("required fields = %v, want [name url] — the changeset extractor has gone blind", got)
	}

	const preFixCaps = `
      core_cmd(
        "webhook.create",
        "webhook",
        "create",
        "Create a webhook subscription.",
        "POST",
        "/v1/webhooks/:dataset",
        "admin",
        args: [arg("url", true, "string", "Delivery URL.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "webhook.get",
        "webhook",
        "get",
        "Fetch a webhook subscription by id.",
        "GET",
        "/v1/webhooks/:dataset/:id",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: false,
        default_output: "table"
      ),
`
	block := manifestCommandBlock(t, preFixCaps, webhookCreateCmdID)
	if strings.Contains(block, "webhook.get") {
		t.Fatalf("block extractor ran past the next core_cmd — it captured webhook.get too")
	}
	args := manifestDeclaredArgs(block)
	if len(args) != 1 || !args["url"] {
		t.Fatalf("pre-fix args = %v, want exactly {url:true} — the arg extractor has gone blind", args)
	}
	if args["name"] {
		t.Fatalf("pre-fix args must NOT contain name — the fixture is not the pre-fix text")
	}
	pathParams := manifestPathPlaceholders(t, block, webhookCreateCmdID)
	if !pathParams["dataset"] {
		t.Fatalf("path placeholders = %v, want dataset — the path extractor has gone blind", pathParams)
	}
	if pathParams["name"] {
		t.Fatalf("path placeholders must not contain name — the route does not supply it")
	}
}
