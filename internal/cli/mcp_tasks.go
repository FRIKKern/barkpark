package cli

// mcp_tasks.go — the curated five Barkpark task tools, hand-mapped onto the
// manifest task verbs and exposed over MCP. Each tool's description carries the
// barkpark-tasks.mdc doctrine (claim-first, epoch-CAS, lifecycle_status is the
// done-signal, criteria-in-close, 409 doc_changed_since_claim, re-claim on
// lapse) so an MCP model drives the queue the way a human following the card
// would.
//
// The handlers ride the seam (mcpInvoke): they translate MCP tool arguments into
// the manifest command's path args + typed body fields, run the SAME machinery a
// `bp task …` invocation would (BuildURL → buildBody → authHeaders → doRequest),
// and return the raw response JSON as MCP result content. Two hard rules:
//
//   - yes is FORCED (the prod write-guard is bypassed): confirmProdWrite reads
//     stdin, and an MCP server has no interactive stdin — the pipe is the
//     protocol — so a guard prompt would hang the server. mcpInvoke calls
//     doRequest directly, never runCommand, so no guard runs.
//   - NOTHING is written to os.Stdout. The result is the response body as text;
//     an HTTP status >= 400 sets IsError so the client sees a tool failure with
//     the server's error envelope as the message.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// @canonical capability:mcp-task-tools aka:mcp,cursor,tasks,task_ready,task_next,task_close doc:docs/cards/cli.md
// registerTaskTools registers the curated five task tools on srv, hand-mapping
// each onto its manifest task verb (task_create has no manifest verb — the live
// manifest declares no task.create, so it is built directly from the mutate
// contract). It returns an error only if a required manifest verb is missing —
// the server must not come up advertising a tool it cannot back.
func registerTaskTools(srv *mcp.Server, ctx manifest.Context, m *manifest.Manifest) error {
	tree := m.Tree()

	ready, ok := tree.Lookup("task", "ready")
	if !ok {
		return fmt.Errorf("manifest has no task.ready verb")
	}
	next, ok := tree.Lookup("task", "next")
	if !ok {
		return fmt.Errorf("manifest has no task.next verb")
	}
	show, ok := tree.Lookup("task", "get")
	if !ok {
		return fmt.Errorf("manifest has no task.get verb")
	}
	closeCmd, ok := tree.Lookup("task", "close")
	if !ok {
		return fmt.Errorf("manifest has no task.close verb")
	}

	// task_ready — the queue head. A read; the optional limit rides the query.
	readyCmd := *ready
	srv.AddTool(&mcp.Tool{
		Name:        "task_ready",
		Title:       "List ready tasks",
		Description: "List the READY tasks — unblocked work available to claim, in priority order (priority 0 is highest). This is the queue head: start here to find work. Read-only; it does NOT claim anything. To take a task, call task_next (atomic claim) rather than task_show on a specific id, so you never race another worker.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "limit": {
      "type": "integer",
      "minimum": 1,
      "maximum": 200,
      "description": "Max tasks to return (default server page size)."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			Limit *int `json:"limit"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		q := url.Values{}
		if in.Limit != nil {
			q.Set("limit", strconv.Itoa(*in.Limit))
		}
		return mcpRun(mcpInvoke(ctx, m, readyCmd, nil, nil, q)), nil
	})

	// task_next — atomically claim the NEXT ready task. Claim-first: the claim IS
	// how you get the brief and the epoch. An empty queue answers 200 {ok:false,
	// reason:"no_ready"} — a valid outcome, not an error.
	nextCmd := *next
	srv.AddTool(&mcp.Tool{
		Name:        "task_next",
		Title:       "Claim the next ready task",
		Description: "Atomically CLAIM the next ready task (priority order) for worker_id, and return its brief. Claim FIRST — the claim is what hands you the task's full description + acceptance_criteria AND the epoch you need to close it. Pick one worker_id and keep it (e.g. \"cursor-<your-name-or-branch>\") so claim/close stay symmetric. An empty queue returns 200 with {\"ok\":false,\"reason\":\"no_ready\"} — that means 'no work available', NOT an error; do not retry in a tight loop. On success the response carries the claimed doc and its claim.epoch — remember that epoch to close.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["worker_id"],
  "properties": {
    "worker_id": {
      "type": "string",
      "description": "Stable worker identity, e.g. \"cursor-alice\". Reuse the same id for the matching close."
    },
    "phase_id": {
      "type": "string",
      "description": "Optional: restrict the claim to tasks under this phase/goal slug."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			WorkerID string `json:"worker_id"`
			PhaseID  string `json:"phase_id"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.WorkerID) == "" {
			return mcpArgError(fmt.Errorf("worker_id is required")), nil
		}
		set := []string{"worker_id=" + in.WorkerID}
		if in.PhaseID != "" {
			set = append(set, "phase_id="+in.PhaseID)
		}
		return mcpRun(mcpInvoke(ctx, m, nextCmd, nil, set, nil)), nil
	})

	// task_show — full detail for one task id (children + child_count).
	showCmd := *show
	srv.AddTool(&mcp.Tool{
		Name:        "task_show",
		Title:       "Show a task",
		Description: "Fetch one task by its doc_id — full detail including description, acceptance_criteria, lifecycle_status, any claim, and children + child_count. Read-only. Use it to re-read a brief (e.g. after a close 409'd with doc_changed_since_claim, read the task again before closing) or to inspect a task you already hold. To START work, prefer task_next (which claims atomically) over showing an id and hoping it's still free.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["doc_id"],
  "properties": {
    "doc_id": {
      "type": "string",
      "description": "The task's doc_id (its slug), e.g. \"mcp-w1-core\"."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			DocID string `json:"doc_id"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.DocID) == "" {
			return mcpArgError(fmt.Errorf("doc_id is required")), nil
		}
		return mcpRun(mcpInvoke(ctx, m, showCmd, map[string]string{"doc_id": in.DocID}, nil, nil)), nil
	})

	// task_close — complete a claimed task under epoch-CAS, optionally flipping
	// acceptance criteria in the same atomic write.
	cc := *closeCmd
	srv.AddTool(&mcp.Tool{
		Name:        "task_close",
		Title:       "Close a claimed task",
		Description: "Close a task you hold, under epoch-CAS. Pass the SAME worker_id you claimed with and the observed_epoch from that claim (doc.claim.epoch). lifecycle_status is the done-signal — \"done\" for completed work, \"cancelled\" to drop it, \"blocked\" if it can't proceed; it is what marks the task finished, NOT the claim record. Mark acceptance criteria in the same write via `criteria` — an array of {index, met, evidence} — so the ledger records WHAT you proved and HOW. If the close returns 409 doc_changed_since_claim, the brief changed under your claim: task_show it again, reconcile, then close again. If your claim lapsed (epoch moved on), re-claim the task with task_next / a fresh claim to get a new epoch, then close with that.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["doc_id", "worker_id", "observed_epoch"],
  "properties": {
    "doc_id": {
      "type": "string",
      "description": "The claimed task's doc_id."
    },
    "worker_id": {
      "type": "string",
      "description": "The SAME worker_id used for the claim."
    },
    "observed_epoch": {
      "type": "integer",
      "description": "The epoch from your claim (doc.claim.epoch). Close is a compare-and-swap on this — a stale epoch 409s."
    },
    "lifecycle_status": {
      "type": "string",
      "enum": ["done", "cancelled", "blocked"],
      "description": "The done-signal. Default \"done\".",
      "default": "done"
    },
    "reason": {
      "type": "string",
      "description": "Short human note on the outcome."
    },
    "criteria": {
      "type": "array",
      "description": "Acceptance criteria to flip in the same atomic write.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["index", "met"],
        "properties": {
          "index": { "type": "integer", "description": "0-based position in the task's acceptance_criteria." },
          "met": { "type": "boolean" },
          "evidence": { "type": "string", "description": "Concrete proof: test names, gate output, branch, commit." }
        }
      }
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			DocID           string            `json:"doc_id"`
			WorkerID        string            `json:"worker_id"`
			ObservedEpoch   *int              `json:"observed_epoch"`
			LifecycleStatus string            `json:"lifecycle_status"`
			Reason          string            `json:"reason"`
			Criteria        []json.RawMessage `json:"criteria"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.DocID) == "" || strings.TrimSpace(in.WorkerID) == "" {
			return mcpArgError(fmt.Errorf("doc_id and worker_id are required")), nil
		}
		if in.ObservedEpoch == nil {
			return mcpArgError(fmt.Errorf("observed_epoch is required (the epoch from your claim)")), nil
		}
		status := in.LifecycleStatus
		if status == "" {
			status = "done"
		}
		// worker_id/lifecycle_status/reason ride as strings; observed_epoch and
		// criteria ride TYPED (:=) so the server sees a number / JSON array, not a
		// stringified value its validators would reject.
		set := []string{
			"worker_id=" + in.WorkerID,
			"observed_epoch:=" + strconv.Itoa(*in.ObservedEpoch),
			"lifecycle_status=" + status,
		}
		if in.Reason != "" {
			set = append(set, "reason="+in.Reason)
		}
		if len(in.Criteria) > 0 {
			arr, err := json.Marshal(in.Criteria)
			if err != nil {
				return mcpArgError(fmt.Errorf("criteria: %w", err)), nil
			}
			set = append(set, "criteria:="+string(arr))
		}
		return mcpRun(mcpInvoke(ctx, m, cc, map[string]string{"doc_id": in.DocID}, set, nil)), nil
	})

	// task_create — file a new task. No manifest verb exists (the live manifest
	// declares no task.create); it is built directly from the mutate contract,
	// injecting the task schema's required kind/lifecycle_status defaults, exactly
	// as `bp task create` does. Published by default so boards + gates (which read
	// the published ledger) can see it.
	srv.AddTool(&mcp.Tool{
		Name:        "task_create",
		Title:       "Create a task",
		Description: "File a NEW task. Injects the task schema's required kind=\"task\" + lifecycle_status=\"open\" defaults, so you supply only the title (and any optional fields). Published by default — an unpublished task is invisible to boards and gates, so it effectively 'does not exist'; pass publish:false only for a deliberate draft. Nest large work with parent_id (a slug) for a Goal -> sub-task tree; keep it flat otherwise. priority is 0 (highest) .. 4. Give acceptance_criteria as concrete, evidence-bearing checks — one per real proof obligation.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["title"],
  "properties": {
    "title": { "type": "string", "description": "Task title (required, non-empty)." },
    "description": { "type": "string" },
    "parent_id": { "type": "string", "description": "Parent task/goal slug for a nested tree." },
    "priority": { "type": "integer", "minimum": 0, "maximum": 4, "description": "0 = highest .. 4 = lowest." },
    "acceptance_criteria": {
      "type": "array",
      "description": "Proof obligations.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["criterion"],
        "properties": {
          "criterion": { "type": "string" },
          "met": { "type": "boolean" },
          "evidence": { "type": "string" }
        }
      }
    },
    "publish": { "type": "boolean", "description": "Publish immediately (default true).", "default": true }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			Title              string            `json:"title"`
			Description        string            `json:"description"`
			ParentID           string            `json:"parent_id"`
			Priority           *int              `json:"priority"`
			AcceptanceCriteria []json.RawMessage `json:"acceptance_criteria"`
			Publish            *bool             `json:"publish"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.Title) == "" {
			return mcpArgError(fmt.Errorf("title is required (a task needs a non-empty title)")), nil
		}
		body := map[string]any{
			"kind":             "task",
			"lifecycle_status": "open",
			"title":            in.Title,
		}
		if in.Description != "" {
			body["description"] = in.Description
		}
		if in.ParentID != "" {
			body["parent_id"] = in.ParentID
		}
		if in.Priority != nil {
			body["priority"] = *in.Priority
		}
		if len(in.AcceptanceCriteria) > 0 {
			crit := make([]any, 0, len(in.AcceptanceCriteria))
			for _, raw := range in.AcceptanceCriteria {
				var v any
				if err := json.Unmarshal(raw, &v); err != nil {
					return mcpArgError(fmt.Errorf("acceptance_criteria: %w", err)), nil
				}
				crit = append(crit, v)
			}
			body["acceptance_criteria"] = crit
		}
		publish := true
		if in.Publish != nil {
			publish = *in.Publish
		}
		return mcpTaskCreate(ctx, body, publish), nil
	})

	return nil
}

// mcpInvoke is the seam: it executes one manifest command programmatically and
// returns the raw HTTP status + response bytes, with the prod write-guard forced
// OFF (an MCP server has no interactive stdin). It reuses the CLI's own
// machinery — m.BuildURL fills path placeholders, buildBody assembles the JSON
// body from the same --set convention, authHeaders attaches the tier credential,
// doRequest sends — so an MCP tool call is byte-for-byte the request the
// equivalent `bp task …` command would make. It NEVER renders or maps to an exit
// code; the caller wraps the result for MCP.
//
// argMap carries path/body arg values (only path placeholders matter here — the
// task tools pass every body field through setPairs so integers/arrays stay
// typed). setPairs are `key=value` / `key:=json` tokens merged into the body
// exactly as buildBody handles them. query carries read query-string params.
func mcpInvoke(ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, argMap map[string]string, setPairs []string, query url.Values) (int, []byte, error) {
	if argMap == nil {
		argMap = map[string]string{}
	}
	rawURL, err := m.BuildURL(cmd, ctx, argMap)
	if err != nil {
		return 0, nil, err
	}
	if len(query) > 0 {
		sep := "?"
		if strings.Contains(rawURL, "?") {
			sep = "&"
		}
		rawURL = rawURL + sep + query.Encode()
	}

	var flags map[string][]string
	if len(setPairs) > 0 {
		flags = map[string][]string{"set": setPairs}
	}
	body, stream, contentType, err := buildBody(cmd, flags, argMap)
	if err != nil {
		return 0, nil, err
	}
	// The task tools never upload a stream; guard the invariant explicitly.
	if stream != nil {
		return 0, nil, fmt.Errorf("mcp: streaming body not supported for %s %s", cmd.Noun, cmd.Verb)
	}

	headers := authHeaders(cmd, ctx)
	if contentType != "" {
		headers["Content-Type"] = contentType
	}
	return doRequest(cmd.HTTP.Method, rawURL, headers, body)
}

// mcpTaskCreate files a new task via the mutate contract (there is no task.create
// manifest verb), mirroring runTaskCreate but returning an MCP result instead of
// writing a receipt to stdout. It creates the draft, optionally publishes it, and
// returns a compact JSON receipt {id, draft, status} as tool content. Any failure
// sets IsError with a message that still names the created id (so a
// created-but-publish-failed task is not silently lost).
func mcpTaskCreate(ctx manifest.Context, body map[string]any, publish bool) *mcp.CallToolResult {
	createOp := map[string]any{"_type": "task"}
	for k, v := range body {
		createOp[k] = v
	}
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
	})
	results, err := client.MutateResults([]map[string]any{{"create": createOp}})
	if err != nil {
		return mcpTextError(fmt.Sprintf("task_create: %v", err))
	}
	if len(results) == 0 || results[0].ID == "" {
		return mcpTextError("task_create: server returned no id")
	}
	draftID := results[0].ID
	bareID := strings.TrimPrefix(draftID, "drafts.")
	status := "draft"
	if publish {
		if err := client.Publish("task", bareID); err != nil {
			return mcpTextError(fmt.Sprintf("task_create: created %s but publish failed: %v", bareID, err))
		}
		status = "published"
	}
	receipt, _ := json.Marshal(map[string]any{"id": bareID, "draft": draftID, "status": status})
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(receipt)}}}
}

// decodeMCPArgs unmarshals a tool call's raw arguments into dst. A nil/empty
// arguments object is valid (all-optional tools); only malformed JSON errors.
func decodeMCPArgs(req *mcp.CallToolRequest, dst any) error {
	if req == nil || req.Params == nil || len(req.Params.Arguments) == 0 {
		return nil
	}
	if err := json.Unmarshal(req.Params.Arguments, dst); err != nil {
		return fmt.Errorf("invalid arguments: %w", err)
	}
	return nil
}

// mcpRun wraps an mcpInvoke result into an MCP tool result: the raw response body
// as text content, with IsError set when the HTTP status is >= 400. A transport
// error (never reached the server) is itself an IsError text result. NOTE: a 200
// carrying {"ok":false,"reason":"no_ready"} (the empty-queue claim) is NOT an
// error — it is a valid outcome the model should read, so IsError stays false.
func mcpRun(status int, body []byte, err error) *mcp.CallToolResult {
	if err != nil {
		return mcpTextError("request failed: " + err.Error())
	}
	text := string(body)
	if text == "" {
		text = fmt.Sprintf("(empty response, HTTP %d)", status)
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
		IsError: status >= 400,
	}
}

// mcpArgError is an IsError result for a bad tool argument (before any request).
func mcpArgError(err error) *mcp.CallToolResult {
	return mcpTextError(err.Error())
}

// mcpTextError builds an IsError result carrying msg as its text content.
func mcpTextError(msg string) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: msg}},
		IsError: true,
	}
}
