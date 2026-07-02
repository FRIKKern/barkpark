# TODO (gh-6 follow-up): provision DNS A records for preview hosts

**Status of gh-6:** FULL on-box preview routing shipped. A push to a
non-production branch of a connected repo:

- creates a `preview` Deployment (`environment=preview`, `branch`,
  `preview_slug`, `preview_host`) — builder picks it up like any deploy;
- the runtime executor renders a **dedicated Caddy block** keyed on the preview
  slug + host on its own container/port, **without** touching the production
  slot (`current_deployment_id` / `port`);
- the on-demand-TLS gate `GET /v1/tls/ask` **allowlists the preview host** so
  Caddy issues its cert on demand;
- lifecycle: replace-per-branch, per-site cap + oldest-branch eviction,
  branch-delete teardown; dashboard lists previews distinctly with a
  click-through URL + live console.

## The one remaining hop: public DNS

A preview host `<site-slug>--<branch>-<hash>.barkpark.cloud` only resolves
publicly once an **A record → the site's box IP** exists. Today DNS is owned by
the Go warm-pool (`cloud.CloudDNS` over `hcloud zone rrset`, `HCLOUD_TOKEN`) and
is provisioned **per-instance at go-live** (`internal/cli/cloud/warmpool.go`
~L846, a single `<name>.<zone>` A record). It is **not reachable from the Elixir
control-plane deploy path** that handles the webhook, so a push cannot
synchronously mint a DNS record.

Until this is wired, a preview **routes for any request that reaches the box
with the right `Host` header** (cert issues on demand), but public DNS does not
resolve the host. The dashboard shows the true serving URL; it is not
independently verified as publicly reachable.

## Options

- **(a) Wildcard per instance (preferred):** provision
  `*.<instance-subdomain>.barkpark.cloud` **once** at go-live and nest preview
  hosts under the instance subdomain. One record covers every current + future
  preview on that box — no per-preview DNS. Requires changing the preview host
  scheme to `<branch-slug>-<hash>.<instance-subdomain>.barkpark.cloud` and a
  warm-pool go-live change (`internal/cli/cloud/warmpool.go`).
- **(b) Control-plane DNS seam:** a small DNS-upsert/delete port callable from
  the preview create/teardown paths (`Registry.create_preview_deployment/3`,
  `teardown_branch_previews/2`), authenticating with `HCLOUD_TOKEN`. Per-preview
  records; must also delete on eviction/teardown to avoid leaks.

## Anchors

- `cloud/lib/barkpark_cloud/registry.ex` — `preview_host_for/2`,
  `create_preview_deployment/3`, `teardown_branch_previews/2`,
  `domain_registered?/1` (TLS-ask).
- `internal/runtime/runtime.go` — preview Caddy block + no-`make_current`.
- `docs/ops/barkpark-cloud-go-live.md` Gate 2 — zone/wildcard delegation.
