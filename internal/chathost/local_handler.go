package chathost

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type LocalHandler struct {
	ApprovedRoots []string

	mu       sync.Mutex
	sessions map[string]*activeLocalSession
}

type activeLocalSession struct {
	provider string
	stdin    io.WriteCloser
	cmd      *exec.Cmd

	mu        sync.Mutex
	threadID  string
	turnID    string
	approvals map[string]approvalRequest
	pending   map[string]chan map[string]any
	nextID    atomic.Uint64
}

type approvalRequest struct {
	id     any
	method string
	input  map[string]any
}

func NewLocalHandler(approvedRoots []string) *LocalHandler {
	return &LocalHandler{ApprovedRoots: approvedRoots, sessions: make(map[string]*activeLocalSession)}
}

func (h *LocalHandler) Handle(ctx context.Context, remote RemoteCommand, emit func(map[string]any) error) error {
	provider, _ := remote.Command["provider"].(string)
	operation, _ := remote.Command["operation"].(string)
	payload, _ := remote.Command["payload"].(map[string]any)
	sessionID, _ := remote.Command["session_id"].(string)

	if operation != "send_turn" {
		return h.handleControl(ctx, sessionID, operation, remote, emit)
	}

	cwd, _ := payload["cwd"].(string)
	content := textContent(payload["content"])
	if cwd == "" || content == "" {
		return fmt.Errorf("command requires cwd and content")
	}
	resolved, err := ResolveApprovedPath(h.ApprovedRoots, cwd)
	if err != nil {
		return err
	}
	if provider == "codex" {
		return h.runCodex(ctx, resolved, content, remote, emit)
	}
	switch provider {
	case "claude":
		return h.runClaude(ctx, resolved, content, remote, emit)
	default:
		return fmt.Errorf("unsupported provider %q", provider)
	}
}

func (h *LocalHandler) register(sessionID string, session *activeLocalSession) error {
	if sessionID == "" {
		return fmt.Errorf("command requires session_id")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.sessions == nil {
		h.sessions = make(map[string]*activeLocalSession)
	}
	if _, exists := h.sessions[sessionID]; exists {
		return fmt.Errorf("session %q already has an active turn", sessionID)
	}
	h.sessions[sessionID] = session
	return nil
}

func (h *LocalHandler) unregister(sessionID string, session *activeLocalSession) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.sessions[sessionID] == session {
		delete(h.sessions, sessionID)
	}
}

func (h *LocalHandler) active(sessionID string) *activeLocalSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessions[sessionID]
}

func (h *LocalHandler) handleControl(ctx context.Context, sessionID, operation string, remote RemoteCommand, emit func(map[string]any) error) error {
	session := h.active(sessionID)
	if session == nil {
		return fmt.Errorf("registered-host session %q has no active turn", sessionID)
	}
	if err := session.control(ctx, operation, remote.Command); err != nil {
		return err
	}
	return emit(map[string]any{"kind": "control_completed", "operation": operation})
}

