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

## How Track A's docs site consumes this

Fumadocs reads the file at config time and passes it to twoslash via
`extraFiles`:

```ts
// apps/docs/source.config.ts — owned by Track A
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

5. Re-run the docs app type-check (`pnpm --filter docs build` once Track A
   has scaffolded `apps/docs`) — CI's `twoslash.yml` workflow gates this on
   every PR.

## Not a runtime package

This package publishes no JS. It ships `.d.ts` only. If you find yourself
wanting to import values from here, you want the real `next` package, not
this mock.
