---
'@barkpark/nextjs': patch
'@barkpark/react': patch
'create-barkpark-app': patch
---

Release the entry points the starters already import (owner item 54).

The versions on npm were built long before the code the `create-barkpark-app`
starters now import: `@barkpark/nextjs@1.0.0-preview.3` was published on
2026-04-27 from 0c81beeb1 and has no `barkparkMetadata` (added in #963,
2026-07-03); `@barkpark/react@1.0.0-preview.1` was published on 2026-04-19 and
exports only `.` and `./package.json`, with no `./client` (#3604) and no
`./paper-surface.css` (#3449). A fresh blog-starter or website-starter scaffold
therefore fails `next build` against the registry. This release carries all
three. The package.json version on main is the last published version, and
everything merged since is waiting in pending changesets, so the workspace and
the registry show the same version number with different contents.

`@barkpark/nextjs`: `revalidateBarkpark` now accepts the payload that
`createWebhookHandler` hands to `onMutation`. Since #550 that payload is core's
`WebhookEvent`, whose `document` is `Record<string, unknown> | null` and whose
`workspace` / `project` are `string | null`, while `RevalidatePayload` declared
`document?: { _id?: string; _type?: string }` and `workspace?` / `project?` as
`string`. So the documented route, `onMutation: (payload) =>
revalidateBarkpark(payload)`, which both starters ship, failed `next build` at
the type check even with every export present. `RevalidatePayload` now also
takes `null` for these three fields and an untyped record for `document`. The
runtime already read `document._id` / `_type` through a non-empty-string guard,
so runtime behaviour is unchanged.

`create-barkpark-app` gains `tests/template-named-exports.test.ts`: every named
`@barkpark/*` import in a starter template must be exported by the source entry
that each of the package's `exports` conditions resolves to (`react-server`
included). It reads the source offline, so it cannot see a name that the source
exports but a published version lacks. Only a release closes that gap.
