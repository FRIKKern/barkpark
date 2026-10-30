package cli

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// laneBTemplates stands for deploy/azure with the Entra and registry files.
func laneBTemplates(t *testing.T) {
	t.Helper()
	old := instanceUpAzureFS
	instanceUpAzureFS = fstest.MapFS{
		"azure/main.bicep":              {Data: []byte("param image string\nparam entraEnabled bool = false\n")},
		"azure/main.example.bicepparam": {Data: []byte("using 'main.bicep'\nvar l = loadTextContent('barkpark.env')\n")},
		"azure/entra.bicep":             {Data: []byte("param host string\n")},
		"azure/acr.bicep":               {Data: []byte("param acrName string\n")},
		"azure/acr-build.sh":            {Data: []byte("#!/bin/bash\n")},
		"azure/bicepconfig.json":        {Data: []byte("{}\n")},
	}
	t.Cleanup(func() { instanceUpAzureFS = old })
}

func TestInstanceUpContainerAppsWithBicepEntraAndACRScript(t *testing.T) {
	f := stubInstanceUp(t)
	laneBTemplates(t)
	f.reply = func(c instanceUpCmd) (string, error) {
		s := c.String()
		switch {
		case strings.HasPrefix(s, "az deployment group create") && strings.Contains(s, "acr.bicep"):
			return `{"acrName":{"value":"crbarkpark1"},"loginServer":{"value":"crbarkpark1.azurecr.io"}}`, nil
		case strings.HasPrefix(s, "bash ") && strings.Contains(s, "acr-build.sh"):
			return "step\ncrbarkpark1.azurecr.io/barkpark:sha-0123456789ab\n", nil
		case strings.HasPrefix(s, "az deployment group show"):
			return `{"host":{"value":"app.norwayeast.azurecontainerapps.io"},"entraTenantId":{"value":"tenant-1"},"entraClientId":{"value":"app-9"},"entraOwnersGroupId":{"value":"group-9"}}`, nil
		}
		return defaultUpReply(c)
	}
	stubRedirect(t, 302, "https://login.microsoftonline.com/tenant-1/oauth2/v2.0/authorize?x=1")
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com", "--from-source", "main")
	if code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	if f.has("az acr build") != 0 || f.has("acr-build.sh crbarkpark1 main") != 1 {
		t.Errorf("registry build:\n%s", f.dump())
	}
	if !strings.Contains(stderr, "built crbarkpark1.azurecr.io/barkpark:sha-0123456789ab") {
		t.Errorf("the image step does not name the image:\n%s", stderr)
	}
	dep := f.find("az deployment group create -g rg-aca -n barkpark ")
	for _, want := range []string{"image=crbarkpark1.azurecr.io/barkpark:sha-0123456789ab", "acrName=crbarkpark1", "entraEnabled=true", "entraOrg=pensum", `entraOwnerUpns=["owner@example.com"]`, "entraAddDeployer=false"} {
		if !strings.Contains(dep.String(), want) {
			t.Errorf("deploy lacks %q: %s", want, dep)
		}
	}
	if f.has("entra-app-register") != 0 || f.has("org oidc-create") != 0 || f.has("org create") != 0 {
		t.Errorf("ran the script path although main.bicep made the app:\n%s", f.dump())
	}
	if len(f.connects) != 1 {
		t.Errorf("bp was not connected")
	}
	if st := readUpState(t); !st.Out.EntraByBicep || st.Out.AppID != "app-9" {
		t.Errorf("state = %+v", st.Out)
	}
	if fi, err := os.Stat(filepath.Join(instanceUpAzureDir, "acr-build.sh")); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("acr-build.sh: %v", err)
	}
}

func TestInstanceUpVMWithEntraBicep(t *testing.T) {
	f := stubInstanceUp(t)
	laneBTemplates(t)
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az deployment group create") && strings.Contains(c.String(), "entra.bicep") {
			return `{"clientId":{"value":"app-7"},"appObjectId":{"value":"obj-7"},"ownersGroupId":{"value":"group-7"},"tenantId":{"value":"tenant-1"}}`, nil
		}
		return defaultUpReply(c)
	}
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	host := "pensum-cms.swedencentral.cloudapp.azure.com"
	ent := f.find("entra.bicep")
	for _, want := range []string{"-n barkpark-entra", "host=" + host, "org=pensum", `ownerUpns=["owner@example.com"]`, "addDeployer=false", "ownersGroupName=Barkpark pensum owners (" + host + ")"} {
		if !strings.Contains(ent.String(), want) {
			t.Errorf("entra.bicep deploy lacks %q: %s", want, ent)
		}
	}
	if f.has("entra-app-register") != 0 || f.has("--secret-file") != 0 {
		t.Errorf("the script ran after entra.bicep:\n%s", f.dump())
	}
	if len(f.graph) != 2 || !strings.HasSuffix(f.graph[1], "/applications/obj-7/addPassword") {
		t.Errorf("Graph calls: %v", f.graph)
	}
	if f.has("org oidc-create") != 1 || !strings.Contains(f.find("org oidc-create").String(), `{"group-7":"owner"}`) {
		t.Errorf("the VM path connects the org with bp org")
	}
}

