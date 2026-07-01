---
'@barkpark/react': patch
---

`<BarkparkImage>`: prepend `baseUrl` to an expanded asset whose inline `.url` is a relative `/media/…` path. The no-preset expanded-asset branch previously returned the inline url verbatim, so an expanded `{_id, url:'/media/files/x.jpg'}` rendered with a cross-origin CDN `baseUrl` resolved against the page origin — a broken/wrong-origin image. It now mirrors the string branch: relative inline urls are joined to `baseUrl`, while absolute inline urls are used unchanged (no double-prefix).
