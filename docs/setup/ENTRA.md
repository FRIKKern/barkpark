<!-- doc-tier: human | canonical-for: entra-app-registration | budget: 2500tok -->
# Sign in with Microsoft Entra ID

This guide registers the Entra app that a Barkpark organization signs in through, and connects it to Barkpark. The instance setup is in [SELF-HOST.md](SELF-HOST.md#sign-in-with-entra-id).

## Sign-in URL and redirect URI

The redirect URI holds the organization slug: `https://<host>/v1/auth/oidc/<org>/callback`. Entra accepts sign-ins only for the exact URI on the app. Pick the slug, such as `gyldendal`, before you register the app, and use the same slug in every `bp org` command.

Editors sign in at `https://<host>/v1/auth/oidc/<org>/start`. The script prints both URLs.

## Register the app with the script

Run the script with the Azure CLI, signed in with `az login` as a user who may create app registrations and groups:

```bash
scripts/entra-app-register.sh --host barkpark.example.com --org gyldendal \
  --secret-file ./entra-client-secret --add-owner owner@example.com
```

The script does these steps and is safe to run again:

1. It creates the app registration, or finds it by name. The app is single tenant (`AzureADMyOrg`) and has the redirect URI on the Web platform. A single-page application (SPA) redirect does not work, because Barkpark exchanges the code on the server with a client secret.
2. It turns on the `groups` claim with group object ids, adds the optional `email` and `amr` claims to the ID token, and adds the Microsoft Graph delegated permissions `openid`, `profile` and `email`. It then grants admin consent.
3. It creates the service principal, which is the enterprise app that users sign in to.
4. It creates the owners security group and adds each `--add-owner` user to it.
5. It creates a client secret and writes it to `--secret-file` with mode 600. The secret is never printed. A second run keeps the secret while the file holds one. `--rotate-secret` creates a new one.

At the end it prints the tenant id, client id, owners group id, secret expiry date, the sign-in URL and the `bp org` commands to run next. Record the expiry date in the run log. Sign-ins stop on that date, so rotate the secret before it with `--rotate-secret` and `bp org oidc-rotate-secret`.

## Connect the app to Barkpark

Run the printed commands on your machine with an operator token. They look like this:

```bash
bp org create gyldendal Gyldendal
bp org attach-workspace gyldendal default
bp org oidc-create gyldendal "https://login.microsoftonline.com/$TENANT/v2.0" "$CLIENT_ID" "$(cat ./entra-client-secret)" \
  --tenant_id "$TENANT" --scopes "openid profile email" --strict_validation \
  --set group_role_mappings:='{"<owners group id>":"owner"}'
```

Add more groups to the mapping, such as an editors group mapped to `member`. The keys are group object ids. Each sign-in sets the role from the user's groups and can lower it, so always map the owners group to `owner`. With `BARKPARK_OIDC_KEEP_OWNER=on`, Barkpark refuses a mapping that maps no group to `owner` while the organization has an owner, and a sign-in never lowers a workspace's last owner.

The `profile` scope gives Barkpark `preferred_username`, which the UPN match below needs. Barkpark does not read the `name` claim, so `profile` is not needed for display names.

## Entra MFA counts as Barkpark MFA

`bp org oidc-update <org> --trust_idp_mfa` makes a sign-in count as MFA when the ID token's `amr` claim contains `mfa`. A v2.0 ID token carries `amr` only when the app requests it as an optional claim. The script adds it. In the portal, add `{"name": "amr", "essential": false}` to `optionalClaims.idToken` in the app's Manifest. Entra puts `mfa` in `amr` only when the user completed MFA in that sign-in, so require MFA for the app with a Conditional Access policy.


## The bootstrap owner

`BARKPARK_BOOTSTRAP_OWNER_EMAIL` seats the first owner on a fresh instance. Barkpark matches a sign-in to that owner on the ID token's `email` claim, ignoring case. Entra leaves out `email` for an account with no mailbox address. Set `BARKPARK_OIDC_EMAIL_FROM_UPN=on` so Barkpark matches on `preferred_username`, the UPN, when `email` is absent. The connection needs the `profile` scope for that claim.

The bootstrap owner does not need domain verification. The owner holds a seat in the default workspace, and that seat lets the organization's connection sign the owner in.

## Break-glass account

An instance without outgoing mail cannot send a password reset link, so the owner has no way in while Entra or the connection is broken. A break-glass account on `BARKPARK_BREAKGLASS_EMAILS` signs in with a password and TOTP, or a passkey, even when the organization allows only SSO. Create it before you run `bp org auth-methods <org> sso`:

1. `bp auth register <email> <password>` creates the account.
2. `bp auth login <email> <password>` returns a token. With `BARKPARK_TOKEN` set to it, `bp auth mfa-enroll <password>` returns a TOTP secret. Add it to an authenticator, then run `bp auth mfa-verify <secret> <code> <password>`.
3. As an owner, `bp workspace member-add <email>` seats it.

## Domain verification

`bp org domain-add <org> <domain>` prints a TXT record value, `barkpark-verify=...`. Publish it as a TXT record on the domain itself, such as `gyldendal.no`, not on a subdomain. `bp org domain-verify <org> <domain>` then checks it. A verified domain does two things:

- The sign-in page sends a user with an address in that domain to the organization's Entra sign-in.
- The connection may sign in an existing Barkpark account with an address in that domain, even when the account holds no seat in the organization.

Pensum does not need it when editors open the sign-in URL above and every account is created by its first Entra sign-in. Add it when existing accounts must move to Entra sign-in, or when editors start from the generic sign-in page.

## Users in many groups

Entra puts at most 200 groups in a token. A user in more groups gets an overage claim, `_claim_names`, instead of `groups`. Barkpark does not call Microsoft Graph to read the groups. That user's existing role stays as it is, and a new user gets `member`.

The script's default, `--group-claims application`, avoids this. Entra then puts only the groups assigned to the app in the token. The script assigns the owners group to the app. Assign each other mapped group in the portal under Enterprise applications, Users and groups. This mode counts direct members only and needs Entra ID P1. Without P1, run the script with `--group-claims security`, which sends every security group, and keep users who need a mapped role under 200 groups.

## Portal steps

When the Azure CLI is not available, do the same in the Entra admin center:

1. App registrations, New registration. Accounts in this organizational directory only. Redirect URI platform Web, with the URI above.
2. Token configuration. Add groups claim, Groups assigned to the application, or Security groups without P1, emitted as Group ID. Add optional claim, ID token, `email`. In Manifest, add `{"name": "amr", "essential": false}` to `optionalClaims.idToken`.
3. API permissions. Microsoft Graph delegated `openid`, `profile` and `email`, then Grant admin consent.
4. Certificates and secrets. New client secret. Copy the value once and note the expiry date.
5. Groups. Create the owners security group and add the owner. Under Enterprise applications, Users and groups, assign the group to the app.
6. Copy the Directory (tenant) ID, the Application (client) ID and the group's Object ID into the commands above.
