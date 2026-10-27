<!-- doc-tier: human | canonical-for: self-host-updates | budget: 2500tok -->
# Update an instance and rotate its credentials

This page comes after setup in [SELF-HOST.md](SELF-HOST.md), next to [SELF-HOST-OPERATIONS.md](SELF-HOST-OPERATIONS.md). It covers updates and rollbacks, API token rotation and OIDC client secret rotation.

## Rotate the OIDC client secret

Sign-ins through an organization's OIDC connection stop when its client secret expires. Entra ID keeps several secrets valid at once, so a rotation has no downtime:

1. Create a new secret and keep the old one. `scripts/entra-app-register.sh` with the same arguments and `--rotate-secret` adds one and prints its expiry date.
2. Store it with `bp org oidc-rotate-secret <org> "$(cat <secret file>)" --client_secret_expires_at <expiry date>`. The next sign-in uses it. Without `--client_secret_expires_at` the stored date is cleared.
3. Sign in once through the connection. Then delete the old secret with `az ad app credential delete --id <client id> --key-id <old key id>`. `az ad app credential list --id <client id>` lists the key ids.

With `BARKPARK_TOKEN_EXPIRY_WARNINGS=on`, the operators on `BARKPARK_OPERATOR_EMAILS` and the owners and admins of the organization's workspaces get a mail 30, 14 and 7 days before the stored date. `bp instance check` prints the date for each connection when it can read the database, and fails once the date has passed. Set a date on an existing connection with `bp org oidc-update <org> --client_secret_expires_at <date>`.
