# Contributing to Barkpark JS

Thanks for helping build Barkpark. This guide covers the essentials.

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

## How to add a changeset

Every PR that touches `packages/**` must include a changeset:

```bash
pnpm changeset
```

Follow the prompts, then commit the generated `.changeset/*.md` file with your PR.
CI's `changeset-check` job blocks merges that touch `packages/**` without one.

## How to run tests

```bash
pnpm test                              # all projects
pnpm test --project=core               # single package
pnpm test --project=core-workerd       # workerd parity
pnpm test --project=react-browser      # DOM tests
pnpm --filter @barkpark/core test:contract   # against ephemeral Phoenix
```

## Bundle budgets

```bash
pnpm size
```

CI fails on > 2% regression (ADR-001).

## ADRs

Architecture Decision Records live in `.doey/plans/adrs/`. Any change touching
the **Decision** section of a locked ADR requires a follow-up amendment ADR.

## No `node:` imports

The `@barkpark/core` package and `@barkpark/nextjs` edge subpaths
(`client`, `server`, `webhook`, `draft-mode`) must NOT import from `node:*`
built-ins. This is enforced by `scripts/check-no-node-imports.sh` and runs
in CI on every PR.
