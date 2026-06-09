<!-- doc-tier: human | canonical-for: js-contributing | budget: 800tok -->
# Contributing to Barkpark JS

## Workflow

1. Fork the repo and branch off `main`.
2. Make your changes, add a changeset (see below), and open a PR.
3. PRs are squash-merged. Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## Local setup

```bash
cd js
pnpm install
pnpm build
```

Requires Node 20+ and pnpm 9+.

## Changesets

Every PR that touches `packages/**` must include a changeset:

```bash
pnpm changeset
```

Follow the prompts, then commit the generated `.changeset/*.md` file. CI's `changeset-check` job blocks merges that touch `packages/**` without one.

## Tests

```bash
pnpm test                              # all projects
pnpm test --project=node               # single package (core, node env)
pnpm test --project=core-workerd       # workerd parity
pnpm test --project=react-browser      # DOM tests
pnpm --filter @barkpark/core test:all  # core: node + workerd + browser
```

## Bundle budget

```bash
pnpm size
```

CI fails on > 2% regression.

## ADR amendment rule

Architecture Decision Records live in `docs/adr/` (backend ADRs: `api/docs/adr/`). Any change touching the **Decision** section of a locked ADR requires a follow-up amendment ADR — not an in-place edit.

## No `node:` imports

`@barkpark/core` and `@barkpark/nextjs` edge subpaths (`client`, `server`, `webhook`, `draft-mode`) must NOT import from `node:*` built-ins. Enforced by `scripts/check-no-node-imports.sh` in CI on every PR.
