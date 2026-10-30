<!-- doc-tier: human | canonical-for: self-host-guide | budget: 2500tok -->
# Set up a Barkpark instance for Pensum

This guide goes from an Azure subscription to Pensum sign-in. Backups, moves and key rotation are in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md).

| Path | What runs | Where the settings live |
|---|---|---|
| [Single VM](#path-a-a-single-vm) | `deploy.sh` runs the server image in Docker on one Ubuntu server, with local PostgreSQL 17 and Caddy for TLS. | `/opt/barkpark/.env` |
| [Container Apps](#path-b-azure-container-apps) | The published image on one replica, PostgreSQL Flexible Server 17, Azure Files for media and Key Vault. | `barkpark.env`, deployed by `main.bicep` |

## Set up with bp instance up

`bp instance up` runs this guide from an empty resource group to the owner's first sign-in. With `bp` 1.26.13 or newer and `az login` as a user who may create app registrations, run one of these in an empty directory:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp instance up --azure --path vm --resource-group <resource group> --host <dns label> \
  --owner <owner upn> --breakglass <breakglass email>
bp instance up --azure --path containerapps --resource-group <resource group> \
  --owner <owner upn> --breakglass <breakglass email>
```

On Path A, `--host` is a DNS label or your own host, as [step 2](#path-a-a-single-vm) says. On Path B, leave it out for the Container Apps address. The published image is the default. `--image <ref>` names another, and `--from-source <git ref>` builds one on the VM or with `az acr build`.

up writes `barkpark.env` and `entra-client-secret` with mode 600 and prints no secret. After a failure the same command resumes from `.bp-instance-up.json`. On `CapacityNotAvailable` up deploys Postgres again as `Standard_B2s`.

The Entra app `Barkpark <org> (<host>)` and group `Barkpark <org> owners (<host>)` sit outside the resource group, and all else inside. `--org` defaults to `pensum`. up ends with the sign-in link. Sign in as the owner, create the [break-glass account](ENTRA.md#break-glass-account), then run `bp org auth-methods <org> sso --yes`.

## What up does

These are the steps up runs, in order.

## Before you start on Azure

A new subscription has no resource providers. Run this loop until each line says `Registered`:

<!-- run -->
```bash
for p in Compute Network Storage App DBforPostgreSQL KeyVault OperationalInsights ManagedIdentity; do
  az provider register --namespace "Microsoft.$p"
  az provider show -n "Microsoft.$p" --query "join(' ', [namespace,registrationState])" -o tsv
done
```

Check quota with `az vm list-usage --location <region> -o table`.

## Decide the host name and the org slug

The host name becomes `PHX_HOST`, and passkeys stop working if it changes. It must be a DNS name; with `PHX_SCHEME=https` the server refuses an IP address. The Entra ID redirect URI contains the org slug, so [fix the slug](ENTRA.md#sign-in-url-and-redirect-uri) before you register the app.

## Write and check the settings file

On your machine, install `bp` 1.26.11 or newer and write a settings file:

<!-- run -->
```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp instance init --target <target> --host "<host>" --studio-origin <studio origin> \
  --owner-email <owner email> --operator-emails <operator emails> \
  --breakglass-email <breakglass email>
```

The installer puts `bp` in `~/.local/bin`. Pipe to `BARKPARK_BIN_DIR=<dir> sh` for another directory. `<target>` is `vm` for Path A and `containerapps` for Path B. On Path B, `<host>` is your own domain, or empty for the Container Apps address. Without a separate Studio, `<studio origin>` is `http://localhost:3000` for the [headless sign-in check](../../tooling/entra-signin/README.md).

The owner can be the only operator email. `--breakglass-email` is a separate admin mailbox with a password and TOTP, not the owner's daily account.

`bp instance init` writes `barkpark.env` with mode 600 and the [Pensum settings](SELF-HOST-SETTINGS.md#pensum-settings). With `--target containerapps` it also writes the keys, a database password and the first admin token, with its id on `BARKPARK_OPERATOR_TOKEN_IDS`. For `--target vm`, `deploy.sh` makes them. It prints each `<...>` value left to fill in. Then check the file:

<!-- run -->
```bash
bp instance check --env-file barkpark.env --target <target> --skip database,media,url
```

It exits 1 on any problem. `--skip` leaves out server probes, which `deploy.sh` and `barkpark-ops` run.

## Path A: a single VM

1. Create a resource group, an ssh key and an Ubuntu 22.04 or later VM with 2 vCPU and 4 GB or more, and open ports 22, 80 and 443:

   <!-- run -->
   ```bash
   RG=<resource group>
   az group create -n "$RG" -l swedencentral
   mkdir -p -m 700 ~/.ssh
   test -f ~/.ssh/barkpark || ssh-keygen -t ed25519 -N '' -f ~/.ssh/barkpark
   az vm create -g "$RG" -n barkpark --image Ubuntu2204 --size Standard_D2als_v7 \
     --location swedencentral --admin-username azureuser --ssh-key-values ~/.ssh/barkpark.pub \
     --public-ip-address-dns-name <dns label>
   az vm open-port -g "$RG" -n barkpark --port 80,443 --priority 900
   ```

2. `<ip>` is the `publicIpAddress` from `az vm create`. The host name is `<dns label>.swedencentral.cloudapp.azure.com`, or your own domain with a DNS A record to `<ip>`.
3. Copy the file and run `deploy.sh` over ssh. It keeps its own `DATABASE_URL` and keys and deletes the copy:

   <!-- run -->
   ```bash
   o=(-i ~/.ssh/barkpark -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$HOME/.ssh/known_hosts")
   scp "${o[@]}" barkpark.env azureuser@<ip>:/tmp/pensum.env
   curl -fsSLO https://raw.githubusercontent.com/FRIKKern/barkpark/main/deploy.sh
   ssh "${o[@]}" azureuser@<ip> 'sudo DOMAIN=<host> BARKPARK_ENV_FILE=/tmp/pensum.env bash -s' < deploy.sh
   ```

   `deploy.sh` runs `ghcr.io/frikkern/barkpark` at the latest release, in about 2 minutes. Add `BARKPARK_IMAGE=<ref>` after `sudo` for another image, or `BARKPARK_FROM_SOURCE=<git ref>` to build `api/Dockerfile` on the VM without ghcr.io, in about 5 minutes. It writes the admin token to `/etc/barkpark/admin-token`, root only, and lists its id on `BARKPARK_OPERATOR_TOKEN_IDS` when the file sets an [operator list](#operator-access). It ends with `bp instance check`.
4. <!-- run --> In the same shell, run `bp setup --target connect --server https://<host> --token "$(ssh "${o[@]}" azureuser@<ip> sudo cat /etc/barkpark/admin-token)"`. It becomes the active server.

To change a setting later, edit `/opt/barkpark/.env` and run `sudo systemctl restart barkpark`. Updates and rollback are in [SELF-HOST-UPDATES.md](SELF-HOST-UPDATES.md#update-and-roll-back-a-single-vm). If HTTPS fails and the Caddy log shows `NXDOMAIN`, fix DNS and run `sudo systemctl restart caddy`.

## Path B: Azure Container Apps

`deploy/azure/main.bicep` puts Postgres on a private network and adds jobs for backups and checks. Next to `barkpark.env`, fetch it and deploy. It takes about 8 minutes. On `CapacityNotAvailable`, deploy again or add `-p postgresSku=Standard_B2s`:

<!-- run -->
```bash
RG=<resource group>
u=https://raw.githubusercontent.com/FRIKKern/barkpark/main/deploy/azure
for f in main.bicep acr-pull.bicep monitor.bicep main.example.bicepparam; do curl -fsSLO "$u/$f"; done
cp main.example.bicepparam main.bicepparam
az group create -n "$RG" -l norwayeast
az deployment group create -g "$RG" -n barkpark -p main.bicepparam -p alertEmail=<alert email> -o none
```

Without `PHX_HOST` in `barkpark.env`, the app gets its Container Apps address. A domain there is `PHX_HOST` from the start and is [bound later](SELF-HOST-UPDATES.md#host-name-on-container-apps). `alertEmail` gets [alerts](SELF-HOST-OPERATIONS.md#container-apps-alerts). Connect once `/readyz` answers, a minute later:

<!-- run -->
```bash
URL=$(az deployment group show -g <resource group> -n barkpark --query properties.outputs.url.value -o tsv)
curl -fsS --retry 30 --retry-delay 10 --retry-all-errors "$URL/readyz"
bp setup --target connect --server "$URL" --token "$(sed -n 's/^BARKPARK_SEED_ADMIN_TOKEN=//p' barkpark.env)"
```

<!-- run hook=jobs --> Run `az containerapp job start -g <resource group> -n barkpark-ops` for `bp instance check` in the network, and the same with `barkpark-backup` for a [backup](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill).

To change a setting, edit `barkpark.env` and deploy again. [SELF-HOST-UPDATES.md](SELF-HOST-UPDATES.md#container-apps) covers updates, jobs, health checks and cost.

## Operator access

Once either operator list is set, operator routes such as `bp org` accept only a token whose owner is on `BARKPARK_OPERATOR_EMAILS` or whose id is on `BARKPARK_OPERATOR_TOKEN_IDS`. `BARKPARK_OPERATOR_FAIL_CLOSED=1` refuses everyone while both lists are empty. The admin token has no owner.

## Sign in with Entra ID

Register and connect the app as [ENTRA.md](ENTRA.md) describes, with the operator token. Once a test sign-in works, turn on [Entra MFA as Barkpark MFA](ENTRA.md#entra-mfa-counts-as-barkpark-mfa). Sign in again. A `TOTP code` step or `idp_mfa: true` in the sign-in tool output shows Entra asked for it. A Studio signs editors in as [SELF-HOST-SETTINGS.md](SELF-HOST-SETTINGS.md#studio-sign-in) says.

## Check the instance

<!-- run path=a -->
```bash
curl -fsS https://<host>/readyz           # {"status":"ready",...}
bp whoami -o table | grep -x 'auth_tier: admin'
```

Then sign a test user in at `https://<host>/studio`, or headless with [tooling/entra-signin](../../tooling/entra-signin/README.md). When all three pass, the first setup is done. Before editors rely on it, create the [break-glass account](ENTRA.md#break-glass-account) and run `bp org auth-methods <org> sso`. Continue with backups in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md).
