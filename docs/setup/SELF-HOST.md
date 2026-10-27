<!-- doc-tier: human | canonical-for: self-host-guide | budget: 2500tok -->
# Set up a Barkpark instance for Pensum

This guide takes you from an empty Azure resource group to Pensum sign-in, in run order, on one of two paths that share the settings. Backups, moves and key rotation are in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md). Running the image on a container platform is experimental.

| Path | What runs | Where the settings live |
|---|---|---|
| [Single VM](#path-a-a-single-vm) | `deploy.sh` builds Barkpark from source on one Ubuntu 22.04 or later server, with local PostgreSQL and Caddy for TLS. | `/opt/barkpark/.env` |
| [Container Apps](#path-b-azure-container-apps) | The published image with one replica, PostgreSQL Flexible Server, media on Azure Files and keys in Key Vault. | Container App settings and Key Vault references |

## Before you start on Azure

A new subscription has no resource providers. Register the ones these paths use and wait until each is `Registered`:

<!-- run -->
```bash
for p in Compute Network Storage App DBforPostgreSQL KeyVault OperationalInsights ManagedIdentity; do
  az provider register --namespace "Microsoft.$p"
done
az provider list --query "[?registrationState!='Registered' && starts_with(namespace,'Microsoft.')].namespace" -o tsv
```

Check VM size availability and quota with `az vm list-skus --location <region> --size Standard_D2 -o table` and `az vm list-usage --location <region> -o table`.

## Decide the host name and the org slug

The host name becomes `PHX_HOST`, and passkeys stop working if it changes later. The Entra ID redirect URI contains the org slug, so fix the slug before you register the app. See [the sign-in URL section](ENTRA.md#sign-in-url-and-redirect-uri).

## Write and check the settings file

On your machine, install `bp` 1.26.0 or newer and write a settings file:

<!-- run -->
```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp instance init --target vm --host <host> --studio-origin <studio origin> \
  --owner-email <owner email> --operator-emails <operator emails> \
  --breakglass-email <breakglass email>
```

`bp instance init` writes `barkpark.env` with mode 600 and the [Pensum settings](#pensum-settings). With `--target containerapps` it also writes new keys, a database password, the first admin token and `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET`, without which a fresh database does not finish migrating. For `--target vm`, `deploy.sh` makes them. It prints each `<...>` value left to fill in. Then check the file:

<!-- run -->
```bash
bp instance check --env-file barkpark.env --target vm --skip database,media,url
```

`bp instance check` lists each problem with a doc link and exits 1 on any. `--skip` leaves out the probes that need the server. Before the first start, run the check where the server runs, without `--skip`. A server missing required settings lists every one at boot and stops.

## Path A: a single VM

1. Create an Ubuntu 22.04 or later VM with 2 vCPU and 4 GB or more, and open ports 22, 80 and 443:

   <!-- run -->
   ```bash
   az vm create -g "$RG" -n barkpark --image Ubuntu2204 --size Standard_D2als_v7 \
     --location swedencentral --admin-username azureuser --generate-ssh-keys \
     --public-ip-address-dns-name <dns label>
   az vm open-port -g "$RG" -n barkpark --port 80,443 --priority 900
   ```

2. The host name is then `<dns label>.swedencentral.cloudapp.azure.com`. For your own domain, create a DNS A record to the VM's public IP instead. Caddy needs one of them for a certificate.
3. Copy the file and run `deploy.sh` over ssh. It keeps its own `DATABASE_URL` and keys, and deletes the copy once merged:

   <!-- run -->
   ```bash
   scp barkpark.env azureuser@<ip>:/tmp/pensum.env
   curl -fsSLO https://raw.githubusercontent.com/FRIKKern/barkpark/main/deploy.sh
   ssh azureuser@<ip> 'sudo DOMAIN=<host> BARKPARK_ENV_FILE=/tmp/pensum.env bash -s' < deploy.sh
   ```

   `deploy.sh` builds Barkpark in `/opt/barkpark` and merges the file into `/opt/barkpark/.env` before the first start. Install and build take 7 to 8 minutes on `Standard_D2als_v7`. It writes the admin token to `/etc/barkpark/admin-token` and its id to `/etc/barkpark/admin-token.id`, both root only. When the file sets `BARKPARK_OPERATOR_EMAILS` or `BARKPARK_OPERATOR_FAIL_CLOSED`, it adds the id to `BARKPARK_OPERATOR_TOKEN_IDS`. The banner prints the token path, the id and a login command, never the token. `DOMAIN` must be the host name, not an IP, or the server refuses to start. It waits up to 3 minutes for HTTPS.
4. <!-- run --> Run the printed `bp setup --target connect --server https://<host> --token "$(ssh azureuser@<ip> sudo cat /etc/barkpark/admin-token)"` on your machine.

To change a setting later, edit `/opt/barkpark/.env` and run `sudo systemctl restart barkpark`. To update, run `sudo git -C /opt/barkpark pull`. A post-merge hook rebuilds and restarts. If `curl https://<host>` returns `000` and the Caddy log shows `NXDOMAIN`, fix DNS and run `sudo systemctl restart caddy`.

## Path B: Azure Container Apps

Deploy to Azure with `deploy/azure/main.bicep`. Copy `main.example.bicepparam` to `main.bicepparam`, export the seven secrets its header lists, then run `az group create -n <rg> -l norwayeast` and `az deployment group create -g <rg> -p main.bicepparam`. The first deployment takes about 8 minutes, and `/readyz` answers about 1 minute later. Monthly cost is in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md#container-apps-cost).

- Barkpark runs on exactly one replica; the template pins min and max to 1.
- Pin an image version, such as `ghcr.io/frikkern/barkpark:0.2.28`. A release tag `v<A.B.C>` publishes `<A.B.C>`, `sha-<12 hex>` and `latest`.
- Add the Pensum settings from `barkpark.env` with `az containerapp update -g <rg> -n barkpark --set-env-vars`, leaving out the key lines.
- `/livez` answers 200 while the server serves HTTP. `/readyz` answers 200 when the database answers, migrations are done and the job queue runs, and 503 otherwise.
- The first boot installs `BARKPARK_SEED_ADMIN_TOKEN` and logs `Admin token id: <id>`. Add the id to `BARKPARK_OPERATOR_TOKEN_IDS` and connect with `bp setup --target connect`.
- Listen streams last at most 30 minutes behind Container Apps ingress; clients resume with `Last-Event-ID`.
- After deleting the resource group, purge its Key Vault with `az keyvault purge` before deploying again under the same name.

## Pensum settings

`bp instance init` writes these for both paths:

```bash
BARKPARK_SELF_UPDATE_CHECK=off
BARKPARK_RETIRE_SSE_ON_SIGTERM=1
BARKPARK_ALWAYS_ALLOWED_ORIGINS=https://<host>,<studio origin>
BARKPARK_PLUGINS=media
BARKPARK_TMUX_CONSOLE=off
BARKPARK_CAPABILITIES_OFF=studio_chat,cycle_fleet,epic_fleet
BARKPARK_OPERATOR_EMAILS=<operator emails>
BARKPARK_OPERATOR_FAIL_CLOSED=1
BARKPARK_SIGN_IN_POLICY_ALL_ROUTES=1
BARKPARK_CLOUD_HANDOFF=off
BARKPARK_BREAKGLASS_EMAILS=<breakglass email>
BARKPARK_TOKEN_EXPIRY_WARNINGS=on
BARKPARK_OIDC_KEEP_OWNER=on
BARKPARK_OIDC_EMAIL_FROM_UPN=on
BARKPARK_BOOTSTRAP_OWNER_EMAIL=<owner email>
```

On Container Apps, keep the keys and the break-glass password in Key Vault. On the VM, run `sudo chmod 600 /opt/barkpark/.env`.

- `BARKPARK_ALWAYS_ALLOWED_ORIGINS` lists only the instance and Studio, because Pensum calls Barkpark from its server.
- `BARKPARK_BOOTSTRAP_OWNER_EMAIL` makes that email the owner of the default workspace while the users table is empty.
- An empty `BARKPARK_PLUGINS` turns off media too, so name `media`.
- `BARKPARK_OIDC_KEEP_OWNER=on` refuses a group mapping with no `owner` group, and a sign-in never lowers a workspace's last owner.
- `BARKPARK_OIDC_EMAIL_FROM_UPN=on` matches an Entra account with no `email` claim on its UPN, so the bootstrap owner can sign in.
- `BARKPARK_BREAKGLASS_EMAILS` lets the [break-glass account](ENTRA.md#break-glass-account) sign in with a password and TOTP, or a passkey, while the org allows only SSO.
- Leave `BARKPARK_SITE_DEPLOY_APPLY`, `BARKPARK_SELF_UPDATE_APPLY`, `CONNECTORS_CONNECT_SECRET` and `INDX_*` unset.

**Operator access.** Once either operator list is set, operator routes such as `bp org` accept only a token whose owner is on `BARKPARK_OPERATOR_EMAILS` or whose id is on `BARKPARK_OPERATOR_TOKEN_IDS`. `BARKPARK_OPERATOR_FAIL_CLOSED=1` refuses everyone while both lists are empty. The admin token has no owner, so only its id grants it. `bp token ls` lists it as `admin (bp setup)`. A 403 from `bp org` names the calling token's id in its hint.

**Mail.** Optional. Without `SMTP_HOST`, `/status.json` shows the mail component as degraded, and no sign-in links, password resets or invitations go out. SSO plus a break-glass account does not need mail.

## Sign in with Entra ID

Register the app and connect it as [ENTRA.md](ENTRA.md) describes. Run the `bp org` commands the script prints with the operator token, then turn on [Entra MFA as Barkpark MFA](ENTRA.md#entra-mfa-counts-as-barkpark-mfa). Once the break-glass account exists, run `bp org auth-methods <org> sso`. A Studio with `STUDIO_SIGN_IN=sso` and `STUDIO_SSO_ORG=<org>` signs editors in through this connection; list its origin in `BARKPARK_STUDIO_SSO_ORIGINS`.

## Check the instance

<!-- run -->
```bash
curl -fsS https://<host>/readyz           # {"status":"ready",...}
bp whoami | grep -x 'auth_tier: admin'
```

Then sign in at `https://<host>/studio` through Entra ID. Continue with backups in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md).
