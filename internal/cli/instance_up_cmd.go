package cli

// instance_up_cmd.go is `bp instance up`: one command from an empty Azure
// resource group to an instance whose owner can sign in with Entra ID.
//
//	bp instance up --azure --path vm|containerapps --resource-group <rg>
//	               --owner <upn> [--host <dns label or host>] [--breakglass <email>]
//	               [--image <ref> | --from-source <git ref>] [--region <r>] [--use]
//	               [--subnet-id <id>] [--public-ip <name>] [--vm-name <name>]
//	               [--entra-app-id <appId>] [--assign-identity] [--entra-ssh]
//
// The last line is for a subscription where IT owns the network and the app
// registration (docs/setup/SELF-HOST-IT-MANAGED.md). --subnet-id puts the VM's
// NIC in that subnet with no NIC NSG, so the subnet's NSG decides which ports
// are open and up opens none. --entra-app-id uses an app registration that
// exists: up adds a client secret to it and pipes the secret to the VM over
// ssh, so it never reaches the operator's disk or any argv.
//
// It runs the steps docs/setup/SELF-HOST.md and docs/setup/ENTRA.md describe:
// preflight, resource group, settings file, check, deploy (a VM through the
// embedded deploy.sh, or Container Apps through the embedded deploy/azure),
// /readyz, the Entra app through the embedded entra-app-register.sh, the bp
// connection and the organization's OIDC connection, and a last check.
//
// up saves the instance as a known bp server and leaves the active server as
// it was, because other bp processes on the machine share that default. --use
// also makes the instance the active server; otherwise up prints the bp use
// command that does.
//
// A state file in the working directory, .bp-instance-up.json by default,
// records each finished step and the values later steps need. A rerun skips
// the finished steps, so a failed run resumes where it stopped and never
// creates a second VM or deployment. The state file holds no secret: the
// secrets stay in the settings file and the Entra secret file, both mode 600.
// Every az call names the given resource group, apart from the Entra app and
// owners group, whose names carry the org and the host.
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
	"regexp"
	"strconv"
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
	// instanceUpVMImage is Ubuntu 24.04 LTS. The URN works on every az
	// version, unlike the Ubuntu2404 alias.
	instanceUpVMImage = "Canonical:ubuntu-24_04-lts:server:latest"
	// instanceUpVMSecret holds the client secret on the VM when up uses an
	// existing app registration (--entra-app-id).
	instanceUpVMSecret = "/etc/barkpark/entra-client-secret"
)

// instanceUpState is the state file. It never holds a secret.
type instanceUpState struct {
	Format        int               `json:"format"`
	Path          string            `json:"path"`
	ResourceGroup string            `json:"resource_group"`
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
	DiskSku       string            `json:"disk_sku,omitempty"`
	DiskGB        string            `json:"disk_gb,omitempty"`
	AlertEmail    string            `json:"alert_email,omitempty"`
	SSHKey        string            `json:"ssh_key,omitempty"`
	VMName        string            `json:"vm_name,omitempty"`
	SubnetID      string            `json:"subnet_id,omitempty"`
	PublicIP      string            `json:"public_ip,omitempty"`
	EntraAppID    string            `json:"entra_app_id,omitempty"`
	AssignID      bool              `json:"assign_identity,omitempty"`
	EntraSSH      bool              `json:"entra_ssh,omitempty"`
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
	// EntraByBicep is true when main.bicep made the Entra app and the
	// server connects the organization at its first boot.
	EntraByBicep bool `json:"entra_by_bicep,omitempty"`
}

// instanceUpCmd is one external command. env adds KEY=VALUE pairs, the only
// way a secret reaches a child; argv never carries one. stdin feeds the
// child. stream copies the child's output to the user's stderr as it runs;
// streamErr copies only its stderr, for a child whose stdout bp reads.
type instanceUpCmd struct {
	name      string
	args      []string
	env       []string
	stdin     []byte
	stream    bool
	streamErr bool
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
	}
	if c.stream || c.streamErr {
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

// instanceUpRedirect fetches a URL without following a redirect and returns
// the status and the Location header. Tests replace it.
var instanceUpRedirect = func(ctx context.Context, url string) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, "", err
	}
	c := &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		return 0, "", err
	}
	resp.Body.Close()
	return resp.StatusCode, resp.Header.Get("Location"), nil
}

