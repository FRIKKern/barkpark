package cli

// instance_up_steps.go holds the steps of `bp instance up`
// (instance_up_cmd.go). Each step is safe to run twice: it looks for what it
// would create before it creates it.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/setup/assets"
)

// instanceUpProviders are the resource providers each path needs.
func instanceUpProviders(st *instanceUpState) []string {
	if st.Path == instanceTargetVM {
		return []string{"Microsoft.Compute", "Microsoft.Network"}
	}
	p := []string{"Microsoft.App", "Microsoft.DBforPostgreSQL", "Microsoft.KeyVault", "Microsoft.Network",
		"Microsoft.OperationalInsights", "Microsoft.ManagedIdentity", "Microsoft.Storage", "Microsoft.Insights"}
	if st.FromSource != "" {
		p = append(p, "Microsoft.ContainerRegistry")
	}
	return p
}

// stepUpPreflight checks the az sign-in on every run. On the first run it
// also registers the resource providers and checks the VM size and quota.
func stepUpPreflight(u *instanceUp) error {
	st := u.st
	var acct struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		TenantID string `json:"tenantId"`
		User     struct {
			Name string `json:"name"`
		} `json:"user"`
	}
	if err := u.az(&acct, "account", "show"); err != nil {
		return fmt.Errorf("az is not signed in. Run az login, then az account set --subscription <id>.\n%v", err)
	}
	if st.Subscription != "" && st.Subscription != acct.ID {
		return fmt.Errorf("az now uses subscription %s, but this run started in %s. Run az account set --subscription %s", acct.ID, st.Subscription, st.Subscription)
	}
	st.Subscription, st.Tenant = acct.ID, acct.TenantID
	u.out.errf("        subscription %s (%s) as %s", acct.Name, acct.ID, acct.User.Name)
	if _, done := st.Done["preflight"]; done {
		return nil
	}
	for _, ns := range instanceUpProviders(st) {
		if err := u.registerProvider(ns); err != nil {
			return err
		}
	}
	if st.Path == instanceTargetVM {
		return u.checkVMQuota()
	}
	return nil
}

func (u *instanceUp) registerProvider(ns string) error {
	state := func() (string, error) {
		var s string
		err := u.az(&s, "provider", "show", "-n", ns, "--query", "registrationState")
		return s, err
	}
	s, err := state()
	if err != nil {
		return err
	}
	if s == "Registered" {
		return nil
	}
	u.out.errf("        registering %s", ns)
	if err := u.az(nil, "provider", "register", "--namespace", ns); err != nil {
		return err
	}
	for i := 0; i < 90; i++ {
		if s, err = state(); err != nil {
			return err
		}
		if s == "Registered" {
			return nil
		}
		instanceUpSleep(10 * time.Second)
	}
	return fmt.Errorf("%s is still %s after 15 minutes. Run the command again later", ns, s)
}

// checkVMQuota checks that the region offers the size to this subscription
// and that the family and regional vCPU quota leave room for it.
func (u *instanceUp) checkVMQuota() error {
	st := u.st
	hint := fmt.Sprintf("Try --region %s --size %s, which small subscriptions can use, or ask for more quota in the portal under Quotas.", instanceUpVMRegion, instanceUpDefaultVM)
	var skus []struct {
		Name         string `json:"name"`
		Family       string `json:"family"`
		Capabilities []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		} `json:"capabilities"`
		Restrictions []struct {
			ReasonCode string `json:"reasonCode"`
		} `json:"restrictions"`
	}
	if err := u.az(&skus, "vm", "list-skus", "--location", st.Region, "--size", st.Size, "--resource-type", "virtualMachines", "--all"); err != nil {
		return err
	}
	var family string
	vcpus := 0
	found := false
	for _, s := range skus {
		if !strings.EqualFold(s.Name, st.Size) {
			continue
		}
		found = true
		if len(s.Restrictions) > 0 {
			return fmt.Errorf("%s is not available to this subscription in %s (%s). %s", st.Size, st.Region, s.Restrictions[0].ReasonCode, hint)
		}
		family = s.Family
		for _, c := range s.Capabilities {
			if c.Name == "vCPUs" {
				fmt.Sscanf(c.Value, "%d", &vcpus)
			}
		}
	}
	if !found {
		return fmt.Errorf("%s is not offered in %s. %s", st.Size, st.Region, hint)
	}
	var usage []struct {
		CurrentValue json.Number `json:"currentValue"`
		Limit        json.Number `json:"limit"`
		Name         struct {
			Value string `json:"value"`
		} `json:"name"`
	}
	if err := u.az(&usage, "vm", "list-usage", "--location", st.Region); err != nil {
		return err
	}
	for _, q := range usage {
		if q.Name.Value != family && q.Name.Value != "cores" {
			continue
		}
		cur, _ := q.CurrentValue.Int64()
		lim, _ := q.Limit.Int64()
		if lim-cur < int64(vcpus) {
			return fmt.Errorf("the %s vCPU quota in %s is %d of %d used, and %s needs %d. %s", q.Name.Value, st.Region, cur, lim, st.Size, vcpus, hint)
		}
	}
	return nil
}

