<!-- Thanks for contributing to Barkpark! -->

## Summary

<!-- What does this PR change and why? 1-3 sentences. -->

## ADR references

<!-- List any relevant ADRs (e.g., ADR-0001, ADR-0003). Delete this section if none. -->

## Checklist

- [ ] Added a changeset (`pnpm changeset`)
- [ ] Tests pass (`pnpm test`)
- [ ] No NEW `node:` imports introduced in `core` or `nextjs` edge subpaths (`client`, `server`) _(CI check is advisory pending ADR-002; manually confirm)_
- [ ] `pnpm size` passes (each bundle stays under its absolute KB cap — see each package's `.size-limit.json`)

## Risk notes

<!-- Anything reviewers should watch for: breaking changes, runtime concerns,
     performance impact, migration steps, feature flags, etc. Delete if none. -->
