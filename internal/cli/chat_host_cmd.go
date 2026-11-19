package cli

// chat_host_cmd.go — `bp chat-host list|enroll|new-code|revoke`: register the
// machines that run a workspace's chat turns (/papers/chat-host-enrollment-overhaul).
//
// Enrolling a machine is the workspace owner's decision, so `enroll` and
// `new-code` need the owner's token; the server refuses any other with 403 and
// bp says so in plain words. `revoke` takes an owner or admin token. A code is
// printed once, by `enroll` or `new-code`, to the owner who asked for it.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const chatHostUsage = `usage: bp chat-host <verb>
  list                              the workspace's chat hosts and their state
  enroll --name <n> --root <path>   make a one-time code and print the command to run on the machine
  new-code <name|id>                replace a waiting machine's code (the old code stops working)
  revoke <name|id>                  remove a machine; it can no longer run turns
  add --ssh <user@host> --name <n> --root <path>
                                    register a machine you can ssh to, in one step: the code
                                    goes to its enroll on ssh's stdin and is never shown
                                    (--bin <path> if barkpark-chat-host is not on its PATH,
                                    --state <file> for the credential file)

enroll, new-code and add need the workspace owner's token. The code lasts 10 minutes.`

// chatHost is one row of GET /w/:ws/v1/chat-hosts.
type chatHost struct {
	ID                  string         `json:"id"`
	Name                string         `json:"name"`
	Enrolled            bool           `json:"enrolled"`
	Online              bool           `json:"online"`
	ApprovedRoots       []string       `json:"approved_roots"`
	LastSeenAt          string         `json:"last_seen_at"`
	EnrollmentExpiresAt string         `json:"enrollment_expires_at"`
	Capabilities        map[string]any `json:"capabilities"`
}

// chatHostCode is the answer to a mint: the host row and its one-time code.
type chatHostCode struct {
	Host           chatHost `json:"host"`
	EnrollmentCode string   `json:"enrollment_token"`
}

func runChatHost(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help || len(args) == 0 {
		out.outf("%s", chatHostUsage)
		if len(args) == 0 && !g.help {
			return exitUsage
		}
		return exitOK
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "list", "ls":
		return runChatHostList(out, ctx, rest)
	case "enroll":
		return runChatHostEnroll(out, ctx, rest)
	case "new-code":
		return runChatHostNewCode(out, ctx, rest)
	case "revoke":
		return runChatHostRevoke(out, ctx, rest)
	case "add":
		return runChatHostAdd(out, ctx, rest)
	}
	return usageErrf(out, func() { out.errf("%s", chatHostUsage) }, "unknown chat-host verb %q", verb)
}

func chatHostsURL(ctx manifest.Context, suffix string) string {
	ws := ctx.Workspace
	if ws == "" {
		ws = "default"
	}
	return strings.TrimRight(ctx.Server, "/") + "/w/" + url.PathEscape(ws) + "/v1/chat-hosts" + suffix
}

func runChatHostList(out *writer, ctx manifest.Context, args []string) int {
	if len(args) > 0 {
		return usageErrf(out, nil, "bp chat-host list takes no arguments (got %q)", args[0])
	}
	hosts, raw, rc := fetchChatHosts(out, ctx, "list")
	if rc != exitOK {
		return rc
	}
	var generic map[string]any
	if json.Unmarshal(raw, &generic) == nil && out.emitStructured(generic) {
		return exitOK
	}
	if len(hosts) == 0 {
		out.outf("No chat hosts in workspace %s. Register one: bp chat-host enroll --name <name> --root <folder>", workspaceName(ctx))
		return exitOK
	}
	now := time.Now()
	for _, h := range hosts {
		out.outf("%-24s %-30s %s", h.Name, chatHostState(h, now), h.ID)
		for _, line := range chatHostCapabilityLines(h.Capabilities) {
			out.outf("  %s", line)
		}
	}
	return exitOK
}

func fetchChatHosts(out *writer, ctx manifest.Context, what string) ([]chatHost, []byte, int) {
	status, body, err := doRequest("GET", chatHostsURL(ctx, ""), ctxAuthHeaders(ctx), nil)
	if err != nil {
		out.userErr("chat-host %s: %v", what, err)
		return nil, nil, exitGeneric
	}
	if status != 200 {
		return nil, nil, chatHostRefused(out, ctx, what, status, body)
	}
	var page struct {
		Hosts []chatHost `json:"hosts"`
	}
	if json.Unmarshal(body, &page) != nil {
		out.userErr("chat-host %s: the server's answer was not a host list (HTTP %d)", what, status)
		return nil, nil, exitGeneric
	}
	sort.Slice(page.Hosts, func(i, j int) bool { return page.Hosts[i].Name < page.Hosts[j].Name })
	return page.Hosts, body, exitOK
}

