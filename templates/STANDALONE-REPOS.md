<!-- doc-tier: human | canonical-for: template-standalone-repos | budget: 2600tok -->
# Standalone template repositories

The blog and website starters ship as two public repositories, `template-blog`
and `template-website`, so that the Vercel clone handoff and the deploy worker
can clone a repository whose root is the app. Both repositories are generated
output. This monorepo is the only place their content is edited.

```
monorepo @ <sha>                                   exported tree (repo root)
  js/packages/create-barkpark-app/templates/_shared ─┐
  js/packages/create-barkpark-app/templates/<slug>  ─┼─▶ the Next.js app
  templates/<slug>/  (manifest, JSON schema, seed)  ─┼─▶ barkpark.template.json (+ schema, seed)
  templates/barkpark.template.schema.json           ─┼─▶ barkpark.template.schema.json
  LICENSE                                           ─┘   LICENSE
                                      derived ─────────▶ vercel.json
                                      stamped ─────────▶ TEMPLATE-SOURCE.json (source_commit, tree_digest)
```

`scripts/export-template-repo.mjs` builds the tree. It reads committed files at
`--rev` with `git cat-file`, never the working tree, so the stamped commit is
the one the bytes came from. The same `--rev` always produces a byte-identical
tree. `scripts/export-template-repo.test.mjs` checks every export, and the
required `Cloud gate` runs it through
`cloud/test/barkpark_cloud/templates/standalone_export_test.exs`.

## What the tree contains

- **The app.** `_shared` is copied first and the starter directory over it, as
  `create-barkpark-app` does. `.tmpl` files are rendered with the repository
  name as the package name, and `_gitignore` becomes `.gitignore`.
- **The server manifest.** `barkpark.template.json` comes from
  `templates/<slug>/`, the manifest the Go provisioner catalog embeds (JSON
  schema and a `mutations` seed that runs server-side). It replaces the
  scaffolder's manifest, whose `script` seed cannot run server-side. Its
  `$schema` points at the vendored `./barkpark.template.schema.json`. `name`
  stays the catalog slug (`blog-starter`), not the repository name.
- **`vercel.json`.** `framework` comes from the manifest, and `buildCommand` /
  `installCommand` are `npm run build` / `npm install`. It has no root directory
  setting because the repository root is the app.
- **Dependencies.** The exporter copies the starters' published registry ranges
  and does not change them. It refuses `workspace:`, `file:`, `link:` and git
  specifiers, because it runs offline and cannot choose a version to pin.
- **No lockfile.** Writing one needs the registry and produces different bytes
  on different runs. Vercel resolves the ranges at build time, so a new
  `@barkpark/*` publish inside a range changes what the next deploy installs.
  To pin exactly, raise the floors at the source
  (`js/packages/create-barkpark-app/templates/_shared/package.json.tmpl`, which
  `template-pins.test.ts` guards) and re-export.

## Before the first push: the SDK publish

Measured 2026-09-25 against the npm registry. Running `npm install && npm run build`
in either exported tree fails:

- `@barkpark/react@1.0.0-preview.1` (latest on npm) does not export `./client`
  or `./paper-surface.css`, and both starters import them. The workspace
  package has the same version number but a different exports map. The task
  `rpu-backlog-publish-react-canonical` tracks the publish.
- `@barkpark/nextjs@1.0.0-preview.3` (latest on npm) does not export
  `barkparkMetadata`, which `template-blog` imports. After swapping in the
  vendored react and core tarballs from `templates/search-starter/vendor/`,
  this is the error that remains.

Until both packages are published with those exports, a Vercel clone of either
repository fails at `next build`. The same failure affects any app created
with `create-barkpark-app` today. Pushing the repositories earlier publishes a
template that cannot deploy. Check before pushing:

```sh
node scripts/export-template-repo.mjs --all --out /tmp/tpl
(cd /tmp/tpl/template-blog && npm install && npm run build)
(cd /tmp/tpl/template-website && npm install && npm run build)
```

