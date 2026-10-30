package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// upFake stubs az, ssh, scp, ssh-keygen, bash and bp for one test. reply
// returns stdout and an error for one command; nil means "{}" and success.
type upFake struct {
	t        *testing.T
	calls    []instanceUpCmd
	reply    func(c instanceUpCmd) (string, error)
	readyz   int
	connects []string
}

func (f *upFake) has(sub string) int {
	n := 0
	for _, c := range f.calls {
		if strings.Contains(c.String(), sub) {
			n++
		}
	}
	return n
}

func (f *upFake) find(sub string) instanceUpCmd {
	for _, c := range f.calls {
		if strings.Contains(c.String(), sub) {
			return c
		}
	}
	f.t.Fatalf("no call contains %q; calls:\n%s", sub, f.dump())
	return instanceUpCmd{}
}

func (f *upFake) dump() string {
	var b strings.Builder
	for _, c := range f.calls {
		b.WriteString(c.String() + "\n")
	}
	return b.String()
}

const upToken = "bp_admin_0123456789abcdef0123456789abcdef0123456789abcd"

// defaultUpReply answers the commands of a run that goes through.
func defaultUpReply(c instanceUpCmd) (string, error) {
	s := c.String()
	switch {
	case strings.HasPrefix(s, "az account show"):
		return `{"id":"sub-1","name":"Test sub","tenantId":"tenant-1","user":{"name":"op@example.com"}}`, nil
	case strings.HasPrefix(s, "az provider list"):
		return allProvidersRegistered(), nil
	case strings.HasPrefix(s, "az vm list-skus"):
		return `[{"name":"Standard_D2als_v7","family":"standardDALSv7Family","capabilities":[{"name":"vCPUs","value":"2"}],"restrictions":[]}]`, nil
	case strings.HasPrefix(s, "az vm list-usage"):
		return `[{"currentValue":0,"limit":10,"name":{"value":"standardDALSv7Family"}},{"currentValue":2,"limit":10,"name":{"value":"cores"}}]`, nil
	case strings.HasPrefix(s, "az group show"), strings.HasPrefix(s, "az vm show"), strings.HasPrefix(s, "az acr show"):
		return "", &instanceUpCmdError{cmd: s, err: errors.New("exit status 3"), stderr: "(ResourceGroupNotFound) not found\n(ResourceNotFound) The Resource was not found."}
	case strings.HasPrefix(s, "az vm create"):
		return `{"publicIpAddress":"20.1.2.3","fqdns":"pensum-cms.swedencentral.cloudapp.azure.com"}`, nil
	case strings.HasPrefix(s, "az deployment group show"):
		return `{"host":{"type":"String","value":"barkpark.nicesea.norwayeast.azurecontainerapps.io"},"url":{"type":"String","value":"https://x"}}`, nil
	case strings.HasPrefix(s, "ssh") && strings.HasSuffix(s, "sudo cat /etc/barkpark/admin-token"):
		return upToken + "\n", nil
	case strings.HasPrefix(s, "bash "):
		for i, a := range c.args {
			if a == "--secret-file" {
				_ = os.WriteFile(c.args[i+1], []byte("entra-secret-value\n"), 0o600)
			}
		}
		return "\nTenant id:         tenant-1\nClient id:         app-1\nOwners group id:   group-1\nSecret expires:    2027-10-30T10:00:00Z\n", nil
	}
	return "{}", nil
}

func stubInstanceUp(t *testing.T) *upFake {
	t.Helper()
	f := &upFake{t: t, reply: defaultUpReply, readyz: 200}
	oldRun, oldGet, oldSleep, oldSelf, oldConnect := instanceUpRun, instanceUpGet, instanceUpSleep, instanceUpSelf, instanceUpConnect
	instanceUpRun = func(_ context.Context, _ io.Writer, c instanceUpCmd) (string, error) {
		f.calls = append(f.calls, c)
		return f.reply(c)
	}
	instanceUpGet = func(context.Context, string) (int, error) { return f.readyz, nil }
	instanceUpSleep = func(time.Duration) {}
	instanceUpSelf = func() (string, error) { return "bp", nil }
	instanceUpConnect = func(_ *writer, _ globals, server, token string) error {
		f.connects = append(f.connects, server)
		if token != upToken && !strings.HasPrefix(token, "bp_admin_") {
			t.Errorf("connect got token %q", token)
		}
		return nil
	}
	stubInstanceProbes(t, allExtensions, nil)
	t.Cleanup(func() {
		instanceUpRun, instanceUpGet, instanceUpSleep, instanceUpSelf, instanceUpConnect = oldRun, oldGet, oldSleep, oldSelf, oldConnect
	})
	dir := t.TempDir()
	wd, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })
	return f
}

