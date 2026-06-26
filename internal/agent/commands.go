package agent

import "fmt"

// Command is one queued command the control plane wants the agent to run. Only
// the Name is honoured — it must be one of the six allowlisted keys. There is
// NO free-form argv on the wire: the control plane names an approved action, the
// agent maps that name to a fixed argv locally. This is the security boundary —
// the control plane cannot inject arbitrary input, only pick from the six.
type Command struct {
	// ID is the queue id, echoed back in the CommandResult so the control plane
	// can correlate.
	ID string `json:"id"`
	// Name is the approved action key (see allowlist). Anything not in the
	// allowlist is REJECTED, not run.
	Name string `json:"name"`
}

// CommandResult is the outcome of one command attempt, POSTed back so the queue
// can mark it done/failed/rejected.
type CommandResult struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Approved bool   `json:"approved"`
	Output   string `json:"output"`
	Err      string `json:"error,omitempty"`
}

// allowlist is the ONLY set of commands the agent will ever run. Each approved
// key maps to a fixed argv resolved on-box — the control plane never supplies
// argv, it names one of these keys. Adding a key is a deliberate, reviewable
// change here; nothing else can grow the surface. This map IS the security
// policy.
//
// The six approved actions and their on-box argv:
//
//	restart → systemctl restart barkpark
//	rebuild → make -C /opt/barkpark rebuild
//	backup  → make -C /opt/barkpark backup
//	update  → make -C /opt/barkpark deploy
//	doctor  → make -C /opt/barkpark doctor
//	logs    → journalctl -u barkpark --no-pager -n 200
var allowlist = map[string][]string{
	"restart": {"systemctl", "restart", "barkpark"},
	"rebuild": {"make", "-C", "/opt/barkpark", "rebuild"},
	"backup":  {"make", "-C", "/opt/barkpark", "backup"},
	"update":  {"make", "-C", "/opt/barkpark", "deploy"},
	"doctor":  {"make", "-C", "/opt/barkpark", "doctor"},
	"logs":    {"journalctl", "-u", "barkpark", "--no-pager", "-n", "200"},
}

// AllowedCommands returns the sorted set of approved command names — the
// complete, fixed surface. Exposed for `bp agent` and tests to assert the exact
// six without reaching into the private map.
func AllowedCommands() []string {
	return []string{"backup", "doctor", "logs", "rebuild", "restart", "update"}
}

// IsApproved reports whether name is on the allowlist. The single source of
// truth both the runner and any caller consult before touching a command.
func IsApproved(name string) bool {
	_, ok := allowlist[name]
	return ok
}

// runCommand resolves cmd against the allowlist and runs it via the injected
// runner. A non-allowlisted name is REJECTED outright — the runner is never
// invoked, so an attacker-supplied "rm -rf" / "curl … | sh" can never execute,
// even if it reached the queue. The returned CommandResult carries Approved so
// the control plane sees the rejection explicitly.
func runCommand(runner CommandRunner, cmd Command) CommandResult {
	res := CommandResult{ID: cmd.ID, Name: cmd.Name}

	argv, ok := allowlist[cmd.Name]
	if !ok {
		// SECURITY: reject. Do NOT shell out. Do NOT echo the rejected name into
		// any argv. The agent runs only the six approved actions.
		res.Approved = false
		res.Err = fmt.Sprintf("rejected: %q is not an approved command (allowed: %v)", cmd.Name, AllowedCommands())
		return res
	}

	res.Approved = true
	out, err := runner.Run(argv[0], argv[1:]...)
	res.Output = out
	if err != nil {
		res.Err = err.Error()
	}
	return res
}
