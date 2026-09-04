package cli

// mcp_chat.go — the four curated chat session tools (herd charter D73h–D77h):
// chat_spawn_session / chat_send / chat_read_tail / chat_wait_for_state. AGENTS
// HERD AGENTS: an agent holding these tools spawns a sub-session, sends it a
// prompt, reads its transcript tail, and waits for it to settle — all over the
// SAME /v1/chat wire the Studio GUI and `bp chat` ride, so the herd surface is a
// third client of the one engine, never a second path.
//
// HARDCODED wrappers over internal/apiclient, NEVER manifest-Lookup-backed
// (D74h): the chat.* manifest verbs are admin-tier + existence-hidden (the open
// D36 gap), so even a chat-widened token projects a manifest with ZERO chat
// commands — a Lookup here would silently fail on the loopback and the tools
// would never register. Hardcoding dodges D36 entirely; the tier remap is the
// backlog task herd-d36-chat-tier-remap. The bridge's never-double-expose law
// still holds: chat.create_session/chat.send_message/chat.get_session are in
// bridgeShadowedIDs (mcp_bridge.go) so a future manifest that DOES carry them
// never generates bp_chat_* twins beside these curated names.
//
// TENANCY IS FAIL-CLOSED BY CONSTRUCTION (D77h): no tool takes a workspace
// parameter — a cross-workspace spawn is UNREPRESENTABLE on this surface. Every
// call inherits the caller token's workspace scope (the loopback bpcs_ session
// token, or whatever bearer `bp mcp serve` rides), and a foreign-workspace
// session id lands on the server's 404 not-found oracle. One-level herding: a
// spawned sub-session cannot mint its own loopback credential (membership, not
// permission, is the gate) — the herder drives its children through its own
// token; recursive herding is the backlog task herd-nested-hands.
//
// STDOUT SILENCE: like every tool in this server, the handlers write NOTHING to
// os.Stdout for their whole lifetime — including the full bounded block of
// chat_wait_for_state — the pipe is the JSON-RPC protocol (mcp_serve.go).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// chatWaitDefault / chatWaitCap bound the chat_wait_for_state block (D76h): the
// default is 30s, arg-tunable up to a hard 50s cap — no numeric MCP tool-call
// budget exists anywhere in the protocol, and the ~60s Codex client default is
// the worst-case floor, so 50s keeps the bound comfortably under every known
// client's patience while the resumable cursor makes longer waits a re-call,
// never a longer block.
const (
	chatWaitDefault = 30 * time.Second
	chatWaitCap     = 50 * time.Second
)

// chatClientFor builds the /v1/chat apiclient for a tool call from the server's
// manifest.Context — the same construction `bp chat` uses (chat_cmd.go): the
// chat routes are data-plane-token scoped, so BaseURL+Token is the whole config
// and there is deliberately no workspace/project/dataset to plumb. In stdio mode
// ctx carries the process credential; in HTTP mode buildMCPServer runs per
// request and ctx.Token is that request's forwarded bearer — either way the
// token IS the tenancy scope (D77h).
func chatClientFor(ctx manifest.Context) *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: ctx.Server, Token: ctx.Token})
}

