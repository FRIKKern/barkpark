package cli

// tasks_create_cmd.go — `bp task create`: file a NEW task document. A CLI
// built-in intercepted before manifest dispatch (the manifest `task` noun
// carries no `create` verb — the Tasks plugin declares only the eight
// lifecycle/read verbs, ls/ready/prime/get/claim/close/next/move). Task
// creation otherwise rides the GENERIC document mutate path (`bp doc create
// task`), which does NOT know the task schema's two required fields — so a bare
// `bp doc create task --set title=…` 422s with
// `kind: is required · lifecycle_status: is required`. This verb is the
// ergonomic, contract-correct front door: it injects the required defaults
// `kind:"task"` + `lifecycle_status:"open"` (both overridable via --set),
// requires a non-empty title (well-formedness — the server's authoring gate
// hard-stops title-only-empty anyway), and sends the SAME create mutation the
// server's `/v1/data/mutate/<dataset>` contract accepts.
//
// No server change and no manifest change: it composes the one mutate endpoint
// the doc path already uses, so the two never drift on the task contract.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runTaskCreate handles `bp task create [<title>] [--title <t>]
// [--description <d>] [--set k=v]… [--publish]`. It returns the process exit
// code. Honors the global --dry-run (print the request, do not send), --yes
// (skip the prod write-guard), and -o json/yaml (structured receipt).
func runTaskCreate(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskCreateHelp(out)
		return exitOK
	}

	body, publish, err := parseTaskCreateArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printTaskCreateHelp(out) }, "%v", err)
	}

	// Well-formedness: a task with no title is the one thing the server's
	// authoring quality gate hard-stops, and an empty-title task is unusable in
	// every board/queue view. Reject it here with a friendly message rather than
	// round-tripping to a 409/422.
	if title, _ := body["title"].(string); strings.TrimSpace(title) == "" {
		return usageErrf(out, func() { printTaskCreateHelp(out) },
			"a task needs a non-empty title (pass it positionally, via --title, or --set title=…)")
	}

	// The create mutation the server's mutate contract accepts. `_type` names the
	// schema; the required task fields + title/description/any --set overrides ride
	// flat at top level (the task write contract: fields are top-level, never
	// nested under content.*).
	createOp := map[string]any{"_type": "task"}
	for k, v := range body {
		createOp[k] = v
	}
	mutations := []map[string]any{{"create": createOp}}

	if g.dryRun {
		return taskCreateDryRun(out, ctx, mutations, publish)
	}

	// Prod write-guard parity with the manifest write path: a write against a
	// prod-looking target needs confirmation unless --yes.
	if isProdServer(ctx.Server) && !g.yes {
		out.userErr("prod write to %s needs confirmation — re-run with --yes", ctx.Server)
		return exitGeneric
	}

	httpStatus, respBody, err := sendTaskMutations(ctx, mutations)
	if err != nil {
		out.userErr("task create: %v", err)
		return exitGeneric
	}
	if httpStatus < 200 || httpStatus >= 300 {
		out.userErr("task create: %s", mutateErrorMessage(httpStatus, respBody))
		return exitGeneric
	}
	draftID, ok := firstMutationID(respBody)
	if !ok || draftID == "" {
		out.userErr("task create: server returned no id")
		return exitGeneric
	}

	// The server hands back a "drafts.<type>-<n>" id; the BARE published id (used
	// by publish/get) is that with the "drafts." prefix stripped.
	bareID := strings.TrimPrefix(draftID, "drafts.")
	status := "draft"

	if publish {
		// Publish is a second mutation over the same scoped-mutate endpoint; the
		// server's Content.publish_document derives the drafts. twin from the bare
		// id. A publish failure leaves the draft in place, so surface the id for a
		// retry rather than losing the created task.
		pubOp := map[string]any{"publish": map[string]any{"id": bareID, "type": "task"}}
		pStatus, pBody, pErr := sendTaskMutations(ctx, []map[string]any{pubOp})
		if pErr != nil {
			out.userErr("task create: created %s but publish failed: %v", bareID, pErr)
			return exitGeneric
		}
		if pStatus < 200 || pStatus >= 300 {
			out.userErr("task create: created %s but publish failed: %s", bareID, mutateErrorMessage(pStatus, pBody))
			return exitGeneric
		}
		status = "published"
	}

	if out.machineOut() {
		out.renderJSON(map[string]any{
			"id":     bareID,
			"draft":  draftID,
			"status": status,
		})
		return exitOK
	}
	out.outf("created task %s (%s)", bareID, status)
	return exitOK
}

