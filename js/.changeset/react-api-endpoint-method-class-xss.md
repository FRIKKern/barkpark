---
'@barkpark/react': patch
---

Fix a stored-XSS in the `api-endpoint` PortableDoc block emitter. The method-class modifier was interpolated raw (`bp-api-endpoint__method--${method.toLowerCase()}`) into the class attribute of the rendered HTML, so a user-controlled `method` such as `"><img src=x onerror=alert(1)>` broke out of the attribute and rendered as live markup on the fully-live render surface (the emitter string is injected via `dangerouslySetInnerHTML`, with no CSP or sanitizer). The modifier is now a fail-closed lowercase `[a-z0-9-]` slug (hyphen kept, empty slug drops the modifier), mirroring the Phoenix `compose.ex` emitter; legit methods (`GET`/`POST`/…) keep their byte-identical `bp-api-endpoint__method--<m>` class.