// stepUpGroup creates the resource group, or uses it when it exists.
func stepUpGroup(u *instanceUp) error {
	st := u.st
	var g struct {
		Location string `json:"location"`
	}
	err := u.az(&g, "group", "show", "-n", st.ResourceGroup)
	switch {
	case err == nil:
		if !strings.EqualFold(g.Location, st.Region) {
			u.out.errf("        the group is in %s; resources go to %s", g.Location, st.Region)
		}
		return nil
	case notFound(err):
		return u.az(nil, "group", "create", "-n", st.ResourceGroup, "-l", st.Region, "--query", "properties.provisioningState")
	default:
		return err
	}
}

// envHost is the PHX_HOST the settings file gets: the VM's host, or the own
// domain on Container Apps.
func (st *instanceUpState) envHost() string {
	if st.Path == instanceTargetVM {
		return st.host()
	}
	return st.HostArg
}

// stepUpInit writes the settings file as `bp instance init` does, or keeps
// one that exists.
func stepUpInit(u *instanceUp) error {
	st := u.st
	if _, err := os.Stat(st.EnvFile); err == nil {
		u.out.errf("        keeping %s, which exists", st.EnvFile)
		return nil
	}
	secrets, err := instanceGenerateSecrets()
	if err != nil {
		return err
	}
	body := instanceEnvFile(st.Path, secrets, instanceInitValues{
		target: st.Path, host: st.envHost(), studioOrigin: st.StudioOrigin, ownerEmail: st.Owner,
		operatorEmails: st.Owner, breakglassEmail: st.Breakglass,
	})
	if st.Breakglass == "" {
		// No placeholder reaches the server. The last step says how to add it.
		body = strings.Replace(body, "\nBARKPARK_BREAKGLASS_EMAILS=", "\n# Set before bp org auth-methods <org> sso:\n# BARKPARK_BREAKGLASS_EMAILS=", 1)
	}
	if err := writeNewPrivateFile(st.EnvFile, body); err != nil {
		return err
	}
	u.out.errf("        wrote %s with mode 600 and generated secrets", st.EnvFile)
	return nil
}

// stepUpCheck runs `bp instance check` on the settings file, without the
// server probes.
func stepUpCheck(u *instanceUp) error {
	return u.checkEnv(map[string]bool{"database": true, "media": true, "url": true})
}

func (u *instanceUp) checkEnv(skip map[string]bool) error {
	st := u.st
	f, err := os.Open(st.EnvFile)
	if err != nil {
		return err
	}
	env, err := parseInstanceEnv(f)
	f.Close()
	if err != nil {
		return fmt.Errorf("%s: %v", st.EnvFile, err)
	}
	problems, notes := instanceCheck(u.ctx, env, instanceCheckOpts{target: st.Path, skip: skip})
	var left []string
	for _, p := range problems {
		if p.Setting == "BARKPARK_BREAKGLASS_EMAILS" && st.Breakglass == "" {
			continue
		}
		left = append(left, p.String())
	}
	for _, n := range notes {
		u.out.errf("        note: %s", n.Problem)
	}
	if len(left) > 0 {
		return fmt.Errorf("bp instance check found %d problems in %s:\n%s", len(left), st.EnvFile, strings.Join(left, "\n"))
	}
	u.out.errf("        bp instance check: no problems in %s", st.EnvFile)
	return nil
}