// registerChatTools registers the four curated chat session tools on srv. It is
// infallible by design (no manifest Lookups, nothing to batch-fail — D74h), so
// buildMCPServer's batch-first invariant is preserved trivially: either the
// server assembly reached this call and all four register, or it failed before
// anything landed on srv.
func registerChatTools(srv *mcp.Server, ctx manifest.Context) {
	// chat_spawn_session — POST /v1/chat/sessions. Headless: creates the session
	// ROW only; no runtime boots until the first chat_send (Recorder.ensure →
	// Runtime.open server-side). A write that mints agent capacity → destructive
	// hint so gating clients prompt.
	srv.AddTool(&mcp.Tool{
		Name:        "chat_spawn_session",
		Title:       "Spawn a chat sub-session",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
		Description: "Spawn a NEW Barkpark chat session (a sub-agent you can herd). This creates the session row ONLY — no agent process starts until your first chat_send, so spawning is cheap and a spawned-but-never-prompted session just sits idle. The session inherits YOUR credential's workspace scope; there is NO workspace parameter and no cross-workspace path — a session id outside your scope answers 404 everywhere on this surface. One-level herding: the sub-session cannot mint credentials of its own; drive it with chat_send / chat_read_tail / chat_wait_for_state using the id this returns. All inputs are optional; omit them for the server defaults.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "provider": {
      "type": "string",
      "description": "Agent provider (e.g. \"claude\", \"codex\"). Omit for the server default."
    },
    "mode": {
      "type": "string",
      "description": "Permission mode for the session (server vocabulary). Omit for the default."
    },
    "model": {
      "type": "string",
      "description": "Model choice. Omit for the server default."
    },
    "effort": {
      "type": "string",
      "description": "Reasoning-effort choice. Omit for the server default."
    }
  }
}`),
	}, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			Provider string `json:"provider"`
			Mode     string `json:"mode"`
			Model    string `json:"model"`
			Effort   string `json:"effort"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		s, status, raw, err := chatClientFor(ctx).CreateChatSessionWithOptionsRaw(apiclient.ChatSessionCreateOptions{
			Provider: in.Provider,
			Mode:     in.Mode,
			Model:    in.Model,
			Effort:   in.Effort,
		})
		// The fence runs BEFORE err, deliberately: on an accepted status the raw
		// bytes ARE the receipt, and the only errors reachable there are decode
		// failures over that same body — "unexpected end of JSON input" is a
		// worse account of a proxy page than the fence's named reason.
		if status == http.StatusOK || status == http.StatusCreated {
			if res := chatSpawnReceiptRefusal(status, raw, s.ID); res != nil {
				return res, nil
			}
		}
		if err != nil {
			return mcpTextError(fmt.Sprintf("chat_spawn_session: %v", err)), nil
		}
		return mcpChatResult(s), nil
	})

	// chat_send — POST /v1/chat/sessions/:id/messages. 202 fire-and-forget: the
	// accept is NOT completion. A write that starts (and spends) an agent turn →
	// destructive hint.
	srv.AddTool(&mcp.Tool{
		Name:        "chat_send",
		Title:       "Send a prompt to a chat session",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: mcpBoolPtr(true)},
		Description: "Send a user message to a chat session you spawned (or any session in your workspace scope). FIRE-AND-FORGET: the server accepts the message (202) and runs the turn asynchronously — this result means \"enqueued\", NEVER \"answered\". The first send to a fresh session is what boots its agent process. To observe the outcome: chat_wait_for_state until the session settles (idle) or needs you (blocked), then chat_read_tail for the transcript. AVOID THE SNAPSHOT RACE: a fresh session reads idle until this send's turn boots, so arm a cursor with a chat_wait_for_state call BEFORE this send and pass it to the wait AFTER — a cursor-less wait fired straight after this send resolves instantly on the pre-boot snapshot and hands you a stale transcript (see chat_wait_for_state). A session id outside your workspace scope answers 404 (fail-closed tenancy; no workspace parameter exists).",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["session_id", "content"],
  "properties": {
    "session_id": {
      "type": "string",
      "description": "The chat session id (from chat_spawn_session, or a session you already hold)."
    },
    "content": {
      "type": "string",
      "description": "The user message / prompt to send (required, non-empty)."
    }
  }
}`),
	}, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			SessionID string `json:"session_id"`
			Content   string `json:"content"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.SessionID) == "" {
			return mcpArgError(fmt.Errorf("session_id is required")), nil
		}
		if strings.TrimSpace(in.Content) == "" {
			return mcpArgError(fmt.Errorf("content is required (the message to send)")), nil
		}
		status, raw, err := chatClientFor(ctx).SendChatMessageRaw(in.SessionID, in.Content)
		if err != nil {
			return mcpTextError(fmt.Sprintf("chat_send: %v", err)), nil
		}
		// The `accepted:true` below is SYNTHESISED by this handler, so it must not
		// outrun the server: a 2xx that said nothing would otherwise become a
		// confident local accept. chat_controller answers 202 `{accepted:true}`,
		// a receipt the fence passes; anything emptier is refused here.
		if reason, hint := mcpPoisonedReceipt(status, raw, true); reason != "" {
			return mcpUnreadableResult("chat_send write receipt", status, raw, reason, hint), nil
		}
		// 202 semantics made explicit: accepted, not answered.
		return mcpChatResult(map[string]any{"accepted": true, "session_id": in.SessionID}), nil
	})

	// chat_read_tail — GET /v1/chat/sessions/:id[?since=N]. Pure read.
	srv.AddTool(&mcp.Tool{
		Name:        "chat_read_tail",
		Title:       "Read a chat session's transcript tail",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		Description: "Read a chat session: its status/state, usage metrics, and the transcript messages. TRACK YOUR OWN CURSOR: each message row carries a seq — pass since = the highest seq you have already seen to receive only newer rows. There is no limit parameter, so a cold read (no since) returns the FULL history; on a long session that can exceed the 48KB result clamp — read once cold, then always pass since. A session id outside your workspace scope answers 404 (fail-closed tenancy). Read-only; safe to call repeatedly.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["session_id"],
  "properties": {
    "session_id": {
      "type": "string",
      "description": "The chat session id."
    },
    "since": {
      "type": "integer",
      "minimum": 0,
      "description": "Return only messages with seq greater than this — the highest seq you already hold. Omit (or 0) for the full history."
    }
  }
}`),
	}, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			SessionID string `json:"session_id"`
			Since     *int   `json:"since"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.SessionID) == "" {
			return mcpArgError(fmt.Errorf("session_id is required")), nil
		}
		since := 0
		if in.Since != nil {
			since = *in.Since
		}
		s, err := chatClientFor(ctx).GetChatSession(in.SessionID, since)
		if err != nil {
			return mcpTextError(fmt.Sprintf("chat_read_tail: %v", err)), nil
		}
		return mcpChatResult(s), nil
	})

	// chat_wait_for_state — hybrid resumable wait on the fleet SSE (D76h). A
	// read: it holds one bounded stream and writes nothing.
	srv.AddTool(&mcp.Tool{
		Name:        "chat_wait_for_state",
		Title:       "Wait for a chat session to settle or block",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true},
		Description: "Block (bounded) until a chat session SETTLES (agent_state \"idle\" — its turn finished) or NEEDS YOU (\"blocked\" — a pending approval/question), observed from the workspace fleet stream — never polled. If the session is ALREADY idle or blocked when you call, this resolves instantly from the stream snapshot. ARM A CURSOR BEFORE THE TURN YOU MEAN TO AWAIT: a fresh session is idle until its first turn actually boots, so a cursor-LESS wait fired right after chat_send resolves instantly \"idle\" off that pre-boot snapshot — the turn you just kicked off hasn't started, and you've been fooled into reading a stale transcript. The mandatory pattern: call this ONCE first to capture a cursor (it returns instantly with the current-state snapshot plus a cursor), THEN chat_send, THEN re-call with that cursor — the server replays only the flips AFTER the cursor, so you wait for the real settle instead of the snapshot you already had. The block is bounded: default 30 seconds, tunable via timeout_seconds up to a hard cap of 50. Reaching the bound is a VALID OUTCOME, not an error: you get {resolved:false, last_state, cursor} — re-call with that cursor and the server replays any state flips you missed between calls, so a long-running turn is a sequence of cheap bounded waits, never one long block. A session outside your workspace scope never appears on your fleet stream, so waiting on a foreign id simply times out with last_state \"unknown\" (fail-closed tenancy). After it resolves, chat_read_tail for the transcript.",
		InputSchema: json.RawMessage(`{
  "type": "object",
  "additionalProperties": false,
  "required": ["session_id"],
  "properties": {
    "session_id": {
      "type": "string",
      "description": "The chat session id to watch."
    },
    "timeout_seconds": {
      "type": "integer",
      "minimum": 1,
      "maximum": 50,
      "description": "How long to block before returning {resolved:false, cursor} — default 30, hard cap 50."
    },
    "cursor": {
      "type": "string",
      "description": "Opaque resume cursor from a previous unresolved wait — pass it back VERBATIM so flips between calls are replayed, never missed."
    }
  }
}`),
	}, func(callCtx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var in struct {
			SessionID      string `json:"session_id"`
			TimeoutSeconds *int   `json:"timeout_seconds"`
			Cursor         string `json:"cursor"`
		}
		if err := decodeMCPArgs(req, &in); err != nil {
			return mcpArgError(err), nil
		}
		if strings.TrimSpace(in.SessionID) == "" {
			return mcpArgError(fmt.Errorf("session_id is required")), nil
		}
		timeout := chatWaitDefault
		if in.TimeoutSeconds != nil {
			timeout = time.Duration(*in.TimeoutSeconds) * time.Second
			if timeout < time.Second {
				timeout = time.Second
			}
			if timeout > chatWaitCap {
				timeout = chatWaitCap // hard cap — schema-declared, clamped as backstop
			}
		}
		return runChatWait(callCtx, chatClientFor(ctx), in.SessionID, in.Cursor, timeout), nil
	})
}

