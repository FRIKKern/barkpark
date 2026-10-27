<!-- doc-tier: human | canonical-for: self-host-updates | budget: 2500tok -->
# Update an instance and rotate its credentials

This page comes after setup in [SELF-HOST.md](SELF-HOST.md), next to [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md). It covers updates and rollbacks on a single VM, API token rotation and OIDC client secret rotation. The times below come from a drill on `Standard_D2als_v7` on 2026-10-27.

## Update and roll back a single VM

`/opt/barkpark` is a git checkout of `main`. `GET /status.json` shows the running `commit` and `version`. Take a backup as [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill) describes, and note the commit:

```bash
sudo git -C /opt/barkpark rev-parse --short HEAD
```

**Update.** Run `sudo git -C /opt/barkpark pull`. The post-merge hook runs `scripts/deploy-rebuild.sh`. It builds the new code in `api/_build_next` while the old code serves, runs the migrations, swaps the build in and restarts. A failed build or migration leaves the old build running with no restart. `sudo cat /opt/barkpark/.git/barkpark-deploy-outcome` prints `rebuilt` after a good update. An update took 3 to 4 minutes, and requests failed with 503 for 16 seconds during the restart. When the update adds a migration, `/readyz` also answers 503 from the pull until the migration has run, 175 seconds in the drill, because the running server counts the new migration file as pending. A load balancer that routes on `/readyz` sees that as downtime.

**Roll back.** Move the checkout back and rebuild:

```bash
sudo git -C /opt/barkpark reset --hard <previous commit>
sudo make -C /opt/barkpark rebuild
```

The rollback took 3 minutes 17 seconds, with 16 seconds of 503. Migrations stay applied. The drill's migration added two columns, and the older code ran with them. When an update has a migration that changes or removes data, roll back the code and restore the backup taken before the update. Do not use `git checkout <commit>`, which detaches the checkout so the next `git pull` fails. After a rollback, `git pull` updates to `main` again.

## Rotate an API token

`bp token ls` lists the token ids. `bp token rotate <id> --grace 24h` prints the new token once and keeps the old one working for the grace period, at most `7d`. `--now` ends the old one at once. The new token keeps the old expiry unless you pass `--expires_in_days N`. Give the new token to each client during the grace period. In the drill, a client made 165 reads over a 90-second grace and switched tokens halfway, with no failed request. The old token got 401 after the grace.

An operator token loses operator access when it is rotated, because `BARKPARK_OPERATOR_TOKEN_IDS` names the old id. For the admin token from `deploy.sh`:

1. Run `bp token rotate <id> --grace 30m` and keep the new token.
2. In `/opt/barkpark/.env`, replace the old id in `BARKPARK_OPERATOR_TOKEN_IDS` with the new id, and run `sudo systemctl restart barkpark`. Requests failed for 7 seconds during the restart.
3. Write the new token to `/etc/barkpark/admin-token` and its id to `/etc/barkpark/admin-token.id`, mode 600, and run `bp setup --target connect` with it.

## Rotate the OIDC client secret

Sign-ins through an organization's OIDC connection stop when its client secret expires. Entra ID keeps several secrets valid at once, so the old secret keeps sign-ins working while the new one spreads:

1. Create a new secret and keep the old one. `scripts/entra-app-register.sh` with the same arguments, `--rotate-secret` and a new `--secret-file` adds one, prints its expiry date and waits until Entra accepts it. Entra refused a new secret for about 10 seconds after it was made, and then now and then for 9 more minutes. A sign-in that ends in such a refusal fails.
2. Wait 10 minutes after the secret was made. Then store it with `bp org oidc-rotate-secret <org> "$(cat <secret file>)" --client_secret_expires_at <expiry date>`. The next sign-in uses it. Without `--client_secret_expires_at` the stored date is cleared.
3. Sign in once through the connection. Then delete the old secret with `az ad app credential delete --id <client id> --key-id <old key id>`. `az ad app credential list --id <client id>` lists the key ids and start dates.

With `BARKPARK_TOKEN_EXPIRY_WARNINGS=on`, the operators on `BARKPARK_OPERATOR_EMAILS` and the owners and admins of the organization's workspaces get a mail 30, 14 and 7 days before the stored date. `bp instance check` prints the date for each connection when it can read the database, and fails once the date has passed. Set a date on an existing connection with `bp org oidc-update <org> --client_secret_expires_at <date>`.
