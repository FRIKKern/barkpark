package cli

// mcp_tasks.go — the curated eight Barkpark task tools, hand-mapped onto the
// manifest task verbs and exposed over MCP. Each tool's description carries the
// barkpark-tasks.mdc doctrine (claim-first, epoch-CAS, lifecycle_status is the
// done-signal, criteria-in-close, 409 doc_changed_since_claim, re-claim on
// lapse) so an MCP model drives the queue the way a human following the card
// would. task_prime (task.prime) is the one-call rehydration entry point: an
// agent resuming a session reads its in-progress claims (with the epoch it needs
// to close), the ready head, recent events, and lifecycle counts in a single
// read — no re-fetch loop. task_stamp / task_pulse are the mid-claim heartbeat
// pair: stamp records evidence on ONE acceptance criterion the moment it is
// proven (holder + epoch-gated, --met needs non-empty evidence, --miss records
// an honest attempt WITHOUT flipping the lock), pulse writes the now-line and
// renews the lease in one write (holder-gated, NO epoch arg — it BUMPS the claim
// epoch, so re-read doc.claim.epoch before the next stamp/close). Close remains
// the seal (epoch-only CAS).
//
// Every tool also carries an MCP behaviour annotation (readOnlyHint /
// destructiveHint) hand-set to match what it actually does: the three reads
// (task_ready, task_show, task_prime) are ReadOnlyHint:true; the three
// lifecycle/claim writers (task_next, task_close, task_create) are
// ReadOnlyHint:false + DestructiveHint:true so a client can prompt before a
// mutating call. task_stamp / task_pulse are the deliberate middle ground:
// ReadOnlyHint:false (they DO write) + DestructiveHint:FALSE — both are
// holder+epoch-gated, forward-only updates (stamp records criterion evidence,
// pulse writes a now-line + renews the lease) that a client should NOT gate
// behind a destructive-confirm, since stamp-as-you-go and per-phase pulses fire
// often and neither destroys prior state. This is a deliberate divergence from
// the bridge's blunt Writes→DestructiveHint:true rule (mcp_bridge.go), which has
// only the one manifest bit; the curated tools know better.
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
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// registerTaskTools registers the curated eight task tools on srv, hand-mapping
// each onto its manifest task verb (task_create has no manifest verb — the live
// manifest declares no task.create, so it is built directly from the mutate
// contract). It returns an error only if a required manifest verb is missing —
// the server must not come up advertising a tool it cannot back. All verb
// Lookups run BEFORE the first AddTool: this batch-first invariant is what lets
// runMCPServe report a missing-verb failure cleanly (nothing half-registered),
// and it is why a tasks-less manifest under --tools all fails this function fast
// rather than serving a broken tool.
//
// Naming note: most tool names match their verb, but task_show maps onto the
// task.get verb (the tool keeps its show-vs-get name for MCP-client familiarity).
// task_stamp / task_pulse have no such divergence — they map straight onto
// task.stamp / task.pulse.
//
// @canonical capability:mcp-task-tools aka:mcp,cursor,tasks,task_ready,task_next,task_show,task_close,task_create,task_prime,task_stamp,task_pulse doc:docs/cards/cli.md
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
	stamp, ok := tree.Lookup("task", "stamp")
	if !ok {
		return fmt.Errorf("manifest has no task.stamp verb")
	}
	pulse, ok := tree.Lookup("task", "pulse")
	if !ok {
		return fmt.Errorf("manifest has no task.pulse verb")
	}

	// task_ready — the queue head. A read; the optional limit rides the query.
	readyCmd := *ready
	srv.AddTool(&mcp.Tool{
		Name:        "task_ready",
		Title:       "List ready tasks",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		Description: "List the READY tasks — executable, unblocked work available to claim. Priority order (priority 0 is highest) is the compatibility default; pass order=closure_nearest for fewest unmet criteria, then oldest, then logical task id. This is the queue head: start here to find work. Read-only; it does NOT claim anything. To take a task, call task_next (atomic claim) rather than task_show on a specific id, so you never race another worker.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "limit": {
      "type": "integer",
      "minimum": 1,
      "maximum": 200,
      "description": "Max tasks to return (default server page size)."
    },
    "order": {
      "type": "string",
      "enum": ["closure_nearest"],
      "description": "Optional campaign order: fewest unmet criteria, then oldest, then logical task id."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			Limit *int   `json:"limit"`
			Order string `json:"order"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		// limit rides the pagination globals (task.ready is paginated), exactly
		// like `bp task ready --limit N` — applyQuery turns g.limitSet into the
		// query param regardless of whether the manifest declares a limit flag.
		gq := g
		// An MCP consumer is an agent by definition: request the brief view
		// (AXI R1 — compact cards, no content echo). Old servers ignore the
		// param (proven inert); task_show remains the full-detail escape hatch.
		gq.view = "brief"
		if in.Limit != nil {
			gq.limit = *in.Limit
			gq.limitSet = true
		}
		tail := []string{}
		if in.Order != "" {
			tail = append(tail, "--order", in.Order)
		}
		status, body, rerr := execManifestCommand(gq, ctx, m, readyCmd, tail)
		return mcpRunFor(status, body, rerr, readyCmd.Writes), nil
	})

	// task_next — atomically claim the NEXT ready task. Claim-first: the claim IS
	// how you get the brief and the epoch. An empty queue answers 200 {ok:false,
	// reason:"no_ready"} — a valid outcome, not an error.
	nextCmd := *next
	srv.AddTool(&mcp.Tool{
		Name:        "task_next",
		Title:       "Claim the next ready task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
		Description: "Atomically CLAIM the next executable task for worker_id, and return its brief. Priority order is the compatibility default; pass order=closure_nearest for fewest unmet criteria, then oldest, then logical task id. Claim FIRST — the claim is what hands you the task's full description + acceptance_criteria AND the epoch you need to close it. Pick one worker_id and keep it (e.g. \"cursor-<your-name-or-branch>\") so claim/close stay symmetric. An empty queue returns 200 with {\"ok\":false,\"reason\":\"no_ready\"} — that means 'no work available', NOT an error; do not retry in a tight loop. On success the response carries the claimed doc and its claim.epoch — remember that epoch to close.",
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
	    },
	    "order": {
	      "type": "string",
	      "enum": ["closure_nearest"],
	      "description": "Optional campaign order: fewest unmet criteria, then oldest, then logical task id."
	    },
	    "execution_policy_override": {
	      "type": "object",
	      "additionalProperties": false,
	      "required": ["version"],
	      "properties": {
	        "version": { "type": "integer", "const": 1 },
	        "agent_type": { "type": "string", "minLength": 1, "maxLength": 64 },
	        "model": { "type": "string", "minLength": 1, "maxLength": 128 },
	        "reasoning_effort": { "type": "string", "enum": ["minimal", "low", "medium", "high", "xhigh"] },
	        "resource_class": { "type": "string", "enum": ["light", "standard", "heavy"] }
	      },
	      "description": "Highest-precedence advisory override, frozen into the claim snapshot."
	    }
	  }
	}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			WorkerID                string          `json:"worker_id"`
			PhaseID                 string          `json:"phase_id"`
			Order                   string          `json:"order"`
			ExecutionPolicyOverride json.RawMessage `json:"execution_policy_override"`
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
		if in.Order != "" {
			tail = append(tail, "--order", in.Order)
		}
		var policy map[string]any
		if len(in.ExecutionPolicyOverride) > 0 && string(in.ExecutionPolicyOverride) != "null" {
			var err error
			policy, err = parseTaskExecutionPolicyJSON(in.ExecutionPolicyOverride)
			if err != nil {
				return mcpArgError(fmt.Errorf("execution_policy_override: %w", err)), nil
			}
		}
		status, body, rerr := execTaskNextWithPolicy(g, ctx, m, nextCmd, tail, policy)
		return mcpRunFor(status, body, rerr, nextCmd.Writes), nil
	})

	// task_show — full detail for one task id (children + child_count).
	showCmd := *show
	srv.AddTool(&mcp.Tool{
		Name:        "task_show",
		Title:       "Show a task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		Description: "Fetch one task by its doc_id — full detail including description, acceptance_criteria, lifecycle_status, any claim, and children + child_count. Read-only. Use it to re-read a brief (e.g. after a close 409'd with doc_changed_since_claim, read the task again, reconcile, then close passing observed_rev=current_rev — a bare re-read then close repeats the 409 because your claim's work digest is preserved) or to inspect a task you already hold. To START work, prefer task_next (which claims atomically) over showing an id and hoping it's still free.",
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
		status, body, rerr := execManifestCommand(g, ctx, m, showCmd, []string{in.DocID})
		return mcpRunFor(status, body, rerr, showCmd.Writes), nil
	})

	// task_close — complete a claimed task under epoch-CAS, optionally flipping
	// acceptance criteria in the same atomic write.
	cc := *closeCmd
	srv.AddTool(&mcp.Tool{
		Name:        "task_close",
		Title:       "Close a claimed task",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
		Description: "Close a task you hold, under epoch-CAS. Pass the SAME worker_id you claimed with and the observed_epoch from that claim (doc.claim.epoch). lifecycle_status is the done-signal — \"done\" for completed work, \"cancelled\" to drop it, \"blocked\" if it can't proceed; it is what marks the task finished, NOT the claim record. Mark acceptance criteria in the same write via `criteria` — an array of {index, met, evidence, criterion} — so the ledger records WHAT you proved and HOW. `criterion` (the criterion's EXACT stored wording, copied verbatim from acceptance_criteria[index].criterion) is REQUIRED on every entry with met:true: the 0-based index alone is unverifiable, so an unguarded met-flip is REJECTED (409 criterion_text_required) rather than silently flipping a NEIGHBOURING criterion, and a text that does not match the row at index is REJECTED (409 criteria_mismatch) with nothing written. An entry with met:false needs no text. If the close returns 409 doc_changed_since_claim, the brief changed under your claim and the 409 names current_rev + changed_fields: task_show it, reconcile the changes, then close again passing observed_rev set to that current_rev (strict full-rev CAS, bypasses the digest fence). A plain task_show then close REPEATS the 409 — a same-worker re-read preserves the claim-time work digest, so observed_rev is the only escape. If your claim lapsed (epoch moved on), re-claim the task with task_next / a fresh claim to get a new epoch, then close with that.",
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
    "observed_rev": {
      "type": "string",
      "description": "Recovery from a 409 doc_changed_since_claim: the current_rev the 409 named (the rev you just re-read and reconciled). Passing it switches the close to strict full-rev CAS and BYPASSES the claim-time work-digest fence, so the close succeeds against exactly the revision you reviewed. A stale rev still 409s. Omit for a normal close."
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
      "description": "Acceptance criteria to flip in the same atomic write. Every entry with met:true MUST also carry criterion (its exact stored wording) — an unguarded met-flip is REJECTED (409 criterion_text_required).",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["index", "met"],
        "properties": {
          "index": { "type": "integer", "description": "0-based position in the task's acceptance_criteria. The FIRST criterion is 0." },
          "met": { "type": "boolean" },
          "evidence": { "type": "string", "description": "Concrete proof: test names, gate output, branch, commit." },
          "criterion": { "type": "string", "description": "REQUIRED when met is true: the criterion's exact stored wording, copied verbatim from acceptance_criteria[index].criterion. It is the off-by-one guard — without it the close is REJECTED (409 criterion_text_required); with a text that does not match the row at index it is REJECTED (409 criteria_mismatch) and nothing is written. An entry with met:false needs no text." }
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
			ObservedRev     string            `json:"observed_rev"`
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
		// observed_rev recovers a 409 doc_changed_since_claim: it rides the same
		// repeatable --set flag as criteria so the server switches to strict
		// full-rev CAS and bypasses the work-digest fence (Tasks.close/3 :observed_rev).
		if rev := strings.TrimSpace(in.ObservedRev); rev != "" {
			tail = append(tail, "--set", "observed_rev="+rev)
		}
		httpStatus, body, rerr := execManifestCommand(g, ctx, m, cc, tail)
		return mcpRunFor(httpStatus, body, rerr, cc.Writes), nil
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
		Description: "File a NEW task. Injects the task schema's required kind=\"task\" + lifecycle_status=\"open\" defaults, so you supply only the title (and any optional fields). Published by default — an unpublished task is invisible to boards and gates, so it effectively 'does not exist'; pass publish:false only for a deliberate draft. NOTE: this MCP tool defaults publish TRUE, unlike the `bp task create` CLI which defaults it FALSE (draft-first) — reach for publish:false here only when you deliberately want a draft. Nest large work with parent_id (a slug) for a Goal -> sub-task tree; keep it flat otherwise. priority is 0 (highest) .. 4. Give acceptance_criteria as concrete, evidence-bearing checks — one per real proof obligation. Give tags as weighted labels — each {tag, strength (integer 1-100), rationale}, all three required. Strengths must be DISTINCT with a single UNIQUE MAXIMUM (that top-weighted tag is the main tag). Bounds are HARD: 1-12 tags; the healthy advisory norm is 2-4. Once the authoring-excellence publish wall is live, a task that violates these rules is rejected at publish — so shape tags to the rules and this tool is the retry channel.",
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
	    "execution_policy": {
	      "type": "object",
	      "additionalProperties": false,
	      "required": ["version"],
	      "properties": {
	        "version": { "type": "integer", "const": 1 },
	        "agent_type": { "type": "string", "minLength": 1, "maxLength": 64 },
	        "model": { "type": "string", "minLength": 1, "maxLength": 128 },
	        "reasoning_effort": { "type": "string", "enum": ["minimal", "low", "medium", "high", "xhigh"] },
	        "resource_class": { "type": "string", "enum": ["light", "standard", "heavy"] }
	      },
	      "description": "Optional strict advisory routing policy stored on the Task."
	    },
	    "tags": {
      "type": "array",
      "description": "Weighted labels. Hard bounds 1-12 (advisory norm 2-4); strengths must be distinct with a single unique maximum (the main tag).",
      "minItems": 1,
      "maxItems": 12,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["tag", "strength", "rationale"],
        "properties": {
          "tag": { "type": "string", "pattern": "^[a-z0-9-]+$", "description": "The label — lowercase letters, digits and hyphens only." },
          "strength": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Weight 1-100; distinct across tags, one unique max." },
          "rationale": { "type": "string", "minLength": 20, "description": "Why this label earns its strength (at least 20 characters)." }
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
			ExecutionPolicy    json.RawMessage   `json:"execution_policy"`
			Tags               []json.RawMessage `json:"tags"`
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
		if len(in.ExecutionPolicy) > 0 && string(in.ExecutionPolicy) != "null" {
			policy, err := parseTaskExecutionPolicyJSON(in.ExecutionPolicy)
			if err != nil {
				return mcpArgError(fmt.Errorf("execution_policy: %w", err)), nil
			}
			body["execution_policy"] = policy
		}
		if len(in.Tags) > 0 {
			tags := make([]any, 0, len(in.Tags))
			for _, raw := range in.Tags {
				var v any
				if err := json.Unmarshal(raw, &v); err != nil {
					return mcpArgError(fmt.Errorf("tags: %w", err)), nil
				}
				tags = append(tags, v)
			}
			body["tags"] = tags
		}
		ensureTaskPortableBrief(body)
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
		Description: "One-call REHYDRATION for a resuming agent — read this first when you pick up work. It returns, in a single response: your in_progress claims (each carries claim.epoch, so you can task_close WITHOUT re-fetching the task), the ready-head (top of the queue), recent_events (what changed lately), lifecycle counts, and rails (rail_rev per epic you hold). Pass worker_id = the SAME id you claim and close with, so in_progress is scoped to YOUR claims; OMITTING worker_id returns ALL open claims across every worker — the orchestrator dump, not your working set. IMPORTANT: prime is read-only and NEVER (re-)establishes a claim. If a task you expected is MISSING from in_progress, your claim LAPSED — re-claim it with task_next before you touch it; do not assume the old epoch is still valid.",
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
    },
    "order": {
      "type": "string",
      "enum": ["closure_nearest"],
      "description": "Optional campaign order for the ready head."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			WorkerID string `json:"worker_id"`
			Limit    *int   `json:"limit"`
			Order    string `json:"order"`
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
		if in.Order != "" {
			tail = append(tail, "--order", in.Order)
		}
		// Agent surface → brief view (AXI R1): the rehydration read keeps its
		// claim epochs and counts but drops the content echoes. Inert on old
		// servers; task_show stays full for any doc that needs the whole body.
		gp := g
		gp.view = "brief"
		status, body, rerr := execManifestCommand(gp, ctx, m, primeCmd, tail)
		return mcpRunFor(status, body, rerr, primeCmd.Writes), nil
	})

	// task_stamp — record evidence on ONE acceptance criterion mid-claim. A
	// holder + epoch-gated write, but NOT DestructiveHint: it advances the ledger
	// forward (evidence on --met, an honest attempt note on --miss), it never
	// destroys prior state, and stamp-as-you-go fires often — a confirm prompt
	// would be friction. Stamp does NOT bump the epoch (unlike pulse); close
	// remains the seal.
	stampCmd := *stamp
	srv.AddTool(&mcp.Tool{
		Name:        "task_stamp",
		Title:       "Stamp a criterion mid-claim",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(false)},
		Description: "Record evidence on ONE acceptance criterion the MOMENT it is proven — do NOT batch to the close. Stamp is progress; close is the seal. Pass the SAME worker_id you claimed with and the observed_epoch from your claim (doc.claim.epoch) — stamp is holder-only under the SAME epoch fence as close (a lapsed claim can't stamp: re-claim to renew the epoch, then re-stamp). criterion is the ZERO-BASED index into acceptance_criteria: the FIRST criterion is 0, the second is 1 — do NOT pass a 1-based number. criterion_text (the criterion's EXACT stored wording, copied verbatim from acceptance_criteria[criterion].criterion) is REQUIRED whenever you pass met:true — it is the off-by-one guard: WITHOUT it the stamp is REJECTED (409 criterion_text_required, nothing written), and WITH a text that does not match the row at criterion it is REJECTED (409 criteria_mismatch) instead of silently flipping a NEIGHBOURING criterion. A miss needs no text (it flips nothing). Then pass EXACTLY ONE outcome: `met:true` WITH a non-empty `evidence` (concrete proof — test names, gate output, branch, commit) FLIPS the criterion's lock (a met with empty evidence is rejected); OR `miss:true` WITH a non-empty `note` records an honest failed attempt on the criterion's attempts trail (5 most recent kept) WITHOUT flipping met. Stamp does NOT bump the epoch, so the same observed_epoch is still valid for your next stamp or the close. On success the response carries the fresh doc. A wrong holder / stale epoch / bad index returns 409.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["doc_id", "worker_id", "observed_epoch", "criterion"],
  "properties": {
    "doc_id": {
      "type": "string",
      "description": "The claimed task's doc_id."
    },
    "worker_id": {
      "type": "string",
      "description": "The SAME worker_id you claimed with (holder-only)."
    },
    "observed_epoch": {
      "type": "integer",
      "description": "The epoch from your claim (doc.claim.epoch). Same fence as close — a stale epoch 409s. Stamp does NOT bump it."
    },
    "criterion": {
      "type": "integer",
      "minimum": 0,
      "description": "ZERO-BASED index into the task's acceptance_criteria — the first criterion is 0, the second is 1. Do NOT pass a 1-based number."
    },
    "criterion_text": {
      "type": "string",
      "description": "REQUIRED with met (optional with miss): the criterion's exact stored wording, copied verbatim from acceptance_criteria[criterion].criterion. It is the off-by-one guard — a met stamp with NO criterion_text is REJECTED (409 criterion_text_required), and one whose text does not match the row at criterion is REJECTED (409 criteria_mismatch), instead of silently flipping a neighbour. Nothing is written on either rejection."
    },
    "met": {
      "type": "boolean",
      "description": "Flip the criterion to met. REQUIRES a non-empty evidence AND criterion_text. Pass EITHER met (with evidence + criterion_text) OR miss (with note), never both."
    },
    "evidence": {
      "type": "string",
      "description": "Concrete proof for met — test names, gate output, branch, commit. Required + non-empty when met is true."
    },
    "miss": {
      "type": "boolean",
      "description": "Record an honest failed attempt: appends {note,ts,worker} to the criterion's attempts (5 kept) and does NOT flip met. REQUIRES a non-empty note."
    },
    "note": {
      "type": "string",
      "description": "What was tried and why it missed (with miss), or WHY the criterion is being withdrawn (with withdraw — it is persisted on the withdrawals record and is the only place the reason survives). Required + non-empty for both."
    },
    "withdraw": {
      "type": "boolean",
      "description": "WITHDRAW a met criterion that review refuted: met goes to FALSE (criteria_progress drops), the original evidence is LEFT IN PLACE, and a {note,ts,worker,superseded_evidence} record is appended to the criterion's withdrawals list. REQUIRES note (why) and criterion_text (the same off-by-one guard met carries — lowering the wrong neighbour is as much a lie as raising it). Unlike met/miss this is allowed on a CLOSED or CANCELLED row, because a review that refutes a proof normally lands after the close; any row that is not in_progress needs observed_rev (the rev you read) instead of the epoch fence. Refused with 409 criterion_not_met if the criterion is already met=false."
    },
    "observed_rev": {
      "type": "string",
      "description": "The doc rev you read (task_get -> doc.rev). REQUIRED for a withdraw on a row that is NOT in_progress — such a row has no LIVE lease to fence against (a closed row keeps its claim only as a receipt), so the rev is the read-before-write proof instead (409 observed_rev_required otherwise). Ignored on an in_progress row, where the epoch fence applies."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			DocID         string `json:"doc_id"`
			WorkerID      string `json:"worker_id"`
			ObservedEpoch *int   `json:"observed_epoch"`
			Criterion     *int   `json:"criterion"`
			CriterionText string `json:"criterion_text"`
			Met           bool   `json:"met"`
			Evidence      string `json:"evidence"`
			Miss          bool   `json:"miss"`
			Note          string `json:"note"`
			Withdraw      bool   `json:"withdraw"`
			ObservedRev   string `json:"observed_rev"`
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
		if in.Criterion == nil {
			return mcpArgError(fmt.Errorf("criterion is required (the 0-based acceptance_criteria index)")), nil
		}
		// Exactly one outcome, with its required companion — validated here so the
		// caller gets immediate, precise feedback instead of a server 400 round-trip
		// (the server enforces the same rules as a backstop).
		outcomes := 0
		for _, on := range []bool{in.Met, in.Miss, in.Withdraw} {
			if on {
				outcomes++
			}
		}
		if outcomes != 1 {
			return mcpArgError(fmt.Errorf("pass exactly one of met / miss / withdraw — not two, and not none")), nil
		}
		if in.Met && strings.TrimSpace(in.Evidence) == "" {
			return mcpArgError(fmt.Errorf("met requires non-empty evidence")), nil
		}
		if in.Miss && strings.TrimSpace(in.Note) == "" {
			return mcpArgError(fmt.Errorf("miss requires non-empty note")), nil
		}
		if in.Withdraw && strings.TrimSpace(in.Note) == "" {
			return mcpArgError(fmt.Errorf("withdraw requires non-empty note (why review refuted the proof — it is the only place the reason survives)")), nil
		}
		// Positionals mirror `bp task stamp <id> <worker> <epoch>` (observed_epoch
		// rides as a string the server coerces via fetch_int, same as close);
		// criterion + the met/evidence | miss/note outcome ride as manifest flags
		// (query params) exactly as the CLI types them after the positionals.
		tail := []string{in.DocID, in.WorkerID, strconv.Itoa(*in.ObservedEpoch), "--criterion", strconv.Itoa(*in.Criterion)}
		if strings.TrimSpace(in.CriterionText) != "" {
			tail = append(tail, "--criterion-text", in.CriterionText)
		}
		switch {
		case in.Met:
			tail = append(tail, "--met", "--evidence", in.Evidence)
		case in.Withdraw:
			tail = append(tail, "--withdraw", "--note", in.Note)
			if strings.TrimSpace(in.ObservedRev) != "" {
				tail = append(tail, "--observed-rev", in.ObservedRev)
			}
		default:
			tail = append(tail, "--miss", "--note", in.Note)
		}
		status, body, rerr := execManifestCommand(g, ctx, m, stampCmd, tail)
		return mcpRunFor(status, body, rerr, stampCmd.Writes), nil
	})

	// task_pulse — heartbeat a held claim: write the now-line AND renew the lease
	// in one atomic write. Holder-gated but NO epoch arg — pulse survives fence
	// bumps and BUMPS the claim epoch itself (re-read doc.claim.epoch before the
	// next epoch-gated call). NOT DestructiveHint: it is an additive heartbeat that
	// fires at every phase boundary; a confirm prompt would defeat the point.
	pulseCmd := *pulse
	srv.AddTool(&mcp.Tool{
		Name:        "task_pulse",
		Title:       "Pulse a claim's now-line",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(false)},
		Description: "Heartbeat a task you hold: write the now-line (what you are doing RIGHT NOW) and renew the lease in one atomic write. Pulse right after you claim and at each phase boundary so the board moves while you work. Pass the SAME worker_id you claimed with (holder-only). There is NO epoch arg — pulse survives fence bumps, and a lost lease (reaped / released / closed / foreign) returns 409 not_holder, never a silent re-claim. IMPORTANT: pulse BUMPS the claim epoch, so the epoch you last held is now stale — re-read doc.claim.epoch from the response before your next stamp or close. now is required (max 500 bytes). Optional criterion (0-based index) tells boards which acceptance criterion this pulse is working on.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["doc_id", "worker_id", "now"],
  "properties": {
    "doc_id": {
      "type": "string",
      "description": "The claimed task's doc_id."
    },
    "worker_id": {
      "type": "string",
      "description": "The SAME worker_id you claimed with (holder-only)."
    },
    "now": {
      "type": "string",
      "description": "The now-line: what you are doing right now (required, max 500 bytes), e.g. \"gate green, committing on branch loop-epic/…\"."
    },
    "criterion": {
      "type": "integer",
      "minimum": 0,
      "description": "Optional 0-based acceptance_criteria index this pulse is working on (boards spin that lock)."
    }
  }
}`),
	}, func(c context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			DocID     string `json:"doc_id"`
			WorkerID  string `json:"worker_id"`
			Now       string `json:"now"`
			Criterion *int   `json:"criterion"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.DocID) == "" || strings.TrimSpace(in.WorkerID) == "" {
			return mcpArgError(fmt.Errorf("doc_id and worker_id are required")), nil
		}
		if strings.TrimSpace(in.Now) == "" {
			return mcpArgError(fmt.Errorf("now is required (the now-line text)")), nil
		}
		// Positionals mirror `bp task pulse <id> <worker>` (NO epoch — pulse is the
		// renewal); now + the optional criterion ride as manifest flags (query
		// params), exactly as `bp task pulse … --now "…" [--criterion N]`.
		tail := []string{in.DocID, in.WorkerID, "--now", in.Now}
		if in.Criterion != nil {
			tail = append(tail, "--criterion", strconv.Itoa(*in.Criterion))
		}
		status, body, rerr := execManifestCommand(g, ctx, m, pulseCmd, tail)
		return mcpRunFor(status, body, rerr, pulseCmd.Writes), nil
	})

	return nil
}

// execTaskNextWithPolicy extends the live task.next manifest request only at
// the MCP boundary. The server manifest intentionally remains backwards
// compatible; this curated tool adds the typed override to the JSON body after
// the shared dispatcher has resolved auth, scope, and the standard arguments.
func execTaskNextWithPolicy(g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string, policy map[string]any) (int, []byte, error) {
	req, derr := buildManifestRequest(g, ctx, m, cmd, tail, false)
	if derr != nil {
		return 0, nil, derr
	}
	if policy != nil {
		body := map[string]any{}
		if len(req.body) > 0 {
			if err := json.Unmarshal(req.body, &body); err != nil {
				return 0, nil, fmt.Errorf("decode task.next body: %w", err)
			}
		}
		body["execution_policy_override"] = policy
		encoded, err := json.Marshal(body)
		if err != nil {
			return 0, nil, fmt.Errorf("encode task.next policy: %w", err)
		}
		req.body = encoded
		req.headers["Content-Type"] = "application/json"
	}
	status, respBody, _, err := sendManifestRequest(req)
	return status, respBody, err
}

// mcpBoolPtr returns a pointer to b — for the SDK's *bool annotation fields
// (DestructiveHint) where nil means "SDK default" and a non-nil pointer sets the
// hint explicitly.
func mcpBoolPtr(b bool) *bool { return &b }

// mcpTaskCreate files a new task via the mutate contract (there is no task.create
// manifest verb), riding sendTaskMutations — the same raw send half `bp task
// create` uses (tasks_create_cmd.go) — but returning an MCP result instead of
// writing a receipt to stdout. It creates the draft, optionally publishes it, and
// returns a compact JSON receipt {id, draft, status, lifecycle_status} as tool
// content — plus a `warnings` key when the create/publish success envelope carries the authoring
// wall's advisories (publish response preferred, else create), so an agent sees the
// same {code,severity,message} advice the CLI surfaces. Any failure sets IsError
// with a message that still names the created id (so a created-but-publish-failed
// task is not silently lost).
func mcpTaskCreate(ctx manifest.Context, body map[string]any, publish bool) *mcp.CallToolResult {
	// The SAME pre-flight `bp task create --publish` runs (tasks_publish_wall.go),
	// and it matters more here: an MCP caller is an agent, and an agent that reads
	// "created task-N but publish failed" files a phantom and moves on. Refuse
	// before writing anything, in the machine-readable words the wall uses.
	if publish {
		if ref := checkLabelSpineLocal(body); ref != nil {
			return mcpTextError(mcpPublishWallMessage(ref))
		}
		if ref, _ := checkTagRegistry(ctx, body); ref != nil {
			return mcpTextError(mcpPublishWallMessage(ref))
		}
	}
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
	warnBody := respBody // fold advisories from the last successful step (publish preferred)
	if publish {
		pubOp := map[string]any{"publish": map[string]any{"id": bareID, "type": "task"}}
		pStatus, pBody, pErr := sendTaskMutations(ctx, []map[string]any{pubOp})
		if pErr != nil {
			return mcpTextError(fmt.Sprintf("task_create: created %s but publish failed: %v%s", draftID, pErr, orphanedDraftRemedyText(draftID, bareID)))
		}
		if pStatus < 200 || pStatus >= 300 {
			return mcpTextError(fmt.Sprintf("task_create: created %s but publish failed: %s%s", draftID, mutateErrorMessage(pStatus, pBody), orphanedDraftRemedyText(draftID, bareID)))
		}
		docStatus = "published"
		warnBody = pBody
	}
	// tlv-s6 (TLV charter D14): echo the born lifecycle_status — the body value
	// the server accepted — so a birth-as-considering is visible in the receipt.
	receipt := map[string]any{
		"id":               bareID,
		"draft":            draftID,
		"status":           docStatus,
		"lifecycle_status": body["lifecycle_status"],
		// pds-bl-task-create-draft-at-rc0 — the agent-facing twin of the CLI
		// receipt. An MCP caller reads JSON only, so the remedy has to BE a
		// field: `status: "draft"` beside `lifecycle_status: "open"` was read
		// as a filed task by the first real user of the birth-fence regime.
		"on_board": docStatus == "published",
	}
	if docStatus != "published" {
		receipt["publish_command"] = taskPublishCommand(bareID)
		receipt["not_on_board"] = "a draft is invisible to task_ready and cannot be claimed — publish it with publish_command, or pass publish:true to task_create"
	}
	if warnings := warningsFrom(warnBody); len(warnings) > 0 {
		receipt["warnings"] = warnings
	}
	out, _ := json.Marshal(receipt)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(out)}}}
}