// errChatWaitResolved is the internal stop sentinel runChatWait's onEvent
// returns when the watched session reaches a resolving state — the documented
// onEvent-error stop of FleetEvents, so the SSE tears down the moment the flip
// is seen instead of holding the stream for the rest of the bound.
var errChatWaitResolved = errors.New("chat wait resolved")

// fleetWireSession is the per-session shape shared by the fleet stream's
// event:snapshot rows and event:state flips: {session_id, agent_state, ts,
// title} (title unused here). Decoded tolerantly — an unknown future key never
// breaks the wait.
type fleetWireSession struct {
	SessionID  string `json:"session_id"`
	AgentState string `json:"agent_state"`
	Ts         string `json:"ts"`
}

// chatWaitResolves reports whether an observed agent_state resolves the wait:
// "idle" (the turn settled — `done` does not exist in the herd vocabulary) or
// "blocked" (needs the herder's attention). "working" keeps waiting; "unknown"
// (an errored/void state) also keeps waiting — it is surfaced honestly as
// last_state on the bound rather than dressed up as a resolution.
func chatWaitResolves(state string) bool {
	return state == "idle" || state == "blocked"
}

// runChatWait is the hybrid resumable wait (D76h): one bounded block sleeping on
// the fleet SSE. The stream's snapshot frame answers the already-settled case
// (kills the check-then-wait race); a matching state flip resolves via the
// onEvent-error stop; the bound (ctx timeout) returns IsError:false
// {resolved:false, last_state, cursor} so the caller re-calls with the cursor
// and the server replays exactly the missed flips. The cursor is observed via
// the nil-safe onCursor seam (FleetEventsWithCursor) so it advances only on
// id-bearing flips, pinned across id-less heartbeats. ctx cancellation (the MCP
// client abandoning the call) tears the SSE down promptly on both the read and
// the backoff-sleep paths and returns the same honest unresolved shape.
func runChatWait(ctx context.Context, cli *apiclient.Client, sessionID, cursor string, timeout time.Duration) *mcp.CallToolResult {
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// All mutated from FleetEvents' single dispatch goroutine — no lock needed.
	lastState := "unknown"
	lastTs := ""
	resolved := false
	cur := cursor

	observe := func(s fleetWireSession) error {
		if s.SessionID != sessionID {
			return nil
		}
		lastState, lastTs = s.AgentState, s.Ts
		if chatWaitResolves(s.AgentState) {
			resolved = true
			return errChatWaitResolved
		}
		return nil
	}

	err := cli.FleetEventsWithCursor(waitCtx, cursor, func(event, data string) error {
		switch event {
		case "snapshot":
			var snap struct {
				Sessions []fleetWireSession `json:"sessions"`
			}
			if json.Unmarshal([]byte(data), &snap) != nil {
				return nil // tolerant: a malformed frame never kills the wait
			}
			for _, s := range snap.Sessions {
				if err := observe(s); err != nil {
					return err
				}
			}
		case "state":
			var s fleetWireSession
			if json.Unmarshal([]byte(data), &s) != nil {
				return nil
			}
			return observe(s)
		}
		return nil // heartbeats and unknown events: liveness only
	}, nil, func(c string) { cur = c })

	if err != nil && !errors.Is(err, errChatWaitResolved) {
		// A real stream failure (e.g. the strict initial connect refused).
		return mcpTextError(fmt.Sprintf("chat_wait_for_state: %v", err))
	}

	if resolved {
		return mcpChatResult(map[string]any{
			"resolved":   true,
			"session_id": sessionID,
			"state":      lastState,
			"ts":         lastTs,
			"cursor":     cur,
		})
	}
	// The bound (or a client abandon) — a valid outcome, not an error (D76h):
	// hand back the honest last observation plus the resume cursor.
	return mcpChatResult(map[string]any{
		"resolved":   false,
		"session_id": sessionID,
		"last_state": lastState,
		"cursor":     cur,
	})
}

