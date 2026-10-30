<!-- doc-tier: human | canonical-for: entra-app-registration | budget: 2500tok -->
# Sign in with Microsoft Entra ID

This guide registers the Entra app an organization signs in through and connects it to Barkpark. The instance setup is in [SELF-HOST.md](SELF-HOST.md#sign-in-with-entra-id).

## Sign-in URL and redirect URI

The redirect URI holds the organization slug: `https://<host>/v1/auth/oidc/<org>/callback`. Entra accepts sign-ins only for the exact URI on the app. Pick the slug, such as `gyldendal`, before you register the app, and use the same slug in every `bp org` command.

Editors sign in at `https://<host>/v1/auth/oidc/<org>/start`. The script prints both URLs.

## Create the app with the Bicep template

On Container Apps, `main.bicep` can create the Entra side in the same deployment, without Entra ID P1. Add:

```bash
-p entraEnabled=true entraOrg=gyldendal entraOrgName=Gyldendal 'entraOwnerUpns=["owner@example.com"]'
```

`entra.bicep` then does script steps 1 to 4 below on the instance host, and adds the deploying user to the owners group. A deployment script writes a client secret for `entraSecretYears`, 1 by default, only to the Key Vault as `oidc-client-secret`. At its first boot the app makes the organization, the workspace link and the connection that the `bp org` commands below make, with `trust_idp_mfa` unless `entraTrustIdpMfa=false`. It never changes a connection that exists. The output `entraSignInUrl` is the sign-in URL. The deploying user needs the roles in [IT-HANDOVER.md](IT-HANDOVER.md#what-you-create).

For a VM, `entra.bicep` deploys alone with `-p host=<host> org=<org>` and makes no secret. To add or rotate a secret, run the script with `--app-id <entraClientId>`, `--owners-group "<group name>"` and `--secret-file`.

## Register the app with the script

Run it with the Azure CLI as a user who may create app registrations and groups:

```bash
curl -fsSLO https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/entra-app-register.sh
bash entra-app-register.sh --host barkpark.example.com --org gyldendal \
  --secret-file ./entra-client-secret --add-owner owner@example.com --org-name Gyldendal
```

The script finds the app by `--app-id`, `--name` or the name `Barkpark <org>`, and the owners group by `--owners-group` or `Barkpark <org> owners`. Another instance can own either, so it stops when that app has no redirect URI on `--host`, or when a new app would reuse the group.

The script does these steps and is safe to run again:

1. It creates the app registration, or finds it by `--app-id` or by name. The app is single tenant (`AzureADMyOrg`) and has the redirect URI on the Web platform. A single-page application redirect does not work.
2. It turns on the `groups` claim with group object ids, adds the optional `email` and `amr` claims to the ID token, and adds the Microsoft Graph delegated permissions `openid`, `profile` and `email`. It then grants admin consent itself and retries until the tenant-wide consent holds all three scopes. It stops with an error after about a minute.
3. It creates the service principal, which is the enterprise app that users sign in to.
4. It creates the owners security group and adds each `--add-owner` user to it.
5. It creates a client secret only when the app has none or with `--rotate-secret`, and writes it to `--secret-file` with mode 600. The secret is never printed. Without the secret file it prints the expiry date of each existing secret. Entra never shows a secret again, so keep the file from the first run.

At the end it prints the ids, the secret expiry date, the sign-in URL and the `bp org` commands to run next. Sign-ins stop on the expiry date. The printed commands store it with `--client_secret_expires_at`, and with `BARKPARK_TOKEN_EXPIRY_WARNINGS=on` the operators get a mail 30, 14 and 7 days ahead. Rotate the secret as [SELF-HOST-UPDATES.md](SELF-HOST-UPDATES.md#rotate-the-oidc-client-secret) describes.

For a new app, run the printed commands at once. Until the time the script prints, Entra can refuse the secret now and then, and a sign-in that fails with `AADSTS7000215` works on a second try. After `--rotate-secret`, store the secret after that time.

## Connect the app to Barkpark

Run the printed commands on your machine with an operator token. They look like this:

```bash
bp org create gyldendal Gyldendal --yes
bp org attach-workspace gyldendal default --yes
bp org oidc-create gyldendal "https://login.microsoftonline.com/$TENANT/v2.0" "$CLIENT_ID" - \
  --tenant_id "$TENANT" --scopes "openid profile email" --strict_validation \
  --client_secret_expires_at <secret expiry date> \
  --set group_role_mappings:='{"<owners group id>":"owner"}' --yes < ./entra-client-secret
```

`Gyldendal` is the organization name Barkpark shows, from the script's `--org-name` or the slug.

Add more groups to the mapping, such as an editors group mapped to `member`. The keys are group object ids. Each sign-in sets the role from the user's groups and can lower it, so always map the owners group to `owner`. With `BARKPARK_OIDC_KEEP_OWNER=on`, Barkpark refuses a mapping that maps no group to `owner` while the organization has an owner, and a sign-in never lowers a workspace's last owner.

The scopes must be `openid profile email`. The `profile` scope gives Barkpark `preferred_username`, which the UPN match below needs. Fix a connection made with other scopes:

```bash
bp org oidc-update gyldendal --scopes "openid profile email" --yes
```

## Entra MFA counts as Barkpark MFA

`bp org oidc-update <org> --trust_idp_mfa --yes` makes a sign-in count as MFA when the ID token's `amr` claim contains `mfa`. A v2.0 ID token carries `amr` only when the app requests it as an optional claim. The script adds it, and [portal step 2](#portal-steps) does the same. Entra puts `mfa` in `amr` only when the user completed MFA in that sign-in, so require MFA for the app with a Conditional Access policy.

Conditional Access needs Entra ID P1. Without P1, security defaults make each user register an authenticator at the first sign-in but do not ask for it at every sign-in. With `trust_idp_mfa` on a connection that has `--tenant_id`, Barkpark asks Entra for MFA with the OIDC `claims` parameter. On 2026-10-27, on a tenant with security defaults and no P1, Entra then asked a non-admin user for the code at every sign-in.

Turn `trust_idp_mfa` on once a test sign-in works, then sign in again. A `TOTP code` step in the [tooling/entra-signin](../../tooling/entra-signin/README.md) output shows Entra asked for the code, and `idp_mfa: true` shows Barkpark counted it. [bp login --sso](#sign-the-bp-cli-in-with-sso) shows `idp_mfa` too.

## Removed users

[ENTRA-ACCESS.md](ENTRA-ACCESS.md#removed-users) covers removed users, `require_group_match` and domain verification.

## The bootstrap owner

`BARKPARK_BOOTSTRAP_OWNER_EMAIL` seats the first owner on a fresh instance. Barkpark matches a sign-in to that owner on the ID token's `email` claim, ignoring case. Entra leaves out `email` for an account with no mailbox address. Set `BARKPARK_OIDC_EMAIL_FROM_UPN=on` so Barkpark matches on `preferred_username`, the UPN, when `email` is absent.

The bootstrap owner needs no domain verification, because the owner's seat in the default workspace lets the connection sign the owner in.

## Break-glass account

A break-glass account on `BARKPARK_BREAKGLASS_EMAILS` signs in with a password and TOTP, or a passkey, even when the organization allows only SSO. Create it before you run `bp org auth-methods <org> sso`, as [ENTRA-ACCESS.md](ENTRA-ACCESS.md#break-glass-account) describes.

## Sign the bp CLI in with SSO

An owner who signs in only through Entra signs bp in on their own machine:

```bash
bp login --sso --org gyldendal -s https://<host>
```

bp opens the sign-in URL and waits for the answer on a random port on 127.0.0.1. The instance accepts that loopback return without `BARKPARK_STUDIO_SSO_ORIGINS`. bp saves the session as its token for that server and prints the email and the expiry, with `idp_mfa` under `-o json`. `--no-browser` prints the URL to open on the same machine. Commands such as `bp instance studio-token --workspace default` then run as the owner. `bp logout -s https://<host>` revokes that session.

## Users in many groups

Entra puts at most 200 groups in a token. A user in more groups gets an overage claim, `_claim_names`, instead of `groups`. Barkpark does not call Microsoft Graph to read the groups. That user's existing role stays as it is, and a new user gets `member`.

`--group-claims application` avoids this. The script uses it when the tenant has Entra ID P1. Entra then puts only the groups assigned to the app in the token. The script assigns the owners group to the app. Assign each other mapped group in the portal under Enterprise applications, Users and groups. This mode counts direct members only. Without P1 the script prints a note and uses `--group-claims security`, which sends every security group. Keep users who need a mapped role under 200 groups.

## Portal steps

Without the Azure CLI, do the same in the Entra admin center:

1. App registrations, New registration. Accounts in this organizational directory only. Redirect URI platform Web, with the URI above.
2. Token configuration. Add groups claim, Groups assigned to the application, or Security groups without P1, emitted as Group ID. Add optional claim, ID token, `email`. In Manifest, add `{"name": "amr", "essential": false}` to `optionalClaims.idToken`.
3. API permissions. Microsoft Graph delegated `openid`, `profile` and `email`, then Grant admin consent.
4. Certificates and secrets. New client secret. Copy the value once and note the expiry date.
5. Groups. Create the owners security group and add the owner. Under Enterprise applications, Users and groups, assign the group to the app.
6. Copy the Directory (tenant) ID, the Application (client) ID and the group's Object ID into the commands above.