func (h *LocalHandler) runClaude(ctx context.Context, cwd, content string, remote RemoteCommand, emit func(map[string]any) error) error {
	providerSessionID, _ := remote.Command["provider_session_id"].(string)
	sessionID, _ := remote.Command["session_id"].(string)
	payload, _ := remote.Command["payload"].(map[string]any)
	args := []string{
		"--print", "--verbose",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--include-partial-messages",
		"--permission-prompt-tool", "stdio",
	}
	mode, err := claudePermissionMode(payload)
	if err != nil {
		return err
	}
	args = append(args, "--permission-mode", mode)
	if model, ok := payload["model"].(string); ok && model != "" {
		args = append(args, "--model", model)
	}
	if effort, ok := payload["effort"].(string); ok && effort != "" {
		args = append(args, "--effort", effort)
	}
	if providerSessionID == "" {
		var err error
		providerSessionID, err = uuidV4()
		if err != nil {
			return fmt.Errorf("generate Claude session id: %w", err)
		}
		args = append(args, "--session-id", providerSessionID)
	} else {
		args = append(args, "--resume", providerSessionID)
	}
	mcpPath, cleanupMCP, err := writeClaudeMCPConfig(payload)
	if err != nil {
		return err
	}
	defer cleanupMCP()
	if mcpPath != "" {
		args = append(args, "--mcp-config", mcpPath, "--strict-mcp-config")
	}

	cmd := exec.CommandContext(ctx, "claude", args...)
	cmd.Dir = cwd
	cmd.Env = providerEnv(payload)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	session := newActiveLocalSession("claude", cmd, stdin)
	if err := h.register(sessionID, session); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	defer h.unregister(sessionID, session)

	if err := session.write(map[string]any{
		"type": "user",
		"message": map[string]any{
			"role":    "user",
			"content": []any{map[string]any{"type": "text", "text": content}},
		},
	}); err != nil {
		return err
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	terminal := false
	for scanner.Scan() {
		var message map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			return fmt.Errorf("decode claude JSONL: %w", err)
		}
		if event := session.claudeMessage(message); event != nil {
			if err := emit(event); err != nil {
				return err
			}
		}
		if message["type"] == "result" {
			terminal = true
			_ = stdin.Close()
			break
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	waitErr := cmd.Wait()
	if waitErr != nil && !terminal {
		return fmt.Errorf("claude: %w: %s", waitErr, strings.TrimSpace(stderr.String()))
	}
	if !terminal {
		return fmt.Errorf("claude exited before turn completion: %s", strings.TrimSpace(stderr.String()))
	}
	return nil
}

func claudeEvent(message map[string]any) map[string]any {
	typeName, _ := message["type"].(string)
	subtype, _ := message["subtype"].(string)
	switch typeName {
	case "system":
		if subtype == "init" {
			return map[string]any{"kind": "session_started", "provider_session_id": message["session_id"]}
		}
	case "stream_event":
		event, _ := message["event"].(map[string]any)
		if event["type"] == "message_start" {
			return map[string]any{"kind": "turn_started"}
		}
		if event["type"] == "content_block_delta" {
			delta, _ := event["delta"].(map[string]any)
			if delta["type"] == "text_delta" {
				if text, ok := delta["text"].(string); ok && text != "" {
					return map[string]any{"kind": "text_delta", "delta": text}
				}
			}
		}
	case "result":
		if isError, _ := message["is_error"].(bool); isError || subtype != "success" {
			return map[string]any{"kind": "error", "error": message, "terminal_state": "failed"}
		}
		return map[string]any{"kind": "turn_completed", "terminal_state": "completed"}
	}
	return nil
}

func uuidV4() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]), nil
}

