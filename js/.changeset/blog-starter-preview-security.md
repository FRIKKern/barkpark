---
'create-barkpark-app': patch
---

blog-starter: harden the `/api/preview` and `/api/exit-preview` routes. The `?path=` redirect target is now same-origin only — external (`https://evil.com`) and protocol-relative (`//host`, `/\host`) values fall back to `/`, closing an open redirect. `/api/preview` also gates `draftMode().enable()` fail-closed: if `BARKPARK_PREVIEW_SECRET` is set the caller must pass a matching `?secret=`, and in production without a secret preview is refused with 401 — so an anonymous visitor can no longer flip a deployed site into draft mode and read unpublished content. Local dev stays frictionless (no secret required outside production).
