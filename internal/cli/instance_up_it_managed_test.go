package cli

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"
)

// instance_up_it_managed_test.go covers bp instance up in a subscription where
// IT owns the network and the app registration: --subnet-id, --public-ip,
// --vm-name, --entra-app-id, --assign-identity and --entra-ssh, and
// bp instance resize. az, ssh and bp are stubbed; nothing reaches Azure.

const (
	itSubnet = "/subscriptions/sub-1/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-it/subnets/snet-it"
	itApp    = "0f8c1a52-3b7e-4d0a-9c1e-2a4b6c8d0e1f"
	itHost   = "pensum-cms.westeurope.cloudapp.azure.com"
)

// itReply answers the calls of an IT-managed run on top of defaultUpReply.
// redirects is the app's Web redirect URIs, nsg the subnet's group id and
// vmSecret what the VM says about its secret file.
type itReply struct {
	redirects, nsg, vnetRegion, vmSecret string
	pipExists                            bool
}

func newITReply() *itReply {
	return &itReply{
		redirects:  `["https://` + itHost + `/v1/auth/oidc/pensum/callback"]`,
		nsg:        `{"id":"/subscriptions/sub-1/resourceGroups/rg-net/providers/Microsoft.Network/networkSecurityGroups/nsg-it"}`,
		vnetRegion: "westeurope",
		vmSecret:   "missing",
	}
}

func (r *itReply) reply(c instanceUpCmd) (string, error) {
	s := c.String()
	switch {
	case strings.HasPrefix(s, "az rest --method get") && strings.Contains(s, "Microsoft.Compute/skus"):
		return `{"value":[{"name":"Standard_D4ls_v7","resourceType":"virtualMachines","family":"standardDLSv7Family","capabilities":[{"name":"vCPUs","value":"4"}]}]}`, nil
	case strings.HasPrefix(s, "az vm list-usage"):
		return `[{"currentValue":0,"limit":350,"name":{"value":"standardDLSv7Family"}},{"currentValue":0,"limit":350,"name":{"value":"cores"}}]`, nil
	case strings.HasPrefix(s, "az network vnet subnet show"):
		return `{"networkSecurityGroup":` + r.nsg + `}`, nil
	case strings.HasPrefix(s, "az network vnet show"):
		return `{"location":"` + r.vnetRegion + `"}`, nil
	case strings.HasPrefix(s, "az network public-ip show"):
		if r.pipExists {
			return `{"fqdn":"` + itHost + `"}`, nil
		}
		return "", &instanceUpCmdError{cmd: s, err: errors.New("exit status 3"), stderr: "(ResourceNotFound) The Resource was not found."}
	case strings.HasPrefix(s, "az vm create"):
		return `{"publicIpAddress":"40.1.2.3","fqdns":"` + itHost + `"}`, nil
	case strings.HasPrefix(s, "az ad app show"):
		return `{"appId":"` + itApp + `","redirects":` + r.redirects + `}`, nil
	case strings.HasPrefix(s, "az ad app credential reset"):
		return `"entra-secret-value"`, nil
	case strings.HasPrefix(s, "ssh") && strings.Contains(s, "sudo test -s "+instanceUpVMSecret):
		return r.vmSecret + "\n", nil
	case strings.HasPrefix(s, "ssh") && strings.HasSuffix(s, "sudo cat "+instanceUpVMSecret):
		return "entra-secret-value\n", nil
	}
	return defaultUpReply(c)
}

func itArgs() []string {
	return []string{"--azure", "--path", "vm", "--resource-group", "rg-box", "--host", "pensum-cms",
		"--owner", "owner@example.com", "--ssh-key", "key/barkpark", "--image", "ghcr.io/frikkern/barkpark:0.2.41",
		"--subnet-id", itSubnet, "--public-ip", "pip-box", "--vm-name", "vm-box", "--entra-app-id", itApp,
		"--entra-ssh", "--size", "Standard_D4ls_v7", "--disk-sku", "Premium_LRS", "--disk-gb", "128"}
}

