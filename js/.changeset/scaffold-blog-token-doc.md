---
'create-barkpark-app': patch
---

The blog starter's README now documents the correct dev token. It presented `changeme-barkpark-dev-token` as the working token, but the API seeds `barkpark-dev-token` (`api/config/dev.exs` `:dev_browser_token`) — following the README led straight to a 401. The website starter already carried the fix (token + a note that `.env.example` ships a placeholder to replace); the blog starter was missed. Brought it in line: README shows `barkpark-dev-token` and explains the `.env.example` placeholder. (Both starters keep `changeme-…` in `.env.example` by design — a deliberate "replace me" placeholder.)
