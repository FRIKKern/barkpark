package cli

// instance_up_cmd.go is `bp instance up`: one command from an empty Azure
// resource group to an instance whose owner can sign in with Entra ID.
//
//	bp instance up --azure --path vm|containerapps --resource-group <rg>
//	               --owner <upn> [--host <dns label or host>] [--breakglass <email>]
//	               [--image <ref> | --from-source <git ref>] [--region <r>]
//
// It runs the steps docs/setup/SELF-HOST.md and docs/setup/ENTRA.md describe:
// preflight, resource group, settings file, check, deploy (a VM through the
// embedded deploy.sh, or Container Apps through the embedded deploy/azure),
// /readyz, the Entra app through the embedded entra-app-register.sh, the bp
// connection and the organization's OIDC connection, and a last check.
//
// A state file in the working directory, .bp-instance-up.json by default,
// records each finished step and the values later steps need. A rerun skips
// the finished steps, so a failed run resumes where it stopped and never
// creates a second VM or deployment. The state file holds no secret: the
// secrets stay in the settings file and the Entra secret file, both mode 600.
// Every az call names the given resource group, apart from the Entra app and
// group, which carry the instance name.
//
// The step functions in instance_up_steps.go call out through instanceUpRun,
// which tests replace to stub az, ssh and bp.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	instanceUpStateFile   = ".bp-instance-up.json"
	instanceUpStateFormat = 1
	instanceUpVMName      = "barkpark"
	instanceUpVMUser      = "azureuser"
	instanceUpDeployment  = "barkpark"
	instanceUpDefaultVM   = "Standard_D2als_v7"
	instanceUpVMRegion    = "swedencentral"
	instanceUpACARegion   = "norwayeast"
	instanceUpPGFallback  = "Standard_B2s"
	instanceUpStudio      = "http://localhost:3000"
	instanceUpSecretFile  = "entra-client-secret"
	instanceUpAzureDir    = "barkpark-azure"
	instanceUpRepoURL     = "https://github.com/FRIKKern/barkpark.git"
	instanceUpLatestImage = "ghcr.io/frikkern/barkpark:latest"
)

// instanceUpState is the state file. It never holds a secret.
type instanceUpState struct {
	Format        int               `json:"format"`
	Path          string            `json:"path"`
	ResourceGroup string            `json:"resource_group"`
	Name          string            `json:"name"`
	Region        string            `json:"region"`
	HostArg       string            `json:"host_arg,omitempty"`
	Owner         string            `json:"owner"`
	Breakglass    string            `json:"breakglass,omitempty"`
	Org           string            `json:"org"`
	OrgName       string            `json:"org_name"`
	Image         string            `json:"image,omitempty"`
	FromSource    string            `json:"from_source,omitempty"`
	EnvFile       string            `json:"env_file"`
	StudioOrigin  string            `json:"studio_origin"`
	Size          string            `json:"size,omitempty"`
	PostgresSku   string            `json:"postgres_sku,omitempty"`
	AlertEmail    string            `json:"alert_email,omitempty"`
	SSHKey        string            `json:"ssh_key,omitempty"`
	Subscription  string            `json:"subscription,omitempty"`
	Tenant        string            `json:"tenant,omitempty"`
	Done          map[string]string `json:"done"`
	Out           instanceUpOutputs `json:"outputs"`
}

// instanceUpOutputs are values a step learns and a later step reads.
type instanceUpOutputs struct {
	Host          string `json:"host,omitempty"`
	IP            string `json:"ip,omitempty"`
	Image         string `json:"image,omitempty"`
	ACR           string `json:"acr,omitempty"`
	AppID         string `json:"app_id,omitempty"`
	OwnersGroupID string `json:"owners_group_id,omitempty"`
	SecretExpires string `json:"secret_expires,omitempty"`
}

// instanceUpCmd is one external command. env adds KEY=VALUE pairs, the only
// way a secret reaches a child; argv never carries one. stdin feeds the
// child. stream copies the child's output to the user's stderr as it runs.
type instanceUpCmd struct {
	name   string
	args   []string
	env    []string
	stdin  []byte
	stream bool
}

func (c instanceUpCmd) String() string { return c.name + " " + strings.Join(c.args, " ") }