// A rerun that has the secret file keeps it and makes no second secret.
func TestInstanceUpVMKeepsTheSecretFile(t *testing.T) {
	f := stubInstanceUp(t)
	f.creds = `[{"displayName":"other","endDateTime":"2028-01-01T00:00:00Z"},{"displayName":"barkpark-pensum","endDateTime":"2027-05-01T08:00:00.5Z"}]`
	if err := os.WriteFile(instanceUpSecretFile, []byte("kept-secret\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	for _, g := range f.graph {
		if strings.Contains(g, "addPassword") {
			t.Errorf("a second secret was made: %v", f.graph)
		}
	}
	if f.tokenTries != 0 {
		t.Errorf("waited for a kept secret")
	}
	if st := readUpState(t); st.Out.SecretExpires != "2027-05-01T08:00:00Z" {
		t.Errorf("expiry = %q", st.Out.SecretExpires)
	}
	if fi, _ := os.Stat(instanceUpSecretFile); fi.Mode().Perm() != 0o600 {
		t.Errorf("secret file mode %v", fi.Mode().Perm())
	}
	if oidc := f.find("org oidc-create"); string(oidc.stdin) != "kept-secret" {
		t.Errorf("oidc-create stdin = %q", oidc.stdin)
	}
}

// An app with a secret but no secret file stops the step: Entra never shows
// the secret again.
func TestInstanceUpVMStopsWhenTheSecretFileIsGone(t *testing.T) {
	f := stubInstanceUp(t)
	f.creds = `[{"displayName":"barkpark-pensum","endDateTime":"2027-05-01T08:00:00Z"}]`
	_, stderr, code := runUp(t, vmArgs()...)
	if code == exitOK || !strings.Contains(stderr, "Entra never shows a secret again") {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	for _, g := range f.graph {
		if strings.Contains(g, "addPassword") {
			t.Errorf("a secret was made: %v", f.graph)
		}
	}
}

// Graph can answer 404 for an app entra.bicep just made. Up asks again until
// Graph knows it, and waits until Entra accepts the new secret.
func TestInstanceUpVMWaitsForEntraToReplicate(t *testing.T) {
	f := stubInstanceUp(t)
	misses := 0
	f.graphReply = func(method, url string) (int, string) {
		if method == "GET" && misses < 2 {
			misses++
			return 404, `{"error":{"code":"Request_ResourceNotFound","message":"Resource 'obj-1' does not exist"}}`
		}
		return f.graphDefault(method, url)
	}
	f.refusals = 2
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if len(f.graph) != 4 {
		t.Errorf("Graph calls: %v", f.graph)
	}
	if f.tokenTries != 5 {
		t.Errorf("token requests = %d, want 2 refused then 3 accepted", f.tokenTries)
	}
}

// Without entra.bicep in the assets, up runs entra-app-register.sh.
func TestInstanceUpVMRunsTheScriptWithoutEntraBicep(t *testing.T) {
	f := stubInstanceUp(t)
	old := instanceUpAzureFS
	instanceUpAzureFS = fstest.MapFS{"azure/main.bicep": {Data: []byte("param image string\n")}}
	t.Cleanup(func() { instanceUpAzureFS = old })
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	script := f.find("--secret-file")
	if !strings.Contains(script.String(), "--name Barkpark pensum (pensum-cms.swedencentral.cloudapp.azure.com)") || len(f.graph) != 0 {
		t.Errorf("script call: %s, Graph calls %v", script, f.graph)
	}
}

func stubRedirect(t *testing.T, code int, loc string) *int {
	t.Helper()
	calls := 0
	old := instanceUpRedirect
	instanceUpRedirect = func(context.Context, string) (int, string, error) { calls++; return code, loc, nil }
	t.Cleanup(func() { instanceUpRedirect = old })
	return &calls
}

func TestInstanceUpContainerAppsFailsWhenTheImageDidNotConnectTheOrg(t *testing.T) {
	f := stubInstanceUp(t)
	laneBTemplates(t)
	stubRedirect(t, 404, "")
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az deployment group show") {
			return `{"host":{"value":"app.norwayeast.azurecontainerapps.io"},"entraTenantId":{"value":"tenant-1"},"entraClientId":{"value":"app-9"},"entraOwnersGroupId":{"value":"group-9"}}`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com")
	if code == exitOK || !strings.Contains(stderr, "did not connect pensum at its first boot") || !strings.Contains(stderr, "--from-source main") {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if st := readUpState(t); st.Done["connect"] != "" || st.Done["deploy"] == "" {
		t.Errorf("done = %v", st.Done)
	}
}
