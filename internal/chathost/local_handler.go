package chathost

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

type LocalHandler struct {
	ApprovedRoots []string
}

func (h LocalHandler) Handle(ctx context.Context, remote RemoteCommand, emit func(map[string]any) error) error {
	provider, _ := remote.Command["provider"].(string)
	payload, _ := remote.Command["payload"].(map[string]any)
	cwd, _ := payload["cwd"].(string)
	content, _ := payload["content"].(string)
	if cwd == "" || content == "" {
		return fmt.Errorf("command requires cwd and content")
	}
	resolved, err := ResolveApprovedPath(h.ApprovedRoots, cwd)
	if err != nil {
		return err
	}

	var name string
	var args []string
	switch provider {
	case "claude":
		name, args = "claude", []string{"-p", "--output-format", "json"}
	case "codex":
		name, args = "codex", []string{"exec", "--json", "-"}
	default:
		return fmt.Errorf("unsupported provider %q", provider)
	}
	if err := emit(map[string]any{"kind": "started"}); err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = resolved
	cmd.Stdin = strings.NewReader(content)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("provider process: %w", err)
	}
	return emit(map[string]any{
		"kind":           "terminal",
		"terminal_state": "completed",
		"output":         string(output),
	})
}
