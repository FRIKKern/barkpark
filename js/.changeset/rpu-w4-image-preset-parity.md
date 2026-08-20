---
---

render-unification W4 (media third): a test-only parity proof for the
`@barkpark/react` image path — `imageUrl`/`BarkparkImage` resolve `{_id}+preset`
to `/media/renditions/<id>/<preset>`, a bare-URL asset passes through unchanged,
the rendition URL lands in the SSR `<img src>`, and NO `srcset` is emitted
(aspect-varying preset crops are a reconciled GAP, not a width ladder). No source
or published API changed, so this is an empty changeset that satisfies the
changeset-present gate without a version bump.
