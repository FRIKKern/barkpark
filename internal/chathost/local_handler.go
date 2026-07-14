package chathost

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type LocalHandler struct {
	ApprovedRoots []string
}

func (h LocalHandler) Handle(ctx context.Context, remote RemoteCommand, emit func(map[string]any) error) error {
	provider, _ := remote.Command["provider"].(string)
	operation, _ := remote.Command["operation"].(string)
	payload, _ := remote.Command["payload"].(map[string]any)
	cwd, _ := payload["cwd"].(string)
	content := textContent(payload["content"])
	if operation != "send_turn" {
		return fmt.Errorf("unsupported registered-host operation %q", operation)
	}
	if cwd == "" || content == "" {
		return fmt.Errorf("command requires cwd and content")
	}
	resolved, err := ResolveApprovedPath(h.ApprovedRoots, cwd)
	if err != nil {
		return err
	}
	if provider == "codex" {
		return runCodex(ctx, resolved, content, remote, emit)
	}
	switch provider {
	case "claude":
		return runClaude(ctx, resolved, content, remote, emit)
	default:
		return fmt.Errorf("unsupported provider %q", provider)
	}
}

func runClaude(ctx context.Context, cwd, content string, remote RemoteCommand, emit func(map[string]any) error) error {
	providerSessionID, _ := remote.Command["provider_session_id"].(string)
	args := []string{"-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages"}
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

	cmd := exec.CommandContext(ctx, "claude", args...)
	cmd.Dir = cwd
	cmd.Env = providerEnv()
	cmd.Stdin = strings.NewReader(content)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var message map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			return fmt.Errorf("decode claude JSONL: %w", err)
		}
		if event := claudeEvent(message); event != nil {
			if err := emit(event); err != nil {
				return err
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("claude: %w: %s", err, strings.TrimSpace(stderr.String()))
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

func runCodex(ctx context.Context, cwd, content string, remote RemoteCommand, emit func(map[string]any) error) error {
	providerSessionID, _ := remote.Command["provider_session_id"].(string)
	args := []string{"exec", "--json", "--sandbox", "workspace-write"}
	if providerSessionID == "" {
		args = append(args, "-")
	} else {
		args = append(args, "resume", "--json", providerSessionID, "-")
	}

	cmd := exec.CommandContext(ctx, "codex", args...)
	cmd.Dir = cwd
	cmd.Env = providerEnv()
	cmd.Stdin = strings.NewReader(content)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var message map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			return fmt.Errorf("decode codex JSONL: %w", err)
		}
		if event := codexEvent(message); event != nil {
			if err := emit(event); err != nil {
				return err
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("codex exec: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
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

func providerEnv() []string {
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
	return env
}