// instanceUpRun runs one command and returns its stdout. Tests replace it.
var instanceUpRun = func(ctx context.Context, log io.Writer, c instanceUpCmd) (string, error) {
	cmd := exec.CommandContext(ctx, c.name, c.args...)
	cmd.Env = append(os.Environ(), c.env...)
	if c.stdin != nil {
		cmd.Stdin = bytes.NewReader(c.stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if c.stream {
		cmd.Stdout = io.MultiWriter(&stdout, log)
		cmd.Stderr = io.MultiWriter(&stderr, log)
	}
	if err := cmd.Run(); err != nil {
		return stdout.String(), &instanceUpCmdError{cmd: c.String(), err: err, stderr: stderr.String(), stdout: stdout.String()}
	}
	return stdout.String(), nil
}

// instanceUpCmdError keeps the child's output so a step can read the cause,
// such as CapacityNotAvailable, and prints its last lines.
type instanceUpCmdError struct {
	cmd, stderr, stdout string
	err                 error
}

func (e *instanceUpCmdError) Error() string {
	tail := strings.TrimSpace(e.stderr)
	if tail == "" {
		tail = strings.TrimSpace(e.stdout)
	}
	lines := strings.Split(tail, "\n")
	if len(lines) > 15 {
		lines = lines[len(lines)-15:]
	}
	return fmt.Sprintf("%s: %v\n%s", e.cmd, e.err, strings.Join(lines, "\n"))
}

func (e *instanceUpCmdError) output() string { return e.stdout + "\n" + e.stderr }

// cmdOutput returns everything a failed command printed, or "".
func cmdOutput(err error) string {
	var ce *instanceUpCmdError
	if errors.As(err, &ce) {
		return ce.output()
	}
	if err != nil {
		return err.Error()
	}
	return ""
}

// instanceUpGet fetches a URL and returns its status. Tests replace it.
var instanceUpGet = func(ctx context.Context, url string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return 0, err
	}
	resp.Body.Close()
	return resp.StatusCode, nil
}

// instanceUpSleep waits between polls. Tests replace it.
var instanceUpSleep = time.Sleep

// instanceUpSelf is the bp binary the org commands run as. Tests replace it.
var instanceUpSelf = os.Executable

// instanceUpConnect saves the instance as bp's active server, as
// `bp setup --target connect` does. Tests replace it.
var instanceUpConnect = func(out *writer, g globals, server, token string) error {
	if code := runSetup(out, g, []string{"--target", "connect", "--server", server, "--token", token}); code != exitOK {
		return fmt.Errorf("bp setup --target connect --server %s exited %d", server, code)
	}
	return nil
}

// instanceUp carries one run.
type instanceUp struct {
	ctx       context.Context
	out       *writer
	g         globals
	st        *instanceUpState
	statePath string
}

// instanceUpStep is one resumable step.
type instanceUpStep struct {
	name, title string
	run         func(*instanceUp) error
}

func runInstanceUp(out *writer, g globals, args []string) int {
	const usage = "bp instance up --azure --path vm|containerapps --resource-group <rg> --owner <upn> [--host <dns label or host>] [--breakglass <email>] [--image <ref> | --from-source <git ref>] [--region <r>] [--org <slug>] [--state <file>]"
	a, err := parseHzArgs(args, []string{
		"path", "resource-group", "host", "owner", "breakglass", "image", "from-source", "region",
		"org", "org-name", "name", "env-file", "state", "studio-origin", "size", "postgres-sku",
		"alert-email", "ssh-key",
	}, []string{"azure"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", "unexpected argument "+a.pos[0]+" (usage: "+usage+")", exitUsage)
	}
	statePath := strings.TrimSpace(a.val("state"))
	if statePath == "" {
		statePath = instanceUpStateFile
	}
	st, err := loadInstanceUpState(statePath)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	resumed := st != nil
	if st == nil {
		if !a.bools["azure"] {
			return useError(out, "usage", "--azure is required: Azure is the one provider bp instance up supports (usage: "+usage+")", exitUsage)
		}
		st = &instanceUpState{Format: instanceUpStateFormat, Done: map[string]string{}}
	}
	if err := st.merge(a); err != nil {
		return useError(out, "usage", err.Error()+" (usage: "+usage+")", exitUsage)
	}
	u := &instanceUp{ctx: context.Background(), out: out, g: g, st: st, statePath: statePath}
	if resumed {
		out.errf("resuming from %s: %d steps done.", statePath, len(st.Done))
	}
	if err := u.save(); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	steps := instanceUpSteps(st.Path)
	for i, s := range steps {
		if at, ok := st.Done[s.name]; ok && s.name != "preflight" {
			out.errf("[%d/%d] %s: done %s", i+1, len(steps), s.title, at)
			continue
		}
		out.errf("[%d/%d] %s", i+1, len(steps), s.title)
		start := time.Now()
		if err := s.run(u); err != nil {
			_ = u.save()
			return useError(out, "failed", fmt.Sprintf("%s: %v\nFix the cause and run the same command again. It resumes at this step from %s.", s.title, err, statePath), exitGeneric)
		}
		st.Done[s.name] = time.Now().UTC().Format(time.RFC3339)
		if err := u.save(); err != nil {
			return useError(out, "failed", err.Error(), exitGeneric)
		}
		out.errf("        %s took %s", s.name, time.Since(start).Round(time.Second))
	}
	u.printNext()
	return exitOK
}

// instanceUpSteps lists the steps for a path, in order.
func instanceUpSteps(path string) []instanceUpStep {
	steps := []instanceUpStep{
		{"preflight", "check az, the subscription, resource providers and quota", stepUpPreflight},
		{"group", "create the resource group", stepUpGroup},
		{"init", "write the settings file", stepUpInit},
		{"check", "check the settings file", stepUpCheck},
	}
	if path == instanceTargetVM {
		steps = append(steps,
			instanceUpStep{"ssh-key", "make the ssh key", stepUpSSHKey},
			instanceUpStep{"vm", "create the VM and open ports 80 and 443", stepUpVM},
			instanceUpStep{"deploy", "run deploy.sh on the VM", stepUpDeployVM},
		)
	} else {
		steps = append(steps,
			instanceUpStep{"image", "build the image from source in a registry in the group", stepUpBuildImage},
			instanceUpStep{"deploy", "deploy main.bicep to Container Apps", stepUpDeployACA},
		)
	}
	return append(steps,
		instanceUpStep{"ready", "wait for https://<host>/readyz", stepUpReady},
		instanceUpStep{"entra", "register the Entra app and owners group", stepUpEntra},
		instanceUpStep{"connect", "connect bp and the organization's Entra sign-in", stepUpConnect},
		instanceUpStep{"verify", "check the running instance", stepUpVerify},
	)
}

// merge applies the flags over the state. A rerun may leave flags out; a flag
// that names another instance than the state file is refused.
func (st *instanceUpState) merge(a *hzArgs) error {
	set := func(field *string, flag string, identity bool) error {
		v := strings.TrimSpace(a.val(flag))
		if v == "" {
			return nil
		}
		if identity && *field != "" && *field != v {
			return fmt.Errorf("--%s is %q but the state file is for %q. Use --state <file> for another instance", flag, v, *field)
		}
		*field = v
		return nil
	}
	for _, f := range []struct {
		field    *string
		flag     string
		identity bool
	}{
		{&st.Path, "path", true}, {&st.ResourceGroup, "resource-group", true}, {&st.HostArg, "host", true},
		{&st.Org, "org", true}, {&st.Name, "name", true}, {&st.Region, "region", true},
		{&st.Owner, "owner", false}, {&st.Breakglass, "breakglass", false}, {&st.Image, "image", false},
		{&st.FromSource, "from-source", false}, {&st.OrgName, "org-name", false}, {&st.EnvFile, "env-file", true},
		{&st.StudioOrigin, "studio-origin", false}, {&st.Size, "size", false}, {&st.PostgresSku, "postgres-sku", false},
		{&st.AlertEmail, "alert-email", false}, {&st.SSHKey, "ssh-key", false},
	} {
		if err := set(f.field, f.flag, f.identity); err != nil {
			return err
		}
	}
	switch st.Path {
	case instanceTargetVM, instanceTargetContainerApps:
	case "":
		return fmt.Errorf("--path is required: vm or containerapps")
	default:
		return fmt.Errorf("--path is %q; use vm or containerapps", st.Path)
	}
	if st.ResourceGroup == "" {
		return fmt.Errorf("--resource-group is required")
	}
	if st.Owner == "" || !strings.Contains(st.Owner, "@") {
		return fmt.Errorf("--owner is required: the owner's Entra user principal name, such as owner@example.com")
	}
	if st.Image != "" && st.FromSource != "" {
		return fmt.Errorf("give --image or --from-source, not both")
	}
	h := st.HostArg
	if strings.Contains(h, "/") || strings.Contains(h, ":") {
		return fmt.Errorf("--host is %q; give a DNS label such as pensum-cms, or a host name such as cms.example.com", h)
	}
	if st.Path == instanceTargetVM && h == "" {
		return fmt.Errorf("--host is required on --path vm: a DNS label such as pensum-cms, or your own host name")
	}
	if st.Path == instanceTargetContainerApps && h != "" && !strings.Contains(h, ".") {
		return fmt.Errorf("--host on --path containerapps is your own domain, such as cms.example.com; leave it out for the Container Apps address")
	}
	if st.Region == "" {
		st.Region = instanceUpVMRegion
		if st.Path == instanceTargetContainerApps {
			st.Region = instanceUpACARegion
		}
	}
	if st.Name == "" {
		st.Name = st.ResourceGroup
	}
	if st.Org == "" {
		st.Org = "pensum"
	}
	if st.OrgName == "" {
		st.OrgName = st.Org
	}
	if st.EnvFile == "" {
		st.EnvFile = "barkpark.env"
	}
	if st.StudioOrigin == "" {
		st.StudioOrigin = instanceUpStudio
	}
	if st.Path == instanceTargetVM && st.Size == "" {
		st.Size = instanceUpDefaultVM
	}
	if st.Path == instanceTargetVM && st.SSHKey == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("find the home directory for ~/.ssh/barkpark: %w", err)
		}
		st.SSHKey = filepath.Join(home, ".ssh", "barkpark")
	}
	return nil
}

