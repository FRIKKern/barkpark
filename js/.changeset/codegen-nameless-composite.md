---
'@barkpark/codegen': patch
---

Harden the type mapper against malformed nested schema descriptors. A `composite`
sub-field missing a `name` now fails with a locatable error naming the composite,
instead of an opaque `TypeError: … reading 'localeCompare'` from the member sort
(the envelope's zod validator only checks name/type on each schema's top-level
field, so nameless nested descriptors slip through — reachable via a hand-authored
`--from` schema or the CI drift-gate fixture). `localizedText.languages` now
filters non-string entries before quoting them, mirroring the existing `select`
options defense, so a stray numeric language key no longer crashes generation.