// chatHostState is the one-phrase state a person reads: waiting (with time
// left), code expired, online, or offline (with last seen).
func chatHostState(h chatHost, now time.Time) string {
	if !h.Enrolled {
		expires, err := time.Parse(time.RFC3339, h.EnrollmentExpiresAt)
		if err != nil {
			return "waiting to enroll"
		}
		if !expires.After(now) {
			return "code expired"
		}
		return "waiting, code expires in " + roughDuration(expires.Sub(now))
	}
	if h.Online {
		return "online"
	}
	seen, err := time.Parse(time.RFC3339, h.LastSeenAt)
	if err != nil {
		return "offline"
	}
	return "offline, last seen " + roughDuration(now.Sub(seen)) + " ago"
}

func roughDuration(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "under a minute"
	case d < time.Hour:
		return fmt.Sprintf("%d min", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%d h", int(d.Hours()))
	}
	return fmt.Sprintf("%d days", int(d.Hours()/24))
}

// chatHostCapabilityLines reads a host's providers as "Claude: signed in ·
// 2.1.328", "Claude: installed, not signed in" or "Codex: not installed".
func chatHostCapabilityLines(capabilities map[string]any) []string {
	providers, _ := capabilities["providers"].(map[string]any)
	names := make([]string, 0, len(providers))
	for name := range providers {
		names = append(names, name)
	}
	sort.Strings(names)
	lines := make([]string, 0, len(names))
	for _, name := range names {
		p, _ := providers[name].(map[string]any)
		label := strings.ToUpper(name[:1]) + name[1:]
		installed, _ := p["installed"].(bool)
		signedIn, _ := p["auth_ready"].(bool)
		version, _ := p["version"].(string)
		switch {
		case !installed:
			lines = append(lines, label+": not installed")
		case signedIn:
			lines = append(lines, strings.TrimSuffix(label+": signed in · "+version, " · "))
		default:
			lines = append(lines, strings.TrimSuffix(label+": installed, not signed in · "+version, " · "))
		}
	}
	return lines
}

type chatHostEnrollFlags struct {
	name, ssh, bin, state string
	roots                 []string
}

func parseChatHostFlags(args []string, allowSSH bool) (chatHostEnrollFlags, error) {
	f := chatHostEnrollFlags{bin: "barkpark-chat-host"}
	for i := 0; i < len(args); i++ {
		key, inline, hasInline := splitFlagToken(args[i])
		var target *string
		switch key {
		case "--name":
			target = &f.name
		case "--root":
			v, ni, err := flagValue(args, i, inline, hasInline, key)
			if err != nil {
				return f, err
			}
			f.roots = append(f.roots, v)
			i = ni - 1
			continue
		case "--ssh", "--bin", "--state":
			if !allowSSH {
				return f, fmt.Errorf("%s is a flag of bp chat-host add", key)
			}
			target = map[string]*string{"--ssh": &f.ssh, "--bin": &f.bin, "--state": &f.state}[key]
		default:
			return f, fmt.Errorf("unknown argument %q", args[i])
		}
		v, ni, err := flagValue(args, i, inline, hasInline, key)
		if err != nil {
			return f, err
		}
		*target = v
		i = ni - 1
	}
	if strings.TrimSpace(f.name) == "" || len(f.roots) == 0 {
		return f, fmt.Errorf("needs --name <name> and --root <absolute folder on the machine>")
	}
	for _, root := range f.roots {
		if !strings.HasPrefix(root, "/") {
			return f, fmt.Errorf("--root %q must be an absolute path on the machine", root)
		}
	}
	return f, nil
}

func runChatHostEnroll(out *writer, ctx manifest.Context, args []string) int {
	f, err := parseChatHostFlags(args, false)
	if err != nil {
		return usageErrf(out, nil, "bp chat-host enroll %v", err)
	}
	minted, raw, rc := mintChatHostCode(out, ctx, "enroll", "", f)
	if rc != exitOK {
		return rc
	}
	return printChatHostCode(out, ctx, minted, raw, f.roots)
}