// instanceUpSleep waits between polls. Tests replace it.
var instanceUpSleep = time.Sleep

// instanceUpSelf is the bp binary the org commands run as. Tests replace it.
var instanceUpSelf = os.Executable

// instanceUpConnect saves the instance as a known bp server, as
// `bp setup --target connect --keep-active` does, and leaves the active server
// as it was. Its report goes to stderr, so stdout keeps only up's own result.
// Tests replace it.
var instanceUpConnect = func(out *writer, g globals, server, token string) error {
	w := newWriter(out.stderr, out.stderr)
	g.output, g.outputSet = "table", false
	w.applyGlobals(g)
	if code := runSetup(w, g, []string{"--target", "connect", "--server", server, "--token", token, "--keep-active"}); code != exitOK {
		return fmt.Errorf("bp setup --target connect --server %s exited %d", server, code)
	}
	return nil
}

// instanceUpUse makes the saved instance the active server, as `bp use`
// does, and returns the name it is saved under.
func instanceUpUse(server string) (string, error) {
	cfg, err := LoadConfig()
	if err != nil {
		return "", err
	}
	e, ok := cfg.FindServer(server)
	if !ok {
		return "", fmt.Errorf("%s is not a saved server; run bp setup --target connect --server %s", server, server)
	}
	cfg.SetActiveServer(e)
	if err := SaveConfig(cfg); err != nil {
		return "", err
	}
	return cfg.DisplayName(e), nil
}

// instanceUpServerName returns the name bp saved the instance under, or the
// URL when the config does not list it.
func instanceUpServerName(server string) string {
	cfg, err := LoadConfig()
	if err != nil {
		return server
	}
	if e, ok := cfg.FindServer(server); ok {
		return cfg.DisplayName(e)
	}
	return server
}

// instanceUp carries one run.
type instanceUp struct {
	ctx       context.Context
	out       *writer
	g         globals
	st        *instanceUpState
	statePath string
	// use is --use: make the instance the active server at the end.
	use bool
	// serverName is the name bp saved the instance under.
	serverName string
}

// instanceUpStep is one resumable step.
type instanceUpStep struct {
	name, title string
	run         func(*instanceUp) error
}

func runInstanceUp(out *writer, g globals, args []string) int {
	const usage = "bp instance up --azure --path vm|containerapps --resource-group <rg> --owner <upn> [--host <dns label or host>] [--breakglass <email>] [--image <ref> | --from-source <git ref>] [--region <r>] [--org <slug>] [--state <file>] [--use] [--size <vm size>] [--disk-sku <sku>] [--disk-gb <n>] [--vm-name <name>] [--subnet-id <id>] [--public-ip <name>] [--entra-app-id <appId>] [--assign-identity] [--entra-ssh]"
	a, err := parseHzArgs(args, []string{
		"path", "resource-group", "host", "owner", "breakglass", "image", "from-source", "region",
		"org", "org-name", "env-file", "state", "studio-origin", "size", "postgres-sku",
		"disk-sku", "disk-gb", "alert-email", "ssh-key", "vm-name", "subnet-id", "public-ip", "entra-app-id",
	}, []string{"azure", "use", "assign-identity", "entra-ssh"}, usage)
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
	u := &instanceUp{ctx: context.Background(), out: out, g: g, st: st, statePath: statePath, use: a.bools["use"]}
	if resumed {
		out.errf("resuming from %s: %d steps done.", statePath, len(st.Done))
	}
	if err := u.save(); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	steps := instanceUpSteps(st)
	for i, s := range steps {
		// A title names the host once up knows it.
		title := s.title
		if h := st.host(); h != "" {
			title = strings.ReplaceAll(title, "<host>", h)
		}
		if at, ok := st.Done[s.name]; ok && s.name != "preflight" {
			out.errf("[%d/%d] %s: done %s", i+1, len(steps), title, at)
			continue
		}
		out.errf("[%d/%d] %s", i+1, len(steps), title)
		start := time.Now()
		if err := s.run(u); err != nil {
			_ = u.save()
			return useError(out, "failed", fmt.Sprintf("%s: %v\nFix the cause and run the same command again. It resumes at this step from %s.", title, err, statePath), exitGeneric)
		}
		st.Done[s.name] = time.Now().UTC().Format(time.RFC3339)
		if err := u.save(); err != nil {
			return useError(out, "failed", err.Error(), exitGeneric)
		}
		out.errf("        %s took %s, %s to %s UTC", s.name, time.Since(start).Round(time.Second),
			start.UTC().Format("15:04:05"), time.Now().UTC().Format("15:04:05"))
	}
	server := "https://" + st.host()
	if u.use {
		name, err := instanceUpUse(server)
		if err != nil {
			return useError(out, "failed", "--use: "+err.Error(), exitGeneric)
		}
		u.serverName = name
	} else {
		u.serverName = instanceUpServerName(server)
	}
	u.printNext()
	return exitOK
}