func (h *LocalHandler) runCodex(ctx context.Context, cwd, content string, remote RemoteCommand, emit func(map[string]any) error) error {
	providerSessionID, _ := remote.Command["provider_session_id"].(string)
	sessionID, _ := remote.Command["session_id"].(string)
	payload, _ := remote.Command["payload"].(map[string]any)

	cmd := exec.CommandContext(ctx, "codex", "app-server", "--stdio")
	cmd.Dir = cwd
	cmd.Env = providerEnv(payload)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	session := newActiveLocalSession("codex", cmd, stdin)
	if err := h.register(sessionID, session); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	defer h.unregister(sessionID, session)

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	terminal := make(chan struct{})
	readErr := make(chan error, 1)
	go func() {
		for scanner.Scan() {
			var message map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
				readErr <- fmt.Errorf("decode codex JSONL: %w", err)
				return
			}
			event, done := session.codexMessage(message)
			if event != nil {
				if err := emit(event); err != nil {
					readErr <- err
					return
				}
			}
			if done {
				close(terminal)
				return
			}
		}
		if err := scanner.Err(); err != nil {
			readErr <- err
			return
		}
		readErr <- fmt.Errorf("codex app-server exited before turn completion")
	}()

	if _, err := session.request(ctx, "initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "barkpark-chat-host", "title": "Barkpark Chat Host", "version": "1"},
		"capabilities": map[string]any{"experimentalApi": false},
	}); err != nil {
		return err
	}
	if err := session.write(map[string]any{"method": "initialized"}); err != nil {
		return err
	}

	var threadResult map[string]any
	if providerSessionID == "" {
		params := map[string]any{
			"cwd": cwd, "approvalPolicy": "on-request", "sandbox": "workspace-write",
			"developerInstructions": payload["developer_instructions"],
		}
		putString(params, "model", payload["model"])
		if config := codexTaskConfig(payload); config != nil {
			params["config"] = config
		}
		threadResult, err = session.request(ctx, "thread/start", params)
	} else {
		threadResult, err = session.request(ctx, "thread/resume", map[string]any{
			"threadId": providerSessionID, "cwd": cwd,
			"developerInstructions": payload["developer_instructions"],
		})
	}
	if err != nil {
		return err
	}
	threadID := nestedString(threadResult, "thread", "id")
	if threadID == "" {
		threadID = providerSessionID
	}
	if threadID == "" {
		return fmt.Errorf("codex app-server returned no thread id")
	}
	session.setThreadID(threadID)

	turnParams := map[string]any{
		"threadId": threadID,
		"cwd":      cwd,
		"input":    []any{map[string]any{"type": "text", "text": content}},
	}
	putString(turnParams, "model", payload["model"])
	putString(turnParams, "effort", payload["effort"])
	turnResult, err := session.request(ctx, "turn/start", turnParams)
	if err != nil {
		return err
	}
	if turnID := nestedString(turnResult, "turn", "id"); turnID != "" {
		session.setTurnID(turnID)
	}

	select {
	case <-terminal:
		_ = stdin.Close()
	case err := <-readErr:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
	if err := cmd.Wait(); err != nil && ctx.Err() == nil {
		return fmt.Errorf("codex exec: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func claudePermissionMode(payload map[string]any) (string, error) {
	mode, _ := payload["mode"].(string)
	switch mode {
	case "", "default", "plan", "acceptEdits", "dontAsk":
		if mode == "" || mode == "default" {
			return "plan", nil
		}
		return mode, nil
	case "bypassPermissions":
		if armed, _ := payload["bypass_armed"].(bool); armed {
			return mode, nil
		}
		return "plan", nil
	default:
		return "", fmt.Errorf("unsupported Claude permission mode %q", mode)
	}
}

func putString(target map[string]any, key string, value any) {
	if text, ok := value.(string); ok && text != "" {
		target[key] = text
	}
}

func codexEvent(message map[string]any) map[string]any {
	switch message["type"] {
	case "thread.started":
		return map[string]any{
			"kind":                "session_started",
			"provider_session_id": message["thread_id"],
		}
	case "turn.started":
		return map[string]any{"kind": "turn_started"}
	case "turn.completed":
		return map[string]any{"kind": "turn_completed", "terminal_state": "completed"}
	case "turn.failed", "error":
		return map[string]any{"kind": "error", "error": message}
	case "item.started":
		item, _ := message["item"].(map[string]any)
		return map[string]any{"kind": "item_started", "item_id": item["id"], "item": item}
	case "item.completed":
		item, _ := message["item"].(map[string]any)
		if item["type"] == "agent_message" {
			if text, ok := item["text"].(string); ok && text != "" {
				return map[string]any{"kind": "text_delta", "delta": text}
			}
		}
		return map[string]any{"kind": "item_completed", "item_id": item["id"], "item": item}
	}
	return nil
}

func newActiveLocalSession(provider string, cmd *exec.Cmd, stdin io.WriteCloser) *activeLocalSession {
	session := &activeLocalSession{
		provider:  provider,
		cmd:       cmd,
		stdin:     stdin,
		approvals: make(map[string]approvalRequest),
		pending:   make(map[string]chan map[string]any),
	}
	session.nextID.Store(1000)
	return session
}

func (s *activeLocalSession) write(message map[string]any) error {
	line, err := json.Marshal(message)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stdin == nil {
		return fmt.Errorf("provider session is closed")
	}
	_, err = s.stdin.Write(append(line, '\n'))
	return err
}

func (s *activeLocalSession) request(ctx context.Context, method string, params map[string]any) (map[string]any, error) {
	id := s.nextID.Add(1)
	key := strconv.FormatUint(id, 10)
	response := make(chan map[string]any, 1)
	s.mu.Lock()
	s.pending[key] = response
	s.mu.Unlock()
	if err := s.write(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		s.removePending(key)
		return nil, err
	}
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case message := <-response:
		if failure, ok := message["error"]; ok && failure != nil {
			return nil, fmt.Errorf("%s: %v", method, failure)
		}
		result, _ := message["result"].(map[string]any)
		return result, nil
	case <-ctx.Done():
		s.removePending(key)
		return nil, ctx.Err()
	case <-timer.C:
		s.removePending(key)
		return nil, fmt.Errorf("%s timed out", method)
	}
}

func (s *activeLocalSession) removePending(key string) {
	s.mu.Lock()
	delete(s.pending, key)
	s.mu.Unlock()
}

func (s *activeLocalSession) deliver(message map[string]any) bool {
	id, ok := message["id"]
	if !ok {
		id, ok = message["request_id"]
		if !ok {
			return false
		}
	}
	key := fmt.Sprint(id)
	s.mu.Lock()
	response := s.pending[key]
	delete(s.pending, key)
	s.mu.Unlock()
	if response == nil {
		return false
	}
	response <- message
	return true
}

func (s *activeLocalSession) setThreadID(value string) {
	s.mu.Lock()
	s.threadID = value
	s.mu.Unlock()
}

func (s *activeLocalSession) setTurnID(value string) {
	s.mu.Lock()
	s.turnID = value
	s.mu.Unlock()
}

func (s *activeLocalSession) nativeIDs() (string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.threadID, s.turnID
}

func (s *activeLocalSession) control(ctx context.Context, operation string, command map[string]any) error {
	payload, _ := command["payload"].(map[string]any)
	switch s.provider {
	case "claude":
		return s.controlClaude(ctx, operation, command, payload)
	case "codex":
		return s.controlCodex(ctx, operation, command, payload)
	default:
		return fmt.Errorf("unsupported provider %q", s.provider)
	}
}

func (s *activeLocalSession) controlClaude(ctx context.Context, operation string, command, payload map[string]any) error {
	switch operation {
	case "steer":
		request := map[string]any{}
		if mode, ok := payload["mode"].(string); ok && mode != "" {
			request = map[string]any{"subtype": "set_permission_mode", "mode": mode}
		} else if model, ok := payload["model"].(string); ok && model != "" {
			request = map[string]any{"subtype": "set_model", "model": model}
		} else {
			return fmt.Errorf("Claude steer requires mode or model")
		}
		_, err := s.claudeControlRequest(ctx, request)
		return err
	case "interrupt":
		_, err := s.claudeControlRequest(ctx, map[string]any{"subtype": "interrupt"})
		return err
	case "answer_approval":
		approvalID := fmt.Sprint(command["approval_id"])
		s.mu.Lock()
		approval, ok := s.approvals[approvalID]
		if ok {
			delete(s.approvals, approvalID)
		}
		s.mu.Unlock()
		if !ok {
			return fmt.Errorf("unknown Claude approval %q", approvalID)
		}
		return s.write(map[string]any{
			"type": "control_response",
			"response": map[string]any{
				"subtype": "success", "request_id": approvalID,
				"response": claudeApprovalDecision(payload["decision"], approval.input),
			},
		})
	case "close":
		return s.close()
	default:
		return fmt.Errorf("unsupported registered-host operation %q", operation)
	}
}

func (s *activeLocalSession) claudeControlRequest(ctx context.Context, request map[string]any) (map[string]any, error) {
	id := fmt.Sprintf("bp-host-%d", s.nextID.Add(1))
	response := make(chan map[string]any, 1)
	s.mu.Lock()
	s.pending[id] = response
	s.mu.Unlock()
	if err := s.write(map[string]any{"type": "control_request", "request_id": id, "request": request}); err != nil {
		s.removePending(id)
		return nil, err
	}
	select {
	case message := <-response:
		return message, nil
	case <-ctx.Done():
		s.removePending(id)
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		s.removePending(id)
		return nil, fmt.Errorf("Claude control request timed out")
	}
}

func (s *activeLocalSession) controlCodex(ctx context.Context, operation string, command, payload map[string]any) error {
	threadID, turnID := s.nativeIDs()
	switch operation {
	case "steer":
		content := textContent(payload["content"])
		if content == "" {
			return fmt.Errorf("Codex steer requires content")
		}
		_, err := s.request(ctx, "turn/steer", map[string]any{
			"threadId": threadID, "expectedTurnId": turnID,
			"input": []any{map[string]any{"type": "text", "text": content}},
		})
		return err
	case "interrupt":
		_, err := s.request(ctx, "turn/interrupt", map[string]any{"threadId": threadID, "turnId": turnID})
		return err
	case "answer_approval":
		approvalID := fmt.Sprint(command["approval_id"])
		s.mu.Lock()
		approval, ok := s.approvals[approvalID]
		if ok {
			delete(s.approvals, approvalID)
		}
		s.mu.Unlock()
		if !ok {
			return fmt.Errorf("unknown Codex approval %q", approvalID)
		}
		result, failure := codexApprovalDecision(approval.method, payload["decision"])
		if failure != nil {
			return s.write(map[string]any{"id": approval.id, "error": failure})
		}
		return s.write(map[string]any{"id": approval.id, "result": result})
	case "close":
		return s.close()
	default:
		return fmt.Errorf("unsupported registered-host operation %q", operation)
	}
}

func (s *activeLocalSession) close() error {
	s.mu.Lock()
	stdin := s.stdin
	s.stdin = nil
	cmd := s.cmd
	s.mu.Unlock()
	if stdin != nil {
		_ = stdin.Close()
	}
	if cmd != nil && cmd.Process != nil {
		if err := cmd.Process.Kill(); err != nil && !strings.Contains(err.Error(), "process already finished") {
			return err
		}
	}
	return nil
}

func (s *activeLocalSession) claudeMessage(message map[string]any) map[string]any {
	if message["type"] == "control_response" {
		response, _ := message["response"].(map[string]any)
		if s.deliver(response) {
			return nil
		}
	}
	if message["type"] == "control_request" {
		request, _ := message["request"].(map[string]any)
		if request["subtype"] == "can_use_tool" {
			id := fmt.Sprint(message["request_id"])
			input, _ := request["input"].(map[string]any)
			s.mu.Lock()
			s.approvals[id] = approvalRequest{id: message["request_id"], method: "can_use_tool", input: input}
			s.mu.Unlock()
			return map[string]any{
				"kind": "approval_requested", "approval_id": id,
				"tool_name": request["tool_name"], "input": input, "title": request["title"],
			}
		}
	}
	return claudeEvent(message)
}

func (s *activeLocalSession) codexMessage(message map[string]any) (map[string]any, bool) {
	method, _ := message["method"].(string)
	if method == "" && s.deliver(message) {
		return nil, false
	}
	params, _ := message["params"].(map[string]any)
	if threadID, ok := params["threadId"].(string); ok && threadID != "" {
		s.setThreadID(threadID)
	}
	if turnID, ok := params["turnId"].(string); ok && turnID != "" {
		s.setTurnID(turnID)
	} else if turnID := nestedString(params, "turn", "id"); turnID != "" {
		s.setTurnID(turnID)
	}

	if isCodexApprovalMethod(method) {
		id := fmt.Sprint(message["id"])
		s.mu.Lock()
		s.approvals[id] = approvalRequest{id: message["id"], method: method, input: params}
		s.mu.Unlock()
		return map[string]any{
			"kind": "approval_requested", "approval_id": id,
			"provider_session_id": params["threadId"], "turn_id": params["turnId"],
			"item_id": params["itemId"], "method": method, "params": params,
		}, false
	}

	event := codexAppServerEvent(method, params)
	done := method == "turn/completed"
	return event, done
}

func claudeApprovalDecision(decision any, original map[string]any) map[string]any {
	kind, detail := normalizeApprovalDecision(decision)
	if kind == "allow" {
		updated := original
		if value, ok := detail.(map[string]any); ok {
			updated = value
		}
		return map[string]any{"behavior": "allow", "updatedInput": updated}
	}
	message, _ := detail.(string)
	if message == "" {
		message = "Denied in Barkpark Chat"
	}
	return map[string]any{"behavior": "deny", "message": message}
}

func codexApprovalDecision(method string, decision any) (map[string]any, map[string]any) {
	kind, _ := normalizeApprovalDecision(decision)
	value := "decline"
	if kind == "allow" {
		value = "accept"
	} else if kind == "allow_session" {
		value = "acceptForSession"
	} else if kind == "cancel" {
		value = "cancel"
	}
	if method == "item/permissions/requestApproval" {
		if value == "decline" || value == "cancel" {
			return nil, map[string]any{"code": -32001, "message": value}
		}
		return map[string]any{"permissions": value}, nil
	}
	return map[string]any{"decision": value}, nil
}

func normalizeApprovalDecision(decision any) (string, any) {
	switch value := decision.(type) {
	case string:
		switch value {
		case "allow", "accept":
			return "allow", nil
		case "allow_session", "acceptForSession":
			return "allow_session", nil
		case "cancel":
			return "cancel", nil
		default:
			return "deny", value
		}
	case map[string]any:
		kind, _ := value["kind"].(string)
		return kind, value["value"]
	case []any:
		if len(value) == 2 {
			kind, _ := value[0].(string)
			return kind, value[1]
		}
	}
	return "deny", nil
}

func isCodexApprovalMethod(method string) bool {
	return method == "item/commandExecution/requestApproval" ||
		method == "item/fileChange/requestApproval" ||
		method == "item/permissions/requestApproval"
}

func codexAppServerEvent(method string, params map[string]any) map[string]any {
	base := map[string]any{
		"provider_session_id": params["threadId"], "turn_id": params["turnId"],
		"item_id": params["itemId"], "method": method, "params": params,
	}
	switch method {
	case "thread/started":
		base["kind"] = "session_started"
		if id := nestedString(params, "thread", "id"); id != "" {
			base["provider_session_id"] = id
		}
	case "turn/started":
		base["kind"] = "turn_started"
	case "item/agentMessage/delta":
		base["kind"] = "text_delta"
		base["delta"] = params["delta"]
	case "item/started":
		base["kind"] = "item_started"
		base["item"] = params["item"]
		if id := nestedString(params, "item", "id"); id != "" {
			base["item_id"] = id
		}
	case "item/completed":
		base["kind"] = "item_completed"
		base["item"] = params["item"]
		if id := nestedString(params, "item", "id"); id != "" {
			base["item_id"] = id
		}
	case "turn/completed":
		base["kind"] = "turn_completed"
		status := nestedString(params, "turn", "status")
		if status == "" {
			status = "completed"
		}
		base["terminal_state"] = status
	case "error":
		base["kind"] = "error"
		base["error"] = params
	default:
		return nil
	}
	return base
}

func nestedString(value map[string]any, keys ...string) string {
	var current any = value
	for _, key := range keys {
		mapping, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current = mapping[key]
	}
	result, _ := current.(string)
	return result
}

func textContent(value any) string {
	switch content := value.(type) {
	case string:
		return content
	case []any:
		var parts []string
		for _, raw := range content {
			block, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if block["type"] == "text" {
				if text, ok := block["text"].(string); ok && text != "" {
					parts = append(parts, text)
				}
			}
		}
		return strings.Join(parts, "\n")
	default:
		return ""
	}
}

func providerEnv(payload map[string]any) []string {
	allowed := map[string]bool{
		"PATH": true, "HOME": true, "TMPDIR": true, "USER": true, "LOGNAME": true,
		"SHELL": true, "TERM": true, "LANG": true, "LC_ALL": true,
		"SSL_CERT_FILE": true, "SSL_CERT_DIR": true, "XDG_CONFIG_HOME": true,
		"CODEX_HOME": true, "CLAUDE_CONFIG_DIR": true,
	}
	var env []string
	for _, pair := range os.Environ() {
		key, _, _ := strings.Cut(pair, "=")
		if allowed[key] {
			env = append(env, pair)
		}
	}
	if taskEnv, ok := payload["task_env"].(map[string]any); ok {
		for _, key := range []string{"BARKPARK_API_TOKEN", "BARKPARK_API_URL", "BARKPARK_WORKER_ID"} {
			if value, ok := taskEnv[key].(string); ok && value != "" {
				env = append(env, key+"="+value)
			}
		}
	}
	return env
}

func codexTaskConfig(payload map[string]any) map[string]any {
	taskEnv, ok := payload["task_env"].(map[string]any)
	token, _ := taskEnv["BARKPARK_API_TOKEN"].(string)
	if !ok || !strings.HasPrefix(token, "bpcs_") {
		return nil
	}
	return map[string]any{
		"mcp_servers": map[string]any{
			"barkpark": map[string]any{
				"command": "bp",
				"args":    []any{"mcp", "serve", "--tools", "all"},
				"env_vars": []any{
					"BARKPARK_API_TOKEN", "BARKPARK_API_URL", "BARKPARK_WORKER_ID",
				},
				"required": true,
			},
		},
	}
}

func writeClaudeMCPConfig(payload map[string]any) (string, func(), error) {
	taskEnv, ok := payload["task_env"].(map[string]any)
	if !ok {
		return "", func() {}, nil
	}
	token, _ := taskEnv["BARKPARK_API_TOKEN"].(string)
	apiURL, _ := taskEnv["BARKPARK_API_URL"].(string)
	workerID, _ := taskEnv["BARKPARK_WORKER_ID"].(string)
	if !strings.HasPrefix(token, "bpcs_") || apiURL == "" {
		return "", func() {}, nil
	}
	file, err := os.CreateTemp("", "barkpark-chat-host-mcp-*.json")
	if err != nil {
		return "", func() {}, fmt.Errorf("create Claude MCP config: %w", err)
	}
	cleanup := func() { _ = os.Remove(file.Name()) }
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		cleanup()
		return "", func() {}, err
	}
	config := map[string]any{
		"mcpServers": map[string]any{
			"barkpark": map[string]any{
				"command": "bp", "args": []any{"mcp", "serve", "--tools", "all"},
				"env": map[string]any{
					"BARKPARK_API_TOKEN": token,
					"BARKPARK_API_URL":   apiURL,
					"BARKPARK_WORKER_ID": workerID,
				},
			},
		},
	}
	if err := json.NewEncoder(file).Encode(config); err != nil {
		_ = file.Close()
		cleanup()
		return "", func() {}, err
	}
	if err := file.Close(); err != nil {
		cleanup()
		return "", func() {}, err
	}
	return file.Name(), cleanup, nil
}