// stepUpSSHKey makes ~/.ssh and the key, as the guide does.
func stepUpSSHKey(u *instanceUp) error {
	key := u.st.SSHKey
	if err := os.MkdirAll(filepath.Dir(key), 0o700); err != nil {
		return err
	}
	if _, err := os.Stat(key); err == nil {
		if _, err := os.Stat(key + ".pub"); err != nil {
			return fmt.Errorf("%s exists without %s.pub", key, key)
		}
		return nil
	}
	_, err := u.run(instanceUpCmd{name: "ssh-keygen", args: []string{"-q", "-t", "ed25519", "-N", "", "-C", "barkpark", "-f", key}})
	return err
}

type instanceUpVMInfo struct {
	PublicIPs string `json:"publicIps"`
	FQDNs     string `json:"fqdns"`
}

// stepUpVM creates the VM unless it exists, and opens 80 and 443.
func stepUpVM(u *instanceUp) error {
	st := u.st
	var vm instanceUpVMInfo
	err := u.az(&vm, "vm", "show", "-d", "-g", st.ResourceGroup, "-n", instanceUpVMName)
	if err != nil && !notFound(err) {
		return err
	}
	if err != nil {
		args := []string{"vm", "create", "-g", st.ResourceGroup, "-n", instanceUpVMName, "--image", "Ubuntu2204",
			"--size", st.Size, "--location", st.Region, "--admin-username", instanceUpVMUser,
			"--ssh-key-values", st.SSHKey + ".pub", "--public-ip-sku", "Standard"}
		if l := st.dnsLabel(); l != "" {
			args = append(args, "--public-ip-address-dns-name", l)
		}
		var created struct {
			PublicIPAddress string `json:"publicIpAddress"`
			FQDNs           string `json:"fqdns"`
		}
		if err := u.az(&created, args...); err != nil {
			if strings.Contains(cmdOutput(err), "DnsRecordInUse") || strings.Contains(cmdOutput(err), "DnsLabel") {
				return fmt.Errorf("the DNS label %s is taken in %s. Choose another --host with a new --state file.\n%v", st.dnsLabel(), st.Region, err)
			}
			return err
		}
		vm = instanceUpVMInfo{PublicIPs: created.PublicIPAddress, FQDNs: created.FQDNs}
	}
	if vm.PublicIPs == "" {
		return fmt.Errorf("the VM %s has no public IP address", instanceUpVMName)
	}
	st.Out.IP = vm.PublicIPs
	st.Out.Host = st.host()
	if err := u.az(nil, "vm", "open-port", "-g", st.ResourceGroup, "-n", instanceUpVMName, "--port", "80,443", "--priority", "900", "--query", "provisioningState"); err != nil {
		return err
	}
	u.out.errf("        VM %s at %s, host %s", instanceUpVMName, st.Out.IP, st.Out.Host)
	if st.dnsLabel() == "" {
		u.out.errf("        point a DNS A record for %s at %s now. Caddy needs it for the certificate.", st.Out.Host, st.Out.IP)
	}
	return nil
}

