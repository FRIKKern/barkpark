package chathost

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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
		return emit(map[string]any{"kind": "control_completed", "operation": operation})
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

	var name string
	var args []string
	switch provider {
	case "claude":
		name, args = "claude", []string{"-p", "--output-format", "json"}
	default:
		return fmt.Errorf("unsupported provider %q", provider)
	}
	if err := emit(map[string]any{"kind": "turn_started"}); err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = resolved
	cmd.Stdin = strings.NewReader(content)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("provider process: %w", err)
	}
	if err := emit(map[string]any{"kind": "text_delta", "delta": string(output)}); err != nil {
		return err
	}
	return emit(map[string]any{
		"kind":           "turn_completed",
		"terminal_state": "completed",
	})
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
	case "item.completed":
		item, _ := message["item"].(map[string]any)
		if item["type"] == "agent_message" {
			if text, ok := item["text"].(string); ok && text != "" {
				return map[string]any{"kind": "text_delta", "delta": text}
			}
		}
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
