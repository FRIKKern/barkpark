package cli

// mcp_tasks.go — the curated six Barkpark task tools, hand-mapped onto the
// manifest task verbs and exposed over MCP. Each tool's description carries the
// barkpark-tasks.mdc doctrine (claim-first, epoch-CAS, lifecycle_status is the
// done-signal, criteria-in-close, 409 doc_changed_since_claim, re-claim on
// lapse) so an MCP model drives the queue the way a human following the card
// would. task_prime (task.prime) is the one-call rehydration entry point: an
// agent resuming a session reads its in-progress claims (with the epoch it needs
// to close), the ready head, recent events, and lifecycle counts in a single
// read — no re-fetch loop.
//
// Every tool also carries an MCP behaviour annotation (readOnlyHint /
// destructiveHint) hand-set to match what it actually does: the four reads
// (task_ready, task_show, task_prime) are ReadOnlyHint:true; the three writers
// (task_next, task_close, task_create) are ReadOnlyHint:false + DestructiveHint
// so a client can prompt before a mutating call.
//
// The handlers ride the dispatch seam (execManifestCommand, run.go): each one
// translates its MCP tool arguments into the manifest command's positional+flag
// tail — exactly what a human would type after `bp task <verb>` — and the seam
// runs the SAME machinery a CLI invocation would (splitArgs → bindArgs →
// BuildURL → applyQuery → buildBody → authHeaders → doRequest), returning the
// raw status + body. task_create rides sendTaskMutations
// (tasks_create_cmd.go), the raw send half of `bp task create`. Two hard rules:
//
//   - The prod write-guard never runs: confirmProdWrite reads stdin, and an MCP
//     server has no interactive stdin — the pipe is the protocol — so a guard
//     prompt would hang the server. execManifestCommand carries no guards (they
//     live in runCommand), and runMCPServe forces g.yes as belt-and-braces.
//   - NOTHING is written to os.Stdout. The result is the response body as text;
//     an HTTP status >= 400 sets IsError so the client sees a tool failure with
//     the server's error envelope as the message.

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// @canonical capability:mcp-task-tools aka:mcp,cursor,tasks,task_ready,task_next,task_close,task_prime doc:docs/cards/cli.md
// registerTaskTools registers the curated six task tools on srv, hand-mapping
// each onto its manifest task verb (task_create has no manifest verb — the live
// manifest declares no task.create, so it is built directly from the mutate
// contract). It returns an error only if a required manifest verb is missing —
// the server must not come up advertising a tool it cannot back. All verb
// Lookups run BEFORE the first AddTool: this batch-first invariant is what lets
// runMCPServe report a missing-verb failure cleanly (nothing half-registered),
// and it is why a tasks-less manifest under --tools all fails this function fast
// rather than serving a broken tool.
func registerTaskTools(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest) error {
	tree := m.Tree()

	// Batch every verb Lookup up front (invariant: all Lookups precede the first
	// AddTool). A missing verb aborts registration before anything lands on srv.
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
	prime, ok := tree.Lookup("task", "prime")
	if !ok {
		return fmt.Errorf("manifest has no task.prime verb")
	}

	// task_ready — the queue head. A read; the optional limit rides the query.
	readyCmd := *ready
	srv.AddTool(&mcp.Tool{
		Name:        "task_ready",
		Title:       "List ready tasks",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
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
		// limit rides the pagination globals (task.ready is paginated), exactly
		// like `bp task ready --limit N` — applyQuery turns g.limitSet into the
		// query param regardless of whether the manifest declares a limit flag.
		gq := g
		if in.Limit != nil {
			gq.limit = *in.Limit
			gq.limitSet = true
		}
		return mcpRun(execManifestCommand(gq, ctx, m, readyCmd, nil)), nil
	})

	// task_next — atomically claim the NEXT ready task. Claim-first: the claim IS
	// how you get the brief and the epoch. An empty queue answers 200 {ok:false,
	// reason:"no_ready"} — a valid outcome, not an error.
	nextCmd := *next
	srv.AddTool(&mcp.Tool{
		Name:        "task_next",
		Title:       "Claim the next ready task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
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
		// task.next declares worker_id (+ optional phase_id) as positionals; both
		// resolve to the POST body via ArgLocation inference, same as the CLI.
		tail := []string{in.WorkerID}
		if in.PhaseID != "" {
			tail = append(tail, in.PhaseID)
		}
		return mcpRun(execManifestCommand(g, ctx, m, nextCmd, tail)), nil
	})

	// task_show — full detail for one task id (children + child_count).
	showCmd := *show
	srv.AddTool(&mcp.Tool{
		Name:        "task_show",
		Title:       "Show a task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
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
		return mcpRun(execManifestCommand(g, ctx, m, showCmd, []string{in.DocID})), nil
	})

	// task_close — complete a claimed task under epoch-CAS, optionally flipping
	// acceptance criteria in the same atomic write.
	cc := *closeCmd
	srv.AddTool(&mcp.Tool{
		Name:        "task_close",
		Title:       "Close a claimed task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
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
		// Positionals mirror `bp task close <id> <worker> <epoch> <status> [reason]`
		// (observed_epoch rides as a string the server coerces via fetch_int, same
		// as the CLI); criteria ride TYPED via the manifest's repeatable --set flag
		// (criteria:=[…]) so the server sees a JSON array in the same atomic write.
		tail := []string{in.DocID, in.WorkerID, strconv.Itoa(*in.ObservedEpoch), status}
		if in.Reason != "" {
			tail = append(tail, in.Reason)
		}
		if len(in.Criteria) > 0 {
			arr, err := json.Marshal(in.Criteria)
			if err != nil {
				return mcpArgError(fmt.Errorf("criteria: %w", err)), nil
			}
			tail = append(tail, "--set", "criteria:="+string(arr))
		}
		return mcpRun(execManifestCommand(g, ctx, m, cc, tail)), nil
	})

	// task_create — file a new task. No manifest verb exists (the live manifest
	// declares no task.create); it is built directly from the mutate contract,
	// injecting the task schema's required kind/lifecycle_status defaults, exactly
	// as `bp task create` does. Published by default so boards + gates (which read
	// the published ledger) can see it.
	srv.AddTool(&mcp.Tool{
		Name:        "task_create",
		Title:       "Create a task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
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

	// task_prime — one-call session rehydration. A read (task.prime, GET
	// /v1/tasks/prime): it establishes NOTHING, it only reports. The optional
	// worker_id narrows in_progress to YOUR claims (and their close-ready epochs);
	// omitting it dumps every open claim across all workers (an orchestrator view).
	primeCmd := *prime
	srv.AddTool(&mcp.Tool{
		Name:        "task_prime",
		Title:       "Rehydrate task context",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		Description: "One-call REHYDRATION for a resuming agent — read this first when you pick up work. It returns, in a single response: your in_progress claims (each carries content.claim.epoch, so you can task_close WITHOUT re-fetching the task), the ready-head (top of the queue), recent_events (what changed lately), lifecycle counts, and rails (rail_rev per epic you hold). Pass worker_id = the SAME id you claim and close with, so in_progress is scoped to YOUR claims; OMITTING worker_id returns ALL open claims across every worker — the orchestrator dump, not your working set. IMPORTANT: prime is read-only and NEVER (re-)establishes a claim. If a task you expected is MISSING from in_progress, your claim LAPSED — re-claim it with task_next before you touch it; do not assume the old epoch is still valid.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "worker_id": {
      "type": "string",
      "description": "Your stable worker identity — pass the SAME id you claim/close with, so in_progress is scoped to your claims. Omit it to get the all-claims orchestrator dump across every worker."
    },
    "limit": {
      "type": "integer",
      "minimum": 1,
      "maximum": 100,
      "description": "Ready-head and event-window size (default 10)."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			WorkerID string `json:"worker_id"`
			Limit    *int   `json:"limit"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		// task.prime declares worker + limit as flags (no positionals); build the
		// tail exactly as `bp task prime --worker <id> --limit <n>` and let the seam
		// place both in the query string via ArgLocation inference.
		tail := []string{}
		if strings.TrimSpace(in.WorkerID) != "" {
			tail = append(tail, "--worker", in.WorkerID)
		}
		if in.Limit != nil {
			tail = append(tail, "--limit", strconv.Itoa(*in.Limit))
		}
		return mcpRun(execManifestCommand(g, ctx, m, primeCmd, tail)), nil
	})

	return nil
}

// mcpBoolPtr returns a pointer to b — for the SDK's *bool annotation fields
// (DestructiveHint) where nil means "SDK default" and a non-nil pointer sets the
// hint explicitly.
func mcpBoolPtr(b bool) *bool { return &b }

// mcpTaskCreate files a new task via the mutate contract (there is no task.create
// manifest verb), riding sendTaskMutations — the same raw send half `bp task
// create` uses (tasks_create_cmd.go) — but returning an MCP result instead of
// writing a receipt to stdout. It creates the draft, optionally publishes it, and
// returns a compact JSON receipt {id, draft, status} as tool content. Any failure
// sets IsError with a message that still names the created id (so a
// created-but-publish-failed task is not silently lost).
func mcpTaskCreate(ctx manifest.Context, body map[string]any, publish bool) *mcp.CallToolResult {
	createOp := map[string]any{"_type": "task"}
	for k, v := range body {
		createOp[k] = v
	}
	status, respBody, err := sendTaskMutations(ctx, []map[string]any{{"create": createOp}})
	if err != nil {
		return mcpTextError(fmt.Sprintf("task_create: %v", err))
	}
	if status < 200 || status >= 300 {
		return mcpTextError(fmt.Sprintf("task_create: %s", mutateErrorMessage(status, respBody)))
	}
	draftID, ok := firstMutationID(respBody)
	if !ok || draftID == "" {
		return mcpTextError("task_create: server returned no id")
	}
	bareID := strings.TrimPrefix(draftID, "drafts.")
	docStatus := "draft"
	if publish {
		pubOp := map[string]any{"publish": map[string]any{"id": bareID, "type": "task"}}
		pStatus, pBody, pErr := sendTaskMutations(ctx, []map[string]any{pubOp})
		if pErr != nil {
			return mcpTextError(fmt.Sprintf("task_create: created %s but publish failed: %v", bareID, pErr))
		}
		if pStatus < 200 || pStatus >= 300 {
			return mcpTextError(fmt.Sprintf("task_create: created %s but publish failed: %s", bareID, mutateErrorMessage(pStatus, pBody)))
		}
		docStatus = "published"
	}
	receipt, _ := json.Marshal(map[string]any{"id": bareID, "draft": draftID, "status": docStatus})
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