## Ownership, branch, and pinned revision

- **Owner.** `<ORG>` is a placeholder for the GitHub organization that owns
  both repositories. The owner fills it in when creating them. Both are public.
- **Default branch.** `main`. Every commit on it is an export. Nobody commits to
  it by hand. A pull request opened on a template repository should be made
  against this monorepo instead.
- **Pinned revision.** `TEMPLATE-SOURCE.json` at the repository root records
  `source_commit` (the monorepo sha) and `tree_digest` (sha256 over every other
  file's path, mode and content). Each push also tags the commit
  `source-<12-char sha>`. To reproduce a published tree, re-export that sha and
  compare `tree_digest`.
- **What deploys actually follow.** The Vercel clone URL
  (`vercelCloneUrl` in `cloud/priv/static/app.js`) passes only
  `repository-url`, so Vercel clones the tip of `main`. The stamp and tags
  record which revision that is. They do not stop a later push from changing
  it.

## Owner runbook: item 53, first publish

1. Confirm the SDK publish above: both local builds pass.
2. Create two empty public repositories, with no README, license or
   `.gitignore`: `<ORG>/template-blog` and `<ORG>/template-website`.
   Set the default branch to `main`.
3. Export each template from the current `origin/main`, stamped with its URL:
   ```sh
   git fetch origin main && SHA=$(git rev-parse origin/main)
   node scripts/export-template-repo.mjs --template blog-starter \
     --rev "$SHA" --out /tmp/template-blog --repo-url https://github.com/<ORG>/template-blog
   node scripts/export-template-repo.mjs --template website-starter \
     --rev "$SHA" --out /tmp/template-website --repo-url https://github.com/<ORG>/template-website
   ```
4. Push each tree, for example for the blog:
   ```sh
   cd /tmp/template-blog && git init -b main && git add -A
   git commit -m "Export blog-starter from FRIKKern/barkpark@${SHA}"
   git tag "source-${SHA:0:12}"
   git remote add origin https://github.com/<ORG>/template-blog.git
   git push -u origin main --tags
   ```
5. Point the catalog at the new repositories in one monorepo PR:
   - `cloud/lib/barkpark_cloud/templates.ex`: add a `repo:` value (and a
     `docs:` value pointing at the repository README) to the `blog-starter`
     and `website-starter` entries of `@catalog`. Change `catalog/0` so an
     entry's own `repo` wins over `repo/0`. Today `catalog/0` overwrites every
     entry with the single `repo/0` value (`TEMPLATES_REPO_URL`, default
     `https://github.com/FRIKKern/barkpark`). Keep that override for forks: when
     `TEMPLATES_REPO_URL` is set, it should still apply.
   - Optionally, set the manifest `repo` field in
     `templates/<slug>/barkpark.template.json` and run
     `make provisioner-catalog-sync` so the embedded Go copy matches.
6. After deploy, open `/new?template=blog-starter` on the console. The Vercel
   button's `repository-url` should name the new repository, and a clone should
   build.

## Update procedure

After a change to a starter merges to `main`:

1. Run step 3 with the new `SHA` into a fresh directory.
2. Clone the template repository and compare the trees:
   `diff -r --exclude=.git <clone> /tmp/template-blog`. Only the files you
   changed and `TEMPLATE-SOURCE.json` should differ.
3. Copy the new tree over the clone
   (`rsync -a --delete --exclude=.git /tmp/template-blog/ <clone>/`), commit
   with the source sha in the message, tag it `source-<12-char sha>`, and push.

## Relation to task-32e385b29e75c102

That task found that the fallback Vercel clone points at the monorepo root with
no root directory, so it cannot build a template. For `blog-starter` and
`website-starter`, step 5 fixes this: their `repo` becomes a standalone
repository whose root is the app. `place-directory`, `search-starter` and
`astro-search-starter` still use the monorepo URL, so that task stays open for
them until they get a root-directory parameter or repositories of their own.