// dnsLabel returns the --host value when it is a DNS label for the VM's
// public IP, or "".
func (st *instanceUpState) dnsLabel() string {
	if st.Path == instanceTargetVM && !strings.Contains(st.HostArg, ".") {
		return st.HostArg
	}
	return ""
}

// host is the instance's public host name, known before the deploy on a VM
// and after it on Container Apps without a domain.
func (st *instanceUpState) host() string {
	if st.Out.Host != "" {
		return st.Out.Host
	}
	if l := st.dnsLabel(); l != "" {
		return l + "." + st.Region + ".cloudapp.azure.com"
	}
	return st.HostArg
}

func loadInstanceUpState(path string) (*instanceUpState, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var st instanceUpState
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, fmt.Errorf("%s is not a bp instance up state file: %v", path, err)
	}
	if st.Format != instanceUpStateFormat {
		return nil, fmt.Errorf("%s has format %d; this bp reads format %d", path, st.Format, instanceUpStateFormat)
	}
	if st.Done == nil {
		st.Done = map[string]string{}
	}
	return &st, nil
}

func (u *instanceUp) save() error {
	b, err := json.MarshalIndent(u.st, "", "  ")
	if err != nil {
		return err
	}
	tmp := u.statePath + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, u.statePath)
}

// run runs one command with the run's context and the user's stderr as its log.
func (u *instanceUp) run(c instanceUpCmd) (string, error) {
	return instanceUpRun(u.ctx, u.out.stderr, c)
}