// sendTaskMutations POSTs a mutate batch to /v1/data/mutate/<dataset> and
// returns the raw HTTP status + response body, never rendering. It is the
// headless send primitive for the task-create path: runTaskCreate calls it to
// file the {create:{_type:task}} mutation (and then the follow-up publish), and
// the MCP task_create tool calls it to file a task headlessly and hand the raw
// response body back to the client verbatim. It rides the same scoped mutate
// endpoint + bearer auth apiclient.MutateResults uses, over the CLI's shared
// 30s doRequest transport (the same budget every manifest write gets), so the
// two never drift on the task write contract. Writes nothing to stdout.
func sendTaskMutations(ctx manifest.Context, mutations []map[string]any) (int, []byte, error) {
	endpoint := apiclient.ScopedURL(ctx.Server, ctx.Workspace, ctx.Project, "/v1/data/mutate/"+ctx.Dataset)
	body, err := json.Marshal(map[string]any{"mutations": mutations})
	if err != nil {
		return 0, nil, err
	}
	headers := map[string]string{"Content-Type": "application/json"}
	if ctx.Token != "" {
		headers["Authorization"] = "Bearer " + ctx.Token
	}
	return doRequest("POST", endpoint, headers, body)
}

// firstMutationID pulls the first result id out of a raw mutate response
// ({"results":[{"id":"drafts.task-N",…}]}). The create mutation carries no _id,
// so the server generates one and returns it here — that id is how the caller
// publishes/selects the new task. A body that fails to decode (or carries no
// result) returns "",false.
func firstMutationID(body []byte) (string, bool) {
	var out struct {
		Results []struct {
			ID string `json:"id"`
		} `json:"results"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", false
	}
	if len(out.Results) == 0 {
		return "", false
	}
	return out.Results[0].ID, out.Results[0].ID != ""
}

// mutateErrorMessage turns a non-2xx mutate response into a one-line human
// message, mirroring apiclient.humanAPIError so the raw-bytes task-create path
// keeps the same "validation_failed — kind: is required · …" feedback the
// apiclient path produced. Unknown shapes fall back to the clamped body verbatim
// so nothing is ever swallowed.
func mutateErrorMessage(status int, body []byte) string {
	var env struct {
		Error struct {
			Code    string              `json:"code"`
			Message string              `json:"message"`
			Details map[string][]string `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &env) == nil && (env.Error.Code != "" || env.Error.Message != "") {
		msg := env.Error.Message
		if msg == "" {
			msg = env.Error.Code
		}
		var parts []string
		for field, reasons := range env.Error.Details {
			parts = append(parts, field+": "+strings.Join(reasons, "; "))
		}
		sort.Strings(parts) // deterministic over the map
		if len(parts) > 0 {
			msg += " — " + strings.Join(parts, " · ")
		}
		return msg
	}
	raw := strings.TrimSpace(string(body))
	if r := []rune(raw); len(r) > 200 {
		raw = string(r[:200]) + "…"
	}
	return fmt.Sprintf("error %d: %s", status, raw)
}