// warningsFrom extracts a non-empty top-level {"warnings":[…]} advisory list from a
// mutate response body, mirroring firstMutationID's tolerant decode: the authoring
// wall folds its {code,severity,message} advisories onto the mutate success envelope
// (ae-w1), and the MCP task_create receipt would otherwise drop them on the floor.
// Returns nil for an absent/empty/malformed list so the caller can fold it
// conditionally — the receipt gains a `warnings` key only when there is something
// to say.
func warningsFrom(body []byte) []any {
	var env struct {
		Warnings []any `json:"warnings"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Warnings) == 0 {
		return nil
	}
	return env.Warnings
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

// mcpToolResultMaxBytes is the last-resort byte guard on every MCP tool result
// that rides mcpRun — 7/8 curated tools plus ALL bridge tools in one place
// (AXI R4, charter decision 10). Brief server views are the real diet; this cap
// only stops a pathological payload (a 350KB task_ready against a pre-views
// server) from flooding an agent's context. 48KB keeps a full brief page with
// headroom while bounding the worst case.
const mcpToolResultMaxBytes = 48 << 10

// mcpRun wraps an mcpInvoke result into an MCP tool result: the raw response body
// as text content, with IsError set when the HTTP status is >= 400. A transport
// error (never reached the server) is itself an IsError text result. NOTE: a 200
// carrying {"ok":false,"reason":"no_ready"} (the empty-queue claim) is NOT an
// error — it is a valid outcome the model should read, so IsError stays false.
// An oversized body is clamped to mcpToolResultMaxBytes with an inline
// truncation notice naming the byte total and the escape command (truncation
// honesty — anything omitted says so, with the exact way to get the rest).
func mcpRun(status int, body []byte, err error) *mcp.CallToolResult {
	if err != nil {
		return mcpTextError("request failed: " + err.Error())
	}
	text := string(body)
	if text == "" {
		text = fmt.Sprintf("(empty response, HTTP %d)", status)
	}
	text = clampMCPToolResult(text)
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
		IsError: status >= 400,
	}
}

// mcpRunFor is mcpRun's read/write-aware twin — the fix for this defect. A 200
// status alone is NOT a receipt: mcpRun's `status >= 400` test let a 200
// carrying an error envelope, an HTML proxy/login page, {"result":null}, or a
// bare {} write receipt reach the model as IsError:false with the poison body
// presented as the answer. mcpRunFor closes that by running every 2xx/3xx body
// through the SAME discriminators the human CLI render path already applies on
// its own write and read paths (run.go's reader-law waves 29/30) —
// unreadableWriteReceipt for a write, unreadableReadBody for a read — before
// deciding IsError. writes names the command's nature; every call site already
// knows it statically (manifest.Command.Writes), so nothing here re-derives
// that signal, and the predicates themselves stay owned by run.go: this
// function only CALLS them.
//
// Honest empties are preserved exactly as those predicates already define
// them: {} from a counts read, [] from an empty list, and a 200
// {"ok":false,"reason":"no_ready"} (the empty-queue claim) all stay
// IsError:false. A status >= 400 skips the poison check entirely and falls
// through to mcpRun's existing behaviour — an error status is already an
// error; this function only widens what counts as one on a STATED success.
func mcpRunFor(status int, body []byte, err error, writes bool) *mcp.CallToolResult {
	if err != nil {
		return mcpTextError("request failed: " + err.Error())
	}
	if status < http.StatusBadRequest {
		if reason, hint := mcpPoisonedReceipt(status, body, writes); reason != "" {
			kind := "read"
			if writes {
				kind = "write receipt"
			}
			msg := fmt.Sprintf(
				"unreadable %s: HTTP %d %s (%d bytes): %s\n  remedy: %s",
				kind, status, reason, len(body), bodyPreview(body), hint,
			)
			return &mcp.CallToolResult{
				Content: []mcp.Content{&mcp.TextContent{Text: clampMCPToolResult(msg)}},
				IsError: true,
			}
		}
	}
	return mcpRun(status, body, err)
}

// mcpPoisonedReceipt names WHY a stated-success (< 400) body carries no honest
// statement, reusing run.go's unexported discriminators — unreadableWriteReceipt
// for a write, unreadableReadBody for a read — rather than re-deriving either
// predicate. It returns ("", "") for every answer worth rendering, including
// every honest empty those predicates already carve out, and for a declared
// no-content status (204/205) with an empty body, which is a receipt, not
// silence (mirroring screenWriteReceipt's own 204/205 exemption, run.go:486).
func mcpPoisonedReceipt(status int, body []byte, writes bool) (reason, hint string) {
	if (status == http.StatusNoContent || status == http.StatusResetContent) &&
		len(bytes.TrimSpace(body)) == 0 {
		return "", ""
	}
	if writes {
		if r := unreadableWriteReceipt(body); r != "" {
			return r, unreadableWriteReceiptHint
		}
		return "", ""
	}
	r, contradiction := unreadableReadBody(body)
	if r == "" {
		return "", ""
	}
	if contradiction {
		return r, unreadableReadContradictionHint
	}
	return r, unreadableReadHint
}

// clampMCPToolResult bounds a tool-result body at mcpToolResultMaxBytes,
// cutting on a rune boundary (walk back with utf8.RuneStart so a multi-byte
// rune is never split) and appending the AXI-format truncation notice: the
// byte total plus the exact escape commands that retrieve the rest. Small
// payloads pass through untouched.
func clampMCPToolResult(text string) string {
	return clampMCPToolResultWithHint(text,
		"narrow the call (a smaller limit, or a single-task read via task_show <doc_id>)")
}

// clampMCPToolResultWithHint is clampMCPToolResult with a caller-supplied
// escape-hatch hint, so a surface with a different paging mechanism (the chat
// tools page by `since`, not limit/task_show) can keep the truncation notice
// honest about how to fetch the rest.
func clampMCPToolResultWithHint(text, hint string) string {
	if len(text) <= mcpToolResultMaxBytes {
		return text
	}
	cut := mcpToolResultMaxBytes
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut] + fmt.Sprintf(
		"\n[truncated: %d bytes total, first %d shown — %s to fetch the rest]",
		len(text), cut, hint)
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