// sshArgs are the options for every ssh and scp call. The host key goes to
// a known_hosts file next to the state file, so a reused Azure IP with an old
// key in ~/.ssh/known_hosts does not stop the run.
func (u *instanceUp) sshArgs() []string {
	return []string{"-i", u.st.SSHKey, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
		"-o", "UserKnownHostsFile=" + u.statePath + ".known_hosts", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30"}
}

func (u *instanceUp) ssh(remote string, stdin []byte, stream bool) (string, error) {
	args := append(u.sshArgs(), instanceUpVMUser+"@"+u.st.Out.IP, remote)
	return u.run(instanceUpCmd{name: "ssh", args: args, stdin: stdin, stream: stream})
}

// stepUpDeployVM copies the settings file to the VM and runs the embedded
// deploy.sh there, with the image or the source ref.
func stepUpDeployVM(u *instanceUp) error {
	st := u.st
	var err error
	for i := 0; i < 20; i++ {
		if _, err = u.ssh("true", nil, false); err == nil {
			break
		}
		instanceUpSleep(10 * time.Second)
	}
	if err != nil {
		return fmt.Errorf("ssh to %s did not answer within 3 minutes: %v", st.Out.IP, err)
	}
	scp := append(u.sshArgs(), st.EnvFile, instanceUpVMUser+"@"+st.Out.IP+":/tmp/pensum.env")
	if _, err := u.run(instanceUpCmd{name: "scp", args: scp}); err != nil {
		return err
	}
	env := []string{"DOMAIN=" + st.host(), "BARKPARK_ENV_FILE=/tmp/pensum.env"}
	switch {
	case st.FromSource != "":
		env = append(env, "BARKPARK_FROM_SOURCE="+st.FromSource)
	case st.Image != "":
		env = append(env, "BARKPARK_IMAGE="+st.Image)
	}
	for i, e := range env {
		k, v, _ := strings.Cut(e, "=")
		env[i] = k + "=" + shQuote(v)
	}
	u.out.errf("        deploy.sh output follows")
	_, err = u.ssh("sudo "+strings.Join(env, " ")+" bash -s", assets.DeployScript, true)
	return err
}

// shQuote quotes s for a POSIX shell.
func shQuote(s string) string {
	if s != "" && regexp.MustCompile(`^[A-Za-z0-9_./:@=+-]+$`).MatchString(s) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}

// acrName is the registry name for the group: globally unique, 5 to 50
// letters and digits.
func (st *instanceUpState) acrName() string {
	sum := sha256.Sum256([]byte(st.Subscription + "/" + st.ResourceGroup))
	return "bp" + hex.EncodeToString(sum[:])[:16]
}

var instanceUpTagChars = regexp.MustCompile(`[^A-Za-z0-9_.-]+`)

// stepUpBuildImage builds the image from --from-source in a registry in the
// group with az acr build. Without --from-source it does nothing.
func stepUpBuildImage(u *instanceUp) error {
	st := u.st
	if st.FromSource == "" {
		u.out.errf("        no --from-source; the deploy uses the published image")
		return nil
	}
	acr := st.acrName()
	if err := u.az(nil, "acr", "show", "-g", st.ResourceGroup, "-n", acr, "--query", "name"); err != nil {
		if !notFound(err) {
			return err
		}
		if err := u.az(nil, "acr", "create", "-g", st.ResourceGroup, "-n", acr, "--sku", "Basic", "-l", st.Region, "--query", "name"); err != nil {
			return err
		}
	}
	tag := "barkpark:" + strings.Trim(instanceUpTagChars.ReplaceAllString(st.FromSource, "-"), "-.")
	u.out.errf("        az acr build output follows")
	if _, err := u.run(instanceUpCmd{name: "az", args: []string{"acr", "build", "-g", st.ResourceGroup, "-r", acr, "-t", tag,
		"-f", "api/Dockerfile", "--timeout", "7200", instanceUpRepoURL + "#" + st.FromSource}, stream: true}); err != nil {
		return err
	}
	st.Out.ACR = acr
	st.Out.Image = acr + ".azurecr.io/" + tag
	return nil
}

// writeAzureFiles writes the embedded deploy/azure next to the settings file,
// with main.bicepparam reading that settings file.
func (u *instanceUp) writeAzureFiles() (string, error) {
	st := u.st
	envAbs, err := filepath.Abs(st.EnvFile)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(filepath.Dir(envAbs), instanceUpAzureDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	err = fs.WalkDir(assets.Azure, "azure", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := assets.Azure.ReadFile(p)
		if err != nil {
			return err
		}
		rel := strings.TrimPrefix(p, "azure/")
		if rel == "main.example.bicepparam" {
			rel = "main.bicepparam"
			b = []byte(strings.ReplaceAll(string(b), "loadTextContent('barkpark.env')", "loadTextContent('../"+filepath.Base(envAbs)+"')"))
		}
		target := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o600)
	})
	return dir, err
}

