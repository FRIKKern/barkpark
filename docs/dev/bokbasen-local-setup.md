# Bokbasen — local dev setup

How to wire your local Phoenix server up to Bokbasen credentials for the
OnixEdit plugin (Phase 7). Two paths are supported; pick whichever fits.

For the wire-level contract see
[`docs/spec/bokbasen-api-contract.md`](../spec/bokbasen-api-contract.md).
This file only covers credential setup.

## Path A — OS env file (recommended)

Source a local env file before starting the server. Values flow through
`config/runtime.exs` into the application env and are read first by
`Barkpark.Plugins.OnixEdit.Bokbasen.Settings.get_credentials/0`.

```bash
cp secrets/bokbasen.env.example secrets/bokbasen.env
chmod 600 secrets/bokbasen.env
$EDITOR secrets/bokbasen.env

set -a
source secrets/bokbasen.env
set +a

cd api && mix phx.server
```

`secrets/*.env` is git-ignored. `secrets/bokbasen.env.example` is
committed and contains placeholders only — never paste real values
into it.

## Path B — Studio Settings UI

For one-off testing without sourcing an env file, open the admin
Settings page at `/studio/settings`, choose preset **Bokbasen**, and
fill in the 5 typed inputs. Values are written to the encrypted
`plugin_settings` row keyed by `bokbasen` (Phase 1 infrastructure;
the entire JSON map is encrypted at rest via `Barkpark.EncryptedMap`).

Resolution order at lookup time is **env first, then DB**. If you
have OS env vars set, the Studio UI value is shadowed; clear the
env var (or restart the server in a clean shell) to fall back to DB.

## Required keys

| Key                  | Notes                                       |
|----------------------|---------------------------------------------|
| `BOKBASEN_CLIENT_ID`     | OAuth2 client id (treat as secret)      |
| `BOKBASEN_CLIENT_SECRET` | OAuth2 client secret                    |
| `BOKBASEN_API_BASE`      | metadata import API base URL            |
| `BOKBASEN_OAUTH_TOKEN_URL` | OAuth2 token endpoint                 |
| `BOKBASEN_CLIENT_ROLE`   | `publisher` (default) or `distributor`  |

Default `client_role` is `publisher` per the Phase 7 plan (Q-J):
Barkpark = Publisher (Onix-Block-access blocks 0–12).

## Safety

- **Never** commit a real client secret. There is no automated
  secret-leak scanner — the `.githooks/pre-commit` hook only runs
  `mix format --check-formatted` on staged Elixir files. The single
  safeguard is `.gitignore` (`secrets/*.env`), so keep real values in
  `secrets/bokbasen.env` and never paste them into the committed
  `secrets/bokbasen.env.example`.
- The `secrets/` directory is intentionally outside `api/` so it is
  not picked up by Phoenix's static-asset pipeline.
- WI3 (HTTP client) and WI4 (Oban worker) ship later; WI2 only
  plumbs credentials. Confirm with `iex -S mix phx.server`:
  ```elixir
  Barkpark.Plugins.OnixEdit.Bokbasen.Settings.get_credentials()
  ```