// az runs az with JSON output and decodes it into v when v is not nil.
func (u *instanceUp) az(v any, args ...string) error {
	stdout, err := u.run(instanceUpCmd{name: "az", args: append(args, "-o", "json")})
	if err != nil {
		return err
	}
	if v == nil || strings.TrimSpace(stdout) == "" {
		return nil
	}
	if err := json.Unmarshal([]byte(stdout), v); err != nil {
		return fmt.Errorf("az %s: read its JSON: %v", strings.Join(args, " "), err)
	}
	return nil
}

// notFound reports whether an az error says the resource does not exist.
func notFound(err error) bool {
	s := cmdOutput(err)
	return strings.Contains(s, "ResourceNotFound") || strings.Contains(s, "ResourceGroupNotFound") ||
		strings.Contains(s, "could not be found") || strings.Contains(s, "was not found")
}

func (u *instanceUp) printNext() {
	st := u.st
	signIn := fmt.Sprintf("https://%s/v1/auth/oidc/%s/start", st.host(), st.Org)
	if u.out.emitStructured(map[string]any{"ok": true, "action": "up", "path": st.Path, "resource_group": st.ResourceGroup,
		"host": st.host(), "org": st.Org, "sign_in_url": signIn, "state": u.statePath, "done": st.Done}) {
		return
	}
	o := u.out
	o.outf("")
	o.outf("Barkpark runs at https://%s and is the active server for bp.", st.host())
	o.outf("Sign-in link for the owner %s:", st.Owner)
	o.outf("  %s", signIn)
	o.outf("")
	o.outf("Next steps:")
	o.outf("1. Sign in as %s with the link above. The first sign-in seats the owner.", st.Owner)
	o.outf("   Entra asks for MFA, because the connection counts Entra MFA as Barkpark MFA.")
	if st.Breakglass != "" {
		o.outf("2. Create the break-glass account for %s, as docs/setup/ENTRA-ACCESS.md#break-glass-account says.", st.Breakglass)
	} else {
		o.outf("2. Choose a break-glass mailbox, add it as BARKPARK_BREAKGLASS_EMAILS in %s, deploy again,", st.EnvFile)
		o.outf("   and create the account as docs/setup/ENTRA-ACCESS.md#break-glass-account says.")
	}
	o.outf("3. Then allow only SSO: bp org auth-methods %s sso --yes", st.Org)
	o.outf("4. Remove BARKPARK_BOOTSTRAP_OWNER_EMAIL from %s once the owner has signed in.", st.EnvFile)
	o.outf("Keep %s and %s in your password manager. %s records the run without secrets.",
		st.EnvFile, filepath.Join(filepath.Dir(st.EnvFile), instanceUpSecretFile), u.statePath)
}
