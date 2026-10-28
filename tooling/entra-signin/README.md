<!-- doc-tier: human | canonical-for: entra-signin-harness | budget: 900tok -->
# entra-signin

`signin.mjs` signs an Entra test user in to a Barkpark organization's OIDC connection in headless Chromium and prints the user's seats. It runs without a person at a browser, so a lane can check group mappings, removed users and MFA on a live instance.

```bash
cd tooling/entra-signin && npm install && npx playwright install chromium-headless-shell
node signin.mjs --host https://<host> --org <org> --user <upn> \
  --password-file <file> --totp-file <file> [--enroll-totp] [--save-token <file>]
node signin.mjs --host https://<host> --check-token <file>
```

It opens `/v1/auth/oidc/<org>/start` with a `return_to` on `--studio-origin` (default `http://localhost:3000`), which must be listed in the instance's `BARKPARK_STUDIO_SSO_ORIGINS`. `bp instance init --studio-origin http://localhost:3000` puts it there, as [SELF-HOST.md](../../docs/setup/SELF-HOST.md#write-and-check-the-settings-file) says. It answers the Entra username, password, authenticator code and "Stay signed in?" (No) pages. It takes the ticket from the callback's redirect, exchanges it at `POST /v1/auth/sso/exchange` and reads `GET /v1/auth/token`. Nothing needs to listen on the origin.

The password and the base32 TOTP secret are read from files and never printed. When Entra asks a new user to register MFA, `--enroll-totp` picks "Set up a different authentication app", stores the secret in `--totp-file` with mode 600 and confirms a code. Microsoft Graph cannot register a software TOTP method for another user, so registration goes through the user's own sign-in.

The output is one JSON object: `outcome` (`ok`, `refused` or `error`), the steps taken, the seats, or the Entra or Barkpark refusal text. Exit codes are 0, 2 and 1. `--save-token` keeps the session token (mode 600) so a later `--check-token` run shows whether that session still works.

With bp 1.26.9 or newer, end a saved session with `bp logout -s https://<host> --token-file <file>`. It exits 1 when the server revoked no session. `--check-token` then reports a refusal. `--logout` ends the session right after the sign-in instead.
