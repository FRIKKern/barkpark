<!-- doc-tier: human | canonical-for: deploy-with-barkpark-launch | budget: 1700tok -->
# Deploy with Barkpark

The "Deploy with Barkpark" badge takes a visitor from a template's README to a
managed Barkpark instance with that template's content, an editable Studio, and
a hand-off to host the site on Vercel. This page describes what the flow does
today, including the parts that still depend on operator setup.

```
badge ──► /new?template=<slug> ──► sign in ──► Launch ──► progress ──► ready
                                                                        ├─ Open Studio
                                                                        └─ Deploy the site (Vercel)
```

## The badge

Paste this into a README. Change `blog-starter` to any slug in the table below.

```markdown
[![Deploy with Barkpark](https://barkpark.cloud/button.svg)](https://barkpark.cloud/new?template=blog-starter)
```

| Template | Ships a site app |
|---|---|
| `astro-search-starter` | no |
| `blog-starter` | yes |
| `place-directory` | no |
| `search-starter` | no |
| `website-starter` | yes |

All five launch an instance with the template's content. Only the two that ship
a site app can be deployed to Vercel from the ready screen; the others give you
an instance and Studio, and you build the site yourself.

## What happens after the click

1. **Template card.** The badge opens `GET /new?template=<slug>`. The page reads
   the public catalog from `GET /v1/templates` and shows the template's title,
   description and what you get. A missing or unknown slug shows a template
   picker instead of an error.
2. **Sign in.** Visitors without a session log in or sign up on the same page
   (`POST /v1/auth/login`, `POST /v1/auth/register`, or an enabled OAuth
   provider). After OAuth the browser returns to the same template.
3. **Launch.** The Launch button sends `POST /v1/launch` with the template slug
   and a project name. You must be an owner or admin of the team. A team that
   has not used its free trial gets it started here; a team without an active
   plan sees the plan picker (HTTP 402). An unknown template is refused (HTTP
   422) before any server is created.
   The form labels the name as optional, but the server currently refuses a
   launch without one (`name_required`). Type a name.
4. **Progress.** The page adds `&bp=<id>` to its address, so a refresh resumes
   the same launch rather than starting a new one. The steps come from the
   provisioning worker, with real timestamps and a live log:

   | Step | Shown as |
   |---|---|
   | `create` | Creating your server |
   | `freshen` | Updating to the latest Barkpark |
   | `secure` | Securing your domain |
   | `configure` | Configuring Barkpark |
   | `content` | Installing your content |
   | `verify` | Testing login & Studio |
   | `ready` | Finishing up |

   `freshen` appears only when the server had to update itself, and `content`
   only when a template was chosen.
5. **Ready.** The instance is live at its own `*.barkpark.cloud` address.
   **Open Studio** calls `POST /v1/barkparks/:id/studio-link`, which returns a
   single-use sign-in link valid for 60 seconds. No token is copied or pasted.

If provisioning fails, the page shows the failed step and a Retry setup button
(`POST /v1/barkparks/:id/retry`). Retry never starts a second server while one
is still being provisioned.

## Deploying the site

The ready screen reads the instance's connection values from
`GET /v1/barkparks/:id/bootstrap` (team admins only) and offers up to three
ways to put the site online. Which ones appear depends on how the operator set
up the control plane.

| Route | Needs | Without it |
|---|---|---|
| One-click Vercel deploy: `POST /v1/barkparks/:id/vercel-deploy` deploys the template with every value set, then gives you a link to claim the project into your Vercel account. | `VERCEL_PLATFORM_TOKEN` on the control plane | Returns 503 and the page shows the copy-and-paste route instead. |
| Your own GitHub repo: `POST /v1/github/repos` creates a repo in your account and pushes the template's app. | A registered GitHub App on the control plane, and your team connected to it | The option is hidden. |
| Copy-and-paste: a `vercel.com/new/clone` link plus one "Copy value" button per environment variable. | Nothing | Always available. |

After the site is deployed, paste its URL into the ready screen
(`POST /v1/barkparks/:id/site-url`) so publishing in Studio refreshes the site.

## Launch from the API

A personal access token with the `deploy` ability can launch without the
browser:

```sh
curl -X POST https://barkpark.cloud/v1/launch \
  -H "Authorization: Bearer $BARKPARK_CLOUD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "My blog", "template": "blog-starter"}'
```

A 201 response carries the new instance as `barkpark`, with its `id`. Follow
its progress in the console, or at `/new?template=blog-starter&bp=<id>`. The `bp launch` and
`bp go-live` commands do not take a template yet.

## Not live yet

These parts of the path are not available today. They are tracked on the
Barkpark task ledger.

- **Standalone template repos (task `dwb-2`).** The templates live inside the
  Barkpark monorepo, and the badge is only in Barkpark's own README. The
  copy-and-paste Vercel link names the monorepo and no root directory, so
  Vercel starts from the repository root rather than the template's folder.
- **GitHub App (task `gh-1`).** Not registered on barkpark.cloud, so the
  "Create GitHub repo" option does not appear there.
- **Vercel platform token (task `dwb-vercel-token-gate`).** Until it is set on
  barkpark.cloud, the one-click Vercel deploy answers 503 and the
  copy-and-paste route is shown.

## Keeping this page accurate

`cloud/test/barkpark_cloud/web/deploy_button_docs_test.exs` reads this page and
the root README. It fails when a URL, route or template slug named here stops
matching the router, the template catalog, or the console code behind
`/new`.
