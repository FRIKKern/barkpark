package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// stubGHCR stands for ghcr.io with latest at the given version label.
func stubGHCR(t *testing.T, version string) {
	t.Helper()
	old := instanceUpFetch
	instanceUpFetch = func(_ context.Context, url, _, _ string) ([]byte, error) {
		switch {
		case strings.Contains(url, "/token?"):
			return []byte(`{"token":"t"}`), nil
		case strings.HasSuffix(url, "/manifests/latest"):
			return []byte(`{"manifests":[{"digest":"sha256:arm","platform":{"os":"linux","architecture":"arm64"}},{"digest":"sha256:amd","platform":{"os":"linux","architecture":"amd64"}}]}`), nil
		case strings.HasSuffix(url, "/manifests/sha256:amd"):
			return []byte(`{"config":{"digest":"sha256:cfg"}}`), nil
		case strings.HasSuffix(url, "/blobs/sha256:cfg"):
			return []byte(`{"config":{"Labels":{"org.opencontainers.image.version":"` + version + `"}}}`), nil
		case strings.HasSuffix(url, "/manifests/"+version):
			return []byte(`{}`), nil
		}
		return nil, fmt.Errorf("GET %s: status 404", url)
	}
	t.Cleanup(func() { instanceUpFetch = old })
}

func TestInstanceUpContainerAppsPinsTheLatestRelease(t *testing.T) {
	f := stubInstanceUp(t)
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az deployment group show") {
			return `{"host":{"value":"app.norwayeast.azurecontainerapps.io"},"entraTenantId":{"value":"tenant-1"},"entraClientId":{"value":"app-1"},"entraOwnersGroupId":{"value":"group-1"}}`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com")
	if code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	if f.has("image=ghcr.io/frikkern/barkpark:0.2.33") != 1 || f.has(":latest") != 0 {
		t.Errorf("image not pinned:\n%s", f.dump())
	}
	if st := readUpState(t); st.Out.Image != "ghcr.io/frikkern/barkpark:0.2.33" {
		t.Errorf("state image = %q", st.Out.Image)
	}
}

func TestInstanceUpRetriesWhileEntraReplicates(t *testing.T) {
	f := stubInstanceUp(t)
	fails := 2
	f.reply = func(c instanceUpCmd) (string, error) {
		s := c.String()
		switch {
		case strings.HasPrefix(s, "az deployment group create") && strings.Contains(s, "main.bicep") && fails > 0:
			fails--
			return "", &instanceUpCmdError{cmd: s, err: errors.New("exit status 1"), stderr: `{"code":"BadRequest","message":"Failed to update one or more relationships in 'owners'. Please try again later."}`}
		case strings.HasPrefix(s, "az deployment group show"):
			return `{"host":{"value":"app.norwayeast.azurecontainerapps.io"},"entraTenantId":{"value":"tenant-1"},"entraClientId":{"value":"app-1"},"entraOwnersGroupId":{"value":"group-1"}}`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com")
	if code != exitOK || f.has("main.bicep") != 3 || !strings.Contains(stderr, "has not replicated") {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
}

// The vault and registry that main.bicep and acr.bicep made in rg-m4-c-aca
// on 2026-10-30 were kv-bp-txufs5jlbsyic and crbarkparktxufs5jlbsyic.
func TestArmUniqueStringMatchesAzure(t *testing.T) {
	got := armUniqueString("/subscriptions/abea600a-4458-43fa-a778-666a3f322291/resourceGroups/rg-m4-c-aca")
	if got != "txufs5jlbsyic" {
		t.Fatalf("uniqueString = %q, want txufs5jlbsyic", got)
	}
}

func TestInstanceUpPurgesOnlyThisInstancesLeftovers(t *testing.T) {
	f := stubInstanceUp(t)
	st := &instanceUpState{Subscription: "sub-1", ResourceGroup: "rg-aca", Org: "pensum"}
	vault := st.vaultName()
	app, group := st.entraUniqueNames()
	f.reply = func(c instanceUpCmd) (string, error) {
		s := c.String()
		switch {
		case strings.HasPrefix(s, "az keyvault list-deleted"):
			return `[{"name":"` + vault + `","properties":{"vaultId":"/subscriptions/sub-1/resourceGroups/rg-aca/providers/Microsoft.KeyVault/vaults/` + vault + `","location":"norwayeast"}},
			{"name":"kv-bp-other","properties":{"vaultId":"/subscriptions/sub-1/resourceGroups/rg-other/providers/Microsoft.KeyVault/vaults/kv-bp-other","location":"norwayeast"}}]`, nil
		case strings.HasPrefix(s, "az rest --method get") && strings.Contains(s, "microsoft.graph.application"):
			return `{"value":[{"id":"del-app","displayName":"Barkpark pensum (old)","uniqueName":"` + app + `"},{"id":"other-app","uniqueName":"barkpark-pensum-zzz"}]}`, nil
		case strings.HasPrefix(s, "az rest --method get") && strings.Contains(s, "microsoft.graph.group"):
			return `{"value":[{"id":"del-group","uniqueName":"` + group + `"}]}`, nil
		case strings.HasPrefix(s, "az deployment group show"):
			return `{"host":{"value":"app.norwayeast.azurecontainerapps.io"},"entraTenantId":{"value":"tenant-1"},"entraClientId":{"value":"app-1"},"entraOwnersGroupId":{"value":"group-1"}}`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com", "--image", "ghcr.io/frikkern/barkpark:0.2.33")
	if code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	if f.has("keyvault purge -n "+vault+" -l norwayeast") != 1 || f.has("kv-bp-other") != 0 {
		t.Errorf("vault purge:\n%s", f.dump())
	}
	if f.has("deletedItems/del-app") != 1 || f.has("deletedItems/del-group") != 1 || f.has("deletedItems/other-app") != 0 {
		t.Errorf("Entra purge:\n%s", f.dump())
	}
	if !strings.Contains(f.find("microsoft.graph.application").String(), "uniqueName+eq+%27"+app+"%27") {
		t.Errorf("app filter: %s", f.find("microsoft.graph.application"))
	}
}

func TestInstanceUpLeavesAVaultOfAnotherGroup(t *testing.T) {
	f := stubInstanceUp(t)
	st := &instanceUpState{Subscription: "sub-1", ResourceGroup: "rg-aca", Org: "pensum"}
	vault := st.vaultName()
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az keyvault list-deleted") {
			return `[{"name":"` + vault + `","properties":{"vaultId":"/subscriptions/sub-2/resourceGroups/rg-aca/providers/Microsoft.KeyVault/vaults/` + vault + `","location":"norwayeast"}}]`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, "--azure", "--path", "containerapps", "--resource-group", "rg-aca", "--owner", "owner@example.com")
	if code == exitOK || !strings.Contains(stderr, "bp leaves it") || f.has("keyvault purge") != 0 {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
}