// stepUpDeployACA deploys main.bicep. On CapacityNotAvailable for the default
// Postgres size it tries once more with Standard_B2s.
func stepUpDeployACA(u *instanceUp) error {
	st := u.st
	dir, err := u.writeAzureFiles()
	if err != nil {
		return err
	}
	image := st.Image
	if st.FromSource != "" {
		image = st.Out.Image
	}
	if image == "" && !instanceUpBicepHasImageDefault() {
		image = instanceUpLatestImage
	}
	args := []string{"deployment", "group", "create", "-g", st.ResourceGroup, "-n", instanceUpDeployment,
		"-p", filepath.Join(dir, "main.bicepparam")}
	if image != "" {
		args = append(args, "-p", "image="+image)
	}
	if st.Out.ACR != "" {
		args = append(args, "-p", "acrName="+st.Out.ACR)
	}
	if st.AlertEmail != "" {
		args = append(args, "-p", "alertEmail="+st.AlertEmail)
	}
	deploy := func(sku string) error {
		a := args
		if sku != "" {
			a = append(append([]string{}, args...), "-p", "postgresSku="+sku)
		}
		return u.az(nil, append(a, "--query", "properties.provisioningState")...)
	}
	u.out.errf("        about 8 minutes")
	err = deploy(st.PostgresSku)
	if err != nil && strings.Contains(cmdOutput(err), "CapacityNotAvailable") {
		if st.PostgresSku != "" {
			return fmt.Errorf("Postgres %s has no capacity in %s. Run again with --postgres-sku %s or with --region and a new --state file.\n%v", st.PostgresSku, st.Region, instanceUpPGFallback, err)
		}
		u.out.errf("        Postgres has no capacity for the default size in %s; deploying again with postgresSku=%s", st.Region, instanceUpPGFallback)
		st.PostgresSku = instanceUpPGFallback
		err = deploy(st.PostgresSku)
	}
	if err != nil {
		return err
	}
	var outputs map[string]struct {
		Value any `json:"value"`
	}
	if err := u.az(&outputs, "deployment", "group", "show", "-g", st.ResourceGroup, "-n", instanceUpDeployment, "--query", "properties.outputs"); err != nil {
		return err
	}
	host, _ := outputs["host"].Value.(string)
	if host == "" {
		return fmt.Errorf("the deployment %s has no output host", instanceUpDeployment)
	}
	st.Out.Host = host
	u.out.errf("        Container Apps host %s", host)
	return nil
}

// instanceUpBicepHasImageDefault reports whether the embedded main.bicep gives
// image a default, so a deploy without --image takes the template's version.
func instanceUpBicepHasImageDefault() bool {
	b, err := assets.Azure.ReadFile("azure/main.bicep")
	return err == nil && regexp.MustCompile(`(?m)^param image string\s*=`).Match(b)
}

// stepUpReady waits until https://<host>/readyz answers 200.
func stepUpReady(u *instanceUp) error {
	url := "https://" + u.st.host() + "/readyz"
	var last string
	for i := 0; i < 120; i++ {
		ctx, cancel := context.WithTimeout(u.ctx, 20*time.Second)
		code, err := instanceUpGet(ctx, url)
		cancel()
		if err == nil && code == 200 {
			u.out.errf("        %s answers 200", url)
			return nil
		}
		last = fmt.Sprintf("status %d", code)
		if err != nil {
			last = err.Error()
		}
		instanceUpSleep(10 * time.Second)
	}
	return fmt.Errorf("%s did not answer 200 within 20 minutes; last: %s", url, last)
}

// entraNames are the app and group names. They carry the instance name, so
// two instances in one tenant never share an app.
func (st *instanceUpState) entraNames() (app, group string) {
	return "Barkpark " + st.Name, "Barkpark " + st.Name + " owners"
}

func (st *instanceUpState) secretFile() string {
	return filepath.Join(filepath.Dir(st.EnvFile), instanceUpSecretFile)
}

var instanceUpEntraLine = regexp.MustCompile(`(?m)^(Tenant id|Client id|Owners group id|Secret expires):\s*(\S+)\s*$`)

// stepUpEntra runs the embedded entra-app-register.sh. It writes the client
// secret to the secret file, mode 600, and prints the ids, which this step
// reads.
func stepUpEntra(u *instanceUp) error {
	st := u.st
	tmp, err := os.CreateTemp("", "entra-app-register-*.sh")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(assets.EntraScript); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	app, group := st.entraNames()
	stdout, err := u.run(instanceUpCmd{name: "bash", args: []string{tmp.Name(), "--host", st.host(), "--org", st.Org,
		"--secret-file", st.secretFile(), "--add-owner", st.Owner, "--org-name", st.OrgName,
		"--name", app, "--owners-group", group}, stream: true})
	if err != nil {
		return err
	}
	got := map[string]string{}
	for _, m := range instanceUpEntraLine.FindAllStringSubmatch(stdout, -1) {
		got[m[1]] = m[2]
	}
	if got["Tenant id"] == "" || got["Client id"] == "" || got["Owners group id"] == "" {
		return fmt.Errorf("entra-app-register.sh printed no tenant, client or group id")
	}
	if _, err := os.Stat(st.secretFile()); err != nil {
		return fmt.Errorf("the app %q has a client secret, but %s is missing. Entra never shows a secret again. Delete the app's secret in the portal or the app itself, then run again", app, st.secretFile())
	}
	st.Tenant = got["Tenant id"]
	st.Out.AppID, st.Out.OwnersGroupID, st.Out.SecretExpires = got["Client id"], got["Owners group id"], got["Secret expires"]
	u.out.errf("        app %s (%s), group %s, secret in %s, expires %s", app, st.Out.AppID, group, st.secretFile(), st.Out.SecretExpires)
	return nil
}

