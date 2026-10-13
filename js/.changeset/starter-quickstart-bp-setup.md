---
'create-barkpark-app': patch
---

The starters' quick start no longer begins with `docker compose up -d`, whose image (`ghcr.io/barkpark/api`) had never been published, so step 1 failed for everyone without a Barkpark checkout. Both starter READMEs, the package README and the scaffolder's next steps now lead with installing the `bp` CLI and `bp setup --target local --yes`. Docker stays as the documented alternative: the shared `docker-compose.yml` now passes the four secrets the API release refuses to boot without (`BARKPARK_CLOAK_KEY`, `BARKPARK_KEK`, `PREVIEW_JWT_SECRET`, `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET`) and names each one when it is missing, and the READMEs say how to generate them.
