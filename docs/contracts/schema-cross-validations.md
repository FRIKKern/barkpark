<!-- doc-tier: agent | canonical-for: schema-cross-validations | budget: 300tok -->
# Schema cross-field rules

`cross_validations` entries: `{name, title, rule, level, fields}`. `rule` is a `visibleWhen` predicate, or `{all: [...]}` / `{any: [...]}` of them. Studio shows unsatisfied rules as a banner; API writes get the same rules as findings (code `cross_validation`, path `/<first of fields>`) through the same warnings/422 door as `validation` findings ([schema-reference.md](schema-reference.md)), by `level`. A rule naming an undeclared field or an unknown operator, or with no `rule`, is skipped and logged.

## Code anchors

- `api/lib/barkpark/content/cross_validator.ex`
