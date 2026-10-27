<!-- doc-tier: human | canonical-for: self-host-it-handover | budget: 1600tok -->
# Hand over a Barkpark instance to your IT department

This page is for the IT department of an organisation that will own and run one Barkpark instance for one app. The instance runs on your own Azure subscription, and editors sign in with Microsoft Entra ID. The setup steps are in [SELF-HOST.md](SELF-HOST.md#path-b-azure-container-apps), and the operating steps are in [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md).

## What you get

`deploy/azure/main.bicep` creates these in one resource group:

| Resource | Size in the template |
|---|---|
| Container App `barkpark` in an environment on the virtual network | 1 vCPU, 2 GiB, exactly one replica |
| Jobs `barkpark-backup` and `barkpark-ops` for backup, restore and checks | A daily backup, kept 14 days |
| Virtual network with a subnet for the environment and one for Postgres | 10.40.0.0/16 by default |
| Private DNS zone for Postgres, linked to the virtual network | |
| PostgreSQL Flexible Server 17 | Standard_B1ms, 32 GB, 7 days of backups |
| Storage account with Azure Files shares for media and backups | 100 GB quota each |
| Key Vault with the instance keys | RBAC, soft delete for 7 days |
| Log Analytics workspace for app logs | 30 days |
| User-assigned identity that reads the Key Vault secrets | |

Postgres has no public endpoint and answers only inside the virtual network. The Key Vault and the storage account accept the environment's subnet and the addresses in `operatorIpRanges`. Only the app's HTTPS ingress is public. `deploy/azure/monitor.bicep` adds alerts for `/readyz`, a failed backup job and repeated restarts, as [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md#container-apps-alerts) describes.

## What you create

1. Access to the subscription for the person who deploys, and the resource providers that [SELF-HOST.md](SELF-HOST.md#before-you-start-on-azure) lists.
2. A resource group in the chosen region.
3. The Entra app registration. Run `scripts/entra-app-register.sh` as a user who may create app registrations and groups, as [ENTRA.md](ENTRA.md#register-the-app-with-the-script) describes.
4. An owners group. The script creates it, and Barkpark maps it to the `owner` role.
5. An editors group. Create it in Entra, assign it to the app, and map it to `member`.
6. A host name. Without one, the app answers on its Container Apps default host. The host name becomes `PHX_HOST`, and passkeys stop working if it changes later.
7. A [break-glass account](ENTRA.md#break-glass-account) that signs in without Entra, and a safe place for its password and TOTP secret.

## What you decide

- **Region.** Norway East offers Flexible Server on Standard_B1ms and Container Apps consumption.
- **Network.** The template creates its own virtual network. To join an existing one, pass `appsSubnetId` and `postgresSubnetId`, and `postgresPrivateDnsZoneId` for a central DNS zone. `deploy/azure/main.bicep` lists the size, delegation and service endpoints each subnet needs. Choose the addresses for `operatorIpRanges`.
- **Owners.** Name the people in the owners group. Each sign-in sets the role from the user's groups.
- **Conditional Access and MFA.** Require MFA for the app with a Conditional Access policy. Barkpark then counts Entra MFA as its own, as [ENTRA.md](ENTRA.md#entra-mfa-counts-as-barkpark-mfa) describes.
- **Group claims.** Groups assigned to the app need Entra ID P1. Without P1, run the script with `--group-claims security`.
- **Backup retention.** Choose 7 to 35 days for the database. Decide whether Azure Backup takes snapshots of the media share.
- **Alerts.** Name the address that receives them. Add Azure Monitor alerts for the database if you need them.

## What it costs

The monthly cost in Norway East at the template's sizes is about USD 47 to 101. The [cost table](SELF-HOST-OPERATIONS.md#container-apps-cost) breaks it down. The Container App is most of the range, from 24 idle to 73 busy. The cost rises with a larger database size, high availability, geo-redundant backups, more log volume, and Azure Backup for the shares.

## Who does what after go-live

| Task | What to do |
|---|---|
| Upgrades | Pin an image version, such as `ghcr.io/frikkern/barkpark:0.2.28`. The image never updates itself. To upgrade, note the time and the current tag, set `image` in `main.bicepparam`, run `az deployment group create` again and check `/readyz`. Migrations run when the new image starts. |
| Roll back | Run the same command with the old tag. If the old image does not start on the migrated database, restore the database to the time you noted. |
| Entra client secret | It expires after 1 or 2 years, and the script prints the date. Sign-ins stop on that date. Put the date in your calendar and rotate it before then with `--rotate-secret` and `bp org oidc-rotate-secret`. |
| Barkpark keys | Keep a copy in a password manager, apart from the backups. Rotate them as [the key rotation section](SELF-HOST-OPERATIONS.md#rotate-keys) describes. Never change `BARKPARK_CLOAK_KEY`. |
| Backups | `barkpark-backup` runs `bp instance backup` every day. Flexible Server also keeps point-in-time restore for the retention period. Turn on purge protection on the Key Vault. |
| Restore drill | Once a month, run [the restore drill](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill) and record the result. |
| Who to call | Your IT runs Azure, Entra, DNS, backups and alerts. The app team runs Barkpark settings, organisations and roles. Report a Barkpark bug as an issue on the Barkpark repository. Send a security problem to the app team, not to a public issue. |