// adminToken reads the instance's admin token: from the VM over ssh, or the
// seed token in the settings file on Container Apps. It is never printed.
func (u *instanceUp) adminToken() (string, error) {
	if u.st.Path == instanceTargetVM {
		tok, err := u.ssh("sudo cat /etc/barkpark/admin-token", nil, false)
		tok = strings.TrimSpace(tok)
		if err == nil && tok == "" {
			err = fmt.Errorf("/etc/barkpark/admin-token on the VM is empty")
		}
		return tok, err
	}
	f, err := os.Open(u.st.EnvFile)
	if err != nil {
		return "", err
	}
	defer f.Close()
	env, err := parseInstanceEnv(f)
	if err != nil {
		return "", err
	}
	if env["BARKPARK_SEED_ADMIN_TOKEN"] == "" {
		return "", fmt.Errorf("%s has no BARKPARK_SEED_ADMIN_TOKEN", u.st.EnvFile)
	}
	return env["BARKPARK_SEED_ADMIN_TOKEN"], nil
}

// bp runs this bp binary against the instance. The token goes in the
// environment, never on argv.
func (u *instanceUp) bp(token string, stdin []byte, args ...string) (string, error) {
	self, err := instanceUpSelf()
	if err != nil {
		return "", err
	}
	return u.run(instanceUpCmd{name: self, args: args, stdin: stdin,
		env: []string{"BARKPARK_API_URL=https://" + u.st.host(), "BARKPARK_API_TOKEN=" + token}})
}

func alreadyExists(err error) bool {
	s := strings.ToLower(cmdOutput(err))
	return strings.Contains(s, "already") || strings.Contains(s, "has been taken") || strings.Contains(s, "exists")
}

// stepUpConnect makes the instance bp's active server, then creates the
// organization and its OIDC connection with the owners group mapped to
// owner, and counts Entra MFA as Barkpark MFA.
func stepUpConnect(u *instanceUp) error {
	st := u.st
	token, err := u.adminToken()
	if err != nil {
		return err
	}
	if err := instanceUpConnect(u.out, u.g, "https://"+st.host(), token); err != nil {
		return err
	}
	if _, err := u.bp(token, nil, "org", "create", st.Org, st.OrgName, "--yes"); err != nil && !alreadyExists(err) {
		return err
	}
	if _, err := u.bp(token, nil, "org", "attach-workspace", st.Org, "default", "--yes"); err != nil {
		return err
	}
	secret, err := os.ReadFile(st.secretFile())
	if err != nil {
		return err
	}
	mapping := fmt.Sprintf(`group_role_mappings:={"%s":"owner"}`, st.Out.OwnersGroupID)
	scopes := "openid profile email"
	create := []string{"org", "oidc-create", st.Org, "https://login.microsoftonline.com/" + st.Tenant + "/v2.0", st.Out.AppID, "-",
		"--tenant_id", st.Tenant, "--scopes", scopes, "--strict_validation", "--set", mapping, "--yes"}
	if st.Out.SecretExpires != "" && st.Out.SecretExpires != "unknown" {
		create = append(create, "--client_secret_expires_at", st.Out.SecretExpires)
	}
	if _, err := u.bp(token, []byte(strings.TrimSpace(string(secret))), create...); err != nil {
		if !alreadyExists(err) {
			return err
		}
		u.out.errf("        the OIDC connection exists; setting its scopes and mapping")
		if _, err := u.bp(token, nil, "org", "oidc-update", st.Org, "--set", "client_id="+st.Out.AppID, "--scopes", scopes, "--set", mapping, "--yes"); err != nil {
			return err
		}
	}
	if _, err := u.bp(token, nil, "org", "oidc-update", st.Org, "--trust_idp_mfa", "--yes"); err != nil {
		return err
	}
	u.out.errf("        organization %s connected to Entra; group %s maps to owner", st.Org, st.Out.OwnersGroupID)
	return nil
}

// stepUpVerify runs bp instance check with the TLS probe of PHX_HOST.
func stepUpVerify(u *instanceUp) error {
	return u.checkEnv(map[string]bool{"database": true, "media": true})
}