// mcpChatResult marshals v as the tool result's one text content block, clamped
// at the shared 48KB guard (the same last-resort byte cap mcpRun applies to
// every manifest-backed tool), with a chat-honest escape hatch in the notice —
// the only realistic overflow is a cold chat_read_tail, and its pager is
// `since`, not limit/task_show. IsError stays false: these are valid outcomes;
// failures go through mcpTextError at the call sites.
func mcpChatResult(v any) *mcp.CallToolResult {
	out, err := json.Marshal(v)
	if err != nil {
		return mcpTextError(fmt.Sprintf("encode result: %v", err))
	}
	text := clampMCPToolResultWithHint(string(out),
		"re-call chat_read_tail with since = the highest seq you already hold")
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
	}
}

// chatSpawnReceiptRefusal screens a chat_spawn_session 2xx receipt and returns
// the refusal result, or nil when the spawn is worth reporting as a success.
//
// TWO GATES, ONE FENCE. The first is the SHARED write fence itself — the same
// mcpPoisonedReceipt / writeReceiptVerdict / unreadableWriteReceipt chain every
// manifest-dispatched MCP write crosses via mcpRunFor
// (pds-bl-mcp-exec-bypasses-write-fence, PR #15900). chat_spawn_session is a
// hardcoded BUILT-IN (D74h), so it never reaches mcpRunFor; it calls the fence
// directly rather than growing a second copy of the "did the server say
// anything" discriminator.
//
// The second gate is the one thing the fence structurally CANNOT see: the fence
// is key-agnostic on purpose ("every object regardless of its keys passes"), so
// a receipt like {"ok":true} is honest to it and still carries no session id.
// This surface hands the model a SPAWNED AGENT it is told to address by id, and
// an empty id is a poisoned receipt for that promise specifically — so the
// field check lives here, next to the caller that acts on it, and names its own
// reason instead of pretending the shared discriminator produced it.
func chatSpawnReceiptRefusal(status int, raw []byte, sessionID string) *mcp.CallToolResult {
	if reason, hint := mcpPoisonedReceipt(status, raw, true); reason != "" {
		return mcpUnreadableResult("chat_spawn_session write receipt", status, raw, reason, hint)
	}
	if strings.TrimSpace(sessionID) == "" {
		return mcpUnreadableResult("chat_spawn_session write receipt", status, raw,
			"carried a receipt with no session id — nothing addressable was spawned",
			unreadableWriteReceiptHint)
	}
	return nil
}
