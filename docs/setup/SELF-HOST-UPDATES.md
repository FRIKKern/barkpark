<!-- doc-tier: human | canonical-for: self-host-updates | budget: 2500tok -->
# Update an instance and rotate its credentials

This page comes after setup in [SELF-HOST.md](SELF-HOST.md), next to [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md). The times below come from a drill on `Standard_D2als_v7` on 2026-10-27.

## Update and roll back a single VM

The `barkpark` service runs the image that `/etc/barkpark/image.env` names. `GET /status.json` shows the running `version` and `commit`. Take a backup as [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill) describes, and note the current line with `sudo cat /etc/barkpark/image.env`.

**Update.** Pull the release, write its tag and restart. The container migrates the database as it starts:

```bash
sudo docker pull ghcr.io/frikkern/barkpark:<version>
echo BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:<version> | sudo tee /etc/barkpark/image.env
sudo systemctl restart barkpark
```

On 2026-10-30, `/readyz` failed for 8 seconds in an update from 0.2.30 to 0.2.31 and for 14 seconds in the rollback.

**Roll back.** Run the same three lines with the tag you noted. Migrations stay applied. When an update has a migration that changes or removes data, roll back the image and restore the backup taken before the update.

**From source.** Run `deploy.sh` again with `BARKPARK_FROM_SOURCE=<git ref>`. It builds `barkpark:src-<commit>`, writes it to `image.env` and restarts. A failed build leaves the running container alone.

**A VM from the source build.** A VM set up before 2026-10-30 runs a git checkout in `/opt/barkpark` and keeps working, with `git pull` as its update. One run of the current `deploy.sh` moves it to the image. It keeps `.env`, the database and the admin token, moves `api/uploads` to `/opt/barkpark/uploads` and replaces the service. Do not run `git pull` there after that.

## Container Apps

`deploy/azure/main.bicep` sets every non-key line of `barkpark.env` on the app and both jobs, and keeps the keys in Key Vault. Change a setting or a key by editing `barkpark.env` and running the same `az deployment group create` again. A change made with `az containerapp update` is lost at the next deployment.

