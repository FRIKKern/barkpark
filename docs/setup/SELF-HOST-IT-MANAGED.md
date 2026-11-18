<!-- doc-tier: human | canonical-for: self-host-it-managed | budget: 1500tok -->
# Set up a VM in a subscription that IT manages

Use this page when your IT department owns the network and the Entra app registration, and you have Contributor on a resource group. `bp instance up` then creates only the public IP, the VM, its NIC and disk, and an Entra extension on the VM. It changes no network security group and registers no app. The rest of the setup is as in [SELF-HOST.md](SELF-HOST.md).

## Ask IT for these

- A subnet in a VNet, with a network security group on the subnet. It must allow 443 and 80 inbound from the Internet, and 22 from the operator's address. The VM goes to the VNet's region.
- The host name. With `--host <dns label>`, the host is `<dns label>.<region>.cloudapp.azure.com`.
- An app registration in the tenant: single tenant, Web platform, with the redirect URI `https://<host>/v1/auth/oidc/<org>/callback`, and the operator as an owner. `<org>` is `pensum` unless you pass `--org`.
- Resource providers `Microsoft.Compute` and `Microsoft.Network` registered in the subscription.

## Run up

After `az login` and, with PIM, the role activation:

```bash
bp instance up --azure --path vm --resource-group <rg> --host <dns label> --owner <owner upn> \
  --subnet-id <subnet resource id> --public-ip <public IP name> --vm-name <vm name> \
  --entra-app-id <application id> --entra-ssh --size Standard_D4ls_v7 --disk-sku Premium_LRS --disk-gb 128
```

What these flags change:

- `--subnet-id` puts the NIC in that subnet with no NIC network security group. up opens no port, so the subnet's group decides. Preflight reads the subnet and its VNet, takes the VNet's region, and stops when the subnet has no group.
- `--public-ip` names the Standard static public IP. up creates it with the DNS label from `--host`, or uses one that exists in the group with that label.
- `--entra-app-id` uses IT's app. up checks that the app has the redirect URI, adds a client secret with `az ad app credential reset --append`, which keeps the app's other secrets, and pipes the secret over ssh into `/etc/barkpark/entra-client-secret` on the VM, root only. The secret never reaches your disk or a command line. The org's OIDC connection has no group mapping, and `--owner` becomes owner at the first sign-in. A rerun keeps the secret on the VM.
- `--assign-identity` gives the VM a system-assigned managed identity. `--entra-ssh` also does that and adds the `AADSSHLoginForLinux` extension, so people with the Virtual Machine Administrator Login role sign in with `az ssh vm`.
- `--vm-name` names the VM. The default is `barkpark`.

The VM runs Ubuntu 24.04 LTS. up saves the instance in bp and leaves the active server as it was.

## Import on a larger size, then resize

The 2026-11-18 import of 40,458 documents on 4 vCPU used a median of 45 % user CPU and peaked at 86 %. Daily use needs far less. Create the VM on the larger size, import, then move to the daily size in the same directory:

```bash
bp instance resize --size Standard_D2s_v7 --yes
```

`resize` reads `.bp-instance-up.json`, runs `az vm resize`, which restarts the VM, and waits for `/readyz`. Every service starts again at boot. In the 2026-11-18 run, `/readyz` answered 200 again 50 seconds after the resize started.

## Afterwards

- The client secret expires after one year. Rotate it as [SELF-HOST-UPDATES.md](SELF-HOST-UPDATES.md#rotate-the-oidc-client-secret) says, with `az ad app credential reset --append` for the new secret.
- Set up backups as [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill) says.
- Create the break-glass account before `bp org auth-methods <org> sso`.
