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

Follow the prompts, then commit the generated `.changeset/*.md` file. CI's `changesets` job blocks merges that touch `packages/**` without one.

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

CI fails if an entry exceeds the **absolute** byte cap declared for it in that package's `.size-limit.json`. The caps are not restated here: a number copied into prose goes stale silently (this line claimed 12 KB / 13 KB long after the real caps had moved), and then a reader cannot tell which of the two binds. Read `.size-limit.json`; it is the cap.

There is no percentage budget and no regression comparison — nothing in this repo stores a previous build to compare against. A cap breach means **trim the bundle**, not raise the number.

## ADR amendment rule

Architecture Decision Records live in `docs/adr/` (backend ADRs: `api/docs/adr/`). Any change touching the **Decision** section of a locked ADR requires a follow-up amendment ADR — not an in-place edit.

## No `node:` imports

`@barkpark/core` and `@barkpark/nextjs` edge subpaths (`client`, `server`, `webhook`, `draft-mode`) must NOT import from `node:*` built-ins. Checked (currently advisory, not blocking) by `scripts/check-no-node-imports.sh` in CI on every PR — see `docs/decisions/deferred.md` for the pending ADR-002 resolution.
