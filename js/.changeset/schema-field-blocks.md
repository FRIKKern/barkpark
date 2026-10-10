---
'@barkpark/react': minor
---

`PortableDoc` renders the schema field blocks. `field-string`, `field-slug`, `field-text`, `field-boolean`, `field-select`, `field-datetime`, `field-color`, `field-reference`, `field-image`, `composite`, `arrayOf`, `codelist` and `localizedText` used to render as the "Unsupported block" placeholder. They now render the same read-only definition row as the Phoenix reader: a `bp-field` label beside its value. Each type is checked against the Elixir golden. `field-reference` and `codelist` show a server-stashed `_ref_title` / `_code_label` when present, else the stored value. `embed` and `master-ref` still need server context and are unchanged.
