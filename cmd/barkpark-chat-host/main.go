package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/FRIKKern/barkpark/internal/chathost"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: barkpark-chat-host <enroll|run>")
	}
	stateDefault := filepath.Join(userHome(), ".config", "barkpark", "chat-host.json")

	switch os.Args[1] {
	case "enroll":
		flags := flag.NewFlagSet("enroll", flag.ExitOnError)
		server := flags.String("url", "", "Barkpark server URL")
		token := flags.String("token", "", "one-time enrollment token")
		root := flags.String("root", "", "absolute approved root")
		allowHTTP := flags.Bool("allow-http-loopback", false, "allow plaintext HTTP only for a loopback development server")
		statePath := flags.String("state", stateDefault, "credential state path")
		_ = flags.Parse(os.Args[2:])
		if *server == "" || *token == "" || *root == "" {
			fatal("enroll requires --url, --token, and --root")
		}
		client := &chathost.Client{BaseURL: *server, AllowInsecureLoopback: *allowHTTP}
		result, err := client.Enroll(context.Background(), *token, []string{*root}, capabilities())
		if err != nil {
			fatal(err.Error())
		}
		if err := chathost.SaveState(*statePath, chathost.State{ServerURL: *server, Credential: result.Credential, Host: result.Host, AllowInsecureLoopback: *allowHTTP}); err != nil {
			fatal(err.Error())
		}
		fmt.Printf("enrolled host %s (%s)\n", result.Host.Name, result.Host.ID)

	case "run":
		flags := flag.NewFlagSet("run", flag.ExitOnError)
		statePath := flags.String("state", stateDefault, "credential state path")
		_ = flags.Parse(os.Args[2:])
		state, err := chathost.LoadState(*statePath)
		if err != nil {
			fatal(err.Error())
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		runner := &chathost.Runner{
			Client:       &chathost.Client{BaseURL: state.ServerURL, Credential: state.Credential, AllowInsecureLoopback: state.AllowInsecureLoopback},
			Handler:      chathost.NewLocalHandler(state.Host.ApprovedRoots),
			Capabilities: capabilities(),
		}
		if err := runner.Run(ctx); err != nil && ctx.Err() == nil {
			fatal(err.Error())
		}

	default:
		fatal("unknown command: " + os.Args[1])
	}
}

func capabilities() map[string]any {
	providers := map[string]any{}
	_, taskHandsErr := exec.LookPath("bp")
	taskHandsReady := taskHandsErr == nil
	for _, name := range []string{"claude", "codex"} {
		path, err := exec.LookPath(name)
		metadata := map[string]any{
			"installed":  err == nil,
			"auth_ready": false,
			"operations": []string{"send_turn", "steer", "interrupt", "answer_approval", "close"},
			"task_hands": taskHandsReady,
		}
		if err == nil {
			if output, versionErr := exec.Command(path, "--version").Output(); versionErr == nil {
				metadata["version"] = strings.TrimSpace(string(output))
			}
			var authOutput []byte
			var authErr error
			if name == "claude" {
				authOutput, authErr = exec.Command(path, "auth", "status", "--json").CombinedOutput()
			} else {
				authOutput, authErr = exec.Command(path, "login", "status").CombinedOutput()
			}
			metadata["auth_ready"] = authReady(name, authOutput, authErr)
		}
		providers[name] = metadata
	}
	return map[string]any{
		"protocol_version": 1,
		"chat_runtime":     map[string]any{"protocol": "bidirectional-v2"},
		"providers":        providers,
	}
}

func authReady(provider string, output []byte, err error) bool {
	if err != nil {
		return false
	}
	if provider == "claude" {
		var status struct {
			LoggedIn bool `json:"loggedIn"`
		}
		return json.Unmarshal(output, &status) == nil && status.LoggedIn
	}
	return strings.Contains(strings.ToLower(string(output)), "logged in")
}

func userHome() string {
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err.Error())
	}
	return home
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, "barkpark-chat-host:", message)
	os.Exit(1)
}
