<!-- doc-tier: agent | canonical-for: twoslash-mocks | budget: 100tok -->
# @barkpark/twoslash-mocks

**DORMANT** — stubs compile and the CI gate self-skips. No docs app consumes them yet.

Ambient TypeScript declarations that let `shiki-twoslash` type-check `next/*` imports in doc fences without installing the real Next.js inside the docs build. The target consumer is `js/docs/` (Fumadocs); when it adds twoslash support, pass the stubs via `extraFiles`.

**No `apps/docs/` path exists.** Earlier drafts assumed it; it does not. `.github/workflows/twoslash.yml` detects `apps/docs/` absence and self-skips — zero CI cost today.

**No real-next rationale:** installing the real `next` package in the docs build adds ~600 MB and couples docs CI to Next runtime versions. The ~200-line stubs are zero-dep and match Next.js 15.x (async `headers()`, `cookies()`, `draftMode()`).

## Adding a stub

1. Add an ambient `declare module "<specifier>"` block in `next-stubs.d.ts`.
2. Match signatures to `@barkpark/nextjs`'s `peerDependencies` (currently `>=15 <17`).
3. Verify: `npx tsc --noEmit --strict tooling/twoslash-mocks/next-stubs.d.ts`