func runUp(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{output: "table", outputSet: true}
	w.applyGlobals(g)
	code := runInstance(w, g, append([]string{"up"}, args...))
	return stdout.String(), stderr.String(), code
}

func vmArgs() []string {
	return []string{"--azure", "--path", "vm", "--resource-group", "rg-test", "--host", "pensum-cms",
		"--owner", "owner@example.com", "--breakglass", "glass@example.com", "--ssh-key", "key/barkpark"}
}

func readUpState(t *testing.T) instanceUpState {
	t.Helper()
	b, err := os.ReadFile(instanceUpStateFile)
	if err != nil {
		t.Fatal(err)
	}
	var st instanceUpState
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestInstanceUpVMRunsEveryStepThenResumesWithNone(t *testing.T) {
	f := stubInstanceUp(t)
	if err := os.MkdirAll("key", 0o700); err != nil {
		t.Fatal(err)
	}
	stdout, stderr, code := runUp(t, append(vmArgs(), "--image", "ghcr.io/frikkern/barkpark:0.2.31")...)
	if code != exitOK {
		t.Fatalf("exit %d\n%s\ncalls:\n%s", code, stderr, f.dump())
	}
	host := "pensum-cms.swedencentral.cloudapp.azure.com"
	create := f.find("az vm create")
	for _, want := range []string{"-g rg-test", "--size Standard_D2als_v7", "--public-ip-address-dns-name pensum-cms", "--ssh-key-values key/barkpark.pub", "--admin-username azureuser"} {
		if !strings.Contains(create.String(), want) {
			t.Errorf("vm create lacks %q: %s", want, create)
		}
	}
	if f.has("az group create -n rg-test -l swedencentral") != 1 {
		t.Errorf("group create missing:\n%s", f.dump())
	}
	deploy := f.find("bash -s")
	if !strings.Contains(deploy.String(), "DOMAIN="+host) || !strings.Contains(deploy.String(), "BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.31") || !strings.Contains(deploy.String(), "BARKPARK_ENV_FILE=/tmp/pensum.env") {
		t.Errorf("deploy call: %s", deploy)
	}
	if !bytes.HasPrefix(deploy.stdin, []byte("#!/usr/bin/env bash")) {
		t.Errorf("deploy.sh not streamed on stdin")
	}
	for _, want := range []string{"StrictHostKeyChecking=accept-new", "UserKnownHostsFile=" + instanceUpStateFile + ".known_hosts", "BatchMode=yes"} {
		if !strings.Contains(deploy.String(), want) {
			t.Errorf("ssh lacks %q", want)
		}
	}
	entra := f.find("--owners-group")
	for _, want := range []string{"--host " + host, "--org pensum", "--add-owner owner@example.com", "--name Barkpark pensum (" + host + ")", "--owners-group Barkpark pensum owners (" + host + ")"} {
		if !strings.Contains(entra.String(), want) {
			t.Errorf("entra call lacks %q: %s", want, entra)
		}
	}
	oidc := f.find("org oidc-create")
	if string(oidc.stdin) != "entra-secret-value" {
		t.Errorf("oidc-create stdin = %q", oidc.stdin)
	}
	for _, want := range []string{"https://login.microsoftonline.com/tenant-1/v2.0 app-1 -", `group_role_mappings:={"group-1":"owner"}`, "--client_secret_expires_at 2027-10-30T10:00:00Z", "--strict_validation"} {
		if !strings.Contains(oidc.String(), want) {
			t.Errorf("oidc-create lacks %q: %s", want, oidc)
		}
	}
	if f.has("--trust_idp_mfa") != 1 {
		t.Errorf("trust_idp_mfa not set")
	}
	for _, c := range f.calls {
		if strings.Contains(c.String(), upToken) || strings.Contains(c.String(), "entra-secret-value") {
			t.Errorf("a secret is on argv: %s", c)
		}
		if c.name == "bp" && !slicesContain(c.env, "BARKPARK_API_TOKEN="+upToken) {
			t.Errorf("bp call without the token in env: %s", c)
		}
	}
	if len(f.connects) != 1 || f.connects[0] != "https://"+host {
		t.Errorf("connects = %v", f.connects)
	}
	if !strings.Contains(stdout, "https://"+host+"/v1/auth/oidc/pensum/start") || !strings.Contains(stdout, "bp org auth-methods pensum sso --yes") {
		t.Errorf("stdout lacks the sign-in link or next steps:\n%s", stdout)
	}
	for _, s := range []string{stdout, stderr} {
		if strings.Contains(s, upToken) || strings.Contains(s, "entra-secret-value") {
			t.Errorf("output holds a secret")
		}
	}
	st := readUpState(t)
	if len(st.Done) != len(instanceUpSteps("vm")) || st.Out.IP != "20.1.2.3" || st.Out.AppID != "app-1" {
		t.Errorf("state = %+v", st)
	}
	raw, _ := os.ReadFile(instanceUpStateFile)
	env, _ := os.ReadFile("barkpark.env")
	for _, line := range strings.Split(string(env), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok && v != "" && (slicesContain(instanceSecretNames, k) || k == "DATABASE_URL") && strings.Contains(string(raw), v) {
			t.Errorf("state file holds %s", k)
		}
	}
	if fi, _ := os.Stat("barkpark.env"); fi.Mode().Perm() != 0o600 {
		t.Errorf("env mode %v", fi.Mode().Perm())
	}

	// A rerun with no flags repeats only the az sign-in check.
	f.calls = nil
	_, stderr, code = runUp(t)
	if code != exitOK {
		t.Fatalf("rerun exit %d: %s", code, stderr)
	}
	for _, c := range f.calls {
		if c.String() != "az account show -o json" {
			t.Errorf("rerun ran %s", c)
		}
	}
}

func slicesContain(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func TestInstanceUpResumesAtTheFailedStep(t *testing.T) {
	f := stubInstanceUp(t)
	failDeploy := true
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasSuffix(c.String(), "bash -s") && failDeploy {
			return "", &instanceUpCmdError{cmd: c.String(), err: errors.New("exit status 1"), stderr: "!! build failed"}
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, vmArgs()...)
	if code == exitOK || !strings.Contains(stderr, "resumes at this step") || !strings.Contains(stderr, "build failed") {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if st := readUpState(t); st.Done["vm"] == "" || st.Done["deploy"] != "" {
		t.Fatalf("done = %v", st.Done)
	}
	failDeploy = false
	f.calls = nil
	_, stderr, code = runUp(t, vmArgs()...)
	if code != exitOK {
		t.Fatalf("resume exit %d: %s", code, stderr)
	}
	if f.has("az vm create") != 0 || f.has("az group create") != 0 || f.has("az provider") != 0 {
		t.Errorf("resume repeated a finished step:\n%s", f.dump())
	}
	if f.has("bash -s") != 1 {
		t.Errorf("resume did not deploy")
	}
	if strings.Contains(f.find("bash -s").String(), "BARKPARK_IMAGE") {
		t.Errorf("no --image must leave the image to deploy.sh")
	}
}

func TestInstanceUpVMExistingKeepsTheVM(t *testing.T) {
	f := stubInstanceUp(t)
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az vm show") {
			return `{"publicIps":"20.9.9.9","fqdns":""}`, nil
		}
		if strings.HasPrefix(c.String(), "az group show") {
			return `{"location":"swedencentral"}`, nil
		}
		return defaultUpReply(c)
	}
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if f.has("az vm create") != 0 || f.has("az group create") != 0 {
		t.Errorf("created over an existing resource:\n%s", f.dump())
	}
	if !strings.Contains(f.find("bash -s").String(), "azureuser@20.9.9.9") {
		t.Errorf("deploy went elsewhere")
	}
}

func TestInstanceUpContainerAppsFallsBackOnPostgresCapacity(t *testing.T) {
	f := stubInstanceUp(t)
	f.reply = func(c instanceUpCmd) (string, error) {
		s := c.String()
		if strings.HasPrefix(s, "az deployment group create") && !strings.Contains(s, "postgresSku=") {
			return "", &instanceUpCmdError{cmd: s, err: errors.New("exit status 1"), stderr: `{"code":"CapacityNotAvailable"}`}
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com", "--from-source", "main")
	if code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	if f.has("az deployment group create") != 2 || f.has("postgresSku=Standard_B2s") != 1 {
		t.Errorf("no fallback:\n%s", f.dump())
	}
	st := readUpState(t)
	acr := st.acrName()
	build := f.find("az acr build")
	for _, want := range []string{"-r " + acr, "-t barkpark:main", "-f api/Dockerfile", "https://github.com/FRIKKern/barkpark.git#main"} {
		if !strings.Contains(build.String(), want) {
			t.Errorf("acr build lacks %q: %s", want, build)
		}
	}
	dep := f.find("postgresSku=Standard_B2s")
	if !strings.Contains(dep.String(), "image="+acr+".azurecr.io/barkpark:main") || !strings.Contains(dep.String(), "acrName="+acr) {
		t.Errorf("deploy lacks the built image: %s", dep)
	}
	if st.Out.Host != "barkpark.nicesea.norwayeast.azurecontainerapps.io" || st.Region != "norwayeast" || st.PostgresSku != "Standard_B2s" {
		t.Errorf("state = %+v", st)
	}
	param, err := os.ReadFile(filepath.Join(instanceUpAzureDir, "main.bicepparam"))
	if err != nil || !strings.Contains(string(param), "loadTextContent('../barkpark.env')") {
		t.Errorf("main.bicepparam: %v\n%s", err, param)
	}
	oidc := f.find("org oidc-create")
	if !slicesContain(oidc.env, "BARKPARK_API_URL=https://barkpark.nicesea.norwayeast.azurecontainerapps.io") {
		t.Errorf("oidc env = %v", oidc.env)
	}
	env, _ := os.ReadFile("barkpark.env")
	if !strings.Contains(string(env), "# BARKPARK_BREAKGLASS_EMAILS=") {
		t.Errorf("no break-glass line must be a comment:\n%s", env)
	}
}

func TestInstanceUpQuotaHint(t *testing.T) {
	f := stubInstanceUp(t)
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az vm list-usage") {
			return `[{"currentValue":10,"limit":10,"name":{"value":"standardDALSv7Family"}}]`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, append(vmArgs(), "--region", "norwayeast")...)
	if code == exitOK || !strings.Contains(stderr, "quota") || !strings.Contains(stderr, "--region swedencentral --size Standard_D2als_v7") {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if f.has("az group create") != 0 {
		t.Errorf("went on after the quota check")
	}
}

func TestInstanceUpFlagErrors(t *testing.T) {
	stubInstanceUp(t)
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"--path", "vm", "--resource-group", "rg", "--owner", "o@x.no", "--host", "l"}, "--azure is required"},
		{[]string{"--azure", "--path", "k8s", "--resource-group", "rg", "--owner", "o@x.no"}, "use vm or containerapps"},
		{[]string{"--azure", "--path", "vm", "--resource-group", "rg", "--owner", "o@x.no"}, "--host is required"},
		{[]string{"--azure", "--path", "containerapps", "--resource-group", "rg", "--owner", "o@x.no", "--host", "label"}, "your own domain"},
		{[]string{"--azure", "--path", "vm", "--resource-group", "rg", "--owner", "o@x.no", "--host", "l", "--image", "a", "--from-source", "main"}, "not both"},
		{[]string{"--azure", "--path", "vm", "--resource-group", "rg", "--host", "l"}, "--owner is required"},
	} {
		_, stderr, code := runUp(t, tc.args...)
		if code != exitUsage || !strings.Contains(stderr, tc.want) {
			t.Errorf("%v: exit %d, stderr %q", tc.args, code, stderr)
		}
	}
}

