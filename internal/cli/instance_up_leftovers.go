package cli

// instance_up_leftovers.go finds what an earlier instance in a resource group
// of the same name left in soft-delete, which blocks a new deploy into a
// recreated group:
//
//   - main.bicep names its Key Vault kv-bp-<uniqueString(resourceGroup().id)>.
//     A deleted vault keeps that name for its retention days, and a new vault
//     of the same name fails.
//   - entra.bicep names its app barkpark-<org>-<suffix> and its owners group
//     barkpark-<org>-owners-<suffix> as uniqueName. A deleted app or group
//     keeps its uniqueName in Entra's deleted items for 30 days, and Graph
//     then refuses the new app with "Failed to update one or more
//     relationships in 'owners'".
//
// bp purges an item only when its name is the one the templates give this
// subscription, resource group and org, and, for a vault, when its recorded
// resource id is in this resource group. Anything else stays.

import (
	"encoding/binary"
	"fmt"
	"math/bits"
	"net/url"
	"strings"
)

// armUniqueString is Azure Resource Manager's uniqueString(): a 64-bit
// MurmurHash of the arguments joined with "-", as 13 base32 characters.
func armUniqueString(parts ...string) string {
	h := armMurmur64([]byte(strings.Join(parts, "-")))
	const alphabet = "abcdefghijklmnopqrstuvwxyz234567"
	var b [13]byte
	for i := range b {
		b[i] = alphabet[h>>59]
		h <<= 5
	}
	return string(b[:])
}

func armMurmur64(data []byte) uint64 {
	const c1, c2 = 0x239b961b, 0xab0e9789
	var h1, h2 uint32
	n := len(data)
	i := 0
	for ; i+8 <= n; i += 8 {
		k1 := binary.LittleEndian.Uint32(data[i:])
		k2 := binary.LittleEndian.Uint32(data[i+4:])
		k1 *= c1
		k1 = bits.RotateLeft32(k1, 15)
		k1 *= c2
		h1 ^= k1
		h1 = bits.RotateLeft32(h1, 19)
		h1 += h2
		h1 = h1*5 + 0x561ccd1b
		k2 *= c2
		k2 = bits.RotateLeft32(k2, 17)
		k2 *= c1
		h2 ^= k2
		h2 = bits.RotateLeft32(h2, 13)
		h2 += h1
		h2 = h2*5 + 0x0bcaa747
	}
	if tail := data[i:]; len(tail) > 0 {
		var k1, k2 uint32
		for j := 0; j < len(tail) && j < 4; j++ {
			k1 |= uint32(tail[j]) << (8 * j)
		}
		k1 *= c1
		k1 = bits.RotateLeft32(k1, 15)
		k1 *= c2
		h1 ^= k1
		if len(tail) > 4 {
			for j := 4; j < len(tail); j++ {
				k2 |= uint32(tail[j]) << (8 * (j - 4))
			}
			k2 *= c2
			k2 = bits.RotateLeft32(k2, 17)
			k2 *= c1
			h2 ^= k2
		}
	}
	h1 ^= uint32(n)
	h2 ^= uint32(n)
	h1 += h2
	h2 += h1
	h1, h2 = armFmix(h1), armFmix(h2)
	h1 += h2
	h2 += h1
	return uint64(h2)<<32 | uint64(h1)
}

func armFmix(h uint32) uint32 {
	h ^= h >> 16
	h *= 0x85ebca6b
	h ^= h >> 13
	h *= 0xc2b2ae35
	h ^= h >> 16
	return h
}

// groupID is the resource group's id as resourceGroup().id gives it.
func (st *instanceUpState) groupID() string {
	return "/subscriptions/" + strings.ToLower(st.Subscription) + "/resourceGroups/" + st.ResourceGroup
}

// nameSuffix is the templates' default nameSuffix for this group.
func (st *instanceUpState) nameSuffix() string { return armUniqueString(st.groupID()) }

// vaultName is the Key Vault name main.bicep gives this group.
func (st *instanceUpState) vaultName() string { return "kv-bp-" + st.nameSuffix() }

// entraUniqueNames are the uniqueNames entra.bicep gives the app and the
// owners group of this group and org.
func (st *instanceUpState) entraUniqueNames() (app, group string) {
	s := st.nameSuffix()
	return "barkpark-" + st.Org + "-" + s, "barkpark-" + st.Org + "-owners-" + s
}

// purgeLeftovers purges this instance's soft-deleted vault and deleted Entra
// app and owners group. It runs in the preflight of a first run, before any
// deploy can fail on them.
func (u *instanceUp) purgeLeftovers() error {
	st := u.st
	if st.Path == instanceTargetContainerApps {
		if err := u.purgeDeletedVault(); err != nil {
			return err
		}
	}
	if !instanceUpHasAzureFile("entra.bicep") {
		return nil
	}
	app, group := st.entraUniqueNames()
	for _, it := range []struct{ kind, name string }{{"application", app}, {"group", group}} {
		if err := u.purgeDeletedEntra(it.kind, it.name); err != nil {
			return err
		}
	}
	return nil
}

func (u *instanceUp) purgeDeletedVault() error {
	st := u.st
	name := st.vaultName()
	var vaults []struct {
		Name       string `json:"name"`
		Properties struct {
			VaultID  string `json:"vaultId"`
			Location string `json:"location"`
		} `json:"properties"`
	}
	if err := u.az(&vaults, "keyvault", "list-deleted", "--resource-type", "vault"); err != nil {
		return fmt.Errorf("list the soft-deleted Key Vaults: %v", err)
	}
	wantID := strings.ToLower(st.groupID() + "/providers/Microsoft.KeyVault/vaults/" + name)
	for _, v := range vaults {
		if !strings.EqualFold(v.Name, name) {
			continue
		}
		if strings.ToLower(v.Properties.VaultID) != wantID {
			return fmt.Errorf("the soft-deleted Key Vault %s, which main.bicep would make here, belonged to %s, not this resource group. bp leaves it. Purge it with az keyvault purge -n %s if it is yours", name, v.Properties.VaultID, name)
		}
		u.out.errf("        purging the soft-deleted Key Vault %s, left by an earlier instance in %s", name, st.ResourceGroup)
		if err := u.az(nil, "keyvault", "purge", "-n", name, "-l", v.Properties.Location); err != nil {
			return fmt.Errorf("purge the soft-deleted Key Vault %s: %v", name, err)
		}
	}
	return nil
}

func (u *instanceUp) purgeDeletedEntra(kind, uniqueName string) error {
	var res struct {
		Value []struct {
			ID          string `json:"id"`
			DisplayName string `json:"displayName"`
			UniqueName  string `json:"uniqueName"`
		} `json:"value"`
	}
	q := url.QueryEscape("uniqueName eq '" + uniqueName + "'")
	list := "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph." + kind + "?$filter=" + q + "&$select=id,displayName,uniqueName"
	if err := u.az(&res, "rest", "--method", "get", "--url", list); err != nil {
		return fmt.Errorf("list the deleted Entra %ss: %v", kind, err)
	}
	for _, it := range res.Value {
		if it.UniqueName != uniqueName || it.ID == "" {
			continue
		}
		u.out.errf("        deleting the deleted Entra %s %q (%s) for good: it holds uniqueName %s, which entra.bicep gives this instance", kind, it.DisplayName, it.ID, uniqueName)
		if err := u.az(nil, "rest", "--method", "delete", "--url", "https://graph.microsoft.com/v1.0/directory/deletedItems/"+it.ID); err != nil {
			return fmt.Errorf("delete the deleted Entra %s %s for good: %v", kind, it.ID, err)
		}
	}
	return nil
}