func TestInstanceUpITManagedSubnetAndApp(t *testing.T) {
	f := stubInstanceUp(t)
	r := newITReply()
	f.reply = r.reply
	_ = os.MkdirAll("key", 0o700)

	stdout, stderr, code := runUp(t, itArgs()...)
	if code != exitOK {
		t.Fatalf("exit %d\n%s\ncalls:\n%s", code, stderr, f.dump())
	}
	create := f.find("az vm create")
	for _, want := range []string{"-n vm-box", "--image Canonical:ubuntu-24_04-lts:server:latest", "--location westeurope",
		"--subnet " + itSubnet + " --nsg  ", "--public-ip-address pip-box", "--public-ip-address-dns-name pensum-cms",
		"--assign-identity [system]", "--size Standard_D4ls_v7", "--storage-sku Premium_LRS", "--os-disk-size-gb 128"} {
		if !strings.Contains(create.String(), want) {
			t.Errorf("vm create lacks %q: %s", want, create)
		}
	}
	var nsgArg bool
	for i, a := range create.args {
		nsgArg = nsgArg || (a == "--nsg" && i+1 < len(create.args) && create.args[i+1] == "")
	}
	if !nsgArg {
		t.Errorf("vm create does not pass --nsg \"\": %q", create.args)
	}
	if f.has("open-port") != 0 {
		t.Errorf("up opened a port in IT's network:\n%s", f.dump())
	}
	ext := f.find("az vm extension set")
	if !strings.Contains(ext.String(), "--vm-name vm-box") || !strings.Contains(ext.String(), "--name AADSSHLoginForLinux") {
		t.Errorf("extension call: %s", ext)
	}
	if f.has("entra.bicep") != 0 || len(f.graph) != 0 || f.has("--secret-file") != 0 {
		t.Errorf("up registered an app of its own:\n%s\ngraph %v", f.dump(), f.graph)
	}
	reset := f.find("az ad app credential reset")
	for _, want := range []string{"--id " + itApp, "--append", "--display-name barkpark-pensum-", "--end-date ", "--query password"} {
		if !strings.Contains(reset.String(), want) {
			t.Errorf("credential reset lacks %q: %s", want, reset)
		}
	}
	write := f.find("cat > " + instanceUpVMSecret + ".new")
	if string(write.stdin) != "entra-secret-value\n" || !strings.Contains(write.String(), "umask 077") {
		t.Errorf("secret write to the VM: %s stdin %q", write, write.stdin)
	}
	if _, err := os.Stat(instanceUpSecretFile); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the client secret reached this machine's disk: %v", err)
	}
	if f.tokenTries != 3 {
		t.Errorf("token requests = %d", f.tokenTries)
	}
	oidc := f.find("org oidc-create")
	if string(oidc.stdin) != "entra-secret-value" {
		t.Errorf("oidc-create stdin = %q", oidc.stdin)
	}
	if strings.Contains(oidc.String(), "group_role_mappings") || !strings.Contains(oidc.String(), itApp) {
		t.Errorf("oidc-create: %s", oidc)
	}
	for _, c := range f.calls {
		if strings.Contains(c.String(), "entra-secret-value") || strings.Contains(c.String(), upToken) {
			t.Errorf("a secret is on argv: %s", c)
		}
	}
	for _, s := range []string{stdout, stderr} {
		if strings.Contains(s, "entra-secret-value") || strings.Contains(s, upToken) {
			t.Errorf("output holds a secret")
		}
	}
	if !strings.Contains(stderr, "nsg-it decides the open ports") {
		t.Errorf("stderr does not name the subnet's group:\n%s", stderr)
	}
	if !strings.Contains(stdout, "https://"+itHost+"/v1/auth/oidc/pensum/start") || !strings.Contains(stdout, instanceUpVMSecret) {
		t.Errorf("stdout:\n%s", stdout)
	}
	st := readUpState(t)
	if st.Region != "westeurope" || st.VMName != "vm-box" || !st.EntraSSH || st.Out.AppID != itApp || st.Out.OwnersGroupID != "" {
		t.Errorf("state = %+v", st)
	}

	// A rerun after the entra step was lost keeps the secret the VM has.
	delete(st.Done, "entra")
	delete(st.Done, "connect")
	delete(st.Done, "verify")
	writeUpState(t, st)
	f.calls = nil
	r.vmSecret = "present"
	if _, stderr, code := runUp(t); code != exitOK {
		t.Fatalf("rerun exit %d: %s", code, stderr)
	}
	if f.has("credential reset") != 0 {
		t.Errorf("rerun added a second secret:\n%s", f.dump())
	}
	if string(f.find("org oidc-create").stdin) != "entra-secret-value" {
		t.Errorf("rerun did not read the secret from the VM")
	}
}

func writeUpState(t *testing.T, st instanceUpState) {
	t.Helper()
	u := &instanceUp{st: &st, statePath: instanceUpStateFile}
	if err := u.save(); err != nil {
		t.Fatal(err)
	}
}

