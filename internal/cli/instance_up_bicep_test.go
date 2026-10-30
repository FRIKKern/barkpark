package cli

import (
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
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com", "--from-source", "main")
	if code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	if f.has("az acr build") != 0 || f.has("acr-build.sh crbarkpark1 main") != 1 {
		t.Errorf("registry build:\n%s", f.dump())
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
			return `{"clientId":{"value":"app-7"},"ownersGroupId":{"value":"group-7"},"tenantId":{"value":"tenant-1"}}`, nil
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
	script := f.find("--secret-file")
	if !strings.Contains(script.String(), "--app-id app-7") || strings.Contains(script.String(), "--name ") {
		t.Errorf("script call: %s", script)
	}
	if f.has("org oidc-create") != 1 {
		t.Errorf("the VM path connects the org with bp org")
	}
}
