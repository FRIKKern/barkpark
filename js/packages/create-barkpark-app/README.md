<!-- doc-tier: human | canonical-for: create-barkpark-app | budget: 300tok -->
# create-barkpark-app

Interactive CLI to scaffold a new [Barkpark](https://github.com/barkpark/barkpark)-powered app.

## Quick start

```bash
pnpm create barkpark-app my-site
# or
npx create-barkpark-app my-site
```

Short alias: `pnpm dlx cba my-site`

## Flags

| Flag | Description |
| --- | --- |
| `-t, --template <name>` | `website-starter` or `blog-starter`. |
| `--hosted-demo` | Opt into the public hosted demo at `https://barkpark.dev` instead of local docker-compose. |
| `-y, --yes` | Accept all defaults. |
| `--skip-install` | Do not run pnpm/npm install. |
| `--skip-git` | Do not git init. |

## Templates

- `website-starter` — marketing site: `page`, `post`, `author` schemas.
- `blog-starter` — pure blog: `post`, `author`, `tag` schemas.

## Default local workflow

```bash
cd my-site
docker compose up -d          # Phoenix API + Postgres on :4000
pnpm barkpark generate        # generate types from schema
pnpm dev                      # Next.js on :3000
```

## Demo eject

Pass `--hosted-demo` to skip Docker and use the public read-only dataset at `https://barkpark.dev`. Switch back to local manually:

1. Bring up Docker: `docker compose up -d`
2. Replace `.env.local` with the values from `.env.example`, pointing `BARKPARK_API_URL` to `http://localhost:4000`.
