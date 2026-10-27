<!-- doc-tier: human | canonical-for: self-host-guide | budget: 2500tok -->
# Set up a Barkpark instance for Pensum

This guide takes you from an empty Azure resource group to Pensum sign-in, in run order. It has two paths that share the same settings. Operations that come after setup, such as backups, moves and key rotation, are in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md). Running the image on a container platform is experimental.

| Path | What runs | Where the settings live |
|---|---|---|
| [Single VM](#path-a-a-single-vm) | `deploy.sh` builds Barkpark from source on one Ubuntu 22.04 or later server, with local PostgreSQL and Caddy for TLS. | `/opt/barkpark/.env` |
| [Container Apps](#path-b-azure-container-apps) | The `api/Dockerfile` image with one replica, PostgreSQL Flexible Server, media on Azure Files and keys in Key Vault. | Container App settings and Key Vault references |

## Before you start on Azure

A new subscription has no resource providers registered. Register the ones these paths use, then wait until each shows `Registered`:

```bash
for p in Compute Network Storage App DBforPostgreSQL KeyVault OperationalInsights ContainerRegistry ManagedIdentity; do
  az provider register --namespace "Microsoft.$p"
done
az provider list --query "[?registrationState!='Registered' && starts_with(namespace,'Microsoft.')].namespace" -o tsv
```

A new subscription may see no small VM sizes in Norway East, and its B-series quota can be 0. Check with `az vm list-skus --location <region> --size Standard_D2 -o table` and `az vm list-usage --location <region> -o table`. Sweden Central with `Standard_D2als_v7` worked in the first measured run.

## Decide the host name and the org slug

Choose both before you register anything. The host name becomes `PHX_HOST`, and passkeys stop working if it changes later. The Entra ID redirect URI contains the org slug, `https://<host>/v1/auth/oidc/<org>/callback`, so the slug must be fixed before you register the Entra app in `ENTRA.md`.

Install `bp` on your own machine:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

## Path A: a single VM

1. Create an Ubuntu 22.04 or later VM with 2 vCPU and 4 GB or more, and open ports 22, 80 and 443. Azure gives you a sudo user, not root, so every command below uses `sudo`.

   ```bash
   az vm create -g "$RG" -n barkpark --image Ubuntu2204 --size Standard_D2als_v7 \
     --location swedencentral --admin-username azureuser --generate-ssh-keys
   az vm open-port -g "$RG" -n barkpark --port 80,443 --priority 900
   ```

2. Create a DNS A record from the host name to the VM's public IP. Caddy needs it to resolve publicly before it can issue a certificate.
3. On the VM, download `deploy.sh` from the repository root and run it as a file. The final banner prints an admin token, so send the output to a file only root can read:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/FRIKKern/barkpark/main/deploy.sh
   sudo bash -c 'umask 077; DOMAIN=<host> BARKPARK_SEED_PROFILE=clean bash ./deploy.sh > /root/deploy.log 2>&1'
   sudo tail -n 30 /root/deploy.log
   ```

   `deploy.sh` installs PostgreSQL, Erlang, Elixir and Go, clones the repository to `/opt/barkpark`, generates every key into `/opt/barkpark/.env`, starts the `barkpark` systemd service and installs Caddy. The build took about 10 minutes on 2 vCPU in the first measured run. `DOMAIN` must be the host name, never an IP, or the Studio websocket answers 403.
4. Copy the `bp setup --target connect ...` line from the banner and run it on your machine. Store the token in your password manager, then delete `/root/deploy.log`.
5. Add the [Pensum settings](#pensum-settings) to `/opt/barkpark/.env`. `api/start.sh` reads that file at each start. Run `sudo systemctl restart barkpark`.

To update, run `cd /opt/barkpark && sudo git pull`. A post-merge hook rebuilds and restarts. `make logs` and `make status` show the service. If the script stops right after "Installed erlang", it was piped over stdin; run it as a file. If `curl https://<host>` returns `000` and the Caddy log shows `NXDOMAIN`, fix DNS and run `sudo systemctl restart caddy`.

## Path B: Azure Container Apps

1. Create a PostgreSQL Flexible Server and allow the extensions Barkpark uses: `az postgres flexible-server parameter set -g "$RG" -s "$PG" --name azure.extensions --value citext,pg_trgm,pgcrypto`. Create an empty database.
2. Create a Key Vault with soft delete and purge protection. Store four keys as secrets: `SECRET_KEY_BASE` from `openssl rand -base64 48`, and `BARKPARK_CLOAK_KEY`, `PREVIEW_JWT_SECRET` and `BARKPARK_KEK` each from `openssl rand -base64 32`. Reference them from the Container App with versioned URIs, as [the rotation section](SELF-HOST-OPERATIONS.md#rotate-keys) shows.
3. Build the image from `api/Dockerfile` and push it to your registry.
4. Create the Container App with one replica, an Azure Files mount for media, `DATABASE_URL`, `PHX_HOST` and the [Pensum settings](#pensum-settings). Use these probes. The first boot runs migrations and seeds, so the startup probe allows 300 seconds.

   ```yaml
   probes:
     - { type: Liveness, httpGet: { path: /livez, port: 4000 } }
     - { type: Readiness, httpGet: { path: /readyz, port: 4000 } }
     - { type: Startup, httpGet: { path: /readyz, port: 4000 }, periodSeconds: 10, failureThreshold: 30 }
   ```

   `/livez` always answers 200 while the server serves HTTP and reads no database. `/readyz` answers 200 when the database answers, no migration is pending and the job queue runs, and 503 otherwise. Neither needs a token.

The image has no `git`, `node`, `claude`, `codex`, `bp`, `tmux` or `ps`. The Pensum settings turn off the features that start those programs. A container runs no `barkpark-agent`. Read health and the running commit from `/status.json`, request rates from `GET /v1/instance/request-stats`, and CPU, memory, restarts and storage from the Container Apps and Flexible Server metrics in Azure.

## Pensum settings

Both paths set these:

```bash
BARKPARK_SELF_UPDATE_CHECK=off BARKPARK_RETIRE_SSE_ON_SIGTERM=1
BARKPARK_ALWAYS_ALLOWED_ORIGINS=https://<host>,<Studio origin>
BARKPARK_PLUGINS=media BARKPARK_TMUX_CONSOLE=off
BARKPARK_CAPABILITIES_OFF=studio_chat,cycle_fleet,epic_fleet
BARKPARK_BOOTSTRAP_OWNER_EMAIL=<owner>
BARKPARK_OPERATOR_EMAILS=<operators> BARKPARK_OPERATOR_FAIL_CLOSED=1
BARKPARK_SIGN_IN_POLICY_ALL_ROUTES=1 BARKPARK_CLOUD_HANDOFF=off
BARKPARK_BREAKGLASS_EMAILS=<break-glass account> BARKPARK_TOKEN_EXPIRY_WARNINGS=on
```

- **VM.** Add the lines to `/opt/barkpark/.env`. PostgreSQL runs on the same host, so no `DATABASE_SSL` is needed. The keys stay in that file. Run `sudo chmod 600 /opt/barkpark/.env` so only root can read it.
- **Container Apps.** Add `DATABASE_SSL=verify-full`, and `DATABASE_SSL_CA_FILE=<Flexible Server CA bundle>` when the CA is not in the image's store. Keep the keys and the break-glass password in Key Vault.

Pensum calls Barkpark only from its server, so `BARKPARK_ALWAYS_ALLOWED_ORIGINS` lists only the instance's own origin and Studio's origin. `BARKPARK_BOOTSTRAP_OWNER_EMAIL` makes that email the owner of the default workspace on any boot while the users table is empty. Once a user exists, it does nothing. An empty `BARKPARK_PLUGINS` turns off media too, so name `media`. With `BARKPARK_OPERATOR_FAIL_CLOSED=1`, operator routes refuse every caller while `BARKPARK_OPERATOR_EMAILS` and `BARKPARK_OPERATOR_TOKEN_IDS` are both empty. A break-glass account signs in with a password and TOTP while SSO is down. It must already exist with TOTP turned on. Create it before you turn on SSO-only sign-in: run `bp auth register` with its email, `bp auth mfa-enroll` and `bp auth mfa-verify` while signed in as it, and `bp workspace member-add` to seat it. If `bp org` commands answer 403 after these settings, the admin token is on neither operator list; add its token id to `BARKPARK_OPERATOR_TOKEN_IDS`. Leave `BARKPARK_SITE_DEPLOY_APPLY`, `BARKPARK_SELF_UPDATE_APPLY`, `CONNECTORS_CONNECT_SECRET` and `INDX_*` unset.

## Sign in with Entra ID

Register the Entra app as `ENTRA.md` describes, and use the sign-in URL section there for the redirect URI, with the org slug you chose. Then run these with an operator token. On the VM, that is the admin token from step 4. Container Apps has no documented step for the first operator token yet.

```bash
bp org create <org> "<Org name>"
bp org attach-workspace <org> default
bp org oidc-create <org> "https://login.microsoftonline.com/$TENANT/v2.0" "$CLIENT_ID" "$CLIENT_SECRET" \
  --tenant_id "$TENANT" --strict_validation --trust_idp_mfa \
  --set group_role_mappings:='{"<owners group id>":"owner","<editors group id>":"member"}'
bp org domain-add <org> <email domain>      # publish the TXT record it prints
bp org domain-verify <org> <email domain>
bp org auth-methods <org> sso
```

Each sign-in sets the role from the user's Entra groups and can lower it. Map a group that holds the owner to `owner`, or the first sign-in demotes the owner. A Studio with `STUDIO_SIGN_IN=sso` and `STUDIO_SSO_ORG=<org>` signs editors in through this connection; list its origin in `BARKPARK_STUDIO_SSO_ORIGINS`.

## Check the instance

```bash
curl -sS https://<host>/readyz          # {"status":"ready",...}
bp capabilities | grep auth_tier        # admin or operator
```

Then sign in at `https://<host>/studio` through Entra ID. Continue with backups in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md).