func runChatHostNewCode(out *writer, ctx manifest.Context, args []string) int {
	if len(args) != 1 || strings.HasPrefix(args[0], "-") {
		return usageErrf(out, nil, "bp chat-host new-code needs one host name or id")
	}
	host, rc := resolveChatHost(out, ctx, "new-code", args[0])
	if rc != exitOK {
		return rc
	}
	if host.Enrolled {
		return useError(out, "already_enrolled", fmt.Sprintf(
			"%s is already enrolled, so it needs no code. To move it to another machine, revoke it and enroll again.", host.Name), exitUsage)
	}
	minted, raw, rc := mintChatHostCode(out, ctx, "new-code", "/"+url.PathEscape(host.ID)+"/enrollment", chatHostEnrollFlags{})
	if rc != exitOK {
		return rc
	}
	return printChatHostCode(out, ctx, minted, raw, minted.Host.ApprovedRoots)
}

func runChatHostRevoke(out *writer, ctx manifest.Context, args []string) int {
	if len(args) != 1 || strings.HasPrefix(args[0], "-") {
		return usageErrf(out, nil, "bp chat-host revoke needs one host name or id")
	}
	host, rc := resolveChatHost(out, ctx, "revoke", args[0])
	if rc != exitOK {
		return rc
	}
	status, body, err := chatHostDelete(ctx, "/"+url.PathEscape(host.ID))
	if err != nil {
		out.userErr("chat-host revoke: %v", err)
		return exitGeneric
	}
	if status != 200 {
		return chatHostRefused(out, ctx, "revoke", status, body)
	}
	var answer struct {
		Host struct {
			ID      string `json:"id"`
			Revoked bool   `json:"revoked"`
		} `json:"host"`
	}
	if json.Unmarshal(body, &answer) != nil || answer.Host.ID != host.ID || !answer.Host.Revoked {
		out.userErr("chat-host revoke: the server answered HTTP %d without the revoked host; run bp chat-host list to check", status)
		return exitGeneric
	}
	var generic map[string]any
	if json.Unmarshal(body, &generic) == nil && out.emitStructured(generic) {
		return exitOK
	}
	out.outf("Revoked %s. It can no longer run turns; its running turns were cancelled.", host.Name)
	return exitOK
}

// resolveChatHost finds a live host by exact name or id.
func resolveChatHost(out *writer, ctx manifest.Context, what, ref string) (chatHost, int) {
	hosts, _, rc := fetchChatHosts(out, ctx, what)
	if rc != exitOK {
		return chatHost{}, rc
	}
	for _, h := range hosts {
		if h.ID == ref || h.Name == ref {
			return h, exitOK
		}
	}
	return chatHost{}, useError(out, "not_found",
		fmt.Sprintf("no chat host named %q in workspace %s; bp chat-host list shows them", ref, workspaceName(ctx)), exitGeneric)
}

// mintChatHostCode asks for a code: a new host (suffix "") or a new code for a
// waiting one. The answer must carry the host id and the code, or nothing is
// reported as made.
func mintChatHostCode(out *writer, ctx manifest.Context, what, suffix string, f chatHostEnrollFlags) (chatHostCode, []byte, int) {
	var payload []byte
	if suffix == "" {
		payload, _ = json.Marshal(map[string]any{"name": f.name, "approved_roots": f.roots})
	}
	status, body, err := chatHostPost(ctx, "/enrollments", suffix, payload)
	if err != nil {
		out.userErr("chat-host %s: %v", what, err)
		return chatHostCode{}, nil, exitGeneric
	}
	if status != 201 {
		return chatHostCode{}, nil, chatHostRefused(out, ctx, what, status, body)
	}
	var minted chatHostCode
	if json.Unmarshal(body, &minted) != nil || minted.Host.ID == "" || minted.EnrollmentCode == "" {
		out.userErr("chat-host %s: the server answered HTTP %d without a host and a code; run bp chat-host list to check", what, status)
		return chatHostCode{}, nil, exitGeneric
	}
	return minted, body, exitOK
}