- **Update.** Set a new `image` in `main.bicepparam` and deploy. Pin a release or `sha-<12>` tag, not `latest`.
- **Replicas.** The template runs exactly one replica. Listen streams, LiveView pages and task events get their updates through `Phoenix.PubSub`, which reaches other replicas only over an Erlang cluster, and Container Apps replicas form none. A second replica would miss events and keep its own caches.
- **Health.** `/livez` answers 200 while the server serves HTTP. `/readyz` answers 200 when the database answers, migrations are done and the job queue runs, and 503 otherwise.
- **Streams.** The ingress ends an SSE stream after 30 minutes. A LiveView socket lasted 44 minutes. In a revision swap, traffic moves 30 s before the old revision stops and sends `retire`. SSE clients resume with `Last-Event-ID` and LiveView rejoins, so none of 100 writes was lost.
- **Jobs.** Set job arguments with `az containerapp job update -g <rg> -n barkpark-ops --args ...`, then run `az containerapp job start`. Arguments on `job start` replace the whole container. A deployment resets the arguments. If an execution has no replica after 2 minutes, stop it with `az containerapp job stop` and start it again.
- **Redeploy after deleting.** A deleted resource group leaves its Key Vault soft-deleted for 7 days. Run `az keyvault purge -n <vault> -l norwayeast` before deploying again into a group with the same name.
- **Cost.** See [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md#container-apps-cost).

### Host name on Container Apps

`main.bicep` sets `PHX_HOST` in the deployment that creates the app. Passkeys and the Entra redirect URI depend on it, so choose the final host before the first deployment.

- **Default address.** Leave `PHX_HOST` out of `barkpark.env`. `PHX_HOST` is then `barkpark.` followed by the environment's domain, which Azure picks when it creates the environment. The first revision already has it.
- **Your own domain.** Give a subdomain such as `cms.example.com` to `bp instance init --host`. `main.example.bicepparam` passes `PHX_HOST` as `customDomain`, so `PHX_HOST` is that domain from the first deployment. The template does not take an apex domain. Until the domain is bound, the app answers only on its default address.
- **DNS records.** Print them after the first deployment:

  ```bash
  az deployment group show -g <rg> -n barkpark --query properties.outputs.dnsRecords.value -o table
  ```

  Create the CNAME from your domain to the app's default address, with no proxy or CDN in between, and the TXT record `asuid.<domain>`. When the parent domain has a CAA record, add `0 issue digicert.com`.
- **Bind.** Once both records resolve, set `param bindCustomDomain = true` in `main.bicepparam` and deploy again. That deployment adds the domain to the app and creates a free managed certificate, which Azure renews while the CNAME points at the app. Keep the setting at `true`. Without the TXT record the deployment stops with `InvalidCustomHostNameValidation`, which names the record, and the app keeps running unchanged.
- **Entra.** `scripts/entra-app-register.sh --resource-group <rg> --org <org>` reads the deployment output `host`, which is `PHX_HOST`, and registers `https://<host>/v1/auth/oidc/<org>/callback`. `bp instance check --target containerapps` names the same command when `barkpark.env` has no `PHX_HOST`.

## Rotate an API token

`bp token ls` lists the token ids. `bp token rotate <id> --grace 24h` prints the new token once and keeps the old one working for the grace period, at most `7d`. `--now` ends the old one at once. The new token keeps the old expiry unless you pass `--expires_in_days N`. Give the new token to each client during the grace period. In the drill, a client made 165 reads over a 90-second grace and switched tokens halfway, with no failed request. The old token got 401 after the grace.

An operator token loses operator access when it is rotated, because `BARKPARK_OPERATOR_TOKEN_IDS` names the old id. For the admin token from `deploy.sh`:

1. Run `bp token rotate <id> --grace 30m` and keep the new token.
2. In `/opt/barkpark/.env`, replace the old id in `BARKPARK_OPERATOR_TOKEN_IDS` with the new id, and run `sudo systemctl restart barkpark`. Requests failed for 7 seconds during the restart.
3. Write the new token to `/etc/barkpark/admin-token` and its id to `/etc/barkpark/admin-token.id`, mode 600, and run `bp setup --target connect` with it.

## Lost the admin token

`bp instance admin-token` covers instances that Barkpark Cloud manages. On your own VM or Container App, mint a new admin token on the server. The command adds a token with `read`, `write` and `admin` in the default workspace. It writes the token to a file, mode 600, and the id to the same path with `.id` added. It prints only the id and the path. It refuses to replace an existing file unless you pass `--force`. The audit log records the mint as `admin_token_recovery_mint`.

**On a VM.** The default file is `/etc/barkpark/admin-token`. Run the image as root with that directory mounted:

```bash
sudo bash -c '. /etc/barkpark/image.env; docker run --rm --network host --env-file /opt/barkpark/.env -u 0 \
  -v /etc/barkpark:/etc/barkpark "$BARKPARK_IMAGE" bin/admin-token --label "admin (recovered)" --file /etc/barkpark/admin-token'
```

A `deploy.sh` re-run on a box with no token file runs the same command.

**On Container Apps.** The app runs as uid 10001, so name a file under `/tmp`. Images before 0.2.30 lack the script. Open a shell in the app, mint, copy the token and delete the files:

```bash
az containerapp exec -g "$RG" -n "$APP" --command /bin/bash
/app/bin/admin-token --label "admin (recovered)" --file /tmp/admin-token
cat /tmp/admin-token
rm /tmp/admin-token /tmp/admin-token.id
```

Connect with `bp setup --target connect` and the new token. When `BARKPARK_OPERATOR_EMAILS` or `BARKPARK_OPERATOR_FAIL_CLOSED` is set, add the id to `BARKPARK_OPERATOR_TOKEN_IDS`, or `bp org` refuses the token. On a VM, edit `/opt/barkpark/.env` and restart. On Container Apps, edit `barkpark.env` and deploy again. Once connected, `bp token ls -p default` lists the lost token. Revoke it with `bp token revoke <old id> -p default`.

## Rotate the OIDC client secret

Sign-ins through an organization's OIDC connection stop when its client secret expires. Entra ID keeps several secrets valid at once, so the old secret keeps sign-ins working while the new one spreads:

1. Create a new secret and keep the old one. `scripts/entra-app-register.sh` with the same arguments, `--rotate-secret` and a new `--secret-file` adds one, prints its expiry date and waits until Entra accepts it. Entra refused a new secret for about 10 seconds after it was made, and then now and then for 9 more minutes. A sign-in that ends in such a refusal fails.
2. Wait until the UTC time the script prints, 10 minutes after Entra accepts the secret. Then store it with `bp org oidc-rotate-secret <org> - --client_secret_expires_at <expiry date> < <secret file>`. The next sign-in uses it. Without `--client_secret_expires_at` the stored date is cleared.
3. Sign in once through the connection. Then delete the old secret with `az ad app credential delete --id <client id> --key-id <old key id>`. `az ad app credential list --id <client id>` lists the key ids and start dates.

With `BARKPARK_TOKEN_EXPIRY_WARNINGS=on`, the operators on `BARKPARK_OPERATOR_EMAILS` and the owners and admins of the organization's workspaces get a mail 30, 14 and 7 days before the stored date. `bp instance check` prints the date for each connection when it can read the database, and fails once the date has passed. Set a date on an existing connection with `bp org oidc-update <org> --client_secret_expires_at <date>`.
