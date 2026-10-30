<!-- doc-tier: human | canonical-for: self-host-pensum-settings | budget: 600tok -->
# Pensum settings

These are the settings a Barkpark instance for Pensum runs with. The setup is in [SELF-HOST.md](SELF-HOST.md).

`bp instance init` writes these for both paths:

```bash
BARKPARK_SELF_UPDATE_CHECK=off
BARKPARK_RETIRE_SSE_ON_SIGTERM=1
BARKPARK_ALWAYS_ALLOWED_ORIGINS=https://<host>,<studio origin>
BARKPARK_STUDIO_SSO_ORIGINS=<studio origin>
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

- `BARKPARK_ALWAYS_ALLOWED_ORIGINS` lists only the instance and Studio, as Pensum calls Barkpark from its server.
- [ENTRA.md](ENTRA.md#the-bootstrap-owner) explains the last three.
- `BARKPARK_BREAKGLASS_EMAILS` lets the [break-glass account](ENTRA.md#break-glass-account) sign in while the org allows only SSO.
- Leave `BARKPARK_SITE_DEPLOY_APPLY`, `BARKPARK_SELF_UPDATE_APPLY`, `CONNECTORS_CONNECT_SECRET` and `INDX_*` unset.

**Mail.** Without `SMTP_HOST`, no sign-in links, password resets or invitations go out. SSO with a break-glass account needs no mail.

## Studio sign-in

A Studio with `STUDIO_SIGN_IN=sso` and `STUDIO_SSO_ORG=<org>` signs editors in through this connection. List its origin in `BARKPARK_STUDIO_SSO_ORIGINS` with no path or trailing slash and run `bp instance check --env-file <file> --studio-url <studio url>`. `bp instance studio-token --workspace <ws>` prints its `BARKPARK_TOKEN` line.