// parseTaskCreateArgs folds the positional title + flags into the create body
// (kind/lifecycle_status defaulted, title/description convenience flags, and
// --set overrides in the doc-create key=value / key:=json convention) and
// returns whether --publish was requested.
func parseTaskCreateArgs(tail []string) (map[string]any, bool, error) {
	// Defaults the task schema requires; --set (or --title/--description) wins.
	body := map[string]any{
		"kind":             "task",
		"lifecycle_status": "open",
	}
	publish := false

	takeValue := func(i int, flag, inline string, hasInline bool) (string, int, error) {
		if hasInline {
			return inline, i, nil
		}
		if i+1 >= len(tail) {
			return "", i, fmt.Errorf("flag %s needs a value", flag)
		}
		return tail[i+1], i + 1, nil
	}

	for i := 0; i < len(tail); i++ {
		a := tail[i]
		key, inline, hasInline := a, "", false
		if eq := strings.IndexByte(a, '='); eq >= 0 && strings.HasPrefix(a, "--") {
			key, inline, hasInline = a[:eq], a[eq+1:], true
		}

		switch {
		case a == "--publish":
			publish = true
		case key == "--title":
			v, ni, err := takeValue(i, "--title", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			body["title"] = v
			i = ni
		case key == "--description":
			v, ni, err := takeValue(i, "--description", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			body["description"] = v
			i = ni
		case key == "--set":
			v, ni, err := takeValue(i, "--set", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			if err := applyTaskSet(body, v); err != nil {
				return nil, false, err
			}
			i = ni
		case !strings.HasPrefix(a, "-"):
			// A bare positional is the title (first one wins; a second is an error
			// so a typo'd flag is not silently swallowed as the title).
			if _, ok := body["title"]; ok {
				if t, _ := body["title"].(string); t != "" {
					return nil, false, fmt.Errorf("unexpected extra argument %q (title already set)", a)
				}
			}
			body["title"] = a
		default:
			return nil, false, fmt.Errorf("unknown flag %q (task create accepts --title, --description, --set k=v, --publish)", a)
		}
	}
	return body, publish, nil
}

// applyTaskSet merges one --set token into body, using the doc-create typing
// convention: `key:=json` sends a TYPED value (e.g. --set priority:=3 → number,
// --set 'labels:=["x"]' → array), plain `key=value` stays a string. Task
// validators reject a string where they want a number, so the typed form is the
// caller's explicit escape hatch — type is never sniffed from the value.
func applyTaskSet(body map[string]any, kv string) error {
	if eq := strings.Index(kv, ":="); eq >= 0 && !strings.Contains(kv[:eq], "=") {
		var typed any
		if err := json.Unmarshal([]byte(kv[eq+2:]), &typed); err != nil {
			return fmt.Errorf("invalid --set %q: %q is not valid JSON (key:=value sends raw JSON; use key=value for strings)", kv, kv[eq+2:])
		}
		body[kv[:eq]] = typed
		return nil
	}
	eq := strings.IndexByte(kv, '=')
	if eq < 0 {
		return fmt.Errorf("invalid --set %q (want key=value, or key:=json for typed values)", kv)
	}
	body[kv[:eq]] = kv[eq+1:]
	return nil
}

// taskCreateDryRun prints the resolved mutate request without sending, matching
// the manifest write path's --dry-run degradation notice.
func taskCreateDryRun(out *writer, ctx manifest.Context, mutations []map[string]any, publish bool) int {
	out.errf("dry-run: client-side preview only (server validate-only not available)")
	out.errf("POST %s/v1/data/mutate/%s", ctx.Server, ctx.Dataset)
	out.errf("Authorization: Bearer ****")
	out.errf("Content-Type: application/json")
	out.errf("")
	raw, _ := json.Marshal(map[string]any{"mutations": mutations})
	out.outf("%s", string(raw))
	if publish {
		out.errf("(then publish the created draft to collapse it to published)")
	}
	return exitOK
}

// isProdServer mirrors run.go's isProd URL heuristic for the builtin write path
// (which has no manifest to read m.Server.Name from): a prod-looking host needs
// --yes. localhost is never prod.
func isProdServer(server string) bool {
	s := strings.ToLower(server)
	if strings.Contains(s, "localhost") || strings.Contains(s, "127.0.0.1") || strings.Contains(s, "0.0.0.0") {
		return false
	}
	return strings.Contains(s, "api.barkpark.cloud") || strings.Contains(s, "prod")
}

func printTaskCreateHelp(out *writer) {
	out.outf(`usage: bp task create [<title>] [flags]
  File a new task. Injects the task schema's required kind="task" and
  lifecycle_status="open" defaults, so you only supply the title (and any
  optional fields). By default the task is created as a draft; --publish
  collapses it to published in the same call.

arguments:
  title            The task title (or pass --title / --set title=…).

flags:
  --title <t>      Task title.
  --description <d> Task description.
  --set <k=v>      Extra field (repeatable; k:=json for typed values, e.g.
                   --set priority:=3, --set 'labels:=["infra"]',
                   --set parent_id=my-goal). Overrides the injected defaults.
  --publish        Publish the new task immediately (draft → published).

write globals: --dry-run (print the request, don't send) · --yes (skip the
prod confirmation) · -o json (structured receipt)`)
}
