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
| `--hosted-demo` | Not available yet: the demo host does not answer, so the flag exits with an error before writing anything. Run a local Barkpark instead. |
| `-y, --yes` | Accept all defaults. |
| `--skip-install` | Do not run pnpm/npm install. |
| `--skip-git` | Do not git init. |

## Templates

- `website-starter` — marketing site: `page`, `post`, `author` schemas.
- `blog-starter` — pure blog: `post`, `author`, `tag` schemas.

## Default local workflow

```bash
# A Barkpark API on :4000 (skip if you already run one)
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup --target local --yes

cd my-site
pnpm barkpark generate        # generate types from schema
pnpm dev                      # Next.js on :3000
```

The generated `docker-compose.yml` is the Docker alternative: it runs the published image `ghcr.io/barkpark/api` and needs a `.env` with the API's secrets — each starter's README lists them.

## Demo eject

The hosted demo at `https://barkpark.dev` is not available yet, so `--hosted-demo` refuses and exits 1. When it returns, it skips Docker and uses the public read-only dataset there. Switch back to local manually:

1. Bring up Docker: `docker compose up -d`
2. Replace `.env.local` with the values from `.env.example`, pointing `BARKPARK_API_URL` to `http://localhost:4000`.