func TestInstanceUpExistingPublicIPKeepsItsLabel(t *testing.T) {
	f := stubInstanceUp(t)
	r := newITReply()
	r.pipExists = true
	f.reply = r.reply
	_ = os.MkdirAll("key", 0o700)
	if _, stderr, code := runUp(t, itArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	create := f.find("az vm create")
	if !strings.Contains(create.String(), "--public-ip-address pip-box") || strings.Contains(create.String(), "--public-ip-address-dns-name") {
		t.Errorf("vm create with an existing address: %s", create)
	}
}

func TestInstanceUpITManagedStops(t *testing.T) {
	for name, c := range map[string]struct {
		edit func(*itReply)
		args []string
		want string
	}{
		"redirect missing": {edit: func(r *itReply) { r.redirects = `["https://other.example.com/cb"]` },
			want: "has no Web redirect URI https://" + itHost + "/v1/auth/oidc/pensum/callback"},
		"subnet without a group": {edit: func(r *itReply) { r.nsg = "null" }, want: "has no network security group"},
		"region differs": {edit: func(r *itReply) { r.vnetRegion = "northeurope" }, args: []string{"--region", "westeurope"},
			want: "the subnet's VNet is in northeurope"},
	} {
		t.Run(name, func(t *testing.T) {
			f := stubInstanceUp(t)
			r := newITReply()
			c.edit(r)
			f.reply = r.reply
			_ = os.MkdirAll("key", 0o700)
			_, stderr, code := runUp(t, append(itArgs(), c.args...)...)
			if code == exitOK || !strings.Contains(stderr, c.want) {
				t.Fatalf("exit %d, stderr:\n%s\nwant %q", code, stderr, c.want)
			}
			if f.has("credential reset") != 0 {
				t.Errorf("a secret was made before the stop")
			}
		})
	}
}

func TestInstanceUpITFlagsNeedTheVMPath(t *testing.T) {
	stubInstanceUp(t)
	aca := []string{"--azure", "--path", "containerapps", "--resource-group", "rg", "--owner", "o@example.com"}
	for _, c := range []struct {
		args []string
		want string
	}{
		{append(aca, "--subnet-id", itSubnet), "--subnet-id needs --path vm"},
		{append(aca, "--entra-app-id", itApp), "--entra-app-id needs --path vm"},
		{append(aca, "--entra-ssh"), "--entra-ssh needs --path vm"},
		{append(vmArgs(), "--subnet-id", "snet-it"), "full resource id"},
		{append(vmArgs(), "--entra-app-id", "my-app"), "a GUID"},
		{append(vmArgs(), "--public-ip", "bad name;x"), "--public-ip"},
	} {
		_, stderr, code := runUp(t, c.args...)
		if code != exitUsage || !strings.Contains(stderr, c.want) {
			t.Errorf("%v: exit %d, stderr %q, want %q", c.args, code, stderr, c.want)
		}
		_ = os.Remove(instanceUpStateFile)
	}
}

func TestInstanceUpDefaultVMStillOpensPorts(t *testing.T) {
	f := stubInstanceUp(t)
	_ = os.MkdirAll("key", 0o700)
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	create := f.find("az vm create")
	if !strings.Contains(create.String(), "-n barkpark ") || !strings.Contains(create.String(), "--image "+instanceUpVMImage) ||
		strings.Contains(create.String(), "--subnet") || strings.Contains(create.String(), "--assign-identity") {
		t.Errorf("vm create: %s", create)
	}
	if f.has("az vm open-port -g rg-test -n barkpark --port 80,443") != 1 || f.has("extension set") != 0 {
		t.Errorf("calls:\n%s", f.dump())
	}
}

func TestInstanceResize(t *testing.T) {
	f := stubInstanceUp(t)
	_ = os.MkdirAll("key", 0o700)
	r := newITReply()
	f.reply = r.reply
	if _, stderr, code := runUp(t, itArgs()...); code != exitOK {
		t.Fatalf("up exit %d: %s", code, stderr)
	}

	_, stderr, code := runInstanceCmd(t, "resize", "--size", "Standard_D2s_v7")
	if code != exitUsage || !strings.Contains(stderr, "--yes") {
		t.Fatalf("resize without --yes: exit %d %s", code, stderr)
	}
	f.calls = nil
	stdout, stderr, code := runInstanceCmd(t, "resize", "--size", "Standard_D2s_v7", "--yes")
	if code != exitOK {
		t.Fatalf("resize exit %d: %s\n%s", code, stderr, f.dump())
	}
	if f.has("az vm resize -g rg-box -n vm-box --size Standard_D2s_v7") != 1 {
		t.Errorf("calls:\n%s", f.dump())
	}
	if !strings.Contains(stdout, "vm-box is now Standard_D2s_v7") || !strings.Contains(stderr, "from Standard_D4ls_v7 to Standard_D2s_v7") {
		t.Errorf("stdout %q stderr %q", stdout, stderr)
	}
	if st := readUpState(t); st.Size != "Standard_D2s_v7" {
		t.Errorf("state size %q", st.Size)
	}

	_ = os.Remove(instanceUpStateFile)
	if _, stderr, code := runInstanceCmd(t, "resize", "--size", "Standard_D2s_v7", "--yes"); code != exitUsage || !strings.Contains(stderr, "is missing") {
		t.Errorf("resize without a state file: exit %d %s", code, stderr)
	}
}

func runInstanceCmd(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{output: "table", outputSet: true}
	w.applyGlobals(g)
	code := runInstance(w, g, args)
	return stdout.String(), stderr.String(), code
}
