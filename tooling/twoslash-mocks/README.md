# @barkpark/twoslash-mocks

Ambient TypeScript declarations that let `shiki-twoslash` type-check
documentation code fences referencing Next.js internals without installing
Next.js inside the docs build.

## What's mocked

| Module             | Exports                                                                 |
| ------------------ | ----------------------------------------------------------------------- |
| `server-only`      | default marker                                                          |
| `client-only`      | default marker                                                          |
| `next/cache`       | `revalidateTag`, `revalidatePath`, `unstable_noStore`, `unstable_cache` |
| `next/headers`     | `headers`, `cookies`, `draftMode` (all async, Next 15.x shape)          |
| `next/navigation`  | `notFound`, `redirect`, `permanentRedirect`, `useRouter`, `usePathname`, `useSearchParams`, `useParams` |
| `next/og`          | `ImageResponse`                                                         |
| `next`             | `Metadata`, `NextPage` (thin subset)                                    |
| `next/link`        | default `<Link>` component shape                                        |
| `next/image`       | default `<Image>` component shape                                       |

Signatures match Next.js 15.x. `headers()`, `cookies()`, and `draftMode()`
return Promises — this is the Next 15 breaking change that motivates the
mock in the first place.

## Why this exists

Docs fenced blocks like:

~~~md
```ts twoslash
import { revalidateTag } from "next/cache"
import { headers } from "next/headers"
// ...
```
~~~

…are type-checked by `shiki-twoslash` against an isolated in-memory TS
program. Without these stubs, every such block errors with
`Cannot find module "next/cache"` and the docs build fails. Installing the
real `next` package inside the docs app is heavy (600MB of dependencies)
and couples docs CI to Next runtime versions.

The mocks are small (~200 lines), standalone, and compile with zero
dependencies.

## Current consumption status

These stubs and the standalone `tsc` check (see "Adding a new stub" below)
are wired and pass. **No docs app consumes them yet.** The Fumadocs docs app
lives at `js/docs/` and has no twoslash / `extraFiles` / `next-stubs` wiring
(grep `js/docs` for any of those returns nothing). The `apps/docs/` path that
earlier drafts assumed does not exist.

The CI gate `.github/workflows/twoslash.yml` is therefore **dormant** — it
detects whether `apps/docs/` is present and self-skips when it is absent
(which is the current state), so it runs nothing on PRs today.

When a docs app is scaffolded that wants twoslash on its code fences, it would
read this file and pass it to twoslash via `extraFiles`, e.g.:

```ts
// source.config.ts in the future docs app
import fs from "node:fs";
import path from "node:path";
import { defineConfig } from "fumadocs-mdx/config";
import { transformerTwoslash } from "@shikijs/twoslash";

const nextStubs = fs.readFileSync(
  path.resolve(__dirname, "../../tooling/twoslash-mocks/next-stubs.d.ts"),
  "utf8"
);

export default defineConfig({
  mdxOptions: {
    rehypeCodeOptions: {
      transformers: [
        transformerTwoslash({
          twoslashOptions: {
            extraFiles: { "next-stubs.d.ts": nextStubs },
          },
        }),
      ],
    },
  },
});
```

## Adding a new stub

1. Add an ambient `declare module "<specifier>"` block in `next-stubs.d.ts`.
2. Include ONLY the exports used by docs snippets — resist mirroring the full
   upstream API.
3. Match signatures to the Next.js release pinned by `@barkpark/nextjs`'s
   `peerDependencies` (currently `>=15 <17`).
4. Verify standalone compile:

   ```sh
   npx tsc --noEmit --strict tooling/twoslash-mocks/next-stubs.d.ts
   ```

5. Re-run the docs app type-check once a docs app actually consumes these
   stubs — CI's `twoslash.yml` workflow stays dormant (self-skips) until then.

## Not a runtime package

This package publishes no JS. It ships `.d.ts` only. If you find yourself
wanting to import values from here, you want the real `next` package, not
this mock.
