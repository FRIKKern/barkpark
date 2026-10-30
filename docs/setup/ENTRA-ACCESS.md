<!-- doc-tier: human | canonical-for: entra-access-control | budget: 1200tok -->
# Who keeps access with Entra sign-in

This page belongs to [ENTRA.md](ENTRA.md). It covers removed users and the break-glass account. The steps were run on a staging instance on 2026-10-27.

## Removed users

Disable or delete a user in Entra, and Entra refuses their next sign-in.

`bp org oidc-update <org> --require_group_match --yes` lets only users in a mapped group sign in. The setting is off by default. With it on, Barkpark refuses a sign-in whose groups match no mapping with the error `no_mapped_group`. It also removes the user's seats with a role the connection gives, a mapped role or `member`, and revokes the user's Barkpark sessions. A workspace's last owner keeps the seat. A user with more than 200 groups gets no `groups` claim and is refused too, as [ENTRA.md](ENTRA.md#users-in-many-groups) describes. Turn it off with `--set require_group_match:=false`.

Entra can also refuse users outside the mapped groups before they reach Barkpark. Assign each mapped group, the owners group included, to the enterprise app, then turn on assignment:

```bash
az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo" \
  --body "{\"principalId\":\"$GROUP_ID\",\"resourceId\":\"$SP_ID\",\"appRoleId\":\"00000000-0000-0000-0000-000000000000\"}"
az ad sp update --id "$SP_ID" --set appRoleAssignmentRequired=true
```

`$SP_ID` is the enterprise app's object id. Entra then answers AADSTS50105 to a user in none of the assigned groups. The portal offers group assignment only with Entra ID P1. On 2026-10-27 the Graph call worked on a tenant without P1, and Entra enforced it.

Both act at the next sign-in. Barkpark sessions that already exist keep working until they expire, by default 30 days after sign-in. To end access at once, disable the user in Entra and remove the seat with `bp workspace member-rm <email> -w <workspace> -p <project>`.

## Break-glass account

An instance without outgoing mail cannot send a password reset link, so the owner has no way in while Entra or the connection is broken. A break-glass account on `BARKPARK_BREAKGLASS_EMAILS` signs in with a password and TOTP, or a passkey, even when the organization allows only SSO. Create it with the operator token in `BARKPARK_TOKEN`:

1. `bp auth register <email> <password>` creates the account. It stays unconfirmed, because no mail goes out.
2. Confirm it on the server: `bin/barkpark eval 'Barkpark.Release.confirm_email("<email>")'` in the container, on a VM after `sudo docker exec barkpark`. Seating an unconfirmed account replaces its password.
3. `bp auth login <email> <password>` prints a session token. With `BARKPARK_TOKEN` set to it, `bp auth mfa-enroll <password>` prints a TOTP secret. Add it to an authenticator, then run `bp auth mfa-verify <secret> <code> <password>` and keep the recovery codes. An instance older than #24495 refuses the session token here.
4. `bp workspace member-add <email> --role admin` with the operator token invites the account. Only an owner can give `owner`. With the session token, `bp auth invitation-ls` shows the invitation and `bp auth invitation-accept <id>` takes the seat.

Then sign in with `bp auth login <email> <password> --totp_code <code>`. While the organization allows only SSO, each such sign-in writes a `breakglass_login` audit event.