// chatHostPost is the one POST: /enrollments for a new host, or the given
// suffix (/:id/enrollment) for a new code.
func chatHostPost(ctx manifest.Context, create, suffix string, payload []byte) (int, []byte, error) {
	path := create
	if suffix != "" {
		path = suffix
	}
	headers := ctxAuthHeaders(ctx)
	headers["Content-Type"] = "application/json"
	if payload == nil {
		payload = []byte("{}")
	}
	return doRequest("POST", chatHostsURL(ctx, path), headers, payload)
}

func chatHostDelete(ctx manifest.Context, suffix string) (int, []byte, error) {
	return doRequest("DELETE", chatHostsURL(ctx, suffix), ctxAuthHeaders(ctx), nil)
}

// enrollCommand is what to run on the machine. The code goes on stdin, so it
// never sits in the machine's process list.
func enrollCommand(ctx manifest.Context, roots []string, code string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "printf '%%s\\n' %s | barkpark-chat-host enroll --url %s", shellQuote(code), shellQuote(strings.TrimRight(ctx.Server, "/")))
	for _, root := range roots {
		b.WriteString(" --root " + shellQuote(root))
	}
	return b.String()
}

func printChatHostCode(out *writer, ctx manifest.Context, minted chatHostCode, raw []byte, roots []string) int {
	command := enrollCommand(ctx, roots, minted.EnrollmentCode)
	var generic map[string]any
	if json.Unmarshal(raw, &generic) == nil {
		generic["command"] = command
		if out.emitStructured(generic) {
			return exitOK
		}
	}
	expires := "in 10 minutes"
	if t, err := time.Parse(time.RFC3339, minted.Host.EnrollmentExpiresAt); err == nil {
		expires = "at " + t.Local().Format("15:04") + " (" + roughDuration(time.Until(t)) + ")"
	}
	out.outf("Made a one-time code for %s. It expires %s and works once.", minted.Host.Name, expires)
	out.outf("")
	out.outf("Run this on the machine:")
	out.outf("")
	out.outf("  %s", command)
	out.outf("")
	out.outf("Then start the host there and keep it running: barkpark-chat-host run")
	out.outf("Lost the code? bp chat-host new-code %s makes a new one and stops this one.", shellQuote(minted.Host.Name))
	return exitOK
}

// chatHostRefused turns the server's refusal into a sentence that says what
// to do.
func chatHostRefused(out *writer, ctx manifest.Context, what string, status int, body []byte) int {
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &envelope)
	code, message := envelope.Error.Code, strings.TrimSpace(envelope.Error.Message)
	switch {
	case status == 401:
		return useError(out, "unauthorized",
			"bp chat-host "+what+": the server did not accept your token. Sign in again (bp login) or pass --token.", exitAuth)
	case status == 403 && (what == "enroll" || what == "new-code" || what == "add"):
		return useError(out, "forbidden", fmt.Sprintf(
			"bp chat-host %s: this needs the workspace owner's token. Only the owner of workspace %s can register a machine; run it with the owner's token (--token, or bp login as the owner).",
			what, workspaceName(ctx)), exitAuth)
	case status == 403:
		return useError(out, "forbidden", fmt.Sprintf(
			"bp chat-host %s: this needs a token of an owner or admin of workspace %s.", what, workspaceName(ctx)), exitAuth)
	case status == 404 && code != "not_found":
		return useError(out, "not_found", fmt.Sprintf(
			"bp chat-host %s: this server has no chat hosts for workspace %s (Studio Chat is off, or the workspace does not exist).",
			what, workspaceName(ctx)), exitGeneric)
	case code == "name_taken":
		return useError(out, code, message+" (bp chat-host new-code <name>)", exitGeneric)
	case message != "":
		return useError(out, chatHostErrorCode(code), "bp chat-host "+what+": "+message, exitGeneric)
	}
	return useError(out, "http_error", fmt.Sprintf("bp chat-host %s: the server answered HTTP %d", what, status), exitGeneric)
}

func chatHostErrorCode(code string) string {
	if code == "" {
		return "http_error"
	}
	return code
}

func workspaceName(ctx manifest.Context) string {
	if ctx.Workspace == "" {
		return "default"
	}
	return ctx.Workspace
}

// shellQuote quotes s for a POSIX shell: single quotes, with each ' as '\”.
func shellQuote(s string) string {
	if s != "" && strings.Trim(s, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@=") == "" {
		return s
	}
	var b bytes.Buffer
	b.WriteByte('\'')
	b.WriteString(strings.ReplaceAll(s, "'", `'\''`))
	b.WriteByte('\'')
	return b.String()
}
