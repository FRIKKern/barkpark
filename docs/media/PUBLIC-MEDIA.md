<!-- doc-tier: agent | canonical-for: media-public-delivery | budget: 1100tok -->
# Public media for a website

A browser loads a site's images without a token. Without an opt-in, an anonymous request for a scoped media URL answers 403 `not_a_member`. The flat `/media/files/<path>` serves the seeded Default workspace only, so another workspace's path answers 404 there.

## Turn it on

The opt-in is a `:media` `:read` share on one workspace, project and dataset. An admin of that workspace sets it:

```bash
bp share publish-media <workspace>/<project>/<dataset>   # project defaults to default, dataset to production
```

or `POST /v1/shares/media` with `{"scope": "<workspace>/<project>/<dataset>"}` and an admin token. The call adds `media` to any share the scope already has and keeps its access level. The Studio media library has the same action. `bp share ls` lists shares. `bp share rm <scope>` removes the scope's stored share, its other surfaces, item links and edit tokens included.

A share is the only switch. Route admission never reads an asset's `bp_visibility`, so marking assets `public` alone opens nothing. A separate workspace setting would be a second source of truth for "public" beside shares, which the ruling on task-8627e1a3f974693d refused (`BarkparkWeb.Plugs.RequireShareScope` moduledoc). A `public-read` token does not help an `<img>` tag, which cannot send a header.

## What it serves

Every GET and HEAD under `/w/<ws>/p/<proj>` for that dataset:

- originals and on-demand transforms, `/media/files/<path>[?w=...]`, see [IMAGE-TRANSFORMS.md](IMAGE-TRANSFORMS.md);
- named renditions, `/media/renditions/<id>/<preset>`;
- Sanity image and file URLs, `/images/...` and `/files/...`, see [SANITY-IMAGE-URLS.md](SANITY-IMAGE-URLS.md).

A public asset answers with a strong `ETag` and `304` on `If-None-Match`. Transforms send `Cache-Control: public, max-age=2592000`. Originals and renditions send `public, max-age=86400, must-revalidate`, because the bytes behind a stable URL can change.

## What stays protected

- An asset with `bp_visibility: "private"` or `"token"` answers 403 to an anonymous caller.
- An asset with `rights.watermarkProfile` set serves transforms and renditions with the watermark drawn. Its original URL answers 403 to a caller that is not a media principal, because the stored bytes carry no watermark.
- Writes still need membership. The share admits GET and HEAD only, so an anonymous upload, patch or delete is refused.
- Other datasets of the workspace stay closed, and a file of another dataset answers 404 through the shared one.
- A member's token or session is checked by membership as before. A signed-in member never reads at share level.

## Drafts

Uploads create the `mediaAsset` document as a draft today, and the decision about that is pending on task-9ca3b4c6c58839cc. Delivery does not depend on it. It reads the newest `mediaAsset` document for the file, `drafts.<id>` or published, and decides on the share plus that document's `bp_visibility` and watermark. A visibility change saved in a draft therefore takes effect at once, before publish.

Code: `Barkpark.Sharing.publish_media/1`, `BarkparkWeb.Plugs.RequireShareScope`, `Barkpark.Media.Storage.Access`. Tests: `test/barkpark_web/integration/public_media_share_test.exs`.
