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

// authReady reports whether a provider CLI holds a usable credential, from the
// output and exit error of its status probe.
//
// claude declares the fact structurally — `claude auth status --json` emits a
// `loggedIn` boolean — so that branch reads the boolean and nothing else.
//
// codex has no --json on `codex login status`, but it does have TWO structural
// signals, and both are used here:
//
//   - The exit status. Measured on codex-cli 0.149.0: 0 when a credential is
//     present, 1 when none is. That is the primary gate (err != nil below).
//   - The status LINE, tested for the affirmative form ANCHORED AT THE LINE
//     START. This used to be an unanchored strings.Contains for "logged in",
//     which is the bug this shape exists to prevent: codex's negative status
//     line is the literal string "Not logged in", and it CONTAINS "logged in".
//     The unanchored test therefore read the CLI's own NO as a YES, and the
//     only thing standing between that and a wrong answer was the exit status
//     already checked one line above — so it contributed no correct answer and
//     one specific wrong one. A codex build, wrapper, or shim that reports the
//     negative on a zero exit would be advertised to the control plane as
//     auth_ready:true, and the server would dispatch turns to a host that
//     cannot run them.
//
// The anchor is PER LINE, not over the whole output, and that is load-bearing:
// the probe uses CombinedOutput, so stderr is merged in, and `codex login
// status` was measured emitting a "WARNING: proceeding, …" line AHEAD of its
// status line. Anchoring the whole output would fail closed on a real,
// authenticated host.
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
	// Every affirmative codex ships reads "Logged in using <method>" (ChatGPT,
	// workload identity, access token, personal access token, Amazon Bedrock
	// API key, an API key); the sole negative reads "Not logged in".
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(line)), "logged in") {
			return true
		}
	}
	return false
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
