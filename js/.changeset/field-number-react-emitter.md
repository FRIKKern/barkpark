---
"@barkpark/react": minor
---

`field-number` (B085) gains its missing React emitter: a `bp-field` definition row (label + formatted value + optional unit, honest `—` empty state) matching the Elixir `compose.ex field_number_text/1` and Go `pdrender fieldNumberRenderer` twins, registered so registry dispatch no longer degrades `field-number` to the `bp-unknown-block` placeholder. Clears the reopened `pbw-stier-field-number` partial-done; the mobile registry carries the same row natively (D48 parity).
