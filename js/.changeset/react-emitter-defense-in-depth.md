---
'@barkpark/react': patch
---

PortableDoc defense-in-depth, two non-XSS hardenings from the React SDK XSS class sweep. The form/questionnaire question `type` class modifier now rides a fail-closed lowercase `[a-z0-9-]` slug (the api-endpoint methodSlug pattern) instead of a merely attribute-escaped value, so a type with a space can no longer inject an extra class token (CSS-selector pollution); an empty slug drops the modifier entirely, and the legit type vocabulary is untouched. The «kilde» stamp's link now routes through `safeUrl`, the canonical scheme-allowlister, on top of `parseSourceRef`'s https-only gate — for https refs the emitted bytes are identical, and a future loosening of the parse-gate can no longer make the stamp a live URL sink. All 62 render goldens are byte-identical; a new regression guard pins the https-only gate and the slug behaviour.
