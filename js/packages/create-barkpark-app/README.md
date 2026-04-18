# create-barkpark-app

Interactive CLI to scaffold a new [Barkpark](https://github.com/barkpark/barkpark)-powered app.

## Quick start

```bash
pnpm create barkpark-app my-site
# or
npm create barkpark-app@latest my-site
# or
npx create-barkpark-app my-site
```

The short alias `cba` is also published:

```bash
pnpm dlx cba my-site
```

## Flags

| Flag | Description |
| --- | --- |
| `-t, --template <name>` | Pick a template non-interactively. `website-starter` or `blog-starter`. |
| `--hosted-demo` | Opt into the public hosted demo at `https://barkpark.dev` instead of local `docker-compose`. |
| `-y, --yes` | Accept all defaults, skip prompts. |
| `--skip-install` | Do not run `pnpm install` / `npm install`. |
| `--skip-git` | Do not `git init` + initial commit. |
| `-v, --version` | Print the CLI version. |
| `-h, --help` | Print help. |

## Templates

- `website-starter` — marketing site, schemas: `page`, `post`, `author`.
- `blog-starter` — pure blog, schemas: `post`, `author`, `tag`.

## Default local story

By default, the CLI scaffolds a project that runs locally:

```bash
cd my-site
docker compose up -d          # Phoenix API + Postgres on :4000
pnpm barkpark codegen         # generate types from schema
pnpm dev                      # Next.js on :3000
```

## Hosted demo

Pass `--hosted-demo` to skip Docker and point at the public read-only dataset hosted at `https://barkpark.dev`. Useful for a 30-second preview before committing to local dev. The hosted demo is opt-in — the default remains local `docker-compose`.

Switch back to self-hosted later with:

```bash
npx barkpark demo eject
```