// instanceUpSteps lists the steps for a run, in order.
func instanceUpSteps(st *instanceUpState) []instanceUpStep {
	path := st.Path
	vmTitle := "create the VM and open ports 80 and 443"
	if st.SubnetID != "" {
		vmTitle = "create the VM in the given subnet; its network security group decides the ports"
	}
	entraTitle := "register the Entra app and owners group"
	if st.EntraAppID != "" {
		entraTitle = "add a client secret to the Entra app " + st.EntraAppID + " and put it on the VM"
	}
	steps := []instanceUpStep{
		{"preflight", "check az, the subscription, resource providers and quota", stepUpPreflight},
		{"group", "create the resource group", stepUpGroup},
		{"init", "write the settings file", stepUpInit},
		{"check", "check the settings file", stepUpCheck},
	}
	if path == instanceTargetVM {
		steps = append(steps,
			instanceUpStep{"ssh-key", "make the ssh key", stepUpSSHKey},
			instanceUpStep{"vm", vmTitle, stepUpVM},
			instanceUpStep{"deploy", "run deploy.sh on the VM", stepUpDeployVM},
		)
	} else {
		steps = append(steps,
			instanceUpStep{"image", "choose the image", stepUpBuildImage},
			instanceUpStep{"deploy", "deploy main.bicep to Container Apps", stepUpDeployACA},
		)
	}
	return append(steps,
		instanceUpStep{"ready", "wait for https://<host>/readyz", stepUpReady},
		instanceUpStep{"entra", entraTitle, stepUpEntra},
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
		{&st.Org, "org", true}, {&st.Region, "region", true},
		{&st.Owner, "owner", false}, {&st.Breakglass, "breakglass", false}, {&st.Image, "image", false},
		{&st.FromSource, "from-source", false}, {&st.OrgName, "org-name", false}, {&st.EnvFile, "env-file", true},
		{&st.StudioOrigin, "studio-origin", false}, {&st.Size, "size", false}, {&st.PostgresSku, "postgres-sku", false},
		{&st.DiskSku, "disk-sku", false}, {&st.DiskGB, "disk-gb", false},
		{&st.AlertEmail, "alert-email", false}, {&st.SSHKey, "ssh-key", false},
		{&st.VMName, "vm-name", true}, {&st.SubnetID, "subnet-id", true}, {&st.PublicIP, "public-ip", true},
		{&st.EntraAppID, "entra-app-id", true},
	} {
		if err := set(f.field, f.flag, f.identity); err != nil {
			return err
		}
	}
	// A bool flag stays on for the reruns of a run that set it.
	st.AssignID = st.AssignID || a.bools["assign-identity"]
	st.EntraSSH = st.EntraSSH || a.bools["entra-ssh"]
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
	if (st.DiskSku != "" || st.DiskGB != "") && st.Path != instanceTargetVM {
		return fmt.Errorf("--disk-sku and --disk-gb set the VM's OS disk and need --path vm")
	}
	if st.Path != instanceTargetVM {
		for flag, set := range map[string]bool{"--subnet-id": st.SubnetID != "", "--public-ip": st.PublicIP != "",
			"--vm-name": st.VMName != "", "--entra-app-id": st.EntraAppID != "", "--assign-identity": st.AssignID, "--entra-ssh": st.EntraSSH} {
			if set {
				return fmt.Errorf("%s needs --path vm. On Container Apps, main.bicep makes the network and the Entra app", flag)
			}
		}
	}
	if st.SubnetID != "" && !instanceUpSubnetID.MatchString(st.SubnetID) {
		return fmt.Errorf("--subnet-id is %q; give the subnet's full resource id, /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>", st.SubnetID)
	}
	if st.PublicIP != "" && !instanceUpAzureName.MatchString(st.PublicIP) {
		return fmt.Errorf("--public-ip is %q; give the name of a public IP address resource in the resource group", st.PublicIP)
	}
	if st.VMName != "" && !instanceUpAzureName.MatchString(st.VMName) {
		return fmt.Errorf("--vm-name is %q; use letters, digits, dots, dashes and underscores", st.VMName)
	}
	if st.EntraAppID != "" && !instanceUpGUID.MatchString(st.EntraAppID) {
		return fmt.Errorf("--entra-app-id is %q; give the app registration's application (client) id, a GUID", st.EntraAppID)
	}
	if st.DiskGB != "" {
		if n, err := strconv.Atoi(st.DiskGB); err != nil || n < 30 || n > 4095 {
			return fmt.Errorf("--disk-gb is %q; give the OS disk size in GiB, 30 to 4095", st.DiskGB)
		}
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
	// With --subnet-id the region comes from the subnet's VNet in preflight,
	// since a NIC must be in its VNet's region.
	if st.Region == "" && st.SubnetID == "" {
		st.Region = instanceUpVMRegion
		if st.Path == instanceTargetContainerApps {
			st.Region = instanceUpACARegion
		}
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
	if st.Path == instanceTargetVM && st.VMName == "" {
		st.VMName = instanceUpVMName
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

var (
	instanceUpSubnetID  = regexp.MustCompile(`(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$`)
	instanceUpAzureName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$`)
	instanceUpGUID      = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
)

// vmName is the VM's name: --vm-name, or barkpark for a state file from
// before the flag.
func (st *instanceUpState) vmName() string {
	if st.VMName != "" {
		return st.VMName
	}
	return instanceUpVMName
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

// az runs az with JSON output and decodes it into v when v is not nil. It
// waits out AuthorizationFailed while a new role reaches Azure
// (instance_up_authwait.go).
func (u *instanceUp) az(v any, args ...string) error {
	return u.retryAuth(azWhat(args), func() error { return u.azOnce(v, args...) })
}

// azOnce runs az once, as az does.
func (u *instanceUp) azOnce(v any, args ...string) error {
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
		"host": st.host(), "org": st.Org, "sign_in_url": signIn, "state": u.statePath, "done": st.Done,
		"server_name": u.serverName, "active": u.use}) {
		return
	}
	o := u.out
	o.outf("")
	if u.use {
		o.outf("Barkpark runs at https://%s and is now the active server for bp, saved as %s.", st.host(), u.serverName)
	} else {
		o.outf("Barkpark runs at https://%s. bp saved it as %s and kept the active server as it was.", st.host(), u.serverName)
		o.outf("Switch to it with: bp use %s", u.serverName)
		o.outf("Or run one command against it with: bp --server %s <command>", u.serverName)
	}
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
	if st.EntraAppID != "" {
		o.outf("Keep %s in your password manager. The client secret is only in %s on the VM and in Barkpark.", st.EnvFile, instanceUpVMSecret)
		o.outf("%s records the run without secrets.", u.statePath)
		return
	}
	o.outf("Keep %s and %s in your password manager. %s records the run without secrets.",
		st.EnvFile, filepath.Join(filepath.Dir(st.EnvFile), instanceUpSecretFile), u.statePath)
}