func TestInstanceUpRefusesAnotherInstanceInTheStateFile(t *testing.T) {
	stubInstanceUp(t)
	st := instanceUpState{Format: instanceUpStateFormat, Path: "vm", ResourceGroup: "rg-one", Done: map[string]string{}}
	b, _ := json.Marshal(st)
	if err := os.WriteFile(instanceUpStateFile, b, 0o600); err != nil {
		t.Fatal(err)
	}
	_, stderr, code := runUp(t, vmArgs()...)
	if code != exitUsage || !strings.Contains(stderr, "the state file is for \"rg-one\"") {
		t.Fatalf("exit %d: %s", code, stderr)
	}
}

func TestShQuote(t *testing.T) {
	for in, want := range map[string]string{"main": "main", "a b": "'a b'", "it's": `'it'"'"'s'`, "": "''", "ghcr.io/x/y:1.2": "ghcr.io/x/y:1.2"} {
		if got := shQuote(in); got != want {
			t.Errorf("shQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

func allProvidersRegistered() string {
	var rows []string
	for _, p := range [][]string{instanceUpProviders(&instanceUpState{Path: "vm"}), instanceUpProviders(&instanceUpState{Path: "containerapps", FromSource: "x"})} {
		for _, ns := range p {
			rows = append(rows, `{"n":"`+ns+`","s":"Registered"}`)
		}
	}
	return "[" + strings.Join(rows, ",") + "]"
}

func TestInstanceUpRegistersMissingProviders(t *testing.T) {
	f := stubInstanceUp(t)
	listed := 0
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az provider list") {
			listed++
			if listed == 1 {
				return `[{"n":"Microsoft.Compute","s":"NotRegistered"},{"n":"Microsoft.Network","s":"Registered"}]`, nil
			}
		}
		return defaultUpReply(c)
	}
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if f.has("az provider register --namespace Microsoft.Compute") != 1 || f.has("az provider register --namespace Microsoft.Network") != 0 || listed != 2 {
		t.Errorf("registered wrong providers (listed %d):\n%s", listed, f.dump())
	}
}
